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
# never a recorded flag.
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

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install example (idempotent — skips if already present)
  remove     Uninstall example
  status     Print the version if installed; exit code 0 iff installed
  meta       Print machine-readable metadata (for the TUI / swkit list)
  help       Show this help
EOF
}

kit_dispatch "$@"
