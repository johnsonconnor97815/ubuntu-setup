#!/usr/bin/env bash
# Regression checks for the portable research setup. All Codex writes and CLI
# responses are isolated fixtures; no credentials or network access are needed.
set -Eeuo pipefail

RESEARCH_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESEARCH_TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$RESEARCH_TEST_TMP"' EXIT
command -v jq >/dev/null || { printf 'jq is required for these checks.\n' >&2; exit 1; }
# shellcheck source=../scripts/codex-research.sh
source "$RESEARCH_TEST_ROOT/scripts/codex-research.sh"

_research_home() { printf '%s\n' "$RESEARCH_FIXTURE_CODEX_DIR"; }
have_cmd() {
  [[ "$1" == codex ]] && return 0
  command -v "$1" >/dev/null 2>&1
}

# The native CLI owns config.toml writes. Its fixture keeps an independent JSON
# view, as `codex mcp list/get --json` do, and appends only newly added servers.
_research_codex() {
  printf '%s %s\n' "${1:-}" "${2:-}" >>"$RESEARCH_FIXTURE_CALLS"
  case "${1:-} ${2:-}" in
    '--version ') printf 'codex-cli 0.163.0\n' ;;
    'mcp list')
      [[ -d "$RESEARCH_FIXTURE_CODEX_DIR" ]] || return 1
      cat "$RESEARCH_FIXTURE_STATE"
      ;;
    'mcp get')
      jq -e --arg name "$3" '.[] | select(.name == $name)' "$RESEARCH_FIXTURE_STATE"
      ;;
    'mcp add')
      if [[ "${3:-}" == --help ]]; then
        printf 'Usage: codex mcp add <NAME> --url <URL>\n'
        return 0
      fi
      local server="$3" endpoint="${5:-}"
      [[ "${4:-}" == --url && -n "$endpoint" ]] || return 2
      printf '%s\n' "$server" >>"$RESEARCH_FIXTURE_ADDS"
      if [[ "$server" == "${RESEARCH_FIXTURE_FAIL_ONCE:-}" && ! -e "$RESEARCH_FIXTURE_FAILED" ]]; then
        touch "$RESEARCH_FIXTURE_FAILED"
        printf 'simulated native add failure\n' >&2
        return 1
      fi
      mkdir -p "$RESEARCH_FIXTURE_CODEX_DIR"
      printf '\n[mcp_servers.%s]\nurl = "%s"\n' "$server" "$endpoint" >>"$RESEARCH_FIXTURE_CODEX_DIR/config.toml"
      fixture_server "$server" "$endpoint"
      if [[ "$server" == "${RESEARCH_FIXTURE_FAIL_AFTER_WRITE:-}" ]]; then
        printf 'simulated failure after native config write\n' >&2
        return 1
      fi
      ;;
    *) printf 'unexpected mocked Codex operation\n' >&2; return 2 ;;
  esac
}

fixture() {
  RESEARCH_FIXTURE_DIR="$RESEARCH_TEST_TMP/$1"
  RESEARCH_FIXTURE_CODEX_DIR="$RESEARCH_FIXTURE_DIR/Codex home"
  RESEARCH_FIXTURE_STATE="$RESEARCH_FIXTURE_DIR/servers.json"
  RESEARCH_FIXTURE_ADDS="$RESEARCH_FIXTURE_DIR/adds.txt"
  RESEARCH_FIXTURE_CALLS="$RESEARCH_FIXTURE_DIR/calls.txt"
  RESEARCH_FIXTURE_FAILED="$RESEARCH_FIXTURE_DIR/failed-once"
  RESEARCH_FIXTURE_FAIL_ONCE=''
  RESEARCH_FIXTURE_FAIL_AFTER_WRITE=''
  RESEARCH_FIXTURE_LOG="$RESEARCH_FIXTURE_DIR/run.log"
  mkdir -p "$RESEARCH_FIXTURE_CODEX_DIR"
  printf '[]\n' >"$RESEARCH_FIXTURE_STATE"
  : >"$RESEARCH_FIXTURE_ADDS"
  : >"$RESEARCH_FIXTURE_CALLS"
}

fixture_server() {
  local server="$1" endpoint="$2"
  jq --arg name "$server" --arg url "$endpoint" '
    [.[] | select(.name != $name)] + [{
      name: $name, enabled: true, disabled_reason: null,
      transport: {type: "streamable_http", url: $url,
        bearer_token_env_var: null, http_headers: null, env_http_headers: null},
      startup_timeout_sec: null, tool_timeout_sec: null,
      enabled_tools: null, disabled_tools: []
    }]
  ' "$RESEARCH_FIXTURE_STATE" >"$RESEARCH_FIXTURE_STATE.next"
  mv "$RESEARCH_FIXTURE_STATE.next" "$RESEARCH_FIXTURE_STATE"
}

fixture_edit_servers() {
  jq "$1" "$RESEARCH_FIXTURE_STATE" >"$RESEARCH_FIXTURE_STATE.next"
  mv "$RESEARCH_FIXTURE_STATE.next" "$RESEARCH_FIXTURE_STATE"
}

tree_snapshot() {
  if [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR" ]]; then
    printf 'absent\n'
    return 0
  fi
  (
    cd "$RESEARCH_FIXTURE_CODEX_DIR"
    find . -printf '%P\t%y\t%m\t%T@\n' | LC_ALL=C sort
    find . -type f -exec sha256sum {} + | LC_ALL=C sort
  )
}

configuration_snapshot() {
  (
    cd "$RESEARCH_FIXTURE_CODEX_DIR"
    find . -path './.ubuntu-setup-research-runs' -prune -o -type f -printf '%P\t%m\t%T@\n' | LC_ALL=C sort
    find . -path './.ubuntu-setup-research-runs' -prune -o -type f -exec sha256sum {} + | LC_ALL=C sort
  )
}

latest_report() {
  find "$RESEARCH_FIXTURE_CODEX_DIR/.ubuntu-setup-research-runs" -type f -name report.json -printf '%T@\t%p\n' |
    LC_ALL=C sort -n | tail -n 1 | cut -f 2-
}

complete_report() {
  local report
  report="$(latest_report)" || return 1
  [[ -s "$report" && -s "${report%.json}.html" ]] || return 1
  jq -e '.configuration_complete == true and .connection_verified == false and
    .model_behavior_verified == false and (.changes | type == "array") and
    (.backups | type == "array") and (.pending | type == "array" and length > 0) and
    (.checks | [.exa_mcp, .context7_mcp, .research_skill, .global_rule] |
      all(. == "configured"))' "$report" >/dev/null
}

test_plan_read_only() {
  fixture plan
  rmdir "$RESEARCH_FIXTURE_CODEX_DIR"
  local before
  before="$(tree_snapshot)"
  # The public plan operation deliberately takes no arguments.
  # shellcheck disable=SC2119
  if do_plan >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  rg -q 'Codex home does not exist yet' "$RESEARCH_FIXTURE_LOG" || return 1
  [[ "$(tree_snapshot)" == "$before" && ! -s "$RESEARCH_FIXTURE_CALLS" ]] || return 1
  if status >>"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  [[ "$(tree_snapshot)" == "$before" && ! -s "$RESEARCH_FIXTURE_CALLS" ]]
}

test_install_and_repeat() {
  fixture 'new setup with spaces'
  rmdir "$RESEARCH_FIXTURE_CODEX_DIR"
  if status >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR" && ! -s "$RESEARCH_FIXTURE_CALLS" ]] || return 1
  do_install --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ -s "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" &&
     -s "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/agents/openai.yaml" ]] || return 1
  rg -q 'exa-context7-research' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  jq -e 'length == 2 and ([.[].name] | sort == ["context7", "exa"])' "$RESEARCH_FIXTURE_STATE" >/dev/null || return 1
  complete_report || return 1
  local before adds
  before="$(configuration_snapshot)"
  adds="$(cat "$RESEARCH_FIXTURE_ADDS")"
  do_install --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ "$(configuration_snapshot)" == "$before" && "$(cat "$RESEARCH_FIXTURE_ADDS")" == "$adds" ]] || return 1
  complete_report
}

test_preserve_existing_config() {
  fixture preserve
  cat >"$RESEARCH_FIXTURE_CODEX_DIR/config.toml" <<'CONFIG'
model = "fixture-model"
model_reasoning_effort = "high"

[mcp_servers.exa]
url = "https://mcp.exa.ai/mcp?exaApiKey=fixture-auth-private-marker"
[mcp_servers.exa.http_headers]
Authorization = "fixture-auth-private-marker"
CONFIG
  cp "$RESEARCH_FIXTURE_CODEX_DIR/config.toml" "$RESEARCH_FIXTURE_DIR/config.before"
  fixture_server exa 'https://mcp.exa.ai/mcp?exaApiKey=fixture-auth-private-marker'
  fixture_edit_servers '.[0].transport.http_headers = {Authorization: "fixture-auth-private-marker"}'
  printf 'User global rule must survive.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  chmod 640 "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  local prefix_size report
  prefix_size="$(wc -c <"$RESEARCH_FIXTURE_DIR/config.before")"
  cmp -s "$RESEARCH_FIXTURE_DIR/config.before" <(head -c "$prefix_size" "$RESEARCH_FIXTURE_CODEX_DIR/config.toml") || return 1
  [[ "$(cat "$RESEARCH_FIXTURE_ADDS")" == context7 ]] || return 1
  rg -q '^User global rule must survive\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  [[ "$(stat -c '%a' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")" == 640 ]] || return 1
  report="$(latest_report)" || return 1
  jq -e '.backups | length > 0' "$report" >/dev/null || return 1
  if rg -q 'fixture-auth-private-marker' "$RESEARCH_FIXTURE_LOG" "$report" "${report%.json}.html"; then return 1; fi
  complete_report
}

test_server_conflicts() {
  local kind before
  for kind in disabled endpoint stdio tools tools-query; do
    fixture "conflict-$kind"
    printf 'model = "fixture-model"\n' >"$RESEARCH_FIXTURE_CODEX_DIR/config.toml"
    fixture_server exa https://mcp.exa.ai/mcp
    case "$kind" in
      disabled) fixture_edit_servers '.[0].enabled = false' ;;
      endpoint) fixture_edit_servers '.[0].transport.url = "https://example.invalid/mcp"' ;;
      stdio) fixture_edit_servers '.[0].transport = {type: "stdio", command: "fixture-command", args: []}' ;;
      tools) fixture_edit_servers '.[0].enabled_tools = ["unrelated_tool"]' ;;
      tools-query) fixture_edit_servers '.[0].transport.url = "https://mcp.exa.ai/mcp?tools=agent_run&exaApiKey=fixture-auth-private-marker"' ;;
    esac
    before="$(tree_snapshot)"
    # shellcheck disable=SC2119
    if do_plan >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    [[ "$(tree_snapshot)" == "$before" ]] || return 1
    before="$(configuration_snapshot)"
    if do_install --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    [[ "$(configuration_snapshot)" == "$before" && ! -s "$RESEARCH_FIXTURE_ADDS" ]] || return 1
    if status >>"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    if [[ "$kind" == tools-query ]]; then
      local report
      report="$(latest_report)" || return 1
      if rg -q 'fixture-auth-private-marker' "$RESEARCH_FIXTURE_LOG" "$report" "${report%.json}.html"; then return 1; fi
    fi
  done
}

test_existing_skill_conflict() {
  fixture skill-conflict
  mkdir -p "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research"
  printf 'Unmanaged user skill.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md"
  local before
  before="$(configuration_snapshot)"
  if do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  [[ "$(configuration_snapshot)" == "$before" && ! -s "$RESEARCH_FIXTURE_ADDS" ]]
}

test_override_precedence() {
  fixture override
  printf 'Keep normal global instructions unchanged.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  printf 'Keep override instructions.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  cp -p "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$RESEARCH_FIXTURE_DIR/agents.before"
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  cmp -s "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$RESEARCH_FIXTURE_DIR/agents.before" || return 1
  rg -q '^Keep override instructions\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  rg -q 'exa-context7-research' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1
}

test_empty_override() {
  fixture empty-override
  printf 'Existing global instructions stay effective.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  : >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ ! -s "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" ]] || return 1
  rg -q '^Existing global instructions stay effective\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  rg -q 'exa-context7-research' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1
}

test_whitespace_override() {
  local kind report
  for kind in ascii unicode; do
    fixture "whitespace-override-$kind"
    printf 'Existing global instructions stay effective.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
    if [[ "$kind" == ascii ]]; then
      printf ' \t\r\n\v\f\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
    else
      # Include NBSP, EM SPACE, NARROW NO-BREAK SPACE and IDEOGRAPHIC SPACE.
      printf '\302\240\342\200\203\342\200\257\343\200\200\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
    fi
    cp -p "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" "$RESEARCH_FIXTURE_DIR/override.before"
    do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
    cmp -s "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" "$RESEARCH_FIXTURE_DIR/override.before" || return 1
    rg -q '^Existing global instructions stay effective\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
    rg -q 'exa-context7-research' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
    report="$(latest_report)" || return 1
    jq -e --arg agents "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" '.global_agents == $agents' "$report" >/dev/null || return 1
    status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  done
}

test_original_backup_survives() {
  fixture original-backup
  printf 'model = "fixture-original-model"\n' >"$RESEARCH_FIXTURE_CODEX_DIR/config.toml"
  chmod 640 "$RESEARCH_FIXTURE_CODEX_DIR/config.toml"
  cp -p "$RESEARCH_FIXTURE_CODEX_DIR/config.toml" "$RESEARCH_FIXTURE_DIR/config.before"
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  local report backup found=0
  report="$(latest_report)" || return 1
  while IFS= read -r backup; do
    if [[ -f "$backup" ]] && cmp -s "$backup" "$RESEARCH_FIXTURE_DIR/config.before"; then
      [[ "$(stat -c '%a' "$backup")" == 640 ]] || return 1
      found=1
    fi
  done < <(jq -r '.backups[]' "$report")
  [[ "$found" == 1 ]] || return 1
  complete_report
}

test_existing_oauth_endpoint() {
  fixture oauth
  fixture_server exa https://mcp.exa.ai/mcp
  fixture_server context7 https://mcp.context7.com/mcp/oauth
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ ! -s "$RESEARCH_FIXTURE_ADDS" ]] || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  complete_report
}

test_partial_failure_retry() {
  fixture partial
  RESEARCH_FIXTURE_FAIL_ONCE=context7
  if do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  jq -e 'length == 1 and .[0].name == "exa"' "$RESEARCH_FIXTURE_STATE" >/dev/null || return 1
  if status >>"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  local report
  report="$(latest_report)" || return 1
  jq -e '.configuration_complete == false and .connection_verified == false and
    .model_behavior_verified == false' "$report" >/dev/null || return 1
  do_install --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ "$(rg -c '^exa$' "$RESEARCH_FIXTURE_ADDS")" == 1 &&
     "$(rg -c '^context7$' "$RESEARCH_FIXTURE_ADDS")" == 2 ]] || return 1
  complete_report
}

test_native_error_after_write() {
  fixture native-error-after-write
  RESEARCH_FIXTURE_FAIL_AFTER_WRITE=context7
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  jq -e 'length == 2' "$RESEARCH_FIXTURE_STATE" >/dev/null || return 1
  complete_report
}

test_backup_survives_fast_retry() (
  fixture backup-retry
  printf 'model = "fixture-before-any-add"\n' >"$RESEARCH_FIXTURE_CODEX_DIR/config.toml"
  cp -p "$RESEARCH_FIXTURE_CODEX_DIR/config.toml" "$RESEARCH_FIXTURE_DIR/config.before"
  RESEARCH_FIXTURE_FAIL_ONCE=context7
  # Force backup names based on seconds to collide, without slowing the suite.
  # shellcheck disable=SC2329
  date() {
    if [[ "$*" == +%s ]]; then printf '1700000000\n'; else command date "$@"; fi
  }
  if do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  local report original_backup
  report="$(latest_report)" || return 1
  original_backup="$(jq -r '.backups[0]' "$report")"
  [[ -f "$original_backup" ]] || return 1
  cmp -s "$original_backup" "$RESEARCH_FIXTURE_DIR/config.before" || return 1
  do_install --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  cmp -s "$original_backup" "$RESEARCH_FIXTURE_DIR/config.before" || return 1
  complete_report
)

RESEARCH_TEST_FAILURES=0
run_case() {
  if "$2"; then
    printf 'ok   - %s\n' "$1"
  else
    printf 'FAIL - %s\n' "$1" >&2
    RESEARCH_TEST_FAILURES=$((RESEARCH_TEST_FAILURES + 1))
  fi
}

run_case 'plan and status report a missing target without creating it or calling Codex' test_plan_read_only
run_case 'fresh setup, paths with spaces, complete status, and repeat without rewrites' test_install_and_repeat
run_case 'existing model, authentication, rule content, permissions, and sanitized reports' test_preserve_existing_config
run_case 'disabled, foreign, stdio, and tool-filtered MCP servers including URL filters block configuration writes' test_server_conflicts
run_case 'an existing different skill blocks configuration writes' test_existing_skill_conflict
run_case 'AGENTS.override.md receives the trigger and AGENTS.md stays unchanged' test_override_precedence
run_case 'an empty override stays empty so existing AGENTS.md remains effective' test_empty_override
run_case 'a whitespace-only override stays unchanged so existing AGENTS.md remains effective' test_whitespace_override
run_case 'both server additions preserve the original config backup and permissions' test_original_backup_survives
run_case 'an existing official Context7 OAuth endpoint is preserved' test_existing_oauth_endpoint
run_case 'a native add failure remains incomplete and can be retried safely' test_partial_failure_retry
run_case 'native add failure after a verified config write does not duplicate registration' test_native_error_after_write
run_case 'a retry in the same second cannot overwrite the original recovery backup' test_backup_survives_fast_retry

if (( RESEARCH_TEST_FAILURES )); then
  printf '%s portable research setup check(s) failed.\n' "$RESEARCH_TEST_FAILURES" >&2
  exit 1
fi
printf 'All portable research setup checks passed.\n'
