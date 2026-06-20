#!/usr/bin/env bash
#
# scripts/claude.sh — install / manage the Claude Code CLI on Ubuntu, as a COMPONENT MANAGER.
#
# Beyond installing the CLI, this script manages Claude Code's extension systems — MCP servers,
# plugins/marketplaces, and skills — each independently, by shelling out to the official
# `claude` CLI (MCP, plugins) or managing files under ~/.claude/skills (skills). The native CLI
# is the authoritative interface: it handles scopes and storage paths and survives format
# changes, so we prefer it over hand-editing ~/.claude.json / settings.json. It also manages
# Claude's default external editor (Ctrl+G): since Claude reads the standard $EDITOR/$VISUAL
# and exposes no editor setting of its own, that one axis writes env.EDITOR/env.VISUAL into
# ~/.claude/settings.json (Claude-scoped, via jq, with a backup) rather than the global shell.
#
# install / remove / status manage the CLI binary itself (official native installer by default,
# no Node required; an optional --method npm path for users who already run Node >= 18). This
# script NEVER installs or upgrades Node itself, and NEVER runs `sudo npm`.
#
# Extension actions (kit_dispatch routes <op> -> do_<op>, hyphens -> underscores). They are
# PARAMETRIC and driven by swkit / the LLM / the ui() screen, so they are NOT listed in meta
# ops= (which carries only the no-arg primary ops). Default scope for MCP/plugins is `user`
# (global, all projects) — the "set up my machine" case; pass --scope to override.
#   mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>   (curated names need no args)
#   mcp-remove <name>            ·  mcp-search <term>            (registry search; needs jq)
#   marketplace-add <owner/repo|url|path>  ·  marketplace-remove <name>
#   plugin-install <name@marketplace|curated-name>  ·  plugin-remove <name>
#   plugin-enable <name>         ·  plugin-disable <name>        (toggle without uninstalling)
#   skill-install <git-url|curated-name> [name] [subdir]  ·  skill-remove <name>
#   set-editor <curated-name|command>  ·  clear-editor    (Claude's Ctrl+G editor; settings.json)
#   set-effort <low|medium|high|xhigh|max>  ·  clear-effort   (Claude Code's /effort default; settings.json)
#
# All extension files live under the user's HOME and are written AS THE USER, never via sudo;
# extension actions refuse a sudo-wrapped run so ~/.claude stays user-owned.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly _CLAUDE_NPM_PKG="@anthropic-ai/claude-code"
readonly _CLAUDE_MIN_NODE_MAJOR=18

# --- Curated catalogs (the "curated" half of curated+live; arbitrary add is always allowed) ---
# Verified 2026-06-14: npm packages exist; all stdio servers use npx (Node), context7 is HTTP
# (no runtime). Deliberately Node-only (no uv/uvx) so curated quick-adds work with just Node.
readonly _CLAUDE_MCP_CURATED_KEYS="sequential-thinking filesystem memory playwright context7"
# Curated plugin marketplaces (verified 2026-06-14).
readonly _CLAUDE_MKT_CURATED="anthropics/claude-plugins-official anthropics/skills forrestchang/andrej-karpathy-skills"
# Curated plugins (the "curated" half; arbitrary name@marketplace add is always allowed).
# Each curated plugin bundles the marketplace it comes from, so a one-click install can add
# that marketplace first. Verified 2026-06-14.
readonly _CLAUDE_PLUGIN_CURATED_KEYS="andrej-karpathy-skills"
# Curated standalone skills, taken from the official anthropics/skills repo (subdir skills/<n>).
readonly _CLAUDE_SKILL_CURATED_KEYS="pdf docx pptx frontend-design mcp-builder"
# Skills the kit itself deploys to ~/.claude/skills — never let this manager delete them.
readonly _CLAUDE_SKILL_PROTECTED="ubuntu-install zsh-setup claude-extensions"
# Curated editors for the "default editor" axis. Claude Code's external editor (Ctrl+G)
# reads the standard $EDITOR/$VISUAL; this axis writes them into ~/.claude/settings.json's
# `env` block (Claude-scoped, not the global shell). GUI editors (code/cursor) carry --wait
# and emacs uses -nw so the editor BLOCKS until the edit is done — Claude waits on the
# process before reading the prompt back. Arbitrary commands are always allowed too.
readonly _CLAUDE_EDITOR_CURATED_KEYS="code cursor nvim vim nano micro emacs helix"
# Curated thinking-effort levels for the "default thinking effort" axis. Claude Code's
# /effort level is persisted as the top-level "effortLevel" in ~/.claude/settings.json, so a
# new session starts at this effort. The level names are Claude Code identifiers and stay
# UNtranslated; only the one-line gloss (effort_desc:*) is localized. The value is validated
# against this list before writing (an enum, unlike the free-form editor command) so junk /
# JSON injection is rejected. ("max" is offered but may not persist — see do_set_effort.)
readonly _CLAUDE_EFFORT_LEVELS="low medium high xhigh max"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local so the generic UI library stays free of
# Claude-specific text. Proper nouns stay UNtranslated: the software name, MCP/plugin/skill
# *names* (sequential-thinking, pdf, …), marketplace owner/repo (anthropics/skills),
# transports (stdio/http/sse), "native"/"npm", package/URL specs. Only descriptive and
# operational wording is localized — INCLUDING the one-line catalog descriptions (mcp_desc:*,
# mkt_desc:*, plugin_desc:*, skill_desc:*), which the curated helpers keep in English for the
# command specs but ui() renders from here. Resolve with _claude_t KEY (fallback en -> key).
declare -gA CLAUDE_I18N
# Section headers / rows / status tags / hints
CLAUDE_I18N[en:mcp_servers]="MCP servers"
CLAUDE_I18N[en:plugins_mkts]="Plugins & marketplaces"
CLAUDE_I18N[en:skills]="Skills"
CLAUDE_I18N[en:add_mcp]="add MCP server…"
CLAUDE_I18N[en:add_mkt]="add marketplace…"
CLAUDE_I18N[en:add_plugin]="install plugin…"
CLAUDE_I18N[en:add_skill]="add skill from git…"
CLAUDE_I18N[en:tag_configured]="configured"
CLAUDE_I18N[en:tag_enabled]="enabled"
CLAUDE_I18N[en:tag_disabled]="disabled"
CLAUDE_I18N[en:tag_kit]="kit"
CLAUDE_I18N[en:foot_main]="↑↓ move   ↵/space toggle/select   esc/q close"
CLAUDE_I18N[en:foot_plugin]="↑↓ move   ↵/space enable/disable   x uninstall   esc/q close"
CLAUDE_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
# Install-method picker
CLAUDE_I18N[en:pick_method]="Claude Code CLI — install method"
CLAUDE_I18N[en:method_native]="native (official installer, no Node)"
CLAUDE_I18N[en:method_npm]="npm (needs Node >= {N})"
# Confirms / notifies / prompts
CLAUDE_I18N[en:confirm_remove_cli]="Uninstall the Claude Code CLI?"
CLAUDE_I18N[en:confirm_remove_plugin]="Uninstall plugin '{X}'?"
CLAUDE_I18N[en:confirm_remove_mcp]="Remove MCP server '{X}'?"
CLAUDE_I18N[en:confirm_remove_mkt]="Remove marketplace '{X}'?"
CLAUDE_I18N[en:confirm_remove_skill]="Remove skill '{X}'? (a backup is saved first)"
CLAUDE_I18N[en:prompt_mcp_name]="MCP server name"
CLAUDE_I18N[en:pick_transport]="Transport for '{X}'"
CLAUDE_I18N[en:tr_stdio]="stdio (local command)"
CLAUDE_I18N[en:tr_http]="http (remote URL)"
CLAUDE_I18N[en:tr_sse]="sse (remote URL)"
CLAUDE_I18N[en:prompt_cmd]="command (e.g. npx -y some-mcp)"
CLAUDE_I18N[en:prompt_url]="server URL"
CLAUDE_I18N[en:prompt_mkt]="marketplace (owner/repo, git URL, or path)"
CLAUDE_I18N[en:prompt_plugin]="plugin (name@marketplace)"
CLAUDE_I18N[en:prompt_skill_url]="skill git URL"
CLAUDE_I18N[en:prompt_skill_name]="name (blank = derive)"
CLAUDE_I18N[en:prompt_skill_subdir]="subdir (blank = repo root)"
CLAUDE_I18N[en:skill_title]="Skill '{X}'"
CLAUDE_I18N[en:skill_protected]="This skill is deployed by the ubuntu-setup kit and is protected here."
# Curated catalog one-line descriptions (names stay untranslated; only the gloss is localized)
CLAUDE_I18N[en:mcp_desc:sequential-thinking]="Structured step-by-step reasoning"
CLAUDE_I18N[en:mcp_desc:filesystem]="Read/write files under your home"
CLAUDE_I18N[en:mcp_desc:memory]="Persistent knowledge-graph memory"
CLAUDE_I18N[en:mcp_desc:playwright]="Drive a real browser (Playwright)"
CLAUDE_I18N[en:mcp_desc:context7]="Up-to-date library / API docs"
CLAUDE_I18N[en:mkt_desc:anthropics/claude-plugins-official]="Official Anthropic plugins"
CLAUDE_I18N[en:mkt_desc:anthropics/skills]="Official Anthropic skills (as plugins)"
CLAUDE_I18N[en:mkt_desc:forrestchang/andrej-karpathy-skills]="Karpathy-inspired Claude Code guidelines"
CLAUDE_I18N[en:plugin_desc:andrej-karpathy-skills]="Karpathy-inspired coding guidelines (all projects)"
CLAUDE_I18N[en:skill_desc:pdf]="Fill, parse and generate PDFs"
CLAUDE_I18N[en:skill_desc:docx]="Create and edit Word documents"
CLAUDE_I18N[en:skill_desc:pptx]="Create and edit PowerPoint decks"
CLAUDE_I18N[en:skill_desc:frontend-design]="Produce polished web UIs"
CLAUDE_I18N[en:skill_desc:mcp-builder]="Scaffold new MCP servers"
# Default editor axis
CLAUDE_I18N[en:editor_section]="Default editor"
CLAUDE_I18N[en:editor_set_custom]="set custom editor…"
CLAUDE_I18N[en:editor_use_default]="clear (use shell \$EDITOR)"
CLAUDE_I18N[en:prompt_editor]="editor command (e.g. vim, nano, code --wait)"
CLAUDE_I18N[en:tag_not_installed]="not installed"
CLAUDE_I18N[en:editor_from_settings]="current: {X} (Claude settings)"
CLAUDE_I18N[en:editor_from_env]="current: {X} (shell \$EDITOR)"
CLAUDE_I18N[en:editor_unset]="not set (Claude falls back to your shell / system default)"
CLAUDE_I18N[en:confirm_clear_editor]="Clear Claude's default editor (fall back to your shell \$EDITOR)?"
CLAUDE_I18N[en:editor_need_install_t]="Editor '{X}' is not installed"
CLAUDE_I18N[en:editor_need_install]="Install '{X}' first (e.g. via apt or swkit), then set it here."
CLAUDE_I18N[en:editor_desc:code]="VS Code (waits for the tab to close)"
CLAUDE_I18N[en:editor_desc:cursor]="Cursor (waits for the tab to close)"
CLAUDE_I18N[en:editor_desc:nvim]="Neovim"
CLAUDE_I18N[en:editor_desc:vim]="Vi-compatible modal editor"
CLAUDE_I18N[en:editor_desc:nano]="Simple, always-available editor"
CLAUDE_I18N[en:editor_desc:micro]="Modern, easy terminal editor"
CLAUDE_I18N[en:editor_desc:emacs]="Emacs in the terminal"
CLAUDE_I18N[en:editor_desc:helix]="Helix (hx)"
# Default thinking-effort axis (Claude Code's /effort level)
CLAUDE_I18N[en:effort_section]="Default thinking effort"
CLAUDE_I18N[en:effort_use_default]="clear (use model default)"
CLAUDE_I18N[en:effort_current]="current: {X}"
CLAUDE_I18N[en:effort_unset]="not set (Claude uses each model's default)"
CLAUDE_I18N[en:confirm_clear_effort]="Clear Claude Code's default thinking effort (fall back to each model's default)?"
CLAUDE_I18N[en:effort_desc:low]="Fast & cheap; short, scoped, latency-sensitive tasks"
CLAUDE_I18N[en:effort_desc:medium]="Lower token use for cost-sensitive work"
CLAUDE_I18N[en:effort_desc:high]="Balanced; the default on most models"
CLAUDE_I18N[en:effort_desc:xhigh]="Deeper reasoning at higher token spend (Opus)"
CLAUDE_I18N[en:effort_desc:max]="Maximum capability; may overthink — test first"

CLAUDE_I18N[zh:mcp_servers]="MCP 服务器"
CLAUDE_I18N[zh:plugins_mkts]="插件与市场"
CLAUDE_I18N[zh:skills]="Skills"
CLAUDE_I18N[zh:add_mcp]="添加 MCP 服务器…"
CLAUDE_I18N[zh:add_mkt]="添加市场…"
CLAUDE_I18N[zh:add_plugin]="安装插件…"
CLAUDE_I18N[zh:add_skill]="从 git 添加 skill…"
CLAUDE_I18N[zh:tag_configured]="已配置"
CLAUDE_I18N[zh:tag_enabled]="已启用"
CLAUDE_I18N[zh:tag_disabled]="已禁用"
CLAUDE_I18N[zh:tag_kit]="kit"
CLAUDE_I18N[zh:foot_main]="↑↓ 移动   ↵/space 切换/选择   esc/q 关闭"
CLAUDE_I18N[zh:foot_plugin]="↑↓ 移动   ↵/space 启用/禁用   x 卸载   esc/q 关闭"
CLAUDE_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
CLAUDE_I18N[zh:pick_method]="Claude Code CLI — 安装方式"
CLAUDE_I18N[zh:method_native]="native(官方安装器,无需 Node)"
CLAUDE_I18N[zh:method_npm]="npm(需 Node >= {N})"
CLAUDE_I18N[zh:confirm_remove_cli]="卸载 Claude Code CLI?"
CLAUDE_I18N[zh:confirm_remove_plugin]="卸载插件 '{X}'?"
CLAUDE_I18N[zh:confirm_remove_mcp]="移除 MCP 服务器 '{X}'?"
CLAUDE_I18N[zh:confirm_remove_mkt]="移除市场 '{X}'?"
CLAUDE_I18N[zh:confirm_remove_skill]="移除 skill '{X}'?(会先备份)"
CLAUDE_I18N[zh:prompt_mcp_name]="MCP 服务器名"
CLAUDE_I18N[zh:pick_transport]="'{X}' 的传输方式"
CLAUDE_I18N[zh:tr_stdio]="stdio(本地命令)"
CLAUDE_I18N[zh:tr_http]="http(远程 URL)"
CLAUDE_I18N[zh:tr_sse]="sse(远程 URL)"
CLAUDE_I18N[zh:prompt_cmd]="命令(如 npx -y some-mcp)"
CLAUDE_I18N[zh:prompt_url]="服务器 URL"
CLAUDE_I18N[zh:prompt_mkt]="市场(owner/repo、git URL 或路径)"
CLAUDE_I18N[zh:prompt_plugin]="插件(name@marketplace)"
CLAUDE_I18N[zh:prompt_skill_url]="skill 的 git URL"
CLAUDE_I18N[zh:prompt_skill_name]="名称(留空=自动推导)"
CLAUDE_I18N[zh:prompt_skill_subdir]="子目录(留空=仓库根)"
CLAUDE_I18N[zh:skill_title]="Skill '{X}'"
CLAUDE_I18N[zh:skill_protected]="此 skill 由 ubuntu-setup kit 部署,在此受保护。"
CLAUDE_I18N[zh:mcp_desc:sequential-thinking]="结构化的逐步推理"
CLAUDE_I18N[zh:mcp_desc:filesystem]="读写你 home 下的文件"
CLAUDE_I18N[zh:mcp_desc:memory]="持久化的知识图谱记忆"
CLAUDE_I18N[zh:mcp_desc:playwright]="驱动真实浏览器(Playwright)"
CLAUDE_I18N[zh:mcp_desc:context7]="最新的库 / API 文档"
CLAUDE_I18N[zh:mkt_desc:anthropics/claude-plugins-official]="Anthropic 官方插件"
CLAUDE_I18N[zh:mkt_desc:anthropics/skills]="Anthropic 官方 skills(作为插件)"
CLAUDE_I18N[zh:mkt_desc:forrestchang/andrej-karpathy-skills]="Karpathy 风格的 Claude Code 准则"
CLAUDE_I18N[zh:plugin_desc:andrej-karpathy-skills]="Karpathy 风格的编码准则(所有项目)"
CLAUDE_I18N[zh:skill_desc:pdf]="填写、解析与生成 PDF"
CLAUDE_I18N[zh:skill_desc:docx]="创建与编辑 Word 文档"
CLAUDE_I18N[zh:skill_desc:pptx]="创建与编辑 PowerPoint 演示文稿"
CLAUDE_I18N[zh:skill_desc:frontend-design]="制作精致的网页 UI"
CLAUDE_I18N[zh:skill_desc:mcp-builder]="脚手架式生成新的 MCP 服务器"
# Default editor axis
CLAUDE_I18N[zh:editor_section]="默认编辑器"
CLAUDE_I18N[zh:editor_set_custom]="设置自定义编辑器…"
CLAUDE_I18N[zh:editor_use_default]="清除(用 shell \$EDITOR)"
CLAUDE_I18N[zh:prompt_editor]="编辑器命令(如 vim、nano、code --wait)"
CLAUDE_I18N[zh:tag_not_installed]="未安装"
CLAUDE_I18N[zh:editor_from_settings]="当前:{X}(Claude 设置)"
CLAUDE_I18N[zh:editor_from_env]="当前:{X}(shell \$EDITOR)"
CLAUDE_I18N[zh:editor_unset]="未设置(Claude 回退到 shell / 系统默认)"
CLAUDE_I18N[zh:confirm_clear_editor]="清除 Claude 的默认编辑器(回退到 shell \$EDITOR)?"
CLAUDE_I18N[zh:editor_need_install_t]="编辑器 '{X}' 未安装"
CLAUDE_I18N[zh:editor_need_install]="请先安装 '{X}'(如经 apt 或 swkit),再在此设置。"
CLAUDE_I18N[zh:editor_desc:code]="VS Code(等待标签页关闭)"
CLAUDE_I18N[zh:editor_desc:cursor]="Cursor(等待标签页关闭)"
CLAUDE_I18N[zh:editor_desc:nvim]="Neovim"
CLAUDE_I18N[zh:editor_desc:vim]="Vi 兼容的模式编辑器"
CLAUDE_I18N[zh:editor_desc:nano]="简单、几乎总是可用"
CLAUDE_I18N[zh:editor_desc:micro]="现代、易用的终端编辑器"
CLAUDE_I18N[zh:editor_desc:emacs]="终端里的 Emacs"
CLAUDE_I18N[zh:editor_desc:helix]="Helix(hx)"
# Default thinking-effort axis
CLAUDE_I18N[zh:effort_section]="默认思考级别"
CLAUDE_I18N[zh:effort_use_default]="清除(用模型默认)"
CLAUDE_I18N[zh:effort_current]="当前:{X}"
CLAUDE_I18N[zh:effort_unset]="未设置(Claude 用每个模型的默认级别)"
CLAUDE_I18N[zh:confirm_clear_effort]="清除 Claude Code 的默认思考级别(回退到每个模型的默认)?"
CLAUDE_I18N[zh:effort_desc:low]="快且省;短小、有界、对延迟敏感的任务"
CLAUDE_I18N[zh:effort_desc:medium]="降低 token 用量,适合成本敏感的工作"
CLAUDE_I18N[zh:effort_desc:high]="均衡;多数模型的默认"
CLAUDE_I18N[zh:effort_desc:xhigh]="更深推理、更高 token 开销(Opus)"
CLAUDE_I18N[zh:effort_desc:max]="最大能力;可能过度思考——先测试"

CLAUDE_I18N[ja:mcp_servers]="MCP サーバー"
CLAUDE_I18N[ja:plugins_mkts]="プラグインとマーケットプレイス"
CLAUDE_I18N[ja:skills]="Skills"
CLAUDE_I18N[ja:add_mcp]="MCP サーバーを追加…"
CLAUDE_I18N[ja:add_mkt]="マーケットプレイスを追加…"
CLAUDE_I18N[ja:add_plugin]="プラグインをインストール…"
CLAUDE_I18N[ja:add_skill]="git から skill を追加…"
CLAUDE_I18N[ja:tag_configured]="設定済み"
CLAUDE_I18N[ja:tag_enabled]="有効"
CLAUDE_I18N[ja:tag_disabled]="無効"
CLAUDE_I18N[ja:tag_kit]="kit"
CLAUDE_I18N[ja:foot_main]="↑↓ 移動   ↵/space 切替/選択   esc/q 閉じる"
CLAUDE_I18N[ja:foot_plugin]="↑↓ 移動   ↵/space 有効/無効   x アンインストール   esc/q 閉じる"
CLAUDE_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
CLAUDE_I18N[ja:pick_method]="Claude Code CLI — インストール方法"
CLAUDE_I18N[ja:method_native]="native(公式インストーラー、Node 不要)"
CLAUDE_I18N[ja:method_npm]="npm(Node >= {N} が必要)"
CLAUDE_I18N[ja:confirm_remove_cli]="Claude Code CLI をアンインストールしますか?"
CLAUDE_I18N[ja:confirm_remove_plugin]="プラグイン '{X}' をアンインストールしますか?"
CLAUDE_I18N[ja:confirm_remove_mcp]="MCP サーバー '{X}' を削除しますか?"
CLAUDE_I18N[ja:confirm_remove_mkt]="マーケットプレイス '{X}' を削除しますか?"
CLAUDE_I18N[ja:confirm_remove_skill]="skill '{X}' を削除しますか?(先にバックアップを保存)"
CLAUDE_I18N[ja:prompt_mcp_name]="MCP サーバー名"
CLAUDE_I18N[ja:pick_transport]="'{X}' のトランスポート"
CLAUDE_I18N[ja:tr_stdio]="stdio(ローカルコマンド)"
CLAUDE_I18N[ja:tr_http]="http(リモート URL)"
CLAUDE_I18N[ja:tr_sse]="sse(リモート URL)"
CLAUDE_I18N[ja:prompt_cmd]="コマンド(例 npx -y some-mcp)"
CLAUDE_I18N[ja:prompt_url]="サーバー URL"
CLAUDE_I18N[ja:prompt_mkt]="マーケットプレイス(owner/repo、git URL、またはパス)"
CLAUDE_I18N[ja:prompt_plugin]="プラグイン(name@marketplace)"
CLAUDE_I18N[ja:prompt_skill_url]="skill の git URL"
CLAUDE_I18N[ja:prompt_skill_name]="名前(空=自動導出)"
CLAUDE_I18N[ja:prompt_skill_subdir]="サブディレクトリ(空=リポジトリのルート)"
CLAUDE_I18N[ja:skill_title]="Skill '{X}'"
CLAUDE_I18N[ja:skill_protected]="この skill は ubuntu-setup kit によって配置され、ここでは保護されています。"
CLAUDE_I18N[ja:mcp_desc:sequential-thinking]="構造化された段階的な推論"
CLAUDE_I18N[ja:mcp_desc:filesystem]="ホーム配下のファイルを読み書き"
CLAUDE_I18N[ja:mcp_desc:memory]="永続的なナレッジグラフのメモリ"
CLAUDE_I18N[ja:mcp_desc:playwright]="実ブラウザを操作(Playwright)"
CLAUDE_I18N[ja:mcp_desc:context7]="最新のライブラリ / API ドキュメント"
CLAUDE_I18N[ja:mkt_desc:anthropics/claude-plugins-official]="Anthropic 公式プラグイン"
CLAUDE_I18N[ja:mkt_desc:anthropics/skills]="Anthropic 公式 skills(プラグインとして)"
CLAUDE_I18N[ja:mkt_desc:forrestchang/andrej-karpathy-skills]="Karpathy 風の Claude Code ガイドライン"
CLAUDE_I18N[ja:plugin_desc:andrej-karpathy-skills]="Karpathy 風のコーディングガイドライン(全プロジェクト)"
CLAUDE_I18N[ja:skill_desc:pdf]="PDF の記入・解析・生成"
CLAUDE_I18N[ja:skill_desc:docx]="Word 文書の作成と編集"
CLAUDE_I18N[ja:skill_desc:pptx]="PowerPoint の作成と編集"
CLAUDE_I18N[ja:skill_desc:frontend-design]="洗練された Web UI を作成"
CLAUDE_I18N[ja:skill_desc:mcp-builder]="新しい MCP サーバーを scaffold"
# Default editor axis
CLAUDE_I18N[ja:editor_section]="デフォルトエディタ"
CLAUDE_I18N[ja:editor_set_custom]="カスタムエディタを設定…"
CLAUDE_I18N[ja:editor_use_default]="クリア(shell の \$EDITOR を使用)"
CLAUDE_I18N[ja:prompt_editor]="エディタコマンド(例: vim, nano, code --wait)"
CLAUDE_I18N[ja:tag_not_installed]="未インストール"
CLAUDE_I18N[ja:editor_from_settings]="現在: {X}(Claude 設定)"
CLAUDE_I18N[ja:editor_from_env]="現在: {X}(shell の \$EDITOR)"
CLAUDE_I18N[ja:editor_unset]="未設定(Claude は shell / システム既定にフォールバック)"
CLAUDE_I18N[ja:confirm_clear_editor]="Claude のデフォルトエディタをクリアしますか(shell の \$EDITOR にフォールバック)?"
CLAUDE_I18N[ja:editor_need_install_t]="エディタ '{X}' は未インストール"
CLAUDE_I18N[ja:editor_need_install]="先に '{X}' をインストール(apt や swkit など)してから設定してください。"
CLAUDE_I18N[ja:editor_desc:code]="VS Code(タブが閉じるまで待機)"
CLAUDE_I18N[ja:editor_desc:cursor]="Cursor(タブが閉じるまで待機)"
CLAUDE_I18N[ja:editor_desc:nvim]="Neovim"
CLAUDE_I18N[ja:editor_desc:vim]="Vi 互換のモーダルエディタ"
CLAUDE_I18N[ja:editor_desc:nano]="シンプルでほぼ常に利用可能"
CLAUDE_I18N[ja:editor_desc:micro]="モダンで使いやすい端末エディタ"
CLAUDE_I18N[ja:editor_desc:emacs]="端末内の Emacs"
CLAUDE_I18N[ja:editor_desc:helix]="Helix(hx)"
# Default thinking-effort axis
CLAUDE_I18N[ja:effort_section]="デフォルト思考レベル"
CLAUDE_I18N[ja:effort_use_default]="クリア(モデル既定を使用)"
CLAUDE_I18N[ja:effort_current]="現在: {X}"
CLAUDE_I18N[ja:effort_unset]="未設定(各モデルの既定を使用)"
CLAUDE_I18N[ja:confirm_clear_effort]="Claude Code のデフォルト思考レベルをクリアしますか(各モデルの既定にフォールバック)?"
CLAUDE_I18N[ja:effort_desc:low]="高速・低コスト;短く限定的でレイテンシ重視のタスク"
CLAUDE_I18N[ja:effort_desc:medium]="コスト重視の作業向けにトークン使用量を削減"
CLAUDE_I18N[ja:effort_desc:high]="バランス型;多くのモデルの既定"
CLAUDE_I18N[ja:effort_desc:xhigh]="より深い推論、トークン消費は増加(Opus)"
CLAUDE_I18N[ja:effort_desc:max]="最大能力;考えすぎる場合あり — 先にテストを"

# _claude_t KEY — localized Claude string for $UI_LANG (en/zh/ja), fallback en -> key.
_claude_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${CLAUDE_I18N[$lang:$1]:-${CLAUDE_I18N[en:$1]:-$1}}"
}

# _claude_tx KEY TOKEN VALUE — like _claude_t but substitutes the {TOKEN} placeholder with
# VALUE (kept out of printf to stay SC2059-clean). Used for confirms/titles that embed a name.
_claude_tx() {
  local s; s="$(_claude_t "$1")"
  printf '%s' "${s//\{$2\}/$3}"
}

meta() {
  cat <<'META'
key=claude
name=Claude Code CLI
category=ai
ops=install,remove
desc=Claude Code CLI + extension manager (MCP servers, plugins/marketplaces, skills)
META
}

status() { have_cmd claude && claude --version; }

# ===============================================================================
# The CLI binary: install / remove (unchanged behavior)
# ===============================================================================

do_install() {
  local method="native"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method)
        method="${2:-}"
        shift 2 || { log_err "--method needs a value (native|npm)."; return 2; }
        ;;
      --method=*) method="${1#--method=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done

  if status >/dev/null 2>&1; then
    log_info "Claude Code CLI already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi

  case "$method" in
    native) _claude_install_native ;;
    npm)    _claude_install_npm ;;
    *) log_err "Unknown --method '$method' (expected: native|npm)."; return 2 ;;
  esac
}

# Official native installer: no Node dependency. Drops the binary in ~/.local/bin.
_claude_install_native() {
  have_cmd curl || apt_install curl ca-certificates
  pkg_installed ca-certificates || apt_install ca-certificates
  log_info "Installing Claude Code CLI via the official native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
  ensure_local_bin_on_path
}

# Optional npm path — only for users who already run a recent Node. We refuse to touch
# Node ourselves, and we never `sudo npm` (npm_ensure_user_prefix establishes a user-writable
# prefix in ~/.npm-global — no sudo — or refuses a custom unwritable one).
_claude_install_npm() {
  local node_major
  if ! have_cmd node || ! have_cmd npm; then
    log_err "Node.js and npm are required for --method npm, but were not found."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  node_major="$(node --version 2>/dev/null)"
  node_major="${node_major#v}"
  node_major="${node_major%%.*}"
  if [[ ! "$node_major" =~ ^[0-9]+$ ]] || (( node_major < _CLAUDE_MIN_NODE_MAJOR )); then
    log_err "Node major version >= ${_CLAUDE_MIN_NODE_MAJOR} is required for --method npm (found: $(node --version 2>/dev/null || echo none))."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  npm_ensure_user_prefix || return 1
  log_info "Installing $_CLAUDE_NPM_PKG via npm (user-space global)..."
  npm install -g "$_CLAUDE_NPM_PKG"
  ensure_npm_global_bin_on_path
}

# Best-effort removal: never sudo. The official native installer has no documented
# uninstall, so we conservatively remove the npm global (if present) and the dropped
# binary, then tell the user what may remain.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Claude Code CLI is not installed — nothing to remove."
    return 0
  fi

  if have_cmd npm && npm ls -g --depth 0 "$_CLAUDE_NPM_PKG" >/dev/null 2>&1; then
    log_info "Removing $_CLAUDE_NPM_PKG via npm..."
    npm uninstall -g "$_CLAUDE_NPM_PKG" || log_warn "npm uninstall of $_CLAUDE_NPM_PKG failed."
  fi

  if [[ -e "$HOME/.local/bin/claude" ]]; then
    rm -f "$HOME/.local/bin/claude"
  fi

  if have_cmd claude; then
    log_warn "'claude' is still on PATH after removal — it may have been installed by another method or location."
  else
    log_info "Claude Code CLI removed; some data under ~/.config or ~/.local/share may remain — delete it manually for a full cleanup."
  fi
}

# ===============================================================================
# Shared extension-management helpers
# ===============================================================================

# Gate: extension actions need the CLI present. Returns non-zero so callers `|| return 0`.
_claude_gate() {
  status >/dev/null 2>&1 && return 0
  log_info "Claude Code is not installed yet — run 'swkit claude install' first."
  return 1
}

# Resolve the user's HOME / skills dir, refusing a sudo-wrapped run (so ~/.claude stays
# user-owned — same contract as zsh.sh). Sets globals _CHOME / _CSKILLS.
_claude_user_paths() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run Claude Code extension management as your normal user, not via sudo —"
    log_err "it writes ~/.claude, which must stay user-owned."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _CHOME="${HOME:-}"
  [[ -n "$_CHOME" ]] || _CHOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_CHOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _CSKILLS="$_CHOME/.claude/skills"
}

# ===============================================================================
# Axis 1 — MCP servers (claude mcp …; default --scope user)
# ===============================================================================

# Curated MCP server definition: key -> "transport<TAB>spec<TAB>runtime<TAB>description"
# (spec is the full stdio command, or the URL for http). Returns non-zero for unknown keys.
_claude_mcp_curated() {
  local home="${_CHOME:-$HOME}"
  case "$1" in
    sequential-thinking) printf 'stdio\tnpx -y @modelcontextprotocol/server-sequential-thinking\tNode\tStructured step-by-step reasoning' ;;
    filesystem)          printf 'stdio\tnpx -y @modelcontextprotocol/server-filesystem %s\tNode\tRead/write files under your home' "$home" ;;
    memory)              printf 'stdio\tnpx -y @modelcontextprotocol/server-memory\tNode\tPersistent knowledge-graph memory' ;;
    playwright)          printf 'stdio\tnpx -y @playwright/mcp@latest\tNode\tDrive a real browser (Playwright)' ;;
    context7)            printf 'http\thttps://mcp.context7.com/mcp\t-\tUp-to-date library / API docs' ;;
    *) return 1 ;;
  esac
}

# Exit 0 iff an MCP server named $1 is configured (fast for the common not-present case).
_claude_mcp_present() { claude mcp get "$1" >/dev/null 2>&1; }

# Names of currently configured MCP servers (one per line). Parses `claude mcp list`
# (lines "name: cmd|url - status"; the name is everything before the single ": ").
_claude_mcp_configured_names() {
  claude mcp list 2>/dev/null | sed -n 's/^\(..*\): .* - .*$/\1/p'
}

# Add a curated server by key (idempotent).
_claude_mcp_add_curated() {
  local key="$1" def transport spec
  def="$(_claude_mcp_curated "$key")" || { log_err "Unknown curated MCP server '$key'."; return 2; }
  IFS=$'\t' read -r transport spec _ _ <<<"$def"
  if _claude_mcp_present "$key"; then
    log_info "MCP server '$key' already configured — skipping."
    return 0
  fi
  if [[ "$transport" == stdio && "$spec" == npx* ]] && ! have_cmd node; then
    log_warn "'$key' runs via Node (npx) but Node was not found — install it first: swkit node install"
  fi
  log_info "Adding curated MCP server '$key' ($transport) at user scope…"
  if [[ "$transport" == stdio ]]; then
    local -a cmd; read -r -a cmd <<<"$spec"
    claude mcp add --scope user "$key" -- "${cmd[@]}"
  else
    claude mcp add --transport "$transport" --scope user "$key" "$spec"
  fi
}

_claude_mcp_usage() {
  log_err "Usage: claude mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>"
  log_err "       claude mcp-add <curated-name>            (no other args needed)"
  log_err "Curated MCP servers: $_CLAUDE_MCP_CURATED_KEYS"
}

do_mcp_add() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  if [[ -z "$name" ]]; then _claude_mcp_usage; return 2; fi
  shift
  # Curated shortcut: `mcp-add <curated-name>` with no further args.
  if [[ $# -eq 0 ]] && _claude_mcp_curated "$name" >/dev/null 2>&1; then
    _claude_mcp_add_curated "$name"; return $?
  fi
  local transport="stdio" scope="user"
  local -a envs=() rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--transport)     transport="${2:-}"; shift 2 || { log_err "--transport needs a value."; return 2; } ;;
      -t=*|--transport=*) transport="${1#*=}"; shift ;;
      -s|--scope)         scope="${2:-}"; shift 2 || { log_err "--scope needs a value."; return 2; } ;;
      -s=*|--scope=*)     scope="${1#*=}"; shift ;;
      -e|--env)           envs+=(-e "${2:-}"); shift 2 || { log_err "--env needs K=V."; return 2; } ;;
      -e=*|--env=*)       envs+=(-e "${1#*=}"); shift ;;
      --)                 shift; rest=("$@"); break ;;
      *) log_err "Unexpected argument '$1' — put the command/URL after a literal --."; _claude_mcp_usage; return 2 ;;
    esac
  done
  case "$transport" in stdio|http|sse) ;; *) log_err "--transport must be stdio|http|sse."; return 2 ;; esac
  case "$scope" in local|user|project) ;; *) log_err "--scope must be local|user|project."; return 2 ;; esac
  if [[ ${#rest[@]} -eq 0 ]]; then log_err "Missing command/URL after --."; _claude_mcp_usage; return 2; fi
  if _claude_mcp_present "$name"; then
    log_info "MCP server '$name' already configured — skipping."
    return 0
  fi
  log_info "Adding MCP server '$name' ($transport, scope=$scope)…"
  if [[ "$transport" == stdio ]]; then
    claude mcp add --scope "$scope" "${envs[@]}" "$name" -- "${rest[@]}"
  else
    claude mcp add --transport "$transport" --scope "$scope" "${envs[@]}" "$name" "${rest[0]}"
  fi
}

do_mcp_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude mcp-remove <name>"; return 2; }
  if ! _claude_mcp_present "$name"; then
    log_info "MCP server '$name' is not configured — nothing to remove."
    return 0
  fi
  log_info "Removing MCP server '$name'…"
  claude mcp remove "$name"
}

# Optional live discovery against the official MCP registry (needs jq).
do_mcp_search() {
  local term="${1:-}"
  [[ -n "$term" ]] || { log_err "Usage: claude mcp-search <term>"; return 2; }
  have_cmd curl || { log_err "curl is required for mcp-search."; return 1; }
  if ! have_cmd jq; then
    log_warn "jq not found — registry results need jq to parse."
    log_warn "Install jq, or browse https://registry.modelcontextprotocol.io / https://mcp.so"
    return 1
  fi
  local q="${term// /%20}"
  log_info "Searching the official MCP registry for '$term'…"
  if ! curl -fsS "https://registry.modelcontextprotocol.io/v0/servers?limit=25&search=$q" 2>/dev/null \
       | jq -r '.servers[]? | "  \(.name)  —  \(.description // "")"'; then
    log_err "Registry query failed (network?)."
    return 1
  fi
  log_info "Add one with: swkit claude mcp-add <name> -t <stdio|http> -- <command|url>"
}

# ===============================================================================
# Axis 2 — Plugins & marketplaces (claude plugin …; default --scope user)
# ===============================================================================

_claude_mkt_desc() {
  case "$1" in
    anthropics/claude-plugins-official)  printf 'Official Anthropic plugins' ;;
    anthropics/skills)                   printf 'Official Anthropic skills (as plugins)' ;;
    forrestchang/andrej-karpathy-skills) printf 'Karpathy-inspired Claude Code guidelines' ;;
    *) printf '' ;;
  esac
}

# Curated plugin: key -> "plugin-spec<TAB>marketplace-repo<TAB>description". The spec is the
# full <name@marketplace>; the repo is the marketplace to add as a prerequisite. Returns
# non-zero for unknown keys.
_claude_plugin_curated() {
  case "$1" in
    andrej-karpathy-skills) printf 'andrej-karpathy-skills@karpathy-skills\tforrestchang/andrej-karpathy-skills\tKarpathy-inspired coding guidelines (all projects)' ;;
    *) return 1 ;;
  esac
}

# Exit 0 iff a marketplace whose source contains $1 (owner/repo or name) is configured.
_claude_marketplace_present() { claude plugin marketplace list 2>/dev/null | grep -qiF -- "$1"; }

# Resolve the configured marketplace NAME whose Source line contains repo $1 (for removal).
_claude_marketplace_name_for() {
  claude plugin marketplace list 2>/dev/null | awk -v repo="$1" '
    /Source:/ { if (index($0, repo)) { print name; exit } ; next }
    {
      n=$0; sub(/^[^A-Za-z0-9]*/, "", n); sub(/[[:space:]]*$/, "", n)
      if (n != "" && n !~ /:/ && n !~ /[[:space:]]/) name=n
    }'
}

# Emit "id<TAB>enabled(0/1)" for installed plugins (parses --json; jq-free, stable fields).
_claude_plugins_state() {
  claude plugin list --json 2>/dev/null | awk -F'"' '
    /"id":/      { id=$4; have=1 }
    /"enabled":/ { if (have) { printf "%s\t%d\n", id, ($0 ~ /true/) ? 1 : 0; have=0 } }'
}

# Exit 0 iff a plugin matching $1 (name or name@marketplace) is installed.
_claude_plugin_installed() {
  local spec="$1" name="${1%@*}"
  _claude_plugins_state | awk -F'\t' -v s="$spec" -v n="$name" \
    'BEGIN{f=1} $1==s || index($1, n "@")==1 {f=0} END{exit f}'
}

do_marketplace_add() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    log_err "Usage: claude marketplace-add <owner/repo|git-url|path>"
    log_err "Curated: $_CLAUDE_MKT_CURATED"
    return 2
  fi
  if _claude_marketplace_present "$src"; then
    log_info "Marketplace '$src' already configured — skipping."
    return 0
  fi
  log_info "Adding plugin marketplace '$src'…"
  claude plugin marketplace add "$src"
}

do_marketplace_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude marketplace-remove <name>"; return 2; }
  log_info "Removing plugin marketplace '$name'…"
  claude plugin marketplace remove "$name"
}

# Install a curated plugin by key (idempotent), adding its bundled marketplace first if needed.
_claude_plugin_add_curated() {
  local key="$1" def spec repo
  def="$(_claude_plugin_curated "$key")" || { log_err "Unknown curated plugin '$key'."; return 2; }
  IFS=$'\t' read -r spec repo _ <<<"$def"
  if _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' already installed — skipping."
    return 0
  fi
  if [[ -n "$repo" ]] && ! _claude_marketplace_present "$repo"; then
    log_info "Adding plugin marketplace '$repo' (needed by '$key')…"
    claude plugin marketplace add "$repo"
  fi
  log_info "Installing plugin '$spec' at user scope…"
  claude plugin install --scope user "$spec"
}

do_plugin_install() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local spec="${1:-}"
  if [[ -z "$spec" ]]; then
    log_err "Usage: claude plugin-install <name@marketplace|curated-name>"
    log_err "Curated plugins: $_CLAUDE_PLUGIN_CURATED_KEYS"
    return 2
  fi
  # Curated shortcut: a bare curated name (no @marketplace) installs from its bundled marketplace.
  if [[ "$spec" != *@* ]] && _claude_plugin_curated "$spec" >/dev/null 2>&1; then
    _claude_plugin_add_curated "$spec"; return $?
  fi
  if _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' already installed — skipping."
    return 0
  fi
  log_info "Installing plugin '$spec' at user scope…"
  claude plugin install --scope user "$spec"
}

do_plugin_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local spec="${1:-}"
  [[ -n "$spec" ]] || { log_err "Usage: claude plugin-remove <name>"; return 2; }
  if ! _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' is not installed — nothing to remove."
    return 0
  fi
  log_info "Uninstalling plugin '$spec'…"
  claude plugin uninstall "$spec"
}

do_plugin_enable() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local p="${1:-}"; [[ -n "$p" ]] || { log_err "Usage: claude plugin-enable <name>"; return 2; }
  log_info "Enabling plugin '$p'…"
  claude plugin enable "$p"
}

do_plugin_disable() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local p="${1:-}"; [[ -n "$p" ]] || { log_err "Usage: claude plugin-disable <name>"; return 2; }
  log_info "Disabling plugin '$p'…"
  claude plugin disable "$p"
}

# ===============================================================================
# Axis 3 — Skills (file-based: ~/.claude/skills/<name>/SKILL.md)
# ===============================================================================

# Curated standalone skill: key -> "repo<TAB>subdir<TAB>description".
_claude_skill_curated() {
  case "$1" in
    pdf)             printf 'https://github.com/anthropics/skills\tskills/pdf\tFill, parse and generate PDFs' ;;
    docx)            printf 'https://github.com/anthropics/skills\tskills/docx\tCreate and edit Word documents' ;;
    pptx)            printf 'https://github.com/anthropics/skills\tskills/pptx\tCreate and edit PowerPoint decks' ;;
    frontend-design) printf 'https://github.com/anthropics/skills\tskills/frontend-design\tProduce polished web UIs' ;;
    mcp-builder)     printf 'https://github.com/anthropics/skills\tskills/mcp-builder\tScaffold new MCP servers' ;;
    *) return 1 ;;
  esac
}

_claude_skill_protected() {
  case " $_CLAUDE_SKILL_PROTECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Emit "name<TAB>description" for each installed skill.
_claude_skill_list() {
  local d="$_CSKILLS" f nm desc
  [[ -d "$d" ]] || return 0
  shopt -s nullglob
  for f in "$d"/*/SKILL.md; do
    nm="$(basename "$(dirname "$f")")"
    desc="$(sed -n 's/^description:[[:space:]]*//p' "$f" 2>/dev/null | head -1)"
    printf '%s\t%s\n' "$nm" "$desc"
  done
  shopt -u nullglob
}

do_skill_install() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local arg="${1:-}" name="${2:-}" subdir="${3:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: claude skill-install <git-url|curated-name> [name] [subdir]"
    log_err "Curated skills: $_CLAUDE_SKILL_CURATED_KEYS"
    return 2
  fi
  local repo=""
  if _claude_skill_curated "$arg" >/dev/null 2>&1; then
    local def; def="$(_claude_skill_curated "$arg")"
    IFS=$'\t' read -r repo subdir _ <<<"$def"
    name="$arg"
  else
    repo="$arg"
    if [[ -z "$name" ]]; then
      name="$(basename "${subdir:-$repo}")"; name="${name%.git}"
    fi
  fi
  [[ -n "$name" ]] || { log_err "Could not determine a skill name; pass one: skill-install <git> <name> [subdir]"; return 2; }
  local dest="$_CSKILLS/$name"
  if [[ -e "$dest" ]]; then
    log_info "Skill '$name' already present at $dest — skipping (remove it first to reinstall)."
    return 0
  fi
  have_cmd git || apt_install git
  local tmp; tmp="$(mktemp -d)"
  log_info "Cloning $repo …"
  if ! git clone --depth=1 "$repo" "$tmp/repo" >/dev/null 2>&1; then
    rm -rf "$tmp"; log_err "Clone failed: $repo"; return 1
  fi
  local src="$tmp/repo"
  [[ -n "$subdir" ]] && src="$tmp/repo/$subdir"
  if [[ ! -f "$src/SKILL.md" ]]; then
    rm -rf "$tmp"
    log_err "No SKILL.md found${subdir:+ in subdir $subdir} in $repo."
    log_err "For a multi-skill repo, pass the subdir (skill-install <git> <name> <subdir>),"
    log_err "or add it as a plugin marketplace instead (swkit claude marketplace-add <owner/repo>)."
    return 1
  fi
  mkdir -p "$_CSKILLS"
  cp -a "$src" "$dest"
  rm -rf "$tmp"
  log_info "Installed skill '$name' -> $dest"
  log_info "Restart Claude Code (or open a new session) to pick it up."
}

do_skill_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude skill-remove <name>"; return 2; }
  if _claude_skill_protected "$name"; then
    log_err "'$name' is a kit-managed skill (deployed by ubuntu-setup) — refusing to remove it here."
    log_err "Remove it through the kit instead if you really mean to."
    return 2
  fi
  local dest="$_CSKILLS/$name"
  if [[ ! -d "$dest" ]]; then
    log_info "Skill '$name' is not installed — nothing to remove."
    return 0
  fi
  local bakdir="$_CHOME/.cache/ubuntu-setup"
  mkdir -p "$bakdir" 2>/dev/null || bakdir="/tmp"
  local bak; bak="$bakdir/skill-${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
  if tar -czf "$bak" -C "$_CSKILLS" "$name" 2>/dev/null; then
    log_info "Backed up '$name' -> $bak"
  else
    log_warn "Backup of '$name' failed; proceeding with removal."
    bak=""
  fi
  rm -rf "$dest"
  log_info "Removed skill '$name'.${bak:+ (backup: $bak)}"
}

# ===============================================================================
# Axis 4 — Default editor (~/.claude/settings.json env EDITOR/VISUAL)
# ===============================================================================
# Claude Code's external editor (Ctrl+G) reads the standard $EDITOR/$VISUAL. We set those
# Claude-scoped, by writing them into ~/.claude/settings.json's `env` block (not the global
# shell). All JSON edits go through jq (apt-installed if missing) with a backup first.

# Curated editor: key -> "probe-cmd<TAB>EDITOR-value<TAB>description". The probe-cmd decides
# whether it is installed; the EDITOR-value carries the blocking flag for GUI editors so the
# editor stays in the foreground until the user finishes. Returns non-zero for unknown keys.
_claude_editor_curated() {
  case "$1" in
    code)   printf 'code\tcode --wait\tVS Code (waits for the tab to close)' ;;
    cursor) printf 'cursor\tcursor --wait\tCursor (waits for the tab to close)' ;;
    nvim)   printf 'nvim\tnvim\tNeovim' ;;
    vim)    printf 'vim\tvim\tVi-compatible modal editor' ;;
    nano)   printf 'nano\tnano\tSimple, always-available editor' ;;
    micro)  printf 'micro\tmicro\tModern, easy terminal editor' ;;
    emacs)  printf 'emacs\temacs -nw\tEmacs in the terminal' ;;
    helix)  printf 'hx\thx\tHelix (hx)' ;;
    *) return 1 ;;
  esac
}

# Absolute path to the user's Claude settings file (_CHOME comes from _claude_user_paths).
_claude_settings_path() { printf '%s' "${_CHOME:-$HOME}/.claude/settings.json"; }

# Echo the EDITOR value currently set by this kit in settings.json's env (empty if none).
# Prefers jq; falls back to a best-effort grep purely for the display line.
_claude_editor_current() {
  local settings; settings="$(_claude_settings_path)"
  [[ -f "$settings" ]] || return 0
  if have_cmd jq; then
    jq -r '.env.EDITOR // empty' "$settings" 2>/dev/null
  else
    sed -n 's/.*"EDITOR"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" 2>/dev/null | head -1
  fi
}

# Ensure jq is available (apt-installed if missing). Returns non-zero if it still isn't.
_claude_need_jq() {
  have_cmd jq && return 0
  log_info "jq is needed to edit ~/.claude/settings.json safely — installing it…"
  apt_install jq || true
  have_cmd jq && return 0
  log_err "jq is required to edit ~/.claude/settings.json but could not be installed."
  return 1
}

# Write EDITOR=VISUAL=VALUE into settings.json's env (idempotent). Needs jq; backs up first;
# refuses to touch a file that is not valid JSON (the backup is the only undo).
_claude_editor_write() {
  local val="$1" settings tmp
  settings="$(_claude_settings_path)"
  _claude_need_jq || return 1
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || printf '{}\n' >"$settings"
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    log_err "$settings is not valid JSON — fix or remove it first (then re-run)."
    return 1
  fi
  backup_file "$settings"
  tmp="$(mktemp)"
  if jq --arg e "$val" '.env = (.env // {}) | .env.EDITOR = $e | .env.VISUAL = $e' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"; log_err "Failed to update $settings via jq."; return 1
  fi
}

# Remove EDITOR/VISUAL from settings.json's env; drop env entirely if it becomes empty.
_claude_editor_clear() {
  local settings tmp
  settings="$(_claude_settings_path)"
  if [[ ! -f "$settings" ]]; then
    log_info "No ~/.claude/settings.json — Claude's default editor is not set; nothing to clear."
    return 0
  fi
  _claude_need_jq || return 1
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    log_err "$settings is not valid JSON — fix or remove it first (then re-run)."
    return 1
  fi
  if [[ -z "$(_claude_editor_current)" ]]; then
    log_info "Claude's default editor is not set in settings.json — nothing to clear."
    return 0
  fi
  backup_file "$settings"
  tmp="$(mktemp)"
  if jq 'if has("env") then .env |= (del(.EDITOR) | del(.VISUAL)) else . end
         | if (.env? | length) == 0 then del(.env) else . end' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"; log_err "Failed to update $settings via jq."; return 1
  fi
}

# set-editor <curated-key|command>: set Claude's external editor (Ctrl+G). A curated key is
# resolved to its proper command (with --wait/-nw); anything else is written verbatim. An
# editor that is not on PATH is set anyway (so you can configure before installing), with a
# warning. Runs as the user (refuses a sudo-wrapped run) so ~/.claude stays user-owned.
do_set_editor() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: claude set-editor <name|command>"
    log_err "Curated editors: $_CLAUDE_EDITOR_CURATED_KEYS"
    return 2
  fi
  local def val probe first
  if def="$(_claude_editor_curated "$arg")"; then
    IFS=$'\t' read -r probe val _ <<<"$def"
    have_cmd "$probe" || log_warn "'$arg' ($probe) is not on PATH — setting it anyway; install it for Ctrl+G to work."
  else
    val="$arg"
    first="${arg%% *}"
    [[ -z "$first" ]] || have_cmd "$first" || log_warn "'$first' is not on PATH — setting it anyway; install it for Ctrl+G to work."
  fi
  log_info "Setting Claude's default editor (EDITOR/VISUAL) to '$val' in $(_claude_settings_path)…"
  _claude_editor_write "$val" || return 1
  log_info "Done — Claude Code (Ctrl+G) will use '$val'. Restart any running session to pick it up."
}

# clear-editor: remove the kit-set editor from settings.json (fall back to your shell $EDITOR).
do_clear_editor() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  log_info "Clearing Claude's default editor from $(_claude_settings_path)…"
  _claude_editor_clear || return 1
}

# ===============================================================================
# Axis 5 — Default thinking effort (~/.claude/settings.json top-level "effortLevel")
# ===============================================================================
# Claude Code's reasoning effort (the /effort level) is persisted as the top-level
# "effortLevel" in ~/.claude/settings.json, so a NEW session starts at the chosen level
# (equivalent to running /effort once and letting it stick). Like the editor axis, every JSON
# edit goes through jq with a backup first; unlike the editor (a free-form command), the level
# is an enum validated before write. Runs AS THE USER (refuses sudo) so ~/.claude stays owned.

# Exit 0 iff $1 is a known effort level (enum guard — also blocks junk / JSON injection).
_claude_effort_valid() {
  case " $_CLAUDE_EFFORT_LEVELS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Echo the effortLevel currently set in settings.json (empty if none). Prefers jq; falls back
# to a best-effort grep purely for the display line.
_claude_effort_current() {
  local settings; settings="$(_claude_settings_path)"
  [[ -f "$settings" ]] || return 0
  if have_cmd jq; then
    jq -r '.effortLevel // empty' "$settings" 2>/dev/null
  else
    sed -n 's/.*"effortLevel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$settings" 2>/dev/null | head -1
  fi
}

# Write .effortLevel = VALUE into settings.json (idempotent). Needs jq; backs up first;
# refuses to touch a file that is not valid JSON (the backup is the only undo).
_claude_effort_write() {
  local val="$1" settings tmp
  settings="$(_claude_settings_path)"
  _claude_need_jq || return 1
  mkdir -p "$(dirname "$settings")"
  [[ -f "$settings" ]] || printf '{}\n' >"$settings"
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    log_err "$settings is not valid JSON — fix or remove it first (then re-run)."
    return 1
  fi
  backup_file "$settings"
  tmp="$(mktemp)"
  if jq --arg e "$val" '.effortLevel = $e' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"; log_err "Failed to update $settings via jq."; return 1
  fi
}

# Remove .effortLevel from settings.json (back to each model's built-in default).
_claude_effort_clear() {
  local settings tmp
  settings="$(_claude_settings_path)"
  if [[ ! -f "$settings" ]]; then
    log_info "No ~/.claude/settings.json — Claude Code's thinking effort is not set; nothing to clear."
    return 0
  fi
  _claude_need_jq || return 1
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    log_err "$settings is not valid JSON — fix or remove it first (then re-run)."
    return 1
  fi
  if [[ -z "$(_claude_effort_current)" ]]; then
    log_info "Claude Code's thinking effort is not set in settings.json — nothing to clear."
    return 0
  fi
  backup_file "$settings"
  tmp="$(mktemp)"
  if jq 'del(.effortLevel)' "$settings" >"$tmp"; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"; log_err "Failed to update $settings via jq."; return 1
  fi
}

# set-effort <level>: set Claude Code's default thinking effort (the /effort level), written as
# the top-level "effortLevel" in ~/.claude/settings.json so new sessions start there. The level
# must be one of: low medium high xhigh max. Runs as the user (refuses a sudo-wrapped run).
do_set_effort() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local level="${1:-}"
  if [[ -z "$level" ]]; then
    log_err "Usage: claude set-effort <low|medium|high|xhigh|max>"
    return 2
  fi
  if ! _claude_effort_valid "$level"; then
    log_err "Unknown effort level '$level' — expected one of: $_CLAUDE_EFFORT_LEVELS."
    return 2
  fi
  log_info "Setting Claude Code's default thinking effort to '$level' in $(_claude_settings_path)…"
  _claude_effort_write "$level" || return 1
  if [[ "$level" == max ]]; then
    log_warn "Claude Code may not persist 'max' across sessions (a known limitation); for a"
    log_warn "permanent max default, also set CLAUDE_CODE_EFFORT_LEVEL=max in your shell profile."
  fi
  log_info "Done — new Claude Code sessions will start at '$level' effort (run /effort to confirm)."
}

# clear-effort: remove effortLevel from settings.json (each model falls back to its built-in
# default; equivalent to /effort auto).
do_clear_effort() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  log_info "Clearing Claude Code's default thinking effort from $(_claude_settings_path)…"
  _claude_effort_clear || return 1
}

# ===============================================================================
# Interactive management screen (the script's own UI) — consolidated extension manager
# ===============================================================================
# A bespoke full-screen panel: install state at top, then three sections — MCP servers,
# Plugins & marketplaces, Skills — each a checklist of curated quick-adds + currently
# configured items + an "add…" row. State is probed live (slow `claude` calls) only on a
# refresh (entry + after each change), then cached; the keypress loop navigates the cache.
# Every change shells out via ui_run (visible output + log), then triggers a refresh.
# Limited terminals fall back to the synthesized op menu. `ui` is an entry mode — never a
# meta op.
_claude_ui_footer() {
  case "$1" in
    plugin) _claude_t foot_plugin ;;
    *)      _claude_t foot_main ;;
  esac
}

ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g refresh=1
  local installed=0 ver=""
  local mcp_names="" plug_state="" skill_list="" mkt_list=""
  local editor_current="" editor_shell="" effort_current=""
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state (only on refresh; these shell out to claude and can be slow) ----
    if (( refresh )); then
      installed=0; ver=""
      if status >/dev/null 2>&1; then
        installed=1
        ver="$(claude --version 2>/dev/null | awk '{print $1}')"
        _claude_user_paths >/dev/null 2>&1 || true
        mcp_names="$(_claude_mcp_configured_names 2>/dev/null || true)"
        plug_state="$(_claude_plugins_state 2>/dev/null || true)"
        skill_list="$(_claude_skill_list 2>/dev/null || true)"
        # Cache the marketplace list ONCE here, like the other slow `claude` probes — the
        # per-keypress render below matches against this cache instead of re-shelling out
        # to `claude plugin marketplace list` every frame (that was the navigation lag).
        mkt_list="$(claude plugin marketplace list 2>/dev/null || true)"
        # Default editor: the value we set in settings.json (if any), and the shell's own
        # $EDITOR/$VISUAL for the honest "where the current editor comes from" line.
        editor_current="$(_claude_editor_current 2>/dev/null || true)"
        editor_shell="${VISUAL:-${EDITOR:-}}"
        # Default thinking effort: the effortLevel we set in settings.json (empty if none).
        effort_current="$(_claude_effort_current 2>/dev/null || true)"
      fi
      refresh=0
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Claude Code CLI")
    else
      local key on nm en def transport rt desc note repo present mkt_lc

      # ---- MCP servers ----
      dkind+=(header); did+=(""); dlabel+=("$(_claude_t mcp_servers)")
      # user-configured servers (exclude plugin/account-managed and curated dups)
      while IFS= read -r nm; do
        [[ -n "$nm" ]] || continue
        case "$nm" in plugin:*|"claude.ai "*) continue ;; esac
        case " $_CLAUDE_MCP_CURATED_KEYS " in *" $nm "*) continue ;; esac
        dkind+=(mcp_user); did+=("$nm"); dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}($(_claude_t tag_configured))${UI_OFF}")
      done <<<"$mcp_names"
      # curated catalog (the gloss is localized; the spec/runtime label stay as-is)
      for key in $_CLAUDE_MCP_CURATED_KEYS; do
        on=0
        case $'\n'"$mcp_names"$'\n' in *$'\n'"$key"$'\n'*) on=1 ;; esac
        def="$(_claude_mcp_curated "$key")"; IFS=$'\t' read -r transport _ rt _ <<<"$def"
        desc="$(_claude_t "mcp_desc:$key")"
        note=""; [[ "$rt" != "-" ]] && note=" ${UI_MUTED}($rt)${UI_OFF}"
        dkind+=(mcp_curated); did+=("$key")
        if (( on )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
        else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}$note"); fi
      done
      dkind+=(mcp_add); did+=(mcp_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_claude_t add_mcp)")

      # ---- Plugins & marketplaces ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_claude_t plugins_mkts)")
      mkt_lc="${mkt_list,,}"   # case-insensitive match against the cached list (no claude call)
      for repo in $_CLAUDE_MKT_CURATED; do
        if [[ "$mkt_lc" == *"${repo,,}"* ]]; then present=1; else present=0; fi
        dkind+=(marketplace); did+=("$repo")
        if (( present )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $repo ${UI_MUTED}— $(_claude_t "mkt_desc:$repo")${UI_OFF}")
        else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $repo ${UI_MUTED}— $(_claude_t "mkt_desc:$repo")${UI_OFF}"); fi
      done
      dkind+=(marketplace_add); did+=(marketplace_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_claude_t add_mkt)")
      # installed plugins
      local -a installed_plugins=()
      if [[ -n "$plug_state" ]]; then
        while IFS=$'\t' read -r nm en; do
          [[ -n "$nm" ]] || continue
          installed_plugins+=("${nm%@*}")
          dkind+=(plugin); did+=("$nm")
          if [[ "$en" == "1" ]]; then dlabel+=("  ${UI_OK}${UI_DOT_ON}${UI_OFF} $nm ${UI_MUTED}($(_claude_t tag_enabled))${UI_OFF}")
          else dlabel+=("  ${UI_MUTED}${UI_DOT_OFF} $nm ($(_claude_t tag_disabled))${UI_OFF}"); fi
        done <<<"$plug_state"
      fi
      # curated plugins not already installed
      for key in $_CLAUDE_PLUGIN_CURATED_KEYS; do
        local palready=0 p
        for p in "${installed_plugins[@]}"; do [[ "$p" == "$key" ]] && { palready=1; break; }; done
        (( palready )) && continue
        desc="$(_claude_t "plugin_desc:$key")"
        dkind+=(plugin_curated); did+=("$key")
        dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
      done
      dkind+=(plugin_add); did+=(plugin_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_claude_t add_plugin)")

      # ---- Skills ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_claude_t skills)")
      local -a installed_skills=()
      if [[ -n "$skill_list" ]]; then
        # Installed skills show the description reported by the skill itself (from its own
        # SKILL.md front-matter) — that is user content, not a kit string, so it is shown as-is.
        while IFS=$'\t' read -r nm desc; do
          [[ -n "$nm" ]] || continue
          installed_skills+=("$nm")
          dkind+=(skill); did+=("$nm")
          if _claude_skill_protected "$nm"; then
            dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}($(_claude_t tag_kit))${UI_OFF}")
          else
            dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}${desc:+— $desc}${UI_OFF}")
          fi
        done <<<"$skill_list"
      fi
      # curated skills not already installed (gloss localized from the i18n table)
      for key in $_CLAUDE_SKILL_CURATED_KEYS; do
        local already=0 s
        for s in "${installed_skills[@]}"; do [[ "$s" == "$key" ]] && { already=1; break; }; done
        (( already )) && continue
        desc="$(_claude_t "skill_desc:$key")"
        dkind+=(skill_curated); did+=("$key")
        dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
      done
      dkind+=(skill_add); did+=(skill_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_claude_t add_skill)")

      # ---- Default editor (Ctrl+G external editor; ~/.claude/settings.json env) ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      local einfo ekey eprobe evalue einst
      if [[ -n "$editor_current" ]]; then einfo="$(_claude_tx editor_from_settings X "$editor_current")"
      elif [[ -n "$editor_shell" ]]; then einfo="$(_claude_tx editor_from_env X "$editor_shell")"
      else einfo="$(_claude_t editor_unset)"; fi
      dkind+=(header); did+=(""); dlabel+=("$(_claude_t editor_section) ${UI_MUTED}— $einfo${UI_OFF}")
      for ekey in $_CLAUDE_EDITOR_CURATED_KEYS; do
        def="$(_claude_editor_curated "$ekey")"; IFS=$'\t' read -r eprobe evalue _ <<<"$def"
        einst=0; have_cmd "$eprobe" && einst=1
        desc="$(_claude_t "editor_desc:$ekey")"
        dkind+=(editor); did+=("$ekey")
        if [[ -n "$editor_current" && "$editor_current" == "$evalue" ]]; then
          dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $ekey ${UI_MUTED}— $desc${UI_OFF}")
        elif (( einst )); then
          dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $ekey ${UI_MUTED}— $desc${UI_OFF}")
        else
          dlabel+=("  ${UI_MUTED}${UI_CHK_OFF} $ekey — $desc ($(_claude_t tag_not_installed))${UI_OFF}")
        fi
      done
      dkind+=(editor_custom); did+=(editor_custom); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_claude_t editor_set_custom)")
      if [[ -n "$editor_current" ]]; then
        dkind+=(editor_clear); did+=(editor_clear); dlabel+=("  ${UI_MUTED}↺ $(_claude_t editor_use_default)${UI_OFF}")
      fi

      # ---- Default thinking effort (/effort; ~/.claude/settings.json effortLevel) ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      local effinfo eff
      if [[ -n "$effort_current" ]]; then effinfo="$(_claude_tx effort_current X "$effort_current")"
      else effinfo="$(_claude_t effort_unset)"; fi
      dkind+=(header); did+=(""); dlabel+=("$(_claude_t effort_section) ${UI_MUTED}— $effinfo${UI_OFF}")
      for eff in $_CLAUDE_EFFORT_LEVELS; do
        desc="$(_claude_t "effort_desc:$eff")"
        dkind+=(effort); did+=("$eff")
        if [[ -n "$effort_current" && "$effort_current" == "$eff" ]]; then
          dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $eff ${UI_MUTED}— $desc${UI_OFF}")
        else
          dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $eff ${UI_MUTED}— $desc${UI_OFF}")
        fi
      done
      if [[ -n "$effort_current" ]]; then
        dkind+=(effort_clear); did+=(effort_clear); dlabel+=("  ${UI_MUTED}↺ $(_claude_t effort_use_default)${UI_OFF}")
      fi

      # ---- danger zone ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Claude Code CLI")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Claude Code · extension manager" "${ver:+v$ver }${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Claude Code · extension manager" "$(ui_t not_installed)"; fi
    local i row=3 top=0 avail=$(( UI_ROWS - 3 - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_claude_ui_footer "${dkind[$sel]}")"
    else ui_footer "$(_claude_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      x|X)
        if [[ "${dkind[$sel]}" == plugin ]]; then
          ui_confirm "$(_claude_tx confirm_remove_plugin X "${did[$sel]}")" n \
            && { ui_run "plugin-remove ${did[$sel]} · claude" -- "$0" plugin-remove "${did[$sel]}"; refresh=1; }
        fi ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            local _npm_label; _npm_label="$(_claude_t method_npm)"; _npm_label="${_npm_label//\{N\}/${_CLAUDE_MIN_NODE_MAJOR}}"
            if ui_pick "$(_claude_t pick_method)" "" "" -- \
                 native "$(_claude_t method_native)" \
                 npm    "$_npm_label" \
               && [[ -n "$UI_PICK" ]]; then
              ui_run "$(ui_t install) Claude Code" -- "$0" install --method "$UI_PICK"; refresh=1
            fi ;;
          remove)
            ui_confirm "$(_claude_t confirm_remove_cli)" n \
              && { ui_run "$(ui_t remove) Claude Code" -- "$0" remove; refresh=1; } ;;
          mcp_curated)
            local mk="${did[$sel]}"
            if case $'\n'"$mcp_names"$'\n' in *$'\n'"$mk"$'\n'*) true ;; *) false ;; esac; then
              ui_run "mcp-remove $mk · claude" -- "$0" mcp-remove "$mk"
            else
              ui_run "mcp-add $mk · claude" -- "$0" mcp-add "$mk"
            fi
            refresh=1 ;;
          mcp_user)
            ui_confirm "$(_claude_tx confirm_remove_mcp X "${did[$sel]}")" n \
              && { ui_run "mcp-remove ${did[$sel]} · claude" -- "$0" mcp-remove "${did[$sel]}"; refresh=1; } ;;
          mcp_add)
            if ui_input "$(_claude_t prompt_mcp_name)" ""; then
              local mname="$UI_INPUT"
              if [[ -n "$mname" ]]; then
                ui_pick "$(_claude_tx pick_transport X "$mname")" "" "" -- stdio "$(_claude_t tr_stdio)" http "$(_claude_t tr_http)" sse "$(_claude_t tr_sse)"
                if [[ -n "$UI_PICK" ]]; then
                  local mtr="$UI_PICK" prompt2
                  [[ "$mtr" == stdio ]] && prompt2="$(_claude_t prompt_cmd)" || prompt2="$(_claude_t prompt_url)"
                  if ui_input "$prompt2" ""; then
                    local -a specarr; read -r -a specarr <<<"$UI_INPUT"
                    (( ${#specarr[@]} )) && { ui_run "mcp-add $mname · claude" -- "$0" mcp-add "$mname" -t "$mtr" -- "${specarr[@]}"; refresh=1; }
                  fi
                fi
              fi
            fi ;;
          marketplace)
            local mr="${did[$sel]}"
            if _claude_marketplace_present "$mr"; then
              local mname2; mname2="$(_claude_marketplace_name_for "$mr")"; [[ -n "$mname2" ]] || mname2="$mr"
              ui_confirm "$(_claude_tx confirm_remove_mkt X "$mname2")" n \
                && { ui_run "marketplace-remove $mname2 · claude" -- "$0" marketplace-remove "$mname2"; refresh=1; }
            else
              ui_run "marketplace-add $mr · claude" -- "$0" marketplace-add "$mr"; refresh=1
            fi ;;
          marketplace_add)
            if ui_input "$(_claude_t prompt_mkt)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "marketplace-add $UI_INPUT · claude" -- "$0" marketplace-add "$UI_INPUT"; refresh=1
            fi ;;
          plugin)
            local pn="${did[$sel]}" pen=0
            case $'\n'"$plug_state"$'\n' in *$'\n'"$pn"$'\t'1$'\n'*) pen=1 ;; esac
            if (( pen )); then ui_run "plugin-disable $pn · claude" -- "$0" plugin-disable "$pn"
            else ui_run "plugin-enable $pn · claude" -- "$0" plugin-enable "$pn"; fi
            refresh=1 ;;
          plugin_curated)
            ui_run "plugin-install ${did[$sel]} · claude" -- "$0" plugin-install "${did[$sel]}"; refresh=1 ;;
          plugin_add)
            if ui_input "$(_claude_t prompt_plugin)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "plugin-install $UI_INPUT · claude" -- "$0" plugin-install "$UI_INPUT"; refresh=1
            fi ;;
          skill)
            local skn="${did[$sel]}"
            if _claude_skill_protected "$skn"; then
              ui_notify "$(_claude_tx skill_title X "$skn")" "$(_claude_t skill_protected)"
            else
              ui_confirm "$(_claude_tx confirm_remove_skill X "$skn")" n \
                && { ui_run "skill-remove $skn · claude" -- "$0" skill-remove "$skn"; refresh=1; }
            fi ;;
          skill_curated)
            ui_run "skill-install ${did[$sel]} · claude" -- "$0" skill-install "${did[$sel]}"; refresh=1 ;;
          skill_add)
            if ui_input "$(_claude_t prompt_skill_url)" "" && [[ -n "$UI_INPUT" ]]; then
              local surl="$UI_INPUT" sname ssub
              ui_input "$(_claude_t prompt_skill_name)" "" || true; sname="$UI_INPUT"
              ui_input "$(_claude_t prompt_skill_subdir)" "" || true; ssub="$UI_INPUT"
              ui_run "skill-install · claude" -- "$0" skill-install "$surl" "$sname" "$ssub"; refresh=1
            fi ;;
          editor)
            local ek="${did[$sel]}" edef eprobe2
            edef="$(_claude_editor_curated "$ek")"; IFS=$'\t' read -r eprobe2 _ <<<"$edef"
            if have_cmd "$eprobe2"; then
              ui_run "set-editor $ek · claude" -- "$0" set-editor "$ek"; refresh=1
            else
              ui_notify "$(_claude_tx editor_need_install_t X "$ek")" "$(_claude_tx editor_need_install X "$eprobe2")"
            fi ;;
          editor_custom)
            if ui_input "$(_claude_t prompt_editor)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "set-editor · claude" -- "$0" set-editor "$UI_INPUT"; refresh=1
            fi ;;
          editor_clear)
            ui_confirm "$(_claude_t confirm_clear_editor)" n \
              && { ui_run "clear-editor · claude" -- "$0" clear-editor; refresh=1; } ;;
          effort)
            ui_run "set-effort ${did[$sel]} · claude" -- "$0" set-effort "${did[$sel]}"; refresh=1 ;;
          effort_clear)
            ui_confirm "$(_claude_t confirm_clear_effort)" n \
              && { ui_run "clear-effort · claude" -- "$0" clear-effort; refresh=1; } ;;
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

Claude Code CLI + extension manager. install/remove/status manage the CLI binary; the
remaining commands manage its three extension systems by shelling out to the official
\`claude\` CLI (MCP, plugins) or managing files under ~/.claude/skills (skills). MCP and
plugin actions default to --scope user (global); pass a scope to override. Extension
actions run as your normal user (never via sudo).

CLI binary:
  install [--method native|npm]   Install the CLI (idempotent). native (default): official
                                  installer (no Node). npm: needs Node >= ${_CLAUDE_MIN_NODE_MAJOR} (never sudo npm).
  remove                          Best-effort uninstall (npm global and/or ~/.local/bin/claude).

MCP servers (claude mcp):
  mcp-add <curated-name>          Add a curated server (no other args). Curated:
                                    $_CLAUDE_MCP_CURATED_KEYS
  mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>
                                  Add an arbitrary server (default -t stdio, -s user).
  mcp-remove <name>               Remove a configured MCP server.
  mcp-search <term>               Search the official MCP registry (needs jq).

Plugins & marketplaces (claude plugin):
  marketplace-add <owner/repo|url|path>   Add a plugin marketplace. Curated:
                                    $_CLAUDE_MKT_CURATED
  marketplace-remove <name>       Remove a configured marketplace.
  plugin-install <curated-name>   Install a curated plugin (adds its marketplace first). Curated:
                                    $_CLAUDE_PLUGIN_CURATED_KEYS
  plugin-install <name@marketplace>   Install any plugin (scope user). After adding a
                                  marketplace, browse with: claude plugin list --available
  plugin-remove <name>            Uninstall a plugin.
  plugin-enable <name> / plugin-disable <name>   Toggle a plugin without uninstalling it.

Skills (~/.claude/skills/<name>/):
  skill-install <curated-name>    Install a curated skill. Curated:
                                    $_CLAUDE_SKILL_CURATED_KEYS
  skill-install <git-url> [name] [subdir]   Install any single-skill repo (or a subdir of a
                                  multi-skill repo). Kit-managed skills are protected.
  skill-remove <name>             Remove a skill (a tar backup is saved first).

Default editor (~/.claude/settings.json env EDITOR/VISUAL — Claude's Ctrl+G editor):
  set-editor <curated-name>       Set Claude's external editor. Curated:
                                    $_CLAUDE_EDITOR_CURATED_KEYS
  set-editor <command>            Set any command verbatim (e.g. "vim", "code --wait").
                                  GUI editors need a wait flag so Claude blocks on the edit.
  clear-editor                    Remove it (Claude falls back to your shell \$EDITOR).

Default thinking effort (~/.claude/settings.json effortLevel — Claude Code's /effort level):
  set-effort <level>              Set the default thinking effort, persisted across sessions so
                                  new sessions start there. Level is one of:
                                    $_CLAUDE_EFFORT_LEVELS
                                  (max may not persist — set CLAUDE_CODE_EFFORT_LEVEL=max for that).
  clear-effort                    Remove it (each model falls back to its built-in default).

Other:
  ui                              Open the interactive extension manager (needs a terminal).
  status                          Print 'claude --version'; exit 0 iff installed.
  meta / help                     Metadata / this help.
EOF
}

kit_dispatch "$@"
