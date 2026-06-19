#!/usr/bin/env bash
#
# scripts/cursor.sh — install / update / manage Cursor (the AI code editor) on Ubuntu.
#
# Cursor (https://cursor.com) is a VS Code-based editor with AI built in. It is NOT in any
# apt repo; its official Linux distribution is a versioned .deb (and an AppImage). This script
# resolves the latest stable .deb from Cursor's download API, then installs it THROUGH apt so
# dependencies resolve and removal is a clean `apt remove cursor` — the kit's "vendor .deb"
# channel (the same approach scripts/ghostty.sh uses for its community .deb).
#
# Because that .deb is a one-shot download (no apt repo to pull upgrades from), the script adds
# an `update` action: re-resolve the latest .deb and install it over the current one.
#
# Honesty note: Cursor is a desktop GUI app. Over SSH / on a headless server there is no local
# display to run it; install still places the package and says so when it detects an SSH session.
#
# Run it as:  cursor.sh install|remove|update|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly CURSOR_API="https://www.cursor.com/api/download"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "Cursor" and the package
# name "cursor" stay UNtranslated; only descriptive wording is localized. Resolve a row with
# _cursor_t KEY (fallback en -> the key itself, just like ui_t).
declare -gA CURSOR_I18N
CURSOR_I18N[en:update_row]="Update to the latest Cursor"
CURSOR_I18N[en:confirm_remove]="Uninstall Cursor? (apt remove — keeps your ~/.config/Cursor)"
CURSOR_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
CURSOR_I18N[en:foot_manage]="↑↓ move   ↵/space select   esc/q close"
CURSOR_I18N[en:ssh_note]="Cursor is a desktop GUI app — over SSH use Remote-SSH or a remote tunnel (the window runs where there is a display)."
CURSOR_I18N[zh:update_row]="更新到最新版 Cursor"
CURSOR_I18N[zh:confirm_remove]="卸载 Cursor?(apt remove — 保留你的 ~/.config/Cursor)"
CURSOR_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
CURSOR_I18N[zh:foot_manage]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
CURSOR_I18N[zh:ssh_note]="Cursor 是桌面 GUI 应用 — SSH 下请用 Remote-SSH 或远程隧道(窗口运行在有显示器的机器上)。"
CURSOR_I18N[ja:update_row]="最新の Cursor に更新"
CURSOR_I18N[ja:confirm_remove]="Cursor をアンインストールしますか?(apt remove — ~/.config/Cursor は保持)"
CURSOR_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
CURSOR_I18N[ja:foot_manage]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"
CURSOR_I18N[ja:ssh_note]="Cursor はデスクトップ GUI アプリです — SSH では Remote-SSH かリモートトンネルを使用してください(ウィンドウはディスプレイのある環境で動作します)。"

# _cursor_t KEY — localized Cursor string for $UI_LANG (en/zh/ja), fallback en -> key.
_cursor_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${CURSOR_I18N[$lang:$1]:-${CURSOR_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=cursor
name=Cursor
category=common
ops=install,remove,update
desc=Cursor — the AI code editor (official .deb; 'update' fetches the latest)
META
}

# Exit 0 iff the Cursor package is installed. Prefer the dpkg probe (instant, never launches
# the GUI); print the package version. Fall back to a PATH check for non-dpkg installs.
status() {
  if pkg_installed cursor; then
    local v; v="$(dpkg-query -W -f='${Version}' cursor 2>/dev/null || true)"
    printf 'cursor %s\n' "${v:-installed}"
    return 0
  fi
  if have_cmd cursor; then
    printf 'cursor (installed, not via dpkg)\n'
    return 0
  fi
  return 1
}

# True iff we are in an SSH/headless session (no local display to run Cursor).
_cursor_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
# Emit the SSH caveat only when relevant. MUST end on a true status: this is the last command of
# _cursor_post_install (and do_update), so a bare `_cursor_in_ssh && log_warn …` would leak the
# false status up through do_install/do_update and make a fully successful install report exit 1
# whenever NOT in SSH (i.e. the normal local-desktop case). The `if` form returns 0 when not SSH.
_cursor_where_note() { if _cursor_in_ssh; then log_warn "$(_cursor_t ssh_note)"; fi; }

# Map dpkg architecture -> Cursor download-API platform token. Non-zero on an unsupported arch.
_cursor_platform() {
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$arch" in
    amd64) printf 'linux-x64' ;;
    arm64) printf 'linux-arm64' ;;
    *) return 1 ;;
  esac
}

# Resolve the latest stable .deb URL + version into _CURSOR_URL / _CURSOR_VER. The API returns
# JSON with a debUrl ending in .deb (the only .deb URL in the payload), so a plain grep is
# robust and needs no jq. Non-zero (with guidance) if the API is unreachable or has no .deb.
_cursor_resolve_deb() {
  local plat json
  if ! plat="$(_cursor_platform)"; then
    log_err "Cursor publishes Linux builds for amd64/arm64 only (this host is $(dpkg --print-architecture 2>/dev/null || uname -m))."
    return 1
  fi
  have_cmd curl || apt_install curl ca-certificates
  log_info "Looking up the latest Cursor release for ${plat}…"
  json="$(curl -fsSL --max-time 30 "${CURSOR_API}?platform=${plat}&releaseTrack=stable" 2>/dev/null || true)"
  [[ -n "$json" ]] || { log_err "Could not reach the Cursor download API ($CURSOR_API)."; return 1; }
  _CURSOR_URL="$(printf '%s' "$json" | grep -oE 'https://[^"]+\.deb' | head -n1 || true)"
  _CURSOR_VER="$(printf '%s' "$json" | grep -oE '"version":"[^"]+"' | head -n1 | cut -d'"' -f4 || true)"
  [[ -n "$_CURSOR_URL" ]] || { log_err "The Cursor download API did not return a .deb URL."; return 1; }
  return 0
}

# Download the resolved .deb and install it via apt (resolves deps, non-interactive, escalates
# per command). apt treats a path with a slash as a local file. Used by both install and update.
_cursor_install_deb() {
  _cursor_resolve_deb || return 1
  log_info "Channel: official Cursor .deb (v${_CURSOR_VER:-unknown})."
  log_info "Downloading: $_CURSOR_URL"
  local tmp deb rc=0
  tmp="$(mktemp -d)"
  deb="$tmp/cursor.deb"
  # Cursor's .deb is large (~200 MB) and downloads.cursor.com can be slow/throttled. Bound only
  # the connect phase and a genuine STALL — NOT total elapsed time: a wall-clock cap (--max-time)
  # aborts a slow-but-still-progressing transfer (this caused install failures when a healthy
  # download simply ran longer than the cap). --speed-time/--speed-limit abort only when real
  # throughput stays under 1 KB/s for 60s; --retry + -C - retry transient drops and resume the
  # partial bytes already on disk (the server advertises Accept-Ranges: bytes). Do NOT add --max-time.
  if ! curl -fsSL \
        --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$_CURSOR_URL" -o "$deb"; then
    rm -rf "$tmp"; log_err "Failed to download the Cursor .deb."; return 1
  fi
  apt_install "$deb" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_cursor_post_install() {
  log_info "Installed Cursor ($(status 2>/dev/null | head -n1))."
  log_info "Launch it from your application menu or 'cursor'. Update later with: ${0##*/} update"
  _cursor_where_note
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Cursor is already installed ($(status 2>/dev/null | head -n1)) — to get the latest, run: ${0##*/} update"
    return 0
  fi
  _cursor_install_deb || return 1
  _cursor_post_install
}

# update — re-resolve the latest stable .deb and install it over the current one (apt upgrades
# in place). It always re-downloads the current .deb, so this is a deliberate, user-invoked
# action rather than part of the idempotent install path. Installs first if Cursor is absent.
do_update() {
  if ! status >/dev/null 2>&1; then
    log_info "Cursor is not installed — installing the latest instead."
    do_install
    return $?
  fi
  local cur; cur="$(dpkg-query -W -f='${Version}' cursor 2>/dev/null || true)"
  _cursor_install_deb || return 1
  log_info "Cursor is now $(status 2>/dev/null | head -n1) (was ${cur:-unknown})."
  _cursor_where_note
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Cursor is not installed — nothing to remove."
    return 0
  fi
  if pkg_installed cursor; then
    apt_remove cursor
    log_info "Removed the Cursor package (apt remove keeps your ~/.config/Cursor)."
  else
    log_warn "Cursor is on PATH but not a dpkg package; remove it the way you installed it."
    log_warn "Your settings under ~/.config/Cursor are left untouched."
    return 1
  fi
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live panel: Install when missing; when installed, a version line plus Update and Uninstall
# actions. State is read live each pass; every change shells out via ui_run (visible + logged)
# and the screen reloads. Non-selectable rows (version line, spacer) are skipped during
# navigation. Limited terminals fall back to the synthesized op menu. `ui` is an entry mode.
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
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Cursor")
    else
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'cursor' "${UI_INFO}${ver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(update); dlabel+=("$(ui_badge check) $(_cursor_t update_row)")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Cursor")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Cursor" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Cursor" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_cursor_t foot_manage)"
    else ui_footer "$(_cursor_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Cursor" -- "$0" install ;;
          update)  ui_run "$(_cursor_t update_row)" -- "$0" update ;;
          remove)  ui_confirm "$(_cursor_t confirm_remove)" n && ui_run "$(ui_t remove) Cursor" -- "$0" remove ;;
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
  install    Install Cursor from the latest official .deb (via apt). Idempotent.
  update     Re-fetch the latest .deb and install it over the current version
  remove     Uninstall Cursor (apt remove — keeps your ~/.config/Cursor)
  status     Print the package version if installed; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
