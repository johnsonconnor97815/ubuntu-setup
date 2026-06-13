#!/usr/bin/env bash
#
# scripts/node.sh — install / manage Node.js + npm on Ubuntu (apt).
#
# This installs the Node.js shipped in Ubuntu's own apt repos — an explicit opt-in
# runtime. It intentionally does NOT add a NodeSource (or any vendor) apt repo: picking
# a newer channel is a taste/version decision left to a future LLM-authored evolution.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=node
name=Node.js + npm (apt)
category=runtime
ops=install,remove
desc=Node.js runtime and npm from Ubuntu's apt repos
META
}

# Both must be present to count as installed.
status() {
  have_cmd node && have_cmd npm \
    && printf 'node %s / npm %s\n' "$(node --version)" "$(npm --version)"
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Node.js + npm already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install nodejs npm
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Node.js + npm is not installed — nothing to remove."
    return 0
  fi
  apt_remove nodejs npm
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install Node.js + npm via apt (idempotent)
  remove     Uninstall Node.js + npm (apt remove — keeps your config)
  status     Print 'node <ver> / npm <ver>'; exit 0 iff both installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
