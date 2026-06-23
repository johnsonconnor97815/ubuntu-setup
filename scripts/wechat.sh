#!/usr/bin/env bash
#
# scripts/wechat.sh — install / update / manage WeChat (Tencent's official Linux client) on Ubuntu.
#
# WeChat (https://linux.weixin.qq.com/) is Tencent's first-party native Linux client (an Electron
# desktop app). It is NOT in any apt repo; its official Linux distribution is a direct-download .deb
# (plus rpm / AppImage) served from Tencent's CDN at a STABLE, version-agnostic URL that always
# points at the latest stable build:
#   x86_64  https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_x86_64.deb
#   arm64   https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux_arm64.deb
# (Tencent also ships a LoongArch .deb plus rpm / AppImage; this kit targets Ubuntu/Debian on
# amd64/arm64, so on any other arch it refuses with guidance to the official site rather than
# guessing a token.) This script installs the official .deb THROUGH apt so dependencies resolve and removal is a clean
# `apt remove wechat` — the kit's "vendor .deb" channel (the same approach scripts/cursor.sh and
# scripts/obsidian.sh use). There is no apt repo to pull upgrades from and no official snap, so on an
# unsupported arch it refuses with guidance to the official site (AppImage / rpm).
#
# Update model: the download URL is version-agnostic (always the latest), and apt has no repo to
# upgrade from, so the script adds an `update` action: re-download the .deb and install it over the
# current one (apt upgrades in place if it is newer).
#
# Honesty note: WeChat is a desktop GUI app. Over SSH / on a headless server there is no local
# display to run it; install still places the package and says so when it detects an SSH session.
#
# Run it as:  wechat.sh install|remove|update|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# Tencent CDN base for the official Linux .deb. The full URL is "${WECHAT_DEB_BASE}_<token>.deb"
# where <token> is the per-arch token from _wechat_arch_token (x86_64 / arm64).
readonly WECHAT_DEB_BASE="https://dldir1v6.qq.com/weixin/Universal/Linux/WeChatLinux"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "WeChat" and the package name
# "wechat" stay UNtranslated (project rule: names are not translated); only descriptive wording is
# localized. Resolve a row with _wechat_t KEY (fallback en -> the key itself, just like ui_t).
declare -gA WECHAT_I18N
WECHAT_I18N[en:update_row]="Update to the latest WeChat"
WECHAT_I18N[en:confirm_remove]="Uninstall WeChat? (apt remove — keeps your WeChat data in your home directory)"
WECHAT_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
WECHAT_I18N[en:foot_manage]="↑↓ move   ↵/space select   esc/q close"
WECHAT_I18N[en:ssh_note]="WeChat is a desktop GUI app — over SSH the window runs where there is a display (forward X11/Wayland or run it locally)."
WECHAT_I18N[zh:update_row]="更新到最新版 WeChat"
WECHAT_I18N[zh:confirm_remove]="卸载 WeChat?(apt remove — 保留你 home 目录下的 WeChat 数据)"
WECHAT_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
WECHAT_I18N[zh:foot_manage]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
WECHAT_I18N[zh:ssh_note]="WeChat 是桌面 GUI 应用 — SSH 下窗口运行在有显示器的机器上(转发 X11/Wayland 或在本地运行)。"
WECHAT_I18N[ja:update_row]="最新の WeChat に更新"
WECHAT_I18N[ja:confirm_remove]="WeChat をアンインストールしますか?(apt remove — ホーム配下の WeChat データは保持)"
WECHAT_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
WECHAT_I18N[ja:foot_manage]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"
WECHAT_I18N[ja:ssh_note]="WeChat はデスクトップ GUI アプリです — SSH ではディスプレイのある環境でウィンドウが動作します(X11/Wayland 転送かローカル実行)。"

# _wechat_t KEY — localized WeChat string for $UI_LANG (en/zh/ja), fallback en -> key.
_wechat_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${WECHAT_I18N[$lang:$1]:-${WECHAT_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=wechat
name=WeChat
category=common
ops=install,remove,update
desc=WeChat — Tencent's official Linux client (official .deb; 'update' fetches the latest)
META
}

# Exit 0 iff WeChat is installed (via dpkg, or otherwise on PATH). Detection is cheap and never
# launches the GUI. Under KIT_PROBE_ONLY (catalog cache) return the install boolean BEFORE any
# version spawn — both paths return the same exit code. Print the version for the detail view.
status() {
  local via=""
  if pkg_installed wechat; then
    via=deb
  elif have_cmd wechat; then
    via=path
  else
    return 1
  fi
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  case "$via" in
    deb)
      local v; v="$(dpkg-query -W -f='${Version}' wechat 2>/dev/null || true)"
      printf 'wechat %s\n' "${v:-installed}" ;;
    path)
      printf 'wechat (installed, not via dpkg)\n' ;;
  esac
  return 0
}

# True iff we are in an SSH/headless session (no local display to run WeChat).
_wechat_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
# Emit the SSH caveat only when relevant. MUST use the `if` form (not a bare `_wechat_in_ssh &&
# log_warn …`) wherever it is the LAST command of do_install/_wechat_post_install/do_update: the
# bare-&& form would leak _wechat_in_ssh's FALSE (non-SSH) status up through `set -e` and make a
# fully successful local install report exit 1 (cursor.sh:82-86 documents this exact bug).
_wechat_where_note() { if _wechat_in_ssh; then log_warn "$(_wechat_t ssh_note)"; fi; }

# Map dpkg architecture -> WeChat download-URL arch token. Non-zero on an unsupported arch.
_wechat_arch_token() {
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) printf 'x86_64' ;;
    arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}

# Download the official .deb for this arch and install it via apt (resolves deps, non-interactive,
# escalates per command). apt treats a path with a slash as a local file. Used by install + update.
# Refuses (with guidance) on an unsupported arch. The WeChat .deb is large (~hundreds of MB), so the
# curl flags bound only the connect phase and a genuine STALL, never total elapsed time.
_wechat_install_deb() {
  local token url
  if ! token="$(_wechat_arch_token)"; then
    log_err "This kit installs the official WeChat .deb for amd64/arm64 only (this host is $(dpkg --print-architecture 2>/dev/null || uname -m))."
    log_err "See https://linux.weixin.qq.com/ for the LoongArch .deb / rpm / AppImage options."
    return 1
  fi
  url="${WECHAT_DEB_BASE}_${token}.deb"
  have_cmd curl || apt_install curl ca-certificates
  log_info "Channel: official WeChat .deb (${token}, always the latest stable)."
  log_info "Downloading: $url"
  local tmp deb rc=0
  tmp="$(mktemp -d)"
  deb="$tmp/wechat.deb"
  # Bound only the connect phase and a genuine STALL — NOT total elapsed time: a wall-clock cap
  # (--max-time) aborts a slow-but-still-progressing transfer, and WeChat's .deb is large. The
  # --speed-time/--speed-limit pair aborts only when real throughput stays under 1 KB/s for 60s;
  # --retry + -C - retry transient drops and resume the partial bytes already on disk. No --max-time.
  if ! curl -fsSL \
        --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$url" -o "$deb"; then
    rm -rf "$tmp"; log_err "Failed to download the WeChat .deb."; return 1
  fi
  apt_install "$deb" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_wechat_post_install() {
  log_info "Installed WeChat ($(status 2>/dev/null | head -n1))."
  log_info "Launch it from your application menu (search 'WeChat'). Update later with: ${0##*/} update"
  _wechat_where_note
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "WeChat is already installed ($(status 2>/dev/null | head -n1)) — to get the latest, run: ${0##*/} update"
    return 0
  fi
  _wechat_install_deb || return 1
  _wechat_post_install
}

# update — re-download the latest official .deb and install it over the current one (apt upgrades in
# place). The URL is version-agnostic, so this always re-downloads — a deliberate, user-invoked
# action rather than part of the idempotent install path. Installs first if WeChat is absent.
do_update() {
  if ! status >/dev/null 2>&1; then
    log_info "WeChat is not installed — installing the latest instead."
    do_install
    return $?
  fi
  if pkg_installed wechat; then
    local cur; cur="$(dpkg-query -W -f='${Version}' wechat 2>/dev/null || true)"
    _wechat_install_deb || return 1
    log_info "WeChat is now $(status 2>/dev/null | head -n1) (was ${cur:-unknown})."
    _wechat_where_note
    return 0
  fi
  log_warn "WeChat is on PATH but not managed by dpkg; update it the way you installed it"
  log_warn "(e.g. re-download the AppImage from https://linux.weixin.qq.com/)."
  return 1
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "WeChat is not installed — nothing to remove."
    return 0
  fi
  if pkg_installed wechat; then
    apt_remove wechat
    log_info "Removed the WeChat package (apt remove keeps your WeChat data under your home directory)."
  else
    log_warn "WeChat is on PATH but not a dpkg package; remove it the way you installed it."
    log_warn "Your WeChat data under your home directory is left untouched."
    return 1
  fi
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live panel: Install when missing; when installed, a version line plus Update and Uninstall
# actions. State is read live each pass; every change shells out via ui_run (visible + logged) and
# the screen reloads. Non-selectable rows (version line, spacer) are skipped during navigation.
# Limited terminals fall back to the synthesized op menu. `ui` is an entry mode (not in meta.ops).
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null | head -n1)"; fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) WeChat")
    else
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'wechat' "${UI_INFO}${ver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(update); dlabel+=("$(ui_badge check) $(_wechat_t update_row)")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) WeChat")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "WeChat" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "WeChat" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_wechat_t foot_manage)"
    else ui_footer "$(_wechat_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) WeChat" -- "$0" install ;;
          update)  ui_run "$(_wechat_t update_row)" -- "$0" update ;;
          remove)  ui_confirm "$(_wechat_t confirm_remove)" n && ui_run "$(ui_t remove) WeChat" -- "$0" remove ;;
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
  install    Install WeChat from the official .deb (via apt). Idempotent.
  update     Re-fetch the latest .deb and install it over the current version
  remove     Uninstall WeChat (apt remove — keeps your WeChat data under your home)
  status     Print the package version if installed; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
