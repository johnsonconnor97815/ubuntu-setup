#!/usr/bin/env bash
#
# bootstrap.sh — turn a fresh Ubuntu machine into an LLM-driven software manager.
#
# The real work of installing/configuring software lives in a COLLECTION OF SCRIPTS
# (lib/ + scripts/) — one script per piece of software, each with a uniform interface
# (install/remove/configure/status/meta) AND its own interactive screen (the `ui` entry
# mode). Three entry points drive those scripts:
#   1. this launcher's TUI (a modern full-screen renderer in lib/ui.sh, with a plain-text
#      fallback and no whiptail dependency),
#   2. a human running `swkit <software> <op>` directly,
#   3. the LLM, via the bundled skills.
# The LLM is special: besides RUNNING scripts it ORGANISES, RECOMMENDS, and EVOLVES
# them — authoring a new script for software not yet covered, fixing stale ones. So
# "coverage" grows over time; this bootstrap ships a seed set plus the machinery.
#
# bootstrap.sh itself is a LAUNCHER: it ensures a few dependencies (git/curl/ca-certificates),
# DEPLOYS the script collection to a git-tracked dir ($KIT_HOME = ~/.local/share/ubuntu-setup)
# so the LLM's edits are versioned and survive updates (vendor-branch + merge, never a blind
# clobber), deploys the skills, then opens the TUI: "Install software" hands off to the
# shared catalog browser (ui_catalog) which lists scripts by category and drills into each
# script's OWN ui(); a Settings page switches language and toggles passwordless sudo.
#
# Usage: ./bootstrap.sh [--only claude|codex] [--method native|npm] [--with-node]
#                       [--skip-skills] [--headless] [--tui]
#
# With a terminal and no scripting flags it runs the TUI. Pass any install flag (or run
# without a terminal, e.g. in CI) and it runs headless instead, honouring those flags.
#
# Idempotent: every step checks the live system and skips what is already in place, so
# the script is safe to re-run. Privilege model: run as a normal user; only apt and a
# couple of config steps escalate, one command at a time, via sudo. `sudo npm install -g`
# is never used. See lib/common.sh for the shared safety contract.

set -Eeuo pipefail

# --- Constants & shared library ------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# The safety primitives (sudo_run, apt_install/apt_remove, pkg_installed, have_cmd,
# backup_file, append_once, ensure_local_bin_on_path, …) live in the library the scripts
# also use, so bootstrap and the scripts share one implementation.
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Run state (set by parse_args / main)
ONLY=""           # "" = both, or "claude" / "codex"  (headless only)
METHOD="native"   # "native" (official installer) or "npm"  (headless only)
SKIP_SKILLS=0
WITH_NODE=0       # headless: also install Node.js + npm
HEADLESS=0        # forced headless by a scripting flag
FORCE_TUI=0       # --tui forces the menu when a terminal is present
LANG_CODE="en"    # interface language: en / zh / ja
CURRENT_STEP="startup"
KIT_HOME_DIR=""   # resolved in main(): ~/.local/share/ubuntu-setup

# --- Logging (stderr; colors only on a tty) ------------------------------------
# bootstrap keeps its own step-aware logger; the library's log_* names coexist and are
# used by the scripts. User-facing TUI strings are translated; these logs stay English
# (they land in a log file or the boot console, not in front of the menu user).

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

# --- Interface strings (i18n) --------------------------------------------------
# t KEY prints the string for the active LANG_CODE, falling back to English then the key.
# Only fixed UI chrome is translated; software DISPLAY NAMES come from each script's meta
# (the collection is open/LLM-extensible, so per-software names can't be pre-translated).

declare -A MSG

MSG[en:app_title]="ubuntu-setup"
MSG[zh:app_title]="ubuntu-setup"
MSG[ja:app_title]="ubuntu-setup"

# Top-menu subtitle (single line — drawn on one row by the UI).
MSG[en:main_prompt]="LLM-driven Ubuntu software setup"
MSG[zh:main_prompt]="LLM 驱动的 Ubuntu 软件配置"
MSG[ja:main_prompt]="LLM 駆動の Ubuntu ソフトウェアセットアップ"

MSG[en:m_install]="Install software"
MSG[zh:m_install]="安装软件"
MSG[ja:m_install]="ソフトウェアをインストール"

MSG[en:m_settings]="Settings"
MSG[zh:m_settings]="设置"
MSG[ja:m_settings]="設定"

MSG[en:m_quit]="Quit"
MSG[zh:m_quit]="退出"
MSG[ja:m_quit]="終了"

# Catalog / per-software / operation chrome now lives in lib/ui.sh's ui_t table (the
# scripts render their own UIs), so bootstrap keeps only its own top-menu/settings strings.

MSG[en:set_prompt]="Settings:"
MSG[zh:set_prompt]="设置:"
MSG[ja:set_prompt]="設定:"

MSG[en:s_language]="Language / 语言 / 言語"
MSG[zh:s_language]="语言 / Language"
MSG[ja:s_language]="言語 / Language"

MSG[en:s_sudo]="Passwordless sudo for the LLM"
MSG[zh:s_sudo]="LLM 免密 sudo"
MSG[ja:s_sudo]="LLM 用パスワードなし sudo"

MSG[en:s_back]="Back"
MSG[zh:s_back]="返回"
MSG[ja:s_back]="戻る"

MSG[en:lang_prompt]="Choose the interface language:"
MSG[zh:lang_prompt]="选择界面语言:"
MSG[ja:lang_prompt]="インターフェース言語を選択:"

MSG[en:sudo_title]="ubuntu-setup: LLM passwordless sudo"
MSG[zh:sudo_title]="ubuntu-setup:LLM 免密 sudo"
MSG[ja:sudo_title]="ubuntu-setup:LLM 用パスワードなし sudo"

# sudo_off_q: %s = user, %s = drop-in path. Shown when passwordless sudo is currently OFF.
MSG[en:sudo_off_q]=$'The LLM runs sudo (e.g. apt) in its own shell, with no terminal\nto type a password — so it can only install software if sudo is\npasswordless. Enabling grants \'%s\' passwordless root via\n    %s\n(revoke any time:  sudo rm that file).\n\nEnable passwordless sudo for the LLM?'
MSG[zh:sudo_off_q]=$'LLM 在自己的 shell 里执行 sudo(如 apt),该环境没有终端\n无法输入密码——所以只有 sudo 免密时它才能安装软件。开启将\n授予 \'%s\' 免密 root,写入\n    %s\n(随时可撤销:sudo rm 该文件)。\n\n为 LLM 开启免密 sudo?'
MSG[ja:sudo_off_q]=$'LLM は自身のシェルで sudo(apt 等)を実行しますが、パスワード\nを入力する端末がありません。sudo がパスワードなしの場合のみ\nインストールできます。有効化は \'%s\' に免パス root を付与し\n    %s\nに書き込みます(取り消し:sudo rm 該当ファイル)。\n\nLLM 用にパスワードなし sudo を有効にしますか?'

MSG[en:sudo_on_q]="Passwordless sudo is currently ENABLED for the LLM. Disable it?"
MSG[zh:sudo_on_q]="当前已为 LLM 启用免密 sudo。要禁用吗?"
MSG[ja:sudo_on_q]="現在 LLM 用のパスワードなし sudo は有効です。無効にしますか?"

MSG[en:no_sudo_msg]="sudo is not available — skipping. The LLM will need you to run sudo commands yourself."
MSG[zh:no_sudo_msg]="系统没有 sudo,跳过。LLM 之后需要你自己执行 sudo 命令。"
MSG[ja:no_sudo_msg]="sudo がありません。スキップします。sudo コマンドはご自身で実行してください。"

t() {
  local key="${LANG_CODE}:$1"
  if [[ -n "${MSG[$key]:-}" ]]; then
    printf '%s' "${MSG[$key]}"
  else
    printf '%s' "${MSG[en:$1]:-$1}"
  fi
}

# --- Usage ---------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: ./bootstrap.sh [options]

Sets up a fresh Ubuntu (20.04+) machine for LLM-driven software management. The actual
install/configure logic lives in a collection of scripts (scripts/*.sh) backed by a
shared library (lib/common.sh); bootstrap deploys that collection to a git-tracked dir
(~/.local/share/ubuntu-setup), deploys the skills, and provides a TUI front end.

With a terminal and no scripting flags it opens a modern full-screen TUI (lib/ui.sh, with a
plain-text fallback — no whiptail needed): "Install software" browses the script collection
by category and drills into each script's OWN interactive screen (install/remove/configure/
plugins/…), and a Settings page switches language and toggles passwordless sudo for the LLM.
Run scripts directly with `swkit <software> <op>` (or `swkit <software>` for its screen),
or ask the LLM (it can also author/evolve scripts for software not yet covered).

Headless options (any of these, or no terminal, switches off the TUI):
  --only claude|codex   Install only one of the two CLIs (default: both)
  --method native|npm   Install method (default: native = official installer,
                        no Node.js needed; npm requires existing Node >= 18)
  --with-node           Also install Node.js + npm via apt
  --skip-skills         Do not deploy skills to ~/.claude / ~/.codex
  --headless            Force the non-interactive flow even with a terminal
  --tui                 Force the TUI even when scripting flags are present
  -h, --help            Show this help and exit

Passwordless sudo for the LLM is toggled only through the UI (Settings page or, in
headless runs, a one-off prompt) — there is no flag. Revoke later with:
  sudo rm /etc/sudoers.d/ubuntu-setup-llm

The script is idempotent: already-installed components are detected on the live system
and skipped, so it is safe to re-run at any time.
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
        HEADLESS=1
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
        HEADLESS=1
        shift 2
        ;;
      --with-node)
        WITH_NODE=1
        HEADLESS=1
        shift
        ;;
      --skip-skills)
        SKIP_SKILLS=1
        HEADLESS=1
        shift
        ;;
      --headless)
        HEADLESS=1
        shift
        ;;
      --tui)
        FORCE_TUI=1
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

# Whether this run is "root acting on behalf of a sudo user".
running_as_sudo_wrapper() {
  [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]
}

# Home directory the kit/skills should land in: the real user's home when the script
# itself was wrapped in sudo, $HOME otherwise. Never the literal `~`.
resolve_target_home() {
  if running_as_sudo_wrapper; then
    getent passwd "$SUDO_USER" | cut -d: -f6
  else
    printf '%s\n' "$HOME"
  fi
}

# The real user the LLM will run as (the sudo caller when wrapped, else the current user).
resolve_target_user() {
  if running_as_sudo_wrapper; then
    printf '%s\n' "$SUDO_USER"
  else
    id -un
  fi
}

# Can we prompt the user? Actually try to OPEN /dev/tty for read and write — the device
# node can exist (passing -r/-w tests) yet fail to open with ENXIO when there is no
# controlling terminal (cron, nohup, the LLM's shell), which would wrongly route us into
# the TUI. No openable /dev/tty -> headless.
have_tty() {
  { true </dev/tty; } 2>/dev/null && { true >/dev/tty; } 2>/dev/null
}

# Interactive yes/no, info boxes and menus now come from lib/ui.sh (ui_confirm / ui_notify
# / ui_pick / ui_catalog) — a modern full-screen renderer with a plain-text fallback, no
# whiptail dependency. bootstrap composes those primitives below.

# mkdir -p that hands ownership of newly created components back to the real user when we
# are root acting for a sudo user.
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
    chown -R "$SUDO_USER:$(id -gn "$SUDO_USER")" "$@" 2>/dev/null || true
  fi
}

# Print a markdown file minus its leading YAML frontmatter block.
strip_frontmatter() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next }
       fm && $0 == "---"      { fm = 0; next }
       fm                     { next }
                              { print }' "$1"
}

# --- Language config (persisted under the target home) -------------------------

config_path() { printf '%s/.config/ubuntu-setup/config\n' "$(resolve_target_home)"; }

default_lang() {
  case "${LANG:-}" in
    zh*) printf 'zh\n' ;;
    ja*) printf 'ja\n' ;;
    *)   printf 'en\n' ;;
  esac
}

load_config() {
  local f
  f="$(config_path)"
  # shellcheck disable=SC1090
  [[ -f "$f" ]] && source "$f" 2>/dev/null || true
  case "${LANG_CODE:-}" in
    zh|en|ja) ;;
    *) LANG_CODE="$(default_lang)" ;;
  esac
}

save_lang() {
  local f dir
  f="$(config_path)"
  dir="$(dirname "$f")"
  ensure_user_dir "$dir"
  printf 'LANG_CODE=%s\n' "$LANG_CODE" >"$f"
  maybe_chown_user "$f"
}

# --- Passwordless sudo (interactive toggle, Settings page) ---------------------

readonly SUDOERS_DROPIN="/etc/sudoers.d/ubuntu-setup-llm"

# Is our NOPASSWD drop-in currently active? Probe without ever prompting (sudo -n).
passwordless_enabled() {
  sudo -n test -f "$SUDOERS_DROPIN" 2>/dev/null
}

# Write the NOPASSWD drop-in. Best-effort: warn + return on any failure, never leave an
# invalid sudoers file behind.
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

# Present the toggle (ui_confirm modal, text fallback) and flip it to match the choice.
# The privileged write runs via ui_run, which leaves the full-screen UI so sudo can prompt
# for the password on the real terminal. Non-interactive runs are left untouched (UI-only,
# no flag — per the project's "toggle via UI prompt, not a CLI flag" rule).
configure_passwordless_sudo() {
  if ! command -v sudo >/dev/null 2>&1; then
    if have_tty; then ui_notify "$(t sudo_title)" "$(t no_sudo_msg)"; else warn "sudo not available — skipping."; fi
    return 0
  fi
  if ! have_tty; then
    warn "No terminal to show the passwordless-sudo toggle — leaving it unchanged."
    warn "Re-run ./bootstrap.sh in a terminal to turn it on or off."
    return 0
  fi

  local user currently_on=0
  user="$(resolve_target_user)"
  passwordless_enabled && currently_on=1

  if [[ $currently_on -eq 1 ]]; then
    if ui_confirm "$(t sudo_on_q)" n; then
      ui_run "$(t sudo_title)" -- disable_passwordless
    fi
  else
    # shellcheck disable=SC2059
    if ui_confirm "$(printf "$(t sudo_off_q)" "$user" "$SUDOERS_DROPIN")" n; then
      ui_run "$(t sudo_title)" -- enable_passwordless "$user"
    fi
  fi
}

# --- Kit deployment (the script collection -> a git-tracked $KIT_HOME) ----------
# The collection (lib/ scripts/ swkit) is deployed to ~/.local/share/ubuntu-setup, which
# is a git repo. The shipped tree lives on a `vendor` branch; the user/LLM work on `main`.
# Updates refresh `vendor` and `git merge` it into `main`, so LLM-authored scripts are
# preserved and shipped changes that conflict with local edits are surfaced (not clobbered).

kit_home() { printf '%s/.local/share/ubuntu-setup\n' "$(resolve_target_home)"; }

# Directory bootstrap runs scripts from: the deployed kit when present, else the repo.
kit_scripts_dir() {
  if [[ -d "$KIT_HOME_DIR/scripts" ]]; then
    printf '%s/scripts\n' "$KIT_HOME_DIR"
  else
    printf '%s/scripts\n' "$SCRIPT_DIR"
  fi
}

# git wrapper for the kit repo, with a fixed identity (so commits never need user config).
kit_git() {
  git -C "$KIT_HOME_DIR" -c user.name='ubuntu-setup' -c user.email='ubuntu-setup@localhost' "$@"
}

# Replace the vendored entries (lib/ scripts/ swkit) with a pristine copy from the repo.
# rm-then-copy so files removed upstream don't linger; never touches non-vendored files.
kit_lay_down_vendor() {
  local e
  for e in lib scripts; do
    rm -rf "${KIT_HOME_DIR:?}/$e"
    cp -R "$SCRIPT_DIR/$e" "$KIT_HOME_DIR/$e"
  done
  cp -f "$SCRIPT_DIR/swkit" "$KIT_HOME_DIR/swkit"
  chmod +x "$KIT_HOME_DIR/swkit" "$KIT_HOME_DIR"/scripts/*.sh 2>/dev/null || true
}

# Plain (untracked) copy — used when git is unavailable or under a sudo wrapper. Merges
# the shipped files in, overwriting same-named files but keeping any others.
deploy_kit_copy() {
  local e
  for e in lib scripts; do
    ensure_user_dir "$KIT_HOME_DIR/$e"
    cp -R "$SCRIPT_DIR/$e/." "$KIT_HOME_DIR/$e/"
  done
  cp -f "$SCRIPT_DIR/swkit" "$KIT_HOME_DIR/swkit"
  chmod +x "$KIT_HOME_DIR/swkit" "$KIT_HOME_DIR"/scripts/*.sh 2>/dev/null || true
}

# git-tracked deploy: init on first run (main + vendor), else refresh vendor and merge
# into main. Each fallible git step is checked explicitly so it works regardless of the
# surrounding errexit context, returning non-zero to let the caller fall back to a copy.
deploy_kit_git() {
  if [[ ! -d "$KIT_HOME_DIR/.git" ]]; then
    kit_git init -q || return 1
    kit_git checkout -q -B main || return 1
    kit_lay_down_vendor
    kit_git add -A || return 1
    kit_git commit -q -m "Initial kit (shipped by bootstrap.sh)" || return 1
    kit_git branch -f vendor || return 1
    info "Initialized kit repo at $KIT_HOME_DIR (branches: main, vendor)."
    return 0
  fi

  # Recover from an interrupted prior run that left the repo on the vendor branch: force
  # back to main, discarding any stray vendor-side working-tree changes. vendor is
  # pristine (only bootstrap writes it), so nothing of the user's/LLM's lives there to
  # lose — whereas carrying that stray state onto main could poison the scripts that run.
  local cur
  cur="$(kit_git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [[ "$cur" != "main" ]]; then
    warn "Kit repo was left on '${cur:-?}' (interrupted update?) — restoring main."
    kit_git checkout -q -f main || return 1
  fi
  if ! kit_git diff --quiet || ! kit_git diff --cached --quiet; then
    info "Local changes in $KIT_HOME_DIR — committing a snapshot before updating."
    kit_git add -A || return 1
    kit_git commit -q -m "Snapshot of local changes before kit update" || true
  fi

  kit_git checkout -q vendor || return 1
  kit_lay_down_vendor
  kit_git add -A || return 1
  if kit_git diff --cached --quiet; then
    info "Shipped kit unchanged — nothing to update."
    kit_git checkout -q main || return 1
    return 0
  fi
  kit_git commit -q -m "vendor: sync shipped kit" || return 1
  kit_git checkout -q main || return 1

  if kit_git merge --no-edit vendor >/dev/null 2>&1; then
    info "Merged shipped kit updates into $KIT_HOME_DIR."
  else
    local conflicts
    conflicts="$(kit_git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ' ')"
    kit_git merge --abort 2>/dev/null || true
    warn "Shipped updates conflict with your local changes to: ${conflicts}"
    warn "Left your version in place. Reconcile with:  git -C $KIT_HOME_DIR merge vendor"
  fi
}

deploy_kit() {
  step "Deploy script collection to $KIT_HOME_DIR"
  ensure_user_dir "$KIT_HOME_DIR"

  if running_as_sudo_wrapper; then
    warn "Running under sudo — deploying the kit without git tracking."
    warn "Run as your normal user for a tracked, LLM-evolvable deployment."
    deploy_kit_copy
    maybe_chown_user "$KIT_HOME_DIR"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    info "git not found; trying to install it for change-tracked deployment..."
    apt_install git || { warn "Could not install git — deploying without version tracking."; deploy_kit_copy; return 0; }
  fi

  deploy_kit_git || { warn "git deploy hit a problem — falling back to a plain copy."; deploy_kit_copy; }
}

# Symlink swkit onto the user's PATH and make sure ~/.local/bin is on PATH.
install_swkit_path() {
  local bindir
  bindir="$(resolve_target_home)/.local/bin"
  ensure_user_dir "$bindir"
  ln -sf "$KIT_HOME_DIR/swkit" "$bindir/swkit"
  if running_as_sudo_wrapper; then
    chown -h "$SUDO_USER:$(id -gn "$SUDO_USER")" "$bindir/swkit" 2>/dev/null || true
  fi
  ensure_local_bin_on_path
  info "swkit -> $bindir/swkit (run 'swkit list' to browse the collection)."
}

# --- Skill deployment ----------------------------------------------------------
# Skills shipped to the user's machine. Add a directory under skills/ and its name here.

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

# --- Interactive flows (front end composed from lib/ui.sh) ---------------------
# bootstrap is a launcher. It opens a top-level menu, hands "Install software" to the
# shared catalog browser (ui_catalog — it lists every script by category, marks installed
# ones, and drills into each script's OWN ui()), and keeps a Settings page for the two
# things only bootstrap owns (interface language + passwordless sudo). The whole session
# runs inside one alt-screen (ui_begin/ui_end); ui_catalog/ui_confirm/ui_run suspend and
# restore it around child scripts and privileged commands as needed.

tui_language() {
  ui_pick "$(t s_language)" "$(t lang_prompt)" "" -- \
    zh "中文" en "English" ja "日本語" || return 0
  case "$UI_PICK" in
    zh|en|ja) LANG_CODE="$UI_PICK"; export UI_LANG="$LANG_CODE"; save_lang ;;
  esac
}

tui_settings() {
  while true; do
    ui_pick "$(t m_settings)" "$(t set_prompt)" "" -- \
      language "$(t s_language)" \
      sudo     "$(t s_sudo)" \
      back     "$(t s_back)" || return 0
    case "$UI_PICK" in
      language) tui_language ;;
      sudo)     configure_passwordless_sudo ;;
      back|"")  return 0 ;;
    esac
  done
}

run_tui() {
  ui_begin || { warn "Could not open the interactive UI (no usable terminal)."; return 0; }
  while true; do
    ui_pick "$(t app_title)" "$(t main_prompt)" "" -- \
      install  "$(t m_install)" \
      settings "$(t m_settings)" \
      quit     "$(t m_quit)" || break
    case "$UI_PICK" in
      install)  ui_catalog "$(kit_scripts_dir)" ;;
      settings) tui_settings ;;
      quit|"")  break ;;
    esac
  done
  ui_end
}

# --- Verification (headless) ---------------------------------------------------

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
  3. Manage the machine through the LLM, or directly with swkit, e.g.:
       swkit list                       # browse the script collection
       swkit docker install             # run a script yourself
       claude:  "Use the ubuntu-install skill to install docker"
       codex:   type '/ubuntu-install' and then ask it to install docker

Re-running ./bootstrap.sh at any time is safe — installed components are skipped, and
the script collection is updated without losing scripts the LLM has authored.
EOF
}

# --- Headless flow -------------------------------------------------------------

run_headless() {
  # Passwordless-sudo toggle up front: you have a terminal now, so enabling it also warms
  # the credential cache for the apt steps (kit deps, CLI installs) that follow.
  configure_passwordless_sudo

  deploy_kit
  install_swkit_path

  local dir; dir="$(kit_scripts_dir)"
  local want_claude=1 want_codex=1
  case "$ONLY" in
    claude) want_codex=0 ;;
    codex)  want_claude=0 ;;
  esac

  local -a method_args=()
  [[ "$METHOD" == "npm" ]] && method_args=(--method npm)

  step "Install requested CLIs"
  if [[ $want_claude -eq 1 ]]; then "$dir/claude.sh" install "${method_args[@]}"; fi
  if [[ $want_codex  -eq 1 ]]; then "$dir/codex.sh"  install "${method_args[@]}"; fi
  if [[ $WITH_NODE   -eq 1 ]]; then "$dir/node.sh"   install; fi

  if [[ $SKIP_SKILLS -eq 1 ]]; then
    info "Skipping skill deployment (--skip-skills)."
  else
    deploy_skills
  fi

  step "Verify installation"
  [[ $want_claude -eq 1 ]] && verify_cli claude
  [[ $want_codex  -eq 1 ]] && verify_cli codex
  [[ $WITH_NODE   -eq 1 ]] && verify_cli node

  print_next_steps
}

# --- Main ----------------------------------------------------------------------

main() {
  parse_args "$@"

  if running_as_sudo_wrapper; then
    warn "You ran this script under sudo as a whole. That is not recommended:"
    warn "the CLIs will be installed into root's home, not yours. Prefer running"
    warn "as your normal user — sudo is applied per command only where required."
    warn "The kit and skills will still be deployed to the real user's home: $(resolve_target_home)"
  fi

  load_config
  export UI_LANG="$LANG_CODE"   # lib/ui.sh's ui_t renders the catalog/scripts in this language
  KIT_HOME_DIR="$(kit_home)"

  # TUI when there is a terminal and either nothing forces headless, or --tui overrides.
  if have_tty && { [[ $HEADLESS -eq 0 ]] || [[ $FORCE_TUI -eq 1 ]]; }; then
    deploy_kit
    install_swkit_path
    deploy_skills
    run_tui
  else
    run_headless
  fi
}

# Run main only when executed, not when sourced (sourcing enables function-level tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
