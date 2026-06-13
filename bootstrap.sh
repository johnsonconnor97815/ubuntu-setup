#!/usr/bin/env bash
#
# bootstrap.sh — set up a fresh Ubuntu machine for LLM-driven software management.
#
# Installs the Claude Code CLI and the Codex CLI (official native installers by
# default, npm as an opt-in fallback), then deploys the ubuntu-install skill so
# you can ask either LLM to install software for you.
#
# Usage: ./bootstrap.sh [--only claude|codex] [--method native|npm] [--skip-skills]
#
# Idempotent: every step checks the live system first and skips what is already
# in place, so the script is safe to re-run (e.g. after a failure).
#
# Privilege model: run as a normal user. Only the apt dependency top-up
# escalates, one command at a time, via sudo. Running as root also works but is
# not required; `sudo npm install -g` is never used.

set -Eeuo pipefail

# --- Constants ----------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

readonly CLAUDE_INSTALL_URL="https://claude.ai/install.sh"
readonly CODEX_INSTALL_URL="https://chatgpt.com/codex/install.sh"
readonly CLAUDE_NPM_PKG="@anthropic-ai/claude-code"
readonly CODEX_NPM_PKG="@openai/codex"
readonly MIN_NODE_MAJOR=18

# Run state (set by parse_args / main)
ONLY=""           # "" = both, or "claude" / "codex"
METHOD="native"   # "native" (official installer) or "npm"
SKIP_SKILLS=0
CURRENT_STEP="startup"

# --- Logging (stderr; colors only on a tty) ------------------------------------

if [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]; then
  C_INFO=$'\033[1;34m' C_WARN=$'\033[1;33m' C_ERR=$'\033[1;31m' C_OFF=$'\033[0m'
else
  C_INFO="" C_WARN="" C_ERR="" C_OFF=""
fi

info()  { printf '%s[info]%s %s\n'  "$C_INFO" "$C_OFF" "$*" >&2; }
warn()  { printf '%s[warn]%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
error() { printf '%s[error]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; }

step() { CURRENT_STEP="$1"; info "==> $1"; }

on_error() {
  error "Failed during step: ${CURRENT_STEP}."
  error "Fix the cause shown above, then re-run ./bootstrap.sh — completed steps are skipped automatically."
}
trap on_error ERR

# --- Usage ---------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [options]

Sets up a fresh Ubuntu (20.04+) machine for LLM-driven software management:
installs the Claude Code CLI and the Codex CLI, then deploys the
ubuntu-install skill so you can ask either LLM to install software for you.

Options:
  --only claude|codex   Install only one of the two CLIs (default: both)
  --method native|npm   Install method (default: native = official installer,
                        no Node.js needed; npm requires existing Node >= 18)
  --skip-skills         Do not deploy skills to ~/.claude / ~/.codex
  -h, --help            Show this help and exit

The script is idempotent: already-installed components are detected on the
live system and skipped, so it is safe to re-run at any time.
EOF
}

# --- Argument parsing ----------------------------------------------------------

parse_args() {
  while (($#)); do
    case "$1" in
      --only)
        if [[ $# -lt 2 ]]; then
          error "--only requires a value: claude or codex"
          exit 1
        fi
        case "$2" in
          claude|codex) ONLY="$2" ;;
          *)
            error "Invalid --only value '$2' (expected: claude or codex)"
            exit 1
            ;;
        esac
        shift 2
        ;;
      --method)
        if [[ $# -lt 2 ]]; then
          error "--method requires a value: native or npm"
          exit 1
        fi
        case "$2" in
          native|npm) METHOD="$2" ;;
          *)
            error "Invalid --method value '$2' (expected: native or npm)"
            exit 1
            ;;
        esac
        shift 2
        ;;
      --skip-skills)
        SKIP_SKILLS=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        error "Run ./bootstrap.sh --help for usage."
        exit 1
        ;;
    esac
  done
}

# --- Helpers -------------------------------------------------------------------

# True only for fully installed dpkg packages ("install ok installed";
# a removed-but-not-purged package must not count as installed).
pkg_installed() {
  local status
  status="$(dpkg-query -W -f '${Status}' "$1" 2>/dev/null)" || return 1
  [[ "$status" == "install ok installed" ]]
}

# Whether this run is "root acting on behalf of a sudo user".
running_as_sudo_wrapper() {
  [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]
}

# Home directory the skills should land in: the real user's home when the
# script itself was wrapped in sudo, $HOME otherwise. Never the literal `~`.
resolve_target_home() {
  if running_as_sudo_wrapper; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    printf '%s\n' "$HOME"
  fi
}

# mkdir -p that hands ownership of newly created components back to the real
# user when we are root acting for a sudo user.
ensure_user_dir() {
  local dir="$1" d="$1" missing_top=""
  while [[ ! -d "$d" ]]; do
    missing_top="$d"
    d="$(dirname "$d")"
  done
  mkdir -p "$dir"
  if [[ -n "$missing_top" ]] && running_as_sudo_wrapper; then
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$missing_top"
  fi
}

maybe_chown_user() {
  if running_as_sudo_wrapper; then
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$@"
  fi
}

# Print a markdown file minus its leading YAML frontmatter block.
strip_frontmatter() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next }
       fm && $0 == "---"      { fm = 0; next }
       fm                     { next }
                              { print }' "$1"
}

report_version() {
  local cli="$1" ver
  if ver="$("$cli" --version 2>/dev/null)"; then
    info "$cli already installed: $ver — skipping."
  else
    info "$cli already installed (version probe failed) — skipping."
  fi
}

# --- Dependency checks ----------------------------------------------------------

# Install apt packages: plain apt-get as root, per-command sudo otherwise.
# Never re-executes the whole script as root.
apt_install() {
  local apt_prefix=()
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      error "Missing packages: $* — and neither root nor sudo is available."
      error "Ask an administrator to run:"
      error "  apt-get update && apt-get install -y --no-install-recommends $*"
      exit 1
    fi
    apt_prefix=(sudo)
  fi
  info "Installing missing packages (may prompt for your sudo password): $*"
  "${apt_prefix[@]}" DEBIAN_FRONTEND=noninteractive apt-get update
  "${apt_prefix[@]}" DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Dependencies for the native (curl) install method.
ensure_curl_deps() {
  local missing=()
  if ! command -v curl >/dev/null 2>&1; then
    missing+=(curl)
  fi
  if ! pkg_installed ca-certificates; then
    missing+=(ca-certificates)
  fi
  if ((${#missing[@]})); then
    apt_install "${missing[@]}"
  else
    info "curl and ca-certificates already present."
  fi
}

# Prints the major version of an installed node, or fails if node is missing.
node_major_version() {
  local v
  command -v node >/dev/null 2>&1 || return 1
  v="$(node --version 2>/dev/null)" || return 1
  v="${v#v}"
  printf '%s\n' "${v%%.*}"
}

# Dependencies for --method npm. Refuses to install Node.js and refuses any
# path that would lead to `sudo npm install -g`.
ensure_npm_deps() {
  local major prefix target
  if ! major="$(node_major_version)"; then
    error "--method npm requires Node.js >= ${MIN_NODE_MAJOR}, but 'node' was not found."
    error "This script will not install Node.js for you."
    error "Use the default native method instead: ./bootstrap.sh (no --method needed)"
    exit 1
  fi
  if ((major < MIN_NODE_MAJOR)); then
    error "--method npm requires Node.js >= ${MIN_NODE_MAJOR}, found major version ${major}."
    error "Upgrade Node.js yourself, or use the default native method: ./bootstrap.sh"
    exit 1
  fi
  if ! command -v npm >/dev/null 2>&1; then
    error "--method npm requires 'npm', which was not found (node is present)."
    error "Install npm yourself, or use the default native method: ./bootstrap.sh"
    exit 1
  fi
  # Never `sudo npm install -g`: if the global prefix is not user-writable,
  # tell the user the supported fix and stop.
  prefix="$(npm config get prefix)"
  target="$prefix/lib/node_modules"
  [[ -d "$target" ]] || target="$prefix"
  if [[ ! -w "$target" ]]; then
    error "npm's global prefix ($prefix) is not writable by $(id -un)."
    error "Refusing to use 'sudo npm install -g'. Point npm at a user-writable prefix instead:"
    error "  npm config set prefix \"\$HOME/.local\""
    error "then re-run this script."
    exit 1
  fi
  info "Node.js v${major}.x and a user-writable npm prefix ($prefix) found."
}

# --- CLI installs ----------------------------------------------------------------

install_claude() {
  step "Install Claude Code CLI"
  if command -v claude >/dev/null 2>&1; then
    report_version claude
    return 0
  fi
  if [[ "$METHOD" == "npm" ]]; then
    info "Installing via npm: $CLAUDE_NPM_PKG"
    npm install -g "$CLAUDE_NPM_PKG"
  else
    info "Installing via official installer: $CLAUDE_INSTALL_URL"
    curl -fsSL "$CLAUDE_INSTALL_URL" | bash
  fi
}

install_codex() {
  step "Install Codex CLI"
  if command -v codex >/dev/null 2>&1; then
    report_version codex
    return 0
  fi
  if [[ "$METHOD" == "npm" ]]; then
    info "Installing via npm: $CODEX_NPM_PKG"
    npm install -g "$CODEX_NPM_PKG"
  else
    info "Installing via official installer: $CODEX_INSTALL_URL"
    curl -fsSL "$CODEX_INSTALL_URL" | sh
  fi
}

# --- PATH handling -----------------------------------------------------------------

# The native installers land in ~/.local/bin. Make sure it is on PATH: export
# for this process (so verification below works) and append a guarded line to
# the user's shell rc (grep first — never append twice).
ensure_local_bin_on_path() {
  step "Ensure ~/.local/bin is on PATH"
  local local_bin="$HOME/.local/bin" rc_file line
  case ":$PATH:" in
    *":$local_bin:"*)
      info "$local_bin already on PATH."
      return 0
      ;;
  esac
  if [[ ! -d "$local_bin" ]]; then
    info "$local_bin does not exist (nothing was installed there); leaving PATH alone."
    return 0
  fi
  export PATH="$local_bin:$PATH"
  case "${SHELL:-/bin/bash}" in
    */zsh) rc_file="$HOME/.zshrc" ;;
    *)     rc_file="$HOME/.bashrc" ;;
  esac
  line='export PATH="$HOME/.local/bin:$PATH"'
  if [[ -f "$rc_file" ]] && grep -qF "$line" "$rc_file"; then
    info "PATH line already present in $rc_file."
  else
    printf '\n# Added by ubuntu-setup bootstrap.sh\n%s\n' "$line" >>"$rc_file"
    info "Appended PATH line to $rc_file."
  fi
  warn "Run 'source $rc_file' (or open a new shell) so 'claude'/'codex' are found later."
}

# --- Skill deployment -----------------------------------------------------------------

deploy_skills() {
  step "Deploy ubuntu-install skill"
  local src="$SCRIPT_DIR/skills/ubuntu-install"
  local target_home claude_dst codex_prompts
  if [[ ! -f "$src/SKILL.md" ]]; then
    error "Skill source not found: $src/SKILL.md (run from a full clone of the repo)."
    exit 1
  fi
  target_home="$(resolve_target_home)"

  # Claude Code: user-level skill directory (overwrite = idempotent update).
  claude_dst="$target_home/.claude/skills/ubuntu-install"
  ensure_user_dir "$claude_dst"
  cp -R "$src/." "$claude_dst/"
  maybe_chown_user "$claude_dst"
  info "Claude Code skill -> $claude_dst/"

  # Codex: skill body (frontmatter stripped) as a custom prompt, /ubuntu-install.
  codex_prompts="$target_home/.codex/prompts"
  ensure_user_dir "$codex_prompts"
  strip_frontmatter "$src/SKILL.md" >"$codex_prompts/ubuntu-install.md"
  maybe_chown_user "$codex_prompts/ubuntu-install.md"
  info "Codex prompt -> $codex_prompts/ubuntu-install.md"
}

# --- Verification ----------------------------------------------------------------------

verify_cli() {
  local cli="$1" ver
  if ! command -v "$cli" >/dev/null 2>&1; then
    warn "$cli not found on PATH in this shell — open a new shell and run '$cli --version'."
    return 0
  fi
  if ver="$("$cli" --version 2>&1)"; then
    info "$cli: $ver"
  else
    warn "'$cli --version' failed — it may need a new shell. Output: $ver"
  fi
}

print_next_steps() {
  cat <<'EOF'

All done. Next steps:

  1. Sign in to Claude Code:  run 'claude' and follow the login flow.
  2. Sign in to Codex:        run 'codex' and follow the login flow.
  3. Install software through the LLM, from any directory, e.g.:
       claude:  "Use the ubuntu-install skill to install docker"
       codex:   type '/ubuntu-install' and then ask it to install docker

Re-running ./bootstrap.sh at any time is safe — installed components are skipped.
EOF
}

# --- Main ------------------------------------------------------------------------------

main() {
  parse_args "$@"

  if running_as_sudo_wrapper; then
    warn "You ran this script under sudo as a whole. That is not recommended:"
    warn "the CLIs will be installed into root's home, not yours. Prefer running"
    warn "as your normal user — sudo is applied per command only where required."
    warn "Skills will still be deployed to the real user's home: $(resolve_target_home)"
  fi

  local want_claude=1 want_codex=1 need_install=0
  case "$ONLY" in
    claude) want_codex=0 ;;
    codex)  want_claude=0 ;;
  esac

  if [[ $want_claude -eq 1 ]] && ! command -v claude >/dev/null 2>&1; then
    need_install=1
  fi
  if [[ $want_codex -eq 1 ]] && ! command -v codex >/dev/null 2>&1; then
    need_install=1
  fi

  step "Check dependencies"
  if [[ $need_install -eq 1 ]]; then
    if [[ "$METHOD" == "npm" ]]; then
      ensure_npm_deps
    else
      ensure_curl_deps
    fi
  else
    info "Requested CLIs are already installed; no dependencies needed."
  fi

  if [[ $want_claude -eq 1 ]]; then
    install_claude
  fi
  if [[ $want_codex -eq 1 ]]; then
    install_codex
  fi

  ensure_local_bin_on_path

  if [[ $SKIP_SKILLS -eq 1 ]]; then
    info "Skipping skill deployment (--skip-skills)."
  else
    deploy_skills
  fi

  step "Verify installation"
  if [[ $want_claude -eq 1 ]]; then
    verify_cli claude
  fi
  if [[ $want_codex -eq 1 ]]; then
    verify_cli codex
  fi

  print_next_steps
}

# Run main only when executed, not when sourced (sourcing enables function-level tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
