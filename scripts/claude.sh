#!/usr/bin/env bash
#
# scripts/claude.sh — install / manage the Claude Code CLI on Ubuntu.
#
# Default channel is Anthropic's official native installer (no Node required); an
# optional --method npm path is offered for users who already run Node >= 18. This
# script NEVER installs or upgrades Node itself, and NEVER runs `sudo npm`.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly _CLAUDE_NPM_PKG="@anthropic-ai/claude-code"
readonly _CLAUDE_MIN_NODE_MAJOR=18

meta() {
  cat <<'META'
key=claude
name=Claude Code CLI
category=ai
ops=install,remove
desc=Anthropic Claude Code CLI (official native installer; npm optional)
META
}

status() { have_cmd claude && claude --version; }

do_install() {
  local method="native"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method)
        method="${2:-}"
        shift 2 || { log_err "--method needs a value (native|npm)."; return 2; }
        ;;
      --method=*) method="${1#--method=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done

  if status >/dev/null 2>&1; then
    log_info "Claude Code CLI already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi

  case "$method" in
    native) _claude_install_native ;;
    npm)    _claude_install_npm ;;
    *) log_err "Unknown --method '$method' (expected: native|npm)."; return 2 ;;
  esac
}

# Official native installer: no Node dependency. Drops the binary in ~/.local/bin.
_claude_install_native() {
  have_cmd curl || apt_install curl ca-certificates
  pkg_installed ca-certificates || apt_install ca-certificates
  log_info "Installing Claude Code CLI via the official native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
  ensure_local_bin_on_path
}

# Optional npm path — only for users who already run a recent Node. We refuse to touch
# Node ourselves, and we never `sudo npm` (npm_global_writable gates on a writable prefix).
_claude_install_npm() {
  local node_major
  if ! have_cmd node || ! have_cmd npm; then
    log_err "Node.js and npm are required for --method npm, but were not found."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  node_major="$(node --version 2>/dev/null)"
  node_major="${node_major#v}"
  node_major="${node_major%%.*}"
  if [[ ! "$node_major" =~ ^[0-9]+$ ]] || (( node_major < _CLAUDE_MIN_NODE_MAJOR )); then
    log_err "Node major version >= ${_CLAUDE_MIN_NODE_MAJOR} is required for --method npm (found: $(node --version 2>/dev/null || echo none))."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  npm_global_writable || return 1
  log_info "Installing $_CLAUDE_NPM_PKG via npm (user-space global)..."
  npm install -g "$_CLAUDE_NPM_PKG"
  ensure_local_bin_on_path
}

# Best-effort removal: never sudo. The official native installer has no documented
# uninstall, so we conservatively remove the npm global (if present) and the dropped
# binary, then tell the user what may remain.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Claude Code CLI is not installed — nothing to remove."
    return 0
  fi

  if have_cmd npm && npm ls -g --depth 0 "$_CLAUDE_NPM_PKG" >/dev/null 2>&1; then
    log_info "Removing $_CLAUDE_NPM_PKG via npm..."
    npm uninstall -g "$_CLAUDE_NPM_PKG" || log_warn "npm uninstall of $_CLAUDE_NPM_PKG failed."
  fi

  if [[ -e "$HOME/.local/bin/claude" ]]; then
    rm -f "$HOME/.local/bin/claude"
  fi

  if have_cmd claude; then
    log_warn "'claude' is still on PATH after removal — it may have been installed by another method or location."
  else
    log_info "Claude Code CLI removed; some data under ~/.config or ~/.local/share may remain — delete it manually for a full cleanup."
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install [--method native|npm]
             Install the Claude Code CLI (idempotent — skips if already present).
             native (default): official installer via https://claude.ai/install.sh
                                — no Node required.
             npm:               npm install -g $_CLAUDE_NPM_PKG (needs Node >= ${_CLAUDE_MIN_NODE_MAJOR};
                                this script never installs Node and never uses sudo npm).
  remove     Best-effort uninstall (npm global and/or ~/.local/bin/claude). Never sudo.
  status     Print 'claude --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
