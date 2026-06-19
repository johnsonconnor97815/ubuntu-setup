#!/usr/bin/env bash
#
# scripts/rime.sh — install / configure / manage the RIME input method (on fcitx5) on Ubuntu.
#
# RIME (https://rime.im) is a highly-configurable input method engine for Chinese / CJK.
# On Ubuntu it rides on the fcitx5 input-method framework (the community-preferred carrier).
# This script is a *component manager* (like scripts/zsh.sh / scripts/tmux.sh): it installs
# fcitx5 + the RIME engine + frontends, selects the framework, writes the environment that
# lets apps talk to fcitx5, and manages which RIME schemas (输入方案) are enabled — with an
# opt-in for the popular 雾凇拼音 (rime-ice) config. Everything is user-space; only apt needs
# root (escalated per-command via the shared library), never whole-root, never `sudo npm`.
#
# Install channels: apt only (fcitx5 + RIME are in the official Ubuntu repos).
#
# Configuration model (mirrors scripts/ghostty.sh's managed drop-in):
#   - Preferences live in ~/.config/ubuntu-setup/rime.conf (the kit's KEY=VALUE store).
#   - From them we regenerate a managed RIME patch ~/.local/share/fcitx5/rime/default.custom.yaml
#     (we own it; rewritten wholesale + convergent; backed up before the first overwrite).
#   - The fcitx5 input-method environment is a managed file we own too:
#     ~/.config/environment.d/ubuntu-setup-rime.conf (GTK/QT/XMODIFIERS).
#   - A managed XDG autostart entry ~/.config/autostart/org.fcitx.Fcitx5.desktop launches
#     fcitx5 at login. This is REQUIRED on Wayland (Ubuntu's default): im-config/im-launch
#     only starts the IM daemon for X11 sessions (its Wayland branch is disabled) and the
#     fcitx5 package ships no /etc/xdg/autostart entry — so without it nothing starts fcitx5
#     and the desktop keeps falling back to its built-in IBus.
#
# Honesty note: RIME/fcitx5 is a *desktop* input method. Over SSH / on a headless server you
# are not running a graphical session on this box — these settings apply where the desktop
# actually runs (a machine with a display), and take effect after the next login. install /
# configure / deploy say so when they detect an SSH session or no display.
#
# Run it as:  rime.sh install|remove|configure|deploy|status|ui|meta|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- Curated knowledge ---------------------------------------------------------
readonly _RIME_ICE_REPO="https://github.com/iDvel/rime-ice.git"
# fcitx5-rime bundles rime-data (brise), so these schemas need no extra download.
readonly _RIME_CURATED=(
  luna_pinyin_simp luna_pinyin luna_pinyin_fluency
  double_pinyin_flypy double_pinyin bopomofo
  wubi86 wubi_pinyin cangjie5 stroke terra_pinyin
)

# One-line schema descriptions, localized (en/zh/ja). Same shape as scripts/tmux.sh's
# TMUX_I18N: schema *names* are never translated (project rule), only the gloss.
declare -gA RIME_I18N
RIME_I18N[en:luna_pinyin_simp]="Pinyin (朙月拼音) — simplified output"
RIME_I18N[en:luna_pinyin]="Pinyin (朙月拼音) — trad./simp. per dict"
RIME_I18N[en:luna_pinyin_fluency]="Sentence-flow Pinyin (语句流)"
RIME_I18N[en:double_pinyin_flypy]="Xiaohe double pinyin (小鹤双拼)"
RIME_I18N[en:double_pinyin]="Ziranma double pinyin (自然码)"
RIME_I18N[en:bopomofo]="Bopomofo / Zhuyin (注音)"
RIME_I18N[en:wubi86]="Wubi 86 (五笔)"
RIME_I18N[en:wubi_pinyin]="Wubi + Pinyin (五笔·拼音)"
RIME_I18N[en:cangjie5]="Cangjie 5 (仓颉)"
RIME_I18N[en:stroke]="Stroke order (五笔画)"
RIME_I18N[en:terra_pinyin]="Terra Pinyin with tones (地球拼音)"
RIME_I18N[zh:luna_pinyin_simp]="朙月拼音 · 简体输出"
RIME_I18N[zh:luna_pinyin]="朙月拼音 · 繁简随词库"
RIME_I18N[zh:luna_pinyin_fluency]="语句流(整句拼音)"
RIME_I18N[zh:double_pinyin_flypy]="小鹤双拼"
RIME_I18N[zh:double_pinyin]="自然码双拼"
RIME_I18N[zh:bopomofo]="注音"
RIME_I18N[zh:wubi86]="五笔 86"
RIME_I18N[zh:wubi_pinyin]="五笔·拼音混合"
RIME_I18N[zh:cangjie5]="仓颉五代"
RIME_I18N[zh:stroke]="五笔画(笔顺)"
RIME_I18N[zh:terra_pinyin]="地球拼音(带声调)"
RIME_I18N[ja:luna_pinyin_simp]="拼音(朙月)· 簡体字出力"
RIME_I18N[ja:luna_pinyin]="拼音(朙月)· 繁簡混在"
RIME_I18N[ja:luna_pinyin_fluency]="文流入力(整文拼音)"
RIME_I18N[ja:double_pinyin_flypy]="小鶴双拼"
RIME_I18N[ja:double_pinyin]="自然碼双拼"
RIME_I18N[ja:bopomofo]="注音"
RIME_I18N[ja:wubi86]="五筆 86"
RIME_I18N[ja:wubi_pinyin]="五筆・拼音混合"
RIME_I18N[ja:cangjie5]="倉頡五代"
RIME_I18N[ja:stroke]="筆画入力"
RIME_I18N[ja:terra_pinyin]="地球拼音(声調付き)"

# ui() chrome (ubuntu-setup): headers, notes, row labels, prompts, confirms, run titles.
RIME_I18N[en:ui_ssh_note]="Desktop input method — over SSH/headless these apply where the desktop runs, after re-login."
RIME_I18N[en:ui_sec_engine]="Engine"
RIME_I18N[en:ui_im_environment]="IM environment"
RIME_I18N[en:ui_state_on]="on"
RIME_I18N[en:ui_state_missing]="missing"
RIME_I18N[en:ui_fcitx5_autostart]="fcitx5 autostart"
RIME_I18N[en:ui_rime_engine]="RIME engine"
RIME_I18N[en:ui_sec_schemas]="Schemas"
RIME_I18N[en:ui_ice_owns_schemas]="雾凇拼音 (rime-ice) is active and owns the schema list — remove it to manage schemas here."
RIME_I18N[en:ui_add_schema_row]="add another schema by id…"
RIME_I18N[en:ui_sec_options]="Options"
RIME_I18N[en:ui_candidates_per_page]="Candidates per page"
RIME_I18N[en:ui_ice_remove_row]="installed — remove rime-ice"
RIME_I18N[en:ui_ice_install_row]="install rime-ice (batteries-included config)"
RIME_I18N[en:ui_sec_actions]="Actions"
RIME_I18N[en:ui_deploy_now]="Deploy now (apply config)"
RIME_I18N[en:ui_apply_recommended]="Apply recommended setup"
RIME_I18N[en:ui_footer_hints]="↑↓ move   space toggle   d default   a add   ↵ edit/run   esc/q close"
RIME_I18N[en:ui_run_disable_schema]="disable schema"
RIME_I18N[en:ui_run_enable_schema]="enable schema"
RIME_I18N[en:ui_run_set_default_schema]="set default schema"
RIME_I18N[en:ui_run_add_schema]="add schema"
RIME_I18N[en:ui_prompt_schema_id]="schema id to enable (e.g. bopomofo, wubi86)"
RIME_I18N[en:ui_confirm_remove_engine]="Uninstall the RIME engine? (fcitx5 and your data are kept)"
RIME_I18N[en:ui_prompt_page_size]="candidates per page (5-10)"
RIME_I18N[en:ui_run_set_page_size]="set page size"
RIME_I18N[en:ui_confirm_install_ice]="Install 雾凇拼音 (rime-ice)? Clones a config repo from GitHub."
RIME_I18N[en:ui_run_install_ice]="install rime-ice"
RIME_I18N[en:ui_confirm_remove_ice]="Remove rime-ice and restore the built-in schemas?"
RIME_I18N[en:ui_run_remove_ice]="remove rime-ice"
RIME_I18N[en:ui_run_deploy]="deploy"
RIME_I18N[en:ui_run_apply_recommended]="apply recommended"
RIME_I18N[zh:ui_ssh_note]="桌面输入法 —— 经 SSH/无头时这些设置在运行桌面的机器上生效,需重新登录。"
RIME_I18N[zh:ui_sec_engine]="引擎"
RIME_I18N[zh:ui_im_environment]="输入法环境"
RIME_I18N[zh:ui_state_on]="已启用"
RIME_I18N[zh:ui_state_missing]="缺失"
RIME_I18N[zh:ui_fcitx5_autostart]="fcitx5 自启动"
RIME_I18N[zh:ui_rime_engine]="RIME 引擎"
RIME_I18N[zh:ui_sec_schemas]="输入方案"
RIME_I18N[zh:ui_ice_owns_schemas]="雾凇拼音 (rime-ice) 已启用并接管方案列表 —— 移除它才能在此管理方案。"
RIME_I18N[zh:ui_add_schema_row]="按 id 添加其他方案…"
RIME_I18N[zh:ui_sec_options]="选项"
RIME_I18N[zh:ui_candidates_per_page]="每页候选词数"
RIME_I18N[zh:ui_ice_remove_row]="已安装 —— 移除 rime-ice"
RIME_I18N[zh:ui_ice_install_row]="安装 rime-ice(开箱即用配置)"
RIME_I18N[zh:ui_sec_actions]="操作"
RIME_I18N[zh:ui_deploy_now]="立即部署(应用配置)"
RIME_I18N[zh:ui_apply_recommended]="应用推荐设置"
RIME_I18N[zh:ui_footer_hints]="↑↓ 移动   space 切换   d 设默认   a 添加   ↵ 编辑/运行   esc/q 关闭"
RIME_I18N[zh:ui_run_disable_schema]="禁用方案"
RIME_I18N[zh:ui_run_enable_schema]="启用方案"
RIME_I18N[zh:ui_run_set_default_schema]="设默认方案"
RIME_I18N[zh:ui_run_add_schema]="添加方案"
RIME_I18N[zh:ui_prompt_schema_id]="要启用的方案 id(如 bopomofo、wubi86)"
RIME_I18N[zh:ui_confirm_remove_engine]="卸载 RIME 引擎?(保留 fcitx5 与你的数据)"
RIME_I18N[zh:ui_prompt_page_size]="每页候选词数(5-10)"
RIME_I18N[zh:ui_run_set_page_size]="设置每页候选数"
RIME_I18N[zh:ui_confirm_install_ice]="安装 雾凇拼音 (rime-ice)?将从 GitHub 克隆一个配置仓库。"
RIME_I18N[zh:ui_run_install_ice]="安装 rime-ice"
RIME_I18N[zh:ui_confirm_remove_ice]="移除 rime-ice 并恢复内置方案?"
RIME_I18N[zh:ui_run_remove_ice]="移除 rime-ice"
RIME_I18N[zh:ui_run_deploy]="部署"
RIME_I18N[zh:ui_run_apply_recommended]="应用推荐"
RIME_I18N[ja:ui_ssh_note]="デスクトップ入力メソッド — SSH/ヘッドレスではデスクトップが動くマシンで再ログイン後に有効になります。"
RIME_I18N[ja:ui_sec_engine]="エンジン"
RIME_I18N[ja:ui_im_environment]="IM 環境"
RIME_I18N[ja:ui_state_on]="有効"
RIME_I18N[ja:ui_state_missing]="なし"
RIME_I18N[ja:ui_fcitx5_autostart]="fcitx5 自動起動"
RIME_I18N[ja:ui_rime_engine]="RIME エンジン"
RIME_I18N[ja:ui_sec_schemas]="入力スキーマ(输入方案)"
RIME_I18N[ja:ui_ice_owns_schemas]="雾凇拼音 (rime-ice) が有効でスキーマ一覧を管理しています — ここで管理するには先に削除してください。"
RIME_I18N[ja:ui_add_schema_row]="id でほかのスキーマを追加…"
RIME_I18N[ja:ui_sec_options]="オプション"
RIME_I18N[ja:ui_candidates_per_page]="1 ページの候補数"
RIME_I18N[ja:ui_ice_remove_row]="インストール済み — rime-ice を削除"
RIME_I18N[ja:ui_ice_install_row]="rime-ice をインストール(設定込み)"
RIME_I18N[ja:ui_sec_actions]="操作"
RIME_I18N[ja:ui_deploy_now]="今すぐデプロイ(設定を適用)"
RIME_I18N[ja:ui_apply_recommended]="推奨設定を適用"
RIME_I18N[ja:ui_footer_hints]="↑↓ 移動   space 切替   d 既定   a 追加   ↵ 編集/実行   esc/q 閉じる"
RIME_I18N[ja:ui_run_disable_schema]="スキーマを無効化"
RIME_I18N[ja:ui_run_enable_schema]="スキーマを有効化"
RIME_I18N[ja:ui_run_set_default_schema]="既定スキーマを設定"
RIME_I18N[ja:ui_run_add_schema]="スキーマを追加"
RIME_I18N[ja:ui_prompt_schema_id]="有効化するスキーマ id(例: bopomofo、wubi86)"
RIME_I18N[ja:ui_confirm_remove_engine]="RIME エンジンをアンインストールしますか?(fcitx5 とデータは保持されます)"
RIME_I18N[ja:ui_prompt_page_size]="1 ページの候補数(5-10)"
RIME_I18N[ja:ui_run_set_page_size]="ページ候補数を設定"
RIME_I18N[ja:ui_confirm_install_ice]="雾凇拼音 (rime-ice) をインストールしますか?GitHub から設定リポジトリを clone します。"
RIME_I18N[ja:ui_run_install_ice]="rime-ice をインストール"
RIME_I18N[ja:ui_confirm_remove_ice]="rime-ice を削除して内蔵スキーマを復元しますか?"
RIME_I18N[ja:ui_run_remove_ice]="rime-ice を削除"
RIME_I18N[ja:ui_run_deploy]="デプロイ"
RIME_I18N[ja:ui_run_apply_recommended]="推奨を適用"

# Gloss for a schema id, in the active UI language (English fallback, then the id itself).
_rime_schema_desc() {
  local lang="${UI_LANG:-en}" key="$1"
  case "$lang" in en|zh|ja) ;; *) lang="en" ;; esac
  printf '%s' "${RIME_I18N[$lang:$key]:-${RIME_I18N[en:$key]:-$key}}"
}

# _rime_t KEY — localized UI-chrome string for $UI_LANG (en/zh/ja), fallback en -> key.
_rime_t() {
  local lang="${UI_LANG:-en}" key="$1"
  case "$lang" in en|zh|ja) ;; *) lang="en" ;; esac
  printf '%s' "${RIME_I18N[$lang:$key]:-${RIME_I18N[en:$key]:-$key}}"
}

meta() {
  cat <<'META'
key=rime
name=RIME
category=common
ops=install,remove,configure,deploy,install-rime-ice,remove-rime-ice
desc=RIME input method on fcitx5 — installs the engine + frontends, manages schemas (输入方案), optional 雾凇拼音(rime-ice); desktop-only (honest no-op note over SSH)
META
}

# --- Install probe -------------------------------------------------------------

# Exit 0 iff the RIME engine for fcitx5 is installed (the thing this script is about).
status() {
  pkg_installed fcitx5-rime || return 1
  local v; v="$(fcitx5 --version 2>/dev/null | head -n1 || true)"
  printf 'fcitx5-rime installed%s\n' "${v:+ (${v})}"
  return 0
}

# --- Home / paths / preferences ------------------------------------------------

# Resolve the user's home (refusing a sudo-wrapped run — RIME config must stay user-owned),
# then derive every path we touch. Mirrors scripts/ghostty.sh's _ghostty_resolve_home.
_rime_resolve_home() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run RIME as your normal user, not via sudo — its config lives in your home"
    log_err "(~/.config, ~/.local/share) and must stay user-owned (apt steps escalate"
    log_err "per-command on their own)."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _R_HOME="${HOME:-}"
  [[ -n "$_R_HOME" ]] || _R_HOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_R_HOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  local xdg_cfg="${XDG_CONFIG_HOME:-$_R_HOME/.config}"
  local xdg_data="${XDG_DATA_HOME:-$_R_HOME/.local/share}"
  _R_RIME_DIR="$xdg_data/fcitx5/rime"                         # fcitx5's RIME user dir
  _R_ENVD="$xdg_cfg/environment.d/ubuntu-setup-rime.conf"     # managed IM environment
  _R_AUTOSTART="$xdg_cfg/autostart/org.fcitx.Fcitx5.desktop"  # managed fcitx5 login autostart
  _R_PREF_DIR="$xdg_cfg/ubuntu-setup"
  _R_PREF="$_R_PREF_DIR/rime.conf"                            # the kit's KEY=VALUE store
  _R_ICE_CLONE="$xdg_data/ubuntu-setup/rime-ice"             # kit-owned rime-ice clone
  _R_ICE_MANIFEST="$_R_PREF_DIR/rime-ice.manifest"           # paths rime-ice put in _R_RIME_DIR
  _R_XINPUTRC="$_R_HOME/.xinputrc"                            # im-config's framework selection
}

_rime_defaults() {
  FRAMEWORK=fcitx5
  SCHEMAS="luna_pinyin_simp luna_pinyin"
  PAGE_SIZE=5
  RIME_ICE=0
}

_rime_pagesize_valid() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 5 && $1 <= 10 )); }
_rime_schema_id_valid() { [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; }

_rime_load() {
  _rime_defaults
  [[ -f "${_R_PREF:-}" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in ''|\#*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    case "$key" in
      FRAMEWORK) [[ "$val" == fcitx5 ]] && FRAMEWORK="$val" ;;
      SCHEMAS)   SCHEMAS="$val" ;;
      PAGE_SIZE) _rime_pagesize_valid "$val" && PAGE_SIZE="$val" ;;
      RIME_ICE)  [[ "$val" == 0 || "$val" == 1 ]] && RIME_ICE="$val" ;;
    esac
  done <"$_R_PREF"
  [[ -n "${SCHEMAS// /}" ]] || SCHEMAS="luna_pinyin_simp luna_pinyin"
}

_rime_save() {
  mkdir -p "$_R_PREF_DIR"
  local tmp; tmp="$(mktemp)"
  {
    printf 'FRAMEWORK=%s\n' "$FRAMEWORK"
    printf 'SCHEMAS=%s\n'   "$SCHEMAS"
    printf 'PAGE_SIZE=%s\n' "$PAGE_SIZE"
    printf 'RIME_ICE=%s\n'  "$RIME_ICE"
  } >"$tmp"
  if [[ -f "$_R_PREF" ]] && cmp -s "$tmp" "$_R_PREF"; then rm -f "$tmp"; return 0; fi
  backup_file "$_R_PREF"
  mv "$tmp" "$_R_PREF" || { rm -f "$tmp"; return 1; }
}

# --- Schema-list helpers (operate on the space-separated SCHEMAS string) --------

_rime_schema_in() { local s; for s in $SCHEMAS; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
_rime_schema_add() { _rime_schema_in "$1" || SCHEMAS="${SCHEMAS:+$SCHEMAS }$1"; }
_rime_schema_remove() {
  local s out=""
  for s in $SCHEMAS; do [[ "$s" == "$1" ]] || out="${out:+$out }$s"; done
  SCHEMAS="$out"
}
_rime_schema_set_default() { _rime_schema_remove "$1"; SCHEMAS="$1${SCHEMAS:+ $SCHEMAS}"; }
_rime_default_schema() { printf '%s' "${SCHEMAS%% *}"; }

# --- Small environment probes --------------------------------------------------

# True when there is no local graphical session to deploy into (SSH or no display).
_rime_no_display() {
  [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]] && return 0
  [[ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]
}

# A short, honest note about where these settings take effect.
_rime_where_note() {
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; then
    log_warn "This is an SSH session. RIME/fcitx5 is a desktop input method — these settings"
    log_warn "apply on a machine with a graphical session, not to this remote shell."
  fi
}

# Desktop / session-type probes (best-effort; vars may be unset in a non-graphical shell).
_rime_is_gnome()   { case "${XDG_CURRENT_DESKTOP:-}" in *[Gg][Nn][Oo][Mm][Ee]*) return 0 ;; *) return 1 ;; esac; }
_rime_is_wayland() { [[ "${XDG_SESSION_TYPE:-}" == wayland || -n "${WAYLAND_DISPLAY:-}" ]]; }

# GNOME-on-Wayland caveat: GNOME runs its own IBus and Mutter routes native-Wayland apps
# through it (it does not implement the Wayland input-method protocol fcitx5 uses). fcitx5
# still serves X11/XWayland apps via GTK_IM_MODULE/XMODIFIERS. Tell the truth + give outs.
_rime_wayland_note() {
  _rime_is_gnome && _rime_is_wayland || return 0
  log_warn "You're on GNOME (Wayland). GNOME starts its own IBus and handles native-Wayland"
  log_warn "apps itself, so fcitx5/RIME covers X11/XWayland apps (most apps) but GNOME may keep"
  log_warn "intercepting some native-Wayland ones. For the most reliable fcitx5 experience:"
  log_warn "  • choose \"Ubuntu on Xorg\" at the login screen (gear icon, bottom-right), or"
  log_warn "  • drop GNOME's competing Chinese input source so it can't shadow fcitx5:"
  log_warn "      gsettings set org.gnome.desktop.input-sources sources \"[('xkb','us')]\""
}

# Notes printed after install / config changes (re-login reminder + honesty).
_rime_post_install_notes() {
  log_info "fcitx5 is set to autostart at login. Log out and back in so it starts and the"
  log_info "input-method environment applies; then switch with Ctrl+Space (fcitx5's toggle)."
  _rime_where_note
  _rime_wayland_note
}

# Is `pkg` an installable apt candidate right now? (No sudo; reads existing apt lists.)
# LC_ALL=C forces apt-cache's field labels to English — without it, on a localized system
# the label is translated (e.g. zh "候选：") and grepping for "Candidate:" matches nothing,
# so every probe falsely reports "unavailable". (Same rule as the lib's locale-proofing:
# decide on stable text, never on text that gets translated.)
_rime_apt_available() {
  local cand; cand="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Install the GTK/Qt IM modules so apps use fcitx5's native frontend. WITHOUT these, GTK/Qt
# apps fall back to XIM (XMODIFIERS), which works for typing but mis-positions the candidate
# window (it floats to a screen corner instead of following the cursor). Prefer the metapackage
# fcitx5-frontend-all (covers gtk2/3/4 + qt5/6, future-proof); fall back to the modern set if
# the metapackage is absent. recommends are off by lib policy, so we install these explicitly.
_rime_install_frontends() {
  if _rime_apt_available fcitx5-frontend-all; then
    apt_install fcitx5-frontend-all || log_warn "Could not install fcitx5-frontend-all (GTK/Qt IM modules)."
    return 0
  fi
  local p any=0
  for p in fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5 fcitx5-frontend-qt6; do
    if _rime_apt_available "$p"; then
      if apt_install "$p"; then any=1; else log_warn "Could not install $p."; fi
    fi
  done
  (( any )) || log_warn "No fcitx5 GTK/Qt IM modules were available — apps may fall back to XIM (mis-positioned candidate window)."
}

# Are the GTK/Qt IM modules present? (Used to self-heal older installs that missed them.)
_rime_frontends_present() {
  pkg_installed fcitx5-frontend-gtk3 || pkg_installed fcitx5-frontend-gtk4 \
    || pkg_installed fcitx5-frontend-qt6 || pkg_installed fcitx5-frontend-all
}

# --- Managed files (own them; rewrite wholesale + convergent; back up first) ----

# The fcitx5 input-method environment (read by systemd/GNOME/KDE graphical sessions).
_rime_write_envd() {
  mkdir -p "$(dirname "$_R_ENVD")"
  local tmp; tmp="$(mktemp)"
  {
    printf '# Generated by ubuntu-setup (swkit rime). Do not edit; re-run: swkit rime install\n'
    printf 'GTK_IM_MODULE=fcitx\n'
    printf 'QT_IM_MODULE=fcitx\n'
    printf 'XMODIFIERS=@im=fcitx\n'
  } >"$tmp"
  if [[ -f "$_R_ENVD" ]] && cmp -s "$tmp" "$_R_ENVD"; then rm -f "$tmp"; return 0; fi
  backup_file "$_R_ENVD"
  mv "$tmp" "$_R_ENVD" || { rm -f "$tmp"; return 1; }
}

# A managed XDG autostart entry that launches fcitx5 at login. This is REQUIRED on Wayland
# (Ubuntu's default session): im-config/im-launch only starts the IM daemon for X11 sessions
# (its Wayland branch is disabled), and the fcitx5 package ships no /etc/xdg/autostart entry,
# so without this nothing starts fcitx5 and the desktop falls back to its built-in IBus.
# GNOME/KDE process ~/.config/autostart on login for both X11 and Wayland.
_rime_write_autostart() {
  mkdir -p "$(dirname "$_R_AUTOSTART")"
  local exe; exe="$(command -v fcitx5 2>/dev/null || echo /usr/bin/fcitx5)"
  local tmp; tmp="$(mktemp)"
  {
    printf '[Desktop Entry]\n'
    printf '# Generated by ubuntu-setup (swkit rime). Autostarts fcitx5 at login — needed on\n'
    printf '# Wayland/GNOME, where im-config/im-launch does NOT start the IM daemon. Delete to disable.\n'
    printf 'Type=Application\n'
    printf 'Name=Fcitx 5 (ubuntu-setup)\n'
    printf 'Exec=%s\n' "$exe"
    printf 'Icon=fcitx\n'
    printf 'Terminal=false\n'
    printf 'StartupNotify=false\n'
    printf 'X-GNOME-Autostart-enabled=true\n'
  } >"$tmp"
  if [[ -f "$_R_AUTOSTART" ]] && cmp -s "$tmp" "$_R_AUTOSTART"; then rm -f "$tmp"; return 0; fi
  backup_file "$_R_AUTOSTART"
  mv "$tmp" "$_R_AUTOSTART" || { rm -f "$tmp"; return 1; }
}

# The managed RIME patch. We own default.custom.yaml; RIME merges *.custom.yaml as patches
# over its built-in defaults, and default.custom.yaml is exactly that user-patch entry point.
# When rime-ice is active we DON'T set schema_list (rime-ice's own default.yaml owns it).
_rime_write_default_yaml() {
  mkdir -p "$_R_RIME_DIR"
  local f="$_R_RIME_DIR/default.custom.yaml" tmp; tmp="$(mktemp)"
  {
    printf '# Generated by ubuntu-setup (swkit rime). Do not edit; re-run: swkit rime configure\n'
    printf 'patch:\n'
    if [[ "${RIME_ICE:-0}" != 1 ]]; then
      printf '  schema_list:\n'
      local s
      for s in $SCHEMAS; do printf '    - schema: %s\n' "$s"; done
    fi
    printf '  "menu/page_size": %s\n' "$PAGE_SIZE"
  } >"$tmp"
  if [[ -f "$f" ]] && cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 0; fi
  backup_file "$f"
  mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# --- Deploy (apply RIME config) ------------------------------------------------

_rime_deploy() {
  if _rime_no_display; then
    log_info "No local graphical session — deploy where the desktop runs (fcitx5 tray ▸"
    log_info "Restart / Deploy), or it applies on next login."
    _rime_where_note
    return 0
  fi
  if have_cmd fcitx5-remote && fcitx5-remote -r 2>/dev/null; then
    log_info "Asked the running fcitx5 to reload (redeploys RIME)."
  else
    log_info "Could not reach a running fcitx5 — deploy via the tray (▸ Deploy) or re-login."
  fi
}

do_deploy() { _rime_resolve_home || return 1; _rime_deploy; }

# --- Install / remove ----------------------------------------------------------

do_install() {
  _rime_resolve_home || return 1
  if status >/dev/null 2>&1; then
    log_info "RIME engine already installed ($(status 2>/dev/null)) — converging config."
    _rime_load
    # Self-heal older installs that missed the GTK/Qt IM modules (their absence makes apps
    # fall back to XIM, which mis-positions the candidate window).
    if ! _rime_frontends_present; then
      log_info "GTK/Qt IM modules are missing — installing them (apps were falling back to XIM)…"
      _rime_install_frontends
    fi
    _rime_write_envd || log_warn "Could not write the IM environment file."
    _rime_write_autostart || log_warn "Could not write the fcitx5 autostart entry."
    # Re-assert the framework selection too (harmless if already fcitx5).
    have_cmd im-config && { im-config -n fcitx5 >/dev/null 2>&1 || true; }
    [[ -f "$_R_RIME_DIR/default.custom.yaml" ]] || _rime_write_default_yaml
    log_info "Configure schemas with:  swkit rime configure   (or open: swkit rime)"
    _rime_post_install_notes
    return 0
  fi

  # Core: framework + RIME engine + GUI config tool + the framework selector.
  apt_install fcitx5 fcitx5-rime fcitx5-config-qt im-config

  # GTK/Qt IM modules (without them apps fall back to XIM → mis-positioned candidate window).
  _rime_install_frontends

  # Select fcitx5 as the input-method framework (Ubuntu's blessed selector; user-space).
  if have_cmd im-config; then
    im-config -n fcitx5 >/dev/null 2>&1 || log_warn "im-config -n fcitx5 did not complete — set the framework manually if needed."
  fi

  _rime_load
  _rime_write_envd || log_warn "Could not write the IM environment file."
  _rime_write_autostart || log_warn "Could not write the fcitx5 autostart entry."
  [[ -f "$_R_RIME_DIR/default.custom.yaml" ]] || _rime_write_default_yaml

  log_info "Installed fcitx5 + RIME."
  log_info "Pick schemas / enable 雾凇拼音 with:  swkit rime configure   (or: swkit rime)"
  _rime_post_install_notes
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "The RIME engine (fcitx5-rime) is not installed — nothing to remove."
    return 0
  fi
  apt_remove fcitx5-rime
  log_info "Removed the RIME engine (fcitx5-rime). Kept fcitx5 itself, your IM environment,"
  log_info "the fcitx5 autostart entry and your RIME data so other engines / a re-install keep working."
  log_info "To remove the whole framework too:  sudo apt remove fcitx5 'fcitx5-*'"
  log_info "  and:  rm -f ~/.config/autostart/org.fcitx.Fcitx5.desktop ~/.config/environment.d/ubuntu-setup-rime.conf"
}

# --- Configure -----------------------------------------------------------------

do_configure() {
  _rime_resolve_home || return 1
  _rime_load
  local want_deploy=0

  while (( $# > 0 )); do
    case "$1" in
      --recommended)
        SCHEMAS="luna_pinyin_simp luna_pinyin"; PAGE_SIZE=8; want_deploy=1; shift ;;
      --schemas)
        [[ $# -ge 2 ]] || { log_err "--schemas needs a space-separated list, e.g. \"luna_pinyin_simp luna_pinyin\"."; return 2; }
        SCHEMAS="$2"; shift 2 ;;
      --schemas=*) SCHEMAS="${1#--schemas=}"; shift ;;
      --default-schema)
        [[ $# -ge 2 ]] || { log_err "--default-schema needs a schema id."; return 2; }
        _rime_schema_id_valid "$2" || { log_err "Invalid schema id: $2"; return 2; }
        _rime_schema_set_default "$2"; shift 2 ;;
      --default-schema=*)
        _rime_schema_id_valid "${1#--default-schema=}" || { log_err "Invalid schema id."; return 2; }
        _rime_schema_set_default "${1#--default-schema=}"; shift ;;
      --page-size)
        if [[ $# -lt 2 ]] || ! _rime_pagesize_valid "${2:-}"; then log_err "--page-size needs an integer from 5 to 10."; return 2; fi
        PAGE_SIZE="$2"; shift 2 ;;
      --page-size=*)
        if ! _rime_pagesize_valid "${1#--page-size=}"; then log_err "--page-size needs an integer from 5 to 10."; return 2; fi
        PAGE_SIZE="${1#--page-size=}"; shift ;;
      --deploy) want_deploy=1; shift ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done

  # Validate/sanitize the resolved schema list (drop empties / invalid ids, keep order).
  local s clean=""
  for s in $SCHEMAS; do
    if _rime_schema_id_valid "$s"; then clean="${clean:+$clean }$s"; else log_warn "Dropping invalid schema id: $s"; fi
  done
  [[ -n "$clean" ]] || clean="luna_pinyin_simp luna_pinyin"
  SCHEMAS="$clean"

  _rime_save || { log_err "Failed to save preferences to $_R_PREF."; return 1; }
  _rime_write_default_yaml
  log_info "RIME config written. Enabled schemas: $SCHEMAS (default: $(_rime_default_schema)); page size: $PAGE_SIZE."
  if (( want_deploy )); then _rime_deploy; else log_info "Apply it with:  swkit rime deploy"; fi
  _rime_where_note
}

# --- Schema actions (parameterized; routed by kit_dispatch, reachable from ui) --

do_add_schema() {
  [[ $# -ge 1 ]] || { log_err "Usage: rime add-schema <schema-id>  (e.g. bopomofo)"; return 2; }
  _rime_schema_id_valid "$1" || { log_err "Invalid schema id: $1"; return 2; }
  _rime_resolve_home || return 1
  _rime_load
  if [[ "${RIME_ICE:-0}" == 1 ]]; then
    log_warn "雾凇拼音 (rime-ice) is active and owns the schema list; remove it first to manage schemas here."
    return 0
  fi
  _rime_schema_in "$1" && { log_info "Schema '$1' is already enabled."; return 0; }
  _rime_schema_add "$1"
  _rime_save; _rime_write_default_yaml
  log_info "Enabled schema '$1'. Enabled: $SCHEMAS"
  _rime_deploy
}

do_remove_schema() {
  [[ $# -ge 1 ]] || { log_err "Usage: rime remove-schema <schema-id>"; return 2; }
  _rime_resolve_home || return 1
  _rime_load
  _rime_schema_in "$1" || { log_info "Schema '$1' is not enabled — nothing to do."; return 0; }
  local remaining=0 s
  for s in $SCHEMAS; do [[ "$s" == "$1" ]] || remaining=$(( remaining + 1 )); done
  (( remaining >= 1 )) || { log_err "Refusing to remove the last enabled schema."; return 2; }
  _rime_schema_remove "$1"
  _rime_save; _rime_write_default_yaml
  log_info "Disabled schema '$1'. Enabled: $SCHEMAS"
  _rime_deploy
}

do_set_default_schema() {
  [[ $# -ge 1 ]] || { log_err "Usage: rime set-default-schema <schema-id>"; return 2; }
  _rime_schema_id_valid "$1" || { log_err "Invalid schema id: $1"; return 2; }
  _rime_resolve_home || return 1
  _rime_load
  _rime_schema_set_default "$1"
  _rime_save; _rime_write_default_yaml
  log_info "Default schema is now '$1'. Enabled: $SCHEMAS"
  _rime_deploy
}

# --- 雾凇拼音 (rime-ice): manifest-based, reversible install -------------------

do_install_rime_ice() {
  _rime_resolve_home || return 1
  _rime_load
  have_cmd git || { log_err "git is required for rime-ice — run: swkit git install"; return 1; }
  _rime_where_note

  if [[ -d "$_R_ICE_CLONE/.git" ]]; then
    log_info "Updating the existing rime-ice clone…"
    ( cd "$_R_ICE_CLONE" && git pull --ff-only ) || log_warn "git pull failed — using the existing clone."
  else
    mkdir -p "$(dirname "$_R_ICE_CLONE")"
    git clone --depth 1 "$_RIME_ICE_REPO" "$_R_ICE_CLONE" || { log_err "Failed to clone rime-ice."; return 1; }
  fi

  mkdir -p "$_R_RIME_DIR" "$_R_PREF_DIR"
  # Remember what WE installed last time so a re-install doesn't back up our own files.
  local -A was_ours=()
  if [[ -f "$_R_ICE_MANIFEST" ]]; then
    local ln
    while IFS= read -r ln || [[ -n "$ln" ]]; do [[ -n "$ln" ]] && was_ours["$ln"]=1; done <"$_R_ICE_MANIFEST"
  fi

  : >"$_R_ICE_MANIFEST"
  local entry base
  for entry in "$_R_ICE_CLONE"/*; do
    [[ -e "$entry" ]] || continue
    base="$(basename "$entry")"
    case "$base" in .git|.github|*.md|LICENSE|.gitignore|.gitattributes) continue ;; esac
    if [[ -e "$_R_RIME_DIR/$base" && -z "${was_ours[$base]:-}" ]]; then
      backup_file "$_R_RIME_DIR/$base"
    fi
    rm -rf "${_R_RIME_DIR:?}/$base"
    cp -rf "$entry" "$_R_RIME_DIR/$base"
    printf '%s\n' "$base" >>"$_R_ICE_MANIFEST"
  done

  RIME_ICE=1; _rime_save
  _rime_write_default_yaml   # drop our schema_list; rime-ice owns it
  log_info "Installed 雾凇拼音 (rime-ice) into $_R_RIME_DIR."
  _rime_deploy
}

do_remove_rime_ice() {
  _rime_resolve_home || return 1
  _rime_load
  if [[ -f "$_R_ICE_MANIFEST" ]]; then
    local ln
    while IFS= read -r ln || [[ -n "$ln" ]]; do
      [[ -n "$ln" ]] || continue
      case "$ln" in /*|*..*) log_warn "Skipping unsafe manifest entry: $ln"; continue ;; esac
      rm -rf "${_R_RIME_DIR:?}/$ln"
    done <"$_R_ICE_MANIFEST"
    rm -f "$_R_ICE_MANIFEST"
    log_info "Removed rime-ice files from $_R_RIME_DIR."
  else
    log_info "rime-ice is not installed (no manifest) — nothing to remove."
  fi
  rm -rf "$_R_ICE_CLONE"
  RIME_ICE=0; _rime_save
  _rime_write_default_yaml   # restore the built-in schema_list
  _rime_deploy
}

# --- Interactive management screen --------------------------------------------

ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  _rime_resolve_home || { ui_default_menu; return 0; }
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    _rime_load
    local installed=0 ver=""
    if status >/dev/null 2>&1; then installed=1; ver="$(fcitx5 --version 2>/dev/null | head -n1 || true)"; fi
    local envd_ok=0; [[ -f "$_R_ENVD" ]] && envd_ok=1
    local auto_ok=0; [[ -f "$_R_AUTOSTART" ]] && auto_ok=1
    local ice_on=0; [[ "${RIME_ICE:-0}" == 1 ]] && ice_on=1
    local defschema; defschema="$(_rime_default_schema)"

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if _rime_no_display; then
      dkind+=(note); did+=(""); dlabel+=("$(_rime_t ui_ssh_note)")
      dkind+=(spacer); did+=(""); dlabel+=("")
    fi

    dkind+=(header); did+=(""); dlabel+=("$(_rime_t ui_sec_engine)")
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) fcitx5 + RIME")
    else
      dkind+=(envrow); did+=(""); dlabel+=("$(printf '%-22s %s' "$(_rime_t ui_im_environment)" "$( ((envd_ok)) && printf '%s %s' "$(ui_badge on)" "$(_rime_t ui_state_on)" || printf '%s %s' "$(ui_badge off)" "$(_rime_t ui_state_missing)")")")
      dkind+=(autorow); did+=(""); dlabel+=("$(printf '%-22s %s' "$(_rime_t ui_fcitx5_autostart)" "$( ((auto_ok)) && printf '%s %s' "$(ui_badge on)" "$(_rime_t ui_state_on)" || printf '%s %s' "$(ui_badge off)" "$(_rime_t ui_state_missing)")")")
      dkind+=(remove);  did+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) $(_rime_t ui_rime_engine)")
    fi

    if (( installed )); then
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_rime_t ui_sec_schemas)")
      if (( ice_on )); then
        dkind+=(note); did+=(""); dlabel+=("$(_rime_t ui_ice_owns_schemas)")
      else
        local key chk star desc
        for key in "${_RIME_CURATED[@]}"; do
          if _rime_schema_in "$key"; then chk="${UI_OK}${UI_CHK_ON}${UI_OFF}"; else chk="${UI_MUTED}${UI_CHK_OFF}${UI_OFF}"; fi
          star=""; [[ "$key" == "$defschema" ]] && star=" ${UI_INFO}★${UI_OFF}"
          desc="$(_rime_schema_desc "$key")"
          dkind+=(schema); did+=("$key"); dlabel+=("$(printf '%s %-20s %s%s' "$chk" "$key" "$desc" "$star")")
        done
        dkind+=(addschema); did+=(""); dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_rime_t ui_add_schema_row)")
      fi

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_rime_t ui_sec_options)")
      dkind+=(pagesize); did+=(pagesize); dlabel+=("$(printf '%-22s %s  %s' "$(_rime_t ui_candidates_per_page)" "$PAGE_SIZE" "$UI_ARROW")")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("雾凇拼音 (rime-ice)")
      if (( ice_on )); then
        dkind+=(iceremove); did+=(""); dlabel+=("$(ui_badge on) $(_rime_t ui_ice_remove_row)")
      else
        dkind+=(iceinstall); did+=(""); dlabel+=("$(ui_badge off) $(_rime_t ui_ice_install_row)")
      fi

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_rime_t ui_sec_actions)")
      dkind+=(deploy);  did+=(""); dlabel+=("$(ui_badge check) $(_rime_t ui_deploy_now)")
      dkind+=(recommend); did+=(""); dlabel+=("$(ui_badge check) $(_rime_t ui_apply_recommended)")
    fi

    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in note|spacer|header|envrow|autorow)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in note|spacer|header|envrow|autorow) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "RIME · input method" "${ver:-installed} $(ui_badge installed)"
    else ui_header "RIME · input method" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        note)   ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_MUTED" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        envrow|autorow) ui_move "$row" 4; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_rime_t ui_footer_hints)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in note|spacer|header|envrow|autorow) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in note|spacer|header|envrow|autorow) ;; *) break ;; esac; done ;;
      space)
        case "${dkind[$sel]}" in
          schema)
            local id="${did[$sel]}"
            if _rime_schema_in "$id"; then
              ui_run "$(_rime_t ui_run_disable_schema) $id · rime" -- "$0" remove-schema "$id"
            else
              ui_run "$(_rime_t ui_run_enable_schema) $id · rime" -- "$0" add-schema "$id"
            fi ;;
        esac ;;
      d|D)
        [[ "${dkind[$sel]}" == schema ]] && ui_run "$(_rime_t ui_run_set_default_schema) ${did[$sel]} · rime" -- "$0" set-default-schema "${did[$sel]}" ;;
      a|A)
        if (( installed )) && (( ! ice_on )); then
          if ui_input "$(_rime_t ui_prompt_schema_id)" ""; then
            [[ -n "$UI_INPUT" ]] && ui_run "$(_rime_t ui_run_add_schema) $UI_INPUT · rime" -- "$0" add-schema "$UI_INPUT"
          fi
        fi ;;
      enter)
        case "${dkind[$sel]}" in
          install)    ui_run "$(ui_t install) fcitx5 + RIME" -- "$0" install ;;
          remove)     ui_confirm "$(_rime_t ui_confirm_remove_engine)" n && ui_run "$(ui_t remove) $(_rime_t ui_rime_engine)" -- "$0" remove ;;
          schema)
            local id="${did[$sel]}"
            if _rime_schema_in "$id"; then
              ui_run "$(_rime_t ui_run_disable_schema) $id · rime" -- "$0" remove-schema "$id"
            else
              ui_run "$(_rime_t ui_run_enable_schema) $id · rime" -- "$0" add-schema "$id"
            fi ;;
          addschema)
            if ui_input "$(_rime_t ui_prompt_schema_id)" ""; then
              [[ -n "$UI_INPUT" ]] && ui_run "$(_rime_t ui_run_add_schema) $UI_INPUT · rime" -- "$0" add-schema "$UI_INPUT"
            fi ;;
          pagesize)
            if ui_input "$(_rime_t ui_prompt_page_size)" "$PAGE_SIZE"; then
              [[ -n "$UI_INPUT" ]] && ui_run "$(_rime_t ui_run_set_page_size) · rime" -- "$0" configure --page-size "$UI_INPUT"
            fi ;;
          iceinstall) ui_confirm "$(_rime_t ui_confirm_install_ice)" y && ui_run "$(_rime_t ui_run_install_ice) · rime" -- "$0" install-rime-ice ;;
          iceremove)  ui_confirm "$(_rime_t ui_confirm_remove_ice)" n && ui_run "$(_rime_t ui_run_remove_ice) · rime" -- "$0" remove-rime-ice ;;
          deploy)     ui_run "$(_rime_t ui_run_deploy) · rime" -- "$0" deploy ;;
          recommend)  ui_run "$(_rime_t ui_run_apply_recommended) · rime" -- "$0" configure --recommended ;;
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

RIME input method on the fcitx5 framework. Installs fcitx5 + the RIME engine + frontends via
apt, selects fcitx5 (im-config), and writes a managed IM environment + RIME schema patch —
your own files are backed up before any change. RIME/fcitx5 is a desktop input method: over
SSH/headless these settings apply where the desktop runs, after the next login.

  install              Install fcitx5 + RIME (idempotent; converges config on re-run)
  remove               Uninstall the RIME engine (keeps fcitx5, IM env and your RIME data)
  configure [opts]     Set schemas / page size; with NO opts writes the conservative baseline.
                         --recommended           简体拼音优先 + page size 8 + deploy
                         --schemas "a b c"       enabled schemas (first is the default)
                         --default-schema <id>   make <id> the default (moves it first)
                         --page-size <5-10>      candidates shown per page
                         --deploy                redeploy RIME afterwards
  add-schema <id>      Enable one schema by id (curated or any with data present)
  remove-schema <id>   Disable one schema (never the last one)
  set-default-schema <id>   Make <id> the default schema
  install-rime-ice     Install 雾凇拼音 (rime-ice) — reversible, manifest-tracked, user-space
  remove-rime-ice      Remove rime-ice and restore the built-in schemas
  deploy               Ask a running fcitx5 to reload/redeploy RIME (no-op note if headless)
  status               Print the engine version if installed; exit 0 iff installed
  ui                   Open the interactive manager (needs a terminal)
  meta                 Print machine-readable metadata (for the TUI / swkit list)
  help                 Show this help

Curated schemas: ${_RIME_CURATED[*]}
EOF
}

kit_dispatch "$@"
