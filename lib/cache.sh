#!/usr/bin/env bash
#
# lib/cache.sh — catalog probe cache for the ubuntu-setup script collection.
#
# The TUI catalog (lib/ui.sh) and swkit list/search probe every script's `meta` and
# `status` by forking a subprocess per script — ~3s for the whole collection on a cold
# run. This module memoizes those probes so the catalog can paint instantly from cache and
# revalidate in the background (stale-while-revalidate). It is the data twin of ui.sh's
# rendering: ui.sh decides WHEN to show; this decides WHAT is known and how fresh.
#
# Two kinds of cached data, by nature:
#   - meta   : 100% static (hardcoded in each script) -> cached forever, keyed by the
#              script file's mtime; only re-probed when the .sh changes.
#   - status : live install boolean (read-only, no network, no side effects) -> cached
#              with a timestamp; revalidated in the background and precisely invalidated
#              after any op runs on a script.
#
# A stale badge NEVER causes a wrong action: real install/remove always runs the script,
# whose status gate re-checks the live system (idempotency). The cache only affects display.
#
# Sourced (not executed) by common.sh BEFORE ui.sh, so the catalog and swkit/bootstrap all
# share it. Honors SUDO_USER for the real home (same as kit_load_lang). User-space, no sudo.

[[ -n "${_KIT_CACHE_LOADED:-}" ]] && return 0
_KIT_CACHE_LOADED=1

# Soft TTL (seconds): a status entry younger than this is trusted without re-probing on
# catalog entry (throttles repeated spawns). Override with KIT_STATUS_TTL.
: "${KIT_STATUS_TTL:=5}"

# Resolve the real user's home, honoring a sudo wrapper (mirror kit_load_lang).
_kit_real_home() {
  local home="${HOME:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
  fi
  printf '%s' "$home"
}

_KIT_CACHE_DIR=""
kit_cache_dir() {
  if [[ -n "$_KIT_CACHE_DIR" ]]; then printf '%s' "$_KIT_CACHE_DIR"; return 0; fi
  local home dir fallback="/tmp/ubuntu-setup-catalog-$EUID"
  home="$(_kit_real_home)"
  if [[ -n "$home" ]]; then dir="$home/.cache/ubuntu-setup/catalog"; else dir="$fallback"; fi
  if ! mkdir -p "$dir" 2>/dev/null; then dir="$fallback"; mkdir -p "$dir" 2>/dev/null || true; fi
  chmod 0700 "$dir" 2>/dev/null || true
  _KIT_CACHE_DIR="$dir"
  printf '%s' "$dir"
}

# Epoch mtime of a file (0 if missing).
_kit_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# Filename-safe base (script basename without .sh) for cache file names. Pure bash param
# expansion (no basename fork) — this runs in every cache hot-path read.
_kit_cache_base() { local b="${1##*/}"; printf '%s' "${b%.sh}"; }
_kit_cache_keysafe() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# Current epoch seconds via the printf builtin (no `date` fork). Falls back to date.
_kit_now() { local t; printf -v t '%(%s)T' -1 2>/dev/null && printf '%s' "$t" || date +%s 2>/dev/null || echo 0; }

# Atomically replace FILE with stdin (temp file + mv). Best-effort; cleans up on failure.
_kit_atomic_write() {
  local file="$1" tmp="$1.tmp.$$"
  if cat >"$tmp" 2>/dev/null; then
    if ! mv -f "$tmp" "$file" 2>/dev/null; then rm -f "$tmp" 2>/dev/null || true; fi
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Read one field from a key=value file. $1 file, $2 field. Prints value, 1 if missing.
_kit_cache_field() {
  local f="$1" k="$2" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" == "$k="* ]]; then printf '%s' "${line#*=}"; return 0; fi
  done <"$f"
  return 1
}

# Print the script's meta field block, from cache when the .sh is unchanged, else (re)probe.
kit_meta_cached() {
  local script="$1" base cache mtime blob
  [[ -n "${KIT_NO_CACHE:-}" ]] && { "$script" meta 2>/dev/null; return $?; }
  base="$(_kit_cache_base "$script")"
  _kit_cache_keysafe "$base" || { "$script" meta 2>/dev/null; return $?; }
  cache="$(kit_cache_dir)/${base}.meta"
  mtime="$(_kit_mtime "$script")"
  if [[ -f "$cache" ]] && [[ "$(_kit_cache_field "$cache" script_mtime)" == "$mtime" ]]; then
    grep -v '^script_mtime=' "$cache" 2>/dev/null
    return 0
  fi
  blob="$("$script" meta 2>/dev/null)" || return 1
  { printf 'script_mtime=%s\n' "$mtime"; printf '%s\n' "$blob"; } | _kit_atomic_write "$cache"
  printf '%s\n' "$blob"
}

# Fast read of cached meta WITHOUT mtime revalidation and WITHOUT any fork — for the UI hot
# path's first paint, where instant matters more than catching a just-edited script (the
# background rescan / `r` refresh / child-return rescan use kit_meta_cached to pick up edits).
# Returns 1 if there is no cached meta (caller then probes). Honors KIT_NO_CACHE.
kit_meta_read() {
  local base cache line
  [[ -n "${KIT_NO_CACHE:-}" ]] && { "$1" meta 2>/dev/null; return $?; }
  base="$(_kit_cache_base "$1")"
  cache="$(kit_cache_dir)/${base}.meta"
  [[ -f "$cache" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == script_mtime=* ]] && continue
    printf '%s\n' "$line"
  done <"$cache"
}

# Probe status (boolean only), write installed + ts. Exit code = installed. KIT_PROBE_ONLY
# tells slimmed status functions to skip expensive detail.
kit_probe_status() {
  local script="$1" base cache inst ts
  if KIT_PROBE_ONLY=1 "$script" status >/dev/null 2>&1; then inst=1; else inst=0; fi
  if [[ -z "${KIT_NO_CACHE:-}" ]]; then
    base="$(_kit_cache_base "$script")"
    if _kit_cache_keysafe "$base"; then
      ts="$(_kit_now)"
      cache="$(kit_cache_dir)/${base}.status"
      { printf 'installed=%s\n' "$inst"; printf 'status_ts=%s\n' "$ts"; } | _kit_atomic_write "$cache"
    fi
  fi
  [[ "$inst" == 1 ]]
}

# Print cached install boolean (1/0) or empty if unknown. Never probes. Honors KIT_NO_CACHE
# (probes once, no write).
kit_status_value() {
  local script="$1" base cache
  if [[ -n "${KIT_NO_CACHE:-}" ]]; then
    if KIT_PROBE_ONLY=1 "$script" status >/dev/null 2>&1; then printf '1'; else printf '0'; fi
    return 0
  fi
  base="$(_kit_cache_base "$script")"
  cache="$(kit_cache_dir)/${base}.status"
  _kit_cache_field "$cache" installed 2>/dev/null || true
}

# Seconds since the last status probe (999999 if never).
kit_status_age() {
  local script base cache ts now
  script="$1"; base="$(_kit_cache_base "$script")"
  cache="$(kit_cache_dir)/${base}.status"
  ts="$(_kit_cache_field "$cache" status_ts 2>/dev/null || echo '')"
  [[ -n "$ts" ]] || { echo 999999; return 0; }
  now="$(_kit_now)"
  echo $(( now - ts ))
}

# Drop a script's cached status (force re-probe). Keeps meta.
kit_cache_invalidate() {
  local base; base="$(_kit_cache_base "$1")"
  _kit_cache_keysafe "$base" || return 0
  rm -f "$(kit_cache_dir)/${base}.status" 2>/dev/null || true
}

kit_cache_clear() {
  local dir; dir="$(kit_cache_dir)"
  rm -f "$dir"/*.meta "$dir"/*.status "$dir"/*.tmp.* 2>/dev/null || true
}

# Usable parallelism, capped to keep low-core machines sane.
_kit_nproc() {
  local n; n="$(nproc 2>/dev/null || echo 2)"; case "$n" in ''|*[!0-9]*) n=2 ;; esac
  (( n > 8 )) && n=8; (( n < 1 )) && n=1; printf '%s' "$n"
}

# Run FN over each script in DIR, in parallel, batched by the core cap. FN gets the path.
_kit_parallel_scripts() {
  local dir="$1" fn="$2" f cap n=0
  [[ -d "$dir" ]] || return 0
  cap="$(_kit_nproc)"
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    [[ -x "$f" ]] || continue
    [[ "$(basename "$f")" == TEMPLATE.sh ]] && continue
    "$fn" "$f" >/dev/null 2>&1 &
    (( ++n % cap == 0 )) && wait
  done
  shopt -u nullglob
  wait
}

# Warm only meta (cheap; fills meta cache so subsequent reads are warm).
kit_meta_warm() { _kit_parallel_scripts "${1:-${KIT_SCRIPTS_DIR:-}}" kit_meta_cached; }

# Warm meta then status for the whole collection (preload). Forces a fresh status re-probe
# of every script — use for an explicit `swkit warm` / startup preload where fresh state is
# wanted. meta first so .meta files exist.
kit_cache_warm() {
  local dir="${1:-${KIT_SCRIPTS_DIR:-}}"
  _kit_parallel_scripts "$dir" kit_meta_cached
  _kit_parallel_scripts "$dir" kit_probe_status
}

# Probe a script's status only if it is missing or older than the soft TTL.
_kit_probe_if_stale() {
  local script="$1" v age
  v="$(kit_status_value "$script")"
  age="$(kit_status_age "$script")"
  if [[ -z "$v" ]] || (( age > KIT_STATUS_TTL )); then kit_probe_status "$script" >/dev/null 2>&1; fi
}

# Fill the cache for a one-shot consumer (swkit list): meta always (mtime-cheap), status only
# for missing/stale entries. A warm cache within the TTL re-probes nothing -> near-instant.
kit_cache_fill() {
  local dir="${1:-${KIT_SCRIPTS_DIR:-}}"
  _kit_parallel_scripts "$dir" kit_meta_cached
  _kit_parallel_scripts "$dir" _kit_probe_if_stale
}
