#!/usr/bin/env bash
#
# scripts/mattpocock-skills.sh — install / manage Matt Pocock's agent skills, MULTI-AGENT.
#
# Matt Pocock's skills collection (https://github.com/mattpocock/skills) is consumed via the
# open agent-skill CLI `skills` (vercel-labs/skills, `npx skills@latest`), which installs the
# SAME SKILL.md skill into ANY of 70+ coding agents (Claude Code, Codex, Cursor, OpenCode,
# Gemini CLI, Windsurf, GitHub Copilot, …). That cross-agent reach is the whole reason this is
# its own script instead of more weight on claude.sh (which only manages Claude Code).
#
# Read / write split (idempotency + a snappy UI):
#   - READS  (status, the ui() screen) scan each target agent's GLOBAL skills directory on
#     disk — pure filesystem, offline, instant; no per-frame `npx` spawns.
#   - WRITES (install / remove / update) shell out to `npx -y skills@latest add|remove|update
#     -g -y`, the canonical multi-agent path with non-interactive flags.
#
# Node is REQUIRED for writes (npx). Like claude.sh, this script NEVER auto-installs Node and
# NEVER runs `sudo npm`: a missing Node degrades writes gracefully (pointing at `swkit node
# install`) while reads keep working. All skills live under the user's HOME and are written AS
# THE USER — a sudo-wrapped run is refused so those directories stay user-owned.
#
# Primary ops:  install | remove | configure | update   (meta ops=)
# Parametric ops (kit_dispatch routes <op> -> do_<op>; NOT in meta ops=; reachable in ui()):
#   add-skill <name…>      install one or more skills to the target agents
#   remove-skill <name…>   remove one or more skills from the target agents
#   set-agents <agent…>    set the managed target-agent set (persisted)
#   add-agent <agent>      add one agent to the target set
#   remove-agent <agent>   drop one agent from the target set
#   list                   `skills list -g` (pass-through; needs Node)

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly _MPS_SOURCE="mattpocock/skills"

# --- Curated catalog: the 17 skills the repo's .claude-plugin/plugin.json blesses as a bundle
# (engineering 12 + productivity 5). Skill NAME == its directory basename == the `--skill` value
# and the on-disk `<agent-skills-dir>/<name>/SKILL.md`. Names stay UNtranslated (project rule);
# only the one-line gloss is localized (MPS_I18N[…:skill_desc:<name>]).
readonly _MPS_SKILLS_ENGINEERING="ask-matt codebase-design diagnosing-bugs domain-modeling grill-with-docs improve-codebase-architecture prototype setup-matt-pocock-skills tdd to-issues to-prd triage"
readonly _MPS_SKILLS_PRODUCTIVITY="grill-me grilling handoff teach writing-great-skills"
readonly _MPS_SKILL_KEYS="$_MPS_SKILLS_ENGINEERING $_MPS_SKILLS_PRODUCTIVITY"

# --- Curated agents: the handful we offer in the picker (the CLI supports 70+; we curate). The
# value here is the `-a` flag value; _mps_agent_path maps it to its GLOBAL skills dir (README).
readonly _MPS_AGENT_KEYS="claude-code codex cursor opencode gemini-cli windsurf github-copilot"

# ===============================================================================
# i18n (software-specific strings; same shape as claude.sh's CLAUDE_I18N). Proper nouns —
# the software name, skill names, agent flag values — stay UNtranslated; only descriptive and
# operational wording (incl. the curated skill_desc:* glosses) is localized. _mps_t KEY.
# ===============================================================================
declare -gA MPS_I18N
MPS_I18N[en:agents_hdr]="Target agents"
MPS_I18N[en:unit_agents]="agent(s)"
MPS_I18N[en:skills_hdr]="Skills"
MPS_I18N[en:actions_hdr]="Actions"
MPS_I18N[en:eng_hdr]="engineering"
MPS_I18N[en:prod_hdr]="productivity"
MPS_I18N[en:other_hdr]="other"
MPS_I18N[en:add_agent]="add agent…"
MPS_I18N[en:add_skill]="add skill by name…"
MPS_I18N[en:act_install_all]="Install recommended (all 17)"
MPS_I18N[en:act_update]="Update all skills"
MPS_I18N[en:act_remove_all]="Remove all managed skills"
MPS_I18N[en:node_missing]="Node.js is required to install/remove skills — run: swkit node install"
MPS_I18N[en:foot_main]="↑↓ move   ↵/space toggle/run   esc/q close"
MPS_I18N[en:confirm_remove_all]="Remove all managed Matt Pocock skills from the target agents?"
MPS_I18N[en:prompt_agent]="agent (e.g. claude-code, codex, cursor)"
MPS_I18N[en:prompt_skill]="skill name (e.g. migrate-to-shoehorn)"
MPS_I18N[en:in_agents]="in"
MPS_I18N[en:none_installed]="not installed"
MPS_I18N[en:setup_note]="run /setup-matt-pocock-skills after installing"
MPS_I18N[en:no_agents]="No target agents set."
MPS_I18N[en:tag_detected]="detected"
MPS_I18N[en:title]="Matt Pocock skills · multi-agent"
MPS_I18N[en:skill_desc:ask-matt]="Router: pick the right skill for your situation"
MPS_I18N[en:skill_desc:codebase-design]="Shared vocabulary for designing deep modules"
MPS_I18N[en:skill_desc:diagnosing-bugs]="Diagnosis loop for hard bugs & perf regressions"
MPS_I18N[en:skill_desc:domain-modeling]="Build & sharpen a project's domain model"
MPS_I18N[en:skill_desc:grill-with-docs]="Relentless plan interview + ADRs/glossary docs"
MPS_I18N[en:skill_desc:improve-codebase-architecture]="Scan for deepening opportunities (HTML report)"
MPS_I18N[en:skill_desc:prototype]="Build a throwaway prototype to flesh out a design"
MPS_I18N[en:skill_desc:setup-matt-pocock-skills]="One-time setup for the engineering skills"
MPS_I18N[en:skill_desc:tdd]="Test-driven development (red-green-refactor)"
MPS_I18N[en:skill_desc:to-issues]="Break a plan/PRD into vertical-slice issues"
MPS_I18N[en:skill_desc:to-prd]="Turn the conversation into a PRD"
MPS_I18N[en:skill_desc:triage]="Move issues/PRs through a triage state machine"
MPS_I18N[en:skill_desc:grill-me]="Relentless interview to sharpen a plan/design"
MPS_I18N[en:skill_desc:grilling]="Reusable interview loop (stress-test a plan)"
MPS_I18N[en:skill_desc:handoff]="Compact the conversation into a handoff doc"
MPS_I18N[en:skill_desc:teach]="Teach a skill/concept within this workspace"
MPS_I18N[en:skill_desc:writing-great-skills]="Reference for authoring great skills"

MPS_I18N[zh:agents_hdr]="目标 agent"
MPS_I18N[zh:unit_agents]="个 agent"
MPS_I18N[zh:skills_hdr]="Skills"
MPS_I18N[zh:actions_hdr]="操作"
MPS_I18N[zh:eng_hdr]="engineering"
MPS_I18N[zh:prod_hdr]="productivity"
MPS_I18N[zh:other_hdr]="other"
MPS_I18N[zh:add_agent]="添加 agent…"
MPS_I18N[zh:add_skill]="按名添加 skill…"
MPS_I18N[zh:act_install_all]="安装推荐(全部 17 个)"
MPS_I18N[zh:act_update]="更新全部 skill"
MPS_I18N[zh:act_remove_all]="卸载所有受管 skill"
MPS_I18N[zh:node_missing]="安装/卸载 skill 需要 Node.js——请运行:swkit node install"
MPS_I18N[zh:foot_main]="↑↓ 移动   ↵/space 切换/执行   esc/q 关闭"
MPS_I18N[zh:confirm_remove_all]="从目标 agent 卸掉所有受管的 Matt Pocock skill?"
MPS_I18N[zh:prompt_agent]="agent(如 claude-code、codex、cursor)"
MPS_I18N[zh:prompt_skill]="skill 名(如 migrate-to-shoehorn)"
MPS_I18N[zh:in_agents]="位于"
MPS_I18N[zh:none_installed]="未安装"
MPS_I18N[zh:setup_note]="装后请运行 /setup-matt-pocock-skills"
MPS_I18N[zh:no_agents]="未设置目标 agent。"
MPS_I18N[zh:tag_detected]="已检测"
MPS_I18N[zh:title]="Matt Pocock skills · 多 agent"
MPS_I18N[zh:skill_desc:ask-matt]="路由:为当前场景挑对的 skill"
MPS_I18N[zh:skill_desc:codebase-design]="设计深模块的共享词汇"
MPS_I18N[zh:skill_desc:diagnosing-bugs]="疑难 bug 与性能回归的诊断循环"
MPS_I18N[zh:skill_desc:domain-modeling]="构建并打磨项目领域模型"
MPS_I18N[zh:skill_desc:grill-with-docs]="拷问式定方案 + 生成 ADR/术语表"
MPS_I18N[zh:skill_desc:improve-codebase-architecture]="扫描可深化点(HTML 报告)"
MPS_I18N[zh:skill_desc:prototype]="做一次性原型来充实设计"
MPS_I18N[zh:skill_desc:setup-matt-pocock-skills]="engineering skills 的一次性配置"
MPS_I18N[zh:skill_desc:tdd]="测试驱动开发(红-绿-重构)"
MPS_I18N[zh:skill_desc:to-issues]="把计划/PRD 拆成纵切 issue"
MPS_I18N[zh:skill_desc:to-prd]="把对话整理成 PRD"
MPS_I18N[zh:skill_desc:triage]="用状态机分诊 issue/PR"
MPS_I18N[zh:skill_desc:grill-me]="拷问式访谈,打磨计划/设计"
MPS_I18N[zh:skill_desc:grilling]="可复用的拷问循环(压测计划)"
MPS_I18N[zh:skill_desc:handoff]="把对话压缩成交接文档"
MPS_I18N[zh:skill_desc:teach]="在当前工作区教你一项技能/概念"
MPS_I18N[zh:skill_desc:writing-great-skills]="撰写优秀 skill 的参考"

MPS_I18N[ja:agents_hdr]="対象エージェント"
MPS_I18N[ja:unit_agents]="エージェント"
MPS_I18N[ja:skills_hdr]="Skills"
MPS_I18N[ja:actions_hdr]="操作"
MPS_I18N[ja:eng_hdr]="engineering"
MPS_I18N[ja:prod_hdr]="productivity"
MPS_I18N[ja:other_hdr]="other"
MPS_I18N[ja:add_agent]="エージェントを追加…"
MPS_I18N[ja:add_skill]="名前で skill を追加…"
MPS_I18N[ja:act_install_all]="推奨をインストール(全 17 個)"
MPS_I18N[ja:act_update]="すべての skill を更新"
MPS_I18N[ja:act_remove_all]="管理中の skill をすべて削除"
MPS_I18N[ja:node_missing]="skill の導入/削除には Node.js が必要です — 実行: swkit node install"
MPS_I18N[ja:foot_main]="↑↓ 移動   ↵/space 切替/実行   esc/q 閉じる"
MPS_I18N[ja:confirm_remove_all]="対象エージェントから管理中の Matt Pocock skill をすべて削除しますか?"
MPS_I18N[ja:prompt_agent]="エージェント(例 claude-code、codex、cursor)"
MPS_I18N[ja:prompt_skill]="skill 名(例 migrate-to-shoehorn)"
MPS_I18N[ja:in_agents]="場所"
MPS_I18N[ja:none_installed]="未インストール"
MPS_I18N[ja:setup_note]="導入後に /setup-matt-pocock-skills を実行"
MPS_I18N[ja:no_agents]="対象エージェントが未設定です。"
MPS_I18N[ja:tag_detected]="検出済み"
MPS_I18N[ja:title]="Matt Pocock skills · マルチエージェント"
MPS_I18N[ja:skill_desc:ask-matt]="ルーター:状況に合う skill を選ぶ"
MPS_I18N[ja:skill_desc:codebase-design]="深いモジュール設計の共有語彙"
MPS_I18N[ja:skill_desc:diagnosing-bugs]="難しいバグと性能劣化の診断ループ"
MPS_I18N[ja:skill_desc:domain-modeling]="プロジェクトのドメインモデルを構築・洗練"
MPS_I18N[ja:skill_desc:grill-with-docs]="徹底的な計画面接 + ADR/用語集を生成"
MPS_I18N[ja:skill_desc:improve-codebase-architecture]="深化ポイントを走査(HTML レポート)"
MPS_I18N[ja:skill_desc:prototype]="設計を詰める使い捨てプロトタイプ"
MPS_I18N[ja:skill_desc:setup-matt-pocock-skills]="engineering skills の一度だけの設定"
MPS_I18N[ja:skill_desc:tdd]="テスト駆動開発(レッド-グリーン-リファクタ)"
MPS_I18N[ja:skill_desc:to-issues]="計画/PRD を縦切りの issue に分解"
MPS_I18N[ja:skill_desc:to-prd]="会話を PRD にまとめる"
MPS_I18N[ja:skill_desc:triage]="ステートマシンで issue/PR をトリアージ"
MPS_I18N[ja:skill_desc:grill-me]="計画/設計を磨く徹底面接"
MPS_I18N[ja:skill_desc:grilling]="再利用可能な面接ループ(計画の負荷試験)"
MPS_I18N[ja:skill_desc:handoff]="会話を引き継ぎドキュメントに圧縮"
MPS_I18N[ja:skill_desc:teach]="このワークスペースで技能/概念を教える"
MPS_I18N[ja:skill_desc:writing-great-skills]="優れた skill 作成のリファレンス"

# _mps_t KEY — localized string for $UI_LANG (en/zh/ja); fallback en -> key.
_mps_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${MPS_I18N[$lang:$1]:-${MPS_I18N[en:$1]:-$1}}"
}

# ===============================================================================
# User paths / guards
# ===============================================================================

# Resolve the user's HOME and conf path, refusing a sudo-wrapped run (skills live under $HOME
# and must stay user-owned — same contract as claude.sh). Sets _MPS_HOME / _MPS_CONF.
_mps_user_paths() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run Matt Pocock skills management as your normal user, not via sudo —"
    log_err "skills are written under your HOME, which must stay user-owned."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _MPS_HOME="${HOME:-}"
  [[ -n "$_MPS_HOME" ]] || _MPS_HOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_MPS_HOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _MPS_CONF="$_MPS_HOME/.config/ubuntu-setup/mattpocock-skills.conf"
}

# Node gate for WRITE operations. Reads never call this. Missing Node -> guidance + non-zero.
_mps_node_gate() {
  if have_cmd node && have_cmd npx; then return 0; fi
  log_err "Node.js (npx) is required to install/remove skills via the 'skills' CLI."
  log_err "This script never auto-installs Node. Install it first:  swkit node install"
  return 1
}

# Pass-through to the skills CLI (always npx -y so a missing package is fetched non-interactively).
_mps_npx() { npx -y skills@latest "$@"; }

# ===============================================================================
# Curated tables
# ===============================================================================

# _mps_agent_path AGENT -> absolute GLOBAL skills dir (per the skills CLI README). Non-zero for
# agents outside the curated map (still installable via the CLI; just no on-disk read support).
_mps_agent_path() {
  local home="${_MPS_HOME:-$HOME}"
  case "$1" in
    claude-code)    printf '%s/.claude/skills' "$home" ;;
    codex)          printf '%s/.codex/skills' "$home" ;;
    cursor)         printf '%s/.cursor/skills' "$home" ;;
    opencode)       printf '%s/.config/opencode/skills' "$home" ;;
    gemini-cli)     printf '%s/.gemini/skills' "$home" ;;
    windsurf)       printf '%s/.codeium/windsurf/skills' "$home" ;;
    github-copilot) printf '%s/.copilot/skills' "$home" ;;
    *) return 1 ;;
  esac
}

# _mps_agent_name AGENT -> human display name (proper nouns; UNtranslated).
_mps_agent_name() {
  case "$1" in
    claude-code)    printf 'Claude Code' ;;
    codex)          printf 'Codex' ;;
    cursor)         printf 'Cursor' ;;
    opencode)       printf 'OpenCode' ;;
    gemini-cli)     printf 'Gemini CLI' ;;
    windsurf)       printf 'Windsurf' ;;
    github-copilot) printf 'GitHub Copilot' ;;
    *) printf '%s' "$1" ;;
  esac
}

# _mps_skill_category SKILL -> engineering | productivity | other (for ui() grouping).
_mps_skill_category() {
  case " $_MPS_SKILLS_ENGINEERING " in *" $1 "*) printf 'engineering'; return 0 ;; esac
  case " $_MPS_SKILLS_PRODUCTIVITY " in *" $1 "*) printf 'productivity'; return 0 ;; esac
  printf 'other'
}

_mps_is_curated() {
  case " $_MPS_SKILL_KEYS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ===============================================================================
# Config (pref store; kit-owned, parsed with grep — never sourced)
# ===============================================================================

# An agent is "detected" if the parent of its global skills dir exists (e.g. ~/.claude).
_mps_agent_detected() {
  local p; p="$(_mps_agent_path "$1")" || return 1
  [[ -d "$(dirname "$p")" ]]
}

# Detected curated agents (space-separated), or claude-code as a last resort.
_mps_detected_agents() {
  local a out=""
  for a in $_MPS_AGENT_KEYS; do _mps_agent_detected "$a" && out+="$a "; done
  out="${out% }"
  [[ -n "$out" ]] || out="claude-code"
  printf '%s' "$out"
}

_mps_conf_value() {   # _mps_conf_value KEY -> unquoted value of `KEY="…"` in the conf (or empty)
  local key="$1" line
  [[ -n "${_MPS_CONF:-}" && -f "$_MPS_CONF" ]] || return 0
  line="$(grep -E "^${key}=" "$_MPS_CONF" 2>/dev/null | tail -n1 | cut -d= -f2- || true)"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

# Target agents: persisted AGENTS, else detected default.
_mps_get_agents() {
  local v; v="$(_mps_conf_value AGENTS)"
  [[ -n "$v" ]] && { printf '%s' "$v"; return 0; }
  _mps_detected_agents
}

# Extra (non-curated) skill names the user added through us — kept as re-installable rows.
_mps_get_extra_skills() { _mps_conf_value EXTRA_SKILLS; }

# Rewrite the whole conf (kit-owned state; no backup needed). Callers pass both fields.
_mps_save_conf() {
  local agents="$1" extra="$2" dir
  dir="$(dirname "$_MPS_CONF")"
  mkdir -p "$dir"
  { printf 'AGENTS="%s"\n' "$agents"; printf 'EXTRA_SKILLS="%s"\n' "$extra"; } >"$_MPS_CONF"
}

# Register any non-curated names as EXTRA_SKILLS (so they persist as manageable rows).
_mps_register_extras() {
  local cur extra changed=0 s
  cur="$(_mps_get_agents)"
  extra="$(_mps_get_extra_skills)"
  for s in "$@"; do
    _mps_is_curated "$s" && continue
    case " $extra " in *" $s "*) ;; *) extra="${extra:+$extra }$s"; changed=1 ;; esac
  done
  (( changed )) && _mps_save_conf "$cur" "$extra"
  return 0
}

# All managed skill names: curated 17 + persisted extras (deduped, order: curated then extras).
_mps_managed_skills() {
  local extra s out="$_MPS_SKILL_KEYS"
  extra="$(_mps_get_extra_skills)"
  for s in $extra; do _mps_is_curated "$s" || out+=" $s"; done
  printf '%s' "$out"
}

# ===============================================================================
# State probes (offline filesystem scan — no Node)
# ===============================================================================

_mps_skill_installed_in() {   # SKILL AGENT -> 0 if <agent>/<skill>/SKILL.md exists
  local p; p="$(_mps_agent_path "$2")" || return 1
  [[ -f "$p/$1/SKILL.md" ]]
}

# Agents (among the target set) that have SKILL installed, space-separated.
_mps_skill_agents() {
  local skill="$1" a out=""
  for a in $(_mps_get_agents); do _mps_skill_installed_in "$skill" "$a" && out+="$a "; done
  printf '%s' "${out% }"
}

# Curated skills installed in at least one target agent (one per line).
_mps_installed_curated() {
  local s
  for s in $_MPS_SKILL_KEYS; do
    [[ -n "$(_mps_skill_agents "$s")" ]] && printf '%s\n' "$s"
  done
}

meta() {
  cat <<'META'
key=mattpocock-skills
name=Matt Pocock Skills
category=ai
ops=install,remove,configure,update
desc=Matt Pocock's agent skills — multi-agent installer (via the skills CLI)
META
}

# Exit 0 iff >=1 curated skill is installed in any target agent; print a one-line summary.
status() {
  _mps_user_paths >/dev/null 2>&1 || return 1
  local installed count agents
  installed="$(_mps_installed_curated)"
  [[ -n "$installed" ]] || return 1
  count="$(printf '%s\n' "$installed" | grep -c .)"
  agents="$(_mps_get_agents | tr ' ' ',')"
  printf '%s Matt Pocock skills installed (agents: %s)\n' "$count" "$agents"
}

# ===============================================================================
# Write operations (via the skills CLI)
# ===============================================================================

# _mps_do_add SKILL… — install the named skills into every target agent.
_mps_do_add() {
  _mps_node_gate || return 1
  local -a skills=("$@")
  (( ${#skills[@]} )) || { log_info "No skills specified — nothing to install."; return 0; }
  local agents; agents="$(_mps_get_agents)"
  [[ -n "$agents" ]] || { log_err "$(_mps_t no_agents) Run: ${0##*/} set-agents <agent…>"; return 2; }
  local -a aargs=() sargs=() arr a s
  read -ra arr <<<"$agents"; for a in "${arr[@]}"; do aargs+=(-a "$a"); done
  for s in "${skills[@]}"; do sargs+=(-s "$s"); done
  log_info "Installing [${skills[*]}] into agents: $agents"
  _mps_npx add "$_MPS_SOURCE" -g -y "${aargs[@]}" "${sargs[@]}"
  _mps_register_extras "${skills[@]}"
}

# _mps_do_remove SKILL… — remove the named skills from every target agent.
_mps_do_remove() {
  _mps_node_gate || return 1
  local -a skills=("$@")
  (( ${#skills[@]} )) || { log_info "No skills specified — nothing to remove."; return 0; }
  local agents; agents="$(_mps_get_agents)"
  [[ -n "$agents" ]] || { log_err "$(_mps_t no_agents)"; return 2; }
  local -a aargs=() sargs=() arr a s
  read -ra arr <<<"$agents"; for a in "${arr[@]}"; do aargs+=(-a "$a"); done
  for s in "${skills[@]}"; do sargs+=(-s "$s"); done
  log_info "Removing [${skills[*]}] from agents: $agents"
  _mps_npx remove -g -y "${aargs[@]}" "${sargs[@]}"
}

# install (no args) = the curated 17 to the target agents; or the named skills.
do_install() {
  _mps_user_paths || return 1
  if (( $# )); then
    _mps_do_add "$@"
  else
    local -a all; read -ra all <<<"$_MPS_SKILL_KEYS"
    _mps_do_add "${all[@]}"
  fi
}

# remove (no args) = all managed skills from the target agents; or the named skills.
do_remove() {
  _mps_user_paths || return 1
  if (( $# )); then
    _mps_do_remove "$@"
  else
    local -a all; read -ra all <<<"$(_mps_managed_skills)"
    _mps_do_remove "${all[@]}"
  fi
}

do_update() {
  _mps_user_paths || return 1
  _mps_node_gate || return 1
  _mps_npx update -g -y "$@"
}

do_list() {
  _mps_user_paths || return 1
  _mps_node_gate || return 1
  _mps_npx list -g
}

# Parametric: add/remove specific skills.
do_add_skill() {
  _mps_user_paths || return 1
  (( $# )) || { log_err "Usage: ${0##*/} add-skill <name…>"; return 2; }
  local s
  for s in "$@"; do [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || { log_err "Invalid skill name: $s"; return 2; }; done
  _mps_do_add "$@"
}

do_remove_skill() {
  _mps_user_paths || return 1
  (( $# )) || { log_err "Usage: ${0##*/} remove-skill <name…>"; return 2; }
  local s
  for s in "$@"; do [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || { log_err "Invalid skill name: $s"; return 2; }; done
  _mps_do_remove "$@"
}

# Parametric: manage the target-agent set.
do_set_agents() {
  _mps_user_paths || return 1
  (( $# )) || { log_err "Usage: ${0##*/} set-agents <agent…>"; return 2; }
  local -a valid=() a
  for a in "$@"; do
    [[ "$a" =~ ^[a-z0-9-]+$ ]] || { log_err "Invalid agent name: $a"; return 2; }
    _mps_agent_path "$a" >/dev/null 2>&1 || log_warn "Agent '$a' is outside the curated set — the skills CLI must still recognize it; on-disk status won't be shown for it."
    valid+=("$a")
  done
  _mps_save_conf "${valid[*]}" "$(_mps_get_extra_skills)"
  log_info "Target agents: ${valid[*]}"
}

do_add_agent() {
  _mps_user_paths || return 1
  local a="${1:-}"
  [[ -n "$a" ]] || { log_err "Usage: ${0##*/} add-agent <agent>"; return 2; }
  [[ "$a" =~ ^[a-z0-9-]+$ ]] || { log_err "Invalid agent name: $a"; return 2; }
  local cur; cur="$(_mps_get_agents)"
  case " $cur " in *" $a "*) log_info "Agent '$a' is already a target."; return 0 ;; esac
  _mps_agent_path "$a" >/dev/null 2>&1 || log_warn "Agent '$a' is outside the curated set."
  _mps_save_conf "${cur:+$cur }$a" "$(_mps_get_extra_skills)"
  log_info "Target agents: ${cur:+$cur }$a"
}

do_remove_agent() {
  _mps_user_paths || return 1
  local a="${1:-}"
  [[ -n "$a" ]] || { log_err "Usage: ${0##*/} remove-agent <agent>"; return 2; }
  local cur out="" x
  cur="$(_mps_get_agents)"
  for x in $cur; do [[ "$x" == "$a" ]] || out+="$x "; done
  out="${out% }"
  _mps_save_conf "$out" "$(_mps_get_extra_skills)"
  log_info "Target agents: ${out:-<none>}"
}

# configure: headless, flag-driven. No args = conservative baseline (persist the detected
# target-agent set; install nothing). Opt-in flags layer on installs.
do_configure() {
  _mps_user_paths || return 1
  local recommended=0 set_agents="" add_skills="" touched=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recommended) recommended=1; shift ;;
      --agents)      set_agents="${2:-}"; shift 2 || { log_err "--agents needs a value."; return 2; } ;;
      --agents=*)    set_agents="${1#*=}"; shift ;;
      --skills)      add_skills="${2:-}"; shift 2 || { log_err "--skills needs a value."; return 2; } ;;
      --skills=*)    add_skills="${1#*=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done
  if [[ -n "$set_agents" ]]; then
    local -a ag; read -ra ag <<<"$set_agents"; do_set_agents "${ag[@]}" || return $?; touched=1
  elif [[ ! -f "$_MPS_CONF" ]]; then
    local -a det; read -ra det <<<"$(_mps_detected_agents)"; do_set_agents "${det[@]}" || return $?; touched=1
  fi
  if [[ -n "$add_skills" ]]; then
    local -a sk; read -ra sk <<<"$add_skills"; _mps_do_add "${sk[@]}" || return $?; touched=1
  fi
  if (( recommended )); then
    local -a all; read -ra all <<<"$_MPS_SKILL_KEYS"; _mps_do_add "${all[@]}" || return $?; touched=1
  fi
  (( touched )) || log_info "Baseline ensured (target agents: $(_mps_get_agents)). Use --recommended / --skills / --agents, or the ui."
}

# ===============================================================================
# Interactive management screen (the script's own UI)
# ===============================================================================
# Two checklists — Target agents and Skills — over an Actions block. Reads are offline
# filesystem scans (cheap every frame); each change shells out via ui_run (visible output +
# log) then refreshes. Limited terminals fall back to the synthesized op menu. A missing-Node
# banner is shown but reads still work. `ui` is an entry mode — never a meta op.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  _mps_user_paths >/dev/null 2>&1 || { ui_default_menu; return 0; }
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g refresh=1
  local node_ok=0 agents="" managed=""
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    if (( refresh )); then
      if _mps_node_gate >/dev/null 2>&1; then node_ok=1; else node_ok=0; fi
      agents="$(_mps_get_agents)"
      managed="$(_mps_managed_skills)"
      refresh=0
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    local a s on have total lastcat cat arr2 detail desc

    if (( ! node_ok )); then
      dkind+=(banner); did+=(""); dlabel+=("$(_mps_t node_missing)")
    fi

    # ---- Target agents ----
    dkind+=(header); did+=(""); dlabel+=("$(_mps_t agents_hdr)")
    # union: curated keys, then any configured agents outside the curated set
    local -a agent_rows=() seen
    for a in $_MPS_AGENT_KEYS; do agent_rows+=("$a"); done
    for a in $agents; do
      seen=0; local e; for e in "${agent_rows[@]}"; do [[ "$e" == "$a" ]] && { seen=1; break; }; done
      (( seen )) || agent_rows+=("$a")
    done
    for a in "${agent_rows[@]}"; do
      on=0; case " $agents " in *" $a "*) on=1 ;; esac
      detail=""
      _mps_agent_detected "$a" && detail=" ${UI_MUTED}($(_mps_t tag_detected))${UI_OFF}"
      dkind+=(agent); did+=("$a")
      if (( on )); then
        dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $(_mps_agent_name "$a") ${UI_MUTED}($a)${UI_OFF}$detail")
      else
        dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $(_mps_agent_name "$a") ${UI_MUTED}($a)${UI_OFF}$detail")
      fi
    done
    dkind+=(agent_add); did+=(agent_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_mps_t add_agent)")

    # ---- Skills (grouped by category) ----
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(header); did+=(""); dlabel+=("$(_mps_t skills_hdr)")
    total="$(printf '%s' "$agents" | wc -w)"
    lastcat=""
    for s in $managed; do
      cat="$(_mps_skill_category "$s")"
      if [[ "$cat" != "$lastcat" ]]; then
        lastcat="$cat"
        dkind+=(subhdr); did+=(""); dlabel+=("$(_mps_t "${cat}_hdr")")
      fi
      read -ra arr2 <<<"$(_mps_skill_agents "$s")"
      have="${#arr2[@]}"
      desc="$(_mps_t "skill_desc:$s")"
      detail=""
      (( have > 0 )) && detail=" ${UI_MUTED}[$(_mps_t in_agents): ${arr2[*]}]${UI_OFF}"
      [[ "$s" == "setup-matt-pocock-skills" ]] && detail+=" ${UI_WARN}($(_mps_t setup_note))${UI_OFF}"
      dkind+=(skill); did+=("$s")
      if (( total > 0 && have == total )); then
        dlabel+=("    ${UI_OK}${UI_CHK_ON}${UI_OFF} $s ${UI_MUTED}— $desc${UI_OFF}$detail")
      elif (( have > 0 )); then
        dlabel+=("    ${UI_WARN}${UI_DOT_MID}${UI_OFF} $s ${UI_MUTED}— $desc${UI_OFF}$detail")
      else
        dlabel+=("    ${UI_MUTED}${UI_CHK_OFF} $s — $desc${UI_OFF}")
      fi
    done
    dkind+=(skill_add); did+=(skill_add); dlabel+=("    ${UI_ACCENT}+${UI_OFF} $(_mps_t add_skill)")

    # ---- Actions ----
    dkind+=(spacer); did+=(""); dlabel+=("")
    dkind+=(header); did+=(""); dlabel+=("$(_mps_t actions_hdr)")
    dkind+=(act_install); did+=(act_install); dlabel+=("  ${UI_ACCENT}${UI_ARROW}${UI_OFF} $(_mps_t act_install_all)")
    dkind+=(act_update);  did+=(act_update);  dlabel+=("  ${UI_ACCENT}${UI_ARROW}${UI_OFF} $(_mps_t act_update)")
    dkind+=(act_remove);  did+=(act_remove);  dlabel+=("  ${UI_ERR}${UI_CROSS}${UI_OFF} $(_mps_t act_remove_all)")

    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|subhdr|banner)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|subhdr|banner) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    ui_header "$(_mps_t title)" "${UI_MUTED}${total} $(_mps_t unit_agents)${UI_OFF}"
    local i row=3 top=0 avail=$(( UI_ROWS - 3 - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        banner) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ERR$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        subhdr) ui_move "$row" 4; printf '\033[K%s%s%s' "$UI_MUTED$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_mps_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|subhdr|banner) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|subhdr|banner) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          agent)
            local agrow="${did[$sel]}"
            if case " $agents " in *" $agrow "*) true ;; *) false ;; esac; then
              ui_run "remove-agent $agrow · mattpocock-skills" -- "$0" remove-agent "$agrow"
            else
              ui_run "add-agent $agrow · mattpocock-skills" -- "$0" add-agent "$agrow"
            fi
            refresh=1 ;;
          agent_add)
            if ui_input "$(_mps_t prompt_agent)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "add-agent $UI_INPUT · mattpocock-skills" -- "$0" add-agent "$UI_INPUT"; refresh=1
            fi ;;
          skill)
            local skrow="${did[$sel]}" sk_agents
            sk_agents="$(_mps_skill_agents "$skrow")"
            read -ra arr2 <<<"$sk_agents"; have="${#arr2[@]}"
            total="$(printf '%s' "$agents" | wc -w)"
            if (( total > 0 && have == total )); then
              ui_run "remove-skill $skrow · mattpocock-skills" -- "$0" remove-skill "$skrow"
            else
              ui_run "add-skill $skrow · mattpocock-skills" -- "$0" add-skill "$skrow"
            fi
            refresh=1 ;;
          skill_add)
            if ui_input "$(_mps_t prompt_skill)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "add-skill $UI_INPUT · mattpocock-skills" -- "$0" add-skill "$UI_INPUT"; refresh=1
            fi ;;
          act_install)
            ui_run "install (recommended) · mattpocock-skills" -- "$0" install; refresh=1 ;;
          act_update)
            ui_run "update · mattpocock-skills" -- "$0" update; refresh=1 ;;
          act_remove)
            ui_confirm "$(_mps_t confirm_remove_all)" n \
              && { ui_run "remove (all managed) · mattpocock-skills" -- "$0" remove; refresh=1; } ;;
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

Matt Pocock's agent skills (https://github.com/mattpocock/skills), installed into one or more
coding agents via the open 'skills' CLI (npx skills@latest). Reads scan agent skills dirs on
disk (offline); writes shell out to the CLI and need Node (never auto-installed, never sudo npm).
Target agents are persisted in ~/.config/ubuntu-setup/mattpocock-skills.conf.

Primary:
  install [name…]        Install the recommended 17 (or the named skills) to the target agents.
  remove  [name…]        Remove all managed skills (or the named ones) from the target agents.
  configure [--recommended] [--agents "a b"] [--skills "x y"]
                         Headless setup. No args = persist the detected target-agent set.
  update [name…]         Update installed skills to their latest versions (skills update -g).

Skills / agents (parametric; reachable in the ui):
  add-skill <name…>      Install one or more skills to the target agents.
  remove-skill <name…>   Remove one or more skills from the target agents.
  set-agents <agent…>    Set the managed target-agent set (e.g. claude-code codex cursor).
  add-agent <agent>      Add one agent to the target set.
  remove-agent <agent>   Drop one agent from the target set.
  list                   Pass-through to 'skills list -g'.

Curated skills (the repo's plugin bundle):
  $_MPS_SKILL_KEYS
Curated agents:
  $_MPS_AGENT_KEYS

Other:
  ui                     Open the interactive manager (needs a terminal).
  status                 Summarize installed skills; exit 0 iff any curated skill is installed.
  meta / help            Metadata / this help.
EOF
}

kit_dispatch "$@"
