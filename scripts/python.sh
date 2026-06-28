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
#   - Python versions      — uv-managed interpreters (uv python install/uninstall/list/upgrade).
#                            Additive `python3.X` by default; an opt-in, reversible `set-default`
#                            makes uv's `python`/`python3` shadow the system one (your interactive
#                            shell only). It NEVER touches /usr/bin/python3, which the OS depends on.
#
# Everything is observed live (no recorded flags): the apt layer via pip, uv via `uv --version`,
# tools via `uv tool list`, managed Pythons via the uv install dir on disk. Re-running converges.
# "Installed" = the apt dev layer is present.
#
# Run it as:  python.sh install|remove|configure|install-uv|remove-uv|update-uv|tools|update-tools|
#             list-versions|upgrade-versions|clear-default|status|meta|ui|help   plus
#             add-tool <name> / remove-tool <name> / set-index <name|url> /
#             install-version <ver|latest> / remove-version <ver> / set-default <ver>.

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
PY_I18N[en:install_env_label]="Python dev environment"
PY_I18N[en:uv_section]="uv — modern package/project manager"
PY_I18N[en:dev_tools]="Dev tools (uv tool install)"
PY_I18N[en:pkg_index]="Package index (pip + uv)"
PY_I18N[en:install_uv]="Install uv (user-space, no sudo)"
PY_I18N[en:update_uv]="Update uv (uv self update)"
PY_I18N[en:remove_uv]="Remove uv + its data (cache/pythons/tools)"
PY_I18N[en:apply_recommended]="Apply recommended setup (uv + ruff + PATH)"
PY_I18N[en:confirm_remove]="Remove the Python dev layer (pip/venv/dev)? python3 itself is kept."
PY_I18N[en:confirm_remove_uv]="Remove uv AND its data — managed Pythons and uv-installed tools? This cannot be undone."
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
PY_I18N[zh:install_env_label]="Python 开发环境"
PY_I18N[zh:uv_section]="uv —— 现代包/项目管理器"
PY_I18N[zh:dev_tools]="开发工具(uv tool install)"
PY_I18N[zh:pkg_index]="包索引(pip + uv)"
PY_I18N[zh:install_uv]="安装 uv(用户态,无 sudo)"
PY_I18N[zh:update_uv]="更新 uv(uv self update)"
PY_I18N[zh:remove_uv]="移除 uv 及其数据(缓存/Python/工具)"
PY_I18N[zh:apply_recommended]="应用推荐配置(uv + ruff + PATH)"
PY_I18N[zh:confirm_remove]="移除 Python 开发层(pip/venv/dev)?python3 本身保留。"
PY_I18N[zh:confirm_remove_uv]="移除 uv 及其数据 —— uv 管理的 Python 与 uv 装的工具?此操作不可撤销。"
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
PY_I18N[ja:install_env_label]="Python 開発環境"
PY_I18N[ja:uv_section]="uv —— モダンなパッケージ/プロジェクト管理"
PY_I18N[ja:dev_tools]="開発ツール(uv tool install)"
PY_I18N[ja:pkg_index]="パッケージインデックス(pip + uv)"
PY_I18N[ja:install_uv]="uv をインストール(ユーザー空間、sudo 不要)"
PY_I18N[ja:update_uv]="uv を更新(uv self update)"
PY_I18N[ja:remove_uv]="uv とそのデータを削除(キャッシュ/Python/ツール)"
PY_I18N[ja:apply_recommended]="推奨セットアップを適用(uv + ruff + PATH)"
PY_I18N[ja:confirm_remove]="Python 開発レイヤ(pip/venv/dev)を削除しますか?python3 本体は保持されます。"
PY_I18N[ja:confirm_remove_uv]="uv とそのデータ(管理下の Python・uv 導入ツール)を削除しますか?元に戻せません。"
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
# --- Python version management (the new component) ---
PY_I18N[en:py_versions]="Python versions (uv-managed)"
PY_I18N[en:install_latest]="Install latest stable"
PY_I18N[en:install_specific]="Install specific version…"
PY_I18N[en:prompt_version]="Python version (e.g. 3.12 or 3.12.8)"
PY_I18N[en:set_default]="Set as default python3 (shadows system)"
PY_I18N[en:clear_default]="Use system python3 (clear uv default)"
PY_I18N[en:confirm_set_default]="Make uv {X} your default python/python3? It shadows the system python3 in your shell (reversible: clear-default)."
PY_I18N[en:confirm_clear_default]="Clear the uv default and fall back to the system python3?"
PY_I18N[en:upgrade_versions]="Upgrade managed Pythons (latest patch · preview)"
PY_I18N[en:tag_default]="default"
PY_I18N[en:invalid_version]="Invalid version (allowed: letters, digits, . @ + -)."
PY_I18N[en:lbl_system]="system"
PY_I18N[en:lbl_shadowing]="shadowing system"
PY_I18N[en:foot_main]="↑↓ move   space toggle   d default   a add   enter select   esc/q close"
PY_I18N[zh:py_versions]="Python 版本(uv 管理)"
PY_I18N[zh:install_latest]="安装最新稳定版"
PY_I18N[zh:install_specific]="安装指定版本…"
PY_I18N[zh:prompt_version]="Python 版本(如 3.12 或 3.12.8)"
PY_I18N[zh:set_default]="设为默认 python3(遮蔽系统)"
PY_I18N[zh:clear_default]="改用系统 python3(清除 uv 默认)"
PY_I18N[zh:confirm_set_default]="将 uv {X} 设为默认 python/python3?会在你的 shell 里遮蔽系统 python3(可撤销:clear-default)。"
PY_I18N[zh:confirm_clear_default]="清除 uv 默认、回退到系统 python3?"
PY_I18N[zh:upgrade_versions]="升级受管 Python(最新补丁版 · 预览)"
PY_I18N[zh:tag_default]="默认"
PY_I18N[zh:invalid_version]="非法版本串(只允许:字母、数字、. @ + -)。"
PY_I18N[zh:lbl_system]="系统"
PY_I18N[zh:lbl_shadowing]="遮蔽系统"
PY_I18N[zh:foot_main]="↑↓ 移动   space 勾选   d 默认   a 添加   ↵ 选择   esc/q 关闭"
PY_I18N[ja:py_versions]="Python バージョン(uv 管理)"
PY_I18N[ja:install_latest]="最新安定版をインストール"
PY_I18N[ja:install_specific]="バージョンを指定してインストール…"
PY_I18N[ja:prompt_version]="Python バージョン(例:3.12 / 3.12.8)"
PY_I18N[ja:set_default]="デフォルト python3 に設定(システムを隠す)"
PY_I18N[ja:clear_default]="システムの python3 を使う(uv デフォルト解除)"
PY_I18N[ja:confirm_set_default]="uv {X} をデフォルト python/python3 にしますか?シェルでシステムの python3 を隠します(取消:clear-default)。"
PY_I18N[ja:confirm_clear_default]="uv デフォルトを解除し、システムの python3 に戻しますか?"
PY_I18N[ja:upgrade_versions]="管理下の Python を更新(最新パッチ · プレビュー)"
PY_I18N[ja:tag_default]="デフォルト"
PY_I18N[ja:invalid_version]="不正なバージョン文字列(使用可:英数字・. @ + -)。"
PY_I18N[ja:lbl_system]="システム"
PY_I18N[ja:lbl_shadowing]="システムを隠す"
PY_I18N[ja:foot_main]="↑↓ 移動   space 切替   d 既定   a 追加   ↵ 選択   esc/q 閉じる"
PY_I18N[en:confirm_remove_version]="Uninstall the uv-managed Python {X}? (re-installable later)"
PY_I18N[zh:confirm_remove_version]="卸载 uv 管理的 Python {X}?(之后可重装)"
PY_I18N[ja:confirm_remove_version]="uv 管理の Python {X} をアンインストールしますか?(後で再インストール可)"

# _py_t KEY — localized Python string for $UI_LANG (en/zh/ja), fallback en -> key.
_py_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${PY_I18N[$lang:$1]:-${PY_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=python
name=Python
category=languages
tags=cli
ops=install,remove,configure,install-uv,remove-uv,update-uv,tools,update-tools,list-versions,upgrade-versions,clear-default
desc=Python dev environment — apt pip/venv/dev + uv (modern manager) + ruff/mypy/…, version mgmt, index mirrors
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

# --- uv-managed Python interpreters (live: read the uv install dir on disk) -----
# A safe version string: a uv request like 3.12 / 3.12.8 / cpython@3.12 — letters, digits, dot,
# at-sign, plus, dash only. Blocks spaces and shell metacharacters before it reaches `uv python …`.
_py_valid_version() { [[ "$1" =~ ^[A-Za-z0-9.@+-]+$ ]]; }

# uv's executable/shim dir (where python3.X and, after set-default, python/python3 live) and the
# install root (where versions are unpacked). Resolved from uv so UV_PYTHON_BIN_DIR etc. are honored.
_py_uv_bin_dir()      { uv python dir --bin 2>/dev/null || printf '%s/.local/bin' "${HOME:-}"; }
_py_uv_install_root() { uv python dir 2>/dev/null; }

# List installed uv-managed CPython/PyPy versions, one X.Y.Z per line, sorted unique. Source of
# truth is the filesystem under the install root (no parsing of `uv python list`, fully offline).
# Skips the minor-version transparent-upgrade dirs (`cpython-3.13-…`), which uv keeps as SYMLINKS
# to the real patch dir — counting both would list 3.13 and 3.13.5 as if they were two installs.
_py_installed_versions() {
  have_cmd uv || return 0
  local root d name ver; root="$(_py_uv_install_root 2>/dev/null || true)"
  [[ -n "$root" && -d "$root" ]] || return 0
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    [[ -L "${d%/}" ]] && continue   # minor-version symlink dir → skip; keep only real patch installs
    name="$(basename "$d")"
    ver="$(printf '%s' "$name" | sed -n 's#^[A-Za-z][A-Za-z]*-\([0-9][0-9.]*\).*#\1#p')"
    [[ -n "$ver" ]] && printf '%s\n' "$ver"
  done | sort -V -u
}
_py_managed_count() { _py_installed_versions | grep -c . || true; }

# Is the `python3` on PATH a uv shim (i.e. shadowing the system one)? Echo the uv version if so,
# nothing otherwise. We resolve the real target and check it lives under the uv INSTALL ROOT (not
# just --bin); fail-closed to "not shadowed" if uv is absent / python3 is not a uv symlink.
_py_default_shadowed() {
  have_cmd uv || return 1
  local p real root ver
  p="$(command -v python3 2>/dev/null)" || return 1
  [[ -n "$p" ]] || return 1
  root="$(_py_uv_install_root 2>/dev/null || true)"; [[ -n "$root" ]] || return 1
  real="$(readlink -f "$p" 2>/dev/null || true)"; [[ -n "$real" ]] || return 1
  [[ "$real" == "$root"/* ]] || return 1
  ver="$(printf '%s' "$real" | sed -n 's#.*/[A-Za-z][A-Za-z]*-\([0-9][0-9.]*\).*#\1#p')"
  printf '%s' "${ver:-?}"
}

# Resolve the newest downloadable stable CPython version (X.Y.Z) from uv's bundled list. Used only
# by the "install latest" convenience; returns non-zero on any parse miss so callers fall back to
# asking for an explicit version. (We never run bare `uv python install`: with no version it reads
# UV_PYTHON / .python-version up the CWD tree, or no-ops if any version is installed — wrong here.)
_py_latest_available() {
  have_cmd uv || return 1
  local v
  v="$(NO_COLOR=1 uv python list --managed-python 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE 'cpython-[0-9]+\.[0-9]+\.[0-9]+-' \
        | sed 's/^cpython-//; s/-$//' \
        | sort -V | tail -n1)"
  [[ -n "$v" ]] && printf '%s' "$v"
}

# Exit 0 iff the apt dev layer is present. Prints python/pip + uv + tool count, a managed-Python
# count, and — only when the system python3 is shadowed by a uv version — that fact.
status() {
  _py_base_installed || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip python/pip/uv spawns
  local py pip uvv="-" ntools=0 t npy=0 shadow=""
  py="$(python3 --version 2>&1 | awk '{print $2}')"
  pip="$(python3 -m pip --version 2>/dev/null | awk '{print $2}')"
  if have_cmd uv; then
    uvv="$(uv --version 2>/dev/null | awk '{print $2}')"
    for t in $PY_TOOLS_ORDER; do _py_tool_installed "$t" && ntools=$(( ntools + 1 )); done
    npy="$(_py_managed_count)"
    shadow="$(_py_default_shadowed || true)"
  fi
  printf 'python %s / pip %s  ·  uv %s  ·  tools %d  ·  pythons %s' "$py" "$pip" "$uvv" "$ntools" "$npy"
  [[ -n "$shadow" ]] && printf '  ·  python3->%s(uv)' "$shadow"
  printf '\n'
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

# --- Python version management (uv-managed interpreters) -----------------------
# All run AS YOU (no sudo) and require uv. They never touch /usr/bin/python3: install-version is
# additive (a versioned python3.X), set-default is an opt-in shadow, clear-default reverts it.
# (list-versions is read-only, so — like status — it does not take the sudo guard.)

# install-version <X.Y[.Z]|latest> — install a uv-managed CPython (additive; versioned exec only).
do_install_version() {
  _py_user_guard || return 1
  local ver="${1:-}"
  [[ -n "$ver" ]] || { log_err "Usage: ${0##*/} install-version <X.Y[.Z]|latest>"; return 2; }
  have_cmd uv || { log_err "$(_py_t install_uv_first)"; return 1; }
  if [[ "$ver" == latest ]]; then
    log_info "Resolving the latest available CPython…"
    ver="$(_py_latest_available || true)"
    [[ -n "$ver" ]] || { log_err "Could not resolve the latest from 'uv python list'. Pass one, e.g. ${0##*/} install-version 3.13"; return 1; }
    log_info "Latest available CPython: $ver"
  fi
  _py_valid_version "$ver" || { log_err "$(_py_t invalid_version) ($ver)"; return 2; }
  log_info "uv python install $ver"
  uv python install "$ver"
  ensure_local_bin_on_path
  log_info "Installed Python $ver (uv). Set it as your default python/python3 with: ${0##*/} set-default $ver"
}

# remove-version <X.Y[.Z]> — uninstall a uv-managed Python (uv matches the request; never system).
do_remove_version() {
  _py_user_guard || return 1
  local ver="${1:-}"
  [[ -n "$ver" ]] || { log_err "Usage: ${0##*/} remove-version <X.Y[.Z]>"; return 2; }
  _py_valid_version "$ver" || { log_err "$(_py_t invalid_version) ($ver)"; return 2; }
  have_cmd uv || { log_info "uv is not installed — nothing to remove."; return 0; }
  log_info "uv python uninstall $ver"
  uv python uninstall "$ver"
}

# list-versions — show uv's installed + downloadable Python versions (read-only).
do_list_versions() {
  have_cmd uv || { log_err "$(_py_t install_uv_first)"; return 1; }
  uv python list
}

# set-default <X.Y[.Z]> — make uv's python/python3 the default, SHADOWING the system python3 for
# your interactive shell (PATH order). Reversible with clear-default. Mirrors remove-uv's guardrails:
# the op runs unattended (headless/LLM-safe) but prints a clear warning; the UI adds a confirm.
# Never passes --force, so a user-placed ~/.local/bin/python* is left for uv to refuse, not clobbered.
do_set_default() {
  _py_user_guard || return 1
  local ver="${1:-}"
  [[ -n "$ver" ]] || { log_err "Usage: ${0##*/} set-default <X.Y[.Z]>"; return 2; }
  _py_valid_version "$ver" || { log_err "$(_py_t invalid_version) ($ver)"; return 2; }
  have_cmd uv || { log_err "$(_py_t install_uv_first)"; return 1; }
  ensure_local_bin_on_path
  log_warn "set-default places ~/.local/bin/{python,python3} that SHADOW /usr/bin/python3 for your"
  log_warn "interactive shell (system services, root and absolute shebangs are unaffected)."
  log_warn "Undo any time with: ${0##*/} clear-default"
  log_info "uv python install $ver --default"
  uv python install "$ver" --default
  log_info "Done. Open a new shell so 'python' / 'python3' resolve to uv $ver."
}

# clear-default — revert set-default: remove ONLY uv-managed bare python/python3 shims, keeping the
# versioned python3.X. Surgical: deletes a shim only if it is a symlink resolving into uv's install
# root; a regular file or a non-uv symlink is left untouched.
do_clear_default() {
  _py_user_guard || return 1
  have_cmd uv || { log_info "uv is not installed — nothing to clear."; return 0; }
  local bindir root f p real removed=0
  bindir="$(_py_uv_bin_dir)"
  root="$(_py_uv_install_root 2>/dev/null || true)"
  for f in python python3; do
    p="$bindir/$f"
    if [[ -L "$p" ]]; then
      real="$(readlink -f "$p" 2>/dev/null || true)"
      if [[ -n "$root" && "$real" == "$root"/* ]]; then
        if rm -f "$p"; then log_info "Removed uv default shim: $p"; removed=1
        else log_warn "Could not remove $p."; fi
      else
        log_warn "$p is a symlink but does not point into uv's install dir — leaving it untouched."
      fi
    elif [[ -e "$p" ]]; then
      log_warn "$p exists but is not a uv-managed symlink — leaving it untouched."
    fi
  done
  if (( removed )); then
    log_info "Cleared the uv default. 'python3' falls back to the system interpreter (open a new shell)."
  else
    log_info "No uv-managed python/python3 shim found — 'python3' is already the system interpreter."
  fi
}

# upgrade-versions — upgrade all uv-managed Pythons to their latest patch release (uv preview).
do_upgrade_versions() {
  _py_user_guard || return 1
  have_cmd uv || { log_info "uv is not installed — nothing to upgrade."; return 0; }
  log_info "uv python upgrade  (latest patch for all managed versions; preview feature)"
  uv python upgrade
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
      --python)           [[ $# -ge 2 ]] || { log_err "--python needs a version (e.g. 3.12 or latest)."; return 2; }; have_cmd uv || do_install_uv; do_install_version "$2"; shift 2 ;;
      --python=*)         have_cmd uv || do_install_uv; do_install_version "${1#--python=}"; shift ;;
      --default-python)   [[ $# -ge 2 ]] || { log_err "--default-python needs a version (e.g. 3.12)."; return 2; }; have_cmd uv || do_install_uv; do_set_default "$2"; shift 2 ;;
      --default-python=*) have_cmd uv || do_install_uv; do_set_default "${1#--default-python=}"; shift ;;
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
    local -a pyvers=(); local pydefault=""
    if (( uv )); then
      mapfile -t pyvers < <(_py_installed_versions)
      pydefault="$(_py_default_shadowed || true)"
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! base )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) $(_py_t install_env_label)")
    else
      dkind+=(status); did+=(""); dlabel+=("$(printf '%-13s %s' 'python3' "${UI_INFO}${pyver}${UI_OFF}")")
      dkind+=(status); did+=(""); dlabel+=("$(printf '%-13s %s' 'pip'     "${UI_INFO}${pipver}${UI_OFF}")")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_py_t uv_section)")
      if (( uv )); then
        dkind+=(status);    did+=("");          dlabel+=("$(printf '%-13s %s' 'uv' "${UI_INFO}${uvver}${UI_OFF}")")
        dkind+=(uv_update); did+=(uv_update);   dlabel+=("$(ui_badge check) $(_py_t update_uv)")
        dkind+=(uv_remove); did+=(uv_remove);   dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_py_t remove_uv)")
        # --- Python versions (uv-managed interpreters) ---
        dkind+=(spacer); did+=(""); dlabel+=("")
        dkind+=(header); did+=(""); dlabel+=("$(_py_t py_versions)")
        if [[ -n "$pydefault" ]]; then
          dkind+=(pydefault); did+=(""); dlabel+=("$(printf '%-13s' 'python3')${UI_INFO}→ uv ${pydefault}${UI_OFF} ${UI_ERR}($(_py_t lbl_shadowing))${UI_OFF}")
        else
          dkind+=(pydefault); did+=(""); dlabel+=("$(printf '%-13s' 'python3')${UI_MUTED}→ $(_py_t lbl_system)${UI_OFF}")
        fi
        local v star
        for v in "${pyvers[@]}"; do
          star=""; [[ -n "$v" && "$v" == "$pydefault" ]] && star=" ${UI_ACCENT}★ $(_py_t tag_default)${UI_OFF}"
          dkind+=(pyver); did+=("$v"); dlabel+=("$(ui_badge installed) $(printf '%-10s' "$v")${star}")
        done
        dkind+=(py_latest);   did+=(py_latest);   dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_py_t install_latest)")
        dkind+=(py_specific); did+=(py_specific); dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_py_t install_specific)")
        if [[ ${#pyvers[@]} -gt 0 ]]; then
          dkind+=(py_upgrade); did+=(py_upgrade); dlabel+=("$(ui_badge check) $(_py_t upgrade_versions)")
        fi
        if [[ -n "$pydefault" ]]; then
          dkind+=(py_clear); did+=(py_clear); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_py_t clear_default)")
        fi
        # --- dev tools ---
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
    case "${dkind[$sel]}" in spacer|header|status|pydefault)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|status|pydefault) ;; *) break ;; esac; done ;;
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
        status|pydefault) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_py_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|status|pydefault) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|status|pydefault) ;; *) break ;; esac; done ;;
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
          pyver)
            local pv="${did[$sel]}" cmsg
            cmsg="$(_py_t confirm_remove_version)"; cmsg="${cmsg//\{X\}/$pv}"
            ui_confirm "$cmsg" n && ui_run "remove-version $pv" -- "$0" remove-version "$pv" ;;
          py_latest)   ui_run "$(_py_t install_latest)" -- "$0" install-version latest ;;
          py_specific) ui_input "$(_py_t prompt_version)" "" && [[ -n "$UI_INPUT" ]] && ui_run "install-version $UI_INPUT" -- "$0" install-version "$UI_INPUT" ;;
          py_upgrade)  ui_run "$(_py_t upgrade_versions)" -- "$0" upgrade-versions ;;
          py_clear)    ui_confirm "$(_py_t confirm_clear_default)" n && ui_run "$(_py_t clear_default)" -- "$0" clear-default ;;
          recommended) ui_run "$(_py_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_py_t confirm_remove)" n && ui_run "$(ui_t remove) Python" -- "$0" remove ;;
        esac ;;
      d)
        if [[ "${dkind[$sel]}" == pyver ]]; then
          local pv="${did[$sel]}" dmsg
          dmsg="$(_py_t confirm_set_default)"; dmsg="${dmsg//\{X\}/$pv}"
          ui_confirm "$dmsg" n && ui_run "set-default $pv" -- "$0" set-default "$pv"
        fi ;;
      a)
        if (( uv )); then
          ui_input "$(_py_t prompt_version)" "" && [[ -n "$UI_INPUT" ]] && ui_run "install-version $UI_INPUT" -- "$0" install-version "$UI_INPUT"
        fi ;;
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
                       --python <ver>        install a uv-managed Python (X.Y[.Z] or 'latest'; additive)
                       --default-python <v>  install it AND make it the default python3 (shadows system)
  install-uv         Install uv (Astral) — user-space into ~/.local/bin, with completion. No sudo.
  remove-uv          Remove uv and its data (cache, managed Pythons, uv-installed tools)
  update-uv          Self-update uv (uv self update)
  tools              Install the recommended uv tools (${PY_RECOMMENDED_TOOLS})
  update-tools       Upgrade all uv-installed tools (uv tool upgrade --all)
  add-tool <name>    Install one curated uv tool (${PY_TOOLS_ORDER// /, })
  remove-tool <name> Uninstall one curated uv tool
  set-index <v>      Set the pip + uv package index (preset name or URL; 'default' clears it)
  install-version <v>  Install a uv-managed Python (X.Y[.Z] or 'latest'); additive 'python3.X'
  remove-version <v>   Uninstall a uv-managed Python
  list-versions      List uv's installed + downloadable Python versions
  set-default <v>    Make uv's python/python3 the default — SHADOWS the system python3 (reversible)
  clear-default      Remove uv's python/python3 shims; revert to the system python3
  upgrade-versions   Upgrade all uv-managed Pythons to their latest patch (uv preview)
  status             Print python/pip/uv + tools + managed-Python count (+ shadow state); exit 0 iff the apt base is present
  ui                 Open the interactive manager (needs a terminal)
  meta               Print machine-readable metadata
  help               Show this help

Notes: uv / tools / configure / set-index / version ops run AS YOU (never sudo) — uv installs to
~/.local/bin and writes your shell rc + pip/uv config. Only the apt install/remove escalates per-command.
/usr/bin/python3 (the OS interpreter) is never touched: install-version is additive, and set-default
only adds ~/.local/bin/{python,python3} shims that shadow it for your shell (undo with clear-default).
EOF
}

kit_dispatch "$@"
