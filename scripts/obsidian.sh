#!/usr/bin/env bash
#
# scripts/obsidian.sh — install / update / manage Obsidian (the Markdown knowledge base) on Ubuntu.
#
# Obsidian (https://obsidian.md) is a local-first Markdown notes app (Electron desktop). It is NOT
# in any apt repo; its official Linux distribution is a versioned .deb on GitHub releases
# (obsidianmd/obsidian-releases) — amd64 ONLY — plus an AppImage and a community-verified Flathub
# flatpak. This script installs the official amd64 .deb THROUGH apt so dependencies resolve and
# removal is a clean `apt remove obsidian` — the kit's "vendor .deb" channel (the same approach
# scripts/cursor.sh and scripts/ghostty.sh use). If the .deb can't be fetched it falls back to the
# official snap (`snap install obsidian --classic`, hands-off auto-update). On non-amd64 (no
# official .deb or snap) it refuses with guidance to the arm64 AppImage / Flathub flatpak.
#
# Update model: Obsidian's in-app updater only patches the asar (the JS layer, under
# ~/.config/obsidian) — it does NOT update the bundled Electron, and apt has no repo to upgrade
# from. So the script adds an `update` action: re-resolve the latest .deb and install it over the
# current one (or `snap refresh` for a snap install).
#
# Honesty note: Obsidian is a desktop GUI app. Over SSH / on a headless server there is no local
# display to run it; install still places the package and says so when it detects an SSH session.
#
# Run it as:  obsidian.sh install|remove|update|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly OBSIDIAN_RELEASES_REPO="obsidianmd/obsidian-releases"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "Obsidian" and the package
# name "obsidian" stay UNtranslated; only descriptive wording is localized. Resolve a row with
# _obsidian_t KEY (fallback en -> the key itself, just like ui_t).
declare -gA OBSIDIAN_I18N
OBSIDIAN_I18N[en:update_row]="Update to the latest Obsidian"
OBSIDIAN_I18N[en:confirm_remove]="Uninstall Obsidian? (apt remove — keeps your ~/.config/obsidian)"
OBSIDIAN_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
OBSIDIAN_I18N[en:foot_manage]="↑↓ move   ↵/space select   esc/q close"
OBSIDIAN_I18N[en:ssh_note]="Obsidian is a desktop GUI app — over SSH the window runs where there is a display (forward X11/Wayland or run it locally)."
OBSIDIAN_I18N[zh:update_row]="更新到最新版 Obsidian"
OBSIDIAN_I18N[zh:confirm_remove]="卸载 Obsidian?(apt remove — 保留你的 ~/.config/obsidian)"
OBSIDIAN_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
OBSIDIAN_I18N[zh:foot_manage]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
OBSIDIAN_I18N[zh:ssh_note]="Obsidian 是桌面 GUI 应用 — SSH 下窗口运行在有显示器的机器上(转发 X11/Wayland 或在本地运行)。"
OBSIDIAN_I18N[ja:update_row]="最新の Obsidian に更新"
OBSIDIAN_I18N[ja:confirm_remove]="Obsidian をアンインストールしますか?(apt remove — ~/.config/obsidian は保持)"
OBSIDIAN_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
OBSIDIAN_I18N[ja:foot_manage]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"
OBSIDIAN_I18N[ja:ssh_note]="Obsidian はデスクトップ GUI アプリです — SSH ではディスプレイのある環境でウィンドウが動作します(X11/Wayland 転送かローカル実行)。"

# _obsidian_t KEY — localized Obsidian string for $UI_LANG (en/zh/ja), fallback en -> key.
_obsidian_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${OBSIDIAN_I18N[$lang:$1]:-${OBSIDIAN_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=obsidian
name=Obsidian
category=apps
tags=gui desktop-only
ops=install,remove,update
desc=Obsidian — the Markdown knowledge base (official .deb from GitHub releases; 'update' fetches the latest)
META
}

# Exit 0 iff Obsidian is installed (via dpkg, snap, or otherwise on PATH). Detection is cheap and
# never launches the GUI. Under KIT_PROBE_ONLY (catalog cache) return the install boolean BEFORE
# any version spawn — both paths return the same exit code. Print the version for the detail view.
status() {
  local via=""
  if pkg_installed obsidian; then
    via=deb
  elif have_cmd snap && snap list obsidian >/dev/null 2>&1; then
    via=snap
  elif have_cmd obsidian; then
    via=path
  else
    return 1
  fi
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  case "$via" in
    deb)
      local v; v="$(dpkg-query -W -f='${Version}' obsidian 2>/dev/null || true)"
      printf 'obsidian %s\n' "${v:-installed}" ;;
    snap)
      local v; v="$(snap list obsidian 2>/dev/null | awk 'NR==2{print $2}' || true)"
      printf 'obsidian %s (snap)\n' "${v:-installed}" ;;
    path)
      printf 'obsidian (installed, not via dpkg/snap)\n' ;;
  esac
  return 0
}

# True iff we are in an SSH/headless session (no local display to run Obsidian).
_obsidian_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
# Emit the SSH caveat only when relevant. MUST use the `if` form (not a bare `_obsidian_in_ssh &&
# log_warn …`) wherever it is the LAST command of do_install/_obsidian_post_install/do_update:
# the bare-&& form would leak _obsidian_in_ssh's FALSE (non-SSH) status up through `set -e` and
# make a fully successful local install report exit 1 (cursor.sh:82-86 documents this exact bug).
_obsidian_where_note() { if _obsidian_in_ssh; then log_warn "$(_obsidian_t ssh_note)"; fi; }

# Resolve the latest official amd64 .deb URL + version into _OBSIDIAN_URL / _OBSIDIAN_VER from the
# GitHub releases API. The asset name is obsidian_<ver>_amd64.deb (the only amd64 .deb in the
# payload), so a plain grep is robust and needs no jq. Non-zero (with guidance) if the API is
# unreachable or has no amd64 .deb. Only ever called on amd64 (do_install gates arch first).
_obsidian_resolve_deb() {
  have_cmd curl || apt_install curl ca-certificates
  local api="https://api.github.com/repos/${OBSIDIAN_RELEASES_REPO}/releases/latest"
  log_info "Looking up the latest Obsidian release from ${OBSIDIAN_RELEASES_REPO}…"
  local url
  # The API body is small and bounded, so a wall-clock cap is safe here (unlike the large .deb
  # download below) and guards against a connection that handshakes then trickles/stalls forever.
  url="$(curl -fsSL --connect-timeout 30 --max-time 30 --retry 3 --retry-delay 5 --retry-all-errors "$api" 2>/dev/null \
    | grep -oE 'https://[^"]*obsidian_[^"/]*_amd64\.deb' \
    | head -n1 || true)"
  if [[ -z "$url" ]]; then
    log_err "Could not find an amd64 .deb in the latest ${OBSIDIAN_RELEASES_REPO} release"
    log_err "(network issue, or the release asset naming changed). See https://obsidian.md/download"
    return 1
  fi
  _OBSIDIAN_URL="$url"
  # Derive the version from the asset filename: obsidian_<ver>_amd64.deb -> <ver> (no extra tools).
  local base="${url##*/}"; base="${base#obsidian_}"; _OBSIDIAN_VER="${base%_amd64.deb}"
  return 0
}

# Download the resolved .deb and install it via apt (resolves deps, non-interactive, escalates per
# command). apt treats a path with a slash as a local file. Used by both install and update.
_obsidian_install_deb() {
  _obsidian_resolve_deb || return 1
  log_info "Channel: official Obsidian .deb (v${_OBSIDIAN_VER:-unknown})."
  log_info "Downloading: $_OBSIDIAN_URL"
  local tmp deb rc=0
  tmp="$(mktemp -d)"
  deb="$tmp/obsidian.deb"
  # Bound only the connect phase and a genuine STALL — NOT total elapsed time: a wall-clock cap
  # (--max-time) aborts a slow-but-still-progressing transfer. --speed-time/--speed-limit abort
  # only when real throughput stays under 1 KB/s for 60s; --retry + -C - retry transient drops and
  # resume the partial bytes already on disk. Do NOT add --max-time.
  if ! curl -fsSL \
        --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$_OBSIDIAN_URL" -o "$deb"; then
    rm -rf "$tmp"; log_err "Failed to download the Obsidian .deb."; return 1
  fi
  apt_install "$deb" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_obsidian_post_install() {
  log_info "Installed Obsidian ($(status 2>/dev/null | head -n1))."
  log_info "Launch it from your application menu or 'obsidian'. Update later with: ${0##*/} update"
  _obsidian_where_note
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Obsidian is already installed ($(status 2>/dev/null | head -n1)) — to get the latest, run: ${0##*/} update"
    return 0
  fi

  # Obsidian publishes an official .deb and snap for amd64 only. There is no official arm64 .deb or
  # snap, so on any other arch refuse honestly and point at the first-party arm64 options.
  local arch; arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  if [[ "$arch" != amd64 ]]; then
    log_err "Obsidian has no official .deb or snap for '${arch}' (amd64 only)."
    log_err "On ${arch}, install the official arm64 AppImage or the Flathub flatpak"
    log_err "(md.obsidian.Obsidian) by hand. See https://obsidian.md/download"
    return 1
  fi
  have_cmd curl || apt_install curl ca-certificates

  # 1. Official amd64 .deb (primary).
  if _obsidian_install_deb; then
    _obsidian_post_install
    return 0
  fi

  # 2. Official snap (classic confinement) — fallback when the .deb can't be fetched. Hands-off
  #    auto-update from the store.
  if have_cmd snap; then
    log_info "Channel: snap (classic confinement) — falling back from the .deb."
    sudo_run snap install obsidian --classic
    _obsidian_post_install
    return 0
  fi

  log_err "Could not install Obsidian: the official .deb could not be fetched and snap is"
  log_err "unavailable. See https://obsidian.md/download for the .deb / AppImage / flatpak options."
  return 1
}

# update — re-resolve the latest official .deb and install it over the current one (apt upgrades in
# place), or `snap refresh` for a snap install. It always re-downloads, so this is a deliberate,
# user-invoked action rather than part of the idempotent install path. Installs if Obsidian is absent.
do_update() {
  if ! status >/dev/null 2>&1; then
    log_info "Obsidian is not installed — installing the latest instead."
    do_install
    return $?
  fi
  if pkg_installed obsidian; then
    local cur; cur="$(dpkg-query -W -f='${Version}' obsidian 2>/dev/null || true)"
    _obsidian_install_deb || return 1
    log_info "Obsidian is now $(status 2>/dev/null | head -n1) (was ${cur:-unknown})."
    _obsidian_where_note
    return 0
  fi
  if have_cmd snap && snap list obsidian >/dev/null 2>&1; then
    log_info "Obsidian was installed via snap — refreshing from the store."
    sudo_run snap refresh obsidian
    log_info "Obsidian snap: $(status 2>/dev/null | head -n1)."
    _obsidian_where_note
    return 0
  fi
  log_warn "Obsidian is on PATH but not managed by dpkg or snap; update it the way you installed"
  log_warn "it (the in-app updater, or re-download the AppImage)."
  return 1
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Obsidian is not installed — nothing to remove."
    return 0
  fi
  if pkg_installed obsidian; then
    apt_remove obsidian
    log_info "Removed the Obsidian package (apt remove keeps your ~/.config/obsidian)."
  elif have_cmd snap && snap list obsidian >/dev/null 2>&1; then
    sudo_run snap remove obsidian
    log_info "Removed the Obsidian snap (your ~/.config/obsidian is kept)."
  else
    log_warn "Obsidian is on PATH but not managed by dpkg or snap; remove it the way you"
    log_warn "installed it. Your vaults config under ~/.config/obsidian is left untouched."
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
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Obsidian")
    else
      dkind+=(status); dlabel+=("$(printf '%-13s %s' 'obsidian' "${UI_INFO}${ver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(update); dlabel+=("$(ui_badge check) $(_obsidian_t update_row)")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Obsidian")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Obsidian" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Obsidian" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_obsidian_t foot_manage)"
    else ui_footer "$(_obsidian_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Obsidian" -- "$0" install ;;
          update)  ui_run "$(_obsidian_t update_row)" -- "$0" update ;;
          remove)  ui_confirm "$(_obsidian_t confirm_remove)" n && ui_run "$(ui_t remove) Obsidian" -- "$0" remove ;;
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
  install    Install Obsidian from the latest official amd64 .deb (via apt), else snap. Idempotent.
  update     Re-fetch the latest .deb and install it over the current version (or snap refresh)
  remove     Uninstall Obsidian (apt/snap remove — keeps your ~/.config/obsidian)
  status     Print the version if installed; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
