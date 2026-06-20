#!/usr/bin/env bash
#
# lib/common.sh — shared safety primitives for the ubuntu-setup script collection.
#
# This library is the "safety contract as code". Every script in scripts/ sources it
# and composes its helpers, so the project's non-negotiables — idempotency probes,
# per-command sudo (never whole-root), non-interactive apt, channel-conservative repo
# setup, back-up-before-edit — are implemented ONCE here and inherited by every script,
# including ones added to the repo later. Writing a conformant script is mostly a matter
# of calling these functions; unsafe patterns (sudo npm, apt-key, whole-root) have no
# primitive on purpose.
#
# Source it, then define meta/status/do_install/do_remove[/do_configure]/usage and call
# `kit_dispatch "$@"`. See scripts/TEMPLATE.sh.
#
# This file is meant to be SOURCED, not executed: it defines functions and a few
# read-only variables and never sets shell options (the sourcing script owns `set -e`).

# Idempotent load guard: sourcing twice in one process must not re-declare readonlys.
[[ -n "${_KIT_COMMON_LOADED:-}" ]] && return 0
_KIT_COMMON_LOADED=1

# --- Locations (resolved from this file's path) --------------------------------
# scripts/ live next to lib/ under $KIT_ROOT, so a script can locate the library as
#   KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; source "$KIT_ROOT/lib/common.sh"
KIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_ROOT="$(dirname "$KIT_LIB_DIR")"
KIT_SCRIPTS_DIR="$KIT_ROOT/scripts"
# Public API: swkit and bootstrap source this file and read these.
# shellcheck disable=SC2034
readonly KIT_LIB_DIR KIT_ROOT KIT_SCRIPTS_DIR

# --- Exit codes ----------------------------------------------------------------
# A step needed root, but sudo wants a password and there is no terminal here to type
# it (the common case when the LLM runs a script through its non-interactive shell).
# sudo_run prints the exact command to run by hand and returns this; `set -e` then stops
# the script. Callers/skills branch on this code, never on message text.
readonly RC_NEED_SUDO=97

# --- Logging (stderr; colors only on a tty) ------------------------------------
if [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]; then
  _KIT_C_INFO=$'\033[1;34m' _KIT_C_WARN=$'\033[1;33m' _KIT_C_ERR=$'\033[1;31m' _KIT_C_OFF=$'\033[0m'
else
  _KIT_C_INFO="" _KIT_C_WARN="" _KIT_C_ERR="" _KIT_C_OFF=""
fi

log_info() { printf '%s[info]%s %s\n'  "$_KIT_C_INFO" "$_KIT_C_OFF" "$*" >&2; }
log_warn() { printf '%s[warn]%s %s\n'  "$_KIT_C_WARN" "$_KIT_C_OFF" "$*" >&2; }
log_err()  { printf '%s[error]%s %s\n' "$_KIT_C_ERR"  "$_KIT_C_OFF" "$*" >&2; }

# --- Probes (idempotency: observe the live system, never trust notes) ----------

# Is CMD on PATH?
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Is the dpkg package fully installed? True ONLY for "install ok installed" — a
# removed-but-not-purged package still produces dpkg output and must not count.
pkg_installed() {
  local status
  status="$(dpkg-query -W -f '${Status}' "$1" 2>/dev/null)" || return 1
  [[ "$status" == "install ok installed" ]]
}

# --- sudo (per-command escalation; never whole-root; no password handling) -----

sudo_available() { command -v sudo >/dev/null 2>&1; }

# Is sudo passwordless right now? Decide on the EXIT STATUS of `sudo -n true`, never on
# message text (classic sudo vs sudo-rs differ and may be localized).
sudo_passwordless() { sudo -n true 2>/dev/null; }

# Can we open the controlling terminal for reading and writing? The device node can
# exist yet fail to open (ENXIO) when there is no controlling terminal (cron, nohup,
# the LLM's non-interactive shell), so actually try to open it rather than test -r/-w.
kit_have_tty() { { true </dev/tty; } 2>/dev/null && { true >/dev/tty; } 2>/dev/null; }

# Run a single command with root privilege, escalating per command:
#   - already root            -> run it directly
#   - sudo is passwordless     -> sudo <cmd>
#   - a terminal is available  -> sudo <cmd> (sudo prompts for the password)
#   - otherwise (no tty)       -> print the exact command to run by hand, return RC_NEED_SUDO
# Never echoes/pipes/here-strings a password into `sudo -S`, never stores a password,
# never writes a NOPASSWD rule. This is the ONLY supported way to escalate.
sudo_run() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
    return $?
  fi
  if ! sudo_available; then
    local cmd_str; cmd_str="$(printf '%q ' "$@")"
    log_err "This step needs root, but neither root nor sudo is available."
    log_err "Ask an administrator to run:"
    log_err "    ${cmd_str}"
    return "$RC_NEED_SUDO"
  fi
  if sudo_passwordless || kit_have_tty; then
    sudo "$@"
    return $?
  fi
  local cmd_str; cmd_str="$(printf '%q ' "$@")"
  log_err "This step needs root, but sudo requires a password and there is no terminal"
  log_err "here to enter it. Enable passwordless sudo (re-run ./bootstrap.sh and turn on"
  log_err "the toggle), or run this command yourself and then re-try:"
  log_err "    sudo ${cmd_str}"
  return "$RC_NEED_SUDO"
}

# --- apt (non-interactive, lean; escalates via sudo_run) -----------------------

# `apt-get update`, but only the first time in this process (a sentinel avoids
# re-updating for every package in a multi-step install).
apt_update_once() {
  [[ -n "${_KIT_APT_UPDATED:-}" ]] && return 0
  sudo_run env DEBIAN_FRONTEND=noninteractive apt-get update
  _KIT_APT_UPDATED=1
}

apt_install() {
  apt_update_once
  sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Uses `remove` (not `purge`) so user configuration survives — the conservative default.
apt_remove() {
  sudo_run env DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
}

# --- Files (back up before editing; idempotent append) -------------------------

# Timestamped copy of PATH next to it, if it exists. That backup is the only "undo".
backup_file() {
  local f="$1" bak
  [[ -e "$f" ]] || return 0
  bak="${f}.bak.$(date +%s)"
  cp -p "$f" "$bak"
  log_info "Backed up $f -> $bak"
}

# Append LINE to FILE only if an exact-match line is not already present (so re-runs
# never accumulate duplicates). Creates FILE if missing.
append_once() {
  local line="$1" file="$2"
  if [[ -f "$file" ]] && grep -qxF "$line" "$file"; then
    return 0
  fi
  printf '%s\n' "$line" >>"$file"
}

# _ensure_dir_on_path DIR RC_LINE — put DIR on PATH for this process (so a just-installed CLI
# is found now) and append RC_LINE (a literal that re-expands at shell-startup time) to the
# user's shell rc for future shells. Runs as the user — never edits another user's dotfiles.
# No-op if DIR is already on PATH or does not exist yet.
_ensure_dir_on_path() {
  local dir="$1" rc_line="$2" rc_file
  case ":$PATH:" in
    *":$dir:"*) return 0 ;;
  esac
  [[ -d "$dir" ]] || return 0
  export PATH="$dir:$PATH"
  case "${SHELL:-/bin/bash}" in
    */zsh) rc_file="$HOME/.zshrc" ;;
    *)     rc_file="$HOME/.bashrc" ;;
  esac
  append_once "$rc_line" "$rc_file"
  log_warn "Added $dir to PATH in $rc_file — open a new shell or run 'source $rc_file'."
}

# Ensure ~/.local/bin is on PATH. The official native installers (Claude Code, Codex) and
# user-space tools (uv) drop binaries there, as does the `swkit` symlink itself.
ensure_local_bin_on_path() {
  # Literal — must expand at shell-startup time, not now.
  # shellcheck disable=SC2016
  _ensure_dir_on_path "$HOME/.local/bin" 'export PATH="$HOME/.local/bin:$PATH"'
}

# Ensure the npm global bin dir is on PATH, for CLIs installed via `npm install -g`. The dir
# is derived LIVE from `npm config get prefix` (<prefix>/bin), so a user's custom prefix is
# honored; for the kit default this is ~/.npm-global/bin — kept out of ~/.local/bin so npm
# globals never collide with native installers (Claude/Codex) that land there.
ensure_npm_global_bin_on_path() {
  have_cmd npm || return 0
  local prefix bin line
  prefix="$(npm config get prefix 2>/dev/null)" || return 0
  [[ -n "$prefix" ]] || return 0
  bin="$prefix/bin"
  # Literal $PATH — must re-expand at shell-startup time, not now.
  # shellcheck disable=SC2016
  printf -v line 'export PATH="%s:$PATH"' "$bin"
  _ensure_dir_on_path "$bin" "$line"
}

# --- Vendor apt channel (channel priority; NEVER apt-key) ----------------------
# Helpers for scripts that need a current version from a vendor's official apt repo:
# put the dearmored key in /etc/apt/keyrings and reference it with signed-by= in a
# sources.list.d entry. apt-key is dead and must not be used.

# add_apt_keyring NAME KEY_URL — fetch and dearmor a signing key to
# /etc/apt/keyrings/NAME.gpg (world-readable). Dearmor happens as the user (into a temp
# file); only the install into /etc needs root.
add_apt_keyring() {
  local name="$1" url="$2" tmp rc=0
  have_cmd curl || apt_install curl ca-certificates
  have_cmd gpg  || apt_install gnupg
  sudo_run install -d -m 0755 /etc/apt/keyrings
  tmp="$(mktemp)"
  if ! curl -fsSL "$url" | gpg --dearmor >"$tmp" 2>/dev/null; then
    rm -f "$tmp"; log_err "Failed to fetch or dearmor key from $url"; return 1
  fi
  sudo_run install -m 0644 "$tmp" "/etc/apt/keyrings/${name}.gpg" || rc=$?
  rm -f "$tmp"
  return $rc
}

# add_apt_source NAME LINE — write a single sources.list.d entry (the LINE should carry
# its own signed-by=/etc/apt/keyrings/NAME.gpg reference).
add_apt_source() {
  local name="$1" line="$2" tmp rc=0
  tmp="$(mktemp)"
  printf '%s\n' "$line" >"$tmp"
  sudo_run install -m 0644 "$tmp" "/etc/apt/sources.list.d/${name}.list" || rc=$?
  rm -f "$tmp"
  return $rc
}

# --- npm (user-space global; NEVER sudo npm install -g) ------------------------

# Resolve npm's global prefix and confirm it is writable by the current user. Returns
# non-zero (with guidance) when it is not, so callers stop instead of reaching for sudo.
npm_global_writable() {
  local prefix target
  have_cmd npm || { log_err "npm not found."; return 1; }
  prefix="$(npm config get prefix 2>/dev/null)"
  target="$prefix/lib/node_modules"
  [[ -d "$target" ]] || target="$prefix"
  if [[ ! -w "$target" ]]; then
    log_err "npm's global prefix ($prefix) is not writable by $(id -un)."
    log_err "Refusing 'sudo npm install -g'. Point npm at a user-writable prefix instead:"
    log_err "    npm config set prefix \"\$HOME/.npm-global\""
    return 1
  fi
  return 0
}

# Make `npm install -g` work AS THE USER (never sudo) for scripts whose only install channel
# is npm. If the global prefix is already user-writable, do nothing. If it is a system DEFAULT
# (/usr or /usr/local) — i.e. the user never chose a custom prefix — redirect npm's *user*
# config to ~/.npm-global (writes ~/.npmrc, no sudo) — a DEDICATED npm-global dir kept out of
# ~/.local/bin so it never collides with native installers (Claude/Codex) landing there — and
# re-verify. A CUSTOM but unwritable prefix is left untouched (respect the user's deliberate
# choice) and we refuse with the standard guidance. Returns 0 only once global installs will
# land somewhere writable. This is the automated form of npm_global_writable's printed advice:
# the safe path becomes the default instead of a manual step. Revert with: npm config delete prefix.
npm_ensure_user_prefix() {
  have_cmd npm || { log_err "npm not found."; return 1; }
  # npm global installs must run AS THE USER, never root. Under a sudo wrapper the real user
  # is SUDO_USER, yet npm would read root's $HOME/config and write root-owned files — so we
  # refuse and tell them to run as themselves. (Genuine root with no SUDO_USER is fine: $HOME
  # is /root and it installs for root; that is not the forbidden `sudo npm`.)
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    log_err "Run this as your normal user, not via sudo — npm global installs must not run as root."
    log_err "    (re-run as '$SUDO_USER' without sudo)"
    return 1
  fi
  npm_global_writable 2>/dev/null && return 0

  local prefix; prefix="$(npm config get prefix 2>/dev/null)"
  case "$prefix" in
    /usr|/usr/ | /usr/local|/usr/local/)
      local target="$HOME/.npm-global"
      log_info "npm's global prefix ($prefix) is not user-writable; configuring a user-space prefix ($target) — no sudo."
      log_info "(Reverts with: npm config delete prefix)"
      npm config set prefix "$target" || { log_err "Could not set the npm prefix."; return 1; }
      mkdir -p "$target/lib/node_modules" "$target/bin"
      ;;
    *)
      # A custom prefix we cannot write — do not clobber it; print the standard guidance.
      npm_global_writable
      return 1
      ;;
  esac

  if ! npm_global_writable 2>/dev/null; then
    log_err "npm's global prefix is still not writable after configuring $HOME/.npm-global."
    return 1
  fi
  # NOTE: callers run ensure_npm_global_bin_on_path right after `npm install -g`; we deliberately
  # don't here (avoids a redundant, $HOME-touching call inside this prefix-only helper).
  return 0
}

# --- Script skeleton -----------------------------------------------------------

# Print one "KEY=VALUE" metadata line (a convenience for meta functions).
emit_meta_line() { printf '%s=%s\n' "$1" "$2"; }

# Load the persisted interface language into UI_LANG if it is not already set, so a script
# run DIRECTLY (via swkit or the LLM, not through bootstrap.sh which already exports UI_LANG)
# still renders chrome — and translated strings like the tmux plugin descriptions — in the
# user's chosen language. The language lives in ~/.config/ubuntu-setup/config as LANG_CODE,
# written by bootstrap.sh's Settings page. PARSED WITH grep, never sourced: that file is
# user-writable and must not be executed. Honors SUDO_USER so a sudo-wrapped run reads the
# real user's config, not root's. Best-effort: any miss leaves UI_LANG unset and ui_t falls
# back to English. (This is the lib-level counterpart of bootstrap.sh's load_config/save_lang
# — keep the file path and accepted codes in sync across the two.)
kit_load_lang() {
  [[ -n "${UI_LANG:-}" ]] && return 0
  local home="${HOME:-}" cfg code
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || return 0
  cfg="$home/.config/ubuntu-setup/config"
  [[ -f "$cfg" ]] || return 0
  code="$(grep -E '^LANG_CODE=' "$cfg" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '[:space:]' || true)"
  case "$code" in zh|en|ja) export UI_LANG="$code" ;; esac
}

# Route a script's subcommand to its convention functions. A script defines
#   meta status do_install do_remove [do_configure] [ui] usage
# and ends with `kit_dispatch "$@"`. configure is offered only if do_configure exists.
#
# Custom actions: any other subcommand <op> routes to the function do_<op> if the script
# defines it (hyphens in <op> map to underscores, so `default-shell` -> do_default_shell).
# This lets a script advertise extra actions in its `meta` ops= line and have the bootstrap
# TUI / swkit drive them, without changing this library per script.
#
# `ui` is an ENTRY MODE (like meta/status/help), NOT an op — it never appears in meta ops=.
# It opens the script's interactive management screen: the script's own ui() when defined,
# else a menu synthesized from meta ops (ui_default_menu). With no terminal (the LLM's
# non-interactive shell) it prints how to drive the script by explicit op instead, and
# exits 0 — the programmatic op interface is unchanged and always available.
kit_dispatch() {
  kit_load_lang   # honor the user's persisted interface language even when run directly
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    meta)      meta ;;
    status)    status ;;
    install)   do_install "$@" ;;
    remove)    do_remove "$@" ;;
    configure)
      if declare -F do_configure >/dev/null 2>&1; then
        do_configure "$@"
      else
        log_err "This software does not support 'configure'."
        return 2
      fi
      ;;
    ui)
      if kit_have_tty; then
        if declare -F ui >/dev/null 2>&1; then ui "$@"; else ui_default_menu; fi
      else
        local _uikey
        _uikey="$(meta 2>/dev/null | awk -F= '$1=="key"{sub(/^[^=]*=/,"");print;exit}')"
        [[ -n "$_uikey" ]] || _uikey="${0##*/}"; _uikey="${_uikey%.sh}"
        log_info "$(ui_t no_tty)"
        log_info "$(ui_t use_swkit)"
        log_info "    swkit ${_uikey} install   ·   swkit ${_uikey} status   ·   swkit ${_uikey} help"
      fi
      ;;
    help|-h|--help) usage ;;
    *)
      local fn="do_${cmd//-/_}"
      if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$@"
      else
        log_err "Unknown subcommand: $cmd"
        usage
        return 2
      fi
      ;;
  esac
}

# --- UI primitives -------------------------------------------------------------
# The modern-TUI rendering library, sourced LAST so its kit_have_tty fallback is skipped
# (ours is already defined) and log_*/probes exist for it. bootstrap, swkit and every
# script get one consistent renderer, exactly as they share the safety helpers above.
# shellcheck source=ui.sh
source "$KIT_LIB_DIR/ui.sh"
