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

# --- Interactive management screen (the script's own UI) -----------------------
# A small bespoke full-screen manager: a status header (installed badge + version) over a
# short action list (Install when missing, Uninstall when present). State is read live each
# pass; every change shells out via ui_run (so apt/sudo output is visible and logged) and the
# screen reloads. Limited terminals fall back to the synthesized op menu. `ui` is an entry
# mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then
      installed=1
      # Just "curl X.Y.Z" — the full --version line lists every protocol/library and would
      # overflow the panel and wrap into the action rows below.
      ver="$(curl --version 2>/dev/null | awk 'NR==1{print $1, $2}')"
    fi

    # ---- build action rows (parallel arrays: id / label) ----
    local -a did=() dlabel=()
    if (( ! installed )); then
      did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) curl — HTTP client + CA certs")
    else
      did+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) curl")
    fi
    local n=${#did[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "curl" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "curl" "$(ui_badge missing) $(ui_t not_installed)"; fi
    if (( installed )); then
      ui_move 3 2; printf '%s%s%s' "$UI_MUTED" "$ver" "$UI_OFF" >&"$_UI_FD"
    else
      ui_move 3 2; printf '%s%s%s' "$UI_MUTED" "Command-line HTTP client and TLS CA certificates." "$UI_OFF" >&"$_UI_FD"
    fi
    local i row=5
    for (( i=0; i<n; i++ )); do
      ui_row "$row" "$i" "$sel" "${dlabel[$i]}"
      (( row++ ))
    done
    ui_footer "↑↓ move   ↵ select   q quit"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do (( sel=(sel-1+n)%n )); done ;;
      down|j) for (( g=0; g<n; g++ )); do (( sel=(sel+1)%n ));   done ;;
      enter|right|l|space)
        case "${did[$sel]}" in
          install) ui_run "$(ui_t install) curl" -- "$0" install ;;
          remove)  ui_confirm "Uninstall curl? (ca-certificates is kept)" n && ui_run "$(ui_t remove) curl" -- "$0" remove ;;
        esac ;;
      q|esc) break ;;
    esac
  done
  ui_end
  return 0
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install curl + ca-certificates via apt (idempotent)
  remove     Uninstall curl (apt remove — keeps ca-certificates)
  status     Print 'curl --version'; exit 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
