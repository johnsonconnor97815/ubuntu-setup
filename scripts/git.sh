#!/usr/bin/env bash
#
# scripts/git.sh — install / manage git on Ubuntu (apt).

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=git
name=git
category=essentials
ops=install,remove
desc=Distributed version control system (apt)
META
}

status() { have_cmd git && git --version; }

do_install() {
  if status >/dev/null 2>&1; then
    log_info "git already installed ($(git --version 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install git
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "git is not installed — nothing to remove."
    return 0
  fi
  apt_remove git
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install git via apt (idempotent)
  remove     Uninstall git (apt remove — keeps your config)
  status     Print 'git --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
