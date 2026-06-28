#!/usr/bin/env bash
#
# scripts/fonts.sh — install / apply / manage Nerd Fonts on Ubuntu, USER-SPACE.
#
# A small font manager for the glyphs that modern prompts (Powerlevel10k, Starship) and
# many TUIs/editors need. Fonts install into ~/.local/share/fonts (NEVER via sudo) and the
# fontconfig cache is refreshed, so any local-display app picks them up immediately.
#
# IMPORTANT (the honest part): over SSH, glyphs are rendered by your LOCAL terminal — the
# machine you connect FROM — not by the server. Installing a font on a headless box only
# helps local-display/desktop use; for SSH you must also install/select the font in your
# client terminal. install/apply print exactly that, tailored to whether you're on SSH.
#
# Actions (kit_dispatch routes <op> -> do_<op>):
#   install [name]                 install a font (default: meslolgs — the P10k font)
#   remove  [name]                 remove a managed font
#   apply   [name] [size] [target] install if needed, then apply to supported local targets
#   configure [--font n] [--size n] [--target t] [--no-apply]
#                                  save defaults and optionally apply them
#   status           exit 0 iff the flagship MesloLGS NF is installed; list installed ones
#   ui               interactive font manager (needs a terminal)
#
# Known names: meslolgs jetbrains-mono firacode hack
# Apply targets: auto ptyxis gnome-terminal gnome-desktop instructions

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# MesloLGS NF (Powerlevel10k's recommended font) ships as four loose TTFs in this repo —
# the exact files p10k itself points at. Other Nerd Fonts come as release zips.
readonly P10K_MEDIA="https://github.com/romkatv/powerlevel10k-media/raw/master"
readonly NERD_FONTS_BASE="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
readonly FONTS_KNOWN="meslolgs jetbrains-mono firacode hack"
readonly FONTS_TARGETS="auto ptyxis gnome-terminal gnome-desktop instructions"
readonly FONTS_DEFAULT_NAME="meslolgs"
readonly FONTS_DEFAULT_SIZE="12"
readonly FONTS_DEFAULT_TARGET="auto"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. Proper nouns stay UNtranslated: font
# family names (MesloLGS NF, …), terminal names (Ptyxis / GNOME Terminal), target KEYS
# (auto/ptyxis/…). Only descriptive/operational wording is localized — including the apply
# target *labels* (target:*), which ui()/configure render from here. Resolve with _fonts_t KEY.
declare -gA FONTS_I18N
# Rows / headers / status tags / hints
FONTS_I18N[en:note]="Apply writes user-level local terminal settings; over SSH, configure the client terminal too."
FONTS_I18N[en:selected]="Selected"
FONTS_I18N[en:size]="Size"
FONTS_I18N[en:apply_to]="Apply to"
FONTS_I18N[en:apply_selected]="Apply selected font"
FONTS_I18N[en:installed_fonts]="Installed fonts"
FONTS_I18N[en:tag_selected]="selected"
FONTS_I18N[en:foot_main]="↑↓ move   ↵/space edit·toggle   a apply   esc/q close"
# Prompts / pickers / confirms
FONTS_I18N[en:current]="current:"
FONTS_I18N[en:pick_font]="Nerd Fonts — selected font"
FONTS_I18N[en:prompt_size]="font size (6-48)"
FONTS_I18N[en:pick_target]="Nerd Fonts — apply target"
FONTS_I18N[en:confirm_remove]="Remove {X}?"
# Apply-target labels
FONTS_I18N[en:target:auto]="auto (detected local terminals)"
FONTS_I18N[en:target:auto_long]="auto (Ptyxis / GNOME Terminal / GNOME desktop if detected)"
FONTS_I18N[en:target:gnome-desktop]="GNOME desktop monospace"
FONTS_I18N[en:target:instructions]="instructions only"

FONTS_I18N[zh:note]="应用会写入用户级的本地终端设置;SSH 时也要在客户端终端配置。"
FONTS_I18N[zh:selected]="已选字体"
FONTS_I18N[zh:size]="字号"
FONTS_I18N[zh:apply_to]="应用到"
FONTS_I18N[zh:apply_selected]="应用所选字体"
FONTS_I18N[zh:installed_fonts]="已安装字体"
FONTS_I18N[zh:tag_selected]="已选"
FONTS_I18N[zh:foot_main]="↑↓ 移动   ↵/space 编辑·切换   a 应用   esc/q 关闭"
FONTS_I18N[zh:current]="当前:"
FONTS_I18N[zh:pick_font]="Nerd Fonts — 选择字体"
FONTS_I18N[zh:prompt_size]="字号(6-48)"
FONTS_I18N[zh:pick_target]="Nerd Fonts — 应用目标"
FONTS_I18N[zh:confirm_remove]="移除 {X}?"
FONTS_I18N[zh:target:auto]="auto(检测到的本地终端)"
FONTS_I18N[zh:target:auto_long]="auto(若检测到 Ptyxis / GNOME Terminal / GNOME 桌面)"
FONTS_I18N[zh:target:gnome-desktop]="GNOME 桌面等宽字体"
FONTS_I18N[zh:target:instructions]="仅显示指引"

FONTS_I18N[ja:note]="適用はユーザーレベルのローカル端末設定を書き込みます。SSH 経由ではクライアント端末も設定してください。"
FONTS_I18N[ja:selected]="選択中"
FONTS_I18N[ja:size]="サイズ"
FONTS_I18N[ja:apply_to]="適用先"
FONTS_I18N[ja:apply_selected]="選択したフォントを適用"
FONTS_I18N[ja:installed_fonts]="インストール済みフォント"
FONTS_I18N[ja:tag_selected]="選択中"
FONTS_I18N[ja:foot_main]="↑↓ 移動   ↵/space 編集·切替   a 適用   esc/q 閉じる"
FONTS_I18N[ja:current]="現在:"
FONTS_I18N[ja:pick_font]="Nerd Fonts — フォントを選択"
FONTS_I18N[ja:prompt_size]="フォントサイズ(6-48)"
FONTS_I18N[ja:pick_target]="Nerd Fonts — 適用先"
FONTS_I18N[ja:confirm_remove]="{X} を削除しますか?"
FONTS_I18N[ja:target:auto]="auto(検出されたローカル端末)"
FONTS_I18N[ja:target:auto_long]="auto(Ptyxis / GNOME Terminal / GNOME デスクトップを検出した場合)"
FONTS_I18N[ja:target:gnome-desktop]="GNOME デスクトップの等幅"
FONTS_I18N[ja:target:instructions]="指示のみ"

# _fonts_t KEY — localized fonts string for $UI_LANG (en/zh/ja), fallback en -> key.
_fonts_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${FONTS_I18N[$lang:$1]:-${FONTS_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=fonts
name=Nerd Fonts
category=essentials
tags=cli
ops=install,remove,apply,configure
desc=Nerd Fonts (MesloLGS NF for Powerlevel10k/Starship, + JetBrainsMono/FiraCode/Hack) — user-space install + fc-cache + local terminal apply
META
}

# --- Font registry (curated) ---------------------------------------------------

# Human-facing family name (what you select in a terminal's font picker).
_font_family() {
  case "$1" in
    meslolgs)       printf 'MesloLGS NF' ;;
    jetbrains-mono) printf 'JetBrainsMono Nerd Font' ;;
    firacode)       printf 'FiraCode Nerd Font' ;;
    hack)           printf 'Hack Nerd Font' ;;
    *)              printf '%s' "$1" ;;
  esac
}

# Subdirectory under ~/.local/share/fonts for this font's files.
_font_dir_name() {
  case "$1" in
    meslolgs)       printf 'MesloLGS NF' ;;
    jetbrains-mono) printf 'JetBrainsMono' ;;
    firacode)       printf 'FiraCode' ;;
    hack)           printf 'Hack' ;;
    *)              printf '%s' "$1" ;;
  esac
}

# nerd-fonts release asset basename (without .zip) for the zip-distributed fonts.
_font_zip_asset() {
  case "$1" in
    jetbrains-mono) printf 'JetBrainsMono' ;;
    firacode)       printf 'FiraCode' ;;
    hack)           printf 'Hack' ;;
    *)              printf '%s' "$1" ;;
  esac
}

_font_known() { local n; for n in $FONTS_KNOWN; do [[ "$n" == "$1" ]] && return 0; done; return 1; }

_font_target_known() { local t; for t in $FONTS_TARGETS; do [[ "$t" == "$1" ]] && return 0; done; return 1; }

_font_target_label() {
  case "$1" in
    auto)           _fonts_t target:auto ;;
    ptyxis)         printf 'Ptyxis' ;;
    gnome-terminal) printf 'GNOME Terminal' ;;
    gnome-desktop)  _fonts_t target:gnome-desktop ;;
    instructions)   _fonts_t target:instructions ;;
    *)              printf '%s' "$1" ;;
  esac
}

_font_size_valid() {
  local n="$1"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  (( 10#$n >= 6 && 10#$n <= 48 ))
}

_font_spec() { printf '%s %s' "$(_font_family "$1")" "$2"; }

# --- Target user / home --------------------------------------------------------
# Sets _FONTS_HOME / _FONTS_DIR. Refuses a sudo-wrapped run so font files stay user-owned.
_fonts_resolve_home() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run font installation as your normal user, not via sudo — fonts install into"
    log_err "your ~/.local/share/fonts and must stay user-owned."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _FONTS_HOME="${HOME:-}"
  [[ -n "$_FONTS_HOME" ]] || _FONTS_HOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_FONTS_HOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _FONTS_DIR="$_FONTS_HOME/.local/share/fonts"
  _FONTS_CONFIG_DIR="$_FONTS_HOME/.config/ubuntu-setup"
  _FONTS_CONFIG="$_FONTS_CONFIG_DIR/fonts.conf"
}

_font_default_config() {
  FONT_SELECTED="$FONTS_DEFAULT_NAME"
  FONT_SIZE="$FONTS_DEFAULT_SIZE"
  FONT_TARGET="$FONTS_DEFAULT_TARGET"
}

_font_load_config() {
  _font_default_config
  [[ -f "${_FONTS_CONFIG:-}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      FONT)   _font_known "$val" && FONT_SELECTED="$val" ;;
      SIZE)   _font_size_valid "$val" && FONT_SIZE="$val" ;;
      TARGET) _font_target_known "$val" && FONT_TARGET="$val" ;;
    esac
  done <"$_FONTS_CONFIG"
}

_font_save_config() {
  local name="$1" size="$2" target="$3" tmp
  _font_known "$name" || { log_err "Unknown font '$name'. Known: $FONTS_KNOWN"; return 2; }
  _font_size_valid "$size" || { log_err "Invalid font size '$size'. Use an integer from 6 to 48."; return 2; }
  _font_target_known "$target" || { log_err "Unknown apply target '$target'. Known: $FONTS_TARGETS"; return 2; }

  mkdir -p "$_FONTS_CONFIG_DIR"
  tmp="$(mktemp)"
  {
    printf 'FONT=%s\n' "$name"
    printf 'SIZE=%s\n' "$size"
    printf 'TARGET=%s\n' "$target"
  } >"$tmp"
  if [[ -f "$_FONTS_CONFIG" ]] && cmp -s "$tmp" "$_FONTS_CONFIG"; then
    rm -f "$tmp"
    return 0
  fi
  backup_file "$_FONTS_CONFIG"
  if ! mv "$tmp" "$_FONTS_CONFIG"; then
    rm -f "$tmp"
    return 1
  fi
  log_info "Saved font preference: $(_font_family "$name") ${size}pt -> $(_font_target_label "$target")."
}

# Idempotency probe: observe the live filesystem, never a recorded flag.
_font_installed() {
  local name="$1" dir g
  dir="$_FONTS_DIR/$(_font_dir_name "$name")"
  case "$name" in
    meslolgs) [[ -f "$dir/MesloLGS NF Regular.ttf" ]] ;;
    *)        for g in "$dir"/*.ttf; do [[ -e "$g" ]] && return 0; done; return 1 ;;
  esac
}

# Exit 0 iff the flagship MesloLGS NF is installed; print every managed font that is.
status() {
  _fonts_resolve_home >/dev/null 2>&1 || return 1
  local name installed=""
  for name in $FONTS_KNOWN; do
    _font_installed "$name" && installed="${installed:+$installed }$name"
  done
  [[ -n "$installed" ]] && printf 'Nerd Fonts installed: %s\n' "$installed"
  if [[ -f "${_FONTS_CONFIG:-}" ]]; then
    _font_load_config
    printf 'Font preference: %s %spt -> %s\n' "$(_font_family "$FONT_SELECTED")" "$FONT_SIZE" "$(_font_target_label "$FONT_TARGET")"
  fi
  _font_installed meslolgs
}

# --- Download helpers ----------------------------------------------------------

_font_dl_meslolgs() {
  local dir="$1" style url
  for style in "Regular" "Bold" "Italic" "Bold Italic"; do
    url="$P10K_MEDIA/MesloLGS%20NF%20${style// /%20}.ttf"
    log_info "Downloading: $url"
    if ! curl -fsSL "$url" -o "$dir/MesloLGS NF $style.ttf"; then
      log_err "Failed to download 'MesloLGS NF $style' from $url"
      return 1
    fi
  done
}

_font_dl_zip() {
  local name="$1" dir="$2" asset url tmp rc=0
  asset="$(_font_zip_asset "$name")"
  url="$NERD_FONTS_BASE/$asset.zip"
  have_cmd unzip || apt_install unzip
  tmp="$(mktemp -d)"
  log_info "Downloading: $url"
  if ! curl -fsSL "$url" -o "$tmp/font.zip"; then
    rm -rf "$tmp"; log_err "Failed to download $asset Nerd Font from $url"; return 1
  fi
  # -j flattens any nested paths so TTFs land directly in $dir (matches _font_installed's probe).
  if ! unzip -o -j -q "$tmp/font.zip" '*.ttf' -d "$dir"; then
    log_err "Failed to extract TTFs from the $asset Nerd Font archive."; rc=1
  fi
  rm -rf "$tmp"
  return $rc
}

# --- Actions -------------------------------------------------------------------

do_install() {
  local name="${1:-meslolgs}"
  _fonts_resolve_home || return 1
  if ! _font_known "$name"; then
    log_err "Unknown font '$name'. Known: $FONTS_KNOWN"
    return 2
  fi
  if _font_installed "$name"; then
    log_info "$(_font_family "$name") already installed — skipping."
    _font_guidance "$name"
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates
  # fc-cache is best-effort: place the files even if fontconfig can't be installed here.
  if ! have_cmd fc-cache; then
    apt_install fontconfig || log_warn "Could not install fontconfig; font files will be placed but the cache won't refresh."
  fi
  local dir; dir="$_FONTS_DIR/$(_font_dir_name "$name")"
  mkdir -p "$dir"
  case "$name" in
    meslolgs) _font_dl_meslolgs "$dir" || return 1 ;;
    *)        _font_dl_zip "$name" "$dir" || return 1 ;;
  esac
  have_cmd fc-cache && fc-cache -f "$_FONTS_DIR" >/dev/null 2>&1 || true
  log_info "Installed $(_font_family "$name") into $dir."
  _font_guidance "$name"
  return 0
}

do_remove() {
  local name="${1:-meslolgs}"
  _fonts_resolve_home || return 1
  if ! _font_known "$name"; then
    log_err "Unknown font '$name'. Known: $FONTS_KNOWN"
    return 2
  fi
  if ! _font_installed "$name"; then
    log_info "$(_font_family "$name") is not installed — nothing to remove."
    return 0
  fi
  local dir; dir="$_FONTS_DIR/$(_font_dir_name "$name")"
  rm -rf "${dir:?}"
  have_cmd fc-cache && fc-cache -f "$_FONTS_DIR" >/dev/null 2>&1 || true
  log_info "Removed $(_font_family "$name") ($dir)."
}

_font_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }

_font_gsettings_has_schema() {
  have_cmd gsettings || return 3
  gsettings list-schemas 2>/dev/null | grep -Fxq "$1" || return 3
}

_font_gsettings_has_relocatable_schema() {
  have_cmd gsettings || return 3
  gsettings list-relocatable-schemas 2>/dev/null | grep -Fxq "$1" || return 3
}

_font_gvariant_unquote() {
  local s="$1"
  s="${s#\'}"
  s="${s%\'}"
  printf '%s' "$s"
}

_font_apply_ptyxis() {
  local spec="$1"
  _font_gsettings_has_schema org.gnome.Ptyxis || return 3
  if ! gsettings set org.gnome.Ptyxis use-system-font false; then
    log_warn "Could not switch Ptyxis away from the system font."
    return 1
  fi
  if ! gsettings set org.gnome.Ptyxis font-name "$spec"; then
    log_warn "Could not set Ptyxis font to '$spec'."
    return 1
  fi
  log_info "Applied '$spec' to Ptyxis."
}

_font_apply_gnome_terminal() {
  local spec="$1" raw uuid schema
  _font_gsettings_has_schema org.gnome.Terminal.ProfilesList || return 3
  _font_gsettings_has_relocatable_schema org.gnome.Terminal.Legacy.Profile || return 3
  if ! raw="$(gsettings get org.gnome.Terminal.ProfilesList default 2>/dev/null)"; then
    log_warn "Could not read the default GNOME Terminal profile."
    return 1
  fi
  uuid="$(_font_gvariant_unquote "$raw")"
  [[ -n "$uuid" && "$uuid" != "@as []" ]] || return 3
  schema="org.gnome.Terminal.Legacy.Profile:/org/gnome/terminal/legacy/profiles:/:$uuid/"
  if ! gsettings set "$schema" use-system-font false; then
    log_warn "Could not switch GNOME Terminal profile '$uuid' away from the system font."
    return 1
  fi
  if ! gsettings set "$schema" font "$spec"; then
    log_warn "Could not set GNOME Terminal profile '$uuid' font to '$spec'."
    return 1
  fi
  log_info "Applied '$spec' to GNOME Terminal profile '$uuid'."
}

_font_apply_gnome_desktop() {
  local spec="$1"
  _font_gsettings_has_schema org.gnome.desktop.interface || return 3
  if ! gsettings set org.gnome.desktop.interface monospace-font-name "$spec"; then
    log_warn "Could not set GNOME desktop monospace font to '$spec'."
    return 1
  fi
  log_info "Applied '$spec' to GNOME desktop monospace font."
}

_font_apply_target() {
  local target="$1" spec="$2"
  case "$target" in
    ptyxis)         _font_apply_ptyxis "$spec" ;;
    gnome-terminal) _font_apply_gnome_terminal "$spec" ;;
    gnome-desktop)  _font_apply_gnome_desktop "$spec" ;;
    *)              return 3 ;;
  esac
}

do_apply() {
  _fonts_resolve_home || return 1
  _font_load_config
  local name="${1:-$FONT_SELECTED}" size="${2:-$FONT_SIZE}" target="${3:-$FONT_TARGET}"
  _font_save_config "$name" "$size" "$target" || return $?

  if [[ "$target" == "instructions" ]]; then
    _font_guidance "$name"
    return 0
  fi

  if ! _font_installed "$name"; then
    log_info "$(_font_family "$name") is not installed; installing it before applying."
    do_install "$name"
  fi

  if _font_in_ssh; then
    log_warn "This is an SSH session; the visible glyphs are controlled by your client terminal."
    _font_guidance "$name"
    return 0
  fi

  local spec applied=0 failed=0 rc t
  spec="$(_font_spec "$name" "$size")"
  case "$target" in
    auto)
      for t in ptyxis gnome-terminal gnome-desktop; do
        if _font_apply_target "$t" "$spec"; then
          applied=1
        else
          rc=$?
          [[ $rc -eq 3 ]] || failed=1
        fi
      done
      if (( ! applied )); then
        if (( failed )); then
          log_err "Detected a local font target, but applying '$spec' failed."
          return 1
        fi
        log_warn "No supported local font target was detected for automatic apply."
        _font_guidance "$name"
        return 0
      fi
      (( failed )) && log_warn "Applied '$spec' to at least one target, but one target failed."
      ;;
    ptyxis|gnome-terminal|gnome-desktop)
      if _font_apply_target "$target" "$spec"; then
        :
      else
        rc=$?
        if [[ $rc -eq 3 ]]; then
          log_err "Apply target '$(_font_target_label "$target")' is not available on this machine."
        else
          log_err "Could not apply '$spec' to '$(_font_target_label "$target")'."
        fi
        return 1
      fi
      ;;
    *)
      log_err "Unknown apply target '$target'. Known: $FONTS_TARGETS"
      return 2
      ;;
  esac

  [[ "$name" == "meslolgs" ]] && log_info "Powerlevel10k users: run 'p10k configure' to pick a style for the new font."
}

do_configure() {
  _fonts_resolve_home || return 1
  _font_load_config
  local name="$FONT_SELECTED" size="$FONT_SIZE" target="$FONT_TARGET" apply=0
  while (( $# > 0 )); do
    case "$1" in
      --font)
        [[ $# -ge 2 ]] || { log_err "--font needs one of: $FONTS_KNOWN"; return 2; }
        name="$2"; shift 2 ;;
      --size)
        [[ $# -ge 2 ]] || { log_err "--size needs an integer from 6 to 48."; return 2; }
        size="$2"; shift 2 ;;
      --target)
        [[ $# -ge 2 ]] || { log_err "--target needs one of: $FONTS_TARGETS"; return 2; }
        target="$2"; shift 2 ;;
      --apply)
        apply=1; shift ;;
      --no-apply)
        apply=0; shift ;;
      -h|--help)
        usage; return 0 ;;
      *)
        log_err "Unknown configure option: $1"
        usage
        return 2 ;;
    esac
  done

  _font_save_config "$name" "$size" "$target" || return $?
  if (( apply )); then
    do_apply "$name" "$size" "$target"
  else
    log_info "Preference saved; run 'swkit fonts apply' when you want to apply it."
  fi
}

# Honest "apply" guidance: a font on the box only helps a LOCAL display; over SSH the
# glyphs come from the client terminal, so say so and point at the client.
_font_guidance() {
  local name="$1" fam hint_size="$FONTS_DEFAULT_SIZE"
  fam="$(_font_family "$name")"
  if [[ -n "${_FONTS_CONFIG:-}" ]]; then
    _font_load_config
    hint_size="$FONT_SIZE"
  fi
  log_info "Family name (select this in your terminal): '$fam'."
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; then
    log_warn "You're on an SSH session — glyphs are rendered by your LOCAL terminal, not the server."
    log_warn "Install/select '$fam' on the machine you connect FROM, then set it as that terminal's font."
    [[ "$name" == "meslolgs" ]] && \
      log_warn "  Download (4 files): $P10K_MEDIA/MesloLGS%20NF%20Regular.ttf  (Bold / Italic / Bold%20Italic too)"
  else
    log_info "Run 'swkit fonts apply $name $hint_size auto' to apply it to supported local GNOME terminals, or select '$fam' manually in your terminal preferences."
  fi
  [[ "$name" == "meslolgs" ]] && log_info "Powerlevel10k users: run 'p10k configure' to pick a style for the new font."
  return 0
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live font manager: choose a preferred font/size/apply target, apply it to supported
# local terminals, and still manage installation state as checkboxes. Limited terminals
# fall back to the synthesized op menu.
ui() {
  _fonts_resolve_home || return 1
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  local -a known=(meslolgs jetbrains-mono firacode hack)
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    _font_load_config

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    local selected="$FONT_SELECTED" size="$FONT_SIZE" target="$FONT_TARGET" selected_state
    if _font_installed "$selected" 2>/dev/null; then selected_state="$(ui_badge installed)"; else selected_state="$(ui_badge missing)"; fi
    dkind+=(note);   did+=(""); dlabel+=("$(_fonts_t note)")
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(select-font); did+=(select-font)
    dlabel+=("$(printf '%-13s %s %s%s%s  %s' "$(_fonts_t selected)" "$selected_state" "$UI_INFO" "$(_font_family "$selected")" "$UI_OFF" "$UI_ARROW")")
    dkind+=(size); did+=(size)
    dlabel+=("$(printf '%-13s %spt  %s' "$(_fonts_t size)" "$size" "$UI_ARROW")")
    dkind+=(target); did+=(target)
    dlabel+=("$(printf '%-13s %s  %s' "$(_fonts_t apply_to)" "$(_font_target_label "$target")" "$UI_ARROW")")
    dkind+=(apply); did+=(apply)
    dlabel+=("$(ui_badge check) $(_fonts_t apply_selected)")
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(header); did+=(""); dlabel+=("$(_fonts_t installed_fonts)")
    local f fam on
    for f in "${known[@]}"; do
      local mark=""
      fam="$(_font_family "$f")"
      on=0; _font_installed "$f" 2>/dev/null && on=1
      [[ "$f" == "$selected" ]] && mark=" ${UI_INFO}($(_fonts_t tag_selected))${UI_OFF}"
      dkind+=(font); did+=("$f")
      if (( on )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $fam$mark")
      else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $fam$mark"); fi
    done
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in note|spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    ui_header "Nerd Fonts · font manager" "$(_font_family "$selected") ${size}pt"
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
    ui_footer "$(_fonts_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      a|A)    ui_run "apply $selected · fonts" -- "$0" apply "$selected" "$size" "$target" ;;
      enter|space)
        case "${dkind[$sel]}" in
          select-font)
            ui_pick "$(_fonts_t pick_font)" "$(_fonts_t current) $(_font_family "$selected")" "" -- \
              meslolgs "MesloLGS NF" jetbrains-mono "JetBrainsMono Nerd Font" \
              firacode "FiraCode Nerd Font" hack "Hack Nerd Font"
            [[ -n "$UI_PICK" ]] && ui_run "configure font $UI_PICK · fonts" -- "$0" configure --font "$UI_PICK" --no-apply ;;
          size)
            if ui_input "$(_fonts_t prompt_size)" "$size"; then
              [[ -n "$UI_INPUT" ]] && ui_run "configure size $UI_INPUT · fonts" -- "$0" configure --size "$UI_INPUT" --no-apply
            fi ;;
          target)
            ui_pick "$(_fonts_t pick_target)" "$(_fonts_t current) $(_font_target_label "$target")" "" -- \
              auto "$(_fonts_t target:auto_long)" \
              ptyxis "Ptyxis" gnome-terminal "GNOME Terminal" \
              gnome-desktop "$(_fonts_t target:gnome-desktop)" instructions "$(_fonts_t target:instructions)"
            [[ -n "$UI_PICK" ]] && ui_run "configure target $UI_PICK · fonts" -- "$0" configure --target "$UI_PICK" --no-apply ;;
          apply)
            ui_run "apply $selected · fonts" -- "$0" apply "$selected" "$size" "$target" ;;
          font)
            local fk="${did[$sel]}"
            if _font_installed "$fk" 2>/dev/null; then
              local _rm_q; _rm_q="$(_fonts_t confirm_remove)"; _rm_q="${_rm_q//\{X\}/$(_font_family "$fk")}"
              ui_confirm "$_rm_q" n && ui_run "remove $fk · fonts" -- "$0" remove "$fk"
            else
              ui_run "install $fk · fonts" -- "$0" install "$fk"
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

Nerd Font manager (user-space: installs into ~/.local/share/fonts + refreshes fc-cache,
never via sudo). Glyphs render in your LOCAL terminal — over SSH, install/select the font
in your client terminal too (install/status prints the details).

  install [name]   Install a font (default: meslolgs). Known names:
                     meslolgs        MesloLGS NF (Powerlevel10k's recommended font; Starship too)
                     jetbrains-mono  JetBrainsMono Nerd Font
                     firacode        FiraCode Nerd Font
                     hack            Hack Nerd Font
  remove [name]    Remove a managed font (default: meslolgs)
  apply [name] [size] [target]
                   Install the font if needed, save the preference, then apply it.
                   Defaults come from ~/.config/ubuntu-setup/fonts.conf, or:
                     meslolgs 12 auto
                   Targets: auto, ptyxis, gnome-terminal, gnome-desktop, instructions
  configure [opts] Save font preferences; add --apply to apply immediately:
                     --font <name>     --size <6-48>     --target <target>
                     --apply           --no-apply
  status           Print installed managed fonts; exit 0 iff MesloLGS NF is installed
  ui               Open the interactive font manager (needs a terminal)
  meta / help
EOF
}

kit_dispatch "$@"
