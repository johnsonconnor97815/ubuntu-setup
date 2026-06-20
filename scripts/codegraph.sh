#!/usr/bin/env bash
#
# scripts/codegraph.sh — install / configure / manage CodeGraph on Ubuntu.
#
# CodeGraph (@colbymchenry/codegraph) is a 100% local code knowledge graph: it parses
# your code with tree-sitter into a SQLite graph and runs as a local MCP server that AI
# coding agents (Claude Code, Codex, …) query instead of scanning files.
#
# Two phases, mirroring the kit's install/configure split:
#   install   — put the global `codegraph` CLI on PATH via npm (needs Node; never sudo).
#   configure — `codegraph install --yes`: wire the MCP server into detected agents.
# Building a per-project index (`codegraph init -i`) is a per-repo action the user runs
# inside their own project; it is intentionally NOT an op here (see the post-install notify).

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# npm package name (kept in one place — used by install/remove probes).
readonly CODEGRAPH_PKG="@colbymchenry/codegraph"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. Proper nouns stay UNtranslated
# ("CodeGraph", "@colbymchenry/codegraph", "Node", "npm", agent names, "codegraph init");
# only descriptive wording is localized. Resolve with _codegraph_t KEY.
declare -gA CODEGRAPH_I18N
CODEGRAPH_I18N[en:need_node]="node/npm not found. Install Node.js first: swkit node install"
CODEGRAPH_I18N[en:installed_title]="CodeGraph installed"
CODEGRAPH_I18N[en:installed_body]="Next: run 'swkit codegraph configure' to wire CodeGraph into your agents, then 'codegraph init -i' inside each project to build its index."
CODEGRAPH_I18N[en:configured_title]="CodeGraph wired into agents"
CODEGRAPH_I18N[en:configured_body]="Inside each project run 'codegraph init -i' to build its local knowledge-graph index (auto-syncs on file changes)."
CODEGRAPH_I18N[en:row_configure]="wire into agents (codegraph install)"
CODEGRAPH_I18N[en:confirm_remove]="Uninstall CodeGraph (and unregister it from agents)?"
CODEGRAPH_I18N[en:foot_main]="↑↓ move   ↵/space select   esc/q close"
CODEGRAPH_I18N[zh:need_node]="未找到 node/npm。请先安装 Node.js:swkit node install"
CODEGRAPH_I18N[zh:installed_title]="CodeGraph 已安装"
CODEGRAPH_I18N[zh:installed_body]="下一步:运行 'swkit codegraph configure' 把 CodeGraph 接入各 agent,再在每个项目里运行 'codegraph init -i' 建立索引。"
CODEGRAPH_I18N[zh:configured_title]="CodeGraph 已接入各 agent"
CODEGRAPH_I18N[zh:configured_body]="在每个项目里运行 'codegraph init -i' 建立本地知识图谱索引(文件变更时自动同步)。"
CODEGRAPH_I18N[zh:row_configure]="接入各 agent(codegraph install)"
CODEGRAPH_I18N[zh:confirm_remove]="卸载 CodeGraph(并从各 agent 反注册)?"
CODEGRAPH_I18N[zh:foot_main]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
CODEGRAPH_I18N[ja:need_node]="node/npm が見つかりません。先に Node.js をインストール:swkit node install"
CODEGRAPH_I18N[ja:installed_title]="CodeGraph をインストールしました"
CODEGRAPH_I18N[ja:installed_body]="次:'swkit codegraph configure' で CodeGraph を各エージェントに接続し、各プロジェクトで 'codegraph init -i' を実行してインデックスを作成。"
CODEGRAPH_I18N[ja:configured_title]="CodeGraph を各エージェントに接続しました"
CODEGRAPH_I18N[ja:configured_body]="各プロジェクトで 'codegraph init -i' を実行してローカルの知識グラフインデックスを作成(ファイル変更時に自動同期)。"
CODEGRAPH_I18N[ja:row_configure]="各エージェントに接続(codegraph install)"
CODEGRAPH_I18N[ja:confirm_remove]="CodeGraph をアンインストール(各エージェントから登録解除)しますか?"
CODEGRAPH_I18N[ja:foot_main]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"

# _codegraph_t KEY — localized string for $UI_LANG (en/zh/ja), fallback en -> key.
_codegraph_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${CODEGRAPH_I18N[$lang:$1]:-${CODEGRAPH_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=codegraph
name=CodeGraph
category=ai
ops=install,remove,configure
desc=Local code knowledge graph (MCP server) for AI coding agents
META
}

# Exit 0 iff installed. have_cmd is the authoritative gate; the version is best-effort
# (the exact --version output is the tool's concern — never let it abort status).
status() {
  have_cmd codegraph || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip version spawn
  local v=""
  v="$(codegraph --version 2>/dev/null | head -n1)" || v=""
  [[ -n "$v" ]] || v="codegraph (installed)"
  printf '%s\n' "$v"
}

# Require Node + npm (no auto-install, never sudo). CodeGraph ships a bundled runtime but
# is installed as a global npm package, so npm must be present.
_codegraph_require_node() {
  if ! have_cmd node || ! have_cmd npm; then
    log_err "$(_codegraph_t need_node)"
    return 1
  fi
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "CodeGraph already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi
  _codegraph_require_node || return 1
  # Establish a user-writable npm global prefix if needed (no sudo) — npm is our only channel.
  npm_ensure_user_prefix || return 1

  log_info "Installing CodeGraph via npm ($CODEGRAPH_PKG)."
  npm install -g "$CODEGRAPH_PKG"
  ensure_local_bin_on_path
}

# Wire the CodeGraph MCP server into detected agents — the meaningful configuration.
# `codegraph install --yes` auto-detects Claude Code/Codex/etc.; --target=a,b limits it.
do_configure() {
  if ! status >/dev/null 2>&1; then
    log_info "Install CodeGraph first: swkit codegraph install"
    return 0
  fi
  local target=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target) target="${2:-}"; [[ -n "$target" ]] || { log_err "--target needs an argument."; return 2; }; shift 2 ;;
      --target=*) target="${1#--target=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done

  local -a args=(install --yes)
  [[ -n "$target" ]] && args+=("--target=$target")
  log_info "Wiring CodeGraph into agents (codegraph ${args[*]})."
  # Feed /dev/null so a non-interactive run can never block on a prompt.
  codegraph "${args[@]}" </dev/null
}

# Best-effort, never sudo. Unregister from agents first (while the CLI still exists), then
# remove the npm package. User project data (.codegraph/ inside repos) is left in place.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "CodeGraph is not installed — nothing to remove."
    return 0
  fi

  if have_cmd codegraph; then
    log_info "Unregistering CodeGraph from agents (codegraph uninstall)."
    codegraph uninstall --yes </dev/null >/dev/null 2>&1 \
      || codegraph uninstall </dev/null >/dev/null 2>&1 \
      || log_warn "codegraph uninstall reported an error — continuing to remove the package."
  fi

  if have_cmd npm && npm ls -g --depth=0 "$CODEGRAPH_PKG" >/dev/null 2>&1; then
    log_info "Removing npm package $CODEGRAPH_PKG."
    npm uninstall -g "$CODEGRAPH_PKG" || log_warn "npm uninstall reported an error — continuing."
  fi

  rm -f "$HOME/.local/bin/codegraph"

  if status >/dev/null 2>&1; then
    log_warn "'codegraph' is still on PATH ($(command -v codegraph)) — it was installed elsewhere; remove it by hand."
  fi
  log_info "Removed CodeGraph. Per-project data (.codegraph/ in your repos) is left in place."
}

# --- Interactive manager (bespoke full-screen screen) --------------------------
# Mirrors scripts/codex.sh's ui(): a status header (name + installed badge + version)
# over a short action list. When installed it offers configure (wire into agents) and
# remove (confirmed); when missing, install. 'ui' is an entry mode (kit_dispatch) — never
# a meta op; limited terminals fall back to the synthesized op menu.
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
      ver="$(status 2>/dev/null)"
    fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) CodeGraph")
    else
      dkind+=(configure); dlabel+=("$(ui_t configure) — $(_codegraph_t row_configure)")
      dkind+=(remove);    dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) CodeGraph")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "CodeGraph" "$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "CodeGraph" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      ui_row "$row" "$i" "$sel" "${dlabel[$i]}"
      (( row++ ))
    done
    ui_footer "$(_codegraph_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            ui_run "$(ui_t install) CodeGraph" -- "$0" install
            if [[ "${UI_RUN_RC:-1}" == 0 ]] && status >/dev/null 2>&1; then
              ui_notify "$(_codegraph_t installed_title)" "$(_codegraph_t installed_body)"
            fi ;;
          configure)
            ui_run "$(ui_t configure) CodeGraph" -- "$0" configure
            if [[ "${UI_RUN_RC:-1}" == 0 ]]; then
              ui_notify "$(_codegraph_t configured_title)" "$(_codegraph_t configured_body)"
            fi ;;
          remove)
            ui_confirm "$(_codegraph_t confirm_remove)" n && \
              ui_run "$(ui_t remove) CodeGraph" -- "$0" remove ;;
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
  install        Install CodeGraph via npm ($CODEGRAPH_PKG; needs Node, never sudo)
  configure [--target a,b]
                 Wire the CodeGraph MCP server into detected agents
                 (codegraph install --yes). --target limits to specific agents.
  remove         Best-effort uninstall (unregister from agents + npm uninstall; never sudo)
  status         Print the version if installed; exit 0 iff installed
  ui             Open the interactive manager (needs a terminal)
  meta           Print machine-readable metadata (for the TUI / swkit list)
  help           Show this help

Note: build a project's index by running 'codegraph init -i' inside that repo.
EOF
}

kit_dispatch "$@"
