#!/usr/bin/env bash
#
# bootstrap.sh — set up a fresh Ubuntu machine for LLM-driven software management.
#
# Installs the Claude Code CLI and the Codex CLI (official native installers by
# default, npm as an opt-in fallback), then deploys the bundled skills
# (ubuntu-install, zsh-setup) so you can ask either LLM to manage your machine.
#
# Usage: ./bootstrap.sh [--only claude|codex] [--method native|npm] [--skip-skills]
#
# Idempotent: every step checks the live system first and skips what is already
# in place, so the script is safe to re-run (e.g. after a failure).
#
# Privilege model: run as a normal user. Only the apt dependency top-up
# escalates, one command at a time, via sudo. Running as root also works but is
# not required; `sudo npm install -g` is never used.
#
# Passwordless sudo: after bootstrap the LLM runs `sudo apt-get …` through its own
# Bash tool, which has NO interactive terminal — so it cannot type a sudo password
# and could not install anything. So bootstrap, run here while you DO have a terminal,
# shows a TUI toggle (a whiptail dialog box, falling back to a text [Y/n] prompt) to
# turn passwordless sudo ON or OFF for the invoking user. ON writes a NOPASSWD sudoers
# drop-in (/etc/sudoers.d/ubuntu-setup-llm) granting passwordless root; OFF removes it.
# The toggle shows the current state, so you can flip it either way on any run.
# Non-interactive runs (no terminal) leave it unchanged. There is no command-line flag
# for this — the choice is made through the UI; revoke any time with
# `sudo rm /etc/sudoers.d/ubuntu-setup-llm`.

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
installs the Claude Code CLI and the Codex CLI, then deploys the bundled
skills (ubuntu-install, zsh-setup) so you can ask either LLM to manage it.

Options:
  --only claude|codex   Install only one of the two CLIs (default: both)
  --method native|npm   Install method (default: native = official installer,
                        no Node.js needed; npm requires existing Node >= 18)
  --skip-skills         Do not deploy skills to ~/.claude / ~/.codex
  -h, --help            Show this help and exit

During the run, bootstrap shows a TUI toggle (a whiptail dialog box, or a text
[Y/n] prompt if whiptail is absent) to turn passwordless sudo ON or OFF for the LLM
— its shell has no terminal to type a sudo password, so without it the LLM cannot
install software. The toggle shows the current state and can flip it either way;
non-interactive runs leave it unchanged. There is no flag for this. Revoke later
with: sudo rm /etc/sudoers.d/ubuntu-setup-llm

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

# The real user the LLM will run as (the sudo caller when wrapped, else the
# current user) — the account that should get passwordless sudo.
resolve_target_user() {
  if running_as_sudo_wrapper; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

# Can we prompt the user? Use the controlling terminal, not stdin, so prompts work
# even when the script is piped (curl … | bash). No /dev/tty -> non-interactive.
have_tty() {
  [[ -r /dev/tty && -w /dev/tty ]]
}

# Interactive yes/no prompt on the controlling terminal. $1 = question, $2 = default
# ("y" or "n", used on a bare Enter). Returns 0 for yes, 1 for no. Reads/writes
# /dev/tty directly (never stdin). Caller must have checked have_tty first.
prompt_yes_no() {
  local question="$1" default="${2:-y}" hint reply
  case "$default" in
    y|Y) hint="[Y/n]" ;;
    *)   hint="[y/N]" ;;
  esac
  while true; do
    printf '%s %s ' "$question" "$hint" >/dev/tty
    read -r reply </dev/tty || reply=""
    [[ -z "$reply" ]] && reply="$default"
    case "$reply" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No)    return 1 ;;
      *) printf 'Please answer y or n.\n' >/dev/tty ;;
    esac
  done
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

# Skills shipped to the user's machine. Add a directory under skills/ and its
# name here to deploy it; each must contain a SKILL.md.
SKILLS=(ubuntu-install zsh-setup)

deploy_skills() {
  step "Deploy skills"
  local target_home name src claude_dst codex_prompts
  target_home="$(resolve_target_home)"
  codex_prompts="$target_home/.codex/prompts"

  for name in "${SKILLS[@]}"; do
    src="$SCRIPT_DIR/skills/$name"
    if [[ ! -f "$src/SKILL.md" ]]; then
      error "Skill source not found: $src/SKILL.md (run from a full clone of the repo)."
      exit 1
    fi

    # Claude Code: user-level skill directory (overwrite = idempotent update).
    claude_dst="$target_home/.claude/skills/$name"
    ensure_user_dir "$claude_dst"
    cp -R "$src/." "$claude_dst/"
    maybe_chown_user "$claude_dst"
    info "Claude Code skill -> $claude_dst/"

    # Codex: skill body (frontmatter stripped) as a custom prompt, /$name.
    ensure_user_dir "$codex_prompts"
    strip_frontmatter "$src/SKILL.md" >"$codex_prompts/$name.md"
    maybe_chown_user "$codex_prompts/$name.md"
    info "Codex prompt -> $codex_prompts/$name.md"
  done
}

# --- Passwordless sudo (interactive TUI toggle) ----------------------------------------

readonly SUDOERS_DROPIN="/etc/sudoers.d/ubuntu-setup-llm"

# Is our NOPASSWD drop-in currently active? Probe without ever prompting (sudo -n):
# if sudo itself needs a password, the drop-in can't be granting passwordless access.
passwordless_enabled() {
  sudo -n test -f "$SUDOERS_DROPIN" 2>/dev/null
}

# Write the NOPASSWD drop-in. Best-effort: warn + return (non-fatal) on any failure,
# and never leave an invalid sudoers file behind.
enable_passwordless() {
  local user="$1" line
  line="$user ALL=(ALL) NOPASSWD:ALL"
  info "You may be asked for your sudo password once now to enable this."
  if ! printf '# Created by ubuntu-setup bootstrap.sh. Lets the LLM run sudo (e.g. apt)\n# without a password. Remove this file to revoke.\n%s\n' \
      "$line" | sudo tee "$SUDOERS_DROPIN" >/dev/null; then
    warn "Could not write $SUDOERS_DROPIN (sudo failed). No change."
    return 0
  fi
  sudo chmod 0440 "$SUDOERS_DROPIN" || true
  if command -v visudo >/dev/null 2>&1 && ! sudo visudo -cf "$SUDOERS_DROPIN" >/dev/null 2>&1; then
    sudo rm -f "$SUDOERS_DROPIN" || true
    warn "sudoers validation failed; removed $SUDOERS_DROPIN. No change."
    return 0
  fi
  info "Passwordless sudo ENABLED for '$user' — the LLM can now run apt/sudo unprompted."
}

# Remove our NOPASSWD drop-in. Best-effort.
disable_passwordless() {
  info "You may be asked for your sudo password once now to disable this."
  if sudo rm -f "$SUDOERS_DROPIN"; then
    info "Passwordless sudo DISABLED — removed $SUDOERS_DROPIN."
  else
    warn "Could not remove $SUDOERS_DROPIN. No change."
  fi
}

# Present a TUI toggle for the LLM's passwordless sudo and turn it on/off to match
# the user's choice. Uses whiptail (a real dialog box) when available, else falls
# back to a /dev/tty [Y/n] prompt. The toggle reflects the current state, so the
# user can switch it either way on any run. Non-interactive runs are left untouched.
# The choice is made entirely through the UI — there is no command-line flag.
configure_passwordless_sudo() {
  step "Passwordless sudo for the LLM"
  if ! command -v sudo >/dev/null 2>&1; then
    warn "sudo not available — skipping. The LLM will need you to run sudo commands yourself."
    return 0
  fi
  if ! have_tty; then
    warn "No terminal to show the toggle — leaving passwordless sudo unchanged."
    warn "Re-run ./bootstrap.sh in a terminal to turn it on or off."
    return 0
  fi

  local user state want_on currently_on=0
  user="$(resolve_target_user)"
  passwordless_enabled && currently_on=1
  state="$([[ $currently_on -eq 1 ]] && echo ENABLED || echo disabled)"

  if command -v whiptail >/dev/null 2>&1; then
    local rc=0 args=(--title "ubuntu-setup: LLM passwordless sudo")
    [[ $currently_on -eq 0 ]] && args+=(--defaultno)
    args+=(--yesno "The LLM runs sudo (e.g. apt) in its own shell, which has no
terminal to type a password - so it can only install
software if sudo is passwordless.

Enabling writes:
    ${SUDOERS_DROPIN}
granting '${user}' passwordless root. Revoke any time with:
    sudo rm ${SUDOERS_DROPIN}

Currently: ${state}

Turn passwordless sudo ON for the LLM?" 18 70)
    whiptail "${args[@]}" </dev/tty || rc=$?
    case "$rc" in
      0) want_on=1 ;;
      1) want_on=0 ;;
      *) info "Cancelled — passwordless sudo left ${state,,}."; return 0 ;;
    esac
  else
    info "(whiptail not installed — using a text prompt.)"
    info "The LLM's shell has no terminal to type a sudo password; without passwordless"
    info "sudo it cannot install software. Enabling writes $SUDOERS_DROPIN"
    info "(revoke: sudo rm $SUDOERS_DROPIN). Currently: $state."
    if prompt_yes_no "Turn passwordless sudo ON for the LLM?" \
        "$([[ $currently_on -eq 1 ]] && echo y || echo n)"; then
      want_on=1
    else
      want_on=0
    fi
  fi

  if [[ $want_on -eq 1 && $currently_on -eq 0 ]]; then
    enable_passwordless "$user"
  elif [[ $want_on -eq 0 && $currently_on -eq 1 ]]; then
    disable_passwordless
  elif [[ $want_on -eq 1 ]]; then
    info "Passwordless sudo already enabled — no change."
  else
    info "Passwordless sudo left disabled."
  fi
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
  3. Manage the machine through the LLM, from any directory, e.g.:
       claude:  "Use the ubuntu-install skill to install docker"
       codex:   type '/ubuntu-install' and then ask it to install docker
       claude:  "Use the zsh-setup skill to install and configure zsh"
       codex:   type '/zsh-setup' and ask it to set zsh up safely

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

  # Passwordless-sudo toggle up front (interactive TUI): you have a terminal now, so
  # if you turn it on, that single password entry also warms the credential cache for
  # the apt steps below.
  configure_passwordless_sudo

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
