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
    ui_footer "↑↓ move   ↵/space select   esc/q close"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   sel=$(( (sel - 1 + n) % n )) ;;
      down|j) sel=$(( (sel + 1) % n )) ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            ui_pick "Codex CLI — $(ui_t install)" "Choose an installation method" "" -- \
              native "native (official installer, no Node)" \
              npm    "npm (@openai/codex, needs Node >= ${CODEX_NODE_MIN_MAJOR})"
            if [[ -n "$UI_PICK" ]]; then
              ui_run "$(ui_t install) Codex CLI ($UI_PICK)" -- "$0" install --method "$UI_PICK"
              if [[ "${UI_RUN_RC:-1}" == 0 ]] && status >/dev/null 2>&1; then
                ui_notify "Codex CLI installed" \
                  "Open a new shell (or 'source ~/.profile'), then run 'codex' to sign in."
              fi
            fi ;;
          remove)
            ui_confirm "Uninstall the Codex CLI?" n && \
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
