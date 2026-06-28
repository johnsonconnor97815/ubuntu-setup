#!/usr/bin/env bash
#
# scripts/codex.sh — install / manage the OpenAI Codex CLI on Ubuntu.
#
# Two channels: the official native installer (default — no Node dependency) and an
# optional npm install of @openai/codex. Both run as the current user; never sudo.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# Minimum Node major version the npm channel supports.
readonly CODEX_NODE_MIN_MAJOR=18

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. Proper nouns stay UNtranslated
# ("Codex CLI", "@openai/codex", "Node", "native"/"npm" channel names, "codex"); only
# descriptive wording is localized. The {N} token in method_npm is replaced with the minimum
# Node major via parameter expansion (kept out of printf to stay SC2059-clean). Resolve with
# _codex_t KEY.
declare -gA CODEX_I18N
CODEX_I18N[en:pick_method]="Choose an installation method"
CODEX_I18N[en:method_native]="native (official installer, no Node)"
CODEX_I18N[en:method_npm]="npm (@openai/codex, needs Node >= {N})"
CODEX_I18N[en:installed_title]="Codex CLI installed"
CODEX_I18N[en:installed_body]="Open a new shell (or 'source ~/.profile'), then run 'codex' to sign in."
CODEX_I18N[en:confirm_remove]="Uninstall the Codex CLI?"
CODEX_I18N[en:foot_main]="↑↓ move   ↵/space select   esc/q close"
CODEX_I18N[zh:pick_method]="选择安装方式"
CODEX_I18N[zh:method_native]="native(官方安装器,无需 Node)"
CODEX_I18N[zh:method_npm]="npm(@openai/codex,需 Node >= {N})"
CODEX_I18N[zh:installed_title]="Codex CLI 已安装"
CODEX_I18N[zh:installed_body]="打开新 shell(或执行 'source ~/.profile'),然后运行 'codex' 登录。"
CODEX_I18N[zh:confirm_remove]="卸载 Codex CLI?"
CODEX_I18N[zh:foot_main]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
CODEX_I18N[ja:pick_method]="インストール方法を選択"
CODEX_I18N[ja:method_native]="native(公式インストーラー、Node 不要)"
CODEX_I18N[ja:method_npm]="npm(@openai/codex、Node >= {N} が必要)"
CODEX_I18N[ja:installed_title]="Codex CLI をインストールしました"
CODEX_I18N[ja:installed_body]="新しいシェルを開く(または 'source ~/.profile')、その後 'codex' を実行してサインイン。"
CODEX_I18N[ja:confirm_remove]="Codex CLI をアンインストールしますか?"
CODEX_I18N[ja:foot_main]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"

# --- i18n: default-editor axis -------------------------------------------------
# Codex's Ctrl+G external editor reads $VISUAL (then $EDITOR). Unlike Claude Code (which has a
# per-app settings.json env block), Codex only reads the PROCESS environment, so this axis must
# write export VISUAL/EDITOR into the user's shell rc -- a GLOBAL change. Editor names stay
# UNtranslated; only descriptive wording is localized. The {X} token is substituted by _codex_tx.
CODEX_I18N[en:editor_section]="Default editor (Ctrl+G)"
CODEX_I18N[en:editor_set_custom]="set custom editor…"
CODEX_I18N[en:editor_use_default]="clear (use your shell \$VISUAL/\$EDITOR)"
CODEX_I18N[en:prompt_editor]="editor command (e.g. nvim, nano, code --wait)"
CODEX_I18N[en:editor_from_rc]="current: {X} (set by this kit)"
CODEX_I18N[en:editor_from_env]="current: {X} (your shell \$VISUAL/\$EDITOR)"
CODEX_I18N[en:editor_unset]="not set (Codex uses your shell / system default)"
CODEX_I18N[en:editor_global]="global env — also affects git & other tools"
CODEX_I18N[en:confirm_clear_editor]="Clear the kit-managed Codex editor (fall back to your shell \$VISUAL/\$EDITOR)?"
CODEX_I18N[en:editor_need_install_t]="Editor '{X}' is not installed"
CODEX_I18N[en:editor_need_install]="Install '{X}' first (e.g. via apt or swkit), then set it here."
CODEX_I18N[en:tag_not_installed]="not installed"
CODEX_I18N[en:editor_desc:code]="VS Code (waits for the tab to close)"
CODEX_I18N[en:editor_desc:cursor]="Cursor (waits for the tab to close)"
CODEX_I18N[en:editor_desc:nvim]="Neovim"
CODEX_I18N[en:editor_desc:vim]="Vi-compatible modal editor"
CODEX_I18N[en:editor_desc:nano]="Simple, always-available editor"
CODEX_I18N[en:editor_desc:micro]="Modern, easy terminal editor"
CODEX_I18N[en:editor_desc:emacs]="Emacs in the terminal"
CODEX_I18N[en:editor_desc:helix]="Helix (hx)"
CODEX_I18N[zh:editor_section]="默认编辑器(Ctrl+G)"
CODEX_I18N[zh:editor_set_custom]="设置自定义编辑器…"
CODEX_I18N[zh:editor_use_default]="清除(用 shell 的 \$VISUAL/\$EDITOR)"
CODEX_I18N[zh:prompt_editor]="编辑器命令(如 nvim、nano、code --wait)"
CODEX_I18N[zh:editor_from_rc]="当前:{X}(本 kit 设置)"
CODEX_I18N[zh:editor_from_env]="当前:{X}(shell 的 \$VISUAL/\$EDITOR)"
CODEX_I18N[zh:editor_unset]="未设置(Codex 回退到 shell / 系统默认)"
CODEX_I18N[zh:editor_global]="全局环境变量 — 同时影响 git 等其他工具"
CODEX_I18N[zh:confirm_clear_editor]="清除本 kit 设置的 Codex 编辑器(回退到 shell 的 \$VISUAL/\$EDITOR)?"
CODEX_I18N[zh:editor_need_install_t]="编辑器 '{X}' 未安装"
CODEX_I18N[zh:editor_need_install]="请先安装 '{X}'(如经 apt 或 swkit),再在此设置。"
CODEX_I18N[zh:tag_not_installed]="未安装"
CODEX_I18N[zh:editor_desc:code]="VS Code(等待标签页关闭)"
CODEX_I18N[zh:editor_desc:cursor]="Cursor(等待标签页关闭)"
CODEX_I18N[zh:editor_desc:nvim]="Neovim"
CODEX_I18N[zh:editor_desc:vim]="Vi 兼容的模式编辑器"
CODEX_I18N[zh:editor_desc:nano]="简单、几乎总是可用"
CODEX_I18N[zh:editor_desc:micro]="现代、易用的终端编辑器"
CODEX_I18N[zh:editor_desc:emacs]="终端里的 Emacs"
CODEX_I18N[zh:editor_desc:helix]="Helix(hx)"
CODEX_I18N[ja:editor_section]="デフォルトエディタ(Ctrl+G)"
CODEX_I18N[ja:editor_set_custom]="カスタムエディタを設定…"
CODEX_I18N[ja:editor_use_default]="クリア(shell の \$VISUAL/\$EDITOR を使用)"
CODEX_I18N[ja:prompt_editor]="エディタコマンド(例: nvim, nano, code --wait)"
CODEX_I18N[ja:editor_from_rc]="現在: {X}(このキットが設定)"
CODEX_I18N[ja:editor_from_env]="現在: {X}(shell の \$VISUAL/\$EDITOR)"
CODEX_I18N[ja:editor_unset]="未設定(Codex は shell / システム既定を使用)"
CODEX_I18N[ja:editor_global]="グローバル環境変数 — git など他のツールにも影響"
CODEX_I18N[ja:confirm_clear_editor]="このキットが設定した Codex エディタをクリアしますか(shell の \$VISUAL/\$EDITOR にフォールバック)?"
CODEX_I18N[ja:editor_need_install_t]="エディタ '{X}' は未インストール"
CODEX_I18N[ja:editor_need_install]="先に '{X}' をインストール(apt や swkit など)してから設定してください。"
CODEX_I18N[ja:tag_not_installed]="未インストール"
CODEX_I18N[ja:editor_desc:code]="VS Code(タブが閉じるまで待機)"
CODEX_I18N[ja:editor_desc:cursor]="Cursor(タブが閉じるまで待機)"
CODEX_I18N[ja:editor_desc:nvim]="Neovim"
CODEX_I18N[ja:editor_desc:vim]="Vi 互換のモーダルエディタ"
CODEX_I18N[ja:editor_desc:nano]="シンプルでほぼ常に利用可能"
CODEX_I18N[ja:editor_desc:micro]="モダンで使いやすい端末エディタ"
CODEX_I18N[ja:editor_desc:emacs]="端末内の Emacs"
CODEX_I18N[ja:editor_desc:helix]="Helix(hx)"

# _codex_t KEY — localized Codex string for $UI_LANG (en/zh/ja), fallback en -> key.
_codex_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${CODEX_I18N[$lang:$1]:-${CODEX_I18N[en:$1]:-$1}}"
}

# _codex_tx KEY TOKEN VALUE — like _codex_t but substitutes the {TOKEN} placeholder with VALUE.
_codex_tx() {
  local s; s="$(_codex_t "$1")"
  printf '%s' "${s//\{$2\}/$3}"
}

meta() {
  cat <<'META'
key=codex
name=Codex CLI
category=ai
tags=cli
recommends=node
ops=install,remove
desc=OpenAI Codex CLI (official native installer; npm optional)
META
}

status() { have_cmd codex && codex --version; }

do_install() {
  local method="native"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method)
        method="${2:-}"
        [[ -n "$method" ]] || { log_err "--method needs an argument (native|npm)."; return 2; }
        shift 2
        ;;
      --method=*) method="${1#--method=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done

  if status >/dev/null 2>&1; then
    log_info "Codex CLI already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi

  case "$method" in
    native) _codex_install_native ;;
    npm)    _codex_install_npm ;;
    *) log_err "Unknown --method: $method (use native or npm)."; return 2 ;;
  esac
}

# Official native installer — drops a self-contained binary in ~/.local/bin (no Node).
_codex_install_native() {
  have_cmd curl || apt_install curl ca-certificates
  log_info "Installing Codex CLI via the official native installer."
  # Piped to `sh` (not bash) per OpenAI's published one-liner. Runs as the user.
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ensure_local_bin_on_path
}

# Optional npm channel. Requires Node >= 18 and a user-writable npm prefix — NEVER sudo.
_codex_install_npm() {
  have_cmd node || { log_err "node not found. Install Node.js (>= ${CODEX_NODE_MIN_MAJOR}) first."; return 1; }
  have_cmd npm  || { log_err "npm not found. Install Node.js (>= ${CODEX_NODE_MIN_MAJOR}) first."; return 1; }

  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || node_major=""
  if [[ -z "$node_major" || ! "$node_major" =~ ^[0-9]+$ ]]; then
    log_err "Could not determine Node.js version from 'node'."
    return 1
  fi
  if (( node_major < CODEX_NODE_MIN_MAJOR )); then
    log_err "Codex CLI needs Node.js >= ${CODEX_NODE_MIN_MAJOR}; found major version ${node_major}."
    return 1
  fi

  # Establish a user-writable npm global prefix if needed (no sudo); refuse a custom unwritable one.
  npm_ensure_user_prefix || return 1

  log_info "Installing Codex CLI via npm (@openai/codex)."
  npm install -g @openai/codex
  ensure_npm_global_bin_on_path
}

# Best-effort, never sudo: undo whichever channel installed it. The official native
# installer ships no uninstaller, so we remove the dropped binary directly.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Codex CLI is not installed — nothing to remove."
    return 0
  fi

  if have_cmd npm && npm ls -g --depth=0 @openai/codex >/dev/null 2>&1; then
    log_info "Removing npm package @openai/codex."
    npm uninstall -g @openai/codex || log_warn "npm uninstall reported an error — continuing."
  fi

  rm -f "$HOME/.local/bin/codex"

  if status >/dev/null 2>&1; then
    log_warn "'codex' is still on PATH ($(command -v codex)) — it was installed elsewhere; remove it by hand."
  fi
  log_info "Removed the Codex CLI binary. Note: user data/config (e.g. ~/.codex) is left in place."
}

# ===============================================================================
# Default editor axis (Codex's Ctrl+G external editor; shell rc VISUAL/EDITOR)
# ===============================================================================
# Codex's composer opens an external editor on Ctrl+G, reading $VISUAL first and falling back to
# $EDITOR (verified against OpenAI's docs). Unlike Claude Code — which has a per-app settings.json
# `env` block, so claude.sh can scope the editor to Claude alone — Codex reads only its PROCESS
# environment and has NO config.toml key for the editor command. The only reliable way to set it
# is to export VISUAL/EDITOR in the user's shell rc, which is GLOBAL (it also affects git, etc.).
# We follow go.sh's managed-rc-line pattern: a marker tag, backup_file before edits, exact-string
# removal on re-set/clear. Runs AS THE USER (refuses a sudo-wrapped run) so the rc stays owned.

# Marker tagged onto every managed line so we can find/replace/remove exactly our own lines.
readonly CODEX_EDITOR_MARKER="# ubuntu-setup (codex default editor)"

# Curated editor: key -> "probe-cmd<TAB>EDITOR-value<TAB>description". The probe-cmd decides
# whether it is installed; the EDITOR-value carries the blocking flag for GUI editors so the
# editor stays in the foreground until the user finishes. Returns non-zero for unknown keys.
readonly _CODEX_EDITOR_CURATED_KEYS="code cursor nvim vim nano micro emacs helix"
_codex_editor_curated() {
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

# The user's shell rc file (honors SUDO_USER's real home; never edits another user's dotfile).
_codex_rc_file() {
  local home="${HOME:-}" shell="${SHELL:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || home="${HOME:-}"
  case "$shell" in */zsh) printf '%s/.zshrc' "$home" ;; *) printf '%s/.bashrc' "$home" ;; esac
}

# Refuse a sudo-wrapped run: this axis writes the user's shell rc, which must stay user-owned.
_codex_user_guard() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run this as your normal user, not via sudo — it edits your shell rc (~/.bashrc or ~/.zshrc)."
    return 1
  fi
}

# Echo the editor value this kit currently sets in the rc's managed VISUAL line (empty if none).
_codex_editor_current() {
  local rc line; rc="$(_codex_rc_file)"
  [[ -f "$rc" ]] || return 0
  line="$(grep -F "$CODEX_EDITOR_MARKER" "$rc" 2>/dev/null | grep -m1 '^export VISUAL=' || true)"
  [[ -n "$line" ]] || return 0
  line="${line#export VISUAL=\"}"          # strip the leading  export VISUAL="
  line="${line%\" "$CODEX_EDITOR_MARKER"}"  # strip the trailing  " <marker>
  printf '%s' "$line"
}

# Write managed export VISUAL/EDITOR lines into the rc (idempotent: drops any prior managed lines
# first so re-setting never accumulates). Backs up a real (non-empty) rc first; creates rc if
# missing. Also exports into THIS process so a codex launched from the same shell sees it now.
_codex_editor_write() {
  local val="$1" rc tmp
  rc="$(_codex_rc_file)"
  [[ -s "$rc" ]] && backup_file "$rc"
  if [[ -f "$rc" ]] && grep -qF "$CODEX_EDITOR_MARKER" "$rc"; then
    tmp="$(mktemp)"
    grep -vF "$CODEX_EDITOR_MARKER" "$rc" >"$tmp" || true
    mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
  fi
  printf 'export VISUAL="%s" %s\n' "$val" "$CODEX_EDITOR_MARKER" >>"$rc"
  printf 'export EDITOR="%s" %s\n' "$val" "$CODEX_EDITOR_MARKER" >>"$rc"
  export VISUAL="$val" EDITOR="$val"
}

# Remove the kit's managed VISUAL/EDITOR lines from the rc (back to the user's own env / default).
_codex_editor_clear() {
  local rc tmp; rc="$(_codex_rc_file)"
  if [[ ! -f "$rc" ]] || ! grep -qF "$CODEX_EDITOR_MARKER" "$rc"; then
    log_info "No kit-managed Codex editor line in $rc — nothing to clear."
    return 0
  fi
  backup_file "$rc"
  tmp="$(mktemp)"
  grep -vF "$CODEX_EDITOR_MARKER" "$rc" >"$tmp" || true
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
  log_info "Removed the kit-managed Codex editor lines from $rc."
}

# set-editor <curated-key|command>: set Codex's external editor (Ctrl+G). A curated key resolves
# to its proper command (with --wait/-nw); anything else is written verbatim. An editor not on
# PATH is set anyway (configure before installing), with a warning. Runs as the user.
do_set_editor() {
  _codex_user_guard || return 1
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: ${0##*/} set-editor <name|command>"
    log_err "Curated editors: $_CODEX_EDITOR_CURATED_KEYS"
    return 2
  fi
  local def val probe first rc
  if def="$(_codex_editor_curated "$arg")"; then
    IFS=$'\t' read -r probe val _ <<<"$def"
    have_cmd "$probe" || log_warn "'$arg' ($probe) is not on PATH — setting it anyway; install it for Ctrl+G to work."
  else
    val="$arg"
    first="${arg%% *}"
    [[ -z "$first" ]] || have_cmd "$first" || log_warn "'$first' is not on PATH — setting it anyway; install it for Ctrl+G to work."
  fi
  # The value lands inside a double-quoted line (export VISUAL="$val") that the shell SOURCES at
  # startup, so " $ ` \ or a newline would break out of the quotes or expand/execute — code
  # execution on the user's machine. Curated values and real editor commands ('vim', 'code
  # --wait') never contain these; refuse anything that does (we offer no primitive for unsafe rc).
  if [[ "$val" == *'"'* || "$val" == *'$'* || "$val" == *'`'* || "$val" == *[\\]* || "$val" == *$'\n'* ]]; then
    log_err "Editor command contains an unsafe character (\" \$ \` \\ or newline) — refusing."
    log_err "Use a plain command such as 'vim', 'nano', or 'code --wait'."
    return 2
  fi
  rc="$(_codex_rc_file)"
  log_info "Setting Codex's external editor (VISUAL/EDITOR) to '$val' in $rc…"
  _codex_editor_write "$val" || return 1
  log_warn "VISUAL/EDITOR are GLOBAL shell env vars — they also affect git commits and other tools"
  log_warn "that honor them (Codex has no app-only editor setting, unlike Claude Code)."
  log_info "Done — open a new shell or 'source $rc'; Codex's Ctrl+G will then open '$val'."
}

# clear-editor: remove the kit-set editor from the rc (Codex falls back to your shell $VISUAL/$EDITOR).
do_clear_editor() {
  _codex_user_guard || return 1
  local rc; rc="$(_codex_rc_file)"
  log_info "Clearing the kit-managed Codex editor from $rc…"
  _codex_editor_clear || return 1
}

# --- Interactive manager (bespoke full-screen screen) --------------------------
# Status header (name + installed badge + version) over the actions. When installed, a
# "Default editor" section lists curated editors as a checklist (current one ✓-marked, missing
# ones tagged), plus "set custom…" / "clear" rows; below it the uninstall action. Headers and
# spacers are skipped during navigation; a viewport scrolls when rows exceed the screen. Install
# offers a native/npm method submenu. 'ui' is an entry mode dispatched by kit_dispatch — never a
# meta op. Non-rich terminals fall back to the synthesized op menu.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" editor_current="" editor_shell=""
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(codex --version 2>/dev/null | awk '{print $NF}')"
      editor_current="$(_codex_editor_current 2>/dev/null || true)"
      editor_shell="${VISUAL:-${EDITOR:-}}"
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Codex CLI")
    else
      # ---- Default editor (Ctrl+G external editor; shell rc VISUAL/EDITOR) ----
      local einfo ekey def eprobe evalue einst desc
      if [[ -n "$editor_current" ]]; then einfo="$(_codex_tx editor_from_rc X "$editor_current")"
      elif [[ -n "$editor_shell" ]]; then einfo="$(_codex_tx editor_from_env X "$editor_shell")"
      else einfo="$(_codex_t editor_unset)"; fi
      dkind+=(header); did+=(""); dlabel+=("$(_codex_t editor_section) ${UI_MUTED}— $einfo${UI_OFF}")
      dkind+=(header); did+=(""); dlabel+=("${UI_MUTED}  ($(_codex_t editor_global))${UI_OFF}")
      for ekey in $_CODEX_EDITOR_CURATED_KEYS; do
        def="$(_codex_editor_curated "$ekey")"; IFS=$'\t' read -r eprobe evalue _ <<<"$def"
        einst=0; have_cmd "$eprobe" && einst=1
        desc="$(_codex_t "editor_desc:$ekey")"
        dkind+=(editor); did+=("$ekey")
        if [[ -n "$editor_current" && "$editor_current" == "$evalue" ]]; then
          dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $ekey ${UI_MUTED}— $desc${UI_OFF}")
        elif (( einst )); then
          dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $ekey ${UI_MUTED}— $desc${UI_OFF}")
        else
          dlabel+=("  ${UI_MUTED}${UI_CHK_OFF} $ekey — $desc ($(_codex_t tag_not_installed))${UI_OFF}")
        fi
      done
      dkind+=(editor_custom); did+=(editor_custom); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_codex_t editor_set_custom)")
      if [[ -n "$editor_current" ]]; then
        dkind+=(editor_clear); did+=(editor_clear); dlabel+=("  ${UI_MUTED}↺ $(_codex_t editor_use_default)${UI_OFF}")
      fi

      # ---- danger zone ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Codex CLI")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Codex CLI" "v$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Codex CLI" "$(ui_t not_installed)"; fi
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
    ui_footer "$(_codex_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            local _npm_label; _npm_label="$(_codex_t method_npm)"; _npm_label="${_npm_label//\{N\}/${CODEX_NODE_MIN_MAJOR}}"
            ui_pick "Codex CLI — $(ui_t install)" "$(_codex_t pick_method)" "" -- \
              native "$(_codex_t method_native)" \
              npm    "$_npm_label"
            if [[ -n "$UI_PICK" ]]; then
              ui_run "$(ui_t install) Codex CLI ($UI_PICK)" -- "$0" install --method "$UI_PICK"
              if [[ "${UI_RUN_RC:-1}" == 0 ]] && status >/dev/null 2>&1; then
                ui_notify "$(_codex_t installed_title)" \
                  "$(_codex_t installed_body)"
              fi
            fi ;;
          editor)
            local ek="${did[$sel]}" edef eprobe2
            edef="$(_codex_editor_curated "$ek")"; IFS=$'\t' read -r eprobe2 _ <<<"$edef"
            if have_cmd "$eprobe2"; then
              ui_run "set-editor $ek · codex" -- "$0" set-editor "$ek"
            else
              ui_notify "$(_codex_tx editor_need_install_t X "$ek")" "$(_codex_tx editor_need_install X "$eprobe2")"
            fi ;;
          editor_custom)
            if ui_input "$(_codex_t prompt_editor)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "set-editor · codex" -- "$0" set-editor "$UI_INPUT"
            fi ;;
          editor_clear)
            ui_confirm "$(_codex_t confirm_clear_editor)" n \
              && ui_run "clear-editor · codex" -- "$0" clear-editor ;;
          remove)
            ui_confirm "$(_codex_t confirm_remove)" n && \
              ui_run "$(ui_t remove) Codex CLI" -- "$0" remove ;;
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
  install [--method native|npm]
             Install the Codex CLI (idempotent — skips if already present).
             native (default): official installer, no Node dependency.
             npm: 'npm install -g @openai/codex' (needs Node >= ${CODEX_NODE_MIN_MAJOR}; never sudo).
  remove     Best-effort uninstall (npm package and/or ~/.local/bin/codex; never sudo)
  status     Print 'codex --version'; exit 0 iff installed

Default editor (Codex's Ctrl+G external editor — reads \$VISUAL, then \$EDITOR):
  set-editor <curated-name>       Set Codex's external editor. Curated:
                                    $_CODEX_EDITOR_CURATED_KEYS
  set-editor <command>            Set any command verbatim (e.g. "vim", "code --wait").
                                  GUI editors need a wait flag so Codex blocks on the edit.
  clear-editor                    Remove it (Codex falls back to your shell \$VISUAL/\$EDITOR).
                                  Note: Codex has no app-only editor setting, so these write
                                  export VISUAL/EDITOR into your shell rc — a GLOBAL change that
                                  also affects git and other tools (run as your user, never sudo).

  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata (for the TUI / swkit list)
  help       Show this help
EOF
}

kit_dispatch "$@"
