#!/usr/bin/env bash
# Shared global evidence/record rules; implementation travels with the Skill.
set -Eeuo pipefail
_evidence_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_evidence_root/lib/common.sh"
meta() {
  cat <<'META'
key=agent-evidence
name=Agent evidence and record rules
category=ai
tags=cli
ops=install,configure,plan
desc=Merge shared evidence rules and deploy a reusable Codex and Claude Skill
META
}
_evidence_run() {
  local interpreter
  for interpreter in python3 python3.14 python3.13 python3.12 python3.11; do
    if command -v "$interpreter" >/dev/null 2>&1 && "$interpreter" -c 'import tomllib' >/dev/null 2>&1; then
      "$interpreter" "$_evidence_root/skills/agent-evidence-setup/scripts/setup.py" "$@"
      return $?
    fi
  done
  log_err 'Python 3.11+ is required; no interpreter was installed or changed.'
  return 1
}
status() { _evidence_run status; }
do_plan() { _evidence_run plan "$@"; }
do_configure() { _evidence_run configure "$@"; }
do_install() { do_configure "$@"; }
usage() {
  cat <<'USAGE'
Usage: swkit agent-evidence <plan|configure|install|status|meta|help|ui>
       plan/configure [--target codex|claude|both] [--no-open]
       python3 skills/agent-evidence-setup/scripts/setup.py --help

plan/status do not write files or call models. configure preserves existing
instructions, backs up changes privately and writes HTML/JSON reports.
Customized same-name rules or Skills block writes instead of being overwritten.
Loading and behavior require separate new-session verification; see the Skill.
USAGE
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  kit_dispatch "$@"
fi
