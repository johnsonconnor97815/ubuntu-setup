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
    .global_rules_loaded == false and .model_behavior_verified == false and (.changes | type == "array") and
    (.backups | type == "array") and (.pending | type == "array" and length > 0) and
    (.checks | [.exa_mcp, .context7_mcp, .global_rules, .legacy_skill_cleanup] |
      all(. == "configured"))' "$report" >/dev/null
}

full_rules_present() {
  jq -en --rawfile actual "$1" \
    --rawfile rules "$RESEARCH_TEST_ROOT/skills/codex-research-setup/assets/research-rules.md" \
    '$actual | contains($rules) and (contains("exa-context7-research") | not)' >/dev/null
}

configuration_tree_snapshot() {
  (
    cd "$RESEARCH_FIXTURE_CODEX_DIR"
    find . -mindepth 1 -path './.ubuntu-setup-research-runs' -prune -o -mindepth 1 \
      -printf '%P\t%y\t%m\t%T@\t%l\n' | LC_ALL=C sort
    find . -path './.ubuntu-setup-research-runs' -prune -o -type f -exec sha256sum {} + | LC_ALL=C sort
  )
}

# Immutable snapshots reproduce the published deployment, not the current rules.
fixture_legacy_skill() {
  local relative
  for relative in SKILL.md agents/openai.yaml; do
    mkdir -p "$(dirname "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/$relative")"
    cp -p "$RESEARCH_TEST_ROOT/test/fixtures/codex-research-legacy/$relative.snapshot" \
      "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/$relative"
  done
}

fixture_legacy_block() {
  local style="${1:-angle}" line
  line="$(jq -nr --arg home "$RESEARCH_FIXTURE_CODEX_DIR" \
    --rawfile text "$RESEARCH_TEST_ROOT/skills/codex-research-setup/assets/legacy-research-trigger.txt" \
    '$text | split("{{CODEX_HOME}}") | join($home) | rtrimstr("\n")')"
  if [[ "$style" == plain ]]; then line="$(sed 's/](</](/; s/>)/)/' <<<"$line")"; fi
  printf '<!-- ubuntu-setup:codex-research:start -->\n## 外部事实查证\n\n%s\n<!-- ubuntu-setup:codex-research:end -->\n' "$line"
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
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR/skills" ]] || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
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
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1
}

test_empty_override() {
  fixture empty-override
  printf 'Existing global instructions stay effective.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  : >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  do_install --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ ! -s "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" ]] || return 1
  rg -q '^Existing global instructions stay effective\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
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
    full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
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

legacy_archive_matches() {
  local report archive manifest relative
  report="$(latest_report)" || return 1
  archive="$(jq -r '.retired_skill_paths | select(length == 1) | .[0]' "$report")" || return 1
  manifest="$(jq -r '.recovery_manifest' "$report")" || return 1
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research" && -d "$archive" && -f "$manifest" ]] || return 1
  [[ "$(stat -c %a "$(dirname "$manifest")")" == 700 ]] || return 1
  for relative in SKILL.md agents/openai.yaml; do
    cmp -s "$RESEARCH_TEST_ROOT/test/fixtures/codex-research-legacy/$relative.snapshot" "$archive/$relative" || return 1
  done
  jq -e '.legacy_skill.status == "retired" and
    all(.global_files[]; .status == "written" and (.before_sha256 | length == 64) and
      (.after_sha256 | length == 64) and (.original_metadata | type == "string"))' "$manifest" >/dev/null || return 1
  complete_report
}

fixture_legacy_setup() {
  fixture_legacy_skill
  fixture_server exa https://mcp.exa.ai/mcp
  fixture_server context7 https://mcp.context7.com/mcp
  fixture_legacy_block >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
}

test_legacy_migration() {
  local style prefix after report backup
  for style in angle plain; do
    fixture "migration-$style"
    fixture_legacy_setup
    {
      printf 'Keep user instructions before.\n\n'
      fixture_legacy_block "$style"
      printf '\nKeep user instructions after without final newline.'
    } >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
    cp -p "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$RESEARCH_FIXTURE_DIR/agents.before"
    chmod 640 "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
    prefix="$(configuration_tree_snapshot)"
    # shellcheck disable=SC2119
    do_plan >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
    [[ "$(configuration_tree_snapshot)" == "$prefix" ]] || return 1
    do_configure --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
    full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
    [[ "$(head -n 1 "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")" == 'Keep user instructions before.' &&
       "$(tail -n 1 "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")" == 'Keep user instructions after without final newline.' &&
       "$(stat -c %a "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")" == 640 && ! -s "$RESEARCH_FIXTURE_ADDS" ]] || return 1
    legacy_archive_matches || return 1
    report="$(latest_report)"
    backup="$(jq -r '.global_files[0].backup' "$(jq -r .recovery_manifest "$report")")"
    cmp -s "$RESEARCH_FIXTURE_DIR/agents.before" "$backup" || return 1
    after="$(configuration_tree_snapshot)"
    do_configure --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
    [[ "$(configuration_tree_snapshot)" == "$after" ]] || return 1
    complete_report || return 1
  done
}

test_two_global_legacy_migration() {
  fixture both-global-legacy
  fixture_legacy_setup
  {
    printf 'Keep active override instructions.\n'
    fixture_legacy_block plain
  } >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  rg -q '^Keep active override instructions\.$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  legacy_archive_matches || return 1
  jq -e '.global_files | length == 2' "$(jq -r .recovery_manifest "$(latest_report)")" >/dev/null
}

test_legacy_tree_conflicts() {
  local kind before root
  for kind in modified missing extra-file hidden extra-directory symlink dangling; do
    fixture "legacy-tree-$kind"
    fixture_legacy_setup
    root="$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research"
    case "$kind" in
      modified) printf 'User customization.\n' >>"$root/SKILL.md" ;;
      missing) mv "$root/agents/openai.yaml" "$RESEARCH_FIXTURE_DIR/user-kept-yaml" ;;
      extra-file) printf 'User data.\n' >"$root/user.txt" ;;
      hidden) printf 'User data.\n' >"$root/.user-note" ;;
      extra-directory) mkdir "$root/custom" ;;
      symlink) ln -s "$root/SKILL.md" "$root/user-link" ;;
      dangling) ln -s "$root/missing-file" "$root/user-link" ;;
    esac
    before="$(configuration_tree_snapshot)"
    if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    [[ "$(configuration_tree_snapshot)" == "$before" && -d "$root" && ! -s "$RESEARCH_FIXTURE_ADDS" ]] || return 1
    jq -e '.outcome == "blocked" and .checks.legacy_skill_cleanup == "conflict" and
      (.retired_skill_paths | length == 0)' "$(latest_report)" >/dev/null || return 1
  done
}

test_legacy_block_conflicts() {
  local kind before original
  for kind in changed duplicate missing-end nested bare-line wrong-home outside-reference; do
    fixture "legacy-block-$kind"
    fixture_legacy_setup
    original="$RESEARCH_FIXTURE_DIR/block.original"
    cp "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$original"
    case "$kind" in
      changed) sed 's/完整查证规则/用户定制规则/' "$original" >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      duplicate) cat "$original" "$original" >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      missing-end) sed '/:codex-research:end/d' "$original" >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      nested) { head -n 1 "$original"; cat "$original"; } >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      bare-line) sed '/:codex-research:/d' "$original" >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      wrong-home) sed 's@/skills/exa-context7-research@/other/skills/exa-context7-research@' "$original" >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
      outside-reference) printf '\nUser link: exa-context7-research\n' >>"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" ;;
    esac
    before="$(configuration_tree_snapshot)"
    if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    [[ "$(configuration_tree_snapshot)" == "$before" &&
       -f "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" ]] || return 1
    jq -e '.outcome == "blocked" and .checks.global_rules == "conflict"' "$(latest_report)" >/dev/null || return 1
  done
}

test_old_reference_without_skill() {
  fixture old-reference-missing-skill
  fixture_legacy_block >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR/skills" ]] || return 1
  complete_report
}

test_global_write_failure_resume() (
  fixture global-write-failure
  fixture_legacy_setup
  fixture_legacy_block plain >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  eval "$(declare -f _research_write_global | sed '1s/_research_write_global/_research_write_global_actual/')"
  _research_write_global() {
    if [[ "$1" == */AGENTS.override.md && ! -e "$RESEARCH_FIXTURE_FAILED" ]]; then
      touch "$RESEARCH_FIXTURE_FAILED"
      return 1
    fi
    _research_write_global_actual "$@"
  }
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  rg -q 'exa-context7-research' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  [[ -f "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" ]] || return 1
  local manifest
  manifest="$(jq -r .recovery_manifest "$(latest_report)")"
  jq -e '.global_files[0].status == "written" and .global_files[1].status == "writing" and
    .legacy_skill.status == "pending"' "$manifest" >/dev/null || return 1
  do_configure --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md" || return 1
  legacy_archive_matches
)

test_archive_failure_resume() (
  fixture archive-failure
  fixture_legacy_setup
  eval "$(declare -f _research_archive_legacy | sed '1s/_research_archive_legacy/_research_archive_legacy_actual/')"
  _research_archive_legacy() {
    if [[ ! -e "$RESEARCH_FIXTURE_FAILED" ]]; then touch "$RESEARCH_FIXTURE_FAILED"; return 1; fi
    _research_archive_legacy_actual
  }
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  [[ -f "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" ]] || return 1
  local after
  after="$(sha256sum "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")"
  do_configure --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ "$(sha256sum "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md")" == "$after" ]] || return 1
  legacy_archive_matches
)

test_concurrent_global_change() (
  fixture concurrent-global
  fixture_legacy_setup
  cp -p "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$RESEARCH_FIXTURE_DIR/agents.before"
  eval "$(declare -f _research_prepare_recovery | sed '1s/_research_prepare_recovery/_research_prepare_recovery_actual/')"
  _research_prepare_recovery() {
    _research_prepare_recovery_actual || return 1
    printf 'A new user override.\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md"
  }
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  cmp -s "$RESEARCH_FIXTURE_DIR/agents.before" "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  [[ "$(cat "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.override.md")" == 'A new user override.' &&
     -f "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" && ! -s "$RESEARCH_FIXTURE_ADDS" ]]
)

test_concurrent_legacy_change() (
  fixture concurrent-legacy
  fixture_legacy_setup
  cp -p "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" "$RESEARCH_FIXTURE_DIR/agents.before"
  eval "$(declare -f _research_prepare_recovery | sed '1s/_research_prepare_recovery/_research_prepare_recovery_actual/')"
  _research_prepare_recovery() {
    _research_prepare_recovery_actual || return 1
    printf 'A new user customization.\n' >>"$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md"
  }
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  cmp -s "$RESEARCH_FIXTURE_DIR/agents.before" "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  rg -q '^A new user customization\.$' "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" || return 1
  [[ ! -s "$RESEARCH_FIXTURE_ADDS" ]]
)

test_change_during_retirement_record() (
  local kind
  for kind in skill global; do
    fixture "late-retirement-change-$kind"
    fixture_legacy_setup
    eval "$(declare -f _research_manifest_status | sed '1s/_research_manifest_status/_research_manifest_status_actual/')"
    _research_manifest_status() {
      _research_manifest_status_actual "$@" || return 1
      if [[ "$1 $2" == 'legacy_skill retiring' ]]; then
        if [[ "$kind" == skill ]]; then
          printf 'A late user customization.\n' >>"$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md"
        else
          printf '\nA late user reference: exa-context7-research\n' >>"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
        fi
      fi
    }
    if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
    [[ -d "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research" ]] || return 1
    if [[ "$kind" == skill ]]; then
      rg -q '^A late user customization\.$' "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research/SKILL.md" || return 1
    else
      rg -q '^A late user reference: exa-context7-research$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
    fi
    # Restore the non-injecting wrapper before creating the next independent case.
    eval "$(declare -f _research_manifest_status_actual | sed '1s/_research_manifest_status_actual/_research_manifest_status/')"
  done
)

test_old_mv_retirement_protection() (
  mv() {
    if [[ "${1:-}" == --help ]]; then printf 'Usage: legacy mv without rename-only support\n'; return 0; fi
    command mv "$@"
  }
  fixture unsupported-rename-retirement
  fixture_legacy_setup
  local before
  before="$(configuration_tree_snapshot)"
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  [[ "$(configuration_tree_snapshot)" == "$before" && ! -s "$RESEARCH_FIXTURE_ADDS" ]] || return 1
  rg -q -- 'requires mv --no-copy' "$RESEARCH_FIXTURE_LOG" || return 1
  fixture unsupported-rename-new-install
  do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR/skills" ]] || return 1
  complete_report
)

test_private_instructions_stay_out_of_argv() (
  fixture private-global-instructions
  printf 'fixture-private-instructions-sentinel\n' >"$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md"
  jq() {
    local argument
    for argument in "$@"; do
      if [[ "$argument" == *fixture-private-instructions-sentinel* ]]; then
        touch "$RESEARCH_FIXTURE_DIR/private-argv-leak"
      fi
    done
    command jq "$@"
  }
  do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  [[ ! -e "$RESEARCH_FIXTURE_DIR/private-argv-leak" ]] || return 1
  local report manifest
  report="$(latest_report)" || return 1
  manifest="$(jq -r .recovery_manifest "$report")"
  if rg -q 'fixture-private-instructions-sentinel' "$RESEARCH_FIXTURE_LOG" "$report" "${report%.json}.html" "$manifest"; then return 1; fi
  rg -q '^fixture-private-instructions-sentinel$' "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  complete_report
)

test_report_failure_after_retirement() (
  fixture report-failure
  fixture_legacy_setup
  eval "$(declare -f _research_report | sed '1s/_research_report/_research_report_actual/')"
  _research_report() {
    if [[ ! -e "$RESEARCH_FIXTURE_FAILED" ]]; then touch "$RESEARCH_FIXTURE_FAILED"; return 1; fi
    _research_report_actual "$@"
  }
  if do_configure --no-open >"$RESEARCH_FIXTURE_LOG" 2>&1; then return 1; fi
  full_rules_present "$RESEARCH_FIXTURE_CODEX_DIR/AGENTS.md" || return 1
  [[ ! -e "$RESEARCH_FIXTURE_CODEX_DIR/skills/exa-context7-research" ]] || return 1
  local manifest
  manifest="$(find "$RESEARCH_FIXTURE_CODEX_DIR/.ubuntu-setup-research-runs" -name recovery.json -type f)"
  jq -e '.legacy_skill.status == "retired"' "$manifest" >/dev/null || return 1
  status >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
  do_configure --no-open >>"$RESEARCH_FIXTURE_LOG" 2>&1 || return 1
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
run_case 'AGENTS.override.md receives complete rules and AGENTS.md stays unchanged' test_override_precedence
run_case 'an empty override stays empty so existing AGENTS.md remains effective' test_empty_override
run_case 'a whitespace-only override stays unchanged so existing AGENTS.md remains effective' test_whitespace_override
run_case 'both server additions preserve the original config backup and permissions' test_original_backup_survives
run_case 'an existing official Context7 OAuth endpoint is preserved' test_existing_oauth_endpoint
run_case 'a native add failure remains incomplete and can be retried safely' test_partial_failure_retry
run_case 'native add failure after a verified config write does not duplicate registration' test_native_error_after_write
run_case 'a retry in the same second cannot overwrite the original recovery backup' test_backup_survives_fast_retry

run_case 'both historical trigger formats migrate without losing user instructions or metadata' test_legacy_migration
run_case 'active and inactive global files are migrated before retiring the legacy skill' test_two_global_legacy_migration
run_case 'modified, missing, unknown and linked legacy entries block all writes' test_legacy_tree_conflicts
run_case 'unrecognized or modified old blocks and outside references are preserved' test_legacy_block_conflicts
run_case 'a recognized dangling old trigger can be replaced without creating a skill' test_old_reference_without_skill
run_case 'a second global write failure leaves old links valid and can resume' test_global_write_failure_resume
run_case 'retirement failure preserves the skill and resumes without rewriting new rules' test_archive_failure_resume
run_case 'a concurrently added override is retained and blocks stale changes' test_concurrent_global_change
run_case 'a concurrently customized legacy skill is retained and blocks stale changes' test_concurrent_legacy_change
run_case 'changes made while recording retirement are retained before the final rename' test_change_during_retirement_record
run_case 'old mv preserves legacy deployments without blocking fresh configuration' test_old_mv_retirement_protection
run_case 'private global instructions never enter jq process arguments or public reports' test_private_instructions_stay_out_of_argv
run_case 'a report failure after retirement leaves durable recovery data and safe retry' test_report_failure_after_retirement

if (( RESEARCH_TEST_FAILURES )); then
  printf '%s portable research setup check(s) failed.\n' "$RESEARCH_TEST_FAILURES" >&2
  exit 1
fi
printf 'All portable research setup checks passed.\n'
