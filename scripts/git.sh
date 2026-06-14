#!/usr/bin/env bash
#
# scripts/git.sh — install / configure / manage git on Ubuntu (apt).
#
# Beyond install/remove, `configure` sets the global user identity (user.name /
# user.email in ~/.gitconfig). It writes AS THE USER — `git config --global` touches the
# user's own dotfile, never via sudo. With no flags it just reports the current values.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=git
name=git
category=essentials
ops=install,remove,configure
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

# Read the current global identity into _GIT_NAME / _GIT_EMAIL (empty if unset).
_git_read_identity() {
  _GIT_NAME="$(git config --global user.name 2>/dev/null || true)"
  _GIT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
}

# Set the global user identity. Flags: --name "X" / --email "Y" (either or both).
# With no flags it just reports the current values. Idempotent; never sudo — writes the
# user's own ~/.gitconfig. Guard: if git is not installed, log and return 0.
do_configure() {
  if ! status >/dev/null 2>&1; then
    log_info "git is not installed — install it first, then configure the identity."
    return 0
  fi

  local name="" email="" set_name=0 set_email=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)    name="${2:-}"; set_name=1; shift 2 || { log_err "--name needs a value."; return 2; } ;;
      --name=*)  name="${1#--name=}"; set_name=1; shift ;;
      --email)   email="${2:-}"; set_email=1; shift 2 || { log_err "--email needs a value."; return 2; } ;;
      --email=*) email="${1#--email=}"; set_email=1; shift ;;
      *) log_err "Unknown configure option: $1 (use --name \"X\" / --email \"Y\")"; return 2 ;;
    esac
  done

  if (( ! set_name && ! set_email )); then
    _git_read_identity
    log_info "Current global git identity:"
    log_info "  user.name  = ${_GIT_NAME:-<unset>}"
    log_info "  user.email = ${_GIT_EMAIL:-<unset>}"
    log_info "Set it with: $(basename "$0") configure --name \"Your Name\" --email \"you@example.com\""
    return 0
  fi

  if (( set_name )); then
    git config --global user.name "$name"
    log_info "Set global user.name = $name"
  fi
  if (( set_email )); then
    git config --global user.email "$email"
    log_info "Set global user.email = $email"
  fi
}

# --- Interactive management screen (the script's own UI) -----------------------
# A bespoke full-screen panel: install (when missing) / set identity + uninstall (when
# installed). State is read live each pass; every change shells out via ui_run (so output
# is visible and logged) and then the screen reloads. Limited terminals fall back to the
# synthesized op menu. `ui` is an entry mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" cur_name="" cur_email=""
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(git --version 2>/dev/null | awk '{print $3}')"
      _git_read_identity
      cur_name="$_GIT_NAME"; cur_email="$_GIT_EMAIL"
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) git")
    else
      dkind+=(header);  did+=("");       dlabel+=("Identity")
      dkind+=(status);  did+=("");       dlabel+=("$(printf '%-13s %s' 'user.name'  "${UI_INFO}${cur_name:-<unset>}${UI_OFF}")")
      dkind+=(status);  did+=("");       dlabel+=("$(printf '%-13s %s' 'user.email' "${UI_INFO}${cur_email:-<unset>}${UI_OFF}")")
      dkind+=(spacer);  did+=("");       dlabel+=("")
      dkind+=(identity); did+=(identity); dlabel+=("$(ui_badge check) Set identity (name + email)  $UI_ARROW")
      dkind+=(spacer);  did+=("");       dlabel+=("")
      dkind+=(remove);  did+=(remove);   dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) git")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "git" "v$ver $(ui_badge installed) $(ui_t installed)"
    else ui_header "git" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "↑↓ move   ↵/space select   esc/q close"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) git" -- "$0" install ;;
          remove)  ui_confirm "Uninstall git? (apt remove — your config is kept)" n && ui_run "$(ui_t remove) git" -- "$0" remove ;;
          identity)
            local new_name="" new_email=""
            ui_input "user.name"  "$cur_name"  && new_name="$UI_INPUT"
            ui_input "user.email" "$cur_email" && new_email="$UI_INPUT"
            local -a cargs=()
            [[ -n "$new_name" ]]  && cargs+=(--name "$new_name")
            [[ -n "$new_email" ]] && cargs+=(--email "$new_email")
            if (( ${#cargs[@]} > 0 )); then
              ui_run "configure · git" -- "$0" configure "${cargs[@]}"
            fi ;;
        esac ;;
      q|Q|esc|backspace) break ;;
    esac
  done
  ui_end
  return 0
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install            Install git via apt (idempotent)
  remove             Uninstall git (apt remove — keeps your config)
  configure [opts]   Set the global git identity (~/.gitconfig; never sudo). Options:
                       --name "Your Name"          set user.name
                       --email "you@example.com"   set user.email
                     With no flags, reports the current user.name / user.email.
  ui                 Open the interactive manager (needs a terminal)
  status             Print 'git --version'; exit 0 iff installed
  meta               Print machine-readable metadata
  help               Show this help
EOF
}

kit_dispatch "$@"
