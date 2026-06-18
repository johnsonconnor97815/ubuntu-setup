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

# _codex_t KEY — localized Codex string for $UI_LANG (en/zh/ja), fallback en -> key.
_codex_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${CODEX_I18N[$lang:$1]:-${CODEX_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=codex
name=Codex CLI
category=ai
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

  # Refuse a global install into a root-owned prefix (the lib helper points at ~/.local).
  npm_global_writable || return 1

  log_info "Installing Codex CLI via npm (@openai/codex)."
  npm install -g @openai/codex
  ensure_local_bin_on_path
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

# --- Interactive manager (bespoke full-screen screen) --------------------------
# Mirrors scripts/claude.sh's ui(): a status header (name + installed badge + version)
# over a short action list. Install offers a native/npm method submenu (do_install
# accepts --method); uninstall asks to confirm; a post-install notify points the user
# at signing in. 'ui' is an entry mode dispatched by kit_dispatch — never a meta op.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(codex --version 2>/dev/null | awk '{print $NF}')"
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Codex CLI")
    else
      dkind+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Codex CLI")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Codex CLI" "v$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Codex CLI" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      ui_row "$row" "$i" "$sel" "${dlabel[$i]}"
      (( row++ ))
    done
    ui_footer "$(_codex_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
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
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata (for the TUI / swkit list)
  help       Show this help
EOF
}

kit_dispatch "$@"
