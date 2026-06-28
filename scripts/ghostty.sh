#!/usr/bin/env bash
#
# scripts/ghostty.sh — install / configure / manage Ghostty on Ubuntu.
#
# Ghostty (https://ghostty.org) is a fast, GPU-accelerated, native terminal emulator.
# It follows a "zero configuration" philosophy with good defaults; this script installs it
# and layers a small, conservative, *managed* configuration on top — theme, font, and a
# handful of common settings — without ever clobbering the user's own config.
#
# Install channels (highest that works wins; the chosen one is logged):
#   1. apt           — Ubuntu 26.04+/Debian trixie+ ship `ghostty` in the official repos.
#   2. community .deb — mkasberg/ghostty-ubuntu publishes real .deb packages (built with
#                       Ghostty's own scripts) for Ubuntu 24.04/25.10/26.04. This is the
#                       recommended route on releases that don't have it in apt yet.
#   3. snap          — `snap install ghostty --classic`, the lower-priority fallback (classic
#                       confinement; the snap is not yet an officially-owned package format).
#
# Configuration model (mirrors scripts/zsh.sh's managed drop-in):
#   - Preferences are stored in ~/.config/ubuntu-setup/ghostty.conf (the kit's own KEY=VALUE
#     store), edited via `configure` / the ui().
#   - From those we regenerate a managed Ghostty config file ~/.config/ghostty/ubuntu-setup
#     (we own it 100%; it is rewritten wholesale and convergent).
#   - We ensure the user's real config (~/.config/ghostty/config) loads it once, via an
#     absolute-path `config-file = …` include (back up before the first edit, append once).
#     Everything the user wrote in `config` is preserved.
#
# Honesty note: Ghostty is a desktop GUI terminal. Over SSH / on a headless server you are
# not running Ghostty on that box — these settings apply where Ghostty actually runs (a
# machine with a display). install/configure say so when they detect an SSH session.
#
# Run it as:  ghostty.sh install|remove|configure|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# Curated quick-pick lists (the source of truth for themes is `ghostty +list-themes`, which
# ships hundreds; these are confident, popular built-ins for the menu, and free text covers
# the rest). Font families map to the kit's user-space Nerd Font manager (scripts/fonts.sh).
readonly GHOSTTY_DEB_REPO="mkasberg/ghostty-ubuntu"
readonly GHOSTTY_DEB_RELEASES="24.04 25.10 26.04"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local so the generic UI library stays free of
# Ghostty-specific text. Proper nouns stay UNtranslated (the software name "Ghostty", theme
# names like "Catppuccin Mocha", font families like "MesloLGS NF", cursor values block/bar/
# underline, config keys) — only the descriptive/operational wording is localized. Resolve a
# row with _ghostty_t KEY; falls back en -> the key itself, just like ui_t.
declare -gA GHOSTTY_I18N
# UI rows / headers / hints
GHOSTTY_I18N[en:note]="Settings are written to a managed drop-in; your own ~/.config/ghostty/config is preserved."
GHOSTTY_I18N[en:appearance]="Appearance"
GHOSTTY_I18N[en:behavior]="Behavior"
GHOSTTY_I18N[en:theme]="Theme"
GHOSTTY_I18N[en:font]="Font"
GHOSTTY_I18N[en:font_size]="Font size"
GHOSTTY_I18N[en:opacity]="Opacity"
GHOSTTY_I18N[en:cursor_style]="Cursor style"
GHOSTTY_I18N[en:window_padding]="Window padding"
GHOSTTY_I18N[en:window_size]="Window size"
GHOSTTY_I18N[en:copy_on_select]="Copy on select"
GHOSTTY_I18N[en:hide_mouse]="Hide mouse on type"
GHOSTTY_I18N[en:confirm_close]="Confirm close"
GHOSTTY_I18N[en:cursor_blink]="Cursor blink"
GHOSTTY_I18N[en:apply_now]="Write config now (apply settings)"
GHOSTTY_I18N[en:set_default]="Set Ghostty as default terminal"
GHOSTTY_I18N[en:is_default]="Default terminal: Ghostty"
GHOSTTY_I18N[en:to_revert]="↵ to revert"
GHOSTTY_I18N[en:default_val]="default"
GHOSTTY_I18N[en:current]="current:"
GHOSTTY_I18N[en:foot_main]="↑↓ move   ↵/space edit·toggle   esc/q close"
# Pickers / prompts
GHOSTTY_I18N[en:pick_theme]="Ghostty — theme"
GHOSTTY_I18N[en:theme_auto]="Catppuccin (auto light/dark)"
GHOSTTY_I18N[en:theme_latte]="Catppuccin Latte (light)"
GHOSTTY_I18N[en:type_theme]="Type a theme name…"
GHOSTTY_I18N[en:prompt_theme]="theme name (see: ghostty +list-themes)"
GHOSTTY_I18N[en:pick_font]="Ghostty — font family"
GHOSTTY_I18N[en:font_p10k]="MesloLGS NF (Powerlevel10k / Starship)"
GHOSTTY_I18N[en:font_system]="System / Ghostty default"
GHOSTTY_I18N[en:type_font]="Type a font family…"
GHOSTTY_I18N[en:prompt_font]="font family"
GHOSTTY_I18N[en:prompt_size]="font size (6-48)"
GHOSTTY_I18N[en:prompt_opacity]="background opacity (0-1)"
GHOSTTY_I18N[en:pick_cursor]="Ghostty — cursor style"
GHOSTTY_I18N[en:prompt_padding]="window padding (px)"
GHOSTTY_I18N[en:prompt_wsize]="window size COLSxROWS, e.g. 120x36 (blank = default)"
GHOSTTY_I18N[en:confirm_remove]="Uninstall Ghostty? (your ~/.config/ghostty is kept)"

GHOSTTY_I18N[zh:note]="设置写入受管 drop-in;你自己的 ~/.config/ghostty/config 不受影响。"
GHOSTTY_I18N[zh:appearance]="外观"
GHOSTTY_I18N[zh:behavior]="行为"
GHOSTTY_I18N[zh:theme]="主题"
GHOSTTY_I18N[zh:font]="字体"
GHOSTTY_I18N[zh:font_size]="字号"
GHOSTTY_I18N[zh:opacity]="不透明度"
GHOSTTY_I18N[zh:cursor_style]="光标样式"
GHOSTTY_I18N[zh:window_padding]="窗口内边距"
GHOSTTY_I18N[zh:window_size]="窗口尺寸"
GHOSTTY_I18N[zh:copy_on_select]="选中即复制"
GHOSTTY_I18N[zh:hide_mouse]="输入时隐藏鼠标"
GHOSTTY_I18N[zh:confirm_close]="关闭前确认"
GHOSTTY_I18N[zh:cursor_blink]="光标闪烁"
GHOSTTY_I18N[zh:apply_now]="立即写入配置(应用设置)"
GHOSTTY_I18N[zh:set_default]="将 Ghostty 设为默认终端"
GHOSTTY_I18N[zh:is_default]="默认终端:Ghostty"
GHOSTTY_I18N[zh:to_revert]="↵ 还原"
GHOSTTY_I18N[zh:default_val]="默认"
GHOSTTY_I18N[zh:current]="当前:"
GHOSTTY_I18N[zh:foot_main]="↑↓ 移动   ↵/space 编辑·切换   esc/q 关闭"
GHOSTTY_I18N[zh:pick_theme]="Ghostty — 主题"
GHOSTTY_I18N[zh:theme_auto]="Catppuccin(自动明暗)"
GHOSTTY_I18N[zh:theme_latte]="Catppuccin Latte(浅色)"
GHOSTTY_I18N[zh:type_theme]="输入主题名…"
GHOSTTY_I18N[zh:prompt_theme]="主题名(见:ghostty +list-themes)"
GHOSTTY_I18N[zh:pick_font]="Ghostty — 字体"
GHOSTTY_I18N[zh:font_p10k]="MesloLGS NF(Powerlevel10k / Starship)"
GHOSTTY_I18N[zh:font_system]="系统 / Ghostty 默认"
GHOSTTY_I18N[zh:type_font]="输入字体名…"
GHOSTTY_I18N[zh:prompt_font]="字体名"
GHOSTTY_I18N[zh:prompt_size]="字号(6-48)"
GHOSTTY_I18N[zh:prompt_opacity]="背景不透明度(0-1)"
GHOSTTY_I18N[zh:pick_cursor]="Ghostty — 光标样式"
GHOSTTY_I18N[zh:prompt_padding]="窗口内边距(px)"
GHOSTTY_I18N[zh:prompt_wsize]="窗口尺寸 列x行,如 120x36(留空=默认)"
GHOSTTY_I18N[zh:confirm_remove]="卸载 Ghostty?(保留你的 ~/.config/ghostty)"

GHOSTTY_I18N[ja:note]="設定は管理対象の drop-in に書き込まれます。あなた自身の ~/.config/ghostty/config はそのまま保持されます。"
GHOSTTY_I18N[ja:appearance]="外観"
GHOSTTY_I18N[ja:behavior]="挙動"
GHOSTTY_I18N[ja:theme]="テーマ"
GHOSTTY_I18N[ja:font]="フォント"
GHOSTTY_I18N[ja:font_size]="フォントサイズ"
GHOSTTY_I18N[ja:opacity]="不透明度"
GHOSTTY_I18N[ja:cursor_style]="カーソルスタイル"
GHOSTTY_I18N[ja:window_padding]="ウィンドウの余白"
GHOSTTY_I18N[ja:window_size]="ウィンドウサイズ"
GHOSTTY_I18N[ja:copy_on_select]="選択でコピー"
GHOSTTY_I18N[ja:hide_mouse]="入力中はマウスを隠す"
GHOSTTY_I18N[ja:confirm_close]="閉じる前に確認"
GHOSTTY_I18N[ja:cursor_blink]="カーソルの点滅"
GHOSTTY_I18N[ja:apply_now]="今すぐ設定を書き込む(適用)"
GHOSTTY_I18N[ja:set_default]="Ghostty を既定の端末にする"
GHOSTTY_I18N[ja:is_default]="既定の端末: Ghostty"
GHOSTTY_I18N[ja:to_revert]="↵ で元に戻す"
GHOSTTY_I18N[ja:default_val]="デフォルト"
GHOSTTY_I18N[ja:current]="現在:"
GHOSTTY_I18N[ja:foot_main]="↑↓ 移動   ↵/space 編集·切替   esc/q 閉じる"
GHOSTTY_I18N[ja:pick_theme]="Ghostty — テーマ"
GHOSTTY_I18N[ja:theme_auto]="Catppuccin(自動で明暗切替)"
GHOSTTY_I18N[ja:theme_latte]="Catppuccin Latte(ライト)"
GHOSTTY_I18N[ja:type_theme]="テーマ名を入力…"
GHOSTTY_I18N[ja:prompt_theme]="テーマ名(参照: ghostty +list-themes)"
GHOSTTY_I18N[ja:pick_font]="Ghostty — フォントファミリー"
GHOSTTY_I18N[ja:font_p10k]="MesloLGS NF(Powerlevel10k / Starship)"
GHOSTTY_I18N[ja:font_system]="システム / Ghostty デフォルト"
GHOSTTY_I18N[ja:type_font]="フォントファミリーを入力…"
GHOSTTY_I18N[ja:prompt_font]="フォントファミリー"
GHOSTTY_I18N[ja:prompt_size]="フォントサイズ(6-48)"
GHOSTTY_I18N[ja:prompt_opacity]="背景の不透明度(0-1)"
GHOSTTY_I18N[ja:pick_cursor]="Ghostty — カーソルスタイル"
GHOSTTY_I18N[ja:prompt_padding]="ウィンドウの余白(px)"
GHOSTTY_I18N[ja:prompt_wsize]="ウィンドウサイズ 列x行 例 120x36(空=デフォルト)"
GHOSTTY_I18N[ja:confirm_remove]="Ghostty をアンインストールしますか?(~/.config/ghostty は保持)"

# _ghostty_t KEY — localized Ghostty string for $UI_LANG (en/zh/ja), fallback en -> key.
_ghostty_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${GHOSTTY_I18N[$lang:$1]:-${GHOSTTY_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=ghostty
name=Ghostty
category=terminal
tags=gui desktop-only
ops=install,remove,configure,default-terminal
desc=Ghostty — fast GPU-accelerated terminal emulator (apt on 26.04+, else community .deb / snap); manages theme, font, sensible defaults, default-terminal
META
}

# --- Install probe -------------------------------------------------------------

# Best-effort version string (Ghostty supports `--version`; `+version` as a fallback).
_ghostty_version() {
  local v=""
  have_cmd ghostty || { printf ''; return 0; }
  v="$(ghostty --version 2>/dev/null | head -n1)"
  [[ -n "$v" ]] || v="$(ghostty +version 2>/dev/null | head -n1)"
  printf '%s' "$v"
}

# Exit 0 iff Ghostty is installed (on PATH via apt/.deb/snap, or a dpkg-installed package).
status() {
  if have_cmd ghostty; then
    local v; v="$(_ghostty_version)"
    printf '%s\n' "${v:-ghostty (installed)}"
    return 0
  fi
  if pkg_installed ghostty; then
    printf 'ghostty (dpkg: installed)\n'
    return 0
  fi
  return 1
}

# --- Channel detection / install ----------------------------------------------

# Read a single field from /etc/os-release without sourcing it (no global leak, and no
# spurious unassigned-variable warnings from a static checker).
_ghostty_os_field() {
  [[ -r /etc/os-release ]] || return 1
  local v
  v="$(grep -E "^$1=" /etc/os-release 2>/dev/null | head -n1 | cut -d= -f2-)"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

# Is `ghostty` an installable apt candidate right now? (No sudo; reads existing apt lists.)
_ghostty_apt_available() {
  local cand
  cand="$(apt-cache policy ghostty 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Set _G_ARCH / _G_VERID and return 0 iff mkasberg/ghostty-ubuntu builds a .deb for this
# Ubuntu release.
_ghostty_deb_supported() {
  local id id_like
  id="$(_ghostty_os_field ID || true)"
  id_like="$(_ghostty_os_field ID_LIKE || true)"
  case " $id $id_like " in *" ubuntu "*) ;; *) return 1 ;; esac
  _G_VERID="$(_ghostty_os_field VERSION_ID || true)"
  local r ok=1
  for r in $GHOSTTY_DEB_RELEASES; do [[ "$r" == "$_G_VERID" ]] && ok=0; done
  (( ok == 0 )) || return 1
  _G_ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
  [[ -n "$_G_ARCH" ]]
}

# Install the latest community .deb that matches this arch + release. Returns non-zero (so
# the caller can fall through to the next channel) if no matching asset is found.
_ghostty_install_deb() {
  _ghostty_deb_supported || {
    log_info "No community .deb is published for this release/arch — trying the next channel."
    return 1
  }
  local suffix="${_G_ARCH}_${_G_VERID}"
  local api="https://api.github.com/repos/${GHOSTTY_DEB_REPO}/releases/latest"
  log_info "Looking up the latest Ghostty .deb for '${suffix}' from ${GHOSTTY_DEB_REPO}…"
  local url
  url="$(curl -fsSL "$api" 2>/dev/null \
    | grep -oE "https://[^\"]*ghostty_[^\"/]*_${suffix}\.deb" \
    | head -n1 || true)"
  if [[ -z "$url" ]]; then
    log_warn "Could not find a .deb asset for '${suffix}' in the latest ${GHOSTTY_DEB_REPO} release."
    return 1
  fi
  log_info "Channel: community .deb (${GHOSTTY_DEB_REPO})."
  log_info "Downloading: $url"
  local tmp deb rc=0
  tmp="$(mktemp -d)"
  deb="$tmp/ghostty.deb"
  if ! curl -fsSL "$url" -o "$deb"; then
    rm -rf "$tmp"; log_err "Failed to download the Ghostty .deb."; return 1
  fi
  # Install the local .deb through apt so its dependencies resolve (apt treats a path with a
  # slash as a file). apt_install keeps it non-interactive and escalates per-command.
  apt_install "$deb" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Ghostty is already installed ($(status 2>/dev/null | head -n1)) — skipping."
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates

  # 1. Native apt (Ubuntu 26.04+ / Debian trixie+).
  if _ghostty_apt_available; then
    log_info "Channel: apt (distro package)."
    apt_install ghostty
    _ghostty_post_install
    return 0
  fi

  # 2. Community .deb (recommended for Ubuntu 24.04 / 25.10).
  if _ghostty_install_deb; then
    _ghostty_post_install
    return 0
  fi

  # 3. snap (classic confinement) — lower priority fallback.
  if have_cmd snap; then
    log_info "Channel: snap (classic confinement)."
    sudo_run snap install ghostty --classic
    _ghostty_post_install
    return 0
  fi

  log_err "Could not install Ghostty: it is not in apt here, no community .deb matched this"
  log_err "release/arch, and snap is unavailable. See https://ghostty.org/docs/install for"
  log_err "options (including building from source)."
  return 1
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Ghostty is not installed — nothing to remove."
    return 0
  fi
  if pkg_installed ghostty; then
    apt_remove ghostty
    log_info "Removed the Ghostty package (apt remove keeps your ~/.config/ghostty)."
  elif have_cmd snap && snap list ghostty >/dev/null 2>&1; then
    sudo_run snap remove ghostty
    log_info "Removed the Ghostty snap (your ~/.config/ghostty is kept)."
  else
    log_warn "Ghostty is on PATH but not managed by dpkg or snap; remove it the way you"
    log_warn "installed it. Your config under ~/.config/ghostty is left untouched."
    return 1
  fi
}

# --- Default terminal ----------------------------------------------------------
# `default-terminal [off]` makes Ghostty the default terminal (or reverts it), across two
# mechanisms, highest-value first:
#   1. PRIMARY (user-scope, no sudo): the freedesktop xdg-terminal-exec selector — Ghostty's
#      Desktop Entry id as the FIRST line of the user's terminal list. This is what modern
#      GNOME (Ubuntu 25.04+/26.04) resolves Ctrl+Alt+T / "Open Terminal" through. We write
#      the $XDG_CURRENT_DESKTOP-suffixed file (top precedence) AND the plain fallback, keeping
#      any other terminals the user listed (de-duplicated) below Ghostty.
#   2. SECONDARY (best-effort, per-command sudo, .deb/apt only): the Debian alternatives
#      `x-terminal-emulator`. Ghostty's packaging does NOT register it, so we --install then
#      --set. Snap is skipped (update-alternatives can't carry the snap wrapper's args). A
#      failure (incl. RC_NEED_SUDO on a no-TTY shell) only warns — the user-scope selector
#      already did the real work. This serves legacy/CLI callers (sensible-terminal, i3/sway,
#      scripts), NOT GNOME's Ctrl+Alt+T on 25.04+.
# Deliberately NOT touched: the deprecated gsettings terminal key (overwriting it regresses
# the modern xdg-terminal-exec chain on 25.04+), $TERMINAL, and third-party Nautilus
# extensions. Ghostty is a desktop GUI app, so on SSH/headless this is honest no-op-with-
# future-value: we still write the user-owned file (applies once a display exists) but say so.

# True iff Ghostty was installed via snap (drives the desktop id + skips update-alternatives).
_ghostty_is_snap() {
  have_cmd snap || return 1
  snap list ghostty >/dev/null 2>&1 && return 0
  local g; g="$(command -v ghostty 2>/dev/null || true)"
  [[ -n "$g" && "$(readlink -f "$g" 2>/dev/null)" == /snap/* ]]
}

# The installed Desktop Entry id. Prefer the id whose .desktop file actually exists; else
# infer from the install method (apt/.deb -> com.mitchellh.ghostty.desktop, snap -> ghostty_ghostty.desktop).
_ghostty_desktop_id() {
  if [[ -f /usr/share/applications/com.mitchellh.ghostty.desktop ]]; then
    printf 'com.mitchellh.ghostty.desktop'; return 0
  fi
  if [[ -f /var/lib/snapd/desktop/applications/ghostty_ghostty.desktop ]]; then
    printf 'ghostty_ghostty.desktop'; return 0
  fi
  if _ghostty_is_snap; then printf 'ghostty_ghostty.desktop'; else printf 'com.mitchellh.ghostty.desktop'; fi
}

# Resolve the xdg-terminal-exec selector files into _G_XDG_PRIMARY (top precedence: the live
# session's $XDG_CURRENT_DESKTOP-suffixed file, e.g. ubuntu-xdg-terminals.list) and
# _G_XDG_PLAIN (the universal fallback). Needs _G_HOME (set by _ghostty_resolve_home).
_ghostty_xdg_files() {
  local cfg="${XDG_CONFIG_HOME:-$_G_HOME/.config}"
  _G_XDG_PLAIN="$cfg/xdg-terminals.list"
  local token=""
  if [[ -n "${XDG_CURRENT_DESKTOP:-}" ]]; then
    token="${XDG_CURRENT_DESKTOP%%:*}"
    token="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
  fi
  if [[ -n "$token" ]]; then
    _G_XDG_PRIMARY="$cfg/${token}-xdg-terminals.list"
  else
    _G_XDG_PRIMARY="$_G_XDG_PLAIN"
  fi
}

# Ensure ID is the FIRST line of FILE, preserving (de-duplicated) any other terminals below.
# Convergent (no-op when already first) and backed up before any edit, like the managed drop-in.
_ghostty_xdg_set_first() {
  local file="$1" id="$2" tmp
  mkdir -p "$(dirname "$file")"
  if [[ -f "$file" && "$(head -n1 "$file" 2>/dev/null)" == "$id" ]]; then
    return 0
  fi
  backup_file "$file"
  tmp="$(mktemp)"
  {
    printf '%s\n' "$id"
    [[ -f "$file" ]] && grep -vxF -- "$id" "$file" || true
  } >"$tmp"
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  log_info "Set $id as the preferred terminal in $file"
}

# Remove ID from FILE; drop the file entirely if nothing meaningful remains.
_ghostty_xdg_remove() {
  local file="$1" id="$2" tmp
  [[ -f "$file" ]] || return 0
  grep -qxF -- "$id" "$file" 2>/dev/null || return 0
  backup_file "$file"
  tmp="$(mktemp)"
  # `|| true` is essential: grep -vxF exits 1 when the file held ONLY the ghostty line
  # (the common case), which would otherwise skip the write and leave the line in place.
  grep -vxF -- "$id" "$file" >"$tmp" || true
  if grep -qvE '^[[:space:]]*(#.*)?$' "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp" "$file"
  fi
  log_info "Removed $id from $file"
}

# Exit 0 iff Ghostty is installed AND it is the first entry of the primary selector file.
# Observes the live filesystem (never a recorded flag). Needs _G_HOME (resolve home first).
_ghostty_is_default() {
  status >/dev/null 2>&1 || return 1
  _ghostty_xdg_files
  local id; id="$(_ghostty_desktop_id)"
  [[ -f "$_G_XDG_PRIMARY" && "$(head -n1 "$_G_XDG_PRIMARY" 2>/dev/null)" == "$id" ]]
}

# Best-effort system-wide x-terminal-emulator registration (.deb/apt only). Never aborts the
# op: a non-zero rc (incl. RC_NEED_SUDO=97 when sudo needs a password on a no-TTY shell, in
# which case sudo_run already printed the exact command) is logged as a warning.
_ghostty_set_alternative() {
  have_cmd update-alternatives || { log_info "update-alternatives absent — skipping the x-terminal-emulator integration."; return 0; }
  if _ghostty_is_snap || [[ ! -x /usr/bin/ghostty ]]; then
    log_info "Skipping x-terminal-emulator (needs a .deb/apt /usr/bin/ghostty; a snap wrapper can't be registered)."
    return 0
  fi
  local g=/usr/bin/ghostty
  # Ghostty's packaging does not register the alternative, so --install first; then --set
  # pins it in manual mode regardless of priority.
  if ! sudo_run update-alternatives --install /usr/bin/x-terminal-emulator x-terminal-emulator "$g" 50; then
    log_warn "Could not register the x-terminal-emulator alternative (rc=$?) — continuing."
    return 0
  fi
  if ! sudo_run update-alternatives --set x-terminal-emulator "$g"; then
    log_warn "Could not select Ghostty for x-terminal-emulator (rc=$?) — continuing."
    return 0
  fi
  log_info "Registered + selected Ghostty for the system x-terminal-emulator alternative."
}

_ghostty_unset_alternative() {
  have_cmd update-alternatives || return 0
  [[ -x /usr/bin/ghostty ]] || return 0
  update-alternatives --query x-terminal-emulator 2>/dev/null | grep -qxF "Alternative: /usr/bin/ghostty" || return 0
  if ! sudo_run update-alternatives --remove x-terminal-emulator /usr/bin/ghostty; then
    log_warn "Could not remove Ghostty from the x-terminal-emulator alternative (rc=$?) — continuing."
    return 0
  fi
  log_info "Removed Ghostty from the system x-terminal-emulator alternative (back to auto)."
}

# default-terminal [off] — set Ghostty as the default terminal, or revert with off/unset.
do_default_terminal() {
  _ghostty_resolve_home || return 1
  local action="set"
  case "${1:-}" in
    ''|on|set|enable)          action="set" ;;
    off|unset|disable|revert)  action="unset" ;;
    -h|--help)                 usage; return 0 ;;
    *) log_err "Usage: ${0##*/} default-terminal [off]"; return 2 ;;
  esac

  if ! status >/dev/null 2>&1; then
    log_info "Ghostty is not installed — install it first (swkit ghostty install)."
    return 0
  fi

  _ghostty_xdg_files
  local id; id="$(_ghostty_desktop_id)"

  if [[ "$action" == "unset" ]]; then
    _ghostty_xdg_remove "$_G_XDG_PRIMARY" "$id"
    [[ "$_G_XDG_PLAIN" != "$_G_XDG_PRIMARY" ]] && _ghostty_xdg_remove "$_G_XDG_PLAIN" "$id"
    rm -f "${XDG_CACHE_HOME:-$_G_HOME/.cache}/xdg-terminal-exec" 2>/dev/null || true
    _ghostty_unset_alternative
    log_info "Ghostty is no longer the configured default terminal; the system default now applies."
    return 0
  fi

  # set: convergent writes (no-ops when already first), then the best-effort alternative.
  _ghostty_xdg_set_first "$_G_XDG_PRIMARY" "$id"
  [[ "$_G_XDG_PLAIN" != "$_G_XDG_PRIMARY" ]] && _ghostty_xdg_set_first "$_G_XDG_PLAIN" "$id"
  _ghostty_set_alternative

  have_cmd xdg-terminal-exec || \
    log_info "Note: the xdg-terminal-exec selector is inert until that consumer exists (ships on Ubuntu 25.04+ GNOME)."
  log_info "Ghostty ($id) is now the preferred terminal."
  log_info "Scope: GNOME 25.04+ Ctrl+Alt+T / 'Open Terminal' via the selector; legacy CLI callers via x-terminal-emulator (if registered). Revert with: ${0##*/} default-terminal off"
  _ghostty_where_note
}

# --- Configuration: paths, preferences, managed drop-in ------------------------

# Resolve the target user's home and config paths into _G_* globals. Refuses a sudo-wrapped
# run so the config files stay user-owned (never created from inside a sudo command).
_ghostty_resolve_home() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run Ghostty configuration as your normal user, not via sudo — the config lives"
    log_err "in your ~/.config/ghostty and must stay user-owned."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _G_HOME="${HOME:-}"
  [[ -n "$_G_HOME" ]] || _G_HOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_G_HOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  local xdg="${XDG_CONFIG_HOME:-$_G_HOME/.config}"
  _G_CFG_DIR="$xdg/ghostty"
  _G_CONFIG="$_G_CFG_DIR/config"          # the user's real config (we only append an include)
  _G_DROPIN="$_G_CFG_DIR/ubuntu-setup"    # the managed file we own and regenerate
  _G_PREF_DIR="$_G_HOME/.config/ubuntu-setup"
  _G_PREF="$_G_PREF_DIR/ghostty.conf"     # the kit's own KEY=VALUE preference store
}

# --- Validation ----------------------------------------------------------------
_ghostty_size_valid() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  (( 10#$1 >= 6 && 10#$1 <= 48 ))
}
_ghostty_int_valid() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
# Initial window size is measured in terminal grid cells. Ghostty refuses windows smaller than
# 10 wide x 4 high; the WM clamps anything larger than the screen, so the generous 1000 cap only
# exists to catch obvious typos. An empty value means "unset" (use Ghostty's runtime default).
_ghostty_cols_valid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; (( 10#$1 >= 10 && 10#$1 <= 1000 )); }
_ghostty_rows_valid() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; (( 10#$1 >= 4  && 10#$1 <= 1000 )); }
# Parse a combined "COLSxROWS" spec (e.g. 120x36) into WINDOW_WIDTH/WINDOW_HEIGHT; the words
# auto/default/none/off/0 (and empty) clear both back to the runtime default. Non-zero on garbage.
_ghostty_parse_window_size() {
  local spec="$1" w h
  case "$spec" in
    ''|auto|default|none|off|0) WINDOW_WIDTH=""; WINDOW_HEIGHT=""; return 0 ;;
    *[xX]*) w="${spec%%[xX]*}"; h="${spec##*[xX]}" ;;
    *) return 1 ;;
  esac
  _ghostty_cols_valid "$w" && _ghostty_rows_valid "$h" || return 1
  WINDOW_WIDTH="$w"; WINDOW_HEIGHT="$h"
}
# Opacity in [0,1] (e.g. 1, 1.0, 0.95).
_ghostty_opacity_valid() { [[ "$1" =~ ^(0(\.[0-9]+)?|1(\.0+)?)$ ]]; }
_ghostty_cursor_valid() { case "$1" in block|bar|underline) return 0 ;; *) return 1 ;; esac; }
# Normalize a boolean-ish value to Ghostty's true/false; non-zero on garbage.
_ghostty_norm_bool() {
  case "$1" in
    on|true|yes|1)  printf 'true' ;;
    off|false|no|0) printf 'false' ;;
    *) return 1 ;;
  esac
}

# Map a curated font family to the kit's fonts.sh key (non-zero if it isn't a managed font).
_ghostty_font_kit_key() {
  case "$1" in
    "MesloLGS NF")             printf 'meslolgs' ;;
    "JetBrainsMono Nerd Font") printf 'jetbrains-mono' ;;
    "FiraCode Nerd Font")      printf 'firacode' ;;
    "Hack Nerd Font")          printf 'hack' ;;
    *) return 1 ;;
  esac
}

# Lenient theme check: warn (never block) when a chosen theme name isn't found in
# `ghostty +list-themes`. Handles the combined "dark:Name,light:Name" form. No-op when
# Ghostty isn't installed (we cannot check) or the list can't be read.
_ghostty_validate_theme() {
  local spec="$1" list part t
  have_cmd ghostty || return 0
  list="$(ghostty +list-themes 2>/dev/null || true)"
  [[ -n "$list" ]] || return 0
  local -a parts=()
  IFS=',' read -ra parts <<<"$spec"
  for part in "${parts[@]}"; do
    t="${part#*:}"                       # strip a leading dark:/light: selector if present
    t="$(printf '%s' "$t" | awk '{$1=$1; print}')"   # trim surrounding whitespace
    [[ -n "$t" ]] || continue
    grep -qiF -- "$t" <<<"$list" || \
      log_warn "Theme '$t' not found in 'ghostty +list-themes' — it may not apply. Browse names with: ghostty +list-themes"
  done
}

# --- Preference store ----------------------------------------------------------
_ghostty_defaults() {
  THEME="dark:Catppuccin Mocha,light:Catppuccin Latte"  # auto light/dark
  FONT=""                 # empty = Ghostty's built-in default font
  FONT_SIZE="12"
  WINDOW_WIDTH=""         # initial window size in grid cells (cols); empty = runtime default
  WINDOW_HEIGHT=""        # initial window size in grid cells (rows); both required to apply
  OPACITY="1.0"           # fully opaque; lower needs a compositor
  CURSOR_STYLE="block"
  CURSOR_BLINK="true"
  PADDING="8"             # window-padding-x/y
  COPY_ON_SELECT="true"
  MOUSE_HIDE="true"
  CONFIRM_CLOSE="true"
  SHELL_INTEGRATION="detect"
}

_ghostty_load() {
  _ghostty_defaults
  [[ -f "${_G_PREF:-}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      THEME)             THEME="$val" ;;
      FONT)              FONT="$val" ;;
      FONT_SIZE)         _ghostty_size_valid "$val" && FONT_SIZE="$val" ;;
      WINDOW_WIDTH)      _ghostty_cols_valid "$val" && WINDOW_WIDTH="$val" ;;
      WINDOW_HEIGHT)     _ghostty_rows_valid "$val" && WINDOW_HEIGHT="$val" ;;
      OPACITY)           _ghostty_opacity_valid "$val" && OPACITY="$val" ;;
      CURSOR_STYLE)      _ghostty_cursor_valid "$val" && CURSOR_STYLE="$val" ;;
      CURSOR_BLINK)      _ghostty_norm_bool "$val" >/dev/null && CURSOR_BLINK="$(_ghostty_norm_bool "$val")" ;;
      PADDING)           _ghostty_int_valid "$val" && PADDING="$val" ;;
      COPY_ON_SELECT)    _ghostty_norm_bool "$val" >/dev/null && COPY_ON_SELECT="$(_ghostty_norm_bool "$val")" ;;
      MOUSE_HIDE)        _ghostty_norm_bool "$val" >/dev/null && MOUSE_HIDE="$(_ghostty_norm_bool "$val")" ;;
      CONFIRM_CLOSE)     _ghostty_norm_bool "$val" >/dev/null && CONFIRM_CLOSE="$(_ghostty_norm_bool "$val")" ;;
      SHELL_INTEGRATION) SHELL_INTEGRATION="$val" ;;
    esac
  done <"$_G_PREF"
}

_ghostty_save() {
  mkdir -p "$_G_PREF_DIR"
  local tmp; tmp="$(mktemp)"
  {
    printf 'THEME=%s\n'             "$THEME"
    printf 'FONT=%s\n'              "$FONT"
    printf 'FONT_SIZE=%s\n'         "$FONT_SIZE"
    printf 'WINDOW_WIDTH=%s\n'      "$WINDOW_WIDTH"
    printf 'WINDOW_HEIGHT=%s\n'     "$WINDOW_HEIGHT"
    printf 'OPACITY=%s\n'           "$OPACITY"
    printf 'CURSOR_STYLE=%s\n'      "$CURSOR_STYLE"
    printf 'CURSOR_BLINK=%s\n'      "$CURSOR_BLINK"
    printf 'PADDING=%s\n'           "$PADDING"
    printf 'COPY_ON_SELECT=%s\n'    "$COPY_ON_SELECT"
    printf 'MOUSE_HIDE=%s\n'        "$MOUSE_HIDE"
    printf 'CONFIRM_CLOSE=%s\n'     "$CONFIRM_CLOSE"
    printf 'SHELL_INTEGRATION=%s\n' "$SHELL_INTEGRATION"
  } >"$tmp"
  if [[ -f "$_G_PREF" ]] && cmp -s "$tmp" "$_G_PREF"; then rm -f "$tmp"; return 0; fi
  backup_file "$_G_PREF"
  mv "$tmp" "$_G_PREF" || { rm -f "$tmp"; return 1; }
}

# Regenerate the managed drop-in wholesale from the loaded preferences (convergent — we own
# this file entirely). Only rewrites when the content changes.
_ghostty_write_dropin() {
  mkdir -p "$_G_CFG_DIR"
  local tmp; tmp="$(mktemp)"
  {
    printf '# Managed by ubuntu-setup (swkit ghostty). Do NOT edit by hand — this file is\n'
    printf '# regenerated. Change settings with:  swkit ghostty configure   (or: swkit ghostty)\n'
    printf '# Reload a running Ghostty after changes with:  ctrl+shift+,\n'
    printf '\n'
    printf '# --- Theme (see: ghostty +list-themes) ---\n'
    [[ -n "$THEME" ]] && printf 'theme = %s\n' "$THEME"
    printf '\n# --- Font ---\n'
    [[ -n "$FONT" ]] && printf 'font-family = %s\n' "$FONT"
    printf 'font-size = %s\n' "$FONT_SIZE"
    # Ghostty applies an initial window size only when BOTH dimensions are set (in grid cells),
    # so we emit the pair as a unit or not at all.
    if [[ -n "$WINDOW_WIDTH" && -n "$WINDOW_HEIGHT" ]]; then
      printf '\n# --- Initial window size (terminal grid cells; only the first window) ---\n'
      printf 'window-width = %s\n'  "$WINDOW_WIDTH"
      printf 'window-height = %s\n' "$WINDOW_HEIGHT"
    fi
    printf '\n# --- Appearance / common settings ---\n'
    printf 'background-opacity = %s\n'      "$OPACITY"
    printf 'cursor-style = %s\n'            "$CURSOR_STYLE"
    printf 'cursor-style-blink = %s\n'      "$CURSOR_BLINK"
    printf 'window-padding-x = %s\n'        "$PADDING"
    printf 'window-padding-y = %s\n'        "$PADDING"
    printf 'mouse-hide-while-typing = %s\n' "$MOUSE_HIDE"
    printf 'copy-on-select = %s\n'          "$COPY_ON_SELECT"
    printf 'confirm-close-surface = %s\n'   "$CONFIRM_CLOSE"
    printf 'shell-integration = %s\n'       "$SHELL_INTEGRATION"
  } >"$tmp"
  if [[ -f "$_G_DROPIN" ]] && cmp -s "$tmp" "$_G_DROPIN"; then rm -f "$tmp"; return 0; fi
  backup_file "$_G_DROPIN"
  mv "$tmp" "$_G_DROPIN" || { rm -f "$tmp"; return 1; }
  log_info "Wrote managed Ghostty config -> $_G_DROPIN"
}

# Make sure the user's real config loads our drop-in, exactly once. Absolute path avoids any
# relative-resolution ambiguity (and the drop-in has no includes, so there is no cycle).
_ghostty_ensure_include() {
  mkdir -p "$_G_CFG_DIR"
  local inc="config-file = $_G_DROPIN"
  if [[ -f "$_G_CONFIG" ]] && grep -qxF -- "$inc" "$_G_CONFIG"; then
    return 0
  fi
  backup_file "$_G_CONFIG"
  append_once "$inc" "$_G_CONFIG"
  log_info "Linked the managed drop-in from $_G_CONFIG (config-file include)."
}

# If the selected font is one the kit manages and it isn't installed yet, install it via
# fonts.sh (best-effort, user-space, never sudo). The glyphs only matter where Ghostty runs.
_ghostty_ensure_font() {
  local fam="$1" key
  [[ -n "$fam" ]] || return 0
  key="$(_ghostty_font_kit_key "$fam")" || return 0
  local fonts="$KIT_SCRIPTS_DIR/fonts.sh"
  [[ -x "$fonts" ]] || return 0
  log_info "Ensuring the Nerd Font '$fam' is installed (fonts.sh $key)…"
  "$fonts" install "$key" || log_warn "Could not auto-install '$fam'; install it where Ghostty runs or it won't render."
}

# A short, honest note about where these settings take effect.
_ghostty_where_note() {
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; then
    log_warn "This is an SSH session. Ghostty is a desktop GUI terminal — these settings apply"
    log_warn "to a Ghostty running on a machine with a display, not to this remote shell."
  fi
}

# True iff we are in an SSH/headless session (no local Ghostty to signal).
_ghostty_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }

# Make config changes take effect immediately in any running Ghostty, with no manual key press.
# Ghostty reloads its config on SIGUSR2 (the same as pressing ctrl+shift+, / the reload_config
# action). IMPORTANT: only SIGUSR2 is safe — Ghostty crashes on any other signal — so we target
# ONLY processes whose command name is exactly `ghostty` (pgrep -x, matching comm, NEVER -f which
# would also match this very script's command line). Mechanism, best-effort, highest-value first:
#   1. the upstream systemd user service (type=notify-reload on apt/.deb installs): a clean
#      `systemctl reload --user com.mitchellh.ghostty.service` — preferred when that unit exists.
#   2. otherwise send SIGUSR2 to each exact-match `ghostty` PID (covers snap + any non-systemd run).
# Honest no-op over SSH/headless (there is no local Ghostty — _ghostty_where_note already says so)
# and when Ghostty isn't installed or isn't running. Fail-safe: any problem only warns, never aborts.
_ghostty_reload_running() {
  _ghostty_in_ssh && return 0
  status >/dev/null 2>&1 || return 0

  if have_cmd systemctl; then
    local unit
    for unit in com.mitchellh.ghostty.service app-com.mitchellh.ghostty.service; do
      if systemctl --user --quiet is-active "$unit" 2>/dev/null; then
        if systemctl --user reload "$unit" >/dev/null 2>&1; then
          log_info "Reloaded the running Ghostty (systemd user service) — changes are live."
          return 0
        fi
        break   # the unit exists but reload failed; fall through to the signal path
      fi
    done
  fi

  have_cmd pgrep || { log_info "Reload a running Ghostty with ctrl+shift+, to pick up the changes."; return 0; }
  local -a pids=()
  mapfile -t pids < <(pgrep -x ghostty 2>/dev/null || true)
  if (( ${#pids[@]} == 0 )); then
    log_info "No running Ghostty found — changes apply next time you open Ghostty."
    return 0
  fi
  # kill accepts all PIDs at once; -USR2 is the ONLY signal Ghostty handles for reload.
  if kill -USR2 "${pids[@]}" 2>/dev/null; then
    log_info "Reloaded the running Ghostty (SIGUSR2) — changes are live."
  else
    log_warn "Could not signal the running Ghostty — reload it with ctrl+shift+, to apply the changes."
  fi
}

_ghostty_post_install() {
  log_info "Installed Ghostty ($(_ghostty_version 2>/dev/null | head -n1 || echo 'version unknown'))."
  log_info "Set the theme, font and defaults with:  swkit ghostty configure   (or open: swkit ghostty)"
  log_info "Config lives at ~/.config/ghostty/config; reload a running Ghostty with ctrl+shift+, ."
  _ghostty_where_note
}

# configure: apply any provided flags onto the saved preferences, then materialize the
# managed config (drop-in + include). With NO flags it writes the conservative baseline —
# safe to run on a fresh machine and idempotent on re-runs.
do_configure() {
  _ghostty_resolve_home || return 1
  _ghostty_load

  while (( $# > 0 )); do
    case "$1" in
      --theme)
        [[ $# -ge 2 ]] || { log_err "--theme needs a theme name (see: ghostty +list-themes)."; return 2; }
        THEME="$2"; shift 2 ;;
      --theme=*) THEME="${1#--theme=}"; shift ;;
      --font)
        [[ $# -ge 2 ]] || { log_err "--font needs a family name, or 'none' for the default."; return 2; }
        if [[ "$2" == none ]]; then FONT=""; else FONT="$2"; fi; shift 2 ;;
      --font=*)
        FONT="${1#--font=}"; [[ "$FONT" == none ]] && FONT=""; shift ;;
      --size)
        if [[ $# -lt 2 ]] || ! _ghostty_size_valid "${2:-}"; then log_err "--size needs an integer from 6 to 48."; return 2; fi
        FONT_SIZE="$2"; shift 2 ;;
      --window-size)
        if [[ $# -lt 2 ]] || ! _ghostty_parse_window_size "${2:-}"; then log_err "--window-size needs COLSxROWS (e.g. 120x36), or 'auto' to reset to the default."; return 2; fi
        shift 2 ;;
      --window-size=*)
        if ! _ghostty_parse_window_size "${1#--window-size=}"; then log_err "--window-size needs COLSxROWS (e.g. 120x36), or 'auto' to reset to the default."; return 2; fi
        shift ;;
      --window-width)
        if [[ $# -lt 2 ]] || ! _ghostty_cols_valid "${2:-}"; then log_err "--window-width needs columns from 10 to 1000."; return 2; fi
        WINDOW_WIDTH="$2"; shift 2 ;;
      --window-height)
        if [[ $# -lt 2 ]] || ! _ghostty_rows_valid "${2:-}"; then log_err "--window-height needs rows from 4 to 1000."; return 2; fi
        WINDOW_HEIGHT="$2"; shift 2 ;;
      --opacity)
        if [[ $# -lt 2 ]] || ! _ghostty_opacity_valid "${2:-}"; then log_err "--opacity needs a value from 0 to 1 (e.g. 0.95)."; return 2; fi
        OPACITY="$2"; shift 2 ;;
      --cursor)
        if [[ $# -lt 2 ]] || ! _ghostty_cursor_valid "${2:-}"; then log_err "--cursor needs one of: block bar underline."; return 2; fi
        CURSOR_STYLE="$2"; shift 2 ;;
      --padding)
        if [[ $# -lt 2 ]] || ! _ghostty_int_valid "${2:-}"; then log_err "--padding needs a non-negative integer."; return 2; fi
        PADDING="$2"; shift 2 ;;
      --blink)
        [[ $# -ge 2 ]] || { log_err "--blink needs on/off."; return 2; }
        CURSOR_BLINK="$(_ghostty_norm_bool "$2")" || { log_err "--blink needs on/off."; return 2; }
        shift 2 ;;
      --copy-on-select)
        [[ $# -ge 2 ]] || { log_err "--copy-on-select needs on/off."; return 2; }
        COPY_ON_SELECT="$(_ghostty_norm_bool "$2")" || { log_err "--copy-on-select needs on/off."; return 2; }
        shift 2 ;;
      --mouse-hide)
        [[ $# -ge 2 ]] || { log_err "--mouse-hide needs on/off."; return 2; }
        MOUSE_HIDE="$(_ghostty_norm_bool "$2")" || { log_err "--mouse-hide needs on/off."; return 2; }
        shift 2 ;;
      --confirm-close)
        [[ $# -ge 2 ]] || { log_err "--confirm-close needs on/off."; return 2; }
        CONFIRM_CLOSE="$(_ghostty_norm_bool "$2")" || { log_err "--confirm-close needs on/off."; return 2; }
        shift 2 ;;
      --shell-integration)
        [[ $# -ge 2 ]] || { log_err "--shell-integration needs a value (detect/none/bash/zsh/fish/elvish)."; return 2; }
        SHELL_INTEGRATION="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done

  _ghostty_validate_theme "$THEME"
  _ghostty_ensure_font "$FONT"
  # Ghostty ignores a lone window dimension — warn rather than silently drop it.
  if { [[ -n "$WINDOW_WIDTH" ]] && [[ -z "$WINDOW_HEIGHT" ]]; } || \
     { [[ -z "$WINDOW_WIDTH" ]] && [[ -n "$WINDOW_HEIGHT" ]]; }; then
    log_warn "Ghostty applies an initial window size only when BOTH width and height are set;"
    log_warn "with just one it uses the default. Set both, e.g.: ${0##*/} configure --window-size 120x36"
  fi

  _ghostty_save || { log_err "Failed to save preferences to $_G_PREF."; return 1; }
  _ghostty_write_dropin || { log_err "Failed to write the managed drop-in $_G_DROPIN."; return 1; }
  _ghostty_ensure_include || { log_err "Failed to update $_G_CONFIG."; return 1; }

  have_cmd ghostty || log_warn "Ghostty isn't installed yet; this config is staged and applies once you install it."
  _ghostty_reload_running
  _ghostty_where_note
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live config manager: theme / font / size / opacity / cursor / padding and a few toggles,
# plus install/remove. Every change shells out via ui_run (visible output + a log) and the
# screen reloads. Limited terminals fall back to the synthesized op menu.
ui() {
  _ghostty_resolve_home || { ui_default_menu; return 0; }
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    _ghostty_load
    local installed=0 ver="" is_def=0
    if status >/dev/null 2>&1; then installed=1; ver="$(_ghostty_version)"; fi
    if (( installed )) && _ghostty_is_default 2>/dev/null; then is_def=1; fi
    local font_disp="${FONT:-${UI_MUTED}$(_ghostty_t default_val)${UI_OFF}}"
    local wsize_disp
    if [[ -n "$WINDOW_WIDTH" && -n "$WINDOW_HEIGHT" ]]; then
      wsize_disp="${WINDOW_WIDTH}×${WINDOW_HEIGHT}"
    else
      wsize_disp="${UI_MUTED}$(_ghostty_t default_val)${UI_OFF}"
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    dkind+=(note); did+=(""); dlabel+=("$(_ghostty_t note)")
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(header); did+=(""); dlabel+=("$(_ghostty_t appearance)")
    dkind+=(theme);  did+=(theme);  dlabel+=("$(printf '%-16s %s%s%s  %s' "$(_ghostty_t theme)"  "$UI_INFO" "$THEME" "$UI_OFF" "$UI_ARROW")")
    dkind+=(font);   did+=(font);   dlabel+=("$(printf '%-16s %s  %s' "$(_ghostty_t font)"   "$font_disp" "$UI_ARROW")")
    dkind+=(size);   did+=(size);   dlabel+=("$(printf '%-16s %spt  %s' "$(_ghostty_t font_size)" "$FONT_SIZE" "$UI_ARROW")")
    dkind+=(opacity);did+=(opacity);dlabel+=("$(printf '%-16s %s  %s' "$(_ghostty_t opacity)" "$OPACITY" "$UI_ARROW")")
    dkind+=(cursor); did+=(cursor); dlabel+=("$(printf '%-16s %s  %s' "$(_ghostty_t cursor_style)" "$CURSOR_STYLE" "$UI_ARROW")")
    dkind+=(padding);did+=(padding);dlabel+=("$(printf '%-16s %s  %s' "$(_ghostty_t window_padding)" "$PADDING" "$UI_ARROW")")
    dkind+=(wsize);  did+=(wsize);  dlabel+=("$(printf '%-16s %s  %s' "$(_ghostty_t window_size)" "$wsize_disp" "$UI_ARROW")")
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(header); did+=(""); dlabel+=("$(_ghostty_t behavior)")
    dkind+=(toggle-copy);    did+=(copy);    dlabel+=("$(_ghostty_toggle_label "$(_ghostty_t copy_on_select)" "$COPY_ON_SELECT")")
    dkind+=(toggle-mouse);   did+=(mouse);   dlabel+=("$(_ghostty_toggle_label "$(_ghostty_t hide_mouse)"     "$MOUSE_HIDE")")
    dkind+=(toggle-confirm); did+=(confirm); dlabel+=("$(_ghostty_toggle_label "$(_ghostty_t confirm_close)"  "$CONFIRM_CLOSE")")
    dkind+=(toggle-blink);   did+=(blink);   dlabel+=("$(_ghostty_toggle_label "$(_ghostty_t cursor_blink)"   "$CURSOR_BLINK")")
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(apply);  did+=(apply);  dlabel+=("$(ui_badge check) $(_ghostty_t apply_now)")
    dkind+=(spacer); did+=(""); dlabel+=("")
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Ghostty")
    else
      if (( is_def )); then
        dkind+=(defterm); did+=(unset); dlabel+=("$(ui_badge on) $(_ghostty_t is_default)  ${UI_MUTED}($(_ghostty_t to_revert))${UI_OFF}")
      else
        dkind+=(defterm); did+=(set);   dlabel+=("$(ui_badge off) $(_ghostty_t set_default)")
      fi
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove);  did+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Ghostty")
    fi

    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in note|spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Ghostty · terminal" "${ver:-installed} $(ui_badge installed)"
    else ui_header "Ghostty · terminal" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        note)   ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_MUTED" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_ghostty_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          theme)
            ui_pick "$(_ghostty_t pick_theme)" "$(_ghostty_t current) $THEME" "" -- \
              "dark:Catppuccin Mocha,light:Catppuccin Latte" "$(_ghostty_t theme_auto)" \
              "Catppuccin Mocha" "Catppuccin Mocha" \
              "Catppuccin Macchiato" "Catppuccin Macchiato" \
              "Catppuccin Frappe" "Catppuccin Frappe" \
              "Catppuccin Latte" "$(_ghostty_t theme_latte)" \
              "Dracula" "Dracula" "Nord" "Nord" \
              "Solarized Dark" "Solarized Dark" "Solarized Light" "Solarized Light" \
              "Tokyo Night" "Tokyo Night" \
              "__custom__" "$(_ghostty_t type_theme)"
            if [[ -n "$UI_PICK" ]]; then
              if [[ "$UI_PICK" == "__custom__" ]]; then
                ui_input "$(_ghostty_t prompt_theme)" "$THEME" && \
                  [[ -n "$UI_INPUT" ]] && ui_run "configure theme · ghostty" -- "$0" configure --theme "$UI_INPUT"
              else
                ui_run "configure theme · ghostty" -- "$0" configure --theme "$UI_PICK"
              fi
            fi ;;
          font)
            ui_pick "$(_ghostty_t pick_font)" "$(_ghostty_t current) ${FONT:-$(_ghostty_t default_val)}" "" -- \
              "MesloLGS NF" "$(_ghostty_t font_p10k)" \
              "JetBrainsMono Nerd Font" "JetBrainsMono Nerd Font" \
              "FiraCode Nerd Font" "FiraCode Nerd Font" \
              "Hack Nerd Font" "Hack Nerd Font" \
              "none" "$(_ghostty_t font_system)" \
              "__custom__" "$(_ghostty_t type_font)"
            if [[ -n "$UI_PICK" ]]; then
              if [[ "$UI_PICK" == "__custom__" ]]; then
                ui_input "$(_ghostty_t prompt_font)" "$FONT" && \
                  ui_run "configure font · ghostty" -- "$0" configure --font "${UI_INPUT:-none}"
              else
                ui_run "configure font · ghostty" -- "$0" configure --font "$UI_PICK"
              fi
            fi ;;
          size)
            if ui_input "$(_ghostty_t prompt_size)" "$FONT_SIZE"; then
              [[ -n "$UI_INPUT" ]] && ui_run "configure size · ghostty" -- "$0" configure --size "$UI_INPUT"
            fi ;;
          opacity)
            if ui_input "$(_ghostty_t prompt_opacity)" "$OPACITY"; then
              [[ -n "$UI_INPUT" ]] && ui_run "configure opacity · ghostty" -- "$0" configure --opacity "$UI_INPUT"
            fi ;;
          cursor)
            ui_pick "$(_ghostty_t pick_cursor)" "$(_ghostty_t current) $CURSOR_STYLE" "" -- \
              block "block" bar "bar" underline "underline"
            [[ -n "$UI_PICK" ]] && ui_run "configure cursor · ghostty" -- "$0" configure --cursor "$UI_PICK" ;;
          padding)
            if ui_input "$(_ghostty_t prompt_padding)" "$PADDING"; then
              [[ -n "$UI_INPUT" ]] && ui_run "configure padding · ghostty" -- "$0" configure --padding "$UI_INPUT"
            fi ;;
          wsize)
            local cur=""
            [[ -n "$WINDOW_WIDTH" && -n "$WINDOW_HEIGHT" ]] && cur="${WINDOW_WIDTH}x${WINDOW_HEIGHT}"
            if ui_input "$(_ghostty_t prompt_wsize)" "$cur"; then
              ui_run "configure window size · ghostty" -- "$0" configure --window-size "${UI_INPUT:-auto}"
            fi ;;
          toggle-copy)    ui_run "toggle copy-on-select · ghostty" -- "$0" configure --copy-on-select "$(_ghostty_flip "$COPY_ON_SELECT")" ;;
          toggle-mouse)   ui_run "toggle mouse-hide · ghostty"     -- "$0" configure --mouse-hide "$(_ghostty_flip "$MOUSE_HIDE")" ;;
          toggle-confirm) ui_run "toggle confirm-close · ghostty"  -- "$0" configure --confirm-close "$(_ghostty_flip "$CONFIRM_CLOSE")" ;;
          toggle-blink)   ui_run "toggle cursor-blink · ghostty"   -- "$0" configure --blink "$(_ghostty_flip "$CURSOR_BLINK")" ;;
          apply)   ui_run "apply config · ghostty" -- "$0" configure ;;
          defterm)
            if [[ "${did[$sel]}" == "unset" ]]; then
              ui_run "unset default terminal · ghostty" -- "$0" default-terminal off
            else
              ui_run "set default terminal · ghostty" -- "$0" default-terminal
            fi ;;
          install) ui_run "$(ui_t install) Ghostty" -- "$0" install ;;
          remove)  ui_confirm "$(_ghostty_t confirm_remove)" n && ui_run "$(ui_t remove) Ghostty" -- "$0" remove ;;
        esac ;;
      q|Q|esc|backspace) break ;;
    esac
  done
  ui_end
  return 0
}

# "on"/"off" -> the opposite, for toggle rows.
_ghostty_flip() { case "$1" in true) printf 'off' ;; *) printf 'on' ;; esac; }

# A toggle row label: name + colored ●/○ + on/off.
_ghostty_toggle_label() {
  local name="$1" val="$2"
  if [[ "$val" == "true" ]]; then
    printf '%-18s %s %son%s' "$name" "$(ui_badge on)" "$UI_OK" "$UI_OFF"
  else
    printf '%-18s %s %soff%s' "$name" "$(ui_badge off)" "$UI_MUTED" "$UI_OFF"
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Ghostty — fast, GPU-accelerated terminal emulator. Installs via apt (Ubuntu 26.04+), else
the community .deb (mkasberg/ghostty-ubuntu) on 24.04/25.10, else snap. Configuration is
written to a managed drop-in (~/.config/ghostty/ubuntu-setup) and included from your real
~/.config/ghostty/config — your own settings there are preserved.

  install            Install Ghostty (idempotent; logs the channel used)
  remove             Uninstall Ghostty (keeps ~/.config/ghostty)
  configure [opts]   Set theme/font/defaults; with NO opts writes the conservative baseline.
                       --theme <name>          a Ghostty theme (see: ghostty +list-themes;
                                               also accepts "dark:Name,light:Name")
                       --font <family|none>    font family (e.g. "MesloLGS NF"); known Nerd
                                               Fonts are auto-installed via fonts.sh
                       --size <6-48>           font size in points
                       --window-size <CxR|auto>  initial window size in grid cells
                                               (e.g. 120x36; 'auto' resets to the default)
                       --window-width <10-1000>  initial columns (needs --window-height too)
                       --window-height <4-1000>  initial rows (needs --window-width too)
                       --opacity <0-1>         background opacity (needs a compositor)
                       --cursor <block|bar|underline>
                       --padding <px>          window padding (x and y)
                       --blink <on|off>            cursor blink
                       --copy-on-select <on|off>
                       --mouse-hide <on|off>       hide mouse while typing
                       --confirm-close <on|off>
                       --shell-integration <detect|none|bash|zsh|fish|elvish>
  default-terminal [off]
                     Make Ghostty the default terminal (or revert with 'off'). Writes the
                     user-scope xdg-terminal-exec selector (GNOME 25.04+ Ctrl+Alt+T /
                     "Open Terminal"); best-effort also registers the system
                     x-terminal-emulator alternative on a .deb/apt install (needs sudo;
                     skipped for snap). Desktop-only — honest no-op on a headless server.
  status             Print the version if installed; exit 0 iff installed
  ui                 Open the interactive manager (needs a terminal)
  meta               Print machine-readable metadata (for the TUI / swkit list)
  help               Show this help

Note: Ghostty is a desktop GUI terminal — over SSH these settings apply where Ghostty runs
(a machine with a display), and font glyphs are rendered by that terminal.
EOF
}

kit_dispatch "$@"
