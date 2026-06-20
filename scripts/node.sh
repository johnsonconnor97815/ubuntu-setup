#!/usr/bin/env bash
#
# scripts/node.sh — install / manage Node.js + npm on Ubuntu (apt).
#
# This installs the Node.js shipped in Ubuntu's own apt repos — an explicit opt-in
# runtime. It intentionally does NOT add a NodeSource (or any vendor) apt repo: picking
# a newer channel is a taste/version decision left to a future change to this script in the repo.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The command names node/npm stay
# UNtranslated; only descriptive wording is localized. Resolve with _node_t KEY.
declare -gA NODE_I18N
NODE_I18N[en:confirm_remove]="Uninstall Node.js + npm?"
NODE_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
NODE_I18N[en:foot_remove]="↑↓ move   ↵/space uninstall   esc/q close"
NODE_I18N[zh:confirm_remove]="卸载 Node.js + npm?"
NODE_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
NODE_I18N[zh:foot_remove]="↑↓ 移动   ↵/space 卸载   esc/q 关闭"
NODE_I18N[ja:confirm_remove]="Node.js + npm をアンインストールしますか?"
NODE_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
NODE_I18N[ja:foot_remove]="↑↓ 移動   ↵/space アンインストール   esc/q 閉じる"

# _node_t KEY — localized Node string for $UI_LANG (en/zh/ja), fallback en -> key.
_node_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${NODE_I18N[$lang:$1]:-${NODE_I18N[en:$1]:-$1}}"
}

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
  have_cmd node && have_cmd npm || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip version spawns
  printf 'node %s / npm %s\n' "$(node --version)" "$(npm --version)"
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

# --- Interactive management screen (the script's own UI) -----------------------
# A small bespoke full-screen panel: a header showing whether Node.js + npm are
# installed (with versions on the right), and a single action — Install when missing,
# Uninstall when present (confirmed first). State is read live each pass; the only
# change shells out via ui_run (so apt/sudo output is visible and logged) and then the
# screen reloads. Limited terminals fall back to the synthesized op menu. `ui` is an
# entry mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 nver="" pver=""
    if status >/dev/null 2>&1; then
      installed=1
      nver="$(node --version 2>/dev/null || true)"
      pver="$(npm --version 2>/dev/null || true)"
    fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Node.js + npm")
    else
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'node' "${UI_INFO}${nver}${UI_OFF}")")
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'npm'  "${UI_INFO}${pver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Node.js + npm")
    fi
    local n=${#dkind[@]} g
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Node.js + npm" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Node.js + npm" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_node_t foot_remove)"
    else ui_footer "$(_node_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Node.js + npm" -- "$0" install ;;
          remove)  ui_confirm "$(_node_t confirm_remove)" n && ui_run "$(ui_t remove) Node.js + npm" -- "$0" remove ;;
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
  install    Install Node.js + npm via apt (idempotent)
  remove     Uninstall Node.js + npm (apt remove — keeps your config)
  status     Print 'node <ver> / npm <ver>'; exit 0 iff both installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
