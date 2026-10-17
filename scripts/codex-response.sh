#!/usr/bin/env bash
# Restore the repository's Codex response preferences without migrating accounts.
set -Eeuo pipefail
_response_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_response_root/lib/common.sh"

meta() {
  cat <<'META'
key=codex-response
name=Codex response preferences
category=ai
tags=cli
requires=codex
ops=install,configure,plan
desc=Restore concise, complete replies and hide reasoning events
META
}

_response_run() {
  local interpreter
  for interpreter in python3 python3.14 python3.13 python3.12 python3.11; do
    if command -v "$interpreter" >/dev/null 2>&1 &&
      "$interpreter" -c 'import tomllib' >/dev/null 2>&1; then
      "$interpreter" "$_response_root/lib/codex_response.py" "$@"
      return $?
    fi
  done
  log_err 'Python 3.11+ with tomllib is required; no runtime was installed or changed.'
  return 1
}

status() { _response_run status; }
do_plan() { _response_run plan "$@"; }
do_configure() { _response_run configure "$@"; }
do_install() { do_configure "$@"; }
usage() {
  cat <<'USAGE'
Usage: swkit codex-response <plan|configure|install|status|meta|help|ui>
       configure/install [--no-open] [--codex-home PATH]
       plan [--codex-home PATH]

Requires Python 3.11+ and Codex CLI. install --with-requires can install Codex
through the existing installer; this command never installs Python or logs in.
Targets CODEX_HOME, otherwise ~/.codex. Plan and status do not write files.
configure saves private backups and HTML/JSON reports, opening HTML by default.
Matching settings are not rewritten. Differing response rules block writes.
No automatic restore: compare current files with saved after-files before merging
back the changed section/setting. See skills/codex-response-setup/SKILL.md.
USAGE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  if [[ -n "${SUDO_USER:-}" && "${1:-}" =~ ^(install|configure)$ ]]; then
    log_err 'Run as the target user, without sudo.'
    exit 1
  fi
  kit_dispatch "$@"
fi
