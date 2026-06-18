#!/usr/bin/env bash
#
# scripts/go.sh — install / manage the Go toolchain on Ubuntu (apt golang-go).
#
# This installs the Go shipped in Ubuntu's own apt repos (the `golang-go` metapackage, which
# pulls the matching golang-1.x-go toolchain and owns the /usr/bin/go + /usr/bin/gofmt
# symlinks). It is an explicit opt-in runtime. Like scripts/node.sh, it intentionally does NOT
# fetch the tarball from go.dev or add a vendor repo: picking a newer channel is a taste /
# version decision left to a future change to this script in the repo.
#
# Run it as:  go.sh install|remove|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The language name "Go" and the command
# `go` stay UNtranslated; only descriptive wording is localized. Resolve with _go_t KEY.
declare -gA GO_I18N
GO_I18N[en:confirm_remove]="Uninstall Go? (apt remove golang-go)"
GO_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
GO_I18N[en:foot_remove]="↑↓ move   ↵/space uninstall   esc/q close"
GO_I18N[zh:confirm_remove]="卸载 Go?(apt remove golang-go)"
GO_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
GO_I18N[zh:foot_remove]="↑↓ 移动   ↵/space 卸载   esc/q 关闭"
GO_I18N[ja:confirm_remove]="Go をアンインストールしますか?(apt remove golang-go)"
GO_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
GO_I18N[ja:foot_remove]="↑↓ 移動   ↵/space アンインストール   esc/q 閉じる"

# _go_t KEY — localized Go string for $UI_LANG (en/zh/ja), fallback en -> key.
_go_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${GO_I18N[$lang:$1]:-${GO_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=go
name=Go
category=runtime
ops=install,remove
desc=Go programming language toolchain from Ubuntu's apt repos (golang-go)
META
}

# Exit 0 iff the Go toolchain is on PATH; print 'go version …'.
status() {
  have_cmd go && go version
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Go is already installed ($(go version 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install golang-go
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Go is not installed — nothing to remove."
    return 0
  fi
  # Removing the metapackage drops the /usr/bin/go + /usr/bin/gofmt symlinks, so `go` leaves
  # PATH. The versioned golang-1.x-go toolchain it pulled in is left behind (autoremovable) —
  # the kit removes, never purges/autoremoves.
  apt_remove golang-go
}

# --- Interactive management screen (the script's own UI) -----------------------
# A small bespoke full-screen panel: a header showing whether Go is installed (with the
# version on the right), and a single action — Install when missing, Uninstall when present
# (confirmed first). State is read live each pass; the only change shells out via ui_run (so
# apt/sudo output is visible and logged) and then the screen reloads. Limited terminals fall
# back to the synthesized op menu. `ui` is an entry mode (kit_dispatch) — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then installed=1; ver="$(go version 2>/dev/null | awk '{print $3}')"; fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Go")
    else
      dkind+=(remove);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Go")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Go" "$ver $(ui_badge installed)"
    else ui_header "Go" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do ui_row "$row" "$i" "$sel" "${dlabel[$i]}"; (( row++ )); done
    if (( installed )); then ui_footer "$(_go_t foot_remove)"
    else ui_footer "$(_go_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Go" -- "$0" install ;;
          remove)  ui_confirm "$(_go_t confirm_remove)" n && ui_run "$(ui_t remove) Go" -- "$0" remove ;;
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
  install    Install the Go toolchain via apt (golang-go). Idempotent.
  remove     Uninstall Go (apt remove golang-go)
  status     Print 'go version …'; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
