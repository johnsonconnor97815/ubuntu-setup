#!/usr/bin/env bash
#
# scripts/python.sh — install / manage a Python development environment on Ubuntu (apt).
#
# Ubuntu already ships the `python3` interpreter (the system depends on it), so this script
# does NOT manage python3 itself. What it manages is the *development environment* layered on
# top: pip (python3-pip), virtual environments (python3-venv) and the C headers needed to
# build wheels with native extensions (python3-dev). "Installed", for this script, means that
# layer is present — install adds it, remove takes it away while LEAVING python3 in place.
#
# Like scripts/node.sh / scripts/go.sh it uses Ubuntu's own apt packages; pyenv / uv / a newer
# interpreter are taste decisions left to a future change to this script (or the skill).
#
# Run it as:  python.sh install|remove|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# The apt packages that make up the managed dev environment (python3 itself is part of the
# base system and is deliberately NOT removed). python3 is listed for install only.
readonly PY_ENV_PKGS=(python3-pip python3-venv python3-dev)

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The language name "Python" and the
# commands python3/pip stay UNtranslated; only descriptive wording is localized.
declare -gA PY_I18N
PY_I18N[en:confirm_remove]="Remove the Python dev environment (pip/venv/dev)? python3 itself is kept."
PY_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
PY_I18N[en:foot_remove]="↑↓ move   ↵/space uninstall   esc/q close"
PY_I18N[zh:confirm_remove]="移除 Python 开发环境(pip/venv/dev)?python3 本身保留。"
PY_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
PY_I18N[zh:foot_remove]="↑↓ 移动   ↵/space 卸载   esc/q 关闭"
PY_I18N[ja:confirm_remove]="Python 開発環境(pip/venv/dev)を削除しますか?python3 本体は保持されます。"
PY_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
PY_I18N[ja:foot_remove]="↑↓ 移動   ↵/space アンインストール   esc/q 閉じる"

# _py_t KEY — localized Python string for $UI_LANG (en/zh/ja), fallback en -> key.
_py_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${PY_I18N[$lang:$1]:-${PY_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=python
name=Python
category=runtime
ops=install,remove
desc=Python development environment (pip + venv + dev headers) from apt
META
}

# Exit 0 iff the dev environment is present: python3 on PATH AND pip usable. (python3 alone is
# always present on Ubuntu; pip is the signal that this script's layer is installed.)
status() {
  have_cmd python3 || return 1
  python3 -m pip --version >/dev/null 2>&1 || return 1
  printf 'python %s / pip %s\n' \
    "$(python3 --version 2>&1 | awk '{print $2}')" \
    "$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Python dev environment already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi
  # python3 is part of the base system; listing it is a harmless, explicit no-op if present.
  apt_install python3 "${PY_ENV_PKGS[@]}"
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Python dev environment is not installed — nothing to remove."
    return 0
  fi
  # Remove ONLY the dev-environment packages — never python3, which the system depends on.
  apt_remove "${PY_ENV_PKGS[@]}"
  log_info "Removed pip/venv/dev. python3 itself is part of the base system and was kept."
}

# --- Interactive management screen (the script's own UI) -----------------------
# A small bespoke full-screen panel: a header showing whether the dev environment is present
# (python/pip versions on the rows), and a single action — Install when missing, Uninstall
# when present (confirmed first). State is read live each pass; the only change shells out via
# ui_run (so apt/sudo output is visible and logged) and then the screen reloads. Non-selectable
# rows (version lines, spacer) are skipped during navigation. Limited terminals fall back to
# the synthesized op menu. `ui` is an entry mode (kit_dispatch) — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 pyver="" pipver=""
    if status >/dev/null 2>&1; then
      installed=1
      pyver="$(python3 --version 2>&1 | awk '{print $2}')"
      pipver="$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
    fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Python dev environment")
    else
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'python3' "${UI_INFO}${pyver}${UI_OFF}")")
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'pip'     "${UI_INFO}${pipver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Python dev environment")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Python" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Python" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_py_t foot_remove)"
    else ui_footer "$(_py_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Python" -- "$0" install ;;
          remove)  ui_confirm "$(_py_t confirm_remove)" n && ui_run "$(ui_t remove) Python" -- "$0" remove ;;
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
  install    Install the Python dev environment via apt (pip + venv + dev headers). Idempotent.
  remove     Remove pip/venv/dev (apt remove — python3 itself is kept)
  status     Print 'python <ver> / pip <ver>'; exit code 0 iff the dev environment is present
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
