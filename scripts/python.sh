#!/usr/bin/env bash
#
# scripts/python.sh — install / manage a modern Python development environment on Ubuntu.
#
# Ubuntu already ships the `python3` interpreter (the system depends on it), so this script never
# touches python3 itself. It manages the *development environment* on top, as components (like
# scripts/zsh.sh / tmux.sh):
#   - the system dev layer — apt python3-pip / python3-venv / python3-dev (pip, venvs, C headers).
#   - uv (Astral)          — the modern, Rust-based package/project/Python-version/tool manager
#                            that unifies pip, venv, virtualenv, pipx, poetry and pyenv. Installed
#                            user-space via the official script into ~/.local/bin (NEVER sudo);
#                            with shell completion + PATH wired up.
#   - dev tools via uv     — ruff (lint+format), ty, mypy, ipython, pre-commit — each installed
#                            as an isolated CLI app with `uv tool install` (the modern pipx).
#   - a package index      — optional mirror for pip (~/.config/pip/pip.conf) and uv
#                            (UV_DEFAULT_INDEX), with curated China mirrors. Off by default.
#
# Everything is observed live (no recorded flags): the apt layer via pip, uv via `uv --version`,
# tools via `uv tool list`. Re-running converges. "Installed" = the apt dev layer is present.
#
# Run it as:  python.sh install|remove|configure|install-uv|remove-uv|update-uv|tools|update-tools|
#             status|meta|ui|help   plus add-tool <name> / remove-tool <name> / set-index <name|url>.

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# The apt packages that make up the system dev layer (python3 itself stays — the OS needs it).
readonly PY_ENV_PKGS=(python3-pip python3-venv python3-dev)
readonly UV_INSTALL_URL="https://astral.sh/uv/install.sh"

# --- Curated uv tools (installed as isolated CLI apps via `uv tool install`) ----
# key -> PyPI package. The produced binary equals the key for every entry below.
declare -gA PY_TOOL_PKG=(
  [ruff]="ruff"
  [ty]="ty"
  [mypy]="mypy"
  [ipython]="ipython"
  [pre-commit]="pre-commit"
)
readonly PY_TOOLS_ORDER="ruff ty mypy ipython pre-commit"
readonly PY_RECOMMENDED_TOOLS="ruff"

# Curated package-index presets: key -> URL ('default' = PyPI, clears any override). Off by default.
declare -gA PY_INDEX_PRESET=(
  [default]=""
  [tsinghua]="https://pypi.tuna.tsinghua.edu.cn/simple"
  [aliyun]="https://mirrors.aliyun.com/pypi/simple/"
  [ustc]="https://pypi.mirrors.ustc.edu.cn/simple/"
)
readonly PY_INDEX_ORDER="default tsinghua aliyun ustc"

readonly PY_UVCOMP_MARKER="# ubuntu-setup (uv shell completion)"
readonly PY_UVINDEX_MARKER="# ubuntu-setup (uv default index)"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The language name "Python" and tool/command
# names (python3, pip, uv, ruff, …) stay UNtranslated; only descriptive wording is localized.
declare -gA PY_I18N
PY_I18N[en:uv_section]="uv — modern package/project manager"
PY_I18N[en:dev_tools]="Dev tools (uv tool install)"
PY_I18N[en:pkg_index]="Package index (pip + uv)"
PY_I18N[en:install_uv]="Install uv (user-space, no sudo)"
PY_I18N[en:update_uv]="Update uv (uv self update)"
PY_I18N[en:remove_uv]="Remove uv + its data (cache/pythons/tools)"
PY_I18N[en:apply_recommended]="Apply recommended setup (uv + ruff + PATH)"
PY_I18N[en:confirm_remove]="Remove the Python dev layer (pip/venv/dev)? python3 itself is kept."
PY_I18N[en:confirm_remove_uv]="Remove uv AND its data — managed Pythons and uv-installed tools? This cannot be undone."
PY_I18N[en:foot_main]="up/down move   space toggle   enter select   esc/q close"
PY_I18N[en:pick_index]="Python — package index mirror"
PY_I18N[en:type_index]="Type an index URL…"
PY_I18N[en:prompt_index]="package index URL (…/simple)"
PY_I18N[en:install_base_first]="Install the Python base first (swkit python install)."
PY_I18N[en:install_uv_first]="Install uv first (swkit python install-uv)."
PY_I18N[en:desc_ruff]="linter + formatter (replaces flake8/black/isort)"
PY_I18N[en:desc_ty]="Astral's fast type checker (preview)"
PY_I18N[en:desc_mypy]="static type checker"
PY_I18N[en:desc_ipython]="enhanced interactive REPL"
PY_I18N[en:desc_pre-commit]="git pre-commit hook framework"
PY_I18N[zh:uv_section]="uv —— 现代包/项目管理器"
PY_I18N[zh:dev_tools]="开发工具(uv tool install)"
PY_I18N[zh:pkg_index]="包索引(pip + uv)"
PY_I18N[zh:install_uv]="安装 uv(用户态,无 sudo)"
PY_I18N[zh:update_uv]="更新 uv(uv self update)"
PY_I18N[zh:remove_uv]="移除 uv 及其数据(缓存/Python/工具)"
PY_I18N[zh:apply_recommended]="应用推荐配置(uv + ruff + PATH)"
PY_I18N[zh:confirm_remove]="移除 Python 开发层(pip/venv/dev)?python3 本身保留。"
PY_I18N[zh:confirm_remove_uv]="移除 uv 及其数据 —— uv 管理的 Python 与 uv 装的工具?此操作不可撤销。"
PY_I18N[zh:foot_main]="↑↓ 移动   space 勾选   ↵ 选择   esc/q 关闭"
PY_I18N[zh:pick_index]="Python —— 包索引镜像"
PY_I18N[zh:type_index]="输入索引 URL…"
PY_I18N[zh:prompt_index]="包索引 URL(…/simple)"
PY_I18N[zh:install_base_first]="请先安装 Python 基础环境(swkit python install)。"
PY_I18N[zh:install_uv_first]="请先安装 uv(swkit python install-uv)。"
PY_I18N[zh:desc_ruff]="linter + 格式化(取代 flake8/black/isort)"
PY_I18N[zh:desc_ty]="Astral 的高速类型检查器(预览)"
PY_I18N[zh:desc_mypy]="静态类型检查器"
PY_I18N[zh:desc_ipython]="增强的交互式 REPL"
PY_I18N[zh:desc_pre-commit]="git pre-commit 钩子框架"
PY_I18N[ja:uv_section]="uv —— モダンなパッケージ/プロジェクト管理"
PY_I18N[ja:dev_tools]="開発ツール(uv tool install)"
PY_I18N[ja:pkg_index]="パッケージインデックス(pip + uv)"
PY_I18N[ja:install_uv]="uv をインストール(ユーザー空間、sudo 不要)"
PY_I18N[ja:update_uv]="uv を更新(uv self update)"
PY_I18N[ja:remove_uv]="uv とそのデータを削除(キャッシュ/Python/ツール)"
PY_I18N[ja:apply_recommended]="推奨セットアップを適用(uv + ruff + PATH)"
PY_I18N[ja:confirm_remove]="Python 開発レイヤ(pip/venv/dev)を削除しますか?python3 本体は保持されます。"
PY_I18N[ja:confirm_remove_uv]="uv とそのデータ(管理下の Python・uv 導入ツール)を削除しますか?元に戻せません。"
PY_I18N[ja:foot_main]="↑↓ 移動   space 切替   ↵ 選択   esc/q 閉じる"
PY_I18N[ja:pick_index]="Python —— パッケージインデックスミラー"
PY_I18N[ja:type_index]="インデックス URL を入力…"
PY_I18N[ja:prompt_index]="パッケージインデックス URL(…/simple)"
PY_I18N[ja:install_base_first]="先に Python ベースをインストールしてください(swkit python install)。"
PY_I18N[ja:install_uv_first]="先に uv をインストールしてください(swkit python install-uv)。"
PY_I18N[ja:desc_ruff]="linter + フォーマッタ(flake8/black/isort を置換)"
PY_I18N[ja:desc_ty]="Astral の高速型チェッカー(プレビュー)"
PY_I18N[ja:desc_mypy]="静的型チェッカー"
PY_I18N[ja:desc_ipython]="高機能な対話 REPL"
PY_I18N[ja:desc_pre-commit]="git pre-commit フックフレームワーク"

# _py_t KEY — localized Python string for $UI_LANG (en/zh/ja), fallback en -> key.
_py_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${PY_I18N[$lang:$1]:-${PY_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=python
name=Python
category=runtime
ops=install,remove,configure,install-uv,remove-uv,update-uv,tools,update-tools
desc=Python dev environment — apt pip/venv/dev + uv (modern manager) + ruff/mypy/…, index mirrors
META
}

# --- Probes (live) -------------------------------------------------------------
# The apt dev layer is present iff python3 is on PATH and pip is usable (python3 alone always is).
_py_base_installed() { have_cmd python3 && python3 -m pip --version >/dev/null 2>&1; }

# Is a curated uv tool installed? `uv tool list` prints "<pkg> v<ver>" lines, but uv may colorize
# them even through a pipe — so force NO_COLOR and strip any residual ANSI before matching, or every
# tool would read as "not installed" (breaking status counts and the ui checklist badges).
_py_tool_installed() {
  have_cmd uv || return 1
  NO_COLOR=1 uv tool list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -qE "^$1 "
}
_py_tool_valid() { [[ -n "${PY_TOOL_PKG[$1]:-}" ]]; }

# Exit 0 iff the apt dev layer is present. Prints python/pip versions + uv version + tool count.
status() {
  _py_base_installed || return 1
  local py pip uvv="-" ntools=0 t
  py="$(python3 --version 2>&1 | awk '{print $2}')"
  pip="$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
  if have_cmd uv; then
    uvv="$(uv --version 2>/dev/null | awk '{print $2}')"
    for t in $PY_TOOLS_ORDER; do _py_tool_installed "$t" && ntools=$(( ntools + 1 )); done
  fi
  printf 'python %s / pip %s  ·  uv %s  ·  tools %d\n' "$py" "$pip" "$uvv" "$ntools"
}

do_install() {
  if _py_base_installed; then
    log_info "Python dev base already present ($(status 2>/dev/null)) — skipping the apt layer."
  else
    # python3 is part of the base system; listing it is a harmless explicit no-op if present.
    apt_install python3 "${PY_ENV_PKGS[@]}"
  fi
  log_info "Base ready. For the modern toolchain (uv + ruff, PATH, completion) run:"
  log_info "    swkit python configure --recommended    (or open: swkit python)"
}

do_remove() {
  if ! _py_base_installed; then
    log_info "Python dev environment is not installed — nothing to remove."
    return 0
  fi
  # Remove ONLY the dev-environment packages — never python3, which the system depends on.
  apt_remove "${PY_ENV_PKGS[@]}"
  log_info "Removed pip/venv/dev. python3 itself is part of the base system and was kept."
  have_cmd uv && log_info "uv is still installed (user-space). Remove it with: ${0##*/} remove-uv"
  return 0
}

# --- User-space guard & rc file ------------------------------------------------
# Refuse a sudo-wrapped run for the user-owned steps (uv, ~/.local/bin, shell rc, pip/uv config).
# apt install/remove escalate per-command via sudo_run and are fine under any user.
_py_user_guard() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run this as your normal user, not via sudo — uv installs to ~/.local/bin and writes your shell rc/config."
    return 1
  fi
}

_py_rc_file() {
  local home="${HOME:-}" shell="${SHELL:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || home="${HOME:-}"
  case "$shell" in */zsh) printf '%s/.zshrc' "$home" ;; *) printf '%s/.bashrc' "$home" ;; esac
}

# Remove a marker-tagged managed line from the shell rc (backs up first). $1 = marker.
_py_rc_strip() {
  local marker="$1" rc tmp; rc="$(_py_rc_file)"
  [[ -f "$rc" ]] && grep -qF "$marker" "$rc" || return 0
  backup_file "$rc"
  tmp="$(mktemp)"
  grep -vF "$marker" "$rc" >"$tmp" || true
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
}

# --- uv lifecycle --------------------------------------------------------------

# Ensure ~/.local/bin on PATH and uv shell completion wired into the rc (idempotent, user-space).
_py_ensure_uv_shell() {
  ensure_local_bin_on_path
  have_cmd uv || return 0
  local rc shellname; rc="$(_py_rc_file)"
  case "${SHELL:-}" in */zsh) shellname=zsh ;; *) shellname=bash ;; esac
  if [[ -f "$rc" ]] && grep -qF "$PY_UVCOMP_MARKER" "$rc"; then return 0; fi
  [[ -s "$rc" ]] && backup_file "$rc"   # back up only a real (non-empty) rc; printf creates it if missing
  # The $(...) must stay literal — it is evaluated at shell startup, not now.
  # shellcheck disable=SC2016
  printf 'eval "$(uv generate-shell-completion %s)" %s\n' "$shellname" "$PY_UVCOMP_MARKER" >>"$rc"
  log_info "Enabled uv shell completion in $rc."
}

# install-uv — install uv via the official user-space script (no sudo). Idempotent.
do_install_uv() {
  _py_user_guard || return 1
  if have_cmd uv; then
    log_info "uv is already installed ($(uv --version 2>/dev/null)) — update with: ${0##*/} update-uv"
    _py_ensure_uv_shell
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates
  log_info "Installing uv (Astral) — user-space into ~/.local/bin, no sudo. Source: $UV_INSTALL_URL"
  curl -LsSf "$UV_INSTALL_URL" | sh
  _py_ensure_uv_shell
  if have_cmd uv; then
    log_info "Installed uv ($(uv --version 2>/dev/null))."
  else
    log_warn "uv was installed to ~/.local/bin — open a new shell (or source your rc) so it is on PATH."
  fi
}

# update-uv — self-update the standalone uv.
do_update_uv() {
  _py_user_guard || return 1
  have_cmd uv || { log_info "uv is not installed — install it first (${0##*/} install-uv)."; return 0; }
  uv self update
}

# remove-uv — complete, user-space uninstall of uv and its data (per the official docs), plus the
# managed rc lines. This deletes uv-managed Pythons and uv-installed tools, so it is explicit only.
do_remove_uv() {
  _py_user_guard || return 1
  if ! have_cmd uv; then
    log_info "uv is not installed."
    _py_rc_strip "$PY_UVCOMP_MARKER"; _py_rc_strip "$PY_UVINDEX_MARKER"
    return 0
  fi
  log_info "Removing uv and its data (cache, managed Pythons, installed tools)…"
  uv cache clean || true
  local d
  d="$(uv python dir 2>/dev/null || true)"; [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  d="$(uv tool dir 2>/dev/null || true)";   [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
  rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
  _py_rc_strip "$PY_UVCOMP_MARKER"; _py_rc_strip "$PY_UVINDEX_MARKER"
  log_info "Removed uv. (Re-install with: ${0##*/} install-uv)"
}

# --- uv tools ------------------------------------------------------------------
_py_install_tool() {
  local key="$1" pkg="${PY_TOOL_PKG[$1]:-}"
  [[ -n "$pkg" ]] || { log_err "Unknown Python tool: $key (known: ${!PY_TOOL_PKG[*]})"; return 2; }
  have_cmd uv || { log_err "$(_py_t install_uv_first)"; return 1; }
  log_info "uv tool install $pkg"
  uv tool install "$pkg"
}
_py_install_tools() {
  local keys="$1" k rc=0
  for k in $keys; do
    _py_tool_valid "$k" || { log_warn "Skipping unknown tool: $k"; continue; }
    _py_install_tool "$k" || rc=$?
  done
  return "$rc"
}

# tools — install the recommended curated uv tools (no-arg op).
do_tools() {
  _py_user_guard || return 1
  have_cmd uv || { log_err "$(_py_t install_uv_first)"; return 1; }
  _py_install_tools "$PY_RECOMMENDED_TOOLS"
}

# update-tools — upgrade all uv-installed tools.
do_update_tools() {
  _py_user_guard || return 1
  have_cmd uv || { log_info "uv is not installed — nothing to update."; return 0; }
  uv tool upgrade --all
}

do_add_tool() {
  _py_user_guard || return 1
  local k="${1:-}"; [[ -n "$k" ]] || { log_err "Usage: ${0##*/} add-tool <${PY_TOOLS_ORDER// /|}>"; return 2; }
  _py_install_tool "$k"
}
do_remove_tool() {
  _py_user_guard || return 1
  local k="${1:-}"; [[ -n "$k" ]] || { log_err "Usage: ${0##*/} remove-tool <name>"; return 2; }
  _py_tool_valid "$k" || { log_err "Unknown Python tool: $k"; return 2; }
  have_cmd uv || { log_info "uv is not installed — nothing to remove."; return 0; }
  if _py_tool_installed "$k"; then
    uv tool uninstall "${PY_TOOL_PKG[$k]}"
    log_info "Removed $k."
  else
    log_info "$k is not installed — nothing to remove."
  fi
}

# --- package index mirror ------------------------------------------------------
# Configure pip (~/.config/pip/pip.conf via `pip config`) and uv (UV_DEFAULT_INDEX in the shell
# rc). 'default' clears both back to PyPI. Accepts a curated preset key or a raw URL.
do_set_index() {
  _py_user_guard || return 1
  local arg="${1:-}"
  [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} set-index <default|tsinghua|aliyun|ustc|URL>"; return 2; }
  local url
  if [[ "$arg" == "default" ]]; then url=""; else url="${PY_INDEX_PRESET[$arg]:-$arg}"; fi

  # Validate a non-empty URL before it touches pip config or the SOURCED shell rc. A double quote
  # (or backtick/$/backslash/newline) would otherwise break out of the rc's "…" assignment and
  # inject a command that runs at every login. Require a plain http(s) index URL, no shell metachars.
  if [[ -n "$url" ]]; then
    if [[ "$url" == *'"'* || "$url" == *'`'* || "$url" == *'$'* || "$url" == *\\* || "$url" == *$'\n'* ]]; then
      log_err "Refusing an index URL containing shell-significant characters (one of: \" \` \$ \\ newline): $url"
      return 2
    fi
    [[ "$url" =~ ^https?:// ]] || { log_err "Index URL must start with http:// or https:// : $url"; return 2; }
  fi

  # pip (user config; no sudo). pip config set/unset writes ~/.config/pip/pip.conf.
  if have_cmd python3 && python3 -m pip --version >/dev/null 2>&1; then
    if [[ -z "$url" ]]; then
      python3 -m pip config unset global.index-url >/dev/null 2>&1 || true
      log_info "pip index reset to PyPI."
    else
      python3 -m pip config set global.index-url "$url" >/dev/null && log_info "pip index-url -> $url"
    fi
  fi

  # uv (managed UV_DEFAULT_INDEX line in the shell rc). _py_rc_strip removes any prior managed line
  # (backing up first if present); the printf below creates the rc if it is missing.
  local rc; rc="$(_py_rc_file)"
  _py_rc_strip "$PY_UVINDEX_MARKER"
  if [[ -n "$url" ]]; then
    printf 'export UV_DEFAULT_INDEX="%s" %s\n' "$url" "$PY_UVINDEX_MARKER" >>"$rc"
    export UV_DEFAULT_INDEX="$url"
    log_info "uv default index -> $url (in $rc; open a new shell to apply)."
  else
    log_info "uv default index reset to PyPI."
  fi
}

# --- configure -----------------------------------------------------------------
# With NO flags: conservative baseline = ensure the apt base is present + ~/.local/bin on PATH.
# --recommended layers on the modern toolchain (uv + ruff).
do_configure() {
  _py_user_guard || return 1
  if [[ $# -eq 0 ]]; then
    _py_base_installed || { log_err "$(_py_t install_base_first)"; return 1; }
    ensure_local_bin_on_path
    return 0
  fi
  while (( $# > 0 )); do
    case "$1" in
      --recommended)
        _py_base_installed || apt_install python3 "${PY_ENV_PKGS[@]}"
        do_install_uv
        _py_install_tools "$PY_RECOMMENDED_TOOLS"
        shift ;;
      --uv)
        [[ $# -ge 2 ]] || { log_err "--uv needs 'on' (install uv); for removal use the explicit 'remove-uv' op."; return 2; }
        case "$2" in
          on)  do_install_uv ;;
          off) log_err "Refusing 'configure --uv off' — removing uv deletes uv-managed Pythons and tools."
               log_err "Run the explicit, self-describing op instead: ${0##*/} remove-uv"; return 2 ;;
          *)   log_err "--uv takes 'on' (for removal use the 'remove-uv' op)."; return 2 ;;
        esac
        shift 2 ;;
      --tools)   [[ $# -ge 2 ]] || { log_err "--tools needs a space-separated list."; return 2; }; _py_install_tools "$2"; shift 2 ;;
      --tools=*) _py_install_tools "${1#--tools=}"; shift ;;
      --index)   [[ $# -ge 2 ]] || { log_err "--index needs a value/preset."; return 2; }; do_set_index "$2"; shift 2 ;;
      --index=*) do_set_index "${1#--index=}"; shift ;;
      -h|--help) usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager: the system dev layer, uv (install/update/remove), uv-installed tools as a
# space-to-toggle checklist, a package-index selector, "Apply recommended setup", and removal.
# State is read live each pass; every change shells out via ui_run then the screen reloads.
# Non-selectable rows (headers, status, spacers) are skipped during navigation. `ui` is an entry
# mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g t
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local base=0 pyver="" pipver="" uv=0 uvver=""
    if _py_base_installed; then
      base=1
      pyver="$(python3 --version 2>&1 | awk '{print $2}')"
      pipver="$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
    fi
    if have_cmd uv; then uv=1; uvver="$(uv --version 2>/dev/null | awk '{print $2}')"; fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! base )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Python dev environment")
    else
      dkind+=(status); did+=(""); dlabel+=("$(printf '%-13s %s' 'python3' "${UI_INFO}${pyver}${UI_OFF}")")
      dkind+=(status); did+=(""); dlabel+=("$(printf '%-13s %s' 'pip'     "${UI_INFO}${pipver}${UI_OFF}")")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_py_t uv_section)")
      if (( uv )); then
        dkind+=(status);    did+=("");          dlabel+=("$(printf '%-13s %s' 'uv' "${UI_INFO}${uvver}${UI_OFF}")")
        dkind+=(uv_update); did+=(uv_update);   dlabel+=("$(ui_badge check) $(_py_t update_uv)")
        dkind+=(uv_remove); did+=(uv_remove);   dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_py_t remove_uv)")
        dkind+=(spacer); did+=(""); dlabel+=("")
        dkind+=(header); did+=(""); dlabel+=("$(_py_t dev_tools)")
        for t in $PY_TOOLS_ORDER; do
          local badge; if _py_tool_installed "$t"; then badge="$(ui_badge installed)"; else badge="$(ui_badge missing)"; fi
          dkind+=(tool); did+=("$t"); dlabel+=("$badge $(printf '%-12s' "$t") ${UI_MUTED}$(_py_t "desc_$t")${UI_OFF}")
        done
      else
        dkind+=(uv_install); did+=(uv_install); dlabel+=("$(ui_badge missing) $(_py_t install_uv)")
      fi
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(index); did+=(index); dlabel+=("$(_py_t pkg_index)  $UI_ARROW")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_py_t apply_recommended)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) (pip/venv/dev)")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( base )); then ui_header "Python" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Python" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_py_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)     ui_run "$(ui_t install) Python" -- "$0" install ;;
          uv_install)  ui_run "$(_py_t install_uv)" -- "$0" install-uv ;;
          uv_update)   ui_run "$(_py_t update_uv)" -- "$0" update-uv ;;
          uv_remove)   ui_confirm "$(_py_t confirm_remove_uv)" n && ui_run "$(_py_t remove_uv)" -- "$0" remove-uv ;;
          tool)
            local k="${did[$sel]}"
            if _py_tool_installed "$k"; then ui_run "remove-tool $k" -- "$0" remove-tool "$k"
            else ui_run "add-tool $k" -- "$0" add-tool "$k"; fi ;;
          index)
            local -a iarg=()
            for t in $PY_INDEX_ORDER; do
              if [[ "$t" == "default" ]]; then iarg+=("$t" "$t  ${UI_MUTED}PyPI${UI_OFF}")
              else iarg+=("$t" "$t  ${UI_MUTED}${PY_INDEX_PRESET[$t]}${UI_OFF}"); fi
            done
            iarg+=(__custom "$(_py_t type_index)")
            if ui_pick "$(_py_t pick_index)" "" "" -- "${iarg[@]}"; then
              if [[ "$UI_PICK" == "__custom" ]]; then
                ui_input "$(_py_t prompt_index)" "" && ui_run "set-index" -- "$0" set-index "$UI_INPUT"
              elif [[ -n "$UI_PICK" ]]; then
                ui_run "set-index $UI_PICK" -- "$0" set-index "$UI_PICK"
              fi
            fi ;;
          recommended) ui_run "$(_py_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_py_t confirm_remove)" n && ui_run "$(ui_t remove) Python" -- "$0" remove ;;
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
  install            Install the system dev layer via apt (python3 + pip + venv + dev). Idempotent.
  remove             Remove pip/venv/dev (apt remove — python3 itself is kept)
  configure [opts]   Set up the dev environment. With no flags: ensure base + ~/.local/bin on PATH.
                       --recommended         base + uv + ruff (the modern toolchain)
                       --uv on               install uv (for removal use the explicit 'remove-uv' op)
                       --tools "<names>"     install the given curated uv tools
                       --index <name|url>    set the pip + uv package index (default|tsinghua|aliyun|ustc|URL)
  install-uv         Install uv (Astral) — user-space into ~/.local/bin, with completion. No sudo.
  remove-uv          Remove uv and its data (cache, managed Pythons, uv-installed tools)
  update-uv          Self-update uv (uv self update)
  tools              Install the recommended uv tools (${PY_RECOMMENDED_TOOLS})
  update-tools       Upgrade all uv-installed tools (uv tool upgrade --all)
  add-tool <name>    Install one curated uv tool (${PY_TOOLS_ORDER// /, })
  remove-tool <name> Uninstall one curated uv tool
  set-index <v>      Set the pip + uv package index (preset name or URL; 'default' clears it)
  status             Print python/pip/uv versions + tool count; exit 0 iff the apt base is present
  ui                 Open the interactive manager (needs a terminal)
  meta               Print machine-readable metadata
  help               Show this help

Notes: uv / tools / configure / set-index run AS YOU (never sudo) — uv installs to ~/.local/bin and
writes your shell rc + pip/uv config. Only the apt install/remove escalates per-command. python3
itself is part of the base system and is never removed.
EOF
}

kit_dispatch "$@"
