#!/usr/bin/env bash
#
# scripts/vscode.sh — install / manage Visual Studio Code on Ubuntu.
#
# Channel priority (highest that works wins; the chosen one is logged):
#   1. Microsoft's official apt repo (packages.microsoft.com/repos/code) — the canonical
#      route; `code` then updates with the rest of the system through apt. The signing key
#      goes to /etc/apt/keyrings with a signed-by= reference (NEVER apt-key), exactly as the
#      kit's vendor-apt contract (add_apt_keyring / add_apt_source) prescribes.
#   2. snap (`snap install code --classic`) — the lower-priority fallback when the apt repo
#      cannot be set up (no curl/gpg, offline mirror, etc.).
#
# Honesty note: VS Code is a desktop GUI app. Over SSH / on a headless server it is normally
# used through Remote-SSH or `code tunnel` (the editor window runs on a machine with a
# display); install still configures everything and says so when it detects an SSH session.
#
# Run it as:  vscode.sh install|remove|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# Microsoft's apt repo coordinates. The keyring filename must match the source's signed-by=.
readonly VSCODE_KEY_URL="https://packages.microsoft.com/keys/microsoft.asc"
readonly VSCODE_KEYRING="packages.microsoft"
readonly VSCODE_REPO_LINE="deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "VS Code" and the
# package name "code" stay UNtranslated; only descriptive wording is localized. Resolve a
# row with _vscode_t KEY (fallback en -> the key itself, just like ui_t).
declare -gA VSCODE_I18N
VSCODE_I18N[en:confirm_remove]="Uninstall Visual Studio Code? (apt/snap remove — keeps your settings)"
VSCODE_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
VSCODE_I18N[en:foot_remove]="↑↓ move   ↵/space uninstall   esc/q close"
VSCODE_I18N[en:ssh_note]="VS Code is a desktop GUI app — over SSH use Remote-SSH or 'code tunnel' (the window runs where there is a display)."
VSCODE_I18N[zh:confirm_remove]="卸载 Visual Studio Code?(apt/snap remove — 保留你的设置)"
VSCODE_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
VSCODE_I18N[zh:foot_remove]="↑↓ 移动   ↵/space 卸载   esc/q 关闭"
VSCODE_I18N[zh:ssh_note]="VS Code 是桌面 GUI 应用 — SSH 下请用 Remote-SSH 或 'code tunnel'(窗口运行在有显示器的机器上)。"
VSCODE_I18N[ja:confirm_remove]="Visual Studio Code をアンインストールしますか?(apt/snap remove — 設定は保持)"
VSCODE_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
VSCODE_I18N[ja:foot_remove]="↑↓ 移動   ↵/space アンインストール   esc/q 閉じる"
VSCODE_I18N[ja:ssh_note]="VS Code はデスクトップ GUI アプリです — SSH では Remote-SSH か 'code tunnel' を使用してください(ウィンドウはディスプレイのある環境で動作します)。"

# _vscode_t KEY — localized VS Code string for $UI_LANG (en/zh/ja), fallback en -> key.
_vscode_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${VSCODE_I18N[$lang:$1]:-${VSCODE_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=vscode
name=VS Code
category=editors
tags=gui desktop-only
desktop_hint=Remote-SSH
ops=install,remove
desc=Visual Studio Code editor (Microsoft apt repo, else snap)
META
}

# Exit 0 iff VS Code is installed (on PATH via apt/snap, or a dpkg-installed package).
status() {
  have_cmd code || pkg_installed code || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, never spawn code
  if have_cmd code; then code --version 2>/dev/null | head -n1; else printf 'code (dpkg: installed)\n'; fi
}

# True iff we are in an SSH/headless session (no local GUI to run VS Code in).
_vscode_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
_vscode_where_note() { _vscode_in_ssh && log_warn "$(_vscode_t ssh_note)"; }

# Configure Microsoft's apt repo (keyring + source list). Idempotent — re-installing the key
# and re-writing the .list converge. Returns non-zero if the key/source can't be set up.
_vscode_setup_repo() {
  add_apt_keyring "$VSCODE_KEYRING" "$VSCODE_KEY_URL" || return 1
  add_apt_source vscode "$VSCODE_REPO_LINE" || return 1
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "VS Code is already installed ($(status 2>/dev/null | head -n1)) — skipping."
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates

  # 1. Microsoft's official apt repo.
  if _vscode_setup_repo; then
    log_info "Channel: Microsoft apt repo (packages.microsoft.com/repos/code)."
    # The freshly-added repo is not in apt's lists yet; clear the once-per-process update
    # sentinel so the next apt_install refreshes the lists and can see the `code` package.
    _KIT_APT_UPDATED=""
    if apt_install code; then
      log_info "Installed VS Code from the Microsoft apt repo — it will update with 'apt upgrade'."
      _vscode_where_note
      return 0
    fi
    log_warn "Install from the Microsoft apt repo failed — trying snap."
  else
    log_warn "Could not set up the Microsoft apt repo — trying snap."
  fi

  # 2. snap (classic confinement) — lower-priority fallback.
  if have_cmd snap; then
    log_info "Channel: snap (classic confinement)."
    sudo_run snap install code --classic
    _vscode_where_note
    return 0
  fi

  log_err "Could not install VS Code: the Microsoft apt repo could not be used and snap is"
  log_err "unavailable here. See https://code.visualstudio.com/docs/setup/linux for options."
  return 1
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "VS Code is not installed — nothing to remove."
    return 0
  fi
  if pkg_installed code; then
    apt_remove code
    log_info "Removed the VS Code package (apt remove keeps your ~/.config/Code settings)."
  elif have_cmd snap && snap list code >/dev/null 2>&1; then
    sudo_run snap remove code
    log_info "Removed the VS Code snap (your ~/.config/Code settings are kept)."
  else
    log_warn "VS Code is on PATH but not managed by dpkg or snap; remove it the way you"
    log_warn "installed it. Your settings under ~/.config/Code are left untouched."
    return 1
  fi
}

# --- Interactive management screen (the script's own UI) -----------------------
# A small bespoke full-screen panel: a header showing whether VS Code is installed (with the
# version on the right), and a single action — Install when missing, Uninstall when present
# (confirmed first). State is read live each pass; the only change shells out via ui_run (so
# apt/sudo output is visible and logged) and then the screen reloads. Limited terminals fall
# back to the synthesized op menu. `ui` is an entry mode (kit_dispatch) — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null | head -n1)"; fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) VS Code")
    else
      dkind+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) VS Code")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "VS Code" "$ver $(ui_badge installed)"
    else ui_header "VS Code" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do ui_row "$row" "$i" "$sel" "${dlabel[$i]}"; (( row++ )); done
    if (( installed )); then ui_footer "$(_vscode_t foot_remove)"
    else ui_footer "$(_vscode_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) VS Code" -- "$0" install ;;
          remove)  ui_confirm "$(_vscode_t confirm_remove)" n && ui_run "$(ui_t remove) VS Code" -- "$0" remove ;;
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
  install    Install VS Code (Microsoft apt repo; falls back to snap). Idempotent.
  remove     Uninstall VS Code (apt/snap remove — keeps your ~/.config/Code settings)
  status     Print the version if installed; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
