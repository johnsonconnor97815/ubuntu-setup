#!/usr/bin/env bash
# Offline regression cases: every package operation is replaced with a shell function.
set -Eeuo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/libxcb-cursor0.sh
source "$TEST_ROOT/scripts/libxcb-cursor0.sh" help >/dev/null

# Test real shared helpers before replacing them. Conditional callers disable bash
# errexit inside functions, so explicit failure propagation is required here.
(
  unset _KIT_APT_UPDATED
  sudo_calls=0
  sudo_run() { sudo_calls=$((sudo_calls + 1)); return 97; }
  rc=0
  apt_update_once || rc=$?
  [[ "$rc" == 97 && -z "${_KIT_APT_UPDATED:-}" && "$sudo_calls" == 1 ]]
  sudo_calls=0 rc=0
  apt_install libxcb-cursor0 || rc=$?
  [[ "$rc" == 97 && -z "${_KIT_APT_UPDATED:-}" && "$sudo_calls" == 1 ]]
)
printf 'ok - real apt helpers preserve update errors for conditional callers\n'

_cursor_environment() { return "${ENV_RC:-0}"; }
dpkg() { printf 'amd64\n'; }
dpkg-query() { printf 'libxcb-cursor0 0.1.4-test\n'; }
pkg_installed() { [[ "$1" == libxcb-cursor0:amd64 && "$INSTALLED" == 1 ]]; }
apt-cache() { printf '  Candidate: %s\n' "$CANDIDATE"; }
apt_update_once() { CALLS+="update "; CANDIDATE="$FRESH_CANDIDATE"; return "$UPDATE_RC"; }
apt_install() { CALLS+="install:$* "; (( INSTALL_RC == 0 )) && INSTALLED=1; return "$INSTALL_RC"; }
apt_remove() { CALLS+="remove:$* "; INSTALLED=0; }
sudo_run() { printf 'Unexpected sudo\n' >&2; return 99; }
# Exercise the real shared apt_plan helper, intercepting only its underlying command.
apt-get() {
  [[ "$1" == --simulate && "$3" == --no-install-recommends ]] || return 99
  printf '%s\n' "$PLAN"
  return "$PLAN_RC"
}

reset_case() {
  INSTALLED=0 CANDIDATE=0.1.4-test FRESH_CANDIDATE=0.1.5-test
  ENV_RC=0 UPDATE_RC=0 INSTALL_RC=0 PLAN_RC=0 CALLS=""
  PLAN='Inst libxcb-cursor0 (0.1.5-test Ubuntu:24.04/noble [amd64])'
}
assert() { if ! "$@"; then printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
expect_rc() {
  local expected="$1" actual=0; shift
  "$@" >/dev/null 2>&1 || actual=$?
  assert test "$actual" -eq "$expected"
}

reset_case
expect_rc 0 do_plan install
assert test "$CALLS" = ""
assert test "$_CURSOR_TARGET" = libxcb-cursor0:amd64=0.1.4-test
printf 'ok - preview is read-only and selects the native candidate\n'

reset_case
expect_rc 0 do_install
assert test "$CALLS" = 'update install:--no-remove libxcb-cursor0:amd64=0.1.5-test '
CALLS=""
expect_rc 0 do_install
assert test "$CALLS" = ""
printf 'ok - install refreshes the candidate; second install changes nothing\n'

reset_case
ENV_RC=1
expect_rc 1 do_install
assert test "$CALLS" = ""
printf 'ok - unsupported environment does not write\n'

reset_case
CANDIDATE='(none)'
expect_rc 1 do_plan install
assert test "$CALLS" = ""
printf 'ok - missing candidate fails safely\n'

reset_case
UPDATE_RC=97
expect_rc 97 do_install
assert test "$CALLS" = 'update '
printf 'ok - sudo handback/index failure stops installation\n'

for conflict in \
  'Inst libc6 [2.38] (2.39 Ubuntu:24.04/noble [amd64])' \
  'Inst libc6 [2.39] (2.38 Ubuntu:24.04/noble [amd64])' \
  'Remv desktop-app [1.0]'; do
  reset_case
  PLAN="$conflict"
  expect_rc 1 do_install
  assert test "$CALLS" = 'update '
done
printf 'ok - refreshed plans cannot upgrade, downgrade, or remove existing packages\n'

reset_case
PLAN_RC=100
expect_rc 100 do_install
assert test "$CALLS" = 'update '
printf 'ok - dependency resolution failure stops installation\n'

reset_case
INSTALL_RC=42
expect_rc 42 do_install
assert test "$INSTALLED" = 0
printf 'ok - package installation errors are preserved\n'

reset_case
INSTALLED=1
PLAN=$'Remv libxcb-cursor0 [0.1.4]\nRemv desktop-app [1.0]'
expect_rc 1 do_remove
assert test "$CALLS" = ""
printf 'ok - removal cannot uninstall dependent packages\n'

reset_case
INSTALLED=1
PLAN='Remv libxcb-cursor0:i386 [0.1.4]'
expect_rc 1 do_remove
assert test "$CALLS" = ""
printf 'ok - removal cannot affect another architecture\n'

reset_case
INSTALLED=1
PLAN='Remv libxcb-cursor0 [0.1.4]'
expect_rc 0 do_remove
assert test "$CALLS" = 'remove:libxcb-cursor0:amd64 '
CALLS=""
expect_rc 0 do_remove
assert test "$CALLS" = ""
printf 'ok - remove targets only the native package; second remove is a no-op\n'

reset_case
expect_rc 1 status
KIT_PROBE_ONLY=1
expect_rc 1 status
INSTALLED=1
expect_rc 0 status
unset KIT_PROBE_ONLY
expect_rc 0 status
printf 'ok - catalog and normal status agree for missing/installed states\n'

reset_case
expect_rc 2 do_plan invalid
expect_rc 2 apt_plan upgrade
assert test "$CALLS" = ""
printf 'ok - invalid operations cannot mutate packages\n'
