#!/usr/bin/env bash
# Configure the repository's Exa / Context7 research workflow for Codex CLI.
set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=codex-research
name=Codex Exa + Context7
category=ai
tags=cli
requires=codex
ops=install,configure,plan
desc=Deploy global research rules and Exa / Context7 MCP configuration
META
}

# These two seams also let tests exercise all configuration work in isolated fixtures.
_research_home() { printf '%s\n' "${CODEX_HOME:-${HOME:?HOME is required}/.codex}"; }
_research_codex() (
  cd / || exit 1
  local cli
  if have_cmd codex; then cli="$(command -v codex)";
  else cli="${HOME:?HOME is required}/.local/bin/codex"; fi
  timeout 45 "$cli" "$@"
)

_research_reset() {
  _RESEARCH_HOME=""
  _RESEARCH_AGENTS=""
  _RESEARCH_COMPLETE=false
  _RESEARCH_EXA_STATE=not_checked
  _RESEARCH_CONTEXT7_STATE=not_checked
  _RESEARCH_LEGACY_STATE=not_checked
  _RESEARCH_LEGACY_SNAPSHOT=""
  _RESEARCH_GLOBAL_SNAPSHOT=""
  _RESEARCH_GLOBAL_PLAN='[]'
  _RESEARCH_AGENTS_STATE=not_checked
  _RESEARCH_ISSUES=()
  _RESEARCH_ACTIONS=()
  _RESEARCH_ADD_MCP=()
  _RESEARCH_ARCHIVE_LEGACY=0
}

_research_issue() { _RESEARCH_ISSUES+=("$*"); }

_research_safe_path() {
  local path="$1" cursor="$1"
  [[ "$path" == /* && "$path" != / && "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
  case "/${path#/}/" in */../*|*/./*) return 1 ;; esac
  while [[ "$cursor" != / ]]; do
    [[ ! -L "$cursor" ]] || return 1
    cursor="$(dirname "$cursor")"
  done
}

_research_has_instructions() {
  # Codex's Rust trim() also ignores Unicode White_Space. Match its UTF-8 bytes
  # independently of the caller's locale; POSIX [:space:] covers the ASCII set.
  LC_ALL=C sed -E \
    $'s/\xc2[\x85\xa0]|\xe1\x9a\x80|\xe2\x80[\x80-\x8a\xa8\xa9\xaf]|\xe2\x81\x9f|\xe3\x80\x80//g' "$1" |
    LC_ALL=C grep '[^[:space:]]' >/dev/null
}

# Inspect paths before installing dependencies or invoking a configuration writer.
_research_paths() {
  local path
  _RESEARCH_HOME="$(_research_home)" || { _research_issue 'Cannot resolve Codex home.'; return 1; }
  _RESEARCH_HOME="${_RESEARCH_HOME%/}"
  if [[ -n "${SUDO_USER:-}" ]]; then
    _research_issue 'Run this configuration as your normal user, without sudo.'
  fi
  # Codex ignores blank instruction files. Appending to an otherwise inactive
  # override would hide the user's effective AGENTS.md instructions.
  if [[ -s "$_RESEARCH_HOME/AGENTS.override.md" ]] &&
    _research_has_instructions "$_RESEARCH_HOME/AGENTS.override.md"; then
    _RESEARCH_AGENTS="$_RESEARCH_HOME/AGENTS.override.md"
  else
    _RESEARCH_AGENTS="$_RESEARCH_HOME/AGENTS.md"
  fi
  for path in "$_RESEARCH_HOME" "$_RESEARCH_HOME/config.toml" \
    "$_RESEARCH_HOME/AGENTS.md" "$_RESEARCH_HOME/AGENTS.override.md" \
    "$_RESEARCH_HOME/skills/exa-context7-research" "$_RESEARCH_HOME/.ubuntu-setup-research-runs"; do
    _research_safe_path "$path" || _research_issue "Unsafe or symbolic-link target: $path"
  done
  for path in "$_RESEARCH_HOME/config.toml" "$_RESEARCH_HOME/AGENTS.md" "$_RESEARCH_HOME/AGENTS.override.md"; do
    [[ ! -e "$path" || -f "$path" ]] || _research_issue "Expected a regular file: $path"
  done
  for path in "$_RESEARCH_HOME" "$_RESEARCH_HOME/skills" \
    "$_RESEARCH_HOME/skills/exa-context7-research" "$_RESEARCH_HOME/.ubuntu-setup-research-runs"; do
    [[ ! -e "$path" || -d "$path" ]] || _research_issue "Expected a directory: $path"
  done
  if [[ -e /.codex/config.toml ]]; then
    _research_issue 'Root-level /.codex/config.toml would affect native CLI configuration inspection.'
  fi
  ((${#_RESEARCH_ISSUES[@]} == 0))
}

_research_dependencies() {
  if ! have_cmd codex && [[ ! -x "${HOME:-}/.local/bin/codex" ]]; then
    _research_issue 'Codex CLI is missing; run: ./swkit codex install'
  fi
  if ! have_cmd jq; then
    _research_issue 'jq is required. The install operation can install it using the shared package helper.'
  fi
  have_cmd sha256sum || _research_issue 'The coreutils sha256sum command is required.'
  have_cmd timeout || _research_issue 'The coreutils timeout command is required.'
  ((${#_RESEARCH_ISSUES[@]} == 0))
}

_research_server_valid() {
  local name="$1" json="$2"
  # Raw CLI JSON can contain credentials. Keep it in memory; only emit booleans.
  jq -e --arg name "$name" '
    .name == $name and .enabled == true
    and .transport.type == "streamable_http"
    and (.enabled_tools == null)
    and ((.disabled_tools // []) | length == 0)
    and (.transport.url | type == "string")
    and (.transport.url | test("[?&]tools(=|&|$)") | not)
    and (.transport.url | if $name == "exa"
      then test("^https://mcp\\.exa\\.ai/mcp/?(\\?[^#]*)?$")
      else test("^https://mcp\\.context7\\.com/mcp(/oauth)?/?(\\?[^#]*)?$") end)
  ' <<<"$json" >/dev/null 2>&1
}

_research_servers() {
  local servers name count details state
  if [[ ! -d "$_RESEARCH_HOME" ]]; then
    _research_issue 'Codex home does not exist yet. Native CLI inspection is pending the execution phase; run: swkit codex-research install --with-requires'
    return 1
  fi
  if ! servers="$(_research_codex mcp list --json 2>/dev/null)" ||
    ! jq -e 'type == "array" and all(.[]; type == "object" and (.name | type == "string"))' \
      <<<"$servers" >/dev/null 2>&1; then
    _research_issue 'Codex could not read MCP configuration as JSON; inspect it locally without publishing credentials.'
    return 1
  fi
  for name in exa context7; do
    count="$(jq --arg name "$name" '[.[] | select(.name == $name)] | length' <<<"$servers")"
    state=configured
    if [[ "$count" == 0 ]]; then
      state=missing
      _RESEARCH_ADD_MCP+=("$name")
      _RESEARCH_ACTIONS+=("Register the public $name MCP endpoint.")
    elif [[ "$count" != 1 ]] || ! details="$(_research_codex mcp get "$name" --json 2>/dev/null)" ||
      ! _research_server_valid "$name" "$details"; then
      state=conflict
      _research_issue "Existing $name MCP conflicts: check endpoint, transport, enabled state and tool restrictions (including URL tools lists). It will be preserved."
    fi
    printf -v "_RESEARCH_${name^^}_STATE" '%s' "$state"
  done
}

# Snapshots stay in memory. AGENTS contents may include private user instructions.
_research_observe_global() {
  local path="$1" stamp=null text=null
  _research_safe_path "$path" || return 1
  if [[ -e "$path" ]]; then
    [[ -f "$path" && "$(stat -c %u "$path")" == "$EUID" ]] || return 1
    stamp="$(stat -c '%d:%i:%u:%g:%a:%s:%y:%z' "$path")" || return 1
    text="$(jq -Rs . "$path")" || return 1
    # Refuse lossy UTF-8 conversion rather than rewriting unrelated bytes.
    cmp -s "$path" <(jq -rj . <<<"$text") || return 1
    jq -c --arg path "$path" --arg stamp "$stamp" \
      '{path:$path, stamp:$stamp, text:.}' <<<"$text"
  else
    jq -cn --arg path "$path" '{path:$path, stamp:null, text:null}'
  fi
}

_research_observe_globals() {
  local first second
  first="$(_research_observe_global "$_RESEARCH_HOME/AGENTS.md")" || return 1
  second="$(_research_observe_global "$_RESEARCH_HOME/AGENTS.override.md")" || return 1
  printf '%s\n' "$first" "$second" | jq -sc .
}

_research_legacy_snapshot() (
  local root="$_RESEARCH_HOME/skills/exa-context7-research" relative expected actual tree
  if [[ ! -e "$root" && ! -L "$root" ]]; then printf 'absent\n'; return 0; fi
  _research_safe_path "$root" && [[ -d "$root" ]] || return 1
  tree="$(find "$root" -mindepth 1 -printf '%P\t%y\n' | LC_ALL=C sort)" || return 1
  [[ "$tree" == $'SKILL.md\tf\nagents\td\nagents/openai.yaml\tf' ]] || return 1
  for relative in '' agents SKILL.md agents/openai.yaml; do
    [[ "$(stat -c %u "$root${relative:+/$relative}")" == "$EUID" ]] || return 1
  done
  for relative in SKILL.md agents/openai.yaml; do
    expected="$(jq -er --arg path "$relative" '.files[$path]' \
      "$KIT_ROOT/skills/codex-research-setup/assets/legacy-research-skill.json")" || return 1
    actual="$(sha256sum -- "$root/$relative")" || return 1
    [[ "${actual%% *}" == "$expected" ]] || return 1
  done
  for relative in '' agents SKILL.md agents/openai.yaml; do
    stat -c '%d:%i:%u:%g:%a:%s:%y:%z' "$root${relative:+/$relative}" || return 1
  done
)

_research_legacy() {
  if ! _RESEARCH_LEGACY_SNAPSHOT="$(_research_legacy_snapshot)"; then
    _RESEARCH_LEGACY_STATE=conflict
    _research_issue 'The legacy research skill has modified/missing files, unknown entries, unsafe links or ownership. It will be preserved.'
  elif [[ "$_RESEARCH_LEGACY_SNAPSHOT" == absent ]]; then
    _RESEARCH_LEGACY_STATE=configured
  elif ! LC_ALL=C mv --help | grep -F -- '--no-copy' >/dev/null; then
    _RESEARCH_LEGACY_STATE=conflict
    _research_issue 'Automatic legacy retirement requires mv --no-copy. Existing rules and files were preserved; retire the verified skill manually before retrying.'
  else
    _RESEARCH_LEGACY_STATE=missing
    _RESEARCH_ARCHIVE_LEGACY=1
    _RESEARCH_ACTIONS+=('Back up and retire the verified legacy research skill after replacing all old global references.')
  fi
}

_research_agents() {
  local assets="$KIT_ROOT/skills/codex-research-setup/assets" plan
  if ! _RESEARCH_GLOBAL_SNAPSHOT="$(_research_observe_globals)"; then
    _RESEARCH_AGENTS_STATE=conflict
    _research_issue 'Cannot safely read both global AGENTS files without losing content or metadata.'
    return
  fi
  if ! plan="$(jq -c --arg active "$_RESEARCH_AGENTS" \
    --rawfile rules "$assets/research-rules.md" --rawfile legacy "$assets/legacy-research-trigger.txt" \
    --arg home "$_RESEARCH_HOME" '
    . as $files |
    "<!-- ubuntu-setup:codex-research:start -->" as $start |
    "<!-- ubuntu-setup:codex-research:end -->" as $end |
    ($start + "\n" + $rules + $end) as $block |
    ($legacy | split("{{CODEX_HOME}}") | join($home) | rtrimstr("\n")) as $old |
    ($old | sub("\\]\\(<"; "](") | sub(">\\)"; ")")) as $old_plain |
    def reserved: contains("ubuntu-setup:codex-research:") or contains("exa-context7-research");
    $files | map(. as $file | (.text // "") as $text |
      if ($text | reserved) then
        if ($text | split($start) | length) != 2 or ($text | split($end) | length) != 2 then
          . + {action:"conflict"}
        else
          ($text | index($start)) as $first | ($text | index($end)) as $last |
          if $last < $first then . + {action:"conflict"}
          else
            ($text[:$first]) as $prefix | ($text[$last + ($end|length):]) as $suffix |
            ($text[$first:$last + ($end|length)]) as $found |
            if ($prefix | reserved) or ($suffix | reserved) or
               ($prefix != "" and ($prefix | endswith("\n") | not)) or
               ($suffix != "" and ($suffix | startswith("\n") | not)) then . + {action:"conflict"}
            elif $found == $block then . + {action:"skip", after:$text}
            elif $found == ($start + "\n## 外部事实查证\n\n" + $old + "\n" + $end) or
                 $found == ($start + "\n## 外部事实查证\n\n" + $old_plain + "\n" + $end) then
              . + {action:"replace", after:($prefix + $block + $suffix)}
            else . + {action:"conflict"} end
          end
        end
      elif .path == $active then
        . + {action:"append", after:($text + (if $text == "" or ($text | endswith("\n")) then "\n" else "\n\n" end) + $block + "\n")}
      else . + {action:"skip", after:.text} end
    )' <<<"$_RESEARCH_GLOBAL_SNAPSHOT")"; then
    _RESEARCH_AGENTS_STATE=conflict
    _research_issue 'Cannot prepare global research rules from repository assets.'
    return
  fi
  _RESEARCH_GLOBAL_PLAN="$plan"
  if jq -e 'any(.[]; .action == "conflict")' <<<"$plan" >/dev/null; then
    _RESEARCH_AGENTS_STATE=conflict
    _research_issue 'A global AGENTS file has an unrecognized, duplicated or modified research block/reference. Both files and the legacy skill will be preserved.'
  elif jq -e 'any(.[]; .action != "skip")' <<<"$plan" >/dev/null; then
    _RESEARCH_AGENTS_STATE=missing
    _RESEARCH_ACTIONS+=('Write complete research rules, replacing only recognized legacy blocks in either global AGENTS file.')
  else
    _RESEARCH_AGENTS_STATE=configured
  fi
}

_research_check_targets() {
  local observed legacy
  observed="$(_research_observe_globals)" && [[ "$observed" == "$_RESEARCH_GLOBAL_SNAPSHOT" ]] &&
    legacy="$(_research_legacy_snapshot)" && [[ "$legacy" == "$_RESEARCH_LEGACY_SNAPSHOT" ]] || {
    _RESEARCH_FAILURE='Global instructions or the legacy skill changed after inspection. Changes were preserved; inspect state before retrying.'
    return 1
  }
}

_research_preflight() {
  _research_reset
  _research_paths || return 1
  _research_dependencies || return 1
  _research_servers || true
  _research_legacy
  _research_agents
  if ((${#_RESEARCH_ISSUES[@]} == 0 && ${#_RESEARCH_ACTIONS[@]} == 0)); then
    _RESEARCH_COMPLETE=true
  fi
  ((${#_RESEARCH_ISSUES[@]} == 0))
}

_research_print_plan() {
  local item
  printf 'Codex home: %s\nGlobal rule: %s\n' "$_RESEARCH_HOME" "$_RESEARCH_AGENTS"
  for item in "${_RESEARCH_ISSUES[@]}"; do printf 'Blocked: %s\n' "$item"; done
  for item in "${_RESEARCH_ACTIONS[@]}"; do printf 'Planned: %s\n' "$item"; done
  if [[ "$_RESEARCH_COMPLETE" == true ]]; then printf 'Configuration is complete; no configuration writes are needed.\n'; fi
  printf 'MCP connectivity and model behavior require verification in a new Codex session.\n'
}

do_plan() {
  (($# == 0)) || { log_err 'plan takes no arguments.'; return 2; }
  local rc=0
  _research_preflight || rc=1
  _research_print_plan
  return "$rc"
}

status() {
  local item
  if _research_preflight && [[ "$_RESEARCH_COMPLETE" == true ]]; then
    printf 'Research configuration complete (MCP connectivity and model behavior not verified).\n'
    return 0
  fi
  for item in "${_RESEARCH_ISSUES[@]}"; do printf 'Blocked: %s\n' "$item"; done
  printf 'Research configuration incomplete; run: swkit codex-research plan\n'
  return 1
}

_research_report_directory() {
  [[ -z "${_RESEARCH_REPORT_DIR:-}" ]] || return 0
  local root="$_RESEARCH_HOME/.ubuntu-setup-research-runs" stamp
  _research_safe_path "$root" || return 1
  mkdir -p "$root" || return 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  _RESEARCH_REPORT_DIR="$(mktemp -d "$root/$stamp.XXXXXX")" || return 1
}

_research_backup() {
  local path="$1" copy
  [[ -f "$path" ]] || return 0
  _research_report_directory || return 1
  mkdir -p "$_RESEARCH_REPORT_DIR/backups" || return 1
  copy="$(mktemp "$_RESEARCH_REPORT_DIR/backups/$(basename "$path").XXXXXX")" || return 1
  # common.sh's second-resolution backup_file cannot preserve separate recovery
  # points for retries in the same second. Use an exact unique path here. The
  # private run directory protects credentials while cp -p keeps recovery metadata.
  cp -p -- "$path" "$copy" || return 1
  _RESEARCH_BACKUPS+=("$copy")
  _RESEARCH_LAST_BACKUP="$copy"
  log_info "Backed up $path -> $copy"
}

_research_prepare_recovery() {
  local record path backup candidate before_hash after_hash entries='[]' legacy=null
  _research_report_directory || return 1
  mkdir -p "$_RESEARCH_REPORT_DIR/candidates" || return 1
  while IFS= read -r record; do
    path="$(jq -r .path <<<"$record")"
    backup=""
    before_hash=""
    if [[ -f "$path" ]]; then
      _research_backup "$path" || return 1
      backup="$_RESEARCH_LAST_BACKUP"
      before_hash="$(sha256sum -- "$backup")"
      before_hash="${before_hash%% *}"
    fi
    candidate="$_RESEARCH_REPORT_DIR/candidates/$(basename "$path")"
    jq -rj .after <<<"$record" >"$candidate" || return 1
    after_hash="$(sha256sum -- "$candidate")"
    entries="$(jq -cn --argjson entries "$entries" --arg path "$path" --arg backup "$backup" \
      --arg candidate "$candidate" --arg before "$before_hash" --arg after "${after_hash%% *}" \
      --argjson stamp "$(jq -c .stamp <<<"$record")" '$entries + [{path:$path, backup:$backup, candidate:$candidate,
        original_metadata:$stamp, before_sha256:$before, after_sha256:$after, status:"pending"}]')" || return 1
  done < <(jq -c '.[] | select(.action != "skip")' <<<"$_RESEARCH_GLOBAL_PLAN")
  if [[ "$_RESEARCH_ARCHIVE_LEGACY" == 1 ]]; then
    backup="$_RESEARCH_REPORT_DIR/legacy-skill-backup"
    cp -a -- "$_RESEARCH_HOME/skills/exa-context7-research" "$backup" || return 1
    _RESEARCH_BACKUPS+=("$backup")
    legacy="$(jq -cn --arg original "$_RESEARCH_HOME/skills/exa-context7-research" \
      --arg backup "$backup" --arg archive "$_RESEARCH_REPORT_DIR/retired-exa-context7-research" \
      --arg metadata "$_RESEARCH_LEGACY_SNAPSHOT" \
      '{original_path:$original, backup:$backup, archive:$archive, original_metadata:$metadata, status:"pending"}')"
  fi
  _RESEARCH_MANIFEST="$_RESEARCH_REPORT_DIR/recovery.json"
  jq -n --argjson globals "$entries" --argjson legacy "$legacy" \
    '{schema_version:1, global_files:$globals, legacy_skill:$legacy,
      restoration:"Compare current files with candidate hashes before restoring backups; preserve later changes. Restore the legacy skill together with its original trigger blocks if reverting."}' \
    >"$_RESEARCH_MANIFEST" || return 1
}

_research_manifest_status() {
  local path="$1" stage="$2" candidate
  candidate="$(mktemp "$_RESEARCH_REPORT_DIR/recovery.XXXXXX")" || return 1
  jq --arg path "$path" --arg stage "$stage" '
    if $path == "legacy_skill" then .legacy_skill.status = $stage
    else .global_files |= map(if .path == $path then .status = $stage else . end) end
  ' "$_RESEARCH_MANIFEST" >"$candidate" && mv -T -- "$candidate" "$_RESEARCH_MANIFEST"
}

# Atomic replacement is a separate seam for isolated write-failure tests.
_research_write_global() (
  local path="$1" source="$2" candidate
  candidate="$(mktemp "$(dirname "$path")/.ubuntu-setup-research.XXXXXX")" || return 1
  trap 'rm -f -- "$candidate"' EXIT
  if [[ -f "$path" ]]; then
    cp -p -- "$path" "$candidate" && chmod u+w "$candidate" &&
      cat -- "$source" >"$candidate" && chmod --reference="$path" "$candidate" || return 1
  else
    cat -- "$source" >"$candidate" || return 1
  fi
  _research_check_targets || return 1
  mv -T -- "$candidate" "$path"
)

_research_archive_legacy() {
  local source="$_RESEARCH_HOME/skills/exa-context7-research"
  local target="$_RESEARCH_REPORT_DIR/retired-exa-context7-research"
  # Require rename without a copy/delete fallback, including mount boundaries.
  [[ "$(stat -c %d "$source")" == "$(stat -c %d "$_RESEARCH_REPORT_DIR")" ]] || {
    _RESEARCH_FAILURE='The verified legacy skill is on another filesystem. Rules were saved; manual retirement is required.'
    return 1
  }
  _research_check_targets || return 1
  mv --no-copy -T -- "$source" "$target" || return 1
  _RESEARCH_ARCHIVES+=("$target")
  _RESEARCH_CHANGES+=('Moved the verified legacy research skill out of discovery paths into the private recovery directory.')
  _RESEARCH_LEGACY_SNAPSHOT=absent
  _research_manifest_status legacy_skill retired
}

_research_apply() {
  local name endpoint details path candidate updated config_mode=""
  mkdir -p "$_RESEARCH_HOME" || return 1
  _research_check_targets || return 1
  _research_prepare_recovery || return 1
  _research_check_targets || return 1
  if ((${#_RESEARCH_ADD_MCP[@]})); then
    if [[ -f "$_RESEARCH_HOME/config.toml" ]]; then
      config_mode="$(stat -c '%a' "$_RESEARCH_HOME/config.toml")"
      _research_backup "$_RESEARCH_HOME/config.toml" || return 1
    fi
    for name in "${_RESEARCH_ADD_MCP[@]}"; do
      case "$name" in
        exa) endpoint=https://mcp.exa.ai/mcp ;;
        context7) endpoint=https://mcp.context7.com/mcp ;;
      esac
      # Native add can save configuration before an OAuth attempt fails/times out.
      _research_codex mcp add "$name" --url "$endpoint" </dev/null >/dev/null 2>&1 || true
      if [[ -f "$_RESEARCH_HOME/config.toml" ]]; then
        chmod "${config_mode:-600}" "$_RESEARCH_HOME/config.toml" || return 1
      fi
      if ! details="$(_research_codex mcp get "$name" --json 2>/dev/null)" ||
        ! _research_server_valid "$name" "$details"; then
        _RESEARCH_FAILURE="Could not verify the registered $name MCP configuration. Any completed changes were preserved; inspect state before retrying."
        return 1
      fi
      _RESEARCH_CHANGES+=("Registered $name MCP configuration; authentication and connectivity remain unverified.")
    done
  fi
  while IFS= read -r path; do
    _research_check_targets || return 1
    candidate="$_RESEARCH_REPORT_DIR/candidates/$(basename "$path")"
    _research_manifest_status "$path" writing || return 1
    _research_write_global "$path" "$candidate" || return 1
    _RESEARCH_CHANGES+=("Saved complete research rules in $(basename "$path").")
    cmp -s "$path" "$candidate" || return 1
    updated="$(_research_observe_global "$path")" || return 1
    # Update only the file we wrote; concurrently changed sibling instructions
    # remain detectable at the next guard instead of being silently accepted.
    _RESEARCH_GLOBAL_SNAPSHOT="$(printf '%s\n' "$_RESEARCH_GLOBAL_SNAPSHOT" "$updated" | jq -sc \
      '.[0] as $files | .[1] as $updated | $files | map(if .path == $updated.path then $updated else . end)')" || return 1
    _research_manifest_status "$path" written || return 1
  done < <(jq -r '.[] | select(.action != "skip") | .path' <<<"$_RESEARCH_GLOBAL_PLAN")
  _research_check_targets || return 1
  if [[ "$_RESEARCH_ARCHIVE_LEGACY" == 1 ]]; then
    # Both active and inactive files must be free of references before retirement.
    for path in "$_RESEARCH_HOME/AGENTS.md" "$_RESEARCH_HOME/AGENTS.override.md"; do
      if [[ -f "$path" ]] && grep -Fq 'exa-context7-research' "$path"; then
        _RESEARCH_FAILURE='An old global reference remains. The legacy skill was preserved.'
        return 1
      fi
    done
    _research_manifest_status legacy_skill retiring || return 1
    _research_archive_legacy || return 1
  fi
}

_research_json_array() {
  if (($#)); then printf '%s\n' "$@" | jq -R . | jq -s .; else printf '[]\n'; fi
}

_research_report() {
  local outcome="$1" open_report="$2" report_dir
  _research_report_directory || return 1
  report_dir="$_RESEARCH_REPORT_DIR"
  jq -n --arg outcome "$outcome" --arg time "$(date -u +%FT%TZ)" \
    --arg target "$_RESEARCH_HOME" --arg agents "$_RESEARCH_AGENTS" \
    --arg exa "$_RESEARCH_EXA_STATE" --arg context7 "$_RESEARCH_CONTEXT7_STATE" \
    --arg legacy "$_RESEARCH_LEGACY_STATE" --arg rule "$_RESEARCH_AGENTS_STATE" \
    --arg failure "$_RESEARCH_FAILURE" --argjson complete "$_RESEARCH_COMPLETE" \
    --argjson before "$_RESEARCH_BEFORE" --arg recovery "$_RESEARCH_MANIFEST" \
    --argjson archives "$(_research_json_array "${_RESEARCH_ARCHIVES[@]}")" \
    --argjson changes "$(_research_json_array "${_RESEARCH_CHANGES[@]}")" \
    --argjson backups "$(_research_json_array "${_RESEARCH_BACKUPS[@]}")" \
    --argjson issues "$(_research_json_array "${_RESEARCH_ISSUES[@]}")" \
    '{outcome: $outcome, checked_at: $time, codex_home: $target, global_agents: $agents,
      configuration_complete: $complete, global_rules_loaded: false, connection_verified: false, model_behavior_verified: false,
      checks: {exa_mcp: $exa, context7_mcp: $context7, global_rules: $rule, legacy_skill_cleanup: $legacy},
      recovery_manifest: $recovery, retired_skill_paths: $archives,
      before: $before, changes: $changes, backups: $backups, issues: $issues, failure: $failure,
      pending: ["Open a new Codex session and verify the complete global rules were loaded; writing bytes does not prove loading or avoid instruction limits/overrides.",
        "Verify Exa and Context7 calls.",
        "Check research behavior on both evidence-gap and already-supported tasks."],
      restoration: "Review the current files before restoring a backup; preserve subsequent user changes. Restore retired legacy skill files together with original trigger blocks when reverting; newly added MCP entries require explicit manual removal."}' \
    >"$report_dir/report.json" || return 1
  jq -r '
    def e: tostring | @html;
    def items: map("<li>" + (. | e) + "</li>") | join("");
    def state: if . == "configured" then "配置已核对" elif . == "missing" then "待配置"
      elif . == "conflict" then "存在冲突，保留现有内容" else "未查清" end;
    "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\"><title>Codex research configuration</title>" +
    "<style>body{max-width:960px;margin:3rem auto;padding:0 1.5rem;font:16px/1.7 sans-serif}td,th{padding:.6rem;border:1px solid #ccc;text-align:left}table{border-collapse:collapse}code{overflow-wrap:anywhere}</style>" +
    "<h1>Codex 外部事实查证配置</h1><p>检查时间：" + (.checked_at|e) + "</p>" +
    "<h2>结论与重点问题</h2><p>结果：" + (.outcome|e) + "；配置完整：" + (.configuration_complete|e) +
    "。新会话规则加载、MCP 连通性和模型触发行为尚未验证。</p><p>" + (.failure|e) + "</p><ul>" + (.issues|items) + "</ul>" +
    "<h2>用户待办与 Agent 后续建议</h2><ul>" + (.pending|items) + "</ul>" +
    "<h2>完整结果总表</h2><table><tr><th>范围</th><th>结果</th></tr>" +
    (.checks | to_entries | map("<tr><td>" + (.key|e) + "</td><td>" + (.value|state|e) + "</td></tr>") | join("")) +
    "<tr><td>完整规则加载</td><td>待新会话验证</td></tr><tr><td>认证及连接</td><td>待新会话验证</td></tr><tr><td>模型触发行为</td><td>待新会话验证</td></tr></table>" +
    "<h2>检查范围与电脑信息</h2><p>仅检查当前用户的 Codex 配置；未进行系统与硬件检查。</p><p>Codex home：<code>" +
    (.codex_home|e) + "</code><br>全局规则：<code>" + (.global_agents|e) + "</code></p>" +
    "<h2>前后变化</h2><ul>" + (.changes|items) + "</ul><p>恢复清单：" + (.recovery_manifest|e) + "</p><ul>" +
    (.retired_skill_paths|items) + "</ul><p>恢复限制：" + (.restoration|e) + "</p><ul>" + (.backups|items) + "</ul>" +
    "<h2>依据附录</h2><p>依据：仓库完整规则比较、旧版文件固定指纹、原生 Codex MCP JSON 与两份全局 AGENTS 文件。配置读取成功不代表工具可用。</p>" +
    "<p><a href=\"report.json\">JSON 记录（不包含 MCP 原始配置或凭据）</a></p></html>"
  ' "$report_dir/report.json" >"$report_dir/report.html" || return 1
  printf 'Report: %s/report.html\nJSON: %s/report.json\n' "$report_dir" "$report_dir"
  if [[ "$open_report" == 1 ]] && have_cmd xdg-open; then
    xdg-open "$report_dir/report.html" >/dev/null 2>&1 || log_warn 'Browser opening failed; the report remains at the printed path.'
  fi
}

_research_install() (
  local allow_dependencies="$1" open_report=1 outcome=complete rc=0 item
  shift
  while (($#)); do
    case "$1" in --no-open) open_report=0 ;; *) log_err "Unknown option: $1"; return 2 ;; esac
    shift
  done
  umask 077
  _RESEARCH_CHANGES=()
  _RESEARCH_BACKUPS=()
  _RESEARCH_ARCHIVES=()
  _RESEARCH_MANIFEST=""
  _RESEARCH_LAST_BACKUP=""
  _RESEARCH_FAILURE=""
  _RESEARCH_REPORT_DIR=""
  _RESEARCH_BEFORE='{}'
  _research_reset
  if ! _research_paths; then
    _research_print_plan
    return 1
  fi
  if [[ "$allow_dependencies" == 1 ]] && ! have_cmd jq; then
    if ! have_cmd codex && [[ ! -x "${HOME:-}/.local/bin/codex" ]]; then
      log_err 'Install Codex first: ./swkit codex install'
      return 1
    fi
    log_info 'Installing the required jq parser through the shared package helper.'
    apt_install jq || return $?
    _RESEARCH_CHANGES+=('Installed the jq configuration parser dependency.')
  fi
  if ! _research_dependencies; then
    _research_print_plan
    return 1
  fi
  # Codex 0.163.0 cannot list configuration until its home exists. Only execution
  # creates the directory; plan/status leave a fresh target untouched and unknown.
  if [[ ! -d "$_RESEARCH_HOME" ]]; then
    mkdir -p "$_RESEARCH_HOME" || return 1
    _RESEARCH_CHANGES+=('Created the Codex configuration directory.')
  fi
  if ! _research_preflight; then
    outcome=blocked
    rc=1
    _research_print_plan
  else
    _research_print_plan
    _RESEARCH_BEFORE="$(jq -n \
      --argjson config_exists "$([[ -f "$_RESEARCH_HOME/config.toml" ]] && printf true || printf false)" \
      --argjson agents_exists "$([[ -f "$_RESEARCH_AGENTS" ]] && printf true || printf false)" \
      --argjson absent_servers "$(_research_json_array "${_RESEARCH_ADD_MCP[@]}")" \
      --arg legacy_state "$_RESEARCH_LEGACY_STATE" \
      '{config_existed: $config_exists, agents_existed: $agents_exists,
        missing_mcp_servers: $absent_servers, legacy_skill_state: $legacy_state}')"
    if ! _research_apply; then
      outcome=partial
      rc=1
      [[ -n "$_RESEARCH_FAILURE" ]] || _RESEARCH_FAILURE='A configuration write failed; inspect the actual files before retrying.'
    fi
    if ! _research_preflight || [[ "$_RESEARCH_COMPLETE" != true ]]; then
      outcome=partial
      rc=1
    fi
  fi
  for item in "${_RESEARCH_CHANGES[@]}"; do log_info "$item"; done
  [[ -z "$_RESEARCH_FAILURE" ]] || log_err "$_RESEARCH_FAILURE"
  if have_cmd jq; then
    _research_report "$outcome" "$open_report" || { log_err 'Could not save the configuration report.'; rc=1; }
  fi
  return "$rc"
)

do_install() { _research_install 1 "$@"; }
do_configure() { _research_install 0 "$@"; }

usage() {
  cat <<'USAGE'
Usage: swkit codex-research <install|configure|plan|status|meta|help|ui> [--no-open]

  install    Install jq if missing, then write complete global research rules
             and register missing Exa / Context7 HTTP MCP entries.
             Use --with-requires to install Codex CLI first if it is missing.
  configure  Apply the same configuration; requires Codex CLI and jq already present.
  plan       Inspect changes or conflicts without changing configuration or installing
             dependencies. The native CLI may create its own runtime temporary files.
  status     Exit 0 only when the configuration matches; no connectivity test.
  --no-open  Save install/configure HTML + JSON reports without opening a browser.

Targets CODEX_HOME (default: ~/.codex). Preserves existing matching MCP credentials
and unrelated configuration. Conflicting endpoints, disabled/restricted servers,
modified/unknown legacy skill files, unrecognized global rule blocks and symbolic-link
targets block configuration writes. Verified old trigger blocks are replaced before
the unchanged legacy skill is backed up and moved into the private recovery directory.
The native Codex CLI may attempt OAuth after registering a server; calls are bounded.
Configuration backups and report paths are printed. Review current contents before
manually restoring a backup; do not overwrite later user changes. No automatic remove.
Open a new Codex session to verify MCP calls and research behavior.
USAGE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  case "${1:-}" in
    install|configure)
      if [[ -n "${SUDO_USER:-}" ]]; then
        log_err 'Run this configuration as your normal user, without sudo.'
        exit 1
      fi
      ;;
  esac
  kit_dispatch "$@"
fi
