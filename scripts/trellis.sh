#!/usr/bin/env bash
#
# scripts/trellis.sh — install / configure / manage Trellis on Ubuntu.
#
# Trellis (@mindfoldhq/trellis) is an engineering framework for AI coding agents: it
# persists specs, tasks and memory into a repo's .trellis/ so any agent (Claude Code,
# Codex, …) works to consistent standards.
#
# Two phases, mirroring the kit's install/configure split:
#   install   — put the global `trellis` CLI on PATH via npm (needs Node; never sudo).
#   configure — `trellis init -u <name>`: initialize Trellis in the CURRENT git repo.
# `configure` is a per-repo action (it writes .trellis/ in the working directory), so it
# requires being inside a git work tree and defaults the user name from `git config`.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# npm package name and minimum Node major (Trellis documents Node >= 18).
readonly TRELLIS_PKG="@mindfoldhq/trellis"
readonly TRELLIS_NODE_MIN_MAJOR=18

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. Proper nouns stay UNtranslated
# ("Trellis", "@mindfoldhq/trellis", "Node", "npm", "Python", "git", "trellis init"); only
# descriptive wording is localized. The {N} token is replaced via parameter expansion (kept
# out of printf to stay SC2059-clean). Resolve with _trellis_t KEY.
declare -gA TRELLIS_I18N
TRELLIS_I18N[en:need_node]="node/npm not found. Install Node.js (>= {N}) first: swkit node install"
TRELLIS_I18N[en:node_old]="Trellis needs Node.js >= {N}; found major version"
TRELLIS_I18N[en:py_warn]="Python >= 3.9 is recommended for some Trellis features (python3 missing or older). Install it with: sudo apt install python3"
TRELLIS_I18N[en:need_repo]="Trellis must be initialized inside a project. cd into your git repo first, then run configure."
TRELLIS_I18N[en:no_user]="Could not determine a user name. Pass one: swkit trellis configure --user <name>"
TRELLIS_I18N[en:installed_title]="Trellis installed"
TRELLIS_I18N[en:installed_body]="Inside a project repo run 'swkit trellis configure' (or 'trellis init -u <name>') to set up .trellis/."
TRELLIS_I18N[en:configured_title]="Trellis initialized in this repo"
TRELLIS_I18N[en:configured_body]="Specs, tasks and memory now live under .trellis/ in this repository."
TRELLIS_I18N[en:row_configure]="initialize in the current repo (trellis init)"
TRELLIS_I18N[en:confirm_remove]="Uninstall Trellis?"
TRELLIS_I18N[en:foot_main]="↑↓ move   ↵/space select   esc/q close"
TRELLIS_I18N[zh:need_node]="未找到 node/npm。请先安装 Node.js(>= {N}):swkit node install"
TRELLIS_I18N[zh:node_old]="Trellis 需要 Node.js >= {N};当前主版本为"
TRELLIS_I18N[zh:py_warn]="Trellis 部分功能建议 Python >= 3.9(未找到 python3 或版本过旧)。可安装:sudo apt install python3"
TRELLIS_I18N[zh:need_repo]="Trellis 需在项目内初始化。请先 cd 进你的 git 仓库,再运行 configure。"
TRELLIS_I18N[zh:no_user]="无法确定用户名。请显式传入:swkit trellis configure --user <名字>"
TRELLIS_I18N[zh:installed_title]="Trellis 已安装"
TRELLIS_I18N[zh:installed_body]="在某个项目仓库里运行 'swkit trellis configure'(或 'trellis init -u <名字>')来建立 .trellis/。"
TRELLIS_I18N[zh:configured_title]="Trellis 已在本仓库初始化"
TRELLIS_I18N[zh:configured_body]="specs / tasks / memory 现已位于本仓库的 .trellis/ 下。"
TRELLIS_I18N[zh:row_configure]="在当前仓库初始化(trellis init)"
TRELLIS_I18N[zh:confirm_remove]="卸载 Trellis?"
TRELLIS_I18N[zh:foot_main]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
TRELLIS_I18N[ja:need_node]="node/npm が見つかりません。先に Node.js(>= {N})をインストール:swkit node install"
TRELLIS_I18N[ja:node_old]="Trellis は Node.js >= {N} が必要です。検出したメジャーバージョン:"
TRELLIS_I18N[ja:py_warn]="Trellis の一部機能には Python >= 3.9 を推奨します(python3 が無いか古い)。インストール:sudo apt install python3"
TRELLIS_I18N[ja:need_repo]="Trellis はプロジェクト内で初期化します。先に git リポジトリへ cd してから configure を実行してください。"
TRELLIS_I18N[ja:no_user]="ユーザー名を判定できません。明示してください:swkit trellis configure --user <名前>"
TRELLIS_I18N[ja:installed_title]="Trellis をインストールしました"
TRELLIS_I18N[ja:installed_body]="プロジェクトのリポジトリ内で 'swkit trellis configure'(または 'trellis init -u <名前>')を実行して .trellis/ を作成。"
TRELLIS_I18N[ja:configured_title]="このリポジトリで Trellis を初期化しました"
TRELLIS_I18N[ja:configured_body]="specs / tasks / memory はこのリポジトリの .trellis/ 配下にあります。"
TRELLIS_I18N[ja:row_configure]="現在のリポジトリで初期化(trellis init)"
TRELLIS_I18N[ja:confirm_remove]="Trellis をアンインストールしますか?"
TRELLIS_I18N[ja:foot_main]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"

# _trellis_t KEY — localized string for $UI_LANG (en/zh/ja), fallback en -> key.
_trellis_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${TRELLIS_I18N[$lang:$1]:-${TRELLIS_I18N[en:$1]:-$1}}"
}

# _trellis_msg KEY — like _trellis_t but with the {N} token expanded to the Node minimum.
_trellis_msg() {
  local s; s="$(_trellis_t "$1")"
  printf '%s' "${s//\{N\}/${TRELLIS_NODE_MIN_MAJOR}}"
}

meta() {
  cat <<'META'
key=trellis
name=Trellis
category=ai
ops=install,remove,configure
desc=AI coding engineering framework (specs/tasks/memory in your repo)
META
}

# Exit 0 iff installed. have_cmd is the authoritative gate; version is best-effort.
status() {
  have_cmd trellis || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip version spawn
  local v=""
  v="$(trellis --version 2>/dev/null | head -n1)" || v=""
  [[ -n "$v" ]] || v="trellis (installed)"
  printf '%s\n' "$v"
}

# Require Node + npm with major >= TRELLIS_NODE_MIN_MAJOR (no auto-install, never sudo).
_trellis_require_node() {
  if ! have_cmd node || ! have_cmd npm; then
    log_err "$(_trellis_msg need_node)"
    return 1
  fi
  local node_major
  node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null)" || node_major=""
  if [[ -z "$node_major" || ! "$node_major" =~ ^[0-9]+$ ]]; then
    log_err "Could not determine Node.js version from 'node'."
    return 1
  fi
  if (( node_major < TRELLIS_NODE_MIN_MAJOR )); then
    log_err "$(_trellis_msg node_old) ${node_major}."
    return 1
  fi
}

# Soft check: Python >= 3.9 is a documented runtime prerequisite for some features, but the
# npm install itself does not need it — warn, never block.
_trellis_check_python() {
  local pv major minor
  if ! have_cmd python3; then
    log_warn "$(_trellis_t py_warn)"
    return 0
  fi
  pv="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || pv=""
  major="${pv%%.*}"; minor="${pv#*.}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ ]] \
     || (( major < 3 )) || { (( major == 3 )) && (( minor < 9 )); }; then
    log_warn "$(_trellis_t py_warn)"
  fi
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Trellis already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi
  _trellis_require_node || return 1
  _trellis_check_python
  # Establish a user-writable npm global prefix if needed (no sudo) — npm is our only channel.
  npm_ensure_user_prefix || return 1

  log_info "Installing Trellis via npm (${TRELLIS_PKG}@latest)."
  npm install -g "${TRELLIS_PKG}@latest"
  ensure_local_bin_on_path
}

# Initialize Trellis in the CURRENT git repo (its only meaningful configuration step).
# Defaults the user name from git config; extra flags (e.g. --claude --codex) pass through.
do_configure() {
  if ! status >/dev/null 2>&1; then
    log_info "Install Trellis first: swkit trellis install"
    return 0
  fi

  local user=""
  local -a passthrough=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user|-u) user="${2:-}"; [[ -n "$user" ]] || { log_err "--user needs an argument."; return 2; }; shift 2 ;;
      --user=*) user="${1#--user=}"; shift ;;
      *) passthrough+=("$1"); shift ;;   # e.g. --claude --codex --cursor --opencode
    esac
  done

  # Per-repo guard: never scatter a .trellis/ into an arbitrary directory.
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_err "$(_trellis_t need_repo)"
    return 1
  fi

  if [[ -z "$user" ]]; then
    user="$(git config user.name 2>/dev/null || true)"
    [[ -n "$user" ]] || user="$(id -un 2>/dev/null || true)"
  fi
  if [[ -z "$user" ]]; then
    log_err "$(_trellis_t no_user)"
    return 1
  fi

  local extra=""
  (( ${#passthrough[@]} )) && extra=" ${passthrough[*]}"
  log_info "Initializing Trellis in $(pwd) (trellis init -u '$user'$extra)."
  # Feed /dev/null so a non-interactive run can never block on a prompt.
  trellis init -u "$user" "${passthrough[@]}" </dev/null
}

# Best-effort, never sudo. Remove the npm package; per-repo .trellis/ data is left in place.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Trellis is not installed — nothing to remove."
    return 0
  fi

  if have_cmd npm && npm ls -g --depth=0 "$TRELLIS_PKG" >/dev/null 2>&1; then
    log_info "Removing npm package $TRELLIS_PKG."
    npm uninstall -g "$TRELLIS_PKG" || log_warn "npm uninstall reported an error — continuing."
  fi

  rm -f "$HOME/.local/bin/trellis"

  if status >/dev/null 2>&1; then
    log_warn "'trellis' is still on PATH ($(command -v trellis)) — it was installed elsewhere; remove it by hand."
  fi
  log_info "Removed Trellis. Per-repo data (.trellis/ in your repos) is left in place."
}

# --- Interactive manager (bespoke full-screen screen) --------------------------
# Mirrors scripts/codex.sh's ui(): a status header (name + installed badge + version) over
# a short action list. When installed it offers configure (init in the current repo) and
# remove (confirmed); when missing, install. 'ui' is an entry mode (kit_dispatch) — never a
# meta op; limited terminals fall back to the synthesized op menu.
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
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Trellis")
    else
      dkind+=(configure); dlabel+=("$(ui_t configure) — $(_trellis_t row_configure)")
      dkind+=(remove);    dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Trellis")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Trellis" "$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Trellis" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      ui_row "$row" "$i" "$sel" "${dlabel[$i]}"
      (( row++ ))
    done
    ui_footer "$(_trellis_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            ui_run "$(ui_t install) Trellis" -- "$0" install
            if [[ "${UI_RUN_RC:-1}" == 0 ]] && status >/dev/null 2>&1; then
              ui_notify "$(_trellis_t installed_title)" "$(_trellis_t installed_body)"
            fi ;;
          configure)
            ui_run "$(ui_t configure) Trellis" -- "$0" configure
            if [[ "${UI_RUN_RC:-1}" == 0 ]]; then
              ui_notify "$(_trellis_t configured_title)" "$(_trellis_t configured_body)"
            fi ;;
          remove)
            ui_confirm "$(_trellis_t confirm_remove)" n && \
              ui_run "$(ui_t remove) Trellis" -- "$0" remove ;;
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
  install        Install Trellis via npm (${TRELLIS_PKG}; needs Node >= ${TRELLIS_NODE_MIN_MAJOR}, never sudo)
  configure [--user <name>] [extra trellis-init flags…]
                 Initialize Trellis in the CURRENT git repo (trellis init -u <name>).
                 Defaults <name> from 'git config user.name'. Extra flags such as
                 --claude / --codex / --cursor / --opencode pass through to trellis init.
  remove         Best-effort uninstall (npm uninstall; never sudo)
  status         Print the version if installed; exit 0 iff installed
  ui             Open the interactive manager (needs a terminal)
  meta           Print machine-readable metadata (for the TUI / swkit list)
  help           Show this help
EOF
}

kit_dispatch "$@"
