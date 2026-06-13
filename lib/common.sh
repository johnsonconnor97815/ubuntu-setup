#!/usr/bin/env bash
#
# lib/common.sh — shared safety primitives for the ubuntu-setup script collection.
#
# This library is the "safety contract as code". Every script in scripts/ sources it
# and composes its helpers, so the project's non-negotiables — idempotency probes,
# per-command sudo (never whole-root), non-interactive apt, channel-conservative repo
# setup, back-up-before-edit — are implemented ONCE here and inherited by every script,
# including ones the LLM authors later. Authoring a conformant script is mostly a matter
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
    log_err "    npm config set prefix \"\$HOME/.local\""
    return 1
  fi
  return 0
}

# --- Script skeleton -----------------------------------------------------------

# Print one "KEY=VALUE" metadata line (a convenience for meta functions).
emit_meta_line() { printf '%s=%s\n' "$1" "$2"; }

# Route a script's subcommand to its convention functions. A script defines
#   meta status do_install do_remove [do_configure] usage
# and ends with `kit_dispatch "$@"`. configure is offered only if do_configure exists.
kit_dispatch() {
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
    help|-h|--help) usage ;;
    *) log_err "Unknown subcommand: $cmd"; usage; return 2 ;;
  esac
}
