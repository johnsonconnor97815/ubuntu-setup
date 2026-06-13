#!/usr/bin/env bash
#
# scripts/curl.sh — install / manage curl on Ubuntu (apt).

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=curl
name=curl
category=essentials
ops=install,remove
desc=Command-line HTTP client and TLS CA certificates (apt)
META
}

status() { have_cmd curl && curl --version | head -n1; }

do_install() {
  if status >/dev/null 2>&1; then
    log_info "curl already installed ($(curl --version 2>/dev/null | head -n1)) — skipping."
    return 0
  fi
  # Install ca-certificates alongside curl so https requests work out of the box.
  apt_install curl ca-certificates
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "curl is not installed — nothing to remove."
    return 0
  fi
  # Remove only curl; ca-certificates is shared TLS trust other software needs.
  apt_remove curl
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install curl + ca-certificates via apt (idempotent)
  remove     Uninstall curl (apt remove — keeps ca-certificates)
  status     Print 'curl --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
