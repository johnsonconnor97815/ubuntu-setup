#!/usr/bin/env bash
# Manage the native-architecture cursor library used by Qt's xcb plugin (including IDA).
set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=libxcb-cursor0
name=Qt xcb cursor library
category=essentials
ops=install,remove,plan
desc=libxcb-cursor0 runtime dependency for Qt xcb applications such as IDA (apt)
META
}

_cursor_environment() {
  local ID=""
  # shellcheck source=/dev/null
  source /etc/os-release
  case "$ID" in ubuntu|debian) ;; *) log_err "Only Ubuntu and Debian are supported."; return 1 ;; esac
  have_cmd apt-get && have_cmd apt-cache && have_cmd dpkg-query
}

_cursor_package() {
  local arch; arch="$(dpkg --print-architecture)" || return
  printf 'libxcb-cursor0:%s\n' "$arch"
}

status() {
  local package; package="$(_cursor_package)"
  pkg_installed "$package" || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  dpkg-query -W -f='${binary:Package} ${Version} (apt; package installed, application startup not checked)\n' "$package"
}

do_plan() {
  local action="${1:-install}" package candidate plan operation changed rest rc
  case "$action" in install|remove) ;; *) log_err "Usage: plan [install|remove]"; return 2 ;; esac
  _cursor_environment || return
  package="$(_cursor_package)"
  log_info "Read-only preview: cached /var/lib/apt/lists metadata; last successful refresh is unverified."
  LC_ALL=C apt-cache policy "$package" || return
  if [[ "$action" == install ]]; then
    candidate="$(LC_ALL=C apt-cache policy "$package" | awk '/Candidate:/ && !seen++ {print $2}')" || return
    if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
      log_err "No candidate for $package; check configured distribution sources."
      return 1
    fi
    _CURSOR_TARGET="$package=$candidate"
    plan="$(apt_plan install --no-remove "$_CURSOR_TARGET")" || { rc=$?; printf '%s\n' "$plan"; return "$rc"; }
  else
    plan="$(apt_plan remove "$package")" || { rc=$?; printf '%s\n' "$plan"; return "$rc"; }
  fi
  printf '%s\n' "$plan"
  # This small dependency repair must not upgrade/downgrade installed software or
  # remove dependent packages. New dependencies are allowed and shown in the plan.
  while read -r operation changed rest; do
    case "$operation" in
      Inst)
        if [[ "$action" == remove || "$rest" == \[* ]]; then
          log_err "Refusing a plan that changes installed software: $changed $rest"
          return 1
        fi
        ;;
      Remv)
        if [[ "$action" == install || ( "$changed" != libxcb-cursor0 && "$changed" != "$package" ) ]]; then
          log_err "Refusing a plan that removes another package: $changed"
          return 1
        fi
        ;;
    esac
  done <<<"$plan"
}

do_install() {
  _cursor_environment || return
  if status; then log_info "Already installed; skipping."; return 0; fi
  apt_update_once || return
  do_plan install || return
  apt_install --no-remove "$_CURSOR_TARGET" || return
  status
}

do_remove() {
  _cursor_environment || return
  if ! status >/dev/null 2>&1; then log_info "Not installed; nothing to remove."; return 0; fi
  do_plan remove || return
  log_warn "Manual applications such as IDA may need this library even without package dependencies."
  apt_remove "$(_cursor_package)" || return
  if pkg_installed "$(_cursor_package)"; then log_err "Package is still installed."; return 1; fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>
  plan [install|remove]  Preview cached dependencies without sudo or index refresh
  install               Refresh indexes, check the plan, install via apt; skip if installed
  remove                Remove only this package; refuse removal of dependent packages
  status                Print native package version; does not verify IDA or any GUI
  meta / help / ui      Metadata, help, or the standard interactive manager

Scope: Ubuntu/Debian native package only. No IDA install, license, Qt settings or files
are changed. Install blocks upgrades/downgrades and removals; remove keeps configuration
and never autoremove/purge. Reinstall with 'install' to recover after removal; the old
version may no longer be available. Confirm application startup separately.
EOF
}

kit_dispatch "$@"
