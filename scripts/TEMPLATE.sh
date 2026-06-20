#!/usr/bin/env bash
#
# scripts/<key>.sh — install / configure / manage <Software> on Ubuntu.
#
# TEMPLATE for the ubuntu-setup script collection. To add software: copy this to
# scripts/<key>.sh and fill in the four required functions (meta, status, do_install,
# do_remove). Add do_configure ONLY if the software has a meaningful, *safe, minimal*
# configuration step — deep/opinionated configuration stays a conversation in the skill.
#
# Every script in this collection:
#   - sources lib/common.sh and composes its helpers, so the project's non-negotiables
#     (idempotency, per-command sudo, non-interactive apt, back-up-before-edit) are met
#     by construction — you rarely write a raw `sudo`/`apt-get` yourself;
#   - is IDEMPOTENT: install/remove check status() first and converge, never accumulate;
#   - is safe to run twice; fails fast (`set -Eeuo pipefail`).
#
# Run it as:  <key>.sh install|remove|configure|status|meta|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# Machine-readable self-description — read by the bootstrap TUI and `swkit list`.
# Hard-code it (this is NOT a data-driven catalog; each script describes only itself).
#   category : essentials | common | ai | runtime   (anything else groups under "other")
#   ops      : MUST list exactly the operations implemented below (install,remove[,configure])
meta() {
  cat <<'META'
key=example
name=Example Tool
category=common
ops=install,remove
desc=One-line description of what this installs
META
}

# Exit 0 iff already installed/active, printing the version/state. The idempotency
# probe — observe the LIVE system (have_cmd / pkg_installed / a version command),
# never a recorded flag. MUST be read-only (no writes / side effects): the catalog
# caches its boolean (lib/cache.sh).
#
# If status is EXPENSIVE (spawns a runtime, scans many files), honor KIT_PROBE_ONLY:
# when it is set, determine the install boolean cheaply and return early, skipping
# version strings / tool enumeration. Both paths MUST return the same exit code. The
# cache/catalog sets KIT_PROBE_ONLY=1; a human `swkit <key> status` does not. Example:
#   status() {
#     have_cmd example || return 1
#     [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # boolean only, skip the spawn below
#     example --version
#   }
status() {
  have_cmd example && example --version
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "example is already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi
  # Channel priority (see lib helpers): apt → vendor apt repo (add_apt_keyring/
  # add_apt_source) → snap → official script → manual binary. Prefer apt.
  apt_install example
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "example is not installed — nothing to remove."
    return 0
  fi
  apt_remove example
}

# Optional — DELETE this whole function if there is no safe configuration step (then
# `configure` will not be offered, and `meta`'s ops must not list it).
# do_configure() {
#   status >/dev/null 2>&1 || { log_info "Install example first."; return 0; }
#   # Minimal, safe, idempotent only. Back up before editing any file: backup_file PATH.
#   :
# }

# --- Interactive management screen (the script's own UI) — OPTIONAL ------------
# `ui` is an ENTRY MODE (like meta/status/help), routed by kit_dispatch — NOT an op:
# it MUST NOT appear in meta's ops= line, and there is no do_ui. Running `<key>.sh ui`
# (or `swkit <key> ui`) on a real terminal opens an interactive manager; with no terminal
# (the LLM's non-interactive shell) kit_dispatch prints how to drive the script by explicit
# op and exits 0 — so you NEVER lose the programmatic op interface.
#
# If you DEFINE NOTHING here, kit_dispatch synthesizes a menu from your meta ops via
# ui_default_menu (status badge + an Install/Remove/Configure list that shells out per op).
# That is enough for most scripts — delete the example below and rely on it.
#
# DEFINE ui() only to hand-write a richer screen with the lib/ui.sh primitives:
#   ui_run TITLE -- cmd...     run a state-changing command with VISIBLE output + a log,
#                              show OK/FAIL, wait for Enter, then re-enter the screen
#   ui_pick TITLE SUB FT -- id label …   single-select submenu (sets UI_PICK)
#   ui_confirm "question?"     yes/no (returns 0/1)
#   ui_input "prompt" [def]    one-line text entry (sets UI_INPUT)
#   ui_notify TITLE BODY       modal info box (any key)
#   ui_badge installed|missing|on|off|check|cross   colored status glyph
#   ui_header/ui_footer/ui_row + ui_read_key (sets UI_KEY: up/down/enter/space/q/esc/backspace/…)
#     for a fully custom screen (write inside it with  >&"$_UI_FD").
# See scripts/zsh.sh for the flagship bespoke ui(). The commented sketch below is the
# minimal shape: a live status header over Install/Remove rows. Uncomment + adapt, or delete.
#
# ui() {
#   # Rich full-screen UI not possible (no /dev/tty or a dumb TERM)? Fall back to the
#   # auto-generated op menu. Returning 0 keeps `ui` a safe no-op entry mode.
#   if ! ui_supported; then ui_default_menu; return 0; fi
#   # Enter the alternate screen; if that fails for any reason, degrade to the op menu.
#   ui_begin || { ui_default_menu; return 0; }
#
#   local sel=0
#   while true; do
#     # Reload the SIGWINCH flag + terminal size each pass (resize-safe).
#     [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
#
#     # ---- gather LIVE status every pass (read-only until the user acts) ----
#     local installed=0 ver=""
#     if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null)"; fi
#
#     # ---- build parallel arrays of selectable rows (id / label) ----
#     local -a did=() dlabel=()
#     if (( ! installed )); then
#       did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) example")
#     else
#       did+=(remove);  dlabel+=("$(ui_badge installed) $(ui_t remove) example")
#       # If you defined do_configure, offer it too:
#       # did+=(configure); dlabel+=("$(ui_t configure) example")
#     fi
#     local n=${#did[@]}
#     (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
#
#     # ---- render: accent header + the rows + a keybind footer ----
#     printf '\033[2J' >&"$_UI_FD"
#     if (( installed )); then ui_header "example" "$ver $(ui_badge check)"
#     else ui_header "example" "$(ui_t not_installed)"; fi
#     local i row=3
#     for (( i=0; i<n; i++ )); do ui_row "$row" "$i" "$sel" "${dlabel[$i]}"; (( row++ )); done
#     ui_footer "$(ui_t nav_list)"
#
#     # ---- one keypress, then act ----
#     ui_read_key
#     case "$UI_KEY" in
#       # Move with sel=$(( ... )); NEVER a bare `(( sel = ... ))`. A standalone (( )) command
#       # returns exit status 1 when its result is 0 (wrap-around to the first row, single-item
#       # lists), and under `set -Eeuo pipefail` that aborts the whole UI on a mere keypress.
#       # The $(( )) assignment form always returns 0, so navigation never trips errexit.
#       up|k)   sel=$(( (sel - 1 + n) % n )) ;;
#       down|j) sel=$(( (sel + 1) % n )) ;;
#       enter|space)
#         # EVERY state change shells back out via ui_run so its output is visible + logged;
#         # the loop then reloads status. Keep it idempotent.
#         case "${did[$sel]}" in
#           install)   ui_run "$(ui_t install) example"   -- "$0" install ;;
#           remove)    ui_confirm "Uninstall example?" n && ui_run "$(ui_t remove) example" -- "$0" remove ;;
#           configure) ui_run "$(ui_t configure) example" -- "$0" configure ;;
#         esac ;;
#       q|Q|esc|backspace) break ;;
#     esac
#   done
#   ui_end   # ALWAYS restore the terminal before returning at a normal exit.
#   return 0
# }

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install example (idempotent — skips if already present)
  remove     Uninstall example
  status     Print the version if installed; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata (for the TUI / swkit list)
  help       Show this help
EOF
}

kit_dispatch "$@"
