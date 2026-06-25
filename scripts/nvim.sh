#!/usr/bin/env bash
#
# scripts/nvim.sh — install / configure / manage Neovim (and its config + plugins) on Ubuntu.
#
# Two layers, like the kit's other component managers (ghostty / tmux / rime):
#
#   1) The Neovim BINARY (system-level, escalated per-command via sudo_run) — installed by a
#      best-channel + version-gate policy: apt when its candidate is new enough, otherwise the
#      official stable tarball into /opt (sha256-verified against the GitHub release API), and
#      finally a snap fallback. Tarball ranks ABOVE snap because the official tarball is the
#      always-latest stable with a full API checksum (snap lags upstream).
#
#   2) CONFIG + PLUGINS (user-space, never sudo) — a "distro installer": curated starters
#      (LazyVim / kickstart / AstroNvim / NvChad, plus any git-url) are git-cloned, isolated via
#      NVIM_APPNAME so they never clobber your own ~/.config/nvim (smart default: take over an
#      empty default, else isolate to ~/.config/nvim-<name> + a managed shell alias), tracked in
#      a manifest for exact removal, and their bundled lazy.nvim is driven headless for plugin
#      sync. The kit does NOT parse or rewrite a distro's Lua — it drives lazy.nvim only.
#
# Plus: external deps a distro needs (git/curl/compiler/ripgrep/fd + a Nerd Font), and a
# default-editor toggle (EDITOR/VISUAL in your shell rc + best-effort update-alternatives).
#
# Honesty: Neovim is a TUI (not a GUI), so SSH/headless use is perfect — no "desktop only"
# caveat. Nerd Font glyphs render in your LOCAL/client terminal (fonts.sh prints that guidance).
#
# Run it as:  nvim.sh install|remove|configure|update|update-plugins|status|meta|ui|help
#             plus install-distro <name> [appname] / remove-distro <name|appname> /
#                  add-distro <name> <git-url> / sync-plugins [appname] / clean-plugins [appname] /
#                  set-default-editor [off] / ensure-deps        (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# The apt version gate: install via apt only when its candidate is >= this. Below it, fall back to
# the official stable tarball. 0.11.2 satisfies every curated distro (see prd.md's verified facts).
readonly NVIM_MIN_VERSION="0.11.2"

# GitHub release API for the rolling `stable` tag (tarball channel). `stable` rolls forward, so we
# NEVER hard-code a version or sha256 — both are resolved live from the API at install time.
readonly NVIM_RELEASE_API="https://api.github.com/repos/neovim/neovim/releases/tags/stable"

# --- Curated distros (name -> git repo) ----------------------------------------
# Opt-in starters/distros. lazyvim is the `--recommended` default. The name stays UNtranslated.
declare -gA NVIM_DISTRO_REPO=(
  [lazyvim]="https://github.com/LazyVim/starter"
  [kickstart]="https://github.com/nvim-lua/kickstart.nvim"
  [astronvim]="https://github.com/AstroNvim/template"
  [nvchad]="https://github.com/NvChad/starter"
)
# Stable display order (associative arrays are unordered).
readonly NVIM_DISTRO_ORDER="lazyvim kickstart astronvim nvchad"
readonly NVIM_RECOMMENDED_DISTRO="lazyvim"

# External deps a distro typically needs (apt packages). fd's binary is `fdfind` on Ubuntu.
readonly NVIM_DEP_PKGS="git curl build-essential ripgrep fd-find unzip"

# --- Managed config layer (the third layer on top of binary + distro installer) -
# A component manager for Neovim's ACTUAL config (options / keymaps / colorscheme / plugins),
# like tmux.sh / ghostty.sh / rime.sh. Two modes, auto-detected (see _nvim_cfg_mode):
#   - takeover : an empty/absent ~/.config/nvim → kit OWNS init.lua (leader early + options +
#                keymaps + lazy.nvim bootstrap + curated plugins + colorscheme).
#   - overlay  : a non-empty config (a distro or the user's own) → kit only drops a managed
#                ~/.config/<appname>/after/plugin/ubuntu-setup.lua (options + keymaps[no leader] +
#                colorscheme; NO plugins). after/plugin is sourced LAST even under lazy.nvim/LazyVim
#                (verified: lazy keeps stdpath('config')/after on rtp), so kit never touches distro Lua.
# Marker on the first line claims kit ownership of a managed file (refuse to clobber user files).
readonly NVIM_CFG_MARKER="-- >>> ubuntu-setup nvim config (managed) >>>"
readonly NVIM_CFG_MARKER_END="-- <<< ubuntu-setup nvim config (managed) <<<"

# Curated plugins for the TAKEOVER (bare-nvim) scenario only — each independently toggleable, plus
# `add-plugin <owner/repo|git-url>` for anything else. Name == key; repos stay UNtranslated. The LSP
# group (mason + mason-lspconfig + lspconfig + blink.cmp) is gated separately by CFG_LSP. Verified
# minimal specs for nvim 0.11+ (mason moved to mason-org/; mason-lspconfig auto-enables servers via
# vim.lsp.enable; blink version 1.*; treesitter master configs API) — see the task research note.
declare -gA NVIM_PLUGIN_REPO=(
  [treesitter]="nvim-treesitter/nvim-treesitter"
  [telescope]="nvim-telescope/telescope.nvim"
  [gitsigns]="lewis6991/gitsigns.nvim"
  [which-key]="folke/which-key.nvim"
  [lualine]="nvim-lualine/lualine.nvim"
)
readonly NVIM_PLUGIN_ORDER="treesitter telescope gitsigns which-key lualine"
# Default curated plugin set for --config-recommended / "Apply recommended config".
readonly NVIM_PLUGIN_RECOMMENDED="treesitter telescope gitsigns which-key lualine"

# Built-in colorschemes shipped with Neovim (no plugin needed) — the curated picks for the UI
# selector. `set-colorscheme` accepts any name matching _nvim_colorscheme_valid (not just these).
readonly NVIM_BUILTIN_COLORS="default habamax retrobox slate sorbet desert evening koehler quiet wildcharm"
readonly NVIM_CFG_RECOMMENDED_COLOR="habamax"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "Neovim"/"nvim", distro
# names (lazyvim, kickstart…) and package/command names stay UNtranslated; only descriptive
# wording is localized. Resolve with _nvim_t KEY (fallback en -> key, like ui_t).
declare -gA NVIM_I18N
NVIM_I18N[en:distros]="Distros / starters (NVIM_APPNAME-isolated)"
NVIM_I18N[en:plugins]="Plugins (lazy.nvim, headless)"
NVIM_I18N[en:ext_deps]="External deps"
NVIM_I18N[en:default_editor]="Default editor (EDITOR/VISUAL)"
NVIM_I18N[en:apply_recommended]="Apply recommended setup (Neovim + deps + LazyVim + editor)"
NVIM_I18N[en:add_distro]="add a distro by git-url…"
NVIM_I18N[en:install_deps]="Install external deps (git curl ripgrep fd + Nerd Font)"
NVIM_I18N[en:sync_plugins]="Sync plugins"
NVIM_I18N[en:update_plugins]="Update plugins"
NVIM_I18N[en:clean_plugins]="Clean plugins"
NVIM_I18N[en:confirm_remove]="Uninstall Neovim? (keeps your ~/.config/nvim* and distro data)"
NVIM_I18N[en:confirm_remove_distro]="Remove this distro? (backs up the config dir, then deletes it + its data)"
NVIM_I18N[en:not_installed_first]="Install Neovim first (swkit nvim install)."
NVIM_I18N[en:foot_main]="up/down move   space toggle   enter select   esc/q close"
NVIM_I18N[en:type_giturl]="Type a git URL to clone as a distro…"
NVIM_I18N[en:prompt_giturl]="Distro git URL (https://github.com/owner/repo)"
NVIM_I18N[en:prompt_name]="Short name for this distro (letters/digits/._-)"
NVIM_I18N[en:nerd_font]="Nerd Font (MesloLGS NF)"
NVIM_I18N[en:desc_lazyvim]="batteries-included, lazy.nvim-based config"
NVIM_I18N[en:desc_kickstart]="single-file, minimal starting point to learn from"
NVIM_I18N[en:desc_astronvim]="full UI/IDE distro on a template"
NVIM_I18N[en:desc_nvchad]="fast, minimal, themeable distro"
NVIM_I18N[en:managed_config]="Managed config (options / keymaps / colorscheme / plugins)"
NVIM_I18N[en:mc_options]="Editor options (best-practice baseline)"
NVIM_I18N[en:mc_keymaps]="Keymaps (leader + quality-of-life)"
NVIM_I18N[en:mc_leader]="Leader key"
NVIM_I18N[en:mc_leader_distro_only]="Leader: owned by your distro/config — set vim.g.mapleader early in the distro (kit can't; an overlay loads too late)."
NVIM_I18N[en:mc_colorscheme]="Colorscheme (built-in)"
NVIM_I18N[en:mc_plugins]="Plugins (curated; bare-nvim takeover only)"
NVIM_I18N[en:mc_lsp]="LSP (lspconfig + Mason + blink.cmp)"
NVIM_I18N[en:mc_apply_recommended]="Apply recommended config (options + keymaps + colorscheme + plugins)"
NVIM_I18N[en:mc_reset]="Reset managed config"
NVIM_I18N[en:mc_confirm_reset]="Reset the managed Neovim config? (backs up, then removes kit-managed files)"
NVIM_I18N[en:mc_mode_takeover]="mode: takeover — kit owns this config"
NVIM_I18N[en:mc_mode_overlay]="mode: overlay — after/plugin"
NVIM_I18N[en:mc_plugins_distro_only]="A distro/your config owns plugins here — kit overlays only options/keymaps/colorscheme."
NVIM_I18N[en:mc_add_plugin]="add a plugin (owner/repo or git-url)…"
NVIM_I18N[en:mc_prompt_plugin]="Plugin (owner/repo or https git URL)"
NVIM_I18N[en:mc_prompt_leader]="Leader key (a single char, or the word 'space')"
NVIM_I18N[en:mc_pick_colorscheme]="Pick a built-in colorscheme"
NVIM_I18N[en:mc_node_hint]="Node not found — for Mason LSP servers that need it: swkit node install"
NVIM_I18N[zh:distros]="发行版 / starter(经 NVIM_APPNAME 隔离)"
NVIM_I18N[zh:plugins]="插件(lazy.nvim,headless 驱动)"
NVIM_I18N[zh:ext_deps]="外部依赖"
NVIM_I18N[zh:default_editor]="默认编辑器(EDITOR/VISUAL)"
NVIM_I18N[zh:apply_recommended]="应用推荐配置(Neovim + 依赖 + LazyVim + 编辑器)"
NVIM_I18N[zh:add_distro]="按 git-url 添加发行版…"
NVIM_I18N[zh:install_deps]="安装外部依赖(git curl ripgrep fd + Nerd Font)"
NVIM_I18N[zh:sync_plugins]="同步插件"
NVIM_I18N[zh:update_plugins]="更新插件"
NVIM_I18N[zh:clean_plugins]="清理插件"
NVIM_I18N[zh:confirm_remove]="卸载 Neovim?(保留你的 ~/.config/nvim* 与发行版数据)"
NVIM_I18N[zh:confirm_remove_distro]="移除该发行版?(先备份配置目录,再删除它及其数据)"
NVIM_I18N[zh:not_installed_first]="请先安装 Neovim(swkit nvim install)。"
NVIM_I18N[zh:foot_main]="↑↓ 移动   space 勾选   ↵ 选择   esc/q 关闭"
NVIM_I18N[zh:type_giturl]="输入要作为发行版克隆的 git URL…"
NVIM_I18N[zh:prompt_giturl]="发行版 git URL(https://github.com/owner/repo)"
NVIM_I18N[zh:prompt_name]="该发行版的短名(字母/数字/._-)"
NVIM_I18N[zh:nerd_font]="Nerd Font(MesloLGS NF)"
NVIM_I18N[zh:desc_lazyvim]="开箱即用、基于 lazy.nvim 的配置"
NVIM_I18N[zh:desc_kickstart]="单文件、极简、用于学习的起点"
NVIM_I18N[zh:desc_astronvim]="基于模板的完整 UI/IDE 发行版"
NVIM_I18N[zh:desc_nvchad]="快速、极简、可换主题的发行版"
NVIM_I18N[zh:managed_config]="受管配置(options / keymaps / colorscheme / 插件)"
NVIM_I18N[zh:mc_options]="编辑器 options(最佳实践基线)"
NVIM_I18N[zh:mc_keymaps]="keymaps(leader + 便捷键)"
NVIM_I18N[zh:mc_leader]="leader 键"
NVIM_I18N[zh:mc_leader_distro_only]="leader 键:由 distro/你的配置拥有 —— 请在 distro 里早设 vim.g.mapleader(kit 无法代设:overlay 加载太晚)。"
NVIM_I18N[zh:mc_colorscheme]="colorscheme(内置主题)"
NVIM_I18N[zh:mc_plugins]="插件(curated;仅裸 nvim 接管)"
NVIM_I18N[zh:mc_lsp]="LSP(lspconfig + Mason + blink.cmp)"
NVIM_I18N[zh:mc_apply_recommended]="应用推荐配置(options + keymaps + colorscheme + 插件)"
NVIM_I18N[zh:mc_reset]="重置受管配置"
NVIM_I18N[zh:mc_confirm_reset]="重置受管 Neovim 配置?(先备份,再移除 kit 受管文件)"
NVIM_I18N[zh:mc_mode_takeover]="模式:takeover —— kit 拥有此配置"
NVIM_I18N[zh:mc_mode_overlay]="模式:overlay —— after/plugin"
NVIM_I18N[zh:mc_plugins_distro_only]="此处插件由 distro/你的配置拥有 —— kit 只叠加 options/keymaps/colorscheme。"
NVIM_I18N[zh:mc_add_plugin]="添加插件(owner/repo 或 git-url)…"
NVIM_I18N[zh:mc_prompt_plugin]="插件(owner/repo 或 https git URL)"
NVIM_I18N[zh:mc_prompt_leader]="leader 键(单个字符,或单词 'space')"
NVIM_I18N[zh:mc_pick_colorscheme]="选择一个内置 colorscheme"
NVIM_I18N[zh:mc_node_hint]="未找到 Node —— Mason 的 Node 系 LSP server 需要:swkit node install"
NVIM_I18N[ja:distros]="ディストロ / starter(NVIM_APPNAME で分離)"
NVIM_I18N[ja:plugins]="プラグイン(lazy.nvim、ヘッドレス)"
NVIM_I18N[ja:ext_deps]="外部依存"
NVIM_I18N[ja:default_editor]="デフォルトエディタ(EDITOR/VISUAL)"
NVIM_I18N[ja:apply_recommended]="推奨セットアップを適用(Neovim + 依存 + LazyVim + エディタ)"
NVIM_I18N[ja:add_distro]="git-url でディストロを追加…"
NVIM_I18N[ja:install_deps]="外部依存をインストール(git curl ripgrep fd + Nerd Font)"
NVIM_I18N[ja:sync_plugins]="プラグインを同期"
NVIM_I18N[ja:update_plugins]="プラグインを更新"
NVIM_I18N[ja:clean_plugins]="プラグインを整理"
NVIM_I18N[ja:confirm_remove]="Neovim をアンインストールしますか?(~/.config/nvim* とディストロのデータは保持)"
NVIM_I18N[ja:confirm_remove_distro]="このディストロを削除しますか?(設定ディレクトリをバックアップしてから削除)"
NVIM_I18N[ja:not_installed_first]="先に Neovim をインストールしてください(swkit nvim install)。"
NVIM_I18N[ja:foot_main]="↑↓ 移動   space 切替   ↵ 選択   esc/q 閉じる"
NVIM_I18N[ja:type_giturl]="ディストロとして clone する git URL を入力…"
NVIM_I18N[ja:prompt_giturl]="ディストロの git URL(https://github.com/owner/repo)"
NVIM_I18N[ja:prompt_name]="このディストロの短い名前(英数/._-)"
NVIM_I18N[ja:nerd_font]="Nerd Font(MesloLGS NF)"
NVIM_I18N[ja:desc_lazyvim]="全部入り、lazy.nvim ベースの設定"
NVIM_I18N[ja:desc_kickstart]="単一ファイル、学習向けの最小構成"
NVIM_I18N[ja:desc_astronvim]="テンプレート方式の完全な UI/IDE ディストロ"
NVIM_I18N[ja:desc_nvchad]="高速・最小・テーマ可能なディストロ"
NVIM_I18N[ja:managed_config]="管理対象の設定(options / keymaps / colorscheme / プラグイン)"
NVIM_I18N[ja:mc_options]="エディタ options(ベストプラクティス基準)"
NVIM_I18N[ja:mc_keymaps]="keymaps(leader + 便利キー)"
NVIM_I18N[ja:mc_leader]="leader キー"
NVIM_I18N[ja:mc_leader_distro_only]="leader キー:distro/あなたの設定が所有 — distro 側で vim.g.mapleader を早期設定してください(kit は不可:overlay は読み込みが遅すぎる)。"
NVIM_I18N[ja:mc_colorscheme]="colorscheme(内蔵テーマ)"
NVIM_I18N[ja:mc_plugins]="プラグイン(curated;素の nvim 引き継ぎ時のみ)"
NVIM_I18N[ja:mc_lsp]="LSP(lspconfig + Mason + blink.cmp)"
NVIM_I18N[ja:mc_apply_recommended]="推奨設定を適用(options + keymaps + colorscheme + プラグイン)"
NVIM_I18N[ja:mc_reset]="管理設定をリセット"
NVIM_I18N[ja:mc_confirm_reset]="管理対象の Neovim 設定をリセットしますか?(バックアップ後、kit 管理ファイルを削除)"
NVIM_I18N[ja:mc_mode_takeover]="モード:takeover — kit がこの設定を所有"
NVIM_I18N[ja:mc_mode_overlay]="モード:overlay — after/plugin"
NVIM_I18N[ja:mc_plugins_distro_only]="ここのプラグインは distro/あなたの設定が所有 — kit は options/keymaps/colorscheme のみ重ねます。"
NVIM_I18N[ja:mc_add_plugin]="プラグインを追加(owner/repo か git-url)…"
NVIM_I18N[ja:mc_prompt_plugin]="プラグイン(owner/repo か https git URL)"
NVIM_I18N[ja:mc_prompt_leader]="leader キー(1 文字、または 'space')"
NVIM_I18N[ja:mc_pick_colorscheme]="内蔵 colorscheme を選択"
NVIM_I18N[ja:mc_node_hint]="Node が見つかりません — Node が必要な Mason LSP server には:swkit node install"

# _nvim_t KEY — localized Neovim string for $UI_LANG (en/zh/ja), fallback en -> key.
_nvim_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${NVIM_I18N[$lang:$1]:-${NVIM_I18N[en:$1]:-$1}}"
}

# Localized one-line description for distro NAME (curated only; empty for an extra git-url distro).
_nvim_distro_desc() {
  [[ -n "${NVIM_DISTRO_REPO[$1]:-}" ]] || return 0
  _nvim_t "desc_$1"
}

meta() {
  cat <<'META'
key=nvim
name=Neovim
category=common
ops=install,remove,configure,update,update-plugins
desc=Neovim editor — best-channel install (apt/tarball/snap), curated distros (LazyVim/kickstart…), lazy.nvim plugin sync, and a managed config layer (options/keymaps/colorscheme/plugins)
META
}

# --- Install probe -------------------------------------------------------------
# Exit 0 iff nvim is installed. KIT_PROBE_ONLY: boolean only (skip version/channel spawns).
# Read-only; both paths return the same exit code. Does NOT resolve home (must work under the
# catalog probe), so distro count uses $HOME best-effort.
status() {
  have_cmd nvim || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  local ver path chan="?"
  ver="$(nvim --version 2>/dev/null | head -n1)"
  path="$(command -v nvim 2>/dev/null || true)"
  if [[ "$(readlink -f "$path" 2>/dev/null)" == /opt/nvim-linux-* ]]; then chan="tarball"
  elif [[ "$path" == /snap/* ]] || { have_cmd snap && snap list nvim >/dev/null 2>&1; }; then chan="snap"
  elif pkg_installed neovim; then chan="apt"; fi
  local mf="${XDG_CONFIG_HOME:-${HOME:-}/.config}/ubuntu-setup/nvim-distros.manifest" ndistro=0
  [[ -f "$mf" ]] && ndistro="$(grep -c . "$mf" 2>/dev/null || echo 0)"
  printf '%s  ·  channel:%s  ·  distros:%s\n' "${ver:-nvim installed}" "$chan" "$ndistro"
  # Warn only on *genuinely distinct* nvim binaries (e.g. apt + tarball + snap). Dedup by real
  # target so usrmerge aliases (/bin -> /usr/bin) don't look like duplicates on a clean install.
  local p real cnt=0; local -A seen=()
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    real="$(readlink -f "$p" 2>/dev/null || printf '%s' "$p")"
    [[ -n "${seen[$real]:-}" ]] && continue
    seen[$real]=1; cnt=$(( cnt + 1 ))
  done < <(type -aP nvim 2>/dev/null || true)
  if (( cnt > 1 )); then
    log_warn "Multiple distinct nvim on PATH (see 'type -a nvim') — the first wins; remove stale ones to avoid version confusion."
  fi
  return 0
}

# --- Home / paths / preferences (user-space; refuses a sudo-wrapped run) --------
_nvim_resolve_home() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run nvim.sh as your normal user, not via sudo — its config/data live in your \$HOME"
    log_err "(~/.config, ~/.local). The apt/snap/opt steps escalate per-command on their own."
    log_err "    (re-run as '$SUDO_USER' without sudo)"
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _NV_HOME="${HOME:-}"
  [[ -n "$_NV_HOME" ]] || _NV_HOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_NV_HOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _NV_CFG="${XDG_CONFIG_HOME:-$_NV_HOME/.config}"
  _NV_DATA="${XDG_DATA_HOME:-$_NV_HOME/.local/share}"
  _NV_STATE="${XDG_STATE_HOME:-$_NV_HOME/.local/state}"
  _NV_CACHE="${XDG_CACHE_HOME:-$_NV_HOME/.cache}"
  _NV_PREF_DIR="$_NV_CFG/ubuntu-setup"
  _NV_PREF="$_NV_PREF_DIR/nvim.conf"
  _NV_MANIFEST="$_NV_PREF_DIR/nvim-distros.manifest"
}

# The user's shell rc (honors SUDO_USER's real home; never edits another user's dotfile).
_nvim_rc_file() {
  case "${SHELL:-}" in */zsh) printf '%s/.zshrc' "$_NV_HOME" ;; *) printf '%s/.bashrc' "$_NV_HOME" ;; esac
}

# nvim.conf: a tiny KEY=VALUE store, parsed with grep (never sourced). A getter: a missing key
# is normal, NOT an error — so always exit 0 (the `|| true` keeps grep's empty-match non-zero from
# tripping `set -e` at a bare `x="$(_nvim_conf_get …)"` call site). Convention: see mattpocock-skills.sh.
_nvim_conf_get() {
  [[ -f "${_NV_PREF:-}" ]] || return 0
  grep -E "^$1=" "$_NV_PREF" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}
_nvim_conf_set() {
  local key="$1" val="$2" tmp
  mkdir -p "$_NV_PREF_DIR"
  tmp="$(mktemp)"
  if [[ -f "$_NV_PREF" ]]; then grep -vE "^$key=" "$_NV_PREF" >"$tmp" 2>/dev/null || true; fi
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  mv "$tmp" "$_NV_PREF" || { rm -f "$tmp"; return 1; }
}

# --- Distro manifest (one line per kit-managed appname: appname<TAB>name<TAB>repo) ---
_nvim_manifest_add() {
  local app="$1" name="$2" repo="$3" tmp
  mkdir -p "$_NV_PREF_DIR"
  tmp="$(mktemp)"
  if [[ -f "$_NV_MANIFEST" ]]; then awk -F'\t' -v a="$app" '$1!=a' "$_NV_MANIFEST" >"$tmp" 2>/dev/null || true; fi
  printf '%s\t%s\t%s\n' "$app" "$name" "$repo" >>"$tmp"
  mv "$tmp" "$_NV_MANIFEST" || { rm -f "$tmp"; return 1; }
}
_nvim_manifest_remove() {
  local app="$1" tmp
  [[ -f "${_NV_MANIFEST:-}" ]] || return 0
  tmp="$(mktemp)"
  awk -F'\t' -v a="$app" '$1!=a' "$_NV_MANIFEST" >"$tmp" 2>/dev/null || true
  mv "$tmp" "$_NV_MANIFEST" || { rm -f "$tmp"; return 1; }
}
_nvim_manifest_has() {
  [[ -f "${_NV_MANIFEST:-}" ]] || return 1
  awk -F'\t' -v a="$1" '$1==a{f=1} END{exit f?0:1}' "$_NV_MANIFEST"
}
# Echo the appname kit-managed for distro NAME (empty + nonzero if none).
_nvim_distro_appname() {
  [[ -f "${_NV_MANIFEST:-}" ]] || return 1
  local a n
  while IFS=$'\t' read -r a n _; do
    [[ -n "$a" ]] || continue
    [[ "$n" == "$1" ]] && { printf '%s' "$a"; return 0; }
  done < "$_NV_MANIFEST"
  return 1
}

# --- Version helpers -----------------------------------------------------------
# dpkg arch -> the token in the official release asset name. Nonzero on an unsupported arch.
_nvim_arch() {
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64) printf 'x86_64' ;;
    arm64) printf 'arm64' ;;
    *) return 1 ;;
  esac
}
# Normalize a Debian/PPA version (0.11.3-0.1ubuntu2, 0.12.0~ubuntu1+git) to bare X.Y.Z. No match
# is normal (no nvim / unparseable --version) → echo empty + exit 0 so a bare `x="$(_nvim_norm_ver …)"`
# assignment never trips `set -e` (grep's empty-match is non-zero under pipefail).
_nvim_norm_ver() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true; }
# True iff $1 >= $2 (after normalization). Numeric per-segment compare (not `sort -V`).
_nvim_vercmp_ge() {
  local a b; a="$(_nvim_norm_ver "$1")"; b="$(_nvim_norm_ver "$2")"
  [[ -n "$a" ]] || return 1
  local -a aa bb; local i x y
  IFS=. read -ra aa <<<"$a"
  IFS=. read -ra bb <<<"$b"
  for i in 0 1 2; do
    x="${aa[i]:-0}"; y="${bb[i]:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}
# The running nvim's bare X.Y.Z (empty if not installed).
_nvim_running_ver() { _nvim_norm_ver "$(nvim --version 2>/dev/null | head -n1)"; }

# Is apt's neovim candidate present AND new enough? (No sudo; reads existing apt lists.)
# LC_ALL=C keeps apt-cache's field labels in English on a localized system (same rule as
# rime/android: decide on stable text, never on text that gets translated).
_nvim_apt_ok() {
  local cand
  cand="$(LC_ALL=C apt-cache policy neovim 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]] || return 1
  _nvim_vercmp_ge "$cand" "$NVIM_MIN_VERSION"
}

# Exit 0 iff nvim is installed AND new enough (>= NVIM_MIN_VERSION) for the curated distros. This
# is the install/upgrade gate — UNLIKE status(), which only checks presence. Spawns nvim, so it
# runs in real ops only (never under the KIT_PROBE_ONLY catalog probe).
_nvim_installed_ok() {
  have_cmd nvim || return 1
  _nvim_vercmp_ge "$(_nvim_running_ver)" "$NVIM_MIN_VERSION"
}

# --- SSH / where-it-applies notes ----------------------------------------------
# Neovim is a TUI, so SSH use is perfect (no desktop caveat). The only honest note is that Nerd
# Font glyphs are drawn by the CLIENT terminal — relevant only when external deps include a font.

# --- Binary channel: tarball (official stable, sha256-verified) ----------------
# Resolve the stable release asset (nvim-linux-<arch>.tar.gz) URL + sha256 from the GitHub API,
# download it, VERIFY the checksum (the trust boundary — this archive is unpacked + executed), and
# install into /opt with a /usr/local/bin/nvim symlink. No jq: parse the JSON with grep/sed anchored
# on the asset name. API/parse/verify failure is fail-fast — we NEVER unpack an unverified download.
_nvim_install_tarball() {
  local arch asset json url digest hex
  arch="$(_nvim_arch)" || { log_err "Neovim official tarballs target amd64/arm64 only (this host is $(dpkg --print-architecture 2>/dev/null || uname -m))."; return 1; }
  asset="nvim-linux-${arch}.tar.gz"
  have_cmd curl || apt_install curl ca-certificates
  log_info "Resolving the latest Neovim stable release ($asset) from GitHub…"
  json="$(curl -fsSL --max-time 30 "$NVIM_RELEASE_API" 2>/dev/null || true)"
  [[ -n "$json" ]] || { log_err "Could not reach the Neovim release API ($NVIM_RELEASE_API)."; return 1; }

  # Parse the assets array (no jq). Two pitfalls make a naive "one asset per { line" split wrong:
  # GitHub emits "name": "…" WITH a space after the colon, and each asset carries a nested
  # "uploader": {…} object — so `tr '{' '\n'` scatters an asset's name and its digest/url into
  # different segments. Instead: split on commas (no comma appears inside the name/url/digest
  # values) and run a tiny awk state machine. Each "name" line flips an in-our-asset flag (the
  # uploader object has a "login" key, NOT "name", so it can't pollute the flag); while the flag is
  # set we capture the browser_download_url + the sha256 digest — binding the checksum to the file.
  local fields
  fields="$(printf '%s' "$json" | tr ',' '\n')"
  url="$(printf '%s\n' "$fields" | awk -v a="$asset" '
    /"name":[[:space:]]*"/ { cur = (index($0, "\"" a "\"") > 0) ? 1 : 0 }
    cur && /"browser_download_url":[[:space:]]*"/ { v=$0; sub(/.*"browser_download_url":[[:space:]]*"/,"",v); sub(/".*/,"",v); print v; exit }' || true)"
  digest="$(printf '%s\n' "$fields" | awk -v a="$asset" '
    /"name":[[:space:]]*"/ { cur = (index($0, "\"" a "\"") > 0) ? 1 : 0 }
    cur && /"digest":[[:space:]]*"sha256:/ { v=$0; sub(/.*"digest":[[:space:]]*"sha256:/,"",v); sub(/".*/,"",v); print v; exit }' || true)"
  [[ -n "$url" ]]    || { log_err "Could not resolve the download URL for $asset (asset missing or the release API format changed)."; return 1; }
  [[ -n "$digest" ]] || { log_err "Could not resolve the sha256 digest for $asset — refusing to install an unverified tarball."; return 1; }
  hex="$digest"

  log_info "Channel: official Neovim stable tarball ($asset)."
  log_info "Downloading: $url"
  local tmp tarball rc=0
  tmp="$(mktemp -d)"
  tarball="$tmp/$asset"
  if ! curl -fSL --connect-timeout 30 --retry 3 --retry-delay 5 --retry-all-errors -C - "$url" -o "$tarball"; then
    rm -rf "$tmp"; log_err "Failed to download $asset."; return 1
  fi
  # Verify BEFORE unpacking — the trust boundary.
  if ! printf '%s  %s\n' "$hex" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
    rm -rf "$tmp"; log_err "sha256 verification FAILED for $asset — refusing to install."; return 1
  fi
  log_info "sha256 OK ($hex)."

  local root="/opt/nvim-linux-${arch}"
  sudo_run rm -rf "$root" || rc=$?
  if (( rc == 0 )); then sudo_run tar -C /opt -xzf "$tarball" || rc=$?; fi
  if (( rc == 0 )); then sudo_run ln -sfn "$root/bin/nvim" /usr/local/bin/nvim || rc=$?; fi
  rm -rf "$tmp"
  (( rc == 0 )) || { log_err "Failed to install the Neovim tarball into /opt."; return "$rc"; }

  # Old glibc machines can't run the supported tarball; tell the truth, don't auto-fall-back.
  if ! /usr/local/bin/nvim --version >/dev/null 2>&1; then
    log_warn "Installed to $root but 'nvim --version' failed — likely a glibc too old for the"
    log_warn "supported build. See the unsupported (older-glibc) builds at:"
    log_warn "    https://github.com/neovim/neovim-releases/releases"
  fi
  return 0
}

# --- Binary: install / remove / update -----------------------------------------

# do_install — best channel + version gate. Prints the channel actually used. Idempotent.
do_install() {
  _nvim_resolve_home || return 1
  if _nvim_installed_ok; then
    log_info "Neovim is already installed and new enough ($(status 2>/dev/null)) — to refresh a tarball install, run: ${0##*/} update"
    log_info "For distros / plugins / deps, run:  swkit nvim configure --recommended   (or: swkit nvim)"
    return 0
  fi
  # Already present but older than the curated-distro floor? Upgrade it. A leftover apt /usr/bin/nvim
  # is the classic "LazyVim requires >= 0.11.2" trap, so clear it — but only AFTER the new binary
  # lands (deferred), so a failed download never leaves you with no nvim at all. The tarball's
  # /usr/local/bin/nvim outranks apt's /usr/bin/nvim on PATH, so the stale apt copy is hygiene, not
  # a blocker. NON-apt stale installs (manual tarball/snap) are left for their own channel.
  local drop_apt=0
  if have_cmd nvim; then
    log_info "Installed Neovim ($(_nvim_running_ver)) is older than ${NVIM_MIN_VERSION} — upgrading."
    if pkg_installed neovim && ! _nvim_apt_ok; then drop_apt=1; fi
  fi
  if _nvim_apt_ok; then
    log_info "Channel: apt (neovim — candidate >= ${NVIM_MIN_VERSION})."
    apt_install neovim
    _nvim_conf_set CHANNEL apt
  elif _nvim_install_tarball; then
    _nvim_conf_set CHANNEL tarball
    if (( drop_apt )); then log_info "Removing the now-shadowed outdated apt 'neovim'…"; apt_remove neovim; fi
  else
    log_warn "apt is too old and the tarball channel failed — falling back to snap (lags upstream)."
    have_cmd snap || { log_err "snap is not available; cannot install Neovim."; return 1; }
    log_info "Channel: snap (nvim --classic)."
    sudo_run snap install nvim --classic
    _nvim_conf_set CHANNEL snap
    if (( drop_apt )); then log_info "Removing the now-shadowed outdated apt 'neovim'…"; apt_remove neovim; fi
  fi
  log_info "Installed Neovim ($(status 2>/dev/null))."
  log_info "Add a distro + plugins with:  swkit nvim configure --recommended   (or open: swkit nvim)"
}

# do_remove — conservative: pick the source and uninstall the binary, keeping ~/.config/nvim* and
# distro data (user config is precious). Prints how to wipe data fully.
do_remove() {
  _nvim_resolve_home || return 1
  if ! status >/dev/null 2>&1; then
    log_info "Neovim is not installed — nothing to remove."
    return 0
  fi
  local path; path="$(command -v nvim 2>/dev/null || true)"
  if pkg_installed neovim; then
    apt_remove neovim
    log_info "Removed the apt neovim package."
  elif [[ "$path" == /snap/* ]] || { have_cmd snap && snap list nvim >/dev/null 2>&1; }; then
    sudo_run snap remove nvim
    log_info "Removed the nvim snap."
  elif [[ "$(readlink -f "$path" 2>/dev/null)" == /opt/nvim-linux-* ]]; then
    local arch root; arch="$(_nvim_arch || true)"; root="/opt/nvim-linux-${arch:-x86_64}"
    sudo_run rm -f /usr/local/bin/nvim
    [[ -n "$arch" ]] && sudo_run rm -rf "$root"
    log_info "Removed the tarball install ($root) and the /usr/local/bin/nvim symlink."
  else
    log_warn "nvim is on PATH but its install source is unrecognized — remove it the way you installed it."
    return 1
  fi
  log_info "Kept your ~/.config/nvim* and distro data. To wipe a distro fully, run: ${0##*/} remove-distro <name>."
}

# do_update — meaningful only for the tarball channel (apt/snap track the system). Re-resolves the
# latest stable and reinstalls over /opt. Installs first if Neovim is absent.
do_update() {
  _nvim_resolve_home || return 1
  if ! status >/dev/null 2>&1; then
    log_info "Neovim is not installed — installing the latest instead."
    do_install
    return $?
  fi
  local path; path="$(command -v nvim 2>/dev/null || true)"
  if pkg_installed neovim; then
    if _nvim_apt_ok; then
      log_info "Neovim was installed via apt — update it with your system: sudo apt update && sudo apt upgrade."
      return 0
    fi
    # apt's candidate is too old for the curated distros — `apt upgrade` can't help. Reuse the
    # install path: it upgrades to the official tarball and clears the now-shadowed apt package.
    log_info "The apt 'neovim' candidate is older than ${NVIM_MIN_VERSION} — upgrading to the official tarball instead."
    do_install
    return $?
  fi
  if [[ "$path" == /snap/* ]] || { have_cmd snap && snap list nvim >/dev/null 2>&1; }; then
    log_info "Neovim was installed via snap — update it with: sudo snap refresh nvim."
    return 0
  fi
  local cur; cur="$(_nvim_running_ver)"
  _nvim_install_tarball || return 1
  _nvim_conf_set CHANNEL tarball
  log_info "Neovim is now $(status 2>/dev/null) (was ${cur:-unknown})."
}

# --- Distro installer ----------------------------------------------------------

# Validate a distro short name / appname (no path-injection metacharacters).
_nvim_name_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
# Validate a git URL: accept the common https/ssh/git forms with a conservative charset, barring
# shell metacharacters ($ ` & ; ' " ( ) * | < > space) even though the URL is only ever passed
# quoted to git — defense in depth, per the "loosen but block injection metacharacters" rule.
_nvim_giturl_valid() { [[ "$1" =~ ^(https?://|git@|ssh://|git://)[A-Za-z0-9._~:/?#@!+,=%-]+$ ]]; }

# Back up a NON-EMPTY config directory before we take it over: rename it aside with a timestamp
# (directory-level — backup_file only handles single files). No-op if the dir is absent/empty.
_nvim_backup_dir() {
  local d="$1" bak
  [[ -d "$d" ]] || return 0
  # Empty (no entries)? nothing to preserve.
  [[ -n "$(ls -A "$d" 2>/dev/null || true)" ]] || return 0
  bak="${d}.bak.$(date +%s)"
  mv "$d" "$bak"
  log_info "Backed up $d -> $bak"
}

# Path guard for a managed config dir: must be a non-empty, non-symlinked path strictly under
# ~/.config, with no `..` escape and not equal to ~/.config itself. Delegates to the shared
# kit_path_safe_under (anchor=$_NV_CFG) so the pre-deletion guard is identical across scripts; the
# shared version also rejects symlinks (kit's targets are real git-cloned dirs / real managed files)
# and log_warn's on refusal. Every call site already wraps this with its own log_err+return, so the
# extra warning only ever appears on an actual refusal, not in normal control flow.
_nvim_path_under_config() {
  kit_path_safe_under "$1" "$_NV_CFG"
}

# Add ($1=alias for appname) or remove the managed `nvim-<name>` alias line in the shell rc.
readonly NVIM_ALIAS_MARKER="# ubuntu-setup (nvim distro alias)"
_nvim_alias_add() {
  local name="$1" appname="$2" rc line
  rc="$(_nvim_rc_file)"
  line="alias nvim-${name}='NVIM_APPNAME=${appname} nvim' $NVIM_ALIAS_MARKER"
  if [[ -f "$rc" ]] && grep -qxF "$line" "$rc"; then return 0; fi
  [[ -s "$rc" ]] && backup_file "$rc"
  # Drop any stale alias for the same name first, then append the fresh one.
  if [[ -f "$rc" ]] && grep -qF "alias nvim-${name}=" "$rc"; then
    local tmp; tmp="$(mktemp)"
    grep -vF "alias nvim-${name}=" "$rc" >"$tmp" || true
    mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
  fi
  printf '%s\n' "$line" >>"$rc"
  log_info "Added alias 'nvim-${name}' (NVIM_APPNAME=${appname}) to $rc — open a new shell or 'source $rc'."
}
_nvim_alias_remove() {
  local name="$1" rc
  rc="$(_nvim_rc_file)"
  [[ -f "$rc" ]] && grep -qF "alias nvim-${name}=" "$rc" || return 0
  backup_file "$rc"
  local tmp; tmp="$(mktemp)"
  grep -vF "alias nvim-${name}=" "$rc" >"$tmp" || true
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
  log_info "Removed the managed 'nvim-${name}' alias from $rc."
}

# Resolve the repo URL for a distro name: curated table, else an extra git-url in nvim.conf
# (EXTRA_DISTRO_<name>). Echoes the URL; nonzero if unknown.
_nvim_distro_repo() {
  local name="$1" url
  url="${NVIM_DISTRO_REPO[$name]:-}"
  [[ -n "$url" ]] || url="$(_nvim_conf_get "EXTRA_DISTRO_${name}")"
  [[ -n "$url" ]] || return 1
  printf '%s' "$url"
}

# Drive a distro's bundled lazy.nvim headless: sync | update | clean. Bounded by `timeout` so a
# stuck/offline run never hangs the script. Needs a working nvim.
_nvim_sync() {
  local appname="$1" op="${2:-sync}" cmd
  have_cmd nvim || { log_err "$(_nvim_t not_installed_first)"; return 1; }
  case "$op" in
    sync)   cmd='+Lazy! sync' ;;
    update) cmd='+Lazy! update' ;;
    clean)  cmd='+Lazy! clean' ;;
    *) log_err "Unknown plugin op: $op"; return 2 ;;
  esac
  log_info "Driving lazy.nvim ($op) for NVIM_APPNAME=${appname} (headless)…"
  if have_cmd timeout; then
    NVIM_APPNAME="$appname" timeout 600 nvim --headless "$cmd" +qa
  else
    NVIM_APPNAME="$appname" nvim --headless "$cmd" +qa
  fi
}

# install-distro <name> [appname] — clone a curated/extra distro, isolate via NVIM_APPNAME (smart
# default: take over an empty ~/.config/nvim, else nvim-<name>), manifest it, alias if isolated,
# then headless-sync its plugins.
do_install_distro() {
  _nvim_resolve_home || return 1
  local name="${1:-}" appname="${2:-}"
  [[ -n "$name" ]] || { log_err "Usage: ${0##*/} install-distro <${NVIM_DISTRO_ORDER// /|}|name> [appname]"; return 2; }
  _nvim_name_valid "$name" || { log_err "Invalid distro name: $name (letters/digits/._- only)."; return 2; }
  local repo; repo="$(_nvim_distro_repo "$name")" || { log_err "Unknown distro: $name (curated: ${NVIM_DISTRO_ORDER}; add others with: ${0##*/} add-distro <name> <git-url>)."; return 2; }

  have_cmd git || { log_err "git is required to clone a distro — install it with: swkit git install (or: ${0##*/} ensure-deps)."; return 1; }

  # Smart default appname: explicit wins; else take over an empty/absent default nvim, else isolate.
  if [[ -z "$appname" ]]; then
    if [[ ! -d "$_NV_CFG/nvim" ]] || [[ -z "$(ls -A "$_NV_CFG/nvim" 2>/dev/null || true)" ]]; then
      appname="nvim"
    else
      appname="nvim-${name}"
    fi
  fi
  _nvim_name_valid "$appname" || { log_err "Invalid appname: $appname."; return 2; }
  local dest="$_NV_CFG/$appname"
  log_info "Installing distro '$name' into $dest (NVIM_APPNAME=${appname})."

  _nvim_path_under_config "$dest" || { log_err "Refusing to write outside ~/.config: $dest"; return 1; }
  _nvim_backup_dir "$dest"
  git clone --depth 1 "$repo" "$dest"

  _nvim_manifest_add "$appname" "$name" "$repo"
  # Isolated configs get a convenience alias; the default `nvim` does not need one.
  if [[ "$appname" != "nvim" ]]; then _nvim_alias_add "$name" "$appname"; fi

  # Sync plugins now when nvim is present and new enough; otherwise install/upgrade it first (the
  # user opted into auto-upgrade) and then sync — so a freshly cloned distro is never left in a
  # state where launching it just errors out ("requires Neovim >= …"). do_install is idempotent,
  # so calling it here is safe even when --recommended already ran it.
  if _nvim_installed_ok; then
    _nvim_sync "$appname" sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} sync-plugins ${appname}."
  else
    log_info "Neovim is missing or older than ${NVIM_MIN_VERSION} — installing/upgrading it first…"
    do_install
    if _nvim_installed_ok; then
      _nvim_sync "$appname" sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} sync-plugins ${appname}."
    else
      log_warn "Could not get Neovim >= ${NVIM_MIN_VERSION} automatically — sync later with: ${0##*/} sync-plugins ${appname}."
    fi
  fi
  if [[ "$appname" == "nvim" ]]; then
    log_info "Launch it with:  nvim"
  else
    log_info "Launch it with:  nvim-${name}   (NVIM_APPNAME=${appname} nvim)"
  fi
}

# remove-distro <name|appname> — resolve the appname from the manifest, guard the path, back up
# the config dir, then delete it + its data/state/cache and the managed alias.
do_remove_distro() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"
  [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} remove-distro <name|appname>"; return 2; }
  _nvim_name_valid "$arg" || { log_err "Invalid argument: $arg."; return 2; }

  # Resolve appname + name from the manifest (accept either a distro name or an appname).
  local appname="" name=""
  if appname="$(_nvim_distro_appname "$arg")" && [[ -n "$appname" ]]; then
    name="$arg"
  elif _nvim_manifest_has "$arg"; then
    appname="$arg"
    name="$(awk -F'\t' -v a="$arg" '$1==a{print $2; exit}' "$_NV_MANIFEST" 2>/dev/null || true)"
  else
    log_info "No kit-managed distro '$arg' found in the manifest — nothing to remove."
    return 0
  fi

  # Defense in depth: the appname came from the manifest (a user could hand-corrupt it), so
  # re-validate it just like the install path before it becomes part of any rm target. The
  # path guard below is the real backstop, but a clean name keeps every derived path sane.
  _nvim_name_valid "$appname" || { log_err "Manifest holds an invalid appname for '$arg': $appname (refusing to remove)."; return 1; }
  local dest="$_NV_CFG/$appname"
  _nvim_path_under_config "$dest" || { log_err "Refusing to remove a path outside ~/.config: $dest"; return 1; }

  if [[ -d "$dest" ]]; then
    _nvim_backup_dir "$dest"
    rm -rf "${dest:?}"
    log_info "Removed $dest (a timestamped backup was kept)."
  else
    log_info "$dest is already gone."
  fi
  # Runtime products (no precious user data) — safe to delete.
  rm -rf "${_NV_DATA:?}/$appname" "${_NV_STATE:?}/$appname" "${_NV_CACHE:?}/$appname"
  [[ -n "$name" ]] && _nvim_alias_remove "$name"
  _nvim_manifest_remove "$appname"
  log_info "Removed distro '${name:-$appname}' (appname ${appname})."
}

# add-distro <name> <git-url> — record an extra (non-curated) distro so install-distro can use it.
do_add_distro() {
  _nvim_resolve_home || return 1
  local name="${1:-}" url="${2:-}"
  [[ -n "$name" && -n "$url" ]] || { log_err "Usage: ${0##*/} add-distro <name> <git-url>"; return 2; }
  _nvim_name_valid "$name" || { log_err "Invalid distro name: $name (letters/digits/._- only)."; return 2; }
  [[ -z "${NVIM_DISTRO_REPO[$name]:-}" ]] || { log_err "'$name' is a curated distro already — pick another name."; return 2; }
  _nvim_giturl_valid "$url" || { log_err "Invalid git URL: $url"; return 2; }
  _nvim_conf_set "EXTRA_DISTRO_${name}" "$url"
  log_info "Registered distro '$name' -> $url. Install it with: ${0##*/} install-distro $name"
}

# --- Plugin sync ops (parametric; ui-reachable) --------------------------------
do_sync_plugins()   { _nvim_resolve_home || return 1; _nvim_sync "${1:-nvim}" sync; }
do_update_plugins() { _nvim_resolve_home || return 1; _nvim_sync "${1:-nvim}" update; }
do_clean_plugins()  { _nvim_resolve_home || return 1; _nvim_sync "${1:-nvim}" clean; }

# --- External deps -------------------------------------------------------------
# Install the apt packages a distro typically needs + a Nerd Font (best-effort, via fonts.sh).
# Clipboard helpers are best-effort and only matter with a display (SSH note printed). NEVER Node:
# Mason's LSP runtime is opt-in — if absent we point at `swkit node install`, we never auto-install.
_nvim_ensure_deps() {
  # shellcheck disable=SC2086  # word-splitting NVIM_DEP_PKGS into separate package args is intended
  apt_install $NVIM_DEP_PKGS

  # Nerd Font (user-space, never sudo). Glyphs render in the LOCAL/client terminal.
  local fonts="$KIT_SCRIPTS_DIR/fonts.sh"
  if [[ -x "$fonts" ]]; then
    if "$fonts" status >/dev/null 2>&1; then
      log_info "Recommended Nerd Font (MesloLGS NF) already installed."
    else
      log_info "Installing the recommended Nerd Font (MesloLGS NF) via fonts.sh…"
      "$fonts" install meslolgs || log_warn "Could not install the Nerd Font automatically — run 'swkit fonts install' yourself."
    fi
  else
    log_warn "fonts.sh not found; install a Nerd Font with 'swkit fonts install' for theme/icon glyphs."
  fi
  log_warn "Nerd Font glyphs render in your LOCAL terminal — over SSH, also install/select MesloLGS NF on your client."

  # Clipboard providers (best-effort; only useful with a display).
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    apt_install wl-clipboard || log_warn "Could not install wl-clipboard (clipboard provider)."
  elif [[ -n "${DISPLAY:-}" ]]; then
    apt_install xclip || log_warn "Could not install xclip (clipboard provider)."
  else
    log_info "No display detected — skipping a clipboard provider (Neovim can use OSC52 over SSH)."
  fi

  # Node is opt-in (Mason LSP runtime); never auto-installed.
  if ! have_cmd node; then
    log_info "Node is not installed. For Mason-managed LSP/tools that need it, run: swkit node install (opt-in)."
  fi
}
do_ensure_deps() { _nvim_resolve_home || return 1; _nvim_ensure_deps; }

# --- Default editor ------------------------------------------------------------
readonly NVIM_EDITOR_MARKER="# ubuntu-setup (nvim as default editor)"

# set-default-editor [off] — user-space: write/remove managed EDITOR/VISUAL=nvim lines in the
# shell rc; best-effort system: register/set (or auto) update-alternatives `editor`.
do_set_default_editor() {
  _nvim_resolve_home || return 1
  local mode="${1:-on}" rc
  rc="$(_nvim_rc_file)"
  case "$mode" in
    on|"")
      have_cmd nvim || { log_err "$(_nvim_t not_installed_first)"; return 1; }
      local line_e="export EDITOR=nvim $NVIM_EDITOR_MARKER"
      local line_v="export VISUAL=nvim $NVIM_EDITOR_MARKER"
      export EDITOR=nvim VISUAL=nvim
      if [[ -f "$rc" ]] && grep -qxF "$line_e" "$rc" && grep -qxF "$line_v" "$rc"; then
        log_info "EDITOR/VISUAL already set to nvim via $rc."
      else
        [[ -s "$rc" ]] && backup_file "$rc"
        grep -qxF "$line_e" "$rc" 2>/dev/null || printf '%s\n' "$line_e" >>"$rc"
        grep -qxF "$line_v" "$rc" 2>/dev/null || printf '%s\n' "$line_v" >>"$rc"
        log_info "Set EDITOR/VISUAL=nvim in $rc — open a new shell or 'source $rc'."
      fi
      # Best-effort system alternative (tarball installs need --install first; apt's neovim
      # self-registers). RC_NEED_SUDO / any failure only warns — never aborts.
      local path; path="$(command -v nvim 2>/dev/null || true)"
      if [[ -n "$path" ]]; then
        sudo_run update-alternatives --install /usr/bin/editor editor "$path" 60 >/dev/null 2>&1 \
          || log_warn "Could not register nvim as the system 'editor' alternative (needs sudo) — the shell EDITOR/VISUAL still apply."
        sudo_run update-alternatives --set editor "$path" >/dev/null 2>&1 \
          || log_warn "Could not set the system 'editor' alternative to nvim (needs sudo)."
      fi
      _nvim_conf_set DEFAULT_EDITOR on
      ;;
    off)
      if [[ -f "$rc" ]] && grep -qF "$NVIM_EDITOR_MARKER" "$rc"; then
        backup_file "$rc"
        local tmp; tmp="$(mktemp)"
        grep -vF "$NVIM_EDITOR_MARKER" "$rc" >"$tmp" || true
        mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
        log_info "Removed the managed EDITOR/VISUAL=nvim lines from $rc."
      else
        log_info "No managed EDITOR/VISUAL lines in $rc — nothing to remove."
      fi
      sudo_run update-alternatives --auto editor >/dev/null 2>&1 \
        || log_warn "Could not reset the system 'editor' alternative to auto (needs sudo)."
      _nvim_conf_set DEFAULT_EDITOR off
      ;;
    *) log_err "set-default-editor takes nothing (on) or 'off'."; return 2 ;;
  esac
}

# --- Managed config layer: helpers + generators + ops --------------------------
# All user-space (no sudo). nvim.conf keys: CFG_OPTIONS/CFG_KEYMAPS (on|off), CFG_LEADER,
# CFG_COLORSCHEME, CFG_PLUGINS (space list of curated keys), CFG_LSP (on|off), EXTRA_PLUGIN_<slug>,
# MANAGED_MODE_<appname> (takeover|overlay — the mode lock).

# Remove a key from nvim.conf (a missing file/key is a no-op).
_nvim_conf_unset() {
  local key="$1" tmp
  [[ -f "${_NV_PREF:-}" ]] || return 0
  tmp="$(mktemp)"
  grep -vE "^$key=" "$_NV_PREF" >"$tmp" 2>/dev/null || true
  mv "$tmp" "$_NV_PREF" || { rm -f "$tmp"; return 1; }
}
# Add / remove a token in a space-separated list value (idempotent).
_nvim_cfg_list_add() {
  local key="$1" tok="$2" cur new w
  cur="$(_nvim_conf_get "$key")"
  for w in $cur; do [[ "$w" == "$tok" ]] && return 0; done
  new="${cur:+$cur }$tok"
  _nvim_conf_set "$key" "$new"
}
_nvim_cfg_list_remove() {
  local key="$1" tok="$2" cur new="" w
  cur="$(_nvim_conf_get "$key")"
  for w in $cur; do [[ "$w" == "$tok" ]] || new="${new:+$new }$w"; done
  _nvim_conf_set "$key" "$new"
}

# --- Validators (block injection into the generated Lua / conf keys) ------------
# Leader: the word 'space', or any single character safe inside the generated `vim.g.mapleader =
# "<x>"` Lua string. Only a double-quote, a backslash, or whitespace/control chars would break (or
# inject into) that string; everything else is fine — including common picks like ; < | & ( ) : that
# the old over-strict allow-list wrongly rejected. (Use the word 'space' for <Space>.)
_nvim_leader_valid() {
  [[ "$1" == space ]] && return 0
  [[ ${#1} -eq 1 ]] || return 1
  case "$1" in '"'|\\|[[:space:]]|[[:cntrl:]]) return 1 ;; esac
  return 0
}
# Built-in colorscheme name (loose; emitted into a Lua double-quoted string).
_nvim_colorscheme_valid() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
# A conf-key-safe slug for an arbitrary plugin spec (owner/repo or git URL).
_nvim_plugin_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
# Echo non-curated plugin specs recorded as EXTRA_PLUGIN_<slug>=<owner/repo|giturl>, one per line.
_nvim_extra_plugins() {
  [[ -f "${_NV_PREF:-}" ]] || return 0
  grep -E '^EXTRA_PLUGIN_[A-Za-z0-9_]+=' "$_NV_PREF" 2>/dev/null | cut -d= -f2- || true
}
# True iff the takeover config should bootstrap lazy.nvim (any plugin requested).
_nvim_has_plugins() {
  [[ -n "$(_nvim_conf_get CFG_PLUGINS)" ]] && return 0
  [[ "$(_nvim_conf_get CFG_LSP)" == on ]] && return 0
  [[ -n "$(_nvim_extra_plugins)" ]] && return 0
  return 1
}

# --- Config paths + mode detection ---------------------------------------------
# The managed overlay file lives in the TOP-LEVEL after/plugin of the appname's config dir — verified
# to be sourced last even under lazy.nvim/LazyVim (NOT lua/after/, which would need require()).
_nvim_cfg_overlay_file() { printf '%s/%s/after/plugin/ubuntu-setup.lua' "$_NV_CFG" "$1"; }

# True iff $1 is a kit-managed file (first line is our marker). Uses an exact string compare, not
# grep — the marker begins with "--", which grep would parse as an option.
_nvim_cfg_is_managed() {
  local first
  [[ -f "$1" ]] || return 1
  IFS= read -r first <"$1" || true
  [[ "$first" == "$NVIM_CFG_MARKER" ]]
}

# Echo 'takeover' or 'overlay' for an appname. Priority: conf lock (so a takeover never flips to
# overlay once its init.lua makes the dir non-empty) -> kit distro (a distro owns it) -> empty
# default nvim (eligible for takeover) -> otherwise overlay. Only the default `nvim` can take over.
_nvim_cfg_mode() {
  local app="${1:-nvim}" locked
  locked="$(_nvim_conf_get "MANAGED_MODE_${app}")"
  [[ -n "$locked" ]] && { printf '%s' "$locked"; return 0; }
  _nvim_manifest_has "$app" && { printf 'overlay'; return 0; }
  if [[ "$app" == nvim ]]; then
    local d="$_NV_CFG/nvim"
    if [[ ! -d "$d" ]] || [[ -z "$(ls -A "$d" 2>/dev/null || true)" ]]; then printf 'takeover'; return 0; fi
  fi
  printf 'overlay'
}

# --- Lua generators (pure; stdout only) ----------------------------------------
_nvim_gen_options() {
  [[ "$(_nvim_conf_get CFG_OPTIONS)" == on ]] || return 0
  cat <<'LUA'
-- options (ubuntu-setup best-practice baseline)
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2
vim.opt.smartindent = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.termguicolors = true
vim.opt.scrolloff = 4
vim.opt.signcolumn = "yes"
vim.opt.undofile = true
vim.opt.mouse = "a"
vim.opt.cursorline = true
vim.opt.clipboard = "unnamedplus"
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.wrap = false
LUA
}
_nvim_gen_keymaps() {
  [[ "$(_nvim_conf_get CFG_KEYMAPS)" == on ]] || return 0
  cat <<'LUA'
-- keymaps (ubuntu-setup quality-of-life; best-effort under a distro's lazy-loaded maps)
vim.keymap.set("n", "<leader>w", "<cmd>write<cr>", { desc = "Save" })
vim.keymap.set("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit window" })
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })
vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Window left" })
vim.keymap.set("n", "<C-j>", "<C-w>j", { desc = "Window down" })
vim.keymap.set("n", "<C-k>", "<C-w>k", { desc = "Window up" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Window right" })
vim.keymap.set("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Prev buffer" })
vim.keymap.set("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next buffer" })
LUA
}
# Leader (takeover only; localleader is always backslash). Validated upstream.
_nvim_gen_leader() {
  local l; l="$(_nvim_conf_get CFG_LEADER)"; [[ -n "$l" ]] || l="space"
  [[ "$l" == space ]] && l=" "
  printf 'vim.g.mapleader = "%s"\n' "$l"
  printf 'vim.g.maplocalleader = "\\\\"\n'
}
_nvim_gen_colorscheme() {
  local c; c="$(_nvim_conf_get CFG_COLORSCHEME)"
  [[ -n "$c" ]] || return 0
  printf 'pcall(vim.cmd.colorscheme, "%s")\n' "$c"
}
# lazy.nvim plugin specs from CFG_PLUGINS + CFG_LSP + EXTRA_PLUGIN_* (takeover only).
_nvim_gen_plugin_spec() {
  local key plugins val
  plugins="$(_nvim_conf_get CFG_PLUGINS)"
  for key in $plugins; do
    case "$key" in
      treesitter) cat <<'LUA'
  { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate", config = function()
      require("nvim-treesitter.configs").setup({ ensure_installed = { "lua", "vim", "vimdoc", "bash" }, highlight = { enable = true }, indent = { enable = true } })
    end },
LUA
        ;;
      telescope) printf '  { "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" }, opts = {} },\n' ;;
      gitsigns)  printf '  { "lewis6991/gitsigns.nvim", opts = {} },\n' ;;
      which-key) printf '  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },\n' ;;
      lualine)   printf '  { "nvim-lualine/lualine.nvim", opts = {} },\n' ;;
    esac
  done
  if [[ "$(_nvim_conf_get CFG_LSP)" == on ]]; then
    cat <<'LUA'
  { "mason-org/mason.nvim", opts = {} },
  { "mason-org/mason-lspconfig.nvim", opts = {}, dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig" } },
  { "neovim/nvim-lspconfig" },
  { "saghen/blink.cmp", version = "1.*", opts = {} },
LUA
  fi
  while IFS= read -r val; do
    [[ -n "$val" ]] || continue
    if [[ "$val" == *://* || "$val" == git@* ]]; then printf '  { url = "%s" },\n' "$val"
    else printf '  { "%s" },\n' "$val"; fi
  done < <(_nvim_extra_plugins)
}

# --- Renderers (assemble the full managed file to stdout) -----------------------
_nvim_render_overlay() {
  printf '%s\n' "$NVIM_CFG_MARKER"
  cat <<'LUA'
-- Generated by `swkit nvim` — sourced LAST (after/plugin), overriding distro/your options &
-- colorscheme. Do NOT edit (regenerated on every change); put your own config elsewhere.
LUA
  _nvim_gen_options
  _nvim_gen_keymaps
  _nvim_gen_colorscheme
  printf '%s\n' "$NVIM_CFG_MARKER_END"
}
_nvim_render_takeover() {
  printf '%s\n' "$NVIM_CFG_MARKER"
  cat <<'LUA'
-- Generated by `swkit nvim` (kit owns this init.lua; regenerated on every change).
-- Put your own customizations under ~/.config/nvim/lua/ and require them at the end.
LUA
  _nvim_gen_leader
  _nvim_gen_options
  _nvim_gen_keymaps
  if _nvim_has_plugins; then
    local color; color="$(_nvim_conf_get CFG_COLORSCHEME)"; [[ -n "$color" ]] || color="$NVIM_CFG_RECOMMENDED_COLOR"
    cat <<'LUA'
-- bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then error("Failed to clone lazy.nvim:\n" .. out) end
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({
  spec = {
LUA
    _nvim_gen_plugin_spec
    printf '  },\n  install = { colorscheme = { "%s" } },\n  checker = { enabled = false },\n})\n' "$color"
  fi
  _nvim_gen_colorscheme
  printf '%s\n' "$NVIM_CFG_MARKER_END"
}

# --- Apply / reset -------------------------------------------------------------
_nvim_apply_overlay() {
  local app="$1" file dir tmp
  file="$(_nvim_cfg_overlay_file "$app")"
  dir="$(dirname "$file")"
  _nvim_path_under_config "$file" || { log_err "Refusing to write outside ~/.config: $file"; return 1; }
  if [[ -f "$file" ]] && ! _nvim_cfg_is_managed "$file"; then
    log_err "$file exists but is not kit-managed — refusing to overwrite (move it aside first)."; return 1
  fi
  mkdir -p "$dir"
  [[ -f "$file" ]] && backup_file "$file"
  tmp="$(mktemp)"
  _nvim_render_overlay >"$tmp"
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  _nvim_conf_set "MANAGED_MODE_${app}" overlay
  log_info "Wrote managed overlay: $file"
  log_info "Sourced after all plugins; restart nvim${app:+ (NVIM_APPNAME=$app)} to apply."
  _nvim_has_plugins && log_warn "Plugins/LSP are configured but IGNORED in overlay mode — a distro/your config owns plugins here."
  return 0
}
_nvim_apply_takeover() {
  local dir="$_NV_CFG/nvim" file="$_NV_CFG/nvim/init.lua" tmp
  _nvim_path_under_config "$dir" || { log_err "Refusing to write outside ~/.config: $dir"; return 1; }
  if [[ -f "$file" ]] && ! _nvim_cfg_is_managed "$file"; then
    log_err "$file exists and is not kit-managed — refusing to take it over (use an isolated appname or move it aside)."; return 1
  fi
  # Defensive: a non-empty, non-managed dir would normally be detected as overlay; back it up if we
  # somehow reach takeover here.
  if [[ ! -f "$file" ]] && [[ -d "$dir" ]] && [[ -n "$(ls -A "$dir" 2>/dev/null || true)" ]]; then
    _nvim_backup_dir "$dir"
  fi
  mkdir -p "$dir"
  [[ -f "$file" ]] && backup_file "$file"
  tmp="$(mktemp)"
  _nvim_render_takeover >"$tmp"
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  _nvim_conf_set MANAGED_MODE_nvim takeover
  log_info "Wrote kit-managed init.lua: $file"
  if _nvim_has_plugins; then
    if _nvim_installed_ok; then
      _nvim_sync nvim sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} sync-plugins."
    else
      log_info "Neovim is missing or older than ${NVIM_MIN_VERSION} — installing/upgrading it first…"
      do_install
      if _nvim_installed_ok; then
        _nvim_sync nvim sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} sync-plugins."
      else
        log_warn "Could not get Neovim >= ${NVIM_MIN_VERSION} automatically — sync later with: ${0##*/} sync-plugins."
      fi
    fi
    have_cmd node || log_info "$(_nvim_t mc_node_hint)"
    if ! { have_cmd cc || have_cmd gcc; } || ! have_cmd rg; then
      log_warn "Curated plugins need external deps (a C compiler for treesitter, ripgrep/fd for telescope). Run: ${0##*/} ensure-deps"
    fi
  fi
  log_info "Launch it with:  nvim"
  return 0
}

# Worker: regenerate the managed file for appname $1 in its detected mode. Setters call this with
# an explicit appname; the config-apply op parses --app then delegates here.
_nvim_config_apply() {
  local app="${1:-nvim}"
  _nvim_resolve_home || return 1
  _nvim_name_valid "$app" || { log_err "Invalid appname: $app (letters/digits/._- only)."; return 2; }
  if [[ "$(_nvim_cfg_mode "$app")" == takeover ]]; then _nvim_apply_takeover; else _nvim_apply_overlay "$app"; fi
}
# config-apply [--app <name>] — regenerate the managed file for the appname's detected mode.
do_config_apply() {
  local app="nvim"
  while (( $# > 0 )); do
    case "$1" in
      --app)   [[ $# -ge 2 ]] || { log_err "--app needs a name."; return 2; }; app="$2"; shift 2 ;;
      --app=*) app="${1#--app=}"; shift ;;
      *) log_err "Unknown config-apply option: $1"; return 2 ;;
    esac
  done
  _nvim_config_apply "$app"
}

# config-reset [--app <name>] — remove kit-managed files + clear the component state (keeps backups).
do_config_reset() {
  _nvim_resolve_home || return 1
  local app="nvim"
  while (( $# > 0 )); do
    case "$1" in
      --app)   [[ $# -ge 2 ]] || { log_err "--app needs a name."; return 2; }; app="$2"; shift 2 ;;
      --app=*) app="${1#--app=}"; shift ;;
      *) log_err "Unknown config-reset option: $1"; return 2 ;;
    esac
  done
  _nvim_name_valid "$app" || { log_err "Invalid appname: $app."; return 2; }
  if [[ "$(_nvim_cfg_mode "$app")" == takeover ]]; then
    local dir="$_NV_CFG/nvim" file="$_NV_CFG/nvim/init.lua"
    if _nvim_cfg_is_managed "$file"; then
      _nvim_path_under_config "$dir" || { log_err "Refusing to touch outside ~/.config: $dir"; return 1; }
      _nvim_backup_dir "$dir"
      rm -rf "${_NV_DATA:?}/nvim/lazy" 2>/dev/null || true
      log_info "Removed kit-managed init.lua (backed up the config dir aside)."
    else
      log_info "No kit-managed init.lua at $file — nothing to reset."
    fi
  else
    local file; file="$(_nvim_cfg_overlay_file "$app")"
    if _nvim_cfg_is_managed "$file"; then
      _nvim_path_under_config "$file" || { log_err "Refusing to remove outside ~/.config: $file"; return 1; }
      backup_file "$file"; rm -f "$file"
      log_info "Removed managed overlay: $file (a backup was kept)."
    else
      log_info "No kit-managed overlay for appname '$app' — nothing to reset."
    fi
  fi
  _nvim_conf_unset "MANAGED_MODE_${app}"
  # Clear the component prefs for a clean slate.
  local k
  for k in CFG_OPTIONS CFG_KEYMAPS CFG_LEADER CFG_COLORSCHEME CFG_PLUGINS CFG_LSP; do _nvim_conf_unset "$k"; done
  if [[ -f "${_NV_PREF:-}" ]]; then
    local tmp; tmp="$(mktemp)"
    grep -vE '^EXTRA_PLUGIN_' "$_NV_PREF" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$_NV_PREF" || rm -f "$tmp"
  fi
}

# --- Component setters (each persists state, then re-applies) -------------------
do_set_options() {
  _nvim_resolve_home || return 1
  local v="${1:-on}"; case "$v" in on|off) ;; *) log_err "set-options takes on|off."; return 2 ;; esac
  _nvim_conf_set CFG_OPTIONS "$v"; _nvim_config_apply nvim
}
do_set_keymaps() {
  _nvim_resolve_home || return 1
  local v="${1:-on}"; case "$v" in on|off) ;; *) log_err "set-keymaps takes on|off."; return 2 ;; esac
  _nvim_conf_set CFG_KEYMAPS "$v"; _nvim_config_apply nvim
}
do_set_leader() {
  _nvim_resolve_home || return 1
  local l="${1:-}"; [[ -n "$l" ]] || { log_err "Usage: ${0##*/} set-leader <char|space>"; return 2; }
  _nvim_leader_valid "$l" || { log_err "Invalid leader: $l (a single character other than \" or \\, or the word 'space')."; return 2; }
  # The leader must be set BEFORE plugins load; kit's overlay (after/plugin) runs last, far too late
  # to change a distro's leader. So leader is takeover-only — refuse (don't silently no-op) in overlay,
  # matching how add-plugin/enable-lsp gate themselves, and point the user at the distro's own config.
  if [[ "$(_nvim_cfg_mode nvim)" != takeover ]]; then
    log_err "Leader is owned by your distro/config here (overlay mode) — kit can't set it: vim.g.mapleader must be set before plugins load, which an after/plugin overlay can't do. Set it in your distro's early config (e.g. LazyVim: ~/.config/nvim/lua/config/options.lua), or let kit own an empty ~/.config/nvim to manage the leader."
    return 1
  fi
  _nvim_conf_set CFG_LEADER "$l"
  log_info "Leader set to '${l}'."
  _nvim_config_apply nvim
}
do_set_colorscheme() {
  _nvim_resolve_home || return 1
  local c="${1-}"
  [[ -z "$c" ]] || _nvim_colorscheme_valid "$c" || { log_err "Invalid colorscheme name: $c (letters/digits/_-)."; return 2; }
  _nvim_conf_set CFG_COLORSCHEME "$c"; _nvim_config_apply nvim
}
# set-cfg-plugins "<space list of curated keys>" — replace the curated set (takeover only).
do_set_cfg_plugins() {
  _nvim_resolve_home || return 1
  [[ "$(_nvim_cfg_mode nvim)" == takeover ]] || { log_err "Plugins are only managed for a kit-owned (bare-nvim) config — a distro owns plugins here."; return 1; }
  local list="${1-}" k clean=""
  for k in $list; do
    [[ -n "${NVIM_PLUGIN_REPO[$k]:-}" ]] || { log_err "Unknown curated plugin: $k (curated: ${NVIM_PLUGIN_ORDER}; add others with add-plugin)."; return 2; }
    clean="${clean:+$clean }$k"
  done
  _nvim_conf_set CFG_PLUGINS "$clean"; _nvim_config_apply nvim
}
do_add_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} add-plugin <key|owner/repo|git-url>"; return 2; }
  [[ "$(_nvim_cfg_mode nvim)" == takeover ]] || { log_err "Plugins are only managed for a kit-owned (bare-nvim) config. A distro owns plugins here — add it the distro's way, or 'swkit nvim install-distro'."; return 1; }
  if [[ -n "${NVIM_PLUGIN_REPO[$arg]:-}" ]]; then
    _nvim_cfg_list_add CFG_PLUGINS "$arg"
  elif [[ "$arg" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || _nvim_giturl_valid "$arg"; then
    _nvim_conf_set "EXTRA_PLUGIN_$(_nvim_plugin_slug "$arg")" "$arg"
  else
    log_err "Invalid plugin: $arg (use a curated key, owner/repo, or an https/ssh git URL)."; return 2
  fi
  _nvim_config_apply nvim
}
do_remove_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} remove-plugin <key|owner/repo|git-url>"; return 2; }
  [[ "$(_nvim_cfg_mode nvim)" == takeover ]] || { log_err "Plugins are only managed for a kit-owned (bare-nvim) config here."; return 1; }
  if [[ -n "${NVIM_PLUGIN_REPO[$arg]:-}" ]]; then
    _nvim_cfg_list_remove CFG_PLUGINS "$arg"
  else
    _nvim_conf_unset "EXTRA_PLUGIN_$(_nvim_plugin_slug "$arg")"
  fi
  _nvim_config_apply nvim
}
do_enable_lsp() {
  _nvim_resolve_home || return 1
  local v="${1:-on}"; case "$v" in on|off) ;; *) log_err "enable-lsp takes on|off."; return 2 ;; esac
  [[ "$(_nvim_cfg_mode nvim)" == takeover ]] || { log_err "LSP plugins are only managed for a kit-owned (bare-nvim) config — a distro owns LSP here."; return 1; }
  _nvim_conf_set CFG_LSP "$v"
  [[ "$v" == on ]] && ! have_cmd node && log_info "$(_nvim_t mc_node_hint)"
  _nvim_config_apply nvim
}

# config --config-recommended: enable options+keymaps+colorscheme; if takeover, add curated plugins
# + LSP + deps. Independent of `--recommended` (which installs LazyVim, untouched).
_nvim_config_recommended() {
  _nvim_resolve_home || return 1
  _nvim_conf_set CFG_OPTIONS on
  _nvim_conf_set CFG_KEYMAPS on
  [[ -n "$(_nvim_conf_get CFG_COLORSCHEME)" ]] || _nvim_conf_set CFG_COLORSCHEME "$NVIM_CFG_RECOMMENDED_COLOR"
  if [[ "$(_nvim_cfg_mode nvim)" == takeover ]]; then
    _nvim_conf_set CFG_PLUGINS "$NVIM_PLUGIN_RECOMMENDED"
    _nvim_conf_set CFG_LSP on
    _nvim_installed_ok || do_install
    _nvim_ensure_deps
  else
    log_info "A distro/your config owns plugins here — applying the options/keymaps/colorscheme overlay only."
  fi
  _nvim_config_apply nvim
}

# --- Configure -----------------------------------------------------------------
# With NO flags: the conservative baseline = just ensure the Neovim binary is present (no distro,
# no editor change, no extra deps). Flags layer on; --recommended is the one-shot full setup.
do_configure() {
  _nvim_resolve_home || return 1
  if [[ $# -eq 0 ]]; then
    status >/dev/null 2>&1 || do_install
    return 0
  fi
  while (( $# > 0 )); do
    case "$1" in
      --recommended)
        _nvim_installed_ok || do_install
        _nvim_ensure_deps
        do_install_distro "$NVIM_RECOMMENDED_DISTRO"
        do_set_default_editor on
        shift ;;
      --distro)   [[ $# -ge 2 ]] || { log_err "--distro needs a name."; return 2; }; do_install_distro "$2"; shift 2 ;;
      --distro=*) do_install_distro "${1#--distro=}"; shift ;;
      --editor)   [[ $# -ge 2 ]] || { log_err "--editor needs on|off."; return 2; }; do_set_default_editor "$2"; shift 2 ;;
      --editor=*) do_set_default_editor "${1#--editor=}"; shift ;;
      --deps)     _nvim_ensure_deps; shift ;;
      # --- Managed config layer (independent of --recommended / distros) ---
      --config-recommended) _nvim_config_recommended; shift ;;
      --options)      [[ $# -ge 2 ]] || { log_err "--options needs on|off."; return 2; }; do_set_options "$2"; shift 2 ;;
      --options=*)    do_set_options "${1#--options=}"; shift ;;
      --keymaps)      [[ $# -ge 2 ]] || { log_err "--keymaps needs on|off."; return 2; }; do_set_keymaps "$2"; shift 2 ;;
      --keymaps=*)    do_set_keymaps "${1#--keymaps=}"; shift ;;
      --leader)       [[ $# -ge 2 ]] || { log_err "--leader needs a key."; return 2; }; do_set_leader "$2"; shift 2 ;;
      --leader=*)     do_set_leader "${1#--leader=}"; shift ;;
      --colorscheme)  [[ $# -ge 2 ]] || { log_err "--colorscheme needs a name."; return 2; }; do_set_colorscheme "$2"; shift 2 ;;
      --colorscheme=*) do_set_colorscheme "${1#--colorscheme=}"; shift ;;
      --cfg-plugins)  [[ $# -ge 2 ]] || { log_err "--cfg-plugins needs a space list."; return 2; }; do_set_cfg_plugins "$2"; shift 2 ;;
      --cfg-plugins=*) do_set_cfg_plugins "${1#--cfg-plugins=}"; shift ;;
      --lsp)          [[ $# -ge 2 ]] || { log_err "--lsp needs on|off."; return 2; }; do_enable_lsp "$2"; shift 2 ;;
      --lsp=*)        do_enable_lsp "${1#--lsp=}"; shift ;;
      -h|--help)  usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager: install/update/remove the binary; curated distros as a checklist (installed
# marked, space toggles install/remove, `a` adds any git-url); per-appname plugin sync/update/clean;
# external deps + Nerd Font; a default-editor toggle; an "Apply recommended" action. State is read
# live each pass; every change shells out via ui_run (visible + logged) then the screen reloads.
# Non-selectable rows (headers, spacers) are skipped during navigation. `ui` is an entry mode.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }
  _nvim_resolve_home || { ui_end; ui_default_menu; return 0; }

  local sel=0 g d
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" editor_on=0
    if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null)"; fi
    [[ "$(_nvim_conf_get DEFAULT_EDITOR)" == on ]] && editor_on=1

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Neovim")
    else
      dkind+=(update); did+=(update); dlabel+=("$(ui_badge check) Update Neovim (tarball channel)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t distros)")
      for d in $NVIM_DISTRO_ORDER; do
        local badge app
        if app="$(_nvim_distro_appname "$d")" && [[ -n "$app" ]]; then
          badge="$(ui_badge installed)"
        else badge="$(ui_badge missing)"; app=""; fi
        dkind+=(distro); did+=("$d"); dlabel+=("$badge $(printf '%-10s' "$d")${app:+ ${UI_INFO}[$app]${UI_OFF}} ${UI_MUTED}$(_nvim_distro_desc "$d")${UI_OFF}")
      done
      dkind+=(add-distro); did+=(add-distro); dlabel+=("$UI_ARROW $(_nvim_t add_distro)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t plugins)")
      dkind+=(sync);   did+=(sync);   dlabel+=("  $(_nvim_t sync_plugins)")
      dkind+=(pupdate); did+=(pupdate); dlabel+=("  $(_nvim_t update_plugins)")
      dkind+=(pclean); did+=(pclean); dlabel+=("  $(_nvim_t clean_plugins)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t ext_deps)")
      dkind+=(deps); did+=(deps); dlabel+=("  $(_nvim_t install_deps)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      local ebadge; if (( editor_on )); then ebadge="$(ui_badge on)"; else ebadge="$(ui_badge off)"; fi
      dkind+=(editor); did+=(editor); dlabel+=("$ebadge $(_nvim_t default_editor)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Managed config layer (options / keymaps / colorscheme / plugins) ----
      local cfgmode opt_on=0 km_on=0 lsp_on=0 cfg_color cfg_leader cfg_plugins w
      cfgmode="$(_nvim_cfg_mode nvim)"
      [[ "$(_nvim_conf_get CFG_OPTIONS)" == on ]] && opt_on=1
      [[ "$(_nvim_conf_get CFG_KEYMAPS)" == on ]] && km_on=1
      [[ "$(_nvim_conf_get CFG_LSP)" == on ]] && lsp_on=1
      cfg_color="$(_nvim_conf_get CFG_COLORSCHEME)"
      cfg_leader="$(_nvim_conf_get CFG_LEADER)"; [[ -n "$cfg_leader" ]] || cfg_leader="space"
      cfg_plugins="$(_nvim_conf_get CFG_PLUGINS)"
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t managed_config)")
      local modetxt; if [[ "$cfgmode" == takeover ]]; then modetxt="$(_nvim_t mc_mode_takeover)"; else modetxt="$(_nvim_t mc_mode_overlay)"; fi
      dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}${modetxt}${UI_OFF}")
      local ob; if (( opt_on )); then ob="$(ui_badge on)"; else ob="$(ui_badge off)"; fi
      dkind+=(mcopts); did+=(mcopts); dlabel+=("$ob $(_nvim_t mc_options)")
      local kb; if (( km_on )); then kb="$(ui_badge on)"; else kb="$(ui_badge off)"; fi
      dkind+=(mckeys); did+=(mckeys); dlabel+=("$kb $(_nvim_t mc_keymaps)")
      if [[ "$cfgmode" == takeover ]]; then
        dkind+=(mcleader); did+=(mcleader); dlabel+=("  $(_nvim_t mc_leader): ${UI_INFO}${cfg_leader}${UI_OFF}")
      else
        dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t mc_leader_distro_only)${UI_OFF}")
      fi
      dkind+=(mccolor); did+=(mccolor); dlabel+=("  $(_nvim_t mc_colorscheme): ${UI_INFO}${cfg_color:-—}${UI_OFF}")
      if [[ "$cfgmode" == takeover ]]; then
        local cp pb instok
        for cp in $NVIM_PLUGIN_ORDER; do
          instok=0; for w in $cfg_plugins; do [[ "$w" == "$cp" ]] && { instok=1; break; }; done
          if (( instok )); then pb="$(ui_badge installed)"; else pb="$(ui_badge missing)"; fi
          dkind+=(cfgplugin); did+=("$cp"); dlabel+=("$pb $cp")
        done
        local lb; if (( lsp_on )); then lb="$(ui_badge on)"; else lb="$(ui_badge off)"; fi
        dkind+=(mclsp); did+=(mclsp); dlabel+=("$lb $(_nvim_t mc_lsp)")
        dkind+=(mcaddplugin); did+=(mcaddplugin); dlabel+=("$UI_ARROW $(_nvim_t mc_add_plugin)")
      else
        dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t mc_plugins_distro_only)${UI_OFF}")
      fi
      dkind+=(mcapply); did+=(mcapply); dlabel+=("$(ui_badge check) $(_nvim_t mc_apply_recommended)")
      dkind+=(mcreset); did+=(mcreset); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_nvim_t mc_reset)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_nvim_t apply_recommended)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Neovim")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|info)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Neovim" "$ver $(ui_badge installed)"
    else ui_header "Neovim" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        info)   ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_nvim_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)     ui_run "$(ui_t install) Neovim" -- "$0" install ;;
          update)      ui_run "Update Neovim" -- "$0" update ;;
          distro)
            local dn="${did[$sel]}" dapp
            if dapp="$(_nvim_distro_appname "$dn")" && [[ -n "$dapp" ]]; then
              ui_confirm "$(_nvim_t confirm_remove_distro)" n && ui_run "remove-distro $dn" -- "$0" remove-distro "$dn"
            else
              ui_run "install-distro $dn" -- "$0" install-distro "$dn"
            fi ;;
          add-distro)
            if ui_input "$(_nvim_t prompt_name)" "" && _nvim_name_valid "$UI_INPUT"; then
              local addname="$UI_INPUT"
              if ui_input "$(_nvim_t prompt_giturl)" "" && [[ -n "$UI_INPUT" ]]; then
                ui_run "add-distro $addname" -- "$0" add-distro "$addname" "$UI_INPUT"
              fi
            fi ;;
          sync)    ui_run "sync-plugins" -- "$0" sync-plugins ;;
          pupdate) ui_run "update-plugins" -- "$0" update-plugins ;;
          pclean)  ui_run "clean-plugins" -- "$0" clean-plugins ;;
          deps)    ui_run "$(_nvim_t install_deps)" -- "$0" ensure-deps ;;
          editor)
            if (( editor_on )); then ui_run "default editor off" -- "$0" set-default-editor off
            else ui_run "default editor on" -- "$0" set-default-editor; fi ;;
          mcopts)  if (( opt_on )); then ui_run "options off" -- "$0" set-options off; else ui_run "options on" -- "$0" set-options on; fi ;;
          mckeys)  if (( km_on )); then ui_run "keymaps off" -- "$0" set-keymaps off; else ui_run "keymaps on" -- "$0" set-keymaps on; fi ;;
          mcleader)
            if ui_input "$(_nvim_t mc_prompt_leader)" "$cfg_leader" && [[ -n "$UI_INPUT" ]]; then
              ui_run "set-leader $UI_INPUT" -- "$0" set-leader "$UI_INPUT"
            fi ;;
          mccolor)
            local -a copts=() cc
            for cc in $NVIM_BUILTIN_COLORS; do copts+=("$cc" "$cc"); done
            copts+=("" "(none / clear)")
            if ui_pick "$(_nvim_t mc_pick_colorscheme)" "" "" -- "${copts[@]}"; then
              ui_run "set-colorscheme ${UI_PICK:-clear}" -- "$0" set-colorscheme "$UI_PICK"
            fi ;;
          cfgplugin)
            local pk="${did[$sel]}" has=0
            for w in $cfg_plugins; do [[ "$w" == "$pk" ]] && { has=1; break; }; done
            if (( has )); then ui_run "remove-plugin $pk" -- "$0" remove-plugin "$pk"
            else ui_run "add-plugin $pk" -- "$0" add-plugin "$pk"; fi ;;
          mclsp)   if (( lsp_on )); then ui_run "lsp off" -- "$0" enable-lsp off; else ui_run "lsp on" -- "$0" enable-lsp on; fi ;;
          mcaddplugin)
            if ui_input "$(_nvim_t mc_prompt_plugin)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "add-plugin $UI_INPUT" -- "$0" add-plugin "$UI_INPUT"
            fi ;;
          mcapply) ui_run "$(_nvim_t mc_apply_recommended)" -- "$0" configure --config-recommended ;;
          mcreset) ui_confirm "$(_nvim_t mc_confirm_reset)" n && ui_run "$(_nvim_t mc_reset)" -- "$0" config-reset ;;
          recommended) ui_run "$(_nvim_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_nvim_t confirm_remove)" n && ui_run "$(ui_t remove) Neovim" -- "$0" remove ;;
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
  install                 Install Neovim — best channel + version gate (apt >= ${NVIM_MIN_VERSION},
                            else the official stable tarball into /opt, else snap). Idempotent.
  remove                  Uninstall the Neovim binary (keeps your ~/.config/nvim* and distro data)
  update                  Re-fetch + reinstall the latest stable tarball (apt/snap track the system)
  configure [opts]        With no flags: ensure the binary is installed. Flags layer on:
                            --recommended         binary + deps + Nerd Font + LazyVim + editor=on
                            --distro <name>       install a curated/extra distro
                            --editor on|off       set/unset nvim as EDITOR/VISUAL
                            --deps                install external deps only
                            --- managed config layer (independent of --recommended / distros) ---
                            --config-recommended  options+keymaps+colorscheme (+ bare-nvim: plugins+LSP)
                            --options on|off      best-practice editor options baseline
                            --keymaps on|off      leader + quality-of-life keymaps
                            --leader <char|space> leader key (takeover only; a distro keeps its own)
                            --colorscheme <name>  a built-in colorscheme ("" clears)
                            --cfg-plugins "<keys>" curated plugins (bare-nvim only): ${NVIM_PLUGIN_ORDER// /, }
                            --lsp on|off          LSP group (lspconfig+Mason+blink.cmp; bare-nvim only)
  update-plugins [app]    lazy.nvim update for NVIM_APPNAME (default: nvim)
  install-distro <name> [app]   Clone a distro (curated: ${NVIM_DISTRO_ORDER// /, }; or an added name);
                            smart default appname (take over an empty ~/.config/nvim, else nvim-<name>)
  remove-distro <name|app>      Remove a kit-managed distro (backs up its config dir, then deletes it)
  add-distro <name> <url> Register an extra distro git-url for install-distro
  sync-plugins [app]      lazy.nvim sync for NVIM_APPNAME (default: nvim)
  clean-plugins [app]     lazy.nvim clean for NVIM_APPNAME (default: nvim)
  --- managed config layer (the kit's own options/keymaps/colorscheme/plugins) ---
  config-apply [--app N]  (Re)generate the managed config: a takeover init.lua for an empty
                            ~/.config/nvim, else an after/plugin overlay (sourced last, never edits
                            distro Lua). --app targets an isolated distro (e.g. nvim-lazyvim).
  config-reset [--app N]  Remove the kit-managed config files + state (keeps timestamped backups)
  set-options on|off      Toggle the editor options baseline, then re-apply
  set-keymaps on|off      Toggle the keymaps, then re-apply
  set-leader <char|space> Set the leader key (takeover only), then re-apply
  set-colorscheme <name>  Set a built-in colorscheme ("" clears), then re-apply
  set-cfg-plugins "<keys>"      Replace the curated plugin set (bare-nvim takeover only)
  add-plugin <key|owner/repo|git-url>   Add a curated/any plugin (bare-nvim takeover only)
  remove-plugin <key|...> Remove a plugin (bare-nvim takeover only)
  enable-lsp on|off       Toggle the LSP group (bare-nvim takeover only)
  set-default-editor [off]      Set (or, with 'off', unset) nvim as EDITOR/VISUAL + system editor
  ensure-deps             Install external deps (git curl build-essential ripgrep fd-find + Nerd Font)
  status                  Print version + channel + distro count; exit code 0 iff Neovim installed
  ui                      Open the interactive manager (needs a terminal)
  meta                    Print machine-readable metadata
  help                    Show this help

Notes: distros / plugins / deps-config / the editor toggle run AS YOU (never sudo) — they touch
your ~/.config/nvim*, ~/.local and shell rc. Only the binary install/remove escalates per-command.
Neovim is a TUI, so SSH works perfectly; Nerd Font glyphs render in your LOCAL/client terminal.
EOF
}

kit_dispatch "$@"
