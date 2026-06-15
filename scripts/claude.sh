#!/usr/bin/env bash
#
# scripts/claude.sh — install / manage the Claude Code CLI on Ubuntu, as a COMPONENT MANAGER.
#
# Beyond installing the CLI, this script manages Claude Code's three extension systems —
# MCP servers, plugins/marketplaces, and skills — each independently, by shelling out to the
# official `claude` CLI (MCP, plugins) or managing files under ~/.claude/skills (skills). The
# native CLI is the authoritative interface: it handles scopes and storage paths and survives
# format changes, so we prefer it over hand-editing ~/.claude.json / settings.json.
#
# install / remove / status manage the CLI binary itself (official native installer by default,
# no Node required; an optional --method npm path for users who already run Node >= 18). This
# script NEVER installs or upgrades Node itself, and NEVER runs `sudo npm`.
#
# Extension actions (kit_dispatch routes <op> -> do_<op>, hyphens -> underscores). They are
# PARAMETRIC and driven by swkit / the LLM / the ui() screen, so they are NOT listed in meta
# ops= (which carries only the no-arg primary ops). Default scope for MCP/plugins is `user`
# (global, all projects) — the "set up my machine" case; pass --scope to override.
#   mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>   (curated names need no args)
#   mcp-remove <name>            ·  mcp-search <term>            (registry search; needs jq)
#   marketplace-add <owner/repo|url|path>  ·  marketplace-remove <name>
#   plugin-install <name@marketplace|curated-name>  ·  plugin-remove <name>
#   plugin-enable <name>         ·  plugin-disable <name>        (toggle without uninstalling)
#   skill-install <git-url|curated-name> [name] [subdir]  ·  skill-remove <name>
#
# All extension files live under the user's HOME and are written AS THE USER, never via sudo;
# extension actions refuse a sudo-wrapped run so ~/.claude stays user-owned.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly _CLAUDE_NPM_PKG="@anthropic-ai/claude-code"
readonly _CLAUDE_MIN_NODE_MAJOR=18

# --- Curated catalogs (the "curated" half of curated+live; arbitrary add is always allowed) ---
# Verified 2026-06-14: npm packages exist; all stdio servers use npx (Node), context7 is HTTP
# (no runtime). Deliberately Node-only (no uv/uvx) so curated quick-adds work with just Node.
readonly _CLAUDE_MCP_CURATED_KEYS="sequential-thinking filesystem memory playwright context7"
# Curated plugin marketplaces (verified 2026-06-14).
readonly _CLAUDE_MKT_CURATED="anthropics/claude-plugins-official anthropics/skills forrestchang/andrej-karpathy-skills"
# Curated plugins (the "curated" half; arbitrary name@marketplace add is always allowed).
# Each curated plugin bundles the marketplace it comes from, so a one-click install can add
# that marketplace first. Verified 2026-06-14.
readonly _CLAUDE_PLUGIN_CURATED_KEYS="andrej-karpathy-skills"
# Curated standalone skills, taken from the official anthropics/skills repo (subdir skills/<n>).
readonly _CLAUDE_SKILL_CURATED_KEYS="pdf docx pptx frontend-design mcp-builder"
# Skills the kit itself deploys to ~/.claude/skills — never let this manager delete them.
readonly _CLAUDE_SKILL_PROTECTED="ubuntu-install zsh-setup claude-extensions"

meta() {
  cat <<'META'
key=claude
name=Claude Code CLI
category=ai
ops=install,remove
desc=Claude Code CLI + extension manager (MCP servers, plugins/marketplaces, skills)
META
}

status() { have_cmd claude && claude --version; }

# ===============================================================================
# The CLI binary: install / remove (unchanged behavior)
# ===============================================================================

do_install() {
  local method="native"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --method)
        method="${2:-}"
        shift 2 || { log_err "--method needs a value (native|npm)."; return 2; }
        ;;
      --method=*) method="${1#--method=}"; shift ;;
      *) log_err "Unknown option: $1"; usage; return 2 ;;
    esac
  done

  if status >/dev/null 2>&1; then
    log_info "Claude Code CLI already installed ($(status 2>/dev/null)) — skipping."
    return 0
  fi

  case "$method" in
    native) _claude_install_native ;;
    npm)    _claude_install_npm ;;
    *) log_err "Unknown --method '$method' (expected: native|npm)."; return 2 ;;
  esac
}

# Official native installer: no Node dependency. Drops the binary in ~/.local/bin.
_claude_install_native() {
  have_cmd curl || apt_install curl ca-certificates
  pkg_installed ca-certificates || apt_install ca-certificates
  log_info "Installing Claude Code CLI via the official native installer..."
  curl -fsSL https://claude.ai/install.sh | bash
  ensure_local_bin_on_path
}

# Optional npm path — only for users who already run a recent Node. We refuse to touch
# Node ourselves, and we never `sudo npm` (npm_global_writable gates on a writable prefix).
_claude_install_npm() {
  local node_major
  if ! have_cmd node || ! have_cmd npm; then
    log_err "Node.js and npm are required for --method npm, but were not found."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  node_major="$(node --version 2>/dev/null)"
  node_major="${node_major#v}"
  node_major="${node_major%%.*}"
  if [[ ! "$node_major" =~ ^[0-9]+$ ]] || (( node_major < _CLAUDE_MIN_NODE_MAJOR )); then
    log_err "Node major version >= ${_CLAUDE_MIN_NODE_MAJOR} is required for --method npm (found: $(node --version 2>/dev/null || echo none))."
    log_err "Use the default native method (no Node needed), or install/upgrade Node"
    log_err "yourself; this script will not auto-install Node."
    return 1
  fi
  npm_global_writable || return 1
  log_info "Installing $_CLAUDE_NPM_PKG via npm (user-space global)..."
  npm install -g "$_CLAUDE_NPM_PKG"
  ensure_local_bin_on_path
}

# Best-effort removal: never sudo. The official native installer has no documented
# uninstall, so we conservatively remove the npm global (if present) and the dropped
# binary, then tell the user what may remain.
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Claude Code CLI is not installed — nothing to remove."
    return 0
  fi

  if have_cmd npm && npm ls -g --depth 0 "$_CLAUDE_NPM_PKG" >/dev/null 2>&1; then
    log_info "Removing $_CLAUDE_NPM_PKG via npm..."
    npm uninstall -g "$_CLAUDE_NPM_PKG" || log_warn "npm uninstall of $_CLAUDE_NPM_PKG failed."
  fi

  if [[ -e "$HOME/.local/bin/claude" ]]; then
    rm -f "$HOME/.local/bin/claude"
  fi

  if have_cmd claude; then
    log_warn "'claude' is still on PATH after removal — it may have been installed by another method or location."
  else
    log_info "Claude Code CLI removed; some data under ~/.config or ~/.local/share may remain — delete it manually for a full cleanup."
  fi
}

# ===============================================================================
# Shared extension-management helpers
# ===============================================================================

# Gate: extension actions need the CLI present. Returns non-zero so callers `|| return 0`.
_claude_gate() {
  status >/dev/null 2>&1 && return 0
  log_info "Claude Code is not installed yet — run 'swkit claude install' first."
  return 1
}

# Resolve the user's HOME / skills dir, refusing a sudo-wrapped run (so ~/.claude stays
# user-owned — same contract as zsh.sh). Sets globals _CHOME / _CSKILLS.
_claude_user_paths() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run Claude Code extension management as your normal user, not via sudo —"
    log_err "it writes ~/.claude, which must stay user-owned."
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _CHOME="${HOME:-}"
  [[ -n "$_CHOME" ]] || _CHOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_CHOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _CSKILLS="$_CHOME/.claude/skills"
}

# ===============================================================================
# Axis 1 — MCP servers (claude mcp …; default --scope user)
# ===============================================================================

# Curated MCP server definition: key -> "transport<TAB>spec<TAB>runtime<TAB>description"
# (spec is the full stdio command, or the URL for http). Returns non-zero for unknown keys.
_claude_mcp_curated() {
  local home="${_CHOME:-$HOME}"
  case "$1" in
    sequential-thinking) printf 'stdio\tnpx -y @modelcontextprotocol/server-sequential-thinking\tNode\tStructured step-by-step reasoning' ;;
    filesystem)          printf 'stdio\tnpx -y @modelcontextprotocol/server-filesystem %s\tNode\tRead/write files under your home' "$home" ;;
    memory)              printf 'stdio\tnpx -y @modelcontextprotocol/server-memory\tNode\tPersistent knowledge-graph memory' ;;
    playwright)          printf 'stdio\tnpx -y @playwright/mcp@latest\tNode\tDrive a real browser (Playwright)' ;;
    context7)            printf 'http\thttps://mcp.context7.com/mcp\t-\tUp-to-date library / API docs' ;;
    *) return 1 ;;
  esac
}

# Exit 0 iff an MCP server named $1 is configured (fast for the common not-present case).
_claude_mcp_present() { claude mcp get "$1" >/dev/null 2>&1; }

# Names of currently configured MCP servers (one per line). Parses `claude mcp list`
# (lines "name: cmd|url - status"; the name is everything before the single ": ").
_claude_mcp_configured_names() {
  claude mcp list 2>/dev/null | sed -n 's/^\(..*\): .* - .*$/\1/p'
}

# Add a curated server by key (idempotent).
_claude_mcp_add_curated() {
  local key="$1" def transport spec
  def="$(_claude_mcp_curated "$key")" || { log_err "Unknown curated MCP server '$key'."; return 2; }
  IFS=$'\t' read -r transport spec _ _ <<<"$def"
  if _claude_mcp_present "$key"; then
    log_info "MCP server '$key' already configured — skipping."
    return 0
  fi
  if [[ "$transport" == stdio && "$spec" == npx* ]] && ! have_cmd node; then
    log_warn "'$key' runs via Node (npx) but Node was not found — install it first: swkit node install"
  fi
  log_info "Adding curated MCP server '$key' ($transport) at user scope…"
  if [[ "$transport" == stdio ]]; then
    local -a cmd; read -r -a cmd <<<"$spec"
    claude mcp add --scope user "$key" -- "${cmd[@]}"
  else
    claude mcp add --transport "$transport" --scope user "$key" "$spec"
  fi
}

_claude_mcp_usage() {
  log_err "Usage: claude mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>"
  log_err "       claude mcp-add <curated-name>            (no other args needed)"
  log_err "Curated MCP servers: $_CLAUDE_MCP_CURATED_KEYS"
}

do_mcp_add() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  if [[ -z "$name" ]]; then _claude_mcp_usage; return 2; fi
  shift
  # Curated shortcut: `mcp-add <curated-name>` with no further args.
  if [[ $# -eq 0 ]] && _claude_mcp_curated "$name" >/dev/null 2>&1; then
    _claude_mcp_add_curated "$name"; return $?
  fi
  local transport="stdio" scope="user"
  local -a envs=() rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--transport)     transport="${2:-}"; shift 2 || { log_err "--transport needs a value."; return 2; } ;;
      -t=*|--transport=*) transport="${1#*=}"; shift ;;
      -s|--scope)         scope="${2:-}"; shift 2 || { log_err "--scope needs a value."; return 2; } ;;
      -s=*|--scope=*)     scope="${1#*=}"; shift ;;
      -e|--env)           envs+=(-e "${2:-}"); shift 2 || { log_err "--env needs K=V."; return 2; } ;;
      -e=*|--env=*)       envs+=(-e "${1#*=}"); shift ;;
      --)                 shift; rest=("$@"); break ;;
      *) log_err "Unexpected argument '$1' — put the command/URL after a literal --."; _claude_mcp_usage; return 2 ;;
    esac
  done
  case "$transport" in stdio|http|sse) ;; *) log_err "--transport must be stdio|http|sse."; return 2 ;; esac
  case "$scope" in local|user|project) ;; *) log_err "--scope must be local|user|project."; return 2 ;; esac
  if [[ ${#rest[@]} -eq 0 ]]; then log_err "Missing command/URL after --."; _claude_mcp_usage; return 2; fi
  if _claude_mcp_present "$name"; then
    log_info "MCP server '$name' already configured — skipping."
    return 0
  fi
  log_info "Adding MCP server '$name' ($transport, scope=$scope)…"
  if [[ "$transport" == stdio ]]; then
    claude mcp add --scope "$scope" "${envs[@]}" "$name" -- "${rest[@]}"
  else
    claude mcp add --transport "$transport" --scope "$scope" "${envs[@]}" "$name" "${rest[0]}"
  fi
}

do_mcp_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude mcp-remove <name>"; return 2; }
  if ! _claude_mcp_present "$name"; then
    log_info "MCP server '$name' is not configured — nothing to remove."
    return 0
  fi
  log_info "Removing MCP server '$name'…"
  claude mcp remove "$name"
}

# Optional live discovery against the official MCP registry (needs jq).
do_mcp_search() {
  local term="${1:-}"
  [[ -n "$term" ]] || { log_err "Usage: claude mcp-search <term>"; return 2; }
  have_cmd curl || { log_err "curl is required for mcp-search."; return 1; }
  if ! have_cmd jq; then
    log_warn "jq not found — registry results need jq to parse."
    log_warn "Install jq, or browse https://registry.modelcontextprotocol.io / https://mcp.so"
    return 1
  fi
  local q="${term// /%20}"
  log_info "Searching the official MCP registry for '$term'…"
  if ! curl -fsS "https://registry.modelcontextprotocol.io/v0/servers?limit=25&search=$q" 2>/dev/null \
       | jq -r '.servers[]? | "  \(.name)  —  \(.description // "")"'; then
    log_err "Registry query failed (network?)."
    return 1
  fi
  log_info "Add one with: swkit claude mcp-add <name> -t <stdio|http> -- <command|url>"
}

# ===============================================================================
# Axis 2 — Plugins & marketplaces (claude plugin …; default --scope user)
# ===============================================================================

_claude_mkt_desc() {
  case "$1" in
    anthropics/claude-plugins-official)  printf 'Official Anthropic plugins' ;;
    anthropics/skills)                   printf 'Official Anthropic skills (as plugins)' ;;
    forrestchang/andrej-karpathy-skills) printf 'Karpathy-inspired Claude Code guidelines' ;;
    *) printf '' ;;
  esac
}

# Curated plugin: key -> "plugin-spec<TAB>marketplace-repo<TAB>description". The spec is the
# full <name@marketplace>; the repo is the marketplace to add as a prerequisite. Returns
# non-zero for unknown keys.
_claude_plugin_curated() {
  case "$1" in
    andrej-karpathy-skills) printf 'andrej-karpathy-skills@karpathy-skills\tforrestchang/andrej-karpathy-skills\tKarpathy-inspired coding guidelines (all projects)' ;;
    *) return 1 ;;
  esac
}

# Exit 0 iff a marketplace whose source contains $1 (owner/repo or name) is configured.
_claude_marketplace_present() { claude plugin marketplace list 2>/dev/null | grep -qiF -- "$1"; }

# Resolve the configured marketplace NAME whose Source line contains repo $1 (for removal).
_claude_marketplace_name_for() {
  claude plugin marketplace list 2>/dev/null | awk -v repo="$1" '
    /Source:/ { if (index($0, repo)) { print name; exit } ; next }
    {
      n=$0; sub(/^[^A-Za-z0-9]*/, "", n); sub(/[[:space:]]*$/, "", n)
      if (n != "" && n !~ /:/ && n !~ /[[:space:]]/) name=n
    }'
}

# Emit "id<TAB>enabled(0/1)" for installed plugins (parses --json; jq-free, stable fields).
_claude_plugins_state() {
  claude plugin list --json 2>/dev/null | awk -F'"' '
    /"id":/      { id=$4; have=1 }
    /"enabled":/ { if (have) { printf "%s\t%d\n", id, ($0 ~ /true/) ? 1 : 0; have=0 } }'
}

# Exit 0 iff a plugin matching $1 (name or name@marketplace) is installed.
_claude_plugin_installed() {
  local spec="$1" name="${1%@*}"
  _claude_plugins_state | awk -F'\t' -v s="$spec" -v n="$name" \
    'BEGIN{f=1} $1==s || index($1, n "@")==1 {f=0} END{exit f}'
}

do_marketplace_add() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local src="${1:-}"
  if [[ -z "$src" ]]; then
    log_err "Usage: claude marketplace-add <owner/repo|git-url|path>"
    log_err "Curated: $_CLAUDE_MKT_CURATED"
    return 2
  fi
  if _claude_marketplace_present "$src"; then
    log_info "Marketplace '$src' already configured — skipping."
    return 0
  fi
  log_info "Adding plugin marketplace '$src'…"
  claude plugin marketplace add "$src"
}

do_marketplace_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude marketplace-remove <name>"; return 2; }
  log_info "Removing plugin marketplace '$name'…"
  claude plugin marketplace remove "$name"
}

# Install a curated plugin by key (idempotent), adding its bundled marketplace first if needed.
_claude_plugin_add_curated() {
  local key="$1" def spec repo
  def="$(_claude_plugin_curated "$key")" || { log_err "Unknown curated plugin '$key'."; return 2; }
  IFS=$'\t' read -r spec repo _ <<<"$def"
  if _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' already installed — skipping."
    return 0
  fi
  if [[ -n "$repo" ]] && ! _claude_marketplace_present "$repo"; then
    log_info "Adding plugin marketplace '$repo' (needed by '$key')…"
    claude plugin marketplace add "$repo"
  fi
  log_info "Installing plugin '$spec' at user scope…"
  claude plugin install --scope user "$spec"
}

do_plugin_install() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local spec="${1:-}"
  if [[ -z "$spec" ]]; then
    log_err "Usage: claude plugin-install <name@marketplace|curated-name>"
    log_err "Curated plugins: $_CLAUDE_PLUGIN_CURATED_KEYS"
    return 2
  fi
  # Curated shortcut: a bare curated name (no @marketplace) installs from its bundled marketplace.
  if [[ "$spec" != *@* ]] && _claude_plugin_curated "$spec" >/dev/null 2>&1; then
    _claude_plugin_add_curated "$spec"; return $?
  fi
  if _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' already installed — skipping."
    return 0
  fi
  log_info "Installing plugin '$spec' at user scope…"
  claude plugin install --scope user "$spec"
}

do_plugin_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local spec="${1:-}"
  [[ -n "$spec" ]] || { log_err "Usage: claude plugin-remove <name>"; return 2; }
  if ! _claude_plugin_installed "$spec"; then
    log_info "Plugin '$spec' is not installed — nothing to remove."
    return 0
  fi
  log_info "Uninstalling plugin '$spec'…"
  claude plugin uninstall "$spec"
}

do_plugin_enable() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local p="${1:-}"; [[ -n "$p" ]] || { log_err "Usage: claude plugin-enable <name>"; return 2; }
  log_info "Enabling plugin '$p'…"
  claude plugin enable "$p"
}

do_plugin_disable() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local p="${1:-}"; [[ -n "$p" ]] || { log_err "Usage: claude plugin-disable <name>"; return 2; }
  log_info "Disabling plugin '$p'…"
  claude plugin disable "$p"
}

# ===============================================================================
# Axis 3 — Skills (file-based: ~/.claude/skills/<name>/SKILL.md)
# ===============================================================================

# Curated standalone skill: key -> "repo<TAB>subdir<TAB>description".
_claude_skill_curated() {
  case "$1" in
    pdf)             printf 'https://github.com/anthropics/skills\tskills/pdf\tFill, parse and generate PDFs' ;;
    docx)            printf 'https://github.com/anthropics/skills\tskills/docx\tCreate and edit Word documents' ;;
    pptx)            printf 'https://github.com/anthropics/skills\tskills/pptx\tCreate and edit PowerPoint decks' ;;
    frontend-design) printf 'https://github.com/anthropics/skills\tskills/frontend-design\tProduce polished web UIs' ;;
    mcp-builder)     printf 'https://github.com/anthropics/skills\tskills/mcp-builder\tScaffold new MCP servers' ;;
    *) return 1 ;;
  esac
}

_claude_skill_protected() {
  case " $_CLAUDE_SKILL_PROTECTED " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Emit "name<TAB>description" for each installed skill.
_claude_skill_list() {
  local d="$_CSKILLS" f nm desc
  [[ -d "$d" ]] || return 0
  shopt -s nullglob
  for f in "$d"/*/SKILL.md; do
    nm="$(basename "$(dirname "$f")")"
    desc="$(sed -n 's/^description:[[:space:]]*//p' "$f" 2>/dev/null | head -1)"
    printf '%s\t%s\n' "$nm" "$desc"
  done
  shopt -u nullglob
}

do_skill_install() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local arg="${1:-}" name="${2:-}" subdir="${3:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: claude skill-install <git-url|curated-name> [name] [subdir]"
    log_err "Curated skills: $_CLAUDE_SKILL_CURATED_KEYS"
    return 2
  fi
  local repo=""
  if _claude_skill_curated "$arg" >/dev/null 2>&1; then
    local def; def="$(_claude_skill_curated "$arg")"
    IFS=$'\t' read -r repo subdir _ <<<"$def"
    name="$arg"
  else
    repo="$arg"
    if [[ -z "$name" ]]; then
      name="$(basename "${subdir:-$repo}")"; name="${name%.git}"
    fi
  fi
  [[ -n "$name" ]] || { log_err "Could not determine a skill name; pass one: skill-install <git> <name> [subdir]"; return 2; }
  local dest="$_CSKILLS/$name"
  if [[ -e "$dest" ]]; then
    log_info "Skill '$name' already present at $dest — skipping (remove it first to reinstall)."
    return 0
  fi
  have_cmd git || apt_install git
  local tmp; tmp="$(mktemp -d)"
  log_info "Cloning $repo …"
  if ! git clone --depth=1 "$repo" "$tmp/repo" >/dev/null 2>&1; then
    rm -rf "$tmp"; log_err "Clone failed: $repo"; return 1
  fi
  local src="$tmp/repo"
  [[ -n "$subdir" ]] && src="$tmp/repo/$subdir"
  if [[ ! -f "$src/SKILL.md" ]]; then
    rm -rf "$tmp"
    log_err "No SKILL.md found${subdir:+ in subdir $subdir} in $repo."
    log_err "For a multi-skill repo, pass the subdir (skill-install <git> <name> <subdir>),"
    log_err "or add it as a plugin marketplace instead (swkit claude marketplace-add <owner/repo>)."
    return 1
  fi
  mkdir -p "$_CSKILLS"
  cp -a "$src" "$dest"
  rm -rf "$tmp"
  log_info "Installed skill '$name' -> $dest"
  log_info "Restart Claude Code (or open a new session) to pick it up."
}

do_skill_remove() {
  _claude_gate || return 0
  _claude_user_paths || return 1
  local name="${1:-}"
  [[ -n "$name" ]] || { log_err "Usage: claude skill-remove <name>"; return 2; }
  if _claude_skill_protected "$name"; then
    log_err "'$name' is a kit-managed skill (deployed by ubuntu-setup) — refusing to remove it here."
    log_err "Remove it through the kit instead if you really mean to."
    return 2
  fi
  local dest="$_CSKILLS/$name"
  if [[ ! -d "$dest" ]]; then
    log_info "Skill '$name' is not installed — nothing to remove."
    return 0
  fi
  local bakdir="$_CHOME/.cache/ubuntu-setup"
  mkdir -p "$bakdir" 2>/dev/null || bakdir="/tmp"
  local bak; bak="$bakdir/skill-${name}-$(date +%Y%m%d-%H%M%S).tar.gz"
  if tar -czf "$bak" -C "$_CSKILLS" "$name" 2>/dev/null; then
    log_info "Backed up '$name' -> $bak"
  else
    log_warn "Backup of '$name' failed; proceeding with removal."
    bak=""
  fi
  rm -rf "$dest"
  log_info "Removed skill '$name'.${bak:+ (backup: $bak)}"
}

# ===============================================================================
# Interactive management screen (the script's own UI) — consolidated extension manager
# ===============================================================================
# A bespoke full-screen panel: install state at top, then three sections — MCP servers,
# Plugins & marketplaces, Skills — each a checklist of curated quick-adds + currently
# configured items + an "add…" row. State is probed live (slow `claude` calls) only on a
# refresh (entry + after each change), then cached; the keypress loop navigates the cache.
# Every change shells out via ui_run (visible output + log), then triggers a refresh.
# Limited terminals fall back to the synthesized op menu. `ui` is an entry mode — never a
# meta op.
_claude_ui_footer() {
  case "$1" in
    plugin) printf '↑↓ move   ↵/space enable/disable   x uninstall   esc/q close' ;;
    *)      printf '↑↓ move   ↵/space toggle/select   esc/q close' ;;
  esac
}

ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g refresh=1
  local installed=0 ver=""
  local mcp_names="" plug_state="" skill_list="" mkt_list=""
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state (only on refresh; these shell out to claude and can be slow) ----
    if (( refresh )); then
      installed=0; ver=""
      if status >/dev/null 2>&1; then
        installed=1
        ver="$(claude --version 2>/dev/null | awk '{print $1}')"
        _claude_user_paths >/dev/null 2>&1 || true
        mcp_names="$(_claude_mcp_configured_names 2>/dev/null || true)"
        plug_state="$(_claude_plugins_state 2>/dev/null || true)"
        skill_list="$(_claude_skill_list 2>/dev/null || true)"
        # Cache the marketplace list ONCE here, like the other slow `claude` probes — the
        # per-keypress render below matches against this cache instead of re-shelling out
        # to `claude plugin marketplace list` every frame (that was the navigation lag).
        mkt_list="$(claude plugin marketplace list 2>/dev/null || true)"
      fi
      refresh=0
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Claude Code CLI")
    else
      local key on nm en def transport rt desc note repo present mkt_lc

      # ---- MCP servers ----
      dkind+=(header); did+=(""); dlabel+=("MCP servers")
      # user-configured servers (exclude plugin/account-managed and curated dups)
      while IFS= read -r nm; do
        [[ -n "$nm" ]] || continue
        case "$nm" in plugin:*|"claude.ai "*) continue ;; esac
        case " $_CLAUDE_MCP_CURATED_KEYS " in *" $nm "*) continue ;; esac
        dkind+=(mcp_user); did+=("$nm"); dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}(configured)${UI_OFF}")
      done <<<"$mcp_names"
      # curated catalog
      for key in $_CLAUDE_MCP_CURATED_KEYS; do
        on=0
        case $'\n'"$mcp_names"$'\n' in *$'\n'"$key"$'\n'*) on=1 ;; esac
        def="$(_claude_mcp_curated "$key")"; IFS=$'\t' read -r transport _ rt desc <<<"$def"
        note=""; [[ "$rt" != "-" ]] && note=" ${UI_MUTED}($rt)${UI_OFF}"
        dkind+=(mcp_curated); did+=("$key")
        if (( on )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
        else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}$note"); fi
      done
      dkind+=(mcp_add); did+=(mcp_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} add MCP server…")

      # ---- Plugins & marketplaces ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Plugins & marketplaces")
      mkt_lc="${mkt_list,,}"   # case-insensitive match against the cached list (no claude call)
      for repo in $_CLAUDE_MKT_CURATED; do
        if [[ "$mkt_lc" == *"${repo,,}"* ]]; then present=1; else present=0; fi
        dkind+=(marketplace); did+=("$repo")
        if (( present )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $repo ${UI_MUTED}— $(_claude_mkt_desc "$repo")${UI_OFF}")
        else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $repo ${UI_MUTED}— $(_claude_mkt_desc "$repo")${UI_OFF}"); fi
      done
      dkind+=(marketplace_add); did+=(marketplace_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} add marketplace…")
      # installed plugins
      local -a installed_plugins=()
      if [[ -n "$plug_state" ]]; then
        while IFS=$'\t' read -r nm en; do
          [[ -n "$nm" ]] || continue
          installed_plugins+=("${nm%@*}")
          dkind+=(plugin); did+=("$nm")
          if [[ "$en" == "1" ]]; then dlabel+=("  ${UI_OK}${UI_DOT_ON}${UI_OFF} $nm ${UI_MUTED}(enabled)${UI_OFF}")
          else dlabel+=("  ${UI_MUTED}${UI_DOT_OFF} $nm (disabled)${UI_OFF}"); fi
        done <<<"$plug_state"
      fi
      # curated plugins not already installed
      for key in $_CLAUDE_PLUGIN_CURATED_KEYS; do
        local palready=0 p
        for p in "${installed_plugins[@]}"; do [[ "$p" == "$key" ]] && { palready=1; break; }; done
        (( palready )) && continue
        def="$(_claude_plugin_curated "$key")"; IFS=$'\t' read -r _ _ desc <<<"$def"
        dkind+=(plugin_curated); did+=("$key")
        dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
      done
      dkind+=(plugin_add); did+=(plugin_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} install plugin…")

      # ---- Skills ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Skills")
      local -a installed_skills=()
      if [[ -n "$skill_list" ]]; then
        while IFS=$'\t' read -r nm desc; do
          [[ -n "$nm" ]] || continue
          installed_skills+=("$nm")
          dkind+=(skill); did+=("$nm")
          if _claude_skill_protected "$nm"; then
            dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}(kit)${UI_OFF}")
          else
            dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $nm ${UI_MUTED}${desc:+— $desc}${UI_OFF}")
          fi
        done <<<"$skill_list"
      fi
      # curated skills not already installed
      for key in $_CLAUDE_SKILL_CURATED_KEYS; do
        local already=0 s
        for s in "${installed_skills[@]}"; do [[ "$s" == "$key" ]] && { already=1; break; }; done
        (( already )) && continue
        def="$(_claude_skill_curated "$key")"; IFS=$'\t' read -r _ _ desc <<<"$def"
        dkind+=(skill_curated); did+=("$key")
        dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $key ${UI_MUTED}— $desc${UI_OFF}")
      done
      dkind+=(skill_add); did+=(skill_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} add skill from git…")

      # ---- danger zone ----
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Claude Code CLI")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Claude Code · extension manager" "${ver:+v$ver }${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "Claude Code · extension manager" "$(ui_t not_installed)"; fi
    local i row=3 top=0 avail=$(( UI_ROWS - 3 - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_claude_ui_footer "${dkind[$sel]}")"
    else ui_footer "↑↓ move   ↵/space install   esc/q close"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      x|X)
        if [[ "${dkind[$sel]}" == plugin ]]; then
          ui_confirm "Uninstall plugin '${did[$sel]}'?" n \
            && { ui_run "plugin-remove ${did[$sel]} · claude" -- "$0" plugin-remove "${did[$sel]}"; refresh=1; }
        fi ;;
      enter|space)
        case "${dkind[$sel]}" in
          install)
            if ui_pick "Claude Code CLI — install method" "" "" -- \
                 native "native (official installer, no Node)" \
                 npm    "npm (needs Node >= ${_CLAUDE_MIN_NODE_MAJOR})" \
               && [[ -n "$UI_PICK" ]]; then
              ui_run "$(ui_t install) Claude Code" -- "$0" install --method "$UI_PICK"; refresh=1
            fi ;;
          remove)
            ui_confirm "Uninstall the Claude Code CLI?" n \
              && { ui_run "$(ui_t remove) Claude Code" -- "$0" remove; refresh=1; } ;;
          mcp_curated)
            local mk="${did[$sel]}"
            if case $'\n'"$mcp_names"$'\n' in *$'\n'"$mk"$'\n'*) true ;; *) false ;; esac; then
              ui_run "mcp-remove $mk · claude" -- "$0" mcp-remove "$mk"
            else
              ui_run "mcp-add $mk · claude" -- "$0" mcp-add "$mk"
            fi
            refresh=1 ;;
          mcp_user)
            ui_confirm "Remove MCP server '${did[$sel]}'?" n \
              && { ui_run "mcp-remove ${did[$sel]} · claude" -- "$0" mcp-remove "${did[$sel]}"; refresh=1; } ;;
          mcp_add)
            if ui_input "MCP server name" ""; then
              local mname="$UI_INPUT"
              if [[ -n "$mname" ]]; then
                ui_pick "Transport for '$mname'" "" "" -- stdio "stdio (local command)" http "http (remote URL)" sse "sse (remote URL)"
                if [[ -n "$UI_PICK" ]]; then
                  local mtr="$UI_PICK" prompt2
                  [[ "$mtr" == stdio ]] && prompt2="command (e.g. npx -y some-mcp)" || prompt2="server URL"
                  if ui_input "$prompt2" ""; then
                    local -a specarr; read -r -a specarr <<<"$UI_INPUT"
                    (( ${#specarr[@]} )) && { ui_run "mcp-add $mname · claude" -- "$0" mcp-add "$mname" -t "$mtr" -- "${specarr[@]}"; refresh=1; }
                  fi
                fi
              fi
            fi ;;
          marketplace)
            local mr="${did[$sel]}"
            if _claude_marketplace_present "$mr"; then
              local mname2; mname2="$(_claude_marketplace_name_for "$mr")"; [[ -n "$mname2" ]] || mname2="$mr"
              ui_confirm "Remove marketplace '$mname2'?" n \
                && { ui_run "marketplace-remove $mname2 · claude" -- "$0" marketplace-remove "$mname2"; refresh=1; }
            else
              ui_run "marketplace-add $mr · claude" -- "$0" marketplace-add "$mr"; refresh=1
            fi ;;
          marketplace_add)
            if ui_input "marketplace (owner/repo, git URL, or path)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "marketplace-add $UI_INPUT · claude" -- "$0" marketplace-add "$UI_INPUT"; refresh=1
            fi ;;
          plugin)
            local pn="${did[$sel]}" pen=0
            case $'\n'"$plug_state"$'\n' in *$'\n'"$pn"$'\t'1$'\n'*) pen=1 ;; esac
            if (( pen )); then ui_run "plugin-disable $pn · claude" -- "$0" plugin-disable "$pn"
            else ui_run "plugin-enable $pn · claude" -- "$0" plugin-enable "$pn"; fi
            refresh=1 ;;
          plugin_curated)
            ui_run "plugin-install ${did[$sel]} · claude" -- "$0" plugin-install "${did[$sel]}"; refresh=1 ;;
          plugin_add)
            if ui_input "plugin (name@marketplace)" "" && [[ -n "$UI_INPUT" ]]; then
              ui_run "plugin-install $UI_INPUT · claude" -- "$0" plugin-install "$UI_INPUT"; refresh=1
            fi ;;
          skill)
            local skn="${did[$sel]}"
            if _claude_skill_protected "$skn"; then
              ui_notify "Skill '$skn'" "This skill is deployed by the ubuntu-setup kit and is protected here."
            else
              ui_confirm "Remove skill '$skn'? (a backup is saved first)" n \
                && { ui_run "skill-remove $skn · claude" -- "$0" skill-remove "$skn"; refresh=1; }
            fi ;;
          skill_curated)
            ui_run "skill-install ${did[$sel]} · claude" -- "$0" skill-install "${did[$sel]}"; refresh=1 ;;
          skill_add)
            if ui_input "skill git URL" "" && [[ -n "$UI_INPUT" ]]; then
              local surl="$UI_INPUT" sname ssub
              ui_input "name (blank = derive)" "" || true; sname="$UI_INPUT"
              ui_input "subdir (blank = repo root)" "" || true; ssub="$UI_INPUT"
              ui_run "skill-install · claude" -- "$0" skill-install "$surl" "$sname" "$ssub"; refresh=1
            fi ;;
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

Claude Code CLI + extension manager. install/remove/status manage the CLI binary; the
remaining commands manage its three extension systems by shelling out to the official
\`claude\` CLI (MCP, plugins) or managing files under ~/.claude/skills (skills). MCP and
plugin actions default to --scope user (global); pass a scope to override. Extension
actions run as your normal user (never via sudo).

CLI binary:
  install [--method native|npm]   Install the CLI (idempotent). native (default): official
                                  installer (no Node). npm: needs Node >= ${_CLAUDE_MIN_NODE_MAJOR} (never sudo npm).
  remove                          Best-effort uninstall (npm global and/or ~/.local/bin/claude).

MCP servers (claude mcp):
  mcp-add <curated-name>          Add a curated server (no other args). Curated:
                                    $_CLAUDE_MCP_CURATED_KEYS
  mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>
                                  Add an arbitrary server (default -t stdio, -s user).
  mcp-remove <name>               Remove a configured MCP server.
  mcp-search <term>               Search the official MCP registry (needs jq).

Plugins & marketplaces (claude plugin):
  marketplace-add <owner/repo|url|path>   Add a plugin marketplace. Curated:
                                    $_CLAUDE_MKT_CURATED
  marketplace-remove <name>       Remove a configured marketplace.
  plugin-install <curated-name>   Install a curated plugin (adds its marketplace first). Curated:
                                    $_CLAUDE_PLUGIN_CURATED_KEYS
  plugin-install <name@marketplace>   Install any plugin (scope user). After adding a
                                  marketplace, browse with: claude plugin list --available
  plugin-remove <name>            Uninstall a plugin.
  plugin-enable <name> / plugin-disable <name>   Toggle a plugin without uninstalling it.

Skills (~/.claude/skills/<name>/):
  skill-install <curated-name>    Install a curated skill. Curated:
                                    $_CLAUDE_SKILL_CURATED_KEYS
  skill-install <git-url> [name] [subdir]   Install any single-skill repo (or a subdir of a
                                  multi-skill repo). Kit-managed skills are protected.
  skill-remove <name>             Remove a skill (a tar backup is saved first).

Other:
  ui                              Open the interactive extension manager (needs a terminal).
  status                          Print 'claude --version'; exit 0 iff installed.
  meta / help                     Metadata / this help.
EOF
}

kit_dispatch "$@"
