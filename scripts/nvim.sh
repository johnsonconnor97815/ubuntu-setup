#!/usr/bin/env bash
#
# scripts/nvim.sh — the nvim + LazyVim COMBO manager for Ubuntu.
#
# LazyVim is the ONE base. Two layers, like the kit's other component managers (ghostty/tmux/rime):
#
#   1) The Neovim BINARY (system-level, escalated per-command via sudo_run) — installed by a
#      best-channel + version-gate policy: apt when its candidate is >= 0.11.2 (LazyVim's real
#      minimum), otherwise the official stable tarball into /opt (sha256-verified against the
#      GitHub release API), and finally a snap fallback. Tarball ranks ABOVE snap because the
#      official tarball is the always-latest stable with a full API checksum (snap lags upstream).
#
#   2) LazyVim + its CONFIG (user-space, never sudo) — `install` lands LazyVim into ~/.config/nvim
#      (collision-aware: clone the starter into an empty dir, adopt a hand-written LazyVim in
#      place, or back up + replace a non-LazyVim config; tracked by a .ubuntu-setup-lazyvim marker)
#      and then layers EVERY setting onto LazyVim's OWN extension points — there is no NVIM_APPNAME
#      isolation, no multi-distro, no takeover/overlay dual mode, just one overlay style ("add to
#      LazyVim's files"): lua/plugins/ubuntu-setup.lua (theme/plugins/Mason), the managed blocks in
#      lua/config/{options,keymaps,autocmds}.lua (leader/options/keymaps/autocmds), and
#      lazyvim.json (extras, via LazyVim's own headless json API). Plugin installs are driven by
#      headless lazy.nvim sync. The font is delegated to fonts.sh (nvim is a TUI; the terminal
#      renders it).
#
# Plus: external deps aligned with LazyVim's healthcheck (git/curl/ripgrep/fd/fzf/compiler/unzip/
# gzip + a Nerd Font), and a default-editor toggle (EDITOR/VISUAL in your shell rc + best-effort
# update-alternatives).
#
# Honesty: Neovim is a TUI (not a GUI), so SSH/headless use is perfect — no "desktop only"
# caveat. Nerd Font glyphs render in your LOCAL/client terminal (fonts.sh prints that guidance).
#
# Run it as:  nvim.sh install|remove|configure|update|update-plugins|status|meta|ui|help
#             plus the parametric config ops (set-colorscheme / add-plugin / extra-add /
#                  set-leader / set-option / add-keymap / mason-add / set-font / … see `help`),
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

# Marker the OLD (task 06-23) managed config layer wrote on the first line of its after/plugin
# overlay file. The combo manager no longer writes it; it survives ONLY so _nvim_migrate_legacy can
# recognize and clean up that old kit-owned overlay (a user's own after/plugin file, with a
# different first line, is left untouched). Matched with an exact string compare, never grep (the
# marker begins with "--", which grep would parse as an option).
readonly NVIM_CFG_MARKER="-- >>> ubuntu-setup nvim config (managed) >>>"

# === nvim + LazyVim combo manager ==============================================
# LazyVim is the ONE base: the kit installs the nvim binary + LazyVim into ~/.config/nvim and then
# layers all settings onto LazyVim's OWN extension points (lua/plugins/ubuntu-setup.lua, the managed
# blocks in lua/config/{options,keymaps,autocmds}.lua, and lazyvim.json). No NVIM_APPNAME isolation,
# no multi-distro, no takeover/overlay dual mode — just one overlay style ("add to LazyVim's files").
readonly NVIM_LAZYVIM_REPO="https://github.com/LazyVim/starter"

# Ownership marker file written under ~/.config/nvim. Its `source=cloned|adopted` line drives the
# install collision branches (R3) and the remove policy (R4): `cloned` = kit git-cloned the starter
# (remove may delete the dir); `adopted` = the user's own LazyVim, kit only tracks it (remove never
# touches the config dir).
readonly NVIM_MARKER_NAME=".ubuntu-setup-lazyvim"

# kit-owned plugins file under LazyVim's lua/plugins/ — a WHOLE file the kit owns (theme/plugins/
# Mason all live here, see _nvim_render_plugins_file). Its first line is this marker; the writer
# refuses to clobber a file whose first line is anything else (so a user's own lua/plugins/*.lua is
# safe).
readonly NVIM_PLUGINS_FILE_REL="lua/plugins/ubuntu-setup.lua"
readonly NVIM_PLUGINS_MARKER="-- >>> ubuntu-setup nvim plugins (managed) >>>"

# Markers delimiting the kit-owned MANAGED BLOCK inside LazyVim's lua/config/{options,keymaps,
# autocmds}.lua (domains 5/6/7/8 — leader / options / keymaps / autocmds). Unlike the WHOLE-file
# plugins marker above, these wrap a region: the writer (_nvim_apply_block, tmux.sh's managed-block
# pattern) rewrites only between the markers and PRESERVES the user's own content outside them, so
# the kit coexists with anything the user already put in those LazyVim files. Matched as EXACT
# lines. NOTE: the markers begin with "--" (a Lua comment), so block-presence is detected with an
# exact awk/first-line compare — NEVER `grep -qxF "$marker"` (grep would parse `-- >>> …` as an
# option and error on the second write; see quality-guidelines.md's lua-marker gotcha).
readonly NVIM_BLOCK_BEGIN="-- >>> ubuntu-setup nvim (managed) >>>"
readonly NVIM_BLOCK_END="-- <<< ubuntu-setup nvim (managed) <<<"

# Curated colorscheme -> the lua/plugins spec line that installs it (domain 1). Built-in schemes
# (tokyonight, catppuccin — both ship with LazyVim) map to an EMPTY spec: only the
# `opts.colorscheme` line is emitted, no extra plugin. The others need their plugin, so the value
# is the FULL `{ … }` spec line. Names stay UNtranslated; repos verified to resolve on GitHub. Any
# non-curated name is accepted too (just sets the opt + warns to add-plugin its plugin yourself).
declare -gA NVIM_THEME_SPEC=(
  [tokyonight]=""
  [catppuccin]=""
  [gruvbox]='{ "ellisonleao/gruvbox.nvim" },'
  [kanagawa]='{ "rebelot/kanagawa.nvim" },'
  [rose-pine]='{ "rose-pine/neovim", name = "rose-pine" },'
  [everforest]='{ "neanias/everforest-nvim" },'
)
# Stable display order for list-colorschemes / the UI selector (associative arrays are unordered).
readonly NVIM_THEME_ORDER="tokyonight catppuccin gruvbox kanagawa rose-pine everforest"

# Background mode shown next to each curated scheme in the picker/list. All six default to a DARK
# background but ALSO ship a LIGHT variant (LazyVim follows `vim.o.background`), so the honest tag is
# "dark/light" rather than a single mode — light flavors: tokyonight=day, catppuccin=latte,
# gruvbox=light, kanagawa=lotus, rose-pine=dawn, everforest=light (verified upstream). A future
# dark-only / light-only scheme would carry "dark" / "light" here instead.
declare -gA NVIM_THEME_MODE=(
  [tokyonight]="dark/light"
  [catppuccin]="dark/light"
  [gruvbox]="dark/light"
  [kanagawa]="dark/light"
  [rose-pine]="dark/light"
  [everforest]="dark/light"
)

# External deps aligned with LazyVim's healthcheck (git/curl/ripgrep/fd/fzf + a C compiler + unzip +
# gzip for the tree-sitter CLI LazyVim auto-installs). lazygit is best-effort (added separately so a
# missing candidate never fails the set). fd's binary is `fdfind` on Ubuntu.
readonly NVIM_LAZYVIM_DEP_PKGS="git curl ripgrep fd-find fzf build-essential unzip gzip"

# Curated Nerd Font display name -> fonts.sh's key (domain 2). nvim is a TUI, so the font is rendered
# by the TERMINAL emulator, not nvim — set-font just delegates to fonts.sh (install + optional apply).
# The pretty display names map to fonts.sh keys; fonts.sh's own keys (meslolgs/jetbrains-mono/…) are
# accepted as-is too. MesloLGS NF is the default (the LazyVim/p10k flagship). Names stay UNtranslated.
declare -gA NVIM_FONT_KEY=(
  ["MesloLGS NF"]="meslolgs"
  [MesloLGS]="meslolgs"
  [JetBrainsMono]="jetbrains-mono"
  ["JetBrainsMono Nerd Font"]="jetbrains-mono"
  [FiraCode]="firacode"
  ["FiraCode Nerd Font"]="firacode"
  [Hack]="hack"
  ["Hack Nerd Font"]="hack"
)
# The fonts.sh keys themselves (accepted directly by set-font), for the stable display order + lookup.
readonly NVIM_FONT_KEYS="meslolgs jetbrains-mono firacode hack"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product names "Neovim"/"nvim"/"LazyVim",
# colorscheme / extra / plugin / font / option / key names, and package/command names stay
# UNtranslated; only descriptive wording is localized. Resolve with _nvim_t KEY (fallback en -> key).
declare -gA NVIM_I18N
# -- Common / binary layer --
NVIM_I18N[en:install_combo]="Install the nvim + LazyVim combo (binary + deps + Nerd Font + sync)"
NVIM_I18N[en:update_nvim]="Update Neovim (tarball channel) + sync plugins"
NVIM_I18N[en:remove_nvim]="Remove the nvim + LazyVim combo"
NVIM_I18N[en:ext_deps]="External deps"
NVIM_I18N[en:install_deps]="Install external deps (git curl ripgrep fd fzf + Nerd Font)"
NVIM_I18N[en:default_editor]="Default editor (EDITOR/VISUAL)"
NVIM_I18N[en:apply_recommended]="Apply recommended setup (combo + EDITOR/VISUAL=nvim)"
NVIM_I18N[en:confirm_remove]="Remove the nvim + LazyVim combo? (cloned config is backed up; adopted config is left alone)"
# shellcheck disable=SC2088  # display string; the ~/ path is a literal label, not meant to expand
NVIM_I18N[en:confirm_destructive_install]="~/.config/nvim holds a non-LazyVim config — back it up (+ share/state/cache) and replace with LazyVim?"
NVIM_I18N[en:not_installed_first]="Install the combo first (swkit nvim install)."
NVIM_I18N[en:foot_main]="up/down move   enter/space select·toggle   a add   d disable   esc/q close"
NVIM_I18N[en:node_hint]="Node not found — for Mason LSP servers that need it: swkit node install"
# -- Domain 1 · theme --
NVIM_I18N[en:sec_theme]="Colorscheme"
NVIM_I18N[en:cur_colorscheme]="Current colorscheme"
NVIM_I18N[en:pick_colorscheme]="Pick a colorscheme"
NVIM_I18N[en:custom_colorscheme]="custom name… (add-plugin its plugin if not built-in)"
NVIM_I18N[en:prompt_colorscheme]="Colorscheme name (letters/digits/_-)"
NVIM_I18N[en:clear_colorscheme]="(clear → LazyVim default)"
# -- Domain 2 · font --
NVIM_I18N[en:sec_font]="Font (Nerd Font, via fonts.sh)"
NVIM_I18N[en:pick_font]="Pick a Nerd Font to install/apply"
NVIM_I18N[en:prompt_font_size]="Font size to apply (blank = install only)"
NVIM_I18N[en:font_tui_note]="nvim is a TUI — the font renders in your terminal; apply only affects this machine's local display."
# -- Domain 3 · plugins --
NVIM_I18N[en:sec_plugins]="Plugins (lua/plugins/ubuntu-setup.lua)"
NVIM_I18N[en:plugins_none]="no extra plugins added"
NVIM_I18N[en:plugins_disabled_hd]="Disabled LazyVim plugins"
NVIM_I18N[en:add_plugin]="add a plugin (owner/repo or git-url)…"
NVIM_I18N[en:disable_plugin]="disable a LazyVim plugin (owner/repo)…"
NVIM_I18N[en:prompt_plugin]="Plugin (owner/repo or https git URL)"
NVIM_I18N[en:prompt_disable_plugin]="LazyVim plugin to disable (owner/repo)"
# -- Domain 4 · extras --
NVIM_I18N[en:sec_extras]="Extras (lazyvim.json — language/feature packs)"
NVIM_I18N[en:add_extra]="add any extra (cat.name, e.g. lang.go)…"
NVIM_I18N[en:prompt_extra]="Extra module (<cat>.<name>, e.g. lang.go / editor.snacks_picker)"
# -- Domain 5/6/7/8 · leader / options / keymaps / autocmds --
NVIM_I18N[en:sec_config]="Config (leader / options / keymaps / autocmds)"
NVIM_I18N[en:leader_label]="Leader key"
NVIM_I18N[en:prompt_leader]="Leader key (a single char, or the word 'space')"
NVIM_I18N[en:opts_hd]="Options"
NVIM_I18N[en:autoformat_label]="Format on save"
NVIM_I18N[en:prompt_option_value]="Value for '%s' (on|off, an integer, or a simple word; blank clears)"
NVIM_I18N[en:keymaps_hd]="Keymaps"
NVIM_I18N[en:add_keymap]="add a keymap (mode lhs rhs)…"
NVIM_I18N[en:keymaps_none]="no keymaps added"
NVIM_I18N[en:prompt_km_mode]="Mode (one of n i v x s o t c)"
NVIM_I18N[en:prompt_km_lhs]="Left-hand side (keys, e.g. <leader>w)"
NVIM_I18N[en:prompt_km_rhs]="Right-hand side (command/keys, e.g. <cmd>w<cr>)"
NVIM_I18N[en:prompt_km_desc]="Description (optional)"
NVIM_I18N[en:autocmds_hd]="Autocmds (curated)"
# -- Domain 9 · Mason --
NVIM_I18N[en:sec_mason]="Mason tools (ensure_installed)"
NVIM_I18N[en:mason_none]="no Mason tools added"
NVIM_I18N[en:add_mason]="add a Mason tool (e.g. stylua, shfmt)…"
NVIM_I18N[en:prompt_mason]="Mason tool name (letters/digits/._-)"
# -- Reset / managed config --
NVIM_I18N[en:reset_config]="Reset managed config (plugins file + config blocks)"
NVIM_I18N[en:confirm_reset]="Reset the kit-managed nvim config? (backs up, then removes the kit's products + clears state)"
# -- Common / binary layer --
NVIM_I18N[zh:install_combo]="安装 nvim + LazyVim 组合(二进制 + 依赖 + Nerd Font + 同步)"
NVIM_I18N[zh:update_nvim]="更新 Neovim(tarball 渠道)+ 同步插件"
NVIM_I18N[zh:remove_nvim]="移除 nvim + LazyVim 组合"
NVIM_I18N[zh:ext_deps]="外部依赖"
NVIM_I18N[zh:install_deps]="安装外部依赖(git curl ripgrep fd fzf + Nerd Font)"
NVIM_I18N[zh:default_editor]="默认编辑器(EDITOR/VISUAL)"
NVIM_I18N[zh:apply_recommended]="应用推荐配置(组合 + EDITOR/VISUAL=nvim)"
NVIM_I18N[zh:confirm_remove]="移除 nvim + LazyVim 组合?(cloned 配置先备份;adopted 配置原样保留)"
# shellcheck disable=SC2088  # display string; the ~/ path is a literal label, not meant to expand
NVIM_I18N[zh:confirm_destructive_install]="~/.config/nvim 是非 LazyVim 配置 —— 备份它(及 share/state/cache)后替换为 LazyVim?"
NVIM_I18N[zh:not_installed_first]="请先安装组合(swkit nvim install)。"
NVIM_I18N[zh:foot_main]="↑↓ 移动   ↵/space 选择·切换   a 添加   d 禁用   esc/q 关闭"
NVIM_I18N[zh:node_hint]="未找到 Node —— Mason 的 Node 系 LSP server 需要:swkit node install"
# -- Domain 1 · theme --
NVIM_I18N[zh:sec_theme]="colorscheme(主题)"
NVIM_I18N[zh:cur_colorscheme]="当前 colorscheme"
NVIM_I18N[zh:pick_colorscheme]="选择一个 colorscheme"
NVIM_I18N[zh:custom_colorscheme]="自定义名称…(非内置请 add-plugin 其插件)"
NVIM_I18N[zh:prompt_colorscheme]="colorscheme 名称(字母/数字/_-)"
NVIM_I18N[zh:clear_colorscheme]="(清除 → LazyVim 默认)"
# -- Domain 2 · font --
NVIM_I18N[zh:sec_font]="字体(Nerd Font,经 fonts.sh)"
NVIM_I18N[zh:pick_font]="选择要安装/应用的 Nerd Font"
NVIM_I18N[zh:prompt_font_size]="要应用的字号(留空=仅安装)"
NVIM_I18N[zh:font_tui_note]="nvim 是 TUI —— 字体由终端渲染;apply 只影响本机本地显示。"
# -- Domain 3 · plugins --
NVIM_I18N[zh:sec_plugins]="插件(lua/plugins/ubuntu-setup.lua)"
NVIM_I18N[zh:plugins_none]="未添加额外插件"
NVIM_I18N[zh:plugins_disabled_hd]="已禁用的 LazyVim 插件"
NVIM_I18N[zh:add_plugin]="添加插件(owner/repo 或 git-url)…"
NVIM_I18N[zh:disable_plugin]="禁用一个 LazyVim 插件(owner/repo)…"
NVIM_I18N[zh:prompt_plugin]="插件(owner/repo 或 https git URL)"
NVIM_I18N[zh:prompt_disable_plugin]="要禁用的 LazyVim 插件(owner/repo)"
# -- Domain 4 · extras --
NVIM_I18N[zh:sec_extras]="extras(lazyvim.json —— 语言/功能包)"
NVIM_I18N[zh:add_extra]="添加任意 extra(cat.name,如 lang.go)…"
NVIM_I18N[zh:prompt_extra]="extra 模块(<cat>.<name>,如 lang.go / editor.snacks_picker)"
# -- Domain 5/6/7/8 · leader / options / keymaps / autocmds --
NVIM_I18N[zh:sec_config]="配置(leader / options / keymaps / autocmds)"
NVIM_I18N[zh:leader_label]="leader 键"
NVIM_I18N[zh:prompt_leader]="leader 键(单个字符,或单词 'space')"
NVIM_I18N[zh:opts_hd]="options"
NVIM_I18N[zh:autoformat_label]="保存时格式化"
NVIM_I18N[zh:prompt_option_value]="'%s' 的值(on|off、整数或简单词;留空=清除)"
NVIM_I18N[zh:keymaps_hd]="keymaps"
NVIM_I18N[zh:add_keymap]="添加 keymap(mode lhs rhs)…"
NVIM_I18N[zh:keymaps_none]="未添加 keymap"
NVIM_I18N[zh:prompt_km_mode]="模式(n i v x s o t c 之一)"
NVIM_I18N[zh:prompt_km_lhs]="左侧(按键,如 <leader>w)"
NVIM_I18N[zh:prompt_km_rhs]="右侧(命令/按键,如 <cmd>w<cr>)"
NVIM_I18N[zh:prompt_km_desc]="描述(可选)"
NVIM_I18N[zh:autocmds_hd]="autocmds(curated)"
# -- Domain 9 · Mason --
NVIM_I18N[zh:sec_mason]="Mason 工具(ensure_installed)"
NVIM_I18N[zh:mason_none]="未添加 Mason 工具"
NVIM_I18N[zh:add_mason]="添加 Mason 工具(如 stylua、shfmt)…"
NVIM_I18N[zh:prompt_mason]="Mason 工具名(字母/数字/._-)"
# -- Reset / managed config --
NVIM_I18N[zh:reset_config]="重置受管配置(插件文件 + 配置块)"
NVIM_I18N[zh:confirm_reset]="重置 kit 受管 nvim 配置?(先备份,再移除 kit 产物并清状态)"
# -- Common / binary layer --
NVIM_I18N[ja:install_combo]="nvim + LazyVim コンボをインストール(バイナリ + 依存 + Nerd Font + sync)"
NVIM_I18N[ja:update_nvim]="Neovim を更新(tarball チャンネル)+ プラグイン同期"
NVIM_I18N[ja:remove_nvim]="nvim + LazyVim コンボを削除"
NVIM_I18N[ja:ext_deps]="外部依存"
NVIM_I18N[ja:install_deps]="外部依存をインストール(git curl ripgrep fd fzf + Nerd Font)"
NVIM_I18N[ja:default_editor]="デフォルトエディタ(EDITOR/VISUAL)"
NVIM_I18N[ja:apply_recommended]="推奨セットアップを適用(コンボ + EDITOR/VISUAL=nvim)"
NVIM_I18N[ja:confirm_remove]="nvim + LazyVim コンボを削除しますか?(cloned 設定はバックアップ、adopted 設定はそのまま)"
# shellcheck disable=SC2088  # display string; the ~/ path is a literal label, not meant to expand
NVIM_I18N[ja:confirm_destructive_install]="~/.config/nvim は LazyVim 以外の設定です — バックアップ(+ share/state/cache)して LazyVim に置き換えますか?"
NVIM_I18N[ja:not_installed_first]="先にコンボをインストールしてください(swkit nvim install)。"
NVIM_I18N[ja:foot_main]="↑↓ 移動   ↵/space 選択・切替   a 追加   d 無効化   esc/q 閉じる"
NVIM_I18N[ja:node_hint]="Node が見つかりません — Node が必要な Mason LSP server には:swkit node install"
# -- Domain 1 · theme --
NVIM_I18N[ja:sec_theme]="colorscheme(テーマ)"
NVIM_I18N[ja:cur_colorscheme]="現在の colorscheme"
NVIM_I18N[ja:pick_colorscheme]="colorscheme を選択"
NVIM_I18N[ja:custom_colorscheme]="カスタム名…(内蔵でなければ add-plugin でプラグインも)"
NVIM_I18N[ja:prompt_colorscheme]="colorscheme 名(英数/_-)"
NVIM_I18N[ja:clear_colorscheme]="(クリア → LazyVim デフォルト)"
# -- Domain 2 · font --
NVIM_I18N[ja:sec_font]="フォント(Nerd Font、fonts.sh 経由)"
NVIM_I18N[ja:pick_font]="インストール/適用する Nerd Font を選択"
NVIM_I18N[ja:prompt_font_size]="適用するサイズ(空欄=インストールのみ)"
NVIM_I18N[ja:font_tui_note]="nvim は TUI — フォントは端末が描画;apply はこのマシンのローカル表示のみに作用。"
# -- Domain 3 · plugins --
NVIM_I18N[ja:sec_plugins]="プラグイン(lua/plugins/ubuntu-setup.lua)"
NVIM_I18N[ja:plugins_none]="追加プラグインなし"
NVIM_I18N[ja:plugins_disabled_hd]="無効化した LazyVim プラグイン"
NVIM_I18N[ja:add_plugin]="プラグインを追加(owner/repo か git-url)…"
NVIM_I18N[ja:disable_plugin]="LazyVim プラグインを無効化(owner/repo)…"
NVIM_I18N[ja:prompt_plugin]="プラグイン(owner/repo か https git URL)"
NVIM_I18N[ja:prompt_disable_plugin]="無効化する LazyVim プラグイン(owner/repo)"
# -- Domain 4 · extras --
NVIM_I18N[ja:sec_extras]="extras(lazyvim.json — 言語/機能パック)"
NVIM_I18N[ja:add_extra]="任意の extra を追加(cat.name、例 lang.go)…"
NVIM_I18N[ja:prompt_extra]="extra モジュール(<cat>.<name>、例 lang.go / editor.snacks_picker)"
# -- Domain 5/6/7/8 · leader / options / keymaps / autocmds --
NVIM_I18N[ja:sec_config]="設定(leader / options / keymaps / autocmds)"
NVIM_I18N[ja:leader_label]="leader キー"
NVIM_I18N[ja:prompt_leader]="leader キー(1 文字、または 'space')"
NVIM_I18N[ja:opts_hd]="options"
NVIM_I18N[ja:autoformat_label]="保存時フォーマット"
NVIM_I18N[ja:prompt_option_value]="'%s' の値(on|off、整数、または単純な語;空欄=クリア)"
NVIM_I18N[ja:keymaps_hd]="keymaps"
NVIM_I18N[ja:add_keymap]="keymap を追加(mode lhs rhs)…"
NVIM_I18N[ja:keymaps_none]="keymap なし"
NVIM_I18N[ja:prompt_km_mode]="モード(n i v x s o t c のいずれか)"
NVIM_I18N[ja:prompt_km_lhs]="左辺(キー、例 <leader>w)"
NVIM_I18N[ja:prompt_km_rhs]="右辺(コマンド/キー、例 <cmd>w<cr>)"
NVIM_I18N[ja:prompt_km_desc]="説明(任意)"
NVIM_I18N[ja:autocmds_hd]="autocmds(curated)"
# -- Domain 9 · Mason --
NVIM_I18N[ja:sec_mason]="Mason ツール(ensure_installed)"
NVIM_I18N[ja:mason_none]="Mason ツールなし"
NVIM_I18N[ja:add_mason]="Mason ツールを追加(例 stylua、shfmt)…"
NVIM_I18N[ja:prompt_mason]="Mason ツール名(英数/._-)"
# -- Reset / managed config --
NVIM_I18N[ja:reset_config]="管理設定をリセット(プラグインファイル + 設定ブロック)"
NVIM_I18N[ja:confirm_reset]="kit 管理の nvim 設定をリセットしますか?(バックアップ後、kit 産物を削除し状態をクリア)"

# _nvim_t KEY — localized Neovim string for $UI_LANG (en/zh/ja), fallback en -> key.
_nvim_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${NVIM_I18N[$lang:$1]:-${NVIM_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=nvim
name=Neovim
category=common
ops=install,remove,configure,update,update-plugins
desc=nvim + LazyVim combo manager — best-channel binary (apt/tarball/snap) + LazyVim config, with full component config via LazyVim's official extension points (theme/font/plugins/extras/leader/keymaps/options/autocmds/Mason)
META
}

# --- Install probe -------------------------------------------------------------
# COMBO semantics: exit 0 iff the COMBO is installed = nvim is on PATH AND the kit's LazyVim
# ownership marker is present under ~/.config/nvim. The boolean is identical in both paths (a marker
# stat — no nvim spawn, no grep), so KIT_PROBE_ONLY (the catalog probe) and the full run ALWAYS
# agree on the exit code. `install` writes that marker for both the cloned and adopted branches, so
# any kit-managed setup satisfies it. The full path additionally prints version/channel and, when
# nvim+LazyVim Lua exist WITHOUT our marker (a hand-written LazyVim the user never ran `install` on),
# a one-line hint to adopt it — but that hint NEVER flips the exit code. Does NOT resolve home (must
# work under the probe with a sudo-wrapped env), so it uses $HOME best-effort.
status() {
  have_cmd nvim || return 1
  local cfg="${XDG_CONFIG_HOME:-${HOME:-}/.config}/nvim"
  local marker="$cfg/$NVIM_MARKER_NAME"
  [[ -f "$marker" ]] || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  local ver path chan="?" src=""
  ver="$(nvim --version 2>/dev/null | head -n1)"
  path="$(command -v nvim 2>/dev/null || true)"
  if [[ "$(readlink -f "$path" 2>/dev/null)" == /opt/nvim-linux-* ]]; then chan="tarball"
  elif [[ "$path" == /snap/* ]] || { have_cmd snap && snap list nvim >/dev/null 2>&1; }; then chan="snap"
  elif pkg_installed neovim; then chan="apt"; fi
  src="$(grep -E '^source=' "$marker" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  printf '%s  ·  channel:%s  ·  LazyVim:%s\n' "${ver:-nvim installed}" "$chan" "${src:-cloned}"
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
  # The LazyVim base + its ownership marker (combo manager).
  _NV_NVIM_DIR="$_NV_CFG/nvim"
  _NV_MARKER="$_NV_NVIM_DIR/$NVIM_MARKER_NAME"
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

# Exit 0 iff nvim is installed AND new enough (>= NVIM_MIN_VERSION) for LazyVim. This is the
# install/upgrade gate — UNLIKE status(), which only checks presence. Spawns nvim, so it runs in
# real ops only (never under the KIT_PROBE_ONLY catalog probe).
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

# _nvim_ensure_binary — best channel + version gate for the Neovim BINARY only (no LazyVim/config).
# Prints the channel actually used. Idempotent: a no-op when nvim is present AND new enough. This is
# the binary half the combo do_install builds on; do_update calls THIS to "just ensure the binary",
# not the whole combo (landing LazyVim + syncing is do_install's job).
_nvim_ensure_binary() {
  if _nvim_installed_ok; then
    log_info "Neovim binary is already installed and new enough ($(nvim --version 2>/dev/null | head -n1))."
    return 0
  fi
  # Already present but older than the LazyVim floor? Upgrade it. A leftover apt /usr/bin/nvim is the
  # classic "LazyVim requires >= 0.11.2" trap, so clear it — but only AFTER the new binary lands
  # (deferred), so a failed download never leaves you with no nvim at all. The tarball's
  # /usr/local/bin/nvim outranks apt's /usr/bin/nvim on PATH, so the stale apt copy is hygiene, not a
  # blocker. NON-apt stale installs (manual tarball/snap) are left for their own channel.
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
  log_info "Installed the Neovim binary ($(nvim --version 2>/dev/null | head -n1))."
  return 0
}

# --- LazyVim landing layer (combo: nvim binary + LazyVim into ~/.config/nvim) ---

# Back up the four LazyVim state locations before a destructive replace, per LazyVim's official
# install guidance (config + share + state + cache). Each is renamed aside with a timestamp via the
# directory-level helper (a no-op on an absent/empty dir). Used only on the "non-LazyVim → replace"
# branch; the cloned/adopted/idempotent branches never call it.
_lazyvim_backup_all() {
  _nvim_backup_dir "$_NV_NVIM_DIR"
  _nvim_backup_dir "$_NV_DATA/nvim"
  _nvim_backup_dir "$_NV_STATE/nvim"
  _nvim_backup_dir "$_NV_CACHE/nvim"
}

# Ownership marker read/write. The marker file records `source=cloned|adopted` (see R3/R4). Write is
# user-space (the marker lives inside ~/.config/nvim); read echoes the source or empty if absent.
_lazyvim_marker_write() {
  local src="$1"
  case "$src" in cloned|adopted) ;; *) log_err "Invalid LazyVim marker source: $src"; return 2 ;; esac
  mkdir -p "$_NV_NVIM_DIR"
  {
    printf '# ubuntu-setup: this ~/.config/nvim is managed as a nvim+LazyVim combo by swkit.\n'
    printf '# source=cloned  : swkit git-cloned the LazyVim starter here (remove may delete this dir).\n'
    printf '# source=adopted : your own pre-existing LazyVim; swkit only tracks it (remove never deletes it).\n'
    printf 'source=%s\n' "$src"
  } >"$_NV_MARKER"
}
_lazyvim_marker_read() {
  [[ -f "${_NV_MARKER:-}" ]] || return 0
  grep -E '^source=' "$_NV_MARKER" 2>/dev/null | tail -n1 | cut -d= -f2- || true
}

# True iff ~/.config/nvim looks like a LazyVim config (starter's lua/config/lazy.lua references
# "LazyVim/LazyVim"). grep -rlq, anchored to the lua/ subtree. Used for the adopt detection.
_lazyvim_is_lazyvim() {
  [[ -d "$_NV_NVIM_DIR/lua" ]] || return 1
  grep -rlq 'LazyVim/LazyVim' "$_NV_NVIM_DIR/lua" 2>/dev/null
}

# git-clone the LazyVim starter into ~/.config/nvim, then drop its .git (the official install steps),
# and mark it cloned. Caller guarantees the dir is absent/empty (or already backed up).
_lazyvim_clone() {
  have_cmd git || { log_err "git is required to clone LazyVim — install it with: swkit git install (or: ${0##*/} ensure-deps)."; return 1; }
  _nvim_path_under_config "$_NV_NVIM_DIR" || { log_err "Refusing to write outside ~/.config: $_NV_NVIM_DIR"; return 1; }
  log_info "Cloning the LazyVim starter into $_NV_NVIM_DIR …"
  git clone --depth 1 "$NVIM_LAZYVIM_REPO" "$_NV_NVIM_DIR" || { log_err "Failed to clone the LazyVim starter from $NVIM_LAZYVIM_REPO."; return 1; }
  rm -rf "$_NV_NVIM_DIR/.git"
  _lazyvim_marker_write cloned
  log_info "Cloned LazyVim (removed its .git so it is now YOUR config)."
}

# _lazyvim_land — put LazyVim at ~/.config/nvim, choosing one of FOUR collision branches (R3):
#   1) our marker present (cloned|adopted)  -> idempotent (the combo is already ours; caller syncs).
#   2) ~/.config/nvim absent/empty          -> clone the starter, rm .git, mark cloned.
#   3) no marker but it IS LazyVim (grep)    -> ADOPT: mark adopted; do NOT clone, do NOT touch files.
#   4) no marker and NOT LazyVim             -> back up config+share+state+cache, clone, mark cloned.
# Branch 4 is destructive: it runs (headless/LLM usable) but logs loudly; the ui() wraps it in an
# ui_confirm. There is NO --force — the timestamped backups are the failsafe. When the LazyVim
# heuristic is uncertain we BIAS toward preserving (adopt), never toward the destructive replace.
# `$1` (optional) = "confirmed" to acknowledge a destructive replace from a caller that already
# prompted (the ui); absent in headless, where we proceed with a loud warning regardless.
_lazyvim_land() {
  local src
  src="$(_lazyvim_marker_read)"
  if [[ -n "$src" ]]; then
    log_info "LazyVim is already managed here (source=$src) — leaving it in place."
    return 0
  fi
  if [[ ! -d "$_NV_NVIM_DIR" ]] || [[ -z "$(ls -A "$_NV_NVIM_DIR" 2>/dev/null || true)" ]]; then
    _lazyvim_clone || return 1
    return 0
  fi
  if _lazyvim_is_lazyvim; then
    _lazyvim_marker_write adopted
    log_info "Adopted your existing LazyVim at $_NV_NVIM_DIR (no files changed; swkit will layer settings onto LazyVim's own files)."
    return 0
  fi
  # Branch 4: a non-LazyVim config occupies ~/.config/nvim. Destructive — back everything up first.
  log_warn "$_NV_NVIM_DIR holds a non-LazyVim Neovim config. Replacing it with LazyVim — your existing"
  log_warn "config AND ~/.local/share/nvim, ~/.local/state/nvim, ~/.cache/nvim are backed up aside"
  log_warn "(timestamped *.bak.<ts>) first. There is no --force; restore from those backups to undo."
  _lazyvim_backup_all
  _lazyvim_clone || return 1
  return 0
}

# _nvim_migrate_legacy — best-effort cleanup of leftovers from the OLD multi-distro / overlay layer
# (task 06-23), called once at the end of do_install. It only removes the kit's OWN markers/artifacts:
#   1) the managed `alias nvim-<distro>=…` lines (NVIM_ALIAS_MARKER) the old layer wrote into the shell
#      rc (backed up first) — they pointed at NVIM_APPNAME-isolated distros that no longer exist;
#   2) the old after/plugin overlay ~/.config/nvim/after/plugin/ubuntu-setup.lua, but ONLY when its
#      first line is the old kit marker (NVIM_CFG_MARKER) — a user's own after/plugin file is untouched;
#      then prune the after/plugin and after dirs ONLY if they are now empty.
# It NEVER deletes ~/.config/nvim-<distro> isolated configs (user data) — it only points them out.
# All user-space; every removal goes through the path guard / a marker check. Failures only warn.
_nvim_migrate_legacy() {
  local rc; rc="$(_nvim_rc_file)"
  # 1) Drop any old managed `nvim-<distro>` alias lines (marker-tagged) from the shell rc.
  if [[ -f "$rc" ]] && grep -qF "$NVIM_ALIAS_MARKER" "$rc" 2>/dev/null; then
    backup_file "$rc"
    local tmp; tmp="$(mktemp)"
    grep -vF "$NVIM_ALIAS_MARKER" "$rc" >"$tmp" || true
    if mv "$tmp" "$rc"; then
      log_info "Migration: removed old managed 'nvim-<distro>' alias lines from $rc (they referenced isolated distros the combo manager no longer uses)."
    else rm -f "$tmp"; log_warn "Migration: could not rewrite $rc to drop old alias lines."; fi
  fi
  # 2) Remove the old after/plugin overlay — only if it is the kit's (old marker on the first line).
  local overlay="$_NV_NVIM_DIR/after/plugin/ubuntu-setup.lua" first=""
  if [[ -f "$overlay" ]]; then
    IFS= read -r first <"$overlay" || true
    if [[ "$first" == "$NVIM_CFG_MARKER" ]] && _nvim_path_under_config "$overlay"; then
      backup_file "$overlay"; rm -f "$overlay"
      log_info "Migration: removed the old kit after/plugin overlay (a backup was kept): $overlay"
      # Prune now-empty after/plugin and after dirs (rmdir only succeeds when empty — safe).
      rmdir "$_NV_NVIM_DIR/after/plugin" 2>/dev/null || true
      rmdir "$_NV_NVIM_DIR/after" 2>/dev/null || true
    fi
  fi
  # 3) Inform about (but NEVER delete) old NVIM_APPNAME-isolated distro configs — that is user data.
  local d isodir
  for d in lazyvim kickstart astronvim nvchad; do
    isodir="$_NV_CFG/nvim-$d"
    if [[ -d "$isodir" ]]; then
      log_warn "Migration: found an old isolated distro config at $isodir — KEPT (your data). Remove it yourself if unwanted: rm -rf '$isodir'"
    fi
  done
  return 0
}

# do_install — the COMBO: the Neovim binary + external deps (incl. a Nerd Font) + LazyVim at
# ~/.config/nvim + a headless plugin sync, delivering a ready-to-use LazyVim in one step. Idempotent:
# when the combo is already installed (our marker present) it skips the heavy steps and at most
# re-syncs plugins. The LazyVim landing chooses one of the four collision branches (see _lazyvim_land).
do_install() {
  _nvim_resolve_home || return 1

  # Fast idempotent path: combo already ours. Refresh deps cheaply (Nerd Font check is quick) and
  # re-sync, but don't re-run the binary install or re-land LazyVim.
  if status >/dev/null 2>&1; then
    log_info "The nvim + LazyVim combo is already installed ($(status 2>/dev/null)) — re-syncing plugins."
    _nvim_sync sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} update-plugins."
    _nvim_migrate_legacy || true
    log_info "For settings (theme / font / plugins / extras / keymaps / options), open: swkit nvim"
    return 0
  fi

  # 1) Ensure the Neovim binary (apt >= floor, else tarball, else snap). Must be new enough for LazyVim.
  _nvim_ensure_binary || return 1
  if ! _nvim_installed_ok; then
    log_err "Could not get Neovim >= ${NVIM_MIN_VERSION}, which LazyVim requires — fix the binary first, then re-run."
    return 1
  fi
  # 2) External deps aligned with LazyVim's healthcheck + a Nerd Font.
  _nvim_ensure_deps
  # 3) Land LazyVim into ~/.config/nvim (four collision branches; writes the ownership marker).
  _lazyvim_land || return 1
  # 4) Sync LazyVim's plugins headless so the first launch is ready.
  _nvim_sync sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} update-plugins (or just launch nvim)."
  # 5) Best-effort: clean up leftovers from the old multi-distro/overlay layer (never touches user data).
  _nvim_migrate_legacy || true

  log_info "Installed the nvim + LazyVim combo ($(status 2>/dev/null))."
  log_info "Launch it with:  nvim    — then run  :LazyHealth  inside it to verify external tools."
  log_info "For settings (theme / font / plugins / extras / keymaps / options), open: swkit nvim"
}

# do_remove — uninstall the binary (by channel), then handle the LazyVim config per its ownership:
#   source=cloned  -> back up ~/.config/nvim aside, delete it, drop the marker. --purge additionally
#                     removes ~/.local/share/nvim, ~/.local/state/nvim, ~/.cache/nvim (runtime data).
#   source=adopted -> NEVER touch the config dir (it is the user's own); only drop our marker.
# Keeps things conservative; the cloned config is backed up before deletion (the timestamped copy is
# the only undo). `--purge` is honored only for a cloned config.
do_remove() {
  _nvim_resolve_home || return 1
  local purge=0 a
  for a in "$@"; do case "$a" in --purge) purge=1 ;; *) log_err "remove takes at most --purge."; return 2 ;; esac; done

  local had_binary=0 path src
  path="$(command -v nvim 2>/dev/null || true)"
  if [[ -n "$path" ]]; then
    had_binary=1
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
    fi
  fi

  # Config side: act on the ownership marker.
  src="$(_lazyvim_marker_read)"
  if [[ -z "$src" ]]; then
    (( had_binary )) || log_info "The nvim + LazyVim combo is not installed — nothing to remove."
    (( had_binary )) && log_info "Kept your ~/.config/nvim (no kit ownership marker — it was not managed by swkit)."
    return 0
  fi
  case "$src" in
    adopted)
      _nvim_path_under_config "$_NV_MARKER" || { log_err "Refusing to touch outside ~/.config: $_NV_MARKER"; return 1; }
      rm -f "$_NV_MARKER"
      log_info "Dropped the kit ownership marker. Left your adopted LazyVim at $_NV_NVIM_DIR untouched."
      ;;
    cloned)
      _nvim_path_under_config "$_NV_NVIM_DIR" || { log_err "Refusing to remove a path outside ~/.config: $_NV_NVIM_DIR"; return 1; }
      if [[ -d "$_NV_NVIM_DIR" ]]; then
        _nvim_backup_dir "$_NV_NVIM_DIR"
        rm -rf "${_NV_NVIM_DIR:?}"
        log_info "Removed the kit-cloned LazyVim at $_NV_NVIM_DIR (a timestamped backup was kept)."
      fi
      if (( purge )); then
        rm -rf "${_NV_DATA:?}/nvim" "${_NV_STATE:?}/nvim" "${_NV_CACHE:?}/nvim"
        log_info "Purged LazyVim runtime data (~/.local/share/nvim, ~/.local/state/nvim, ~/.cache/nvim)."
      else
        log_info "Kept LazyVim runtime data — to wipe it too, run: ${0##*/} remove --purge."
      fi
      ;;
  esac
}

# do_update — meaningful only for the tarball channel (apt/snap track the system). Re-resolves the
# latest stable and reinstalls over /opt. Installs first if Neovim is absent.
do_update() {
  _nvim_resolve_home || return 1
  # `update` refreshes the BINARY (S2 scope). When nvim is absent it ensures the binary; the full
  # combo install is `install`, not `update`. (S5 will layer a headless plugin sync on top.)
  if ! have_cmd nvim; then
    log_info "Neovim is not installed — installing the latest binary instead (use 'install' for the full combo)."
    _nvim_ensure_binary
    return $?
  fi
  local path; path="$(command -v nvim 2>/dev/null || true)"
  if pkg_installed neovim; then
    if _nvim_apt_ok; then
      log_info "Neovim was installed via apt — update it with your system: sudo apt update && sudo apt upgrade."
      return 0
    fi
    # apt's candidate is too old for LazyVim — `apt upgrade` can't help. Reuse the binary install
    # path: it upgrades to the official tarball and clears the now-shadowed apt package.
    log_info "The apt 'neovim' candidate is older than ${NVIM_MIN_VERSION} — upgrading to the official tarball instead."
    _nvim_ensure_binary
    return $?
  fi
  if [[ "$path" == /snap/* ]] || { have_cmd snap && snap list nvim >/dev/null 2>&1; }; then
    log_info "Neovim was installed via snap — update it with: sudo snap refresh nvim."
    return 0
  fi
  local cur; cur="$(_nvim_running_ver)"
  _nvim_install_tarball || return 1
  _nvim_conf_set CHANNEL tarball
  log_info "Neovim binary is now $(nvim --version 2>/dev/null | head -n1) (was ${cur:-unknown})."
}

# --- Shared helpers: validators / dir backup / path guard / lazy.nvim sync ------

# Validate a short name token (letters/digits/._-, no path-injection metacharacters). A shared
# guard kept for any name/identifier the kit derives a filesystem path from.
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

# Marker the OLD managed config layer tagged onto its `alias nvim-<distro>=…` shell-rc lines. The
# combo manager writes no such alias; the constant survives ONLY so _nvim_migrate_legacy can grep it
# out of the rc on the first combo install (the old aliases pointed at isolated distros that no
# longer exist).
readonly NVIM_ALIAS_MARKER="# ubuntu-setup (nvim distro alias)"

# Drive LazyVim's bundled lazy.nvim headless: sync | update | clean. Bounded by `timeout` so a
# stuck/offline run never hangs the script. Needs a working nvim. Runs against the default config
# (~/.config/nvim) — there is no NVIM_APPNAME isolation in the combo manager.
_nvim_sync() {
  local op="${1:-sync}" cmd
  have_cmd nvim || { log_err "$(_nvim_t not_installed_first)"; return 1; }
  case "$op" in
    sync)   cmd='+Lazy! sync' ;;
    update) cmd='+Lazy! update' ;;
    clean)  cmd='+Lazy! clean' ;;
    *) log_err "Unknown plugin op: $op"; return 2 ;;
  esac
  log_info "Driving lazy.nvim ($op) on ~/.config/nvim (headless)…"
  if have_cmd timeout; then
    timeout 600 nvim --headless "$cmd" +qa
  else
    nvim --headless "$cmd" +qa
  fi
}

# --- Plugin sync op (ui-reachable) ---------------------------------------------
# update-plugins — drive LazyVim's lazy.nvim `update` headless against ~/.config/nvim.
do_update_plugins() { _nvim_resolve_home || return 1; _nvim_sync update; }

# --- External deps -------------------------------------------------------------
# Install the apt packages LazyVim's healthcheck wants + a Nerd Font (best-effort, via fonts.sh).
# The required set (NVIM_LAZYVIM_DEP_PKGS) is escalated as one apt transaction; `lazygit` is
# best-effort and installed SEPARATELY so a missing apt candidate (it is absent on older Ubuntu)
# only warns instead of failing the whole set. The tree-sitter CLI is NOT installed here — LazyVim
# auto-installs it, and we ensure `gzip` is present (in the set) so it can. Clipboard helpers are
# best-effort and only matter with a display (SSH note printed). NEVER Node: Mason's LSP runtime is
# opt-in — if absent we point at `swkit node install`, we never auto-install.
_nvim_ensure_deps() {
  # shellcheck disable=SC2086  # word-splitting the package list into separate apt args is intended
  apt_install $NVIM_LAZYVIM_DEP_PKGS

  # lazygit — LazyVim integrates it but it is optional; a missing apt candidate must not abort deps.
  if have_cmd lazygit; then
    log_info "lazygit already installed."
  else
    apt_install lazygit || log_warn "Could not install lazygit (optional; not in apt on older Ubuntu) — install it yourself for LazyVim's git UI."
  fi

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

# --- Domain 2 · font (delegates to fonts.sh) -----------------------------------
# set-font <name> [size] — Neovim is a TUI; its font is rendered by the TERMINAL emulator, not by
# nvim. So this just delegates to fonts.sh: install the Nerd Font, and (if a size is given) apply it
# to the LOCAL display (Ptyxis / GNOME Terminal / GNOME monospace, via fonts.sh's user-level
# gsettings). `<name>` is a curated display name (mapped to a fonts.sh key) or a fonts.sh key itself.
# Honesty: `apply` only affects the LOCAL machine's terminal; over SSH/headless (no DISPLAY) we install
# the font and tell you to pick it in your CLIENT terminal (where the glyphs actually render). nvim.sh
# stores no font state of its own — fonts.sh owns fonts.conf.
do_set_font() {
  _nvim_resolve_home || return 1
  local name="${1:-}" size="${2:-}" key fs
  [[ -n "$name" ]] || { log_err "Usage: ${0##*/} set-font <name> [size]  (curated: MesloLGS NF / JetBrainsMono / FiraCode / Hack)"; return 2; }
  # Map a curated display name to its fonts.sh key; otherwise accept a fonts.sh key as-is.
  key="${NVIM_FONT_KEY[$name]:-}"
  if [[ -z "$key" ]]; then
    case " $NVIM_FONT_KEYS " in
      *" $name "*) key="$name" ;;
      *) log_err "Unknown font: $name (curated: MesloLGS NF / JetBrainsMono / FiraCode / Hack; or a fonts.sh key: ${NVIM_FONT_KEYS})."; return 2 ;;
    esac
  fi
  # Validate the size BEFORE any side effect (so a bad size errors out without installing anything).
  [[ -z "$size" || "$size" =~ ^[0-9]+$ ]] || { log_err "Invalid font size: $size (a positive integer)."; return 2; }
  fs="$KIT_SCRIPTS_DIR/fonts.sh"
  [[ -x "$fs" ]] || { log_err "fonts.sh not found/executable ($fs) — cannot manage the Nerd Font (try: swkit fonts install $key)."; return 1; }
  log_info "Installing the Nerd Font '$key' via fonts.sh (nvim is a TUI; the font is rendered by your terminal)…"
  "$fs" install "$key" || { log_err "fonts.sh install $key failed."; return 1; }
  if [[ -n "$size" ]]; then
    "$fs" apply "$key" "$size" || log_warn "fonts.sh apply $key $size did not complete (SSH/headless only installs; pick the font in your client terminal)."
  else
    log_info "Installed. To apply it to your local terminal: ${0##*/} set-font $key <size> (or use swkit fonts)."
  fi
  # Honest SSH/no-DISPLAY note: the font renders client-side, not on this machine.
  if [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" || -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    log_info "Neovim is a TUI: its glyphs render in your CLIENT terminal — select '$key' (a Nerd Font) there."
  fi
}

# --- Managed config layer: helpers + generators + ops --------------------------
# All user-space (no sudo). The kit mirrors every domain's state into nvim.conf so status/ui and the
# pure-function file generators can regenerate the LazyVim products from it. Keys:
#   CFG_COLORSCHEME            domain 1 — colorscheme name
#   PLUGINS / DISABLED_PLUGINS domain 3 — curated add-plugin keys / disabled LazyVim plugins (lists)
#   EXTRA_PLUGIN_<slug>        domain 3 — a non-curated plugin spec (owner/repo or git-url)
#   EXTRAS                     domain 4 — enabled lazyvim.json extras mirror (lazyvim.json is truth)
#   CFG_LEADER                 domain 5 — leader key (char or 'space')
#   KEYMAP_<slug>              domain 6 — a keymap (TAB-joined mode/lhs/rhs/desc)
#   OPT_<name> / AUTOFORMAT    domain 7 — an option value / format-on-save toggle (vim.g.autoformat)
#   AUTOCMD_<name>             domain 8 — a curated autocmd toggle (on)
#   MASON_TOOLS                domain 9 — mason ensure_installed tools (list)
#   CHANNEL / DEFAULT_EDITOR   binary channel mirror / the editor toggle's recorded value

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
# config-show — read-only: print the current kit-managed config state (from nvim.conf) for a human or
# an LLM to inspect. No state change, no nvim spawn. Covers every domain the kit owns: colorscheme,
# plugins (added / disabled), Mason tools, leader, options (+ format-on-save), keymaps, autocmds,
# extras. (Extras also live in lazyvim.json, the source of truth; this mirror is what the kit enabled.)
do_config_show() {
  _nvim_resolve_home || return 1
  local v src
  src="$(_lazyvim_marker_read)"
  printf 'kit-managed nvim+LazyVim config:\n'
  printf '  base            : %s\n' "${src:-not installed (no LazyVim ownership marker)}"
  v="$(_nvim_conf_get CFG_COLORSCHEME)";     printf '  colorscheme     : %s\n' "${v:-(LazyVim default)}"
  v="$(_nvim_conf_get PLUGINS)";             printf '  plugins         : %s\n' "${v:-(none)}"
  v="$(_nvim_extra_plugins | paste -sd' ' -)"; printf '  plugins (urls)  : %s\n' "${v:-(none)}"
  v="$(_nvim_conf_get DISABLED_PLUGINS)";    printf '  disabled plugins: %s\n' "${v:-(none)}"
  v="$(_nvim_conf_get MASON_TOOLS)";         printf '  Mason tools     : %s\n' "${v:-(none)}"
  v="$(_nvim_conf_get CFG_LEADER)";          printf '  leader          : %s\n' "${v:-space (default)}"
  v="$(_nvim_conf_get AUTOFORMAT)";          printf '  format-on-save  : %s\n' "$([[ "$v" == off ]] && printf 'off' || printf 'on (default)')"
  printf '  options         :'
  if [[ -f "${_NV_PREF:-}" ]] && grep -qE '^OPT_[a-z_]+=' "$_NV_PREF" 2>/dev/null; then
    local key val
    while IFS='=' read -r key val; do printf ' %s=%s' "${key#OPT_}" "$val"; done < <(grep -E '^OPT_[a-z_]+=' "$_NV_PREF" 2>/dev/null || true)
    printf '\n'
  else printf ' (none)\n'; fi
  printf '  keymaps         :'
  if [[ -f "${_NV_PREF:-}" ]] && grep -qE '^KEYMAP_' "$_NV_PREF" 2>/dev/null; then
    local kval mode lhs
    while IFS='=' read -r _ kval; do IFS=$'\t' read -r mode lhs _ _ <<<"$kval"; printf ' %s:%s' "$mode" "$lhs"; done < <(grep -E '^KEYMAP_' "$_NV_PREF" 2>/dev/null || true)
    printf '\n'
  else printf ' (none)\n'; fi
  printf '  autocmds        :'
  local any=0 a
  for a in $NVIM_AUTOCMD_ORDER; do [[ "$(_nvim_conf_get "AUTOCMD_$a")" == on ]] && { printf ' %s' "$a"; any=1; }; done
  (( any )) && printf '\n' || printf ' (none)\n'
  v="$(_nvim_conf_get EXTRAS)";              printf '  extras (kit)    : %s\n' "${v:-(none)}"
}

# config-reset — remove the kit-managed config PRODUCTS (the 5 things the kit writes into LazyVim's
# files) and clear the matching nvim.conf domain state. Keeps timestamped backups (every removal backs
# up first). Touches ONLY the kit's own products: the kit-owned lua/plugins/ubuntu-setup.lua (deleted
# only if its first line is our marker) and the managed BLOCKS inside lua/config/{options,keymaps,
# autocmds}.lua (stripped, the user's content outside the markers preserved — via _nvim_apply_block on
# empty state). EXTRAS are NOT in scope: lazyvim.json is a LazyVim file the user also edits, so we only
# point at `extra-remove` for the extras the kit enabled (never wipe lazyvim.json). The ownership
# marker + the binary + the cloned/adopted config dir are NOT touched (that is `remove`). Every path
# goes through the _nvim_path_under_config guard inside the apply/render helpers.
do_config_reset() {
  _nvim_resolve_home || return 1
  [[ $# -eq 0 ]] || { log_err "config-reset takes no arguments."; return 2; }
  # 1) Remove the kit-owned plugins file (theme + plugins + Mason) — only if it is ours (marker check).
  local pf="$_NV_NVIM_DIR/$NVIM_PLUGINS_FILE_REL" first=""
  if [[ -f "$pf" ]]; then
    IFS= read -r first <"$pf" || true
    if [[ "$first" == "$NVIM_PLUGINS_MARKER" ]]; then
      _nvim_path_under_config "$pf" || { log_err "Refusing to remove outside ~/.config: $pf"; return 1; }
      backup_file "$pf"; rm -f "$pf"
      log_info "Removed kit-managed plugins file (a backup was kept): $pf"
    else
      log_info "$pf is not kit-managed — leaving it in place."
    fi
  fi
  # 2) Clear the nvim.conf state for every domain the kit owns (so re-generation produces nothing).
  local k
  for k in CFG_COLORSCHEME PLUGINS DISABLED_PLUGINS MASON_TOOLS CFG_LEADER AUTOFORMAT; do _nvim_conf_unset "$k"; done
  if [[ -f "${_NV_PREF:-}" ]]; then
    local tmp; tmp="$(mktemp)"
    grep -vE '^(EXTRA_PLUGIN_|OPT_|KEYMAP_|AUTOCMD_)' "$_NV_PREF" >"$tmp" 2>/dev/null || true
    mv "$tmp" "$_NV_PREF" || rm -f "$tmp"
  fi
  # 3) Strip the managed blocks from lua/config/{options,keymaps,autocmds}.lua. With the state cleared
  #    above, _nvim_gen_*_block now yields nothing for options-state but leader is ALWAYS written, so the
  #    options block would persist; so reset removes ALL THREE blocks directly (preserving content
  #    outside the markers) rather than relying on empty-state regeneration.
  local which file stripped newf
  for which in options keymaps autocmds; do
    file="$_NV_NVIM_DIR/lua/config/$which.lua"
    [[ -f "$file" ]] || continue
    _nvim_path_under_config "$file" || { log_err "Refusing to write outside ~/.config: $file"; return 1; }
    awk -v b="$NVIM_BLOCK_BEGIN" -v e="$NVIM_BLOCK_END" 'BEGIN{found=0} $0==b{inblk=1;found=1} inblk==0{print} $0==e{inblk=0} END{exit found?0:1}' "$file" >/dev/null 2>&1 || continue
    stripped="$(awk -v b="$NVIM_BLOCK_BEGIN" -v e="$NVIM_BLOCK_END" '$0==b{inblk=1} inblk==0{print} $0==e{inblk=0}' "$file")"
    newf="$(mktemp)"
    [[ -n "$stripped" ]] && printf '%s\n' "$stripped" >"$newf"
    if cmp -s "$newf" "$file"; then rm -f "$newf"; continue; fi
    backup_file "$file"
    mv "$newf" "$file" || { rm -f "$newf"; return 1; }
    log_info "Stripped the kit-managed block from $file (your content outside the markers is preserved)."
  done
  log_info "Reset the kit-managed nvim config. To disable extras the kit enabled, use: ${0##*/} extra-remove <cat.name>."
  log_info "(This did NOT remove LazyVim itself or its ownership marker — that is: ${0##*/} remove.)"
}

# === Settings layer · domain 1 (theme) / 3 (plugins) / 9 (Mason) ===============
# All three domains write ONE kit-owned file, ~/.config/nvim/lua/plugins/ubuntu-setup.lua, which
# LazyVim auto-loads (it globs lua/plugins/*.lua). The file is regenerated wholesale from nvim.conf
# state (a pure function), so the three domains compose into a single `return { … }`. All user-space
# (never sudo). nvim.conf keys this layer owns:
#   CFG_COLORSCHEME       — colorscheme name (domain 1); empty = LazyVim's default (tokyonight).
#   PLUGINS               — space list of owner/repo plugin specs (domain 3).
#   EXTRA_PLUGIN_<slug>   — a git-URL plugin spec (domain 3); value is the URL.
#   DISABLED_PLUGINS      — space list of owner/repo to disable (domain 3, `enabled = false`).
#   MASON_TOOLS           — space list of Mason tools for ensure_installed (domain 9).

# Validate an owner/repo plugin id (the only non-URL form we emit into Lua). Conservative charset
# barring any Lua-string-breaking metacharacter; one slash separating two path-safe components.
_nvim_owner_repo_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; }
# Validate a Mason tool name (registry ids are letters/digits/._-; bars Lua injection).
_nvim_mason_tool_valid() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

# Echo the lua/plugins spec line for the curated colorscheme NAME (empty for a built-in / unknown).
# Built-ins (tokyonight, catppuccin) and any non-curated name map to "" (no extra plugin spec).
_nvim_theme_spec() { printf '%s' "${NVIM_THEME_SPEC[$1]:-}"; }
# Background mode label ("dark/light" | "dark" | "light"; empty for non-curated names).
_nvim_theme_mode() { printf '%s' "${NVIM_THEME_MODE[$1]:-}"; }

# _nvim_render_plugins_file — PURE: emit lua/plugins/ubuntu-setup.lua to stdout from nvim.conf state.
# First line is the ownership marker. Composes domain 1 (theme) + 3 (plugins) + 9 (Mason) into one
# `return { … }`. Emits nothing plugin-wise when no plugins/Mason are configured; always emits the
# colorscheme opt when CFG_COLORSCHEME is set (a no-op default otherwise). Validated upstream by the
# setters, so values here are already safe to drop into Lua strings.
_nvim_render_plugins_file() {
  local color spec repo url tool tools_lua=""
  color="$(_nvim_conf_get CFG_COLORSCHEME)"
  printf '%s\n' "$NVIM_PLUGINS_MARKER"
  cat <<'LUA'
-- Generated by `swkit nvim` — kit owns this whole file (theme + plugins + Mason).
-- Do NOT edit (regenerated on every change); put your own plugins in other lua/plugins/*.lua files.
return {
LUA
  # Domain 1 · theme. Non-built-in curated schemes need their plugin spec line first.
  if [[ -n "$color" ]]; then
    spec="$(_nvim_theme_spec "$color")"
    [[ -n "$spec" ]] && printf '  %s\n' "$spec"
    printf '  { "LazyVim/LazyVim", opts = { colorscheme = "%s" } },\n' "$color"
  fi
  # Domain 3 · plugins. owner/repo from PLUGINS, git-URLs from EXTRA_PLUGIN_*, disables last.
  for repo in $(_nvim_conf_get PLUGINS); do
    printf '  { "%s" },\n' "$repo"
  done
  while IFS= read -r url; do
    [[ -n "$url" ]] || continue
    printf '  { url = "%s" },\n' "$url"
  done < <(_nvim_extra_plugins)
  for repo in $(_nvim_conf_get DISABLED_PLUGINS); do
    printf '  { "%s", enabled = false },\n' "$repo"
  done
  # Domain 9 · Mason. opts_extend merges ensure_installed across specs (verified), so one line is safe.
  for tool in $(_nvim_conf_get MASON_TOOLS); do
    tools_lua="${tools_lua:+$tools_lua, }\"$tool\""
  done
  [[ -n "$tools_lua" ]] && printf '  { "mason-org/mason.nvim", opts = { ensure_installed = { %s } } },\n' "$tools_lua"
  printf '}\n'
}

# _nvim_apply_plugins_file — write the generated file under LazyVim's lua/plugins/, then sync. Guards:
# path stays under ~/.config; refuse to clobber a non-kit file (first line not our marker); back up an
# existing kit file; write via mktemp + atomic mv; then drive lazy.nvim headless to install/clean.
_nvim_apply_plugins_file() {
  local file dir tmp
  file="$_NV_NVIM_DIR/$NVIM_PLUGINS_FILE_REL"
  dir="$(dirname "$file")"
  _nvim_path_under_config "$file" || { log_err "Refusing to write outside ~/.config: $file"; return 1; }
  if [[ -f "$file" ]]; then
    local first; IFS= read -r first <"$file" || true
    [[ "$first" == "$NVIM_PLUGINS_MARKER" ]] || { log_err "$file exists but is not kit-managed — refusing to overwrite (move it aside first)."; return 1; }
    backup_file "$file"
  fi
  mkdir -p "$dir"
  tmp="$(mktemp)"
  _nvim_render_plugins_file >"$tmp"
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  log_info "Wrote kit-managed plugins file: $file"
  # Install/clean the plugins LazyVim now sees. Needs nvim; _nvim_sync warns+returns if absent.
  _nvim_sync sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} update-plugins (or just launch nvim)."
  return 0
}

# --- Domain 1/3/9 ops (parametric; routed by kit_dispatch; ui-reachable in S7) --
# set-colorscheme <name> — domain 1. Curated → table lookup (built-in or plugin-backed); any other
# valid name → set the opt + warn to add-plugin its plugin. Empty clears (back to LazyVim default).
do_set_colorscheme() {
  _nvim_resolve_home || return 1
  local c="${1-}"
  if [[ -n "$c" ]]; then
    _nvim_colorscheme_valid "$c" || { log_err "Invalid colorscheme name: $c (letters/digits/_-)."; return 2; }
    if [[ -z "${NVIM_THEME_SPEC[$c]+x}" ]]; then
      log_warn "'$c' is not a curated colorscheme — setting it anyway. If it is not built-in/already"
      log_warn "installed, install its plugin too: ${0##*/} add-plugin <owner/repo>."
    fi
  fi
  _nvim_conf_set CFG_COLORSCHEME "$c"
  _nvim_apply_plugins_file
}

# add-plugin <owner/repo|git-url> — domain 3. owner/repo → PLUGINS list; a git-URL → EXTRA_PLUGIN_<slug>.
do_add_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} add-plugin <owner/repo|git-url>"; return 2; }
  if _nvim_owner_repo_valid "$arg"; then
    _nvim_cfg_list_add PLUGINS "$arg"
  elif _nvim_giturl_valid "$arg"; then
    _nvim_conf_set "EXTRA_PLUGIN_$(_nvim_plugin_slug "$arg")" "$arg"
  else
    log_err "Invalid plugin: $arg (use owner/repo or an https/ssh/git URL)."; return 2
  fi
  _nvim_apply_plugins_file
}

# remove-plugin <name> — domain 3. Drop NAME from PLUGINS, DISABLED_PLUGINS, and any EXTRA_PLUGIN_*.
do_remove_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} remove-plugin <owner/repo|git-url>"; return 2; }
  _nvim_cfg_list_remove PLUGINS "$arg"
  _nvim_cfg_list_remove DISABLED_PLUGINS "$arg"
  _nvim_conf_unset "EXTRA_PLUGIN_$(_nvim_plugin_slug "$arg")"
  _nvim_apply_plugins_file
}

# disable-plugin <owner/repo> — domain 3. Emit `{ "<repo>", enabled = false }` (turn off a LazyVim
# default without removing it). Drop it from PLUGINS too (disable wins over an explicit add).
do_disable_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} disable-plugin <owner/repo>"; return 2; }
  _nvim_owner_repo_valid "$arg" || { log_err "Invalid plugin: $arg (use owner/repo)."; return 2; }
  _nvim_cfg_list_remove PLUGINS "$arg"
  _nvim_cfg_list_add DISABLED_PLUGINS "$arg"
  _nvim_apply_plugins_file
}

# enable-plugin <owner/repo> — domain 3. Undo a disable (remove it from DISABLED_PLUGINS).
do_enable_plugin() {
  _nvim_resolve_home || return 1
  local arg="${1:-}"; [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} enable-plugin <owner/repo>"; return 2; }
  _nvim_owner_repo_valid "$arg" || { log_err "Invalid plugin: $arg (use owner/repo)."; return 2; }
  _nvim_cfg_list_remove DISABLED_PLUGINS "$arg"
  _nvim_apply_plugins_file
}

# mason-add <tool> — domain 9. Add a tool to MASON_TOOLS (ensure_installed). Mason installs it on its
# next launch. LSP servers that need a Node runtime go through the Node gate — never auto-install Node.
do_mason_add() {
  _nvim_resolve_home || return 1
  local tool="${1:-}"; [[ -n "$tool" ]] || { log_err "Usage: ${0##*/} mason-add <tool>"; return 2; }
  _nvim_mason_tool_valid "$tool" || { log_err "Invalid Mason tool: $tool (letters/digits/._-)."; return 2; }
  _nvim_cfg_list_add MASON_TOOLS "$tool"
  have_cmd node || log_info "$(_nvim_t node_hint)"
  log_info "For configuring a whole language at once, prefer: ${0##*/} extra-add lang.<name>."
  _nvim_apply_plugins_file
}

# mason-remove <tool> — domain 9. Drop a tool from MASON_TOOLS (Mason won't uninstall an already
# installed tool — that is :MasonUninstall inside nvim — but it leaves ensure_installed).
do_mason_remove() {
  _nvim_resolve_home || return 1
  local tool="${1:-}"; [[ -n "$tool" ]] || { log_err "Usage: ${0##*/} mason-remove <tool>"; return 2; }
  _nvim_cfg_list_remove MASON_TOOLS "$tool"
  _nvim_apply_plugins_file
}

# list-colorschemes — print the curated theme table (built-in vs plugin-backed). No state change.
do_list_colorschemes() {
  local name spec mode
  printf 'Curated colorschemes (set with: %s set-colorscheme <name>):\n' "${0##*/}"
  for name in $NVIM_THEME_ORDER; do
    spec="$(_nvim_theme_spec "$name")"; mode="$(_nvim_theme_mode "$name")"
    if [[ -z "$spec" ]]; then printf '  %-12s  %-10s  built-in (ships with LazyVim)\n' "$name" "$mode"
    else printf '  %-12s  %-10s  plugin: %s\n' "$name" "$mode" "$(printf '%s' "$spec" | sed -E 's/^\{ "([^"]+)".*/\1/')"; fi
  done
  printf 'Any other name is accepted too (add-plugin its plugin if it is not built-in/installed).\n'
}

# === Settings layer · domain 5 (leader) / 6 (keymaps) / 7 (options) / 8 (autocmds) =====
# These four domains write a kit-owned MANAGED BLOCK into LazyVim's OWN config files (the
# tmux.sh managed-block pattern: marker-delimited region, rewritten wholesale, user content
# outside the markers preserved, backup before any change). LazyVim auto-loads these by NAME
# (never require them yourself) and applies the user's lua/config/* AFTER its own defaults, so
# our block overrides LazyVim's options/keymaps/autocmds. ONE exception (verified): leader must
# be set in lua/config/options.lua, which LazyVim loads BEFORE lazy.setup() — so vim.g.mapleader
# lands before any mapping is created. Note "options can only be overridden, not disabled"
# (LazyVim #566): `defaults.options=false` is a no-op, so we re-set every option in our block.
#   options.lua block : leader (domain 5) + options + format-on-save (domain 7)
#   keymaps.lua block : keymaps (domain 6)
#   autocmds.lua block: curated autocmds + disable-named-augroup toggles (domain 8)
# nvim.conf keys this layer owns:
#   CFG_LEADER          — leader char, or the word 'space' (domain 5); empty = LazyVim default (space).
#   OPT_<name>          — an editor option value (domain 7); value is on|off|<int>|<simple string>.
#   AUTOFORMAT          — off → emit `vim.g.autoformat = false` (domain 7, format-on-save).
#   KEYMAP_<slug>       — a keymap, stored as <mode>\t<lhs>\t<rhs>\t<desc> (domain 6); slug = mode+lhs.
#   AUTOCMD_<name>=on   — a curated autocmd enabled (domain 8).

# Curated, first-class autocmds (the ONLY ones add-autocmd accepts — arbitrary Lua autocmds are a
# Lua-injection vector and stay the user's own territory). Each key maps to a fixed, hand-written
# Lua snippet emitted by _nvim_gen_autocmds_block. Two kinds: additive QoL autocmds, and
# "disable a LazyVim default" toggles that call nvim_del_augroup_by_name on a verified lazyvim_*
# augroup (names from LazyVim's lua/lazyvim/config/autocmds.lua). Names stay UNtranslated.
declare -gA NVIM_AUTOCMD_DESC=(
  [trim_whitespace]="Trim trailing whitespace on save"
  [disable_wrap_spell]="Disable LazyVim's auto wrap+spell in text/markdown filetypes"
  [disable_highlight_yank]="Disable LazyVim's highlight-on-yank flash"
)
# Stable display order (associative arrays are unordered).
readonly NVIM_AUTOCMD_ORDER="trim_whitespace disable_wrap_spell disable_highlight_yank"

# --- Validators (block injection into the generated Lua) -----------------------
# An option name: lowercase letters + underscore (Neovim option names like relativenumber,
# shiftwidth, conceallevel). Plus the special token 'autoformat' (handled as vim.g, not vim.opt).
_nvim_option_name_valid() { [[ "$1" =~ ^[a-z_]+$ ]]; }
# An option value: on|off (→ true/false), a non-negative integer, or a simple bareword string
# (letters/digits/_.,- only). Anything with a quote/backslash/space is rejected — it would break
# (or inject into) the generated `vim.opt.<name> = "<value>"` Lua string.
_nvim_option_value_valid() {
  case "$1" in
    on|off) return 0 ;;
    ''|*[!0-9]*) ;;  # not a pure integer; fall through to the string check
    *) return 0 ;;   # pure non-negative integer
  esac
  [[ "$1" =~ ^[A-Za-z0-9_.,-]+$ ]]
}
# Curated, commonly-changed options surfaced in the ui()/help (set-option accepts ANY valid name).
readonly NVIM_OPTION_CURATED="relativenumber wrap scrolloff shiftwidth tabstop conceallevel background spell"
# A keymap mode: one of Neovim's single-letter mode short-names.
_nvim_keymap_mode_valid() { case "$1" in n|i|v|x|s|o|t|c) return 0 ;; *) return 1 ;; esac; }
# A keymap lhs/rhs/desc: reject the chars that would break the generated double-quoted Lua string
# (a double-quote, a backslash) or the line itself (a newline / carriage return). Everything else
# (incl. <leader>, <cmd>…<cr>, ; | etc.) is fine inside "<…>". Empty lhs/rhs is rejected by callers.
_nvim_keymap_field_valid() { case "$1" in *[\"$'\\']*|*$'\n'*|*$'\r'*) return 1 ;; *) return 0 ;; esac; }
# A conf-key-safe slug for a keymap (mode + lhs): non-alnum → underscore.
_nvim_keymap_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }

# --- Lua value emitter ---------------------------------------------------------
# Emit the Lua literal for an option value: on→true, off→false, a pure integer verbatim, else a
# double-quoted string (validated upstream so it is already quote/backslash-free).
_nvim_lua_value() {
  case "$1" in
    on)  printf 'true' ;;
    off) printf 'false' ;;
    ''|*[!0-9]*) printf '"%s"' "$1" ;;
    *)   printf '%s' "$1" ;;
  esac
}

# --- Pure block generators (stdout only; values pre-validated by the setters) ---
# options.lua block body: leader (domain 5) + options + format-on-save (domain 7). Always writes
# the leader (the LazyVim default space too) so the block is self-documenting and leader is pinned
# before lazy.setup. Each OPT_<name> becomes `vim.opt.<name> = <lua literal>`; the special
# AUTOFORMAT=off becomes `vim.g.autoformat = false`.
_nvim_gen_options_block() {
  local l; l="$(_nvim_conf_get CFG_LEADER)"; [[ -n "$l" ]] || l="space"
  [[ "$l" == space ]] && l=" "
  printf 'vim.g.mapleader = "%s"\n' "$l"
  printf 'vim.g.maplocalleader = "\\\\"\n'
  local key name val
  if [[ -f "${_NV_PREF:-}" ]]; then
    while IFS='=' read -r key val; do
      case "$key" in
        OPT_*) name="${key#OPT_}"; printf 'vim.opt.%s = %s\n' "$name" "$(_nvim_lua_value "$val")" ;;
      esac
    done < <(grep -E '^OPT_[a-z_]+=' "$_NV_PREF" 2>/dev/null || true)
  fi
  [[ "$(_nvim_conf_get AUTOFORMAT)" == off ]] && printf 'vim.g.autoformat = false\n'
  return 0
}
# keymaps.lua block body: one vim.keymap.set per stored KEYMAP_<slug> (domain 6).
_nvim_gen_keymaps_block() {
  local key val mode lhs rhs desc
  [[ -f "${_NV_PREF:-}" ]] || return 0
  while IFS='=' read -r key val; do
    case "$key" in KEYMAP_*) ;; *) continue ;; esac
    IFS=$'\t' read -r mode lhs rhs desc <<<"$val"
    [[ -n "$mode" && -n "$lhs" && -n "$rhs" ]] || continue
    printf 'vim.keymap.set("%s", "%s", "%s", { desc = "%s" })\n' "$mode" "$lhs" "$rhs" "$desc"
  done < <(grep -E '^KEYMAP_[A-Za-z0-9_]+=' "$_NV_PREF" 2>/dev/null || true)
  return 0
}
# autocmds.lua block body: each enabled curated autocmd's fixed Lua snippet (domain 8).
_nvim_gen_autocmds_block() {
  local name
  for name in $NVIM_AUTOCMD_ORDER; do
    [[ "$(_nvim_conf_get "AUTOCMD_$name")" == on ]] || continue
    case "$name" in
      trim_whitespace) cat <<'LUA'
vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("ubuntu_setup_trim_whitespace", { clear = true }),
  pattern = "*",
  callback = function()
    local save = vim.fn.winsaveview()
    vim.cmd([[keeppatterns %s/\s\+$//e]])
    vim.fn.winrestview(save)
  end,
})
LUA
        ;;
      disable_wrap_spell)     printf 'pcall(vim.api.nvim_del_augroup_by_name, "lazyvim_wrap_spell")\n' ;;
      disable_highlight_yank) printf 'pcall(vim.api.nvim_del_augroup_by_name, "lazyvim_highlight_yank")\n' ;;
    esac
  done
  return 0
}

# --- Managed-block writer (parametric over which ∈ options|keymaps|autocmds) ----
# _nvim_apply_block <which> — regenerate the kit's managed block inside LazyVim's
# lua/config/<which>.lua (the tmux.sh pattern). Strip any existing block (preserving content
# outside the markers), append a freshly generated one at the end, back up before any change,
# no-op when unchanged. The block body comes from _nvim_gen_<which>_block. Guards: path stays
# under ~/.config; the file need NOT be kit-owned (we only own the marker region, so a user's own
# lua/config/<which>.lua is preserved). Empty body → the block is removed entirely (a no-op block
# would be noise). Block presence is detected with awk (exact-line), never grep (the marker starts
# with "--" — grep would treat it as an option).
_nvim_apply_block() {
  local which="$1" file body stripped newf
  case "$which" in options|keymaps|autocmds) ;; *) log_err "Internal: unknown block '$which'."; return 2 ;; esac
  file="$_NV_NVIM_DIR/lua/config/$which.lua"
  _nvim_path_under_config "$file" || { log_err "Refusing to write outside ~/.config: $file"; return 1; }
  body="$(_nvim_gen_"$which"_block)"
  mkdir -p "$(dirname "$file")"
  # Strip any existing managed block (exact-line markers), keeping everything outside it.
  stripped=""
  if [[ -f "$file" ]]; then
    stripped="$(awk -v b="$NVIM_BLOCK_BEGIN" -v e="$NVIM_BLOCK_END" \
      '$0==b{inblk=1} inblk==0{print} $0==e{inblk=0}' "$file")"
  fi
  newf="$(mktemp)"
  {
    [[ -n "$stripped" ]] && printf '%s\n' "$stripped"
    if [[ -n "$body" ]]; then
      [[ -n "$stripped" ]] && printf '\n'
      printf '%s\n' "$NVIM_BLOCK_BEGIN"
      printf '%s\n' "-- Generated by \`swkit nvim\` — kit owns ONLY this block (regenerated on every change)."
      printf '%s\n' "-- Edit your own $which OUTSIDE these markers; they are preserved."
      printf '%s\n' "$body"
      printf '%s\n' "$NVIM_BLOCK_END"
    fi
  } >"$newf"
  if [[ -f "$file" ]] && cmp -s "$newf" "$file"; then rm -f "$newf"; return 0; fi
  [[ -f "$file" ]] && backup_file "$file"
  mv "$newf" "$file" || { rm -f "$newf"; return 1; }
  log_info "Updated the managed block in $file (your own content outside the markers is preserved)."
  log_info "Restart nvim to apply."
  return 0
}

# --- Domain 5/6/7/8 ops (parametric; routed by kit_dispatch; ui-reachable) ------
# set-leader <char|space> — domain 5. Writes CFG_LEADER, regenerates the options.lua block (where
# LazyVim loads leader before lazy.setup). Empty arg is an error; '' is not a clear here (the
# default space is always written).
do_set_leader() {
  _nvim_resolve_home || return 1
  local l="${1:-}"; [[ -n "$l" ]] || { log_err "Usage: ${0##*/} set-leader <char|space>"; return 2; }
  _nvim_leader_valid "$l" || { log_err "Invalid leader: $l (a single character other than \" or \\, or the word 'space')."; return 2; }
  _nvim_conf_set CFG_LEADER "$l"
  log_info "Leader set to '${l}'."
  _nvim_apply_block options
}

# set-option <name> <value> — domain 7. Curated names are hinted; ANY valid name works. The special
# name 'autoformat' toggles format-on-save (vim.g.autoformat), stored under AUTOFORMAT, not OPT_*.
do_set_option() {
  _nvim_resolve_home || return 1
  local name="${1:-}" val="${2:-}"
  [[ -n "$name" && $# -ge 2 ]] || { log_err "Usage: ${0##*/} set-option <name> <on|off|int|word>"; return 2; }
  _nvim_option_name_valid "$name"  || { log_err "Invalid option name: $name (lowercase letters/underscore)."; return 2; }
  _nvim_option_value_valid "$val"  || { log_err "Invalid option value: $val (on|off, an integer, or a simple word)."; return 2; }
  if [[ "$name" == autoformat ]]; then
    case "$val" in
      on)  _nvim_conf_unset AUTOFORMAT; log_info "Format-on-save: on (LazyVim default)." ;;
      off) _nvim_conf_set AUTOFORMAT off; log_info "Format-on-save: off (vim.g.autoformat = false)." ;;
      *) log_err "set-option autoformat takes on|off."; return 2 ;;
    esac
  else
    _nvim_conf_set "OPT_$name" "$val"
    # Hint when the name is outside the commonly-changed set (still accepted — any valid option works).
    local w curated=0
    for w in $NVIM_OPTION_CURATED; do [[ "$w" == "$name" ]] && { curated=1; break; }; done
    (( curated )) || log_info "Note: '$name' is outside the commonly-changed set (${NVIM_OPTION_CURATED}) — set as vim.opt.$name anyway."
  fi
  _nvim_apply_block options
}

# unset-option <name> — domain 7. Drop OPT_<name> (or AUTOFORMAT for 'autoformat'), back to LazyVim's
# default (the option is simply no longer re-set in our block).
do_unset_option() {
  _nvim_resolve_home || return 1
  local name="${1:-}"; [[ -n "$name" ]] || { log_err "Usage: ${0##*/} unset-option <name>"; return 2; }
  _nvim_option_name_valid "$name" || { log_err "Invalid option name: $name (lowercase letters/underscore)."; return 2; }
  if [[ "$name" == autoformat ]]; then _nvim_conf_unset AUTOFORMAT; else _nvim_conf_unset "OPT_$name"; fi
  _nvim_apply_block options
}

# list-options — print the commonly-changed options + the format-on-save toggle. No state change.
# (set-option still accepts ANY valid Neovim option name; this is just the curated shortlist.)
do_list_options() {
  local name
  printf 'Commonly-changed options (set with: %s set-option <name> <on|off|int|word>):\n' "${0##*/}"
  for name in $NVIM_OPTION_CURATED; do printf '  %s\n' "$name"; done
  printf '  autoformat   (special: on|off → vim.g.autoformat, format-on-save)\n'
  printf 'Any other valid Neovim option name is accepted too.\n'
}

# add-keymap <mode> <lhs> <rhs> [desc] — domain 6. Stores KEYMAP_<mode+lhs>; rhs is a command/keys
# string emitted verbatim into vim.keymap.set's rhs. mode/lhs/rhs/desc are validated against Lua
# string injection. A repeated <mode> <lhs> overwrites the previous mapping (idempotent by slug).
do_add_keymap() {
  _nvim_resolve_home || return 1
  local mode="${1:-}" lhs="${2:-}" rhs="${3:-}" desc="${4:-}"
  [[ -n "$mode" && -n "$lhs" && -n "$rhs" ]] || { log_err "Usage: ${0##*/} add-keymap <mode> <lhs> <rhs> [desc]"; return 2; }
  _nvim_keymap_mode_valid "$mode"   || { log_err "Invalid mode: $mode (one of n i v x s o t c)."; return 2; }
  _nvim_keymap_field_valid "$lhs"   || { log_err "Invalid lhs: contains a quote, backslash, or newline."; return 2; }
  _nvim_keymap_field_valid "$rhs"   || { log_err "Invalid rhs: contains a quote, backslash, or newline."; return 2; }
  _nvim_keymap_field_valid "$desc"  || { log_err "Invalid desc: contains a quote, backslash, or newline."; return 2; }
  _nvim_conf_set "KEYMAP_$(_nvim_keymap_slug "${mode}_${lhs}")" "$(printf '%s\t%s\t%s\t%s' "$mode" "$lhs" "$rhs" "$desc")"
  _nvim_apply_block keymaps
}

# remove-keymap <mode> <lhs> — domain 6. Drop the stored mapping by its mode+lhs slug.
do_remove_keymap() {
  _nvim_resolve_home || return 1
  local mode="${1:-}" lhs="${2:-}"
  [[ -n "$mode" && -n "$lhs" ]] || { log_err "Usage: ${0##*/} remove-keymap <mode> <lhs>"; return 2; }
  _nvim_keymap_mode_valid "$mode" || { log_err "Invalid mode: $mode (one of n i v x s o t c)."; return 2; }
  _nvim_keymap_field_valid "$lhs" || { log_err "Invalid lhs: contains a quote, backslash, or newline."; return 2; }
  _nvim_conf_unset "KEYMAP_$(_nvim_keymap_slug "${mode}_${lhs}")"
  _nvim_apply_block keymaps
}

# add-autocmd <name> — domain 8. CURATED ONLY (arbitrary Lua autocmds are an injection vector). Sets
# AUTOCMD_<name>=on and regenerates the autocmds.lua block. Unknown name → error (exit 2).
do_add_autocmd() {
  _nvim_resolve_home || return 1
  local name="${1:-}"; [[ -n "$name" ]] || { log_err "Usage: ${0##*/} add-autocmd <name> (one of: ${NVIM_AUTOCMD_ORDER})"; return 2; }
  [[ -n "${NVIM_AUTOCMD_DESC[$name]:-}" ]] || { log_err "Unknown autocmd: $name (curated: ${NVIM_AUTOCMD_ORDER})."; return 2; }
  _nvim_conf_set "AUTOCMD_$name" on
  _nvim_apply_block autocmds
}

# remove-autocmd <name> — domain 8. Drop AUTOCMD_<name>; regenerate the block. Curated name check
# guards the conf key (an unknown name was never settable anyway).
do_remove_autocmd() {
  _nvim_resolve_home || return 1
  local name="${1:-}"; [[ -n "$name" ]] || { log_err "Usage: ${0##*/} remove-autocmd <name> (one of: ${NVIM_AUTOCMD_ORDER})"; return 2; }
  [[ -n "${NVIM_AUTOCMD_DESC[$name]:-}" ]] || { log_err "Unknown autocmd: $name (curated: ${NVIM_AUTOCMD_ORDER})."; return 2; }
  _nvim_conf_unset "AUTOCMD_$name"
  _nvim_apply_block autocmds
}

# list-autocmds — print the curated autocmd table. No state change.
do_list_autocmds() {
  local name
  printf 'Curated autocmds (toggle with: %s add-autocmd / remove-autocmd <name>):\n' "${0##*/}"
  for name in $NVIM_AUTOCMD_ORDER; do
    printf '  %-24s  %s\n' "$name" "${NVIM_AUTOCMD_DESC[$name]}"
  done
}

# === Settings layer · domain 4 (extras) — lazyvim.json via LazyVim's own json API ====
# Extras are LazyVim's opt-in feature packs (whole-language support, alternate picker/cmp/explorer,
# AI, etc.), enabled by listing their full module name in ~/.config/nvim/lazyvim.json's `extras`
# array. We do NOT hand-edit that JSON with jq on the main path: the file is only written by
# :LazyExtras / migrate (so it may not even exist after a fresh install), it carries a `version` /
# `install_version` / `news` LazyVim alone maintains, and the enable ordering matters. Instead we
# drive LazyVim HEADLESS and let it read-modify-save the JSON itself — the official non-interactive
# equivalent of toggling in :LazyExtras (mirrors util/extras.lua's X:toggle: filter the module out,
# table.insert on add, table.sort, LazyVim.json.save()). User-enabled extras are preserved (we only
# touch the one module named). All user-space (the JSON lives in ~/.config/nvim); the LSP servers an
# extra pulls in are installed by Mason and gated on Node — never auto-installed (see _nvim_ensure_deps).
#
# Curated short list for the ui()/list-extras (extra-add accepts ANY valid <cat>.<name>). All are
# verified-present lang/ modules in the current LazyVim extras tree. NOTE: typescript is NOT an extra
# (LazyVim ships TS support in its defaults — there is no lazyvim.plugins.extras.lang.typescript), and
# `sh` does not exist either; both are intentionally absent here. Names stay UNtranslated.
readonly NVIM_EXTRAS_CURATED="lang.python lang.go lang.rust lang.json lang.yaml lang.toml lang.markdown lang.docker lang.clangd lang.java"

# Validate a <cat>.<name> extra id (cat is letters/digits/underscore; name allows dots so nested ids
# like editor.snacks_picker / lang.typescript / coding.nvim-cmp pass). The conservative charset bars
# every Lua-string-breaking / shell metacharacter (" \ $ ` ; space etc.), so the module it expands to
# is safe to drop into a Lua "…" literal. Requires exactly one dot between cat and name.
_nvim_extra_id_valid() { [[ "$1" =~ ^[a-z0-9_]+\.[a-z0-9_.-]+$ ]]; }
# Expand a <cat>.<name> id to its full LazyVim extra module name.
_nvim_extra_module() { printf 'lazyvim.plugins.extras.%s' "$1"; }

# _nvim_extras_apply <add|remove> <module> — MAIN PATH (headless LazyVim json API). Run nvim headless
# against ~/.config/nvim (as the real user via _NV_HOME which _nvim_resolve_home already set + refused
# a sudo wrap), let LazyVim load + setup, then read-modify-save lazyvim.json's `extras` array itself.
# `<module>` is interpolated into a Lua "…" literal (already validated free of quotes/backslashes/$);
# the add-vs-remove choice is passed as a bare Lua boolean (a shell literal, never user input), so no
# Lua string compare is needed. `pcall(require, "lazyvim.config")` guards a non-LazyVim / not-ready
# config — on failure we `cq` (non-zero exit) and the shell side reports it instead of silently
# "succeeding". The save call is doubly resolved: the LazyVim.json global if present, else
# require("lazyvim.util.json").save (both are the same M.save — verified against LazyVim's source).
#
# SWITCH: this is the main path. If real-machine testing shows the headless json API is unavailable
# (non-LazyVim, API moved, json module not loaded at headless start), the main session may swap the
# call site to _nvim_extras_apply_jq below (which only handles an already-existing lazyvim.json).
_nvim_extras_apply() {
  local op="$1" module="$2" lua add_bool
  case "$op" in add) add_bool="true" ;; remove) add_bool="false" ;; *) log_err "Internal: extras op must be add|remove."; return 2 ;; esac
  have_cmd nvim || { log_err "$(_nvim_t not_installed_first)"; return 1; }
  # `module` is pre-validated by the callers (do_extra_add/remove) as a safe <cat>.<name> expansion —
  # free of quotes/backslashes/$/space — so interpolating it into the Lua "…" literal below is safe.
  lua=$(cat <<LUA
local ok, Config = pcall(require, "lazyvim.config")
if not ok then vim.cmd("cq") end
local extras = Config.json.data.extras or {}
local m = "$module"
extras = vim.tbl_filter(function(x) return x ~= m end, extras)
if $add_bool then table.insert(extras, m) end
table.sort(extras)
Config.json.data.extras = extras
local save = (LazyVim and LazyVim.json and LazyVim.json.save) or require("lazyvim.util.json").save
save()
LUA
)
  log_info "Driving LazyVim headless to ${op} extra '${module}' in lazyvim.json…"
  local rc=0
  if have_cmd timeout; then
    timeout 600 nvim --headless +"lua $lua" +qa || rc=$?
  else
    nvim --headless +"lua $lua" +qa || rc=$?
  fi
  if (( rc != 0 )); then
    log_err "LazyVim headless ${op} of '${module}' failed (exit $rc) — this ~/.config/nvim may not be a"
    log_err "ready LazyVim, or the extras json API changed. lazyvim.json was NOT modified by this run."
    return "$rc"
  fi
  return 0
}

# _nvim_extras_apply_jq <add|remove> <module> — FALLBACK (off by default; see the SWITCH note above).
# Edits ~/.config/nvim/lazyvim.json's `.extras` array with jq, preserving every other field and any
# user-enabled entry. Only handles an ALREADY-EXISTING file: lazyvim.json is created by LazyVim alone
# (:LazyExtras / migrate), so if it is absent we refuse and point the user at launching nvim once to
# let LazyVim generate it (we will not invent its version/install_version/news scaffolding). Backs up
# before any change; refuses a file that is not valid JSON. Needs jq (apt-installed via _nvim_need_jq).
_nvim_extras_apply_jq() {
  local op="$1" module="$2" file tmp
  case "$op" in add|remove) ;; *) log_err "Internal: extras op must be add|remove."; return 2 ;; esac
  file="$_NV_NVIM_DIR/lazyvim.json"
  if [[ ! -f "$file" ]]; then
    log_err "$file does not exist yet. LazyVim creates it only via :LazyExtras — launch nvim once"
    log_err "(or enable any extra in :LazyExtras), then re-run this. (jq fallback only edits an existing file.)"
    return 1
  fi
  _nvim_need_jq || return 1
  if ! jq -e . "$file" >/dev/null 2>&1; then
    log_err "$file is not valid JSON — fix or remove it first (then re-run)."
    return 1
  fi
  _nvim_path_under_config "$file" || { log_err "Refusing to write outside ~/.config: $file"; return 1; }
  backup_file "$file"
  tmp="$(mktemp)"
  # Drop the module unconditionally, re-add on `add`, then sort+unique — mirrors the headless path.
  if [[ "$op" == add ]]; then
    jq --arg m "$module" '.extras = ((.extras // []) - [$m] + [$m] | sort | unique)' "$file" >"$tmp"
  else
    jq --arg m "$module" '.extras = ((.extras // []) - [$m] | sort | unique)' "$file" >"$tmp"
  fi || { rm -f "$tmp"; log_err "Failed to update $file via jq."; return 1; }
  mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# Ensure jq (apt-installed if missing) — the extras jq fallback's dependency (claude.sh's pattern).
_nvim_need_jq() {
  have_cmd jq && return 0
  log_info "jq is needed for the lazyvim.json fallback — installing it…"
  apt_install jq || true
  have_cmd jq && return 0
  log_err "jq is required for the lazyvim.json fallback but could not be installed."
  return 1
}

# extra-add <cat.name> — domain 4. Validate, expand to the full module name, enable it via the
# headless LazyVim json API (preserving user-enabled extras), then sync plugins + prompt a restart.
# Mirrors EXTRAS in nvim.conf for status/ui display + idempotency, but the JSON is the source of
# truth — we NEVER rebuild lazyvim.json from nvim.conf, only surgically toggle the one named module.
do_extra_add() {
  _nvim_resolve_home || return 1
  local id="${1:-}"; [[ -n "$id" ]] || { log_err "Usage: ${0##*/} extra-add <cat.name>  (e.g. lang.go; see: ${0##*/} list-extras)"; return 2; }
  _nvim_extra_id_valid "$id" || { log_err "Invalid extra: $id (use <cat>.<name>, e.g. lang.go / editor.snacks_picker — letters/digits/._- only)."; return 2; }
  local module; module="$(_nvim_extra_module "$id")"
  _nvim_extras_apply add "$module" || return $?
  _nvim_cfg_list_add EXTRAS "$id"
  have_cmd node || log_info "$(_nvim_t node_hint)"
  _nvim_sync sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} update-plugins (or just launch nvim)."
  log_info "Enabled extra '${module}'. Restart nvim to load it (:LazyExtras shows it as enabled)."
}

# extra-remove <cat.name> — domain 4. Disable the extra via the headless json API + drop the EXTRAS
# mirror, then sync. Leaves any plugins the extra installed for lazy to clean on the next launch.
do_extra_remove() {
  _nvim_resolve_home || return 1
  local id="${1:-}"; [[ -n "$id" ]] || { log_err "Usage: ${0##*/} extra-remove <cat.name>  (e.g. lang.go)"; return 2; }
  _nvim_extra_id_valid "$id" || { log_err "Invalid extra: $id (use <cat>.<name>, e.g. lang.go)."; return 2; }
  local module; module="$(_nvim_extra_module "$id")"
  _nvim_extras_apply remove "$module" || return $?
  _nvim_cfg_list_remove EXTRAS "$id"
  _nvim_sync sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} update-plugins (or just launch nvim)."
  log_info "Disabled extra '${module}'. Restart nvim to apply."
}

# list-extras — print the curated short list (verified lang/ modules) + a note that any module works.
# No state change. EXTRAS mirror (kit-enabled this session) is marked when present.
do_list_extras() {
  _nvim_resolve_home || return 1
  local id enabled w
  enabled="$(_nvim_conf_get EXTRAS)"
  printf 'Curated extras (enable with: %s extra-add <cat.name>):\n' "${0##*/}"
  for id in $NVIM_EXTRAS_CURATED; do
    local mark="  "
    for w in $enabled; do [[ "$w" == "$id" ]] && { mark="✓ "; break; }; done
    printf '  %s%s\n' "$mark" "$id"
  done
  printf 'extra-add accepts ANY lazyvim.plugins.extras.<cat>.<name> module (e.g. editor.snacks_picker,\n'
  printf 'coding.nvim-cmp). Browse them all inside nvim with :LazyExtras.\n'
}

# --- Configure -----------------------------------------------------------------
# With NO flags = conservative convergence (never a heavy install):
#   - combo already installed (status true)  → regenerate the kit-managed products so the on-disk Lua
#     matches nvim.conf state (the plugins file + the three lua/config blocks). No sync needed beyond
#     what the apply does; idempotent (a no-op when already in sync).
#   - combo NOT installed                     → just point at `install` / `configure --recommended`
#     (do NOT trigger the binary download / LazyVim clone behind a bare `configure`).
# Flags layer on; --recommended is the one-shot full combo (= install + editor on). Each domain flag
# routes to its setter (the same op the ui/CLI calls), which writes the right LazyVim file + syncs.
do_configure() {
  _nvim_resolve_home || return 1
  if [[ $# -eq 0 ]]; then
    if status >/dev/null 2>&1; then
      log_info "Re-generating the kit-managed nvim config products from saved state…"
      _nvim_apply_plugins_file
      _nvim_apply_block options
      _nvim_apply_block keymaps
      _nvim_apply_block autocmds
    else
      log_info "The nvim + LazyVim combo is not installed. Install it with:"
      log_info "    ${0##*/} install            (binary + deps + Nerd Font + LazyVim + sync)"
      log_info "    ${0##*/} configure --recommended   (the same, plus EDITOR/VISUAL=nvim)"
    fi
    return 0
  fi
  while (( $# > 0 )); do
    case "$1" in
      --recommended)
        do_install || return $?
        do_set_default_editor on
        shift ;;
      --editor)        [[ $# -ge 2 ]] || { log_err "--editor needs on|off."; return 2; }; do_set_default_editor "$2"; shift 2 ;;
      --editor=*)      do_set_default_editor "${1#--editor=}"; shift ;;
      --deps)          do_ensure_deps; shift ;;
      --colorscheme)   [[ $# -ge 2 ]] || { log_err "--colorscheme needs a name."; return 2; }; do_set_colorscheme "$2"; shift 2 ;;
      --colorscheme=*) do_set_colorscheme "${1#--colorscheme=}"; shift ;;
      --leader)        [[ $# -ge 2 ]] || { log_err "--leader needs a key."; return 2; }; do_set_leader "$2"; shift 2 ;;
      --leader=*)      do_set_leader "${1#--leader=}"; shift ;;
      --font)          [[ $# -ge 2 ]] || { log_err "--font needs a name."; return 2; }; do_set_font "$2"; shift 2 ;;
      --font=*)        do_set_font "${1#--font=}"; shift ;;
      -h|--help)  usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager for the nvim + LazyVim combo, grouped by the 9 settings domains. When the combo
# is NOT installed: an install row (with a destructive-config confirm when ~/.config/nvim holds a
# non-LazyVim config) + Apply recommended + deps. When installed: Neovim (update/remove), Colorscheme
# (domain 1, picker), Font (domain 2, fonts.sh), Plugins (domain 3 — added list space-toggles
# remove, disabled list space-toggles enable, `a` adds any owner/repo|git-url, `d` disables any),
# Extras (domain 4 — curated checklist + `a` adds any cat.name), Config (domains 5/6/7/8 — leader,
# curated options + format-on-save, keymaps, curated autocmds), Mason (domain 9 — list + `a` adds a
# tool), then Apply recommended / Reset managed config / Remove. State is read live each pass (fs +
# nvim.conf); every change shells out via ui_run (visible + logged) then the screen reloads. The
# `lazyvim.json` extras truth is mirrored in nvim.conf EXTRAS (set by extra-add/remove) for display.
# Non-selectable rows (headers, spacers, info) are skipped during navigation. `ui` is an entry mode.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }
  _nvim_resolve_home || { ui_end; ui_default_menu; return 0; }

  local sel=0 g w
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" editor_on=0
    if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null)"; fi
    [[ "$(_nvim_conf_get DEFAULT_EDITOR)" == on ]] && editor_on=1

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(_nvim_t install_combo)")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_nvim_t apply_recommended)")
      dkind+=(deps); did+=(deps); dlabel+=("  $(_nvim_t install_deps)")
    else
      # ---- Neovim binary ----
      dkind+=(update); did+=(update); dlabel+=("$(ui_badge check) $(_nvim_t update_nvim)")
      local ebadge; if (( editor_on )); then ebadge="$(ui_badge on)"; else ebadge="$(ui_badge off)"; fi
      dkind+=(editor); did+=(editor); dlabel+=("$ebadge $(_nvim_t default_editor)")
      dkind+=(deps); did+=(deps); dlabel+=("  $(_nvim_t install_deps)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 1 · colorscheme ----
      local cfg_color; cfg_color="$(_nvim_conf_get CFG_COLORSCHEME)"
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_theme)")
      dkind+=(color); did+=(color); dlabel+=("  $(_nvim_t cur_colorscheme): ${UI_INFO}${cfg_color:-(LazyVim default)}${UI_OFF}")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 2 · font (delegated to fonts.sh) ----
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_font)")
      dkind+=(font); did+=(font); dlabel+=("$UI_ARROW $(_nvim_t pick_font)")
      dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t font_tui_note)${UI_OFF}")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 3 · plugins ----
      local plugins extra_urls disabled
      plugins="$(_nvim_conf_get PLUGINS)"
      extra_urls="$(_nvim_extra_plugins | paste -sd' ' - || true)"
      disabled="$(_nvim_conf_get DISABLED_PLUGINS)"
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_plugins)")
      if [[ -z "$plugins$extra_urls" ]]; then
        dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t plugins_none)${UI_OFF}")
      else
        for w in $plugins $extra_urls; do
          dkind+=(plugin); did+=("$w"); dlabel+=("$(ui_badge installed) $w")
        done
      fi
      if [[ -n "$disabled" ]]; then
        dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t plugins_disabled_hd)${UI_OFF}")
        for w in $disabled; do
          dkind+=(disabled-plugin); did+=("$w"); dlabel+=("$(ui_badge off) $w")
        done
      fi
      dkind+=(add-plugin); did+=(add-plugin); dlabel+=("$UI_ARROW $(_nvim_t add_plugin)")
      dkind+=(disable-plugin); did+=(disable-plugin); dlabel+=("$UI_ARROW $(_nvim_t disable_plugin)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 4 · extras (lazyvim.json; nvim.conf EXTRAS mirrors what the kit enabled) ----
      local extras_on ex eb
      extras_on="$(_nvim_conf_get EXTRAS)"
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_extras)")
      for ex in $NVIM_EXTRAS_CURATED; do
        if _nvim_ui_has "$ex" "$extras_on"; then eb="$(ui_badge installed)"; else eb="$(ui_badge missing)"; fi
        dkind+=(extra); did+=("$ex"); dlabel+=("$eb $ex")
      done
      dkind+=(add-extra); did+=(add-extra); dlabel+=("$UI_ARROW $(_nvim_t add_extra)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 5/6/7/8 · leader / options / keymaps / autocmds ----
      local cfg_leader autoformat_off=0
      cfg_leader="$(_nvim_conf_get CFG_LEADER)"; [[ -n "$cfg_leader" ]] || cfg_leader="space"
      [[ "$(_nvim_conf_get AUTOFORMAT)" == off ]] && autoformat_off=1
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_config)")
      dkind+=(leader); did+=(leader); dlabel+=("  $(_nvim_t leader_label): ${UI_INFO}${cfg_leader}${UI_OFF}")
      # Options (curated shortlist; current value shown, blank when unset).
      dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t opts_hd)${UI_OFF}")
      local on oval
      for on in $NVIM_OPTION_CURATED; do
        oval="$(_nvim_conf_get "OPT_$on")"
        dkind+=(option); did+=("$on"); dlabel+=("    $(printf '%-15s' "$on") ${UI_INFO}${oval:-—}${UI_OFF}")
      done
      local afb; if (( autoformat_off )); then afb="$(ui_badge off)"; else afb="$(ui_badge on)"; fi
      dkind+=(autoformat); did+=(autoformat); dlabel+=("  $afb $(_nvim_t autoformat_label)")
      # Keymaps (added list; space-toggle removes).
      dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t keymaps_hd)${UI_OFF}")
      local km_any=0 kval kmode klhs
      if [[ -f "${_NV_PREF:-}" ]]; then
        while IFS='=' read -r _ kval; do
          IFS=$'\t' read -r kmode klhs _ _ <<<"$kval"
          [[ -n "$kmode" && -n "$klhs" ]] || continue
          km_any=1
          # did carries mode<TAB>lhs (lhs may contain spaces; split on TAB in the handler).
          dkind+=(keymap); did+=("$kmode"$'\t'"$klhs"); dlabel+=("    $(ui_badge installed) ${kmode}: ${klhs}")
        done < <(grep -E '^KEYMAP_[A-Za-z0-9_]+=' "$_NV_PREF" 2>/dev/null || true)
      fi
      (( km_any )) || { dkind+=(info); did+=(""); dlabel+=("    ${UI_MUTED}$(_nvim_t keymaps_none)${UI_OFF}"); }
      dkind+=(add-keymap); did+=(add-keymap); dlabel+=("  $UI_ARROW $(_nvim_t add_keymap)")
      # Autocmds (curated checklist; space-toggles add/remove).
      dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t autocmds_hd)${UI_OFF}")
      local ac acb
      for ac in $NVIM_AUTOCMD_ORDER; do
        if [[ "$(_nvim_conf_get "AUTOCMD_$ac")" == on ]]; then acb="$(ui_badge installed)"; else acb="$(ui_badge missing)"; fi
        dkind+=(autocmd); did+=("$ac"); dlabel+=("    $acb $ac ${UI_MUTED}${NVIM_AUTOCMD_DESC[$ac]}${UI_OFF}")
      done
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Domain 9 · Mason tools ----
      local mason mt
      mason="$(_nvim_conf_get MASON_TOOLS)"
      dkind+=(header); did+=(""); dlabel+=("$(_nvim_t sec_mason)")
      if [[ -z "$mason" ]]; then
        dkind+=(info); did+=(""); dlabel+=("  ${UI_MUTED}$(_nvim_t mason_none)${UI_OFF}")
      else
        for mt in $mason; do
          dkind+=(mason); did+=("$mt"); dlabel+=("  $(ui_badge installed) $mt")
        done
      fi
      dkind+=(add-mason); did+=(add-mason); dlabel+=("$UI_ARROW $(_nvim_t add_mason)")
      dkind+=(spacer); did+=(""); dlabel+=("")

      # ---- Actions ----
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_nvim_t apply_recommended)")
      dkind+=(reset);  did+=(reset);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_nvim_t reset_config)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_nvim_t remove_nvim)")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|info)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    # Viewport-window the row list so a menu taller than the terminal scrolls (the list spans
    # 9 domains and easily exceeds one screen). Mirrors ui_pick/ui_catalog: render only the slice
    # [top, top+avail) and shift `top` to keep the selected row visible — without this, rows past
    # the screen height pile onto the last line and the bottom domains are unreachable.
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Neovim + LazyVim" "$ver $(ui_badge installed)"
    else ui_header "Neovim + LazyVim" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row listrow=3 avail top=0
    avail=$(( UI_ROWS - listrow - 1 )); (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    row=$listrow
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        info)   ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    local foot; foot="$(_nvim_t foot_main)"
    (( top > 0 ))          && foot="↑ $foot"
    (( top + avail < n ))  && foot="$foot ↓"
    ui_footer "$foot"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|info) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            # Destructive when ~/.config/nvim is a non-empty, non-kit, non-LazyVim config: confirm
            # in the ui before _lazyvim_land backs it up + replaces (design's "ui二次确认"). When it
            # IS LazyVim (or empty/already-kit) install is non-destructive — proceed directly.
            if [[ -d "$_NV_NVIM_DIR" && -n "$(ls -A "$_NV_NVIM_DIR" 2>/dev/null || true)" ]] \
               && [[ -z "$(_lazyvim_marker_read)" ]] && ! _lazyvim_is_lazyvim; then
              ui_confirm "$(_nvim_t confirm_destructive_install)" n && ui_run "$(_nvim_t install_combo)" -- "$0" install
            else
              ui_run "$(_nvim_t install_combo)" -- "$0" install
            fi ;;
          update)      ui_run "$(_nvim_t update_nvim)" -- "$0" update ;;
          editor)
            if (( editor_on )); then ui_run "default editor off" -- "$0" set-default-editor off
            else ui_run "default editor on" -- "$0" set-default-editor; fi ;;
          deps)        ui_run "$(_nvim_t install_deps)" -- "$0" ensure-deps ;;
          color)
            local -a copts=() cc spec built mode
            for cc in $NVIM_THEME_ORDER; do
              spec="$(_nvim_theme_spec "$cc")"; if [[ -z "$spec" ]]; then built="built-in"; else built="plugin"; fi
              mode="$(_nvim_theme_mode "$cc")"
              copts+=("$cc" "$cc ($built${mode:+ · $mode})")
            done
            copts+=("__custom__" "$(_nvim_t custom_colorscheme)")
            copts+=("" "$(_nvim_t clear_colorscheme)")
            if ui_pick "$(_nvim_t pick_colorscheme)" "" "" -- "${copts[@]}"; then
              if [[ "$UI_PICK" == "__custom__" ]]; then
                if ui_input "$(_nvim_t prompt_colorscheme)" "" && [[ -n "$UI_INPUT" ]]; then
                  ui_run "set-colorscheme $UI_INPUT" -- "$0" set-colorscheme "$UI_INPUT"
                fi
              else
                ui_run "set-colorscheme ${UI_PICK:-clear}" -- "$0" set-colorscheme "$UI_PICK"
              fi
            fi ;;
          font)
            local -a fopts=() fk
            for fk in $NVIM_FONT_KEYS; do fopts+=("$fk" "$fk"); done
            if ui_pick "$(_nvim_t pick_font)" "" "" -- "${fopts[@]}"; then
              local fkey="$UI_PICK"
              if ui_input "$(_nvim_t prompt_font_size)" ""; then
                ui_run "set-font $fkey $UI_INPUT" -- "$0" set-font "$fkey" "$UI_INPUT"
              else
                ui_run "set-font $fkey" -- "$0" set-font "$fkey"
              fi
            fi ;;
          plugin)          ui_run "remove-plugin ${did[$sel]}" -- "$0" remove-plugin "${did[$sel]}" ;;
          disabled-plugin) ui_run "enable-plugin ${did[$sel]}" -- "$0" enable-plugin "${did[$sel]}" ;;
          add-plugin)
            if ui_input "$(_nvim_t prompt_plugin)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "add-plugin $UI_INPUT" -- "$0" add-plugin "$UI_INPUT"
            fi ;;
          disable-plugin)
            if ui_input "$(_nvim_t prompt_disable_plugin)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "disable-plugin $UI_INPUT" -- "$0" disable-plugin "$UI_INPUT"
            fi ;;
          extra)
            if _nvim_ui_has "${did[$sel]}" "$(_nvim_conf_get EXTRAS)"; then
              ui_run "extra-remove ${did[$sel]}" -- "$0" extra-remove "${did[$sel]}"
            else
              ui_run "extra-add ${did[$sel]}" -- "$0" extra-add "${did[$sel]}"
            fi ;;
          add-extra)
            if ui_input "$(_nvim_t prompt_extra)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "extra-add $UI_INPUT" -- "$0" extra-add "$UI_INPUT"
            fi ;;
          leader)
            if ui_input "$(_nvim_t prompt_leader)" "$cfg_leader" && [[ -n "$UI_INPUT" ]]; then
              ui_run "set-leader $UI_INPUT" -- "$0" set-leader "$UI_INPUT"
            fi ;;
          option)
            local optn="${did[$sel]}" optv
            optv="$(_nvim_conf_get "OPT_$optn")"
            # shellcheck disable=SC2059  # the i18n string is a trusted printf template with one %s
            if ui_input "$(printf "$(_nvim_t prompt_option_value)" "$optn")" "$optv"; then
              if [[ -n "$UI_INPUT" ]]; then ui_run "set-option $optn $UI_INPUT" -- "$0" set-option "$optn" "$UI_INPUT"
              else ui_run "unset-option $optn" -- "$0" unset-option "$optn"; fi
            fi ;;
          autoformat)
            if (( autoformat_off )); then ui_run "format-on-save on" -- "$0" set-option autoformat on
            else ui_run "format-on-save off" -- "$0" set-option autoformat off; fi ;;
          keymap)
            local kmmode2 kmlhs2
            IFS=$'\t' read -r kmmode2 kmlhs2 <<<"${did[$sel]}"
            ui_run "remove-keymap $kmmode2 $kmlhs2" -- "$0" remove-keymap "$kmmode2" "$kmlhs2" ;;
          add-keymap)
            if ui_input "$(_nvim_t prompt_km_mode)" "n" && [[ -n "$UI_INPUT" ]]; then
              local kmmode="$UI_INPUT"
              if ui_input "$(_nvim_t prompt_km_lhs)" "" && [[ -n "$UI_INPUT" ]]; then
                local kmlhs="$UI_INPUT"
                if ui_input "$(_nvim_t prompt_km_rhs)" "" && [[ -n "$UI_INPUT" ]]; then
                  local kmrhs="$UI_INPUT"
                  ui_input "$(_nvim_t prompt_km_desc)" "" || true
                  ui_run "add-keymap $kmmode $kmlhs" -- "$0" add-keymap "$kmmode" "$kmlhs" "$kmrhs" "$UI_INPUT"
                fi
              fi
            fi ;;
          autocmd)
            if [[ "$(_nvim_conf_get "AUTOCMD_${did[$sel]}")" == on ]]; then
              ui_run "remove-autocmd ${did[$sel]}" -- "$0" remove-autocmd "${did[$sel]}"
            else
              ui_run "add-autocmd ${did[$sel]}" -- "$0" add-autocmd "${did[$sel]}"
            fi ;;
          mason)     ui_run "mason-remove ${did[$sel]}" -- "$0" mason-remove "${did[$sel]}" ;;
          add-mason)
            if ui_input "$(_nvim_t prompt_mason)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "mason-add $UI_INPUT" -- "$0" mason-add "$UI_INPUT"
            fi ;;
          recommended) ui_run "$(_nvim_t apply_recommended)" -- "$0" configure --recommended ;;
          reset)       ui_confirm "$(_nvim_t confirm_reset)" n && ui_run "$(_nvim_t reset_config)" -- "$0" config-reset ;;
          remove)      ui_confirm "$(_nvim_t confirm_remove)" n && ui_run "$(_nvim_t remove_nvim)" -- "$0" remove ;;
        esac ;;
      q|Q|esc|backspace) break ;;
    esac
  done
  ui_end
  return 0
}

# _nvim_ui_has TOKEN LIST — true iff TOKEN is in the space-separated LIST (ui membership test).
_nvim_ui_has() {
  local tok="$1" list="$2" w
  for w in $list; do [[ "$w" == "$tok" ]] && return 0; done
  return 1
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

The nvim + LazyVim COMBO manager: a best-channel Neovim binary + LazyVim at ~/.config/nvim, with
full component config via LazyVim's own extension points (theme/font/plugins/extras/leader/keymaps/
options/autocmds/Mason).

Core commands:
  install                 Install the COMBO — binary (apt >= ${NVIM_MIN_VERSION}, else official stable
                            tarball into /opt, else snap) + deps + Nerd Font + LazyVim at
                            ~/.config/nvim + a headless plugin sync. Idempotent.
  remove [--purge]        Remove the binary; for a kit-cloned config, back up + delete ~/.config/nvim
                            (an adopted config is left alone). --purge also wipes LazyVim's
                            data/state/cache (cloned configs only).
  update                  Re-fetch + reinstall the latest stable tarball (apt/snap track the system)
  update-plugins          Drive LazyVim's lazy.nvim 'update' headless
  configure [opts]        No flags: converge (regenerate kit-managed products if the combo is
                            installed; else just point at install). Flags layer on:
                            --recommended         the full combo (= install + editor=on)
                            --editor on|off       set/unset nvim as EDITOR/VISUAL
                            --deps                install external deps only
                            --colorscheme <name>  set a colorscheme ("" clears)
                            --leader <char|space> set the leader key
                            --font <name>         install/apply a Nerd Font (via fonts.sh)

Settings (each writes a LazyVim file, then headless-syncs / regenerates; run AS YOU, never sudo):
  set-colorscheme <name>  Domain 1 — colorscheme (curated: ${NVIM_THEME_ORDER// /, }; "" clears).
  set-font <name> [size]  Domain 2 — Nerd Font via fonts.sh (curated: ${NVIM_FONT_KEYS// /, }).
  add-plugin <owner/repo|git-url>     Domain 3 — add a plugin to lua/plugins/ubuntu-setup.lua
  remove-plugin <owner/repo|...>      Domain 3 — remove an added plugin
  disable-plugin <owner/repo>         Domain 3 — disable a LazyVim plugin (enabled = false)
  enable-plugin <owner/repo>          Domain 3 — undo a disable
  extra-add <cat.name>    Domain 4 — enable a LazyVim extra in lazyvim.json (e.g. lang.go)
  extra-remove <cat.name> Domain 4 — disable an extra
  set-leader <char|space> Domain 5 — leader key (lua/config/options.lua managed block)
  set-option <name> <v>   Domain 7 — an option (on|off|int|word); name 'autoformat' = format-on-save
  unset-option <name>     Domain 7 — drop an option back to LazyVim's default
  add-keymap <mode> <lhs> <rhs> [desc]  Domain 6 — a keymap (lua/config/keymaps.lua block)
  remove-keymap <mode> <lhs>            Domain 6 — drop a keymap
  add-autocmd <name>      Domain 8 — enable a curated autocmd (lua/config/autocmds.lua block)
  remove-autocmd <name>   Domain 8 — disable a curated autocmd
  mason-add <tool>        Domain 9 — add a Mason ensure_installed tool
  mason-remove <tool>     Domain 9 — remove a Mason tool

Other:
  set-default-editor [off]   Set (or, with 'off', unset) nvim as EDITOR/VISUAL + system editor
  ensure-deps             Install external deps (git curl ripgrep fd-find fzf build-essential unzip
                            gzip + best-effort lazygit + a Nerd Font)
  config-show             Print the current kit-managed config state (read-only)
  config-reset            Remove the kit-managed config products + state (keeps timestamped backups)
  list-colorschemes / list-extras / list-options / list-autocmds   Print the curated shortlists
  status                  Print version + channel; exit code 0 iff the combo (nvim + LazyVim) is in
  ui                      Open the interactive manager (needs a terminal)
  meta                    Print machine-readable metadata
  help                    Show this help

Notes: every setting + the editor toggle run AS YOU (never sudo) — they touch your ~/.config/nvim,
~/.local and shell rc. Only the binary install/remove escalates per-command. Node is NEVER installed
automatically (Mason LSP servers that need it: swkit node install). Neovim is a TUI, so SSH works
perfectly; Nerd Font glyphs render in your LOCAL/client terminal.
EOF
}

kit_dispatch "$@"
