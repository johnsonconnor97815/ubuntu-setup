#!/usr/bin/env bash
#
# scripts/go.sh — install / manage a Go development environment on Ubuntu.
#
# Beyond the base toolchain (apt `golang-go`), this manages the things a real Go dev setup
# needs — as components, like scripts/zsh.sh / tmux.sh:
#   - GOBIN on PATH      — `$(go env GOPATH)/bin` (default ~/go/bin) added to your shell rc, so
#                          binaries installed with `go install` are runnable. (User-space.)
#   - the module proxy   — GOPROXY (Go's dependency "package manager" is `go mod`, built in; the
#                          proxy is how it fetches). Curated presets incl. China mirrors; set via
#                          `go env -w` (writes ~/.config/go/env — user-space, never sudo).
#   - curated dev tools  — gopls (LSP), goimports, staticcheck, gofumpt, delve (dlv), golangci-lint;
#                          each `go install …@latest` into GOBIN (user-space, NEVER sudo).
#
# Everything above the apt package is observed live (no recorded flags): GOPROXY via `go env`,
# tools by probing GOBIN, PATH by reading the shell rc. Re-running converges.
#
# Run it as:  go.sh install|remove|configure|tools|update-tools|status|meta|ui|help
#             plus add-tool <name> / remove-tool <name> / set-proxy <name|url>   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- Curated dev tools ---------------------------------------------------------
# key -> module path. Installed via `go install <path>@latest` into GOBIN (~/go/bin), user-space.
# The produced binary name equals the key for every entry below. (golangci-lint also offers a
# pinned official install script; `go install @latest` of its v2 module path is fine for a dev box.)
declare -gA GO_TOOL_PATH=(
  [gopls]="golang.org/x/tools/gopls"
  [goimports]="golang.org/x/tools/cmd/goimports"
  [staticcheck]="honnef.co/go/tools/cmd/staticcheck"
  [gofumpt]="mvdan.cc/gofumpt"
  [dlv]="github.com/go-delve/delve/cmd/dlv"
  [golangci-lint]="github.com/golangci/golangci-lint/v2/cmd/golangci-lint"
)
# Stable display order (associative arrays are unordered).
readonly GO_TOOLS_ORDER="gopls goimports staticcheck gofumpt dlv golangci-lint"
# The `configure --recommended` / `tools` default set (zero-config-friendly, no version pinning).
readonly GO_RECOMMENDED_TOOLS="gopls goimports staticcheck dlv golangci-lint"

# Curated GOPROXY presets: key -> value passed to `go env -w GOPROXY=…` ('default' clears it).
declare -gA GO_PROXY_PRESET=(
  [default]="https://proxy.golang.org,direct"
  [goproxy.cn]="https://goproxy.cn,direct"
  [goproxy.io]="https://goproxy.io,direct"
  [direct]="direct"
)
readonly GO_PROXY_ORDER="default goproxy.cn goproxy.io direct"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The language name "Go", command/tool names
# (go, gopls, dlv, …), GOPROXY values and env keys stay UNtranslated; only descriptive wording is
# localized. Resolve with _go_t KEY (fallback en -> key, like ui_t).
declare -gA GO_I18N
GO_I18N[en:module_proxy]="Module proxy (GOPROXY)"
GO_I18N[en:gobin_path]="GOBIN on PATH (~/go/bin)"
GO_I18N[en:dev_tools]="Dev tools (go install -> ~/go/bin)"
GO_I18N[en:apply_recommended]="Apply recommended setup (PATH + tools)"
GO_I18N[en:confirm_remove]="Uninstall Go? (apt remove golang-go; your ~/go and installed tools are kept)"
GO_I18N[en:foot_main]="up/down move   space toggle   enter select   esc/q close"
GO_I18N[en:pick_proxy]="Go — module proxy (GOPROXY)"
GO_I18N[en:type_proxy]="Type a GOPROXY value…"
GO_I18N[en:prompt_proxy]="GOPROXY (comma-separated, e.g. https://goproxy.cn,direct)"
GO_I18N[en:not_installed_first]="Install Go first (swkit go install)."
GO_I18N[en:desc_gopls]="official language server (LSP) for editors"
GO_I18N[en:desc_goimports]="format code + auto-manage imports"
GO_I18N[en:desc_staticcheck]="deep static analysis / linter"
GO_I18N[en:desc_gofumpt]="stricter gofmt"
GO_I18N[en:desc_dlv]="Delve — the Go debugger"
GO_I18N[en:desc_golangci-lint]="fast multi-linter aggregator"
GO_I18N[zh:module_proxy]="模块代理(GOPROXY)"
GO_I18N[zh:gobin_path]="GOBIN 加入 PATH(~/go/bin)"
GO_I18N[zh:dev_tools]="开发工具(go install -> ~/go/bin)"
GO_I18N[zh:apply_recommended]="应用推荐配置(PATH + 工具)"
GO_I18N[zh:confirm_remove]="卸载 Go?(apt remove golang-go;保留你的 ~/go 与已装工具)"
GO_I18N[zh:foot_main]="↑↓ 移动   space 勾选   ↵ 选择   esc/q 关闭"
GO_I18N[zh:pick_proxy]="Go — 模块代理(GOPROXY)"
GO_I18N[zh:type_proxy]="输入 GOPROXY 值…"
GO_I18N[zh:prompt_proxy]="GOPROXY(逗号分隔,如 https://goproxy.cn,direct)"
GO_I18N[zh:not_installed_first]="请先安装 Go(swkit go install)。"
GO_I18N[zh:desc_gopls]="官方语言服务器(LSP),供编辑器使用"
GO_I18N[zh:desc_goimports]="格式化代码 + 自动管理 import"
GO_I18N[zh:desc_staticcheck]="深度静态分析 / linter"
GO_I18N[zh:desc_gofumpt]="更严格的 gofmt"
GO_I18N[zh:desc_dlv]="Delve —— Go 调试器"
GO_I18N[zh:desc_golangci-lint]="快速的多 linter 聚合器"
GO_I18N[ja:module_proxy]="モジュールプロキシ(GOPROXY)"
GO_I18N[ja:gobin_path]="GOBIN を PATH に追加(~/go/bin)"
GO_I18N[ja:dev_tools]="開発ツール(go install -> ~/go/bin)"
GO_I18N[ja:apply_recommended]="推奨セットアップを適用(PATH + ツール)"
GO_I18N[ja:confirm_remove]="Go をアンインストールしますか?(apt remove golang-go;~/go と導入済みツールは保持)"
GO_I18N[ja:foot_main]="↑↓ 移動   space 切替   ↵ 選択   esc/q 閉じる"
GO_I18N[ja:pick_proxy]="Go — モジュールプロキシ(GOPROXY)"
GO_I18N[ja:type_proxy]="GOPROXY の値を入力…"
GO_I18N[ja:prompt_proxy]="GOPROXY(カンマ区切り、例 https://goproxy.cn,direct)"
GO_I18N[ja:not_installed_first]="先に Go をインストールしてください(swkit go install)。"
GO_I18N[ja:desc_gopls]="エディタ向け公式 Language Server (LSP)"
GO_I18N[ja:desc_goimports]="コード整形 + import 自動管理"
GO_I18N[ja:desc_staticcheck]="高度な静的解析 / linter"
GO_I18N[ja:desc_gofumpt]="より厳格な gofmt"
GO_I18N[ja:desc_dlv]="Delve —— Go デバッガ"
GO_I18N[ja:desc_golangci-lint]="高速なマルチ linter アグリゲータ"

# _go_t KEY — localized Go string for $UI_LANG (en/zh/ja), fallback en -> key.
_go_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${GO_I18N[$lang:$1]:-${GO_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=go
name=Go
category=languages
tags=cli
ops=install,remove,configure,tools,update-tools
desc=Go dev environment — apt golang-go + GOPROXY, GOBIN-on-PATH, curated tools (gopls/dlv/golangci-lint…)
META
}

# GOBIN: where `go install` drops binaries. Prefer `go env`; fall back to the documented default.
_go_gobin() {
  local b=""
  if have_cmd go; then
    b="$(go env GOBIN 2>/dev/null || true)"
    [[ -n "$b" ]] || b="$(go env GOPATH 2>/dev/null || true)/bin"
  fi
  [[ -n "$b" && "$b" != /bin ]] || b="${HOME:-/root}/go/bin"
  printf '%s' "$b"
}

readonly GO_PATH_MARKER="# ubuntu-setup (go tools on PATH)"

# The user's shell rc file (honors SUDO_USER's real home; never edits another user's dotfile).
_go_rc_file() {
  local home="${HOME:-}" shell="${SHELL:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || home="${HOME:-}"
  case "$shell" in */zsh) printf '%s/.zshrc' "$home" ;; *) printf '%s/.bashrc' "$home" ;; esac
}

# Is GOBIN currently reachable (on $PATH now, or a managed line already in the rc)?
_go_path_on() {
  local gobin rc; gobin="$(_go_gobin)"
  case ":$PATH:" in *":$gobin:"*) return 0 ;; esac
  rc="$(_go_rc_file)"
  [[ -f "$rc" ]] && grep -qF "$GO_PATH_MARKER" "$rc"
}

_go_tool_installed() { local t="$1" gobin; gobin="$(_go_gobin)"; [[ -x "$gobin/$t" ]]; }
_go_tool_valid()     { [[ -n "${GO_TOOL_PATH[$1]:-}" ]]; }

# Exit 0 iff the Go toolchain is on PATH. Prints a one-line summary: version, GOPROXY, the count
# of curated tools present, and whether GOBIN is on PATH.
status() {
  have_cmd go || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip go version/env spawns
  local ver proxy gobin n=0 t total=0 path_ok="no"
  ver="$(go version 2>/dev/null | awk '{print $3}')"
  proxy="$(go env GOPROXY 2>/dev/null || true)"
  gobin="$(_go_gobin)"
  for t in $GO_TOOLS_ORDER; do total=$(( total + 1 )); [[ -x "$gobin/$t" ]] && n=$(( n + 1 )); done
  _go_path_on && path_ok="yes"
  printf '%s  ·  GOPROXY=%s  ·  tools %d/%d  ·  PATH:%s\n' "$ver" "${proxy:-?}" "$n" "$total" "$path_ok"
}

do_install() {
  if have_cmd go; then
    log_info "Go is already installed ($(go version 2>/dev/null)) — skipping the toolchain."
  else
    apt_install golang-go
  fi
  log_info "Toolchain ready. For the full dev environment (GOBIN on PATH + gopls/dlv/golangci-lint…) run:"
  log_info "    swkit go configure --recommended    (or open: swkit go)"
}

do_remove() {
  if ! have_cmd go; then
    log_info "Go is not installed — nothing to remove."
    return 0
  fi
  # Removing the metapackage drops the /usr/bin/go + /usr/bin/gofmt symlinks, so `go` leaves PATH.
  # We keep ~/go (modules cache + installed tool binaries) — conservative, like the rest of the kit.
  apt_remove golang-go
  log_info "Removed the Go toolchain. Your ~/go (tools + module cache) and ~/.config/go/env are kept."
}

# --- User-space guard ----------------------------------------------------------
# Refuse a sudo-wrapped run for the user-owned config steps (go env, shell rc, GOBIN): they must
# stay owned by the real user. apt install/remove escalate per-command via sudo_run and are fine.
_go_user_guard() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run this as your normal user, not via sudo — it touches your ~/.config/go and shell rc."
    return 1
  fi
}

# go install <module>@latest, as the user, into GOBIN. Needs the toolchain + network.
_go_install_tool() {
  local key="$1" path="${GO_TOOL_PATH[$1]:-}"
  [[ -n "$path" ]] || { log_err "Unknown Go tool: $key (known: ${!GO_TOOL_PATH[*]})"; return 2; }
  have_cmd go || { log_err "$(_go_t not_installed_first)"; return 1; }
  log_info "go install ${path}@latest  ->  $(_go_gobin)/${key}"
  go install "${path}@latest"
}

# install the curated dev tools listed in $1 (space-separated keys); validates each first.
_go_install_tools() {
  local keys="$1" k rc=0
  for k in $keys; do
    _go_tool_valid "$k" || { log_warn "Skipping unknown tool: $k"; continue; }
    _go_install_tool "$k" || rc=$?
  done
  return "$rc"
}

# --- configure / actions -------------------------------------------------------

# Persist GOPROXY via Go's own config (~/.config/go/env). 'default' clears the override
# (reverts to Go's built-in default). Accepts a curated preset key or a raw value.
do_set_proxy() {
  _go_user_guard || return 1
  have_cmd go || { log_err "$(_go_t not_installed_first)"; return 1; }
  local arg="${1:-}"
  [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} set-proxy <default|goproxy.cn|goproxy.io|direct|URL>"; return 2; }
  if [[ "$arg" == "default" ]]; then
    go env -u GOPROXY
    log_info "GOPROXY reset to Go's built-in default ($(go env GOPROXY 2>/dev/null))."
    return 0
  fi
  local val="${GO_PROXY_PRESET[$arg]:-$arg}"
  go env -w "GOPROXY=$val"
  log_info "Set GOPROXY=$val (in $(go env GOENV 2>/dev/null || echo ~/.config/go/env))."
}

# Add ($1=on, default) or remove ($1=off) the managed GOBIN-on-PATH line in the shell rc.
do_ensure_path() {
  _go_user_guard || return 1
  local mode="${1:-on}" rc gobin line
  rc="$(_go_rc_file)"; gobin="$(_go_gobin)"
  case "$mode" in
    on)
      export PATH="$gobin:$PATH"
      line="export PATH=\"$gobin:\$PATH\" $GO_PATH_MARKER"
      if [[ -f "$rc" ]] && grep -qF "$GO_PATH_MARKER" "$rc"; then
        log_info "GOBIN already on PATH via $rc — nothing to do."
        return 0
      fi
      [[ -s "$rc" ]] && backup_file "$rc"   # back up only a real (non-empty) rc; printf creates it if missing
      printf '%s\n' "$line" >>"$rc"
      log_info "Added $gobin to PATH in $rc — open a new shell or 'source $rc'."
      ;;
    off)
      if [[ ! -f "$rc" ]] || ! grep -qF "$GO_PATH_MARKER" "$rc"; then
        log_info "No managed GOBIN PATH line in $rc — nothing to remove."
        return 0
      fi
      backup_file "$rc"
      local tmp; tmp="$(mktemp)"
      grep -vF "$GO_PATH_MARKER" "$rc" >"$tmp" || true
      mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
      log_info "Removed the managed GOBIN PATH line from $rc."
      ;;
    *) log_err "ensure-path takes on|off."; return 2 ;;
  esac
}

# configure: apply flags; with NO flags, the conservative baseline = put GOBIN on PATH (so the
# tools you `go install` are runnable). --recommended layers on the curated tool set.
do_configure() {
  _go_user_guard || return 1
  have_cmd go || { log_err "$(_go_t not_installed_first)"; return 1; }
  if [[ $# -eq 0 ]]; then
    do_ensure_path on
    return 0
  fi
  while (( $# > 0 )); do
    case "$1" in
      --recommended)
        do_ensure_path on
        _go_install_tools "$GO_RECOMMENDED_TOOLS"
        shift ;;
      --goproxy)   [[ $# -ge 2 ]] || { log_err "--goproxy needs a value/preset."; return 2; }; do_set_proxy "$2"; shift 2 ;;
      --goproxy=*) do_set_proxy "${1#--goproxy=}"; shift ;;
      --tools)     [[ $# -ge 2 ]] || { log_err "--tools needs a space-separated list."; return 2; }; _go_install_tools "$2"; shift 2 ;;
      --tools=*)   _go_install_tools "${1#--tools=}"; shift ;;
      --ensure-path)   [[ $# -ge 2 ]] || { log_err "--ensure-path needs on|off."; return 2; }; do_ensure_path "$2"; shift 2 ;;
      --ensure-path=*) do_ensure_path "${1#--ensure-path=}"; shift ;;
      -h|--help) usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done
}

# tools — install the recommended curated dev tools (no-arg op).
do_tools() {
  _go_user_guard || return 1
  have_cmd go || { log_err "$(_go_t not_installed_first)"; return 1; }
  _go_install_tools "$GO_RECOMMENDED_TOOLS"
}

# update-tools — re-`go install @latest` every curated tool that is currently installed.
do_update_tools() {
  _go_user_guard || return 1
  have_cmd go || { log_err "$(_go_t not_installed_first)"; return 1; }
  local t any=0 rc=0
  for t in $GO_TOOLS_ORDER; do
    if _go_tool_installed "$t"; then any=1; _go_install_tool "$t" || rc=$?; fi
  done
  (( any )) || log_info "No curated Go tools are installed yet — add them with: ${0##*/} tools"
  return "$rc"
}

# add-tool <key> / remove-tool <key> — manage a single curated tool (parametric; ui-reachable).
do_add_tool() {
  _go_user_guard || return 1
  local k="${1:-}"; [[ -n "$k" ]] || { log_err "Usage: ${0##*/} add-tool <${GO_TOOLS_ORDER// /|}>"; return 2; }
  _go_install_tool "$k"
}
do_remove_tool() {
  _go_user_guard || return 1
  local k="${1:-}"; [[ -n "$k" ]] || { log_err "Usage: ${0##*/} remove-tool <name>"; return 2; }
  _go_tool_valid "$k" || { log_err "Unknown Go tool: $k"; return 2; }
  local gobin; gobin="$(_go_gobin)"
  if [[ -x "$gobin/$k" ]]; then
    rm -f "$gobin/$k"
    log_info "Removed $gobin/$k."
  else
    log_info "$k is not installed in $gobin — nothing to remove."
  fi
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager: GOBIN-on-PATH toggle, a GOPROXY selector, the curated dev tools as a
# space-to-toggle checklist, an "Apply recommended setup" action, and Uninstall. State is read
# live each pass; every change shells out via ui_run (visible + logged) then the screen reloads.
# Non-selectable rows (headers, spacers) are skipped during navigation. `ui` is an entry mode
# (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g t
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" proxy="" path_ok=0
    if have_cmd go; then
      installed=1
      ver="$(go version 2>/dev/null | awk '{print $3}')"
      proxy="$(go env GOPROXY 2>/dev/null || true)"
      _go_path_on && path_ok=1
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Go")
    else
      local pbadge; if (( path_ok )); then pbadge="$(ui_badge on)"; else pbadge="$(ui_badge off)"; fi
      dkind+=(path); did+=(path); dlabel+=("$pbadge $(_go_t gobin_path)")
      dkind+=(proxy); did+=(proxy); dlabel+=("$(_go_t module_proxy): ${UI_INFO}${proxy:-default}${UI_OFF}  $UI_ARROW")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_go_t dev_tools)")
      for t in $GO_TOOLS_ORDER; do
        local badge; if _go_tool_installed "$t"; then badge="$(ui_badge installed)"; else badge="$(ui_badge missing)"; fi
        dkind+=(tool); did+=("$t"); dlabel+=("$badge $(printf '%-14s' "$t") ${UI_MUTED}$(_go_t "desc_$t")${UI_OFF}")
      done
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_go_t apply_recommended)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Go")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Go" "$ver $(ui_badge installed)"
    else ui_header "Go" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_go_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)     ui_run "$(ui_t install) Go" -- "$0" install ;;
          path)        if (( path_ok )); then ui_run "GOBIN PATH off" -- "$0" configure --ensure-path off
                       else ui_run "GOBIN PATH on" -- "$0" configure --ensure-path on; fi ;;
          proxy)
            local -a parg=()
            for t in $GO_PROXY_ORDER; do parg+=("$t" "$t  ${UI_MUTED}${GO_PROXY_PRESET[$t]}${UI_OFF}"); done
            parg+=(__custom "$(_go_t type_proxy)")
            if ui_pick "$(_go_t pick_proxy)" "" "" -- "${parg[@]}"; then
              if [[ "$UI_PICK" == "__custom" ]]; then
                ui_input "$(_go_t prompt_proxy)" "$proxy" && ui_run "set-proxy" -- "$0" set-proxy "$UI_INPUT"
              elif [[ -n "$UI_PICK" ]]; then
                ui_run "set-proxy $UI_PICK" -- "$0" set-proxy "$UI_PICK"
              fi
            fi ;;
          tool)
            local k="${did[$sel]}"
            if _go_tool_installed "$k"; then ui_run "remove-tool $k" -- "$0" remove-tool "$k"
            else ui_run "add-tool $k" -- "$0" add-tool "$k"; fi ;;
          recommended) ui_run "$(_go_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_go_t confirm_remove)" n && ui_run "$(ui_t remove) Go" -- "$0" remove ;;
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
  install            Install the Go toolchain via apt (golang-go). Idempotent.
  remove             Uninstall Go (apt remove golang-go; keeps ~/go and installed tools)
  configure [opts]   Set up the dev environment. With no flags: put GOBIN (~/go/bin) on PATH.
                       --recommended            PATH + install the recommended dev tools
                       --goproxy <name|url>     set GOPROXY (default|goproxy.cn|goproxy.io|direct|URL)
                       --tools "<names>"        install the given curated tools
                       --ensure-path on|off     add/remove the GOBIN PATH line in your shell rc
  tools              Install the recommended dev tools (gopls goimports staticcheck dlv golangci-lint)
  update-tools       Re-install (@latest) every curated tool you already have
  add-tool <name>    Install one curated tool (${GO_TOOLS_ORDER// /, })
  remove-tool <name> Remove one curated tool binary from ~/go/bin
  ensure-path on|off Add/remove the GOBIN (~/go/bin) PATH line in your shell rc
  set-proxy <v>      Set GOPROXY (preset name or raw value; 'default' clears the override)
  status             Print version + GOPROXY + tool count + PATH state; exit 0 iff Go installed
  ui                 Open the interactive manager (needs a terminal)
  meta               Print machine-readable metadata
  help               Show this help

Notes: configure / tools / set-proxy run AS YOU (never sudo) — they touch ~/.config/go and your
shell rc, and 'go install' writes to ~/go/bin. Only the apt install/remove escalates per-command.
EOF
}

kit_dispatch "$@"
