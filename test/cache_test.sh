#!/usr/bin/env bash
# test/cache_test.sh — behavior assertions for lib/cache.sh. Dev-only, not deployed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Isolated cache dir so we never touch the user's real cache.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"; unset SUDO_USER
# shellcheck source=/dev/null
source "$HERE/lib/common.sh"

fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }

S="$HERE/scripts/git.sh"   # cheap, always present

# meta cache: first call probes + writes, second is mtime-valid read
m1="$(kit_meta_cached "$S")"
[[ "$m1" == *"key=git"* ]] && ok "meta has key=git" || bad "meta missing key=git"
[[ -f "$(kit_cache_dir)/git.meta" ]] && ok ".meta written" || bad ".meta not written"
grep -q '^script_mtime=' "$(kit_cache_dir)/git.meta" && ok "meta carries script_mtime" || bad "meta missing script_mtime"
m2="$(kit_meta_cached "$S")"
[[ "$m1" == "$m2" ]] && ok "meta stable across calls" || bad "meta differs across calls"
[[ "$m2" != *script_mtime* ]] && ok "meta output strips script_mtime" || bad "meta output leaked script_mtime"

# mtime invalidation: corrupt cache with a stale mtime -> forces a re-probe (real content back)
printf 'script_mtime=0\nkey=STALE\n' >"$(kit_cache_dir)/git.meta"
m3="$(kit_meta_cached "$S")"
[[ "$m3" == *"key=git"* ]] && ok "stale mtime forces re-probe" || bad "stale mtime not re-probed"

# status: probe writes installed + ts; value reads without probing
kit_probe_status "$S" || true
v="$(kit_status_value "$S")"
[[ "$v" == 0 || "$v" == 1 ]] && ok "status value is 0/1 ($v)" || bad "status value not 0/1: '$v'"
[[ -f "$(kit_cache_dir)/git.status" ]] && ok ".status written" || bad ".status not written"
age="$(kit_status_age "$S")"; { [[ "$age" =~ ^[0-9]+$ ]] && (( age < 5 )); } && ok "fresh status age ($age)" || bad "bad status age: $age"

# invalidate drops status, keeps meta
kit_cache_invalidate "$S"
[[ ! -f "$(kit_cache_dir)/git.status" ]] && ok "invalidate removed .status" || bad "invalidate left .status"
[[ -f "$(kit_cache_dir)/git.meta" ]] && ok "invalidate kept .meta" || bad "invalidate removed .meta"
[[ -z "$(kit_status_value "$S")" ]] && ok "value empty after invalidate" || bad "value non-empty after invalidate"

# warm fills the collection
kit_cache_clear
kit_cache_warm "$HERE/scripts"
ls "$(kit_cache_dir)"/*.meta >/dev/null 2>&1 && ok "warm wrote .meta files" || bad "warm wrote no .meta"
ls "$(kit_cache_dir)"/*.status >/dev/null 2>&1 && ok "warm wrote .status files" || bad "warm wrote no .status"

# KIT_NO_CACHE bypass: no files read/written, still returns sane values
kit_cache_clear
KIT_NO_CACHE=1 kit_meta_cached "$S" | grep -q 'key=git' && ok "no-cache meta works" || bad "no-cache meta failed"
[[ ! -f "$(kit_cache_dir)/git.meta" ]] && ok "no-cache wrote nothing" || bad "no-cache wrote a file"
nv="$(KIT_NO_CACHE=1 kit_status_value "$S")"; [[ "$nv" == 0 || "$nv" == 1 ]] && ok "no-cache status value ($nv)" || bad "no-cache status bad: $nv"

exit "$fail"
