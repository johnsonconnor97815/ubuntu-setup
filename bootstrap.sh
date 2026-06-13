#!/usr/bin/env bash
#
# bootstrap.sh — set up a fresh Ubuntu machine for LLM-driven software management.
#
# Run with no arguments in a terminal and it opens a TUI (whiptail, with a plain-text
# fallback): a main menu with "Install software" and a settings page. "Install software"
# is a curated, hand-written catalog browsed in three levels — category (Essentials,
# Common software, AI coding CLIs, Runtime, LLM assets) → software → action (install /
# uninstall / configure). The catalog is pure bash and bounded; arbitrary/long-tail
# software (and deep configuration) is still handled by the LLM via the bundled skills.
# Settings lets you switch the interface language (中文 / English / 日本語) and toggle
# passwordless sudo for the LLM. Each action runs behind a progress bar, with full output
# written to a log file, and you land back on the action menu when it finishes.
#
# Usage: ./bootstrap.sh [--only claude|codex] [--method native|npm] [--with-node]
#                       [--skip-skills] [--headless] [--tui]
#
# With a terminal and no scripting flags it runs the TUI. Pass any install flag (or run
# without a terminal, e.g. in CI) and it runs headless instead, honouring those flags.
#
# Idempotent: every step checks the live system first and skips what is already
# in place, so the script is safe to re-run (e.g. after a failure).
#
# Privilege model: run as a normal user. Only apt steps (the dependency top-up and the
# optional Node.js install) escalate, one command at a time, via sudo. Running as root
# also works but is not required; `sudo npm install -g` is never used.
#
# Passwordless sudo: after bootstrap the LLM runs `sudo apt-get …` through its own
# Bash tool, which has NO interactive terminal — so it cannot type a sudo password
# and could not install anything. So the Settings page offers a toggle (a whiptail
# dialog, falling back to a text [Y/n] prompt) to turn passwordless sudo ON or OFF for
# the invoking user. ON writes a NOPASSWD sudoers drop-in (/etc/sudoers.d/ubuntu-setup-llm)
# granting passwordless root; OFF removes it. The toggle shows the current state, so you
# can flip it either way on any run. Non-interactive runs (no terminal) leave it
# unchanged. There is no command-line flag for this — the choice is made through the UI;
# revoke any time with `sudo rm /etc/sudoers.d/ubuntu-setup-llm`.

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
ONLY=""           # "" = both, or "claude" / "codex"  (headless only)
METHOD="native"   # "native" (official installer) or "npm"  (headless only)
SKIP_SKILLS=0
WITH_NODE=0       # headless: also install Node.js + npm
HEADLESS=0        # forced headless by a scripting flag
FORCE_TUI=0       # --tui forces the menu when a terminal is present
LANG_CODE="en"    # interface language: en / zh / ja
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

# --- Interface strings (i18n) --------------------------------------------------
#
# Only the user-facing TUI is translated; internal info()/warn()/error() logs stay in
# English (they land in a log file, not in front of the user). t KEY prints the string
# for the active LANG_CODE, falling back to English, then to the raw key.

declare -A MSG

MSG[en:app_title]="ubuntu-setup"
MSG[zh:app_title]="ubuntu-setup"
MSG[ja:app_title]="ubuntu-setup"

MSG[en:main_prompt]=$'LLM-driven Ubuntu setup.\nChoose an action:'
MSG[zh:main_prompt]=$'LLM 驱动的 Ubuntu 配置。\n选择操作:'
MSG[ja:main_prompt]=$'LLM 駆動の Ubuntu セットアップ。\n操作を選択してください:'

MSG[en:m_install]="Install software"
MSG[zh:m_install]="安装软件"
MSG[ja:m_install]="ソフトウェアをインストール"

MSG[en:m_settings]="Settings"
MSG[zh:m_settings]="设置"
MSG[ja:m_settings]="設定"

MSG[en:m_quit]="Quit"
MSG[zh:m_quit]="退出"
MSG[ja:m_quit]="終了"

MSG[en:catalog_prompt]="Choose a category:"
MSG[zh:catalog_prompt]="选择类别:"
MSG[ja:catalog_prompt]="カテゴリを選択:"

MSG[en:category_prompt]="Choose software:"
MSG[zh:category_prompt]="选择软件:"
MSG[ja:category_prompt]="ソフトウェアを選択:"

MSG[en:software_prompt]="Choose an action:"
MSG[zh:software_prompt]="选择操作:"
MSG[ja:software_prompt]="操作を選択:"

# Category labels
MSG[en:cat_essentials]="Essentials"
MSG[zh:cat_essentials]="装机必备"
MSG[ja:cat_essentials]="必須ツール"

MSG[en:cat_common]="Common software"
MSG[zh:cat_common]="常用软件"
MSG[ja:cat_common]="よく使うソフト"

MSG[en:cat_ai]="AI coding CLIs"
MSG[zh:cat_ai]="AI 编码 CLI"
MSG[ja:cat_ai]="AI コーディング CLI"

MSG[en:cat_runtime]="Runtime"
MSG[zh:cat_runtime]="运行时"
MSG[ja:cat_runtime]="ランタイム"

MSG[en:cat_assets]="LLM assets"
MSG[zh:cat_assets]="LLM 资产"
MSG[ja:cat_assets]="LLM アセット"

# Operation labels
MSG[en:op_install]="Install"
MSG[zh:op_install]="安装"
MSG[ja:op_install]="インストール"

MSG[en:op_remove]="Uninstall"
MSG[zh:op_remove]="卸载"
MSG[ja:op_remove]="アンインストール"

MSG[en:op_configure]="Configure"
MSG[zh:op_configure]="配置"
MSG[ja:op_configure]="設定"

MSG[en:sw_claude]="Claude Code CLI"
MSG[zh:sw_claude]="Claude Code CLI"
MSG[ja:sw_claude]="Claude Code CLI"

MSG[en:sw_codex]="Codex CLI"
MSG[zh:sw_codex]="Codex CLI"
MSG[ja:sw_codex]="Codex CLI"

MSG[en:sw_node]="Node.js + npm (apt)"
MSG[zh:sw_node]="Node.js + npm(apt 安装)"
MSG[ja:sw_node]="Node.js + npm(apt)"

MSG[en:sw_skills]="LLM skills (ubuntu-install, zsh-setup)"
MSG[zh:sw_skills]="LLM 技能(ubuntu-install、zsh-setup)"
MSG[ja:sw_skills]="LLM スキル(ubuntu-install、zsh-setup)"

MSG[en:sw_git]="git"
MSG[zh:sw_git]="git"
MSG[ja:sw_git]="git"

MSG[en:sw_curl]="curl"
MSG[zh:sw_curl]="curl"
MSG[ja:sw_curl]="curl"

MSG[en:sw_zsh]="zsh"
MSG[zh:sw_zsh]="zsh"
MSG[ja:sw_zsh]="zsh"

MSG[en:sw_docker]="Docker (docker.io)"
MSG[zh:sw_docker]="Docker(docker.io)"
MSG[ja:sw_docker]="Docker(docker.io)"

MSG[en:tag_installed]="[installed]"
MSG[zh:tag_installed]="[已安装]"
MSG[ja:tag_installed]="[インストール済み]"

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

MSG[en:summary_title]="Result"
MSG[zh:summary_title]="操作结果"
MSG[ja:summary_title]="結果"

MSG[en:ok_label]="OK"
MSG[zh:ok_label]="成功"
MSG[ja:ok_label]="成功"

MSG[en:fail_label]="FAILED"
MSG[zh:fail_label]="失败"
MSG[ja:fail_label]="失敗"

MSG[en:log_at]="Full log:"
MSG[zh:log_at]="完整日志:"
MSG[ja:log_at]="詳細ログ:"

MSG[en:done_note]=$'Run \'claude\' or \'codex\' and sign in, then ask the LLM to manage this machine.\nOpen a new shell first so they are on PATH.'
MSG[zh:done_note]=$'运行 claude 或 codex 登录后,即可让 LLM 管理这台机器。\n请先打开新 shell,使它们出现在 PATH 中。'
MSG[ja:done_note]=$'claude または codex を実行してサインインし、LLM にこのマシンの管理を依頼できます。\nまず新しいシェルを開くと PATH に反映されます。'

MSG[en:press_enter]="Press Enter to continue..."
MSG[zh:press_enter]="按回车继续……"
MSG[ja:press_enter]="Enter キーで続行…"

MSG[en:sudo_title]="ubuntu-setup: LLM passwordless sudo"
MSG[zh:sudo_title]="ubuntu-setup:LLM 免密 sudo"
MSG[ja:sudo_title]="ubuntu-setup:LLM 用パスワードなし sudo"

MSG[en:state_enabled]="ENABLED"
MSG[zh:state_enabled]="已启用"
MSG[ja:state_enabled]="有効"

MSG[en:state_disabled]="disabled"
MSG[zh:state_disabled]="未启用"
MSG[ja:state_disabled]="無効"

# Four %s, in order: drop-in path, user, drop-in path, current state.
MSG[en:sudo_body]=$'The LLM runs sudo (e.g. apt) in its own shell, which has no\nterminal to type a password - so it can only install software\nif sudo is passwordless.\n\nEnabling writes:\n    %s\ngranting \'%s\' passwordless root. Revoke any time with:\n    sudo rm %s\n\nCurrently: %s\n\nTurn passwordless sudo ON for the LLM?'
MSG[zh:sudo_body]=$'LLM 在自己的 shell 里执行 sudo(如 apt),该环境没有终端\n无法输入密码——所以只有在 sudo 免密时它才能安装软件。\n\n开启将写入:\n    %s\n授予 \'%s\' 免密 root。随时可撤销:\n    sudo rm %s\n\n当前状态:%s\n\n为 LLM 开启免密 sudo?'
MSG[ja:sudo_body]=$'LLM は自身のシェルで sudo(apt など)を実行しますが、\nパスワードを入力する端末がありません。sudo がパスワード\nなしの場合のみソフトをインストールできます。\n\n有効にすると次を書き込みます:\n    %s\n\'%s\' にパスワードなし root を付与。取り消しは随時:\n    sudo rm %s\n\n現在: %s\n\nLLM 用にパスワードなし sudo を有効にしますか?'

MSG[en:sudo_enabled_msg]="Passwordless sudo ENABLED for '%s'. The LLM can now run apt/sudo unprompted."
MSG[zh:sudo_enabled_msg]="已为 '%s' 启用免密 sudo,LLM 现在可免密运行 apt/sudo。"
MSG[ja:sudo_enabled_msg]="'%s' のパスワードなし sudo を有効化しました。LLM は apt/sudo を無確認で実行できます。"

MSG[en:sudo_disabled_msg]="Passwordless sudo DISABLED."
MSG[zh:sudo_disabled_msg]="已禁用免密 sudo。"
MSG[ja:sudo_disabled_msg]="パスワードなし sudo を無効化しました。"

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

Sets up a fresh Ubuntu (20.04+) machine for LLM-driven software management.

With a terminal and no scripting flags, it opens a TUI: "Install software" browses a
curated catalog in three levels — category (Essentials, Common software, AI coding
CLIs, Runtime, LLM assets) -> software (git, curl, zsh, docker, Claude Code CLI,
Codex CLI, Node.js + npm, the bundled skills) -> action (install / uninstall /
configure). A Settings page switches the interface language (中文 / English / 日本語)
and toggles passwordless sudo for the LLM. Each action runs behind a progress bar;
output goes to a log under ~/.cache/ubuntu-setup/. Long-tail software and deep
configuration stay with the LLM via the bundled skills.

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

The script is idempotent: already-installed components are detected on the live
system and skipped, so it is safe to re-run at any time.
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
# even when the script is piped (curl … | bash). Actually try to OPEN /dev/tty for
# read and write — the device node can exist (passing -r/-w bit tests) yet fail to
# open with ENXIO when there is no controlling terminal (cron, nohup, no PTY), which
# would wrongly route us into the interactive TUI. No openable /dev/tty -> headless.
have_tty() {
  { true </dev/tty; } 2>/dev/null && { true >/dev/tty; } 2>/dev/null
}

has_whiptail() { command -v whiptail >/dev/null 2>&1; }

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

report_version() {
  local cli="$1" ver
  if ver="$("$cli" --version 2>/dev/null)"; then
    info "$cli already installed: $ver — skipping."
  else
    info "$cli already installed (version probe failed) — skipping."
  fi
}

# --- TUI primitives ------------------------------------------------------------
#
# Each falls back to a plain-text equivalent on /dev/tty when whiptail is absent, so
# a minimal Ubuntu server with no whiptail still gets a usable menu. whiptail's newt
# backend draws straight to the terminal device, so menu results are captured off its
# stderr via the 3>&1 1>&2 2>&3 fd-swap and printed on this function's stdout.

# ui_menu TITLE PROMPT  tag1 label1  tag2 label2 ...  -> prints chosen tag (empty on cancel)
ui_menu() {
  local title="$1" prompt="$2"; shift 2
  if has_whiptail; then
    local n=$(( $# / 2 ))
    whiptail --title "$title" --menu "$prompt" 20 74 "$n" "$@" 3>&1 1>&2 2>&3 </dev/tty
    return $?
  fi
  local -a tags=()
  local i=1 tag label
  {
    printf '\n=== %s ===\n%s\n' "$title" "$prompt"
    while (($#)); do
      tag="$1"; label="$2"; shift 2
      tags+=("$tag")
      printf '  %d) %s\n' "$i" "$label"
      i=$((i+1))
    done
    printf '  > '
  } >/dev/tty
  local reply
  read -r reply </dev/tty || return 1
  [[ "$reply" =~ ^[0-9]+$ ]] || return 1
  (( reply >= 1 && reply <= ${#tags[@]} )) || return 1
  printf '%s' "${tags[$((reply-1))]}"
}

# ui_yesno TITLE TEXT [default y|n] -> 0 yes, 1 no, >1 cancelled
ui_yesno() {
  local title="$1" text="$2" def="${3:-y}"
  if has_whiptail; then
    local -a a=(--title "$title")
    [[ "$def" == n ]] && a+=(--defaultno)
    whiptail "${a[@]}" --yesno "$text" 20 74 </dev/tty
    return $?
  fi
  prompt_yes_no "$text" "$def"
}

ui_msgbox() {
  local title="$1" text="$2"
  if has_whiptail; then
    whiptail --title "$title" --msgbox "$text" 20 74 </dev/tty || true
  else
    { printf '\n=== %s ===\n%s\n%s ' "$title" "$text" "$(t press_enter)"; } >/dev/tty
    read -r _ </dev/tty || true
  fi
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

# --- Dependency checks ---------------------------------------------------------

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

# Remove apt packages: plain apt-get as root, per-command sudo otherwise. Uses
# `remove` (not `purge`) so user configuration survives. Never re-executes as root.
apt_remove() {
  local apt_prefix=()
  if [[ $EUID -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      error "Cannot remove $* — neither root nor sudo is available."
      error "Ask an administrator to run: apt-get remove -y $*"
      return 1
    fi
    apt_prefix=(sudo)
  fi
  info "Removing packages (may prompt for your sudo password): $*"
  "${apt_prefix[@]}" DEBIAN_FRONTEND=noninteractive apt-get remove -y "$@"
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
# path that would lead to `sudo npm install -g`. (Installing Node yourself is a
# separate, explicit choice — the "node" software item / --with-node — and never
# happens implicitly to satisfy the npm method.)
ensure_npm_deps() {
  local major prefix target
  if ! major="$(node_major_version)"; then
    error "--method npm requires Node.js >= ${MIN_NODE_MAJOR}, but 'node' was not found."
    error "This script will not install Node.js to satisfy the npm method."
    error "Use the default native method instead: ./bootstrap.sh (no --method needed),"
    error "or install Node explicitly first (software list / --with-node)."
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

# --- CLI / runtime installs ----------------------------------------------------

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

# Node.js + npm from Ubuntu's apt repos — an explicit, opt-in choice (software list
# or --with-node). apt-first per the project's channel-conservative policy; whatever
# version the distro ships is fine for the user who asked for it.
install_node() {
  step "Install Node.js + npm"
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    info "node $(node --version 2>/dev/null) / npm $(npm --version 2>/dev/null) already installed — skipping."
    return 0
  fi
  apt_install nodejs npm
}

# --- PATH handling -------------------------------------------------------------

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

# --- Skill deployment ----------------------------------------------------------

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

# --- Passwordless sudo (interactive toggle, Settings page) ---------------------

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

# Present the passwordless-sudo toggle (whiptail yes/no, text fallback) and turn it
# on/off to match the choice. Reflects the current state, so it flips either way.
# Non-interactive runs are left untouched. The choice is made entirely through the UI
# — there is no command-line flag.
configure_passwordless_sudo() {
  step "Passwordless sudo for the LLM"
  if ! command -v sudo >/dev/null 2>&1; then
    if have_tty; then ui_msgbox "$(t sudo_title)" "$(t no_sudo_msg)"; else warn "sudo not available — skipping."; fi
    return 0
  fi
  if ! have_tty; then
    warn "No terminal to show the toggle — leaving passwordless sudo unchanged."
    warn "Re-run ./bootstrap.sh in a terminal to turn it on or off."
    return 0
  fi

  local user state body def rc=0 currently_on=0
  user="$(resolve_target_user)"
  passwordless_enabled && currently_on=1
  if [[ $currently_on -eq 1 ]]; then state="$(t state_enabled)"; def="y"; else state="$(t state_disabled)"; def="n"; fi

  # shellcheck disable=SC2059
  body="$(printf "$(t sudo_body)" "$SUDOERS_DROPIN" "$user" "$SUDOERS_DROPIN" "$state")"

  if ui_yesno "$(t sudo_title)" "$body" "$def"; then rc=0; else rc=$?; fi
  if [[ $rc -gt 1 ]]; then
    info "Cancelled — passwordless sudo left ${state}."
    return 0
  fi

  if [[ $rc -eq 0 && $currently_on -eq 0 ]]; then
    enable_passwordless "$user"
    # shellcheck disable=SC2059
    ui_msgbox "$(t sudo_title)" "$(printf "$(t sudo_enabled_msg)" "$user")"
  elif [[ $rc -eq 1 && $currently_on -eq 1 ]]; then
    disable_passwordless
    ui_msgbox "$(t sudo_title)" "$(t sudo_disabled_msg)"
  fi
}

# --- Software catalog ----------------------------------------------------------
#
# A curated, hand-written catalog browsed as category -> software -> action. Pure
# bash and bounded (NOT a data-driven engine): each software <key> is described by a
# few functions following a naming convention, and the menus dispatch to them by name:
#
#   sw_<key>_status      return 0 iff installed/deployed (the idempotency probe)
#   sw_<key>_install     install it
#   sw_<key>_remove      uninstall it
#   sw_<key>_configure   OPTIONAL — its presence makes "Configure" appear in the menu
#
# To add software: write these functions and add the key to a CAT_ITEMS category.
# Arbitrary/long-tail software (and deep configuration) stays with the LLM skills.

# Categories in display order; each maps to a space-separated list of software keys.
CATALOG=(essentials common ai runtime assets)
declare -A CAT_ITEMS=(
  [essentials]="git curl zsh"
  [common]="docker"
  [ai]="claude codex"
  [runtime]="node"
  [assets]="skills"
)

# git --------------------------------------------------------------------------
sw_git_status()  { command -v git >/dev/null 2>&1; }
sw_git_install() {
  step "Install git"
  if sw_git_status; then info "git already installed: $(git --version 2>/dev/null) — skipping."; return 0; fi
  apt_install git
}
sw_git_remove() {
  step "Remove git"
  if ! sw_git_status; then info "git is not installed — nothing to remove."; return 0; fi
  apt_remove git
}

# curl -------------------------------------------------------------------------
sw_curl_status()  { command -v curl >/dev/null 2>&1; }
sw_curl_install() {
  step "Install curl"
  if sw_curl_status; then info "curl already installed — skipping."; return 0; fi
  apt_install curl
}
sw_curl_remove() {
  step "Remove curl"
  if ! sw_curl_status; then info "curl is not installed — nothing to remove."; return 0; fi
  apt_remove curl
}

# zsh --------------------------------------------------------------------------
sw_zsh_status()  { command -v zsh >/dev/null 2>&1; }
sw_zsh_install() {
  step "Install zsh"
  if sw_zsh_status; then info "zsh already installed: $(zsh --version 2>/dev/null) — skipping."; return 0; fi
  apt_install zsh
}
sw_zsh_remove() {
  step "Remove zsh"
  if ! sw_zsh_status; then info "zsh is not installed — nothing to remove."; return 0; fi
  apt_remove zsh
}
# Minimal, safe configuration only: make zsh the user's default login shell, via
# per-command sudo (so it never depends on the user's password). Deep customization
# (Starship/plugins/.zshrc) is the zsh-setup skill's job, NOT the TUI's.
sw_zsh_configure() {
  step "Configure zsh (default login shell)"
  if ! sw_zsh_status; then info "zsh is not installed — install it first."; return 0; fi
  local user shell_path current
  user="$(resolve_target_user)"
  shell_path="$(command -v zsh)"
  current="$(getent passwd "$user" | cut -d: -f7)"
  if [[ "$current" == "$shell_path" ]]; then
    info "zsh is already $user's login shell — skipping."
  else
    if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then
      sudo chsh -s "$shell_path" "$user"
    else
      chsh -s "$shell_path" "$user"
    fi
    info "Set $user's login shell to $shell_path — log out and back in for it to take effect."
  fi
  info "For a richer zsh setup (Starship/plugins/.zshrc), ask the LLM to use the zsh-setup skill."
}

# docker -----------------------------------------------------------------------
# Channel-conservative: Ubuntu's docker.io, not Docker's docker-ce repo. The repo
# route (and anything fancier) stays with the LLM skill.
sw_docker_status()  { command -v docker >/dev/null 2>&1; }
sw_docker_install() {
  step "Install Docker"
  if sw_docker_status; then info "docker already installed: $(docker --version 2>/dev/null) — skipping."; return 0; fi
  apt_install docker.io
}
sw_docker_remove() {
  step "Remove Docker"
  if ! sw_docker_status; then info "docker is not installed — nothing to remove."; return 0; fi
  apt_remove docker.io
}
# Add the user to the docker group and enable the service (both idempotent).
sw_docker_configure() {
  step "Configure Docker (group + service)"
  if ! sw_docker_status; then info "docker is not installed — install it first."; return 0; fi
  local user
  local -a sudo_pfx=()
  user="$(resolve_target_user)"
  if [[ $EUID -ne 0 ]] && command -v sudo >/dev/null 2>&1; then sudo_pfx=(sudo); fi
  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    info "$user is already in the docker group — skipping group add."
  else
    "${sudo_pfx[@]}" usermod -aG docker "$user"
    info "Added $user to the docker group — log out and back in for it to take effect."
  fi
  if command -v systemctl >/dev/null 2>&1; then
    "${sudo_pfx[@]}" systemctl enable --now docker || warn "Could not enable/start the docker service."
    info "Enabled and started the docker service."
  else
    info "systemctl not found — start the docker daemon yourself if needed."
  fi
}

# Claude / Codex CLI — reuse the existing installers; uninstall is best-effort -----
sw_claude_status()  { command -v claude >/dev/null 2>&1; }
sw_claude_install() {
  if sw_claude_status; then step "Install Claude Code CLI"; report_version claude; return 0; fi
  ensure_curl_deps
  install_claude
}
sw_claude_remove() { step "Remove Claude Code CLI"; remove_cli claude "$CLAUDE_NPM_PKG"; }

sw_codex_status()  { command -v codex >/dev/null 2>&1; }
sw_codex_install() {
  if sw_codex_status; then step "Install Codex CLI"; report_version codex; return 0; fi
  ensure_curl_deps
  install_codex
}
sw_codex_remove() { step "Remove Codex CLI"; remove_cli codex "$CODEX_NPM_PKG"; }

# Best-effort uninstall of a user-space CLI installed via npm -g or the native
# installer (~/.local/bin). Never uses sudo; warns about possible leftover data.
remove_cli() {
  local cli="$1" npm_pkg="$2" bin
  if ! command -v "$cli" >/dev/null 2>&1; then
    info "$cli is not installed — nothing to remove."
    return 0
  fi
  if command -v npm >/dev/null 2>&1 && npm ls -g --depth 0 "$npm_pkg" >/dev/null 2>&1; then
    info "Removing $cli via npm: $npm_pkg"
    npm uninstall -g "$npm_pkg" || warn "npm uninstall -g $npm_pkg failed."
  fi
  bin="$HOME/.local/bin/$cli"
  if [[ -e "$bin" || -L "$bin" ]]; then
    info "Removing $bin"
    rm -f "$bin"
  fi
  if command -v "$cli" >/dev/null 2>&1; then
    warn "$cli is still on PATH ($(command -v "$cli")) — remove it manually if needed."
  else
    info "$cli removed. Some data under ~/.config or ~/.local/share may remain; delete it manually for a full cleanup."
  fi
}

# Node.js + npm — reuse install_node; remove via apt -----------------------------
sw_node_status()  { command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; }
sw_node_install() { install_node; }
sw_node_remove() {
  step "Remove Node.js + npm"
  if ! sw_node_status; then info "Node.js/npm not installed — nothing to remove."; return 0; fi
  apt_remove nodejs npm
}

# LLM skills — reuse deploy_skills; remove deletes the deployed copies -----------
sw_skills_status() {
  local target_home name
  target_home="$(resolve_target_home)"
  for name in "${SKILLS[@]}"; do
    [[ -f "$target_home/.claude/skills/$name/SKILL.md" ]] || return 1
  done
  return 0
}
sw_skills_install() { ( deploy_skills ); }   # subshell: deploy_skills' exit can't kill run_op
sw_skills_remove() {
  step "Remove deployed skills"
  local target_home name removed=0
  target_home="$(resolve_target_home)"
  for name in "${SKILLS[@]}"; do
    if [[ -d "$target_home/.claude/skills/$name" ]]; then rm -rf "$target_home/.claude/skills/$name"; removed=1; info "Removed $target_home/.claude/skills/$name"; fi
    if [[ -f "$target_home/.codex/prompts/$name.md" ]]; then rm -f "$target_home/.codex/prompts/$name.md"; removed=1; info "Removed $target_home/.codex/prompts/$name.md"; fi
  done
  [[ $removed -eq 0 ]] && info "No deployed skills found — nothing to remove."
  return 0
}

# Does software <key> support operation <op> (install|remove|configure)?
sw_supports_op() { declare -F "sw_${1}_${2}" >/dev/null 2>&1; }

# --- Operation runner (progress bar + log) -------------------------------------

op_label() {
  case "$1" in
    install)   t op_install ;;
    remove)    t op_remove ;;
    configure) t op_configure ;;
    *)         printf '%s' "$1" ;;
  esac
}

# Whether this (software, op) will touch apt / usermod / chsh and so needs sudo warmed
# before it runs inside the progress-bar pipe (which can't prompt for a password).
op_needs_sudo() {
  local sw="$1" op="$2"
  case "$op" in
    configure) case "$sw" in zsh|docker) return 0 ;; esac ;;
    install|remove)
      case "$sw" in
        git|curl|zsh|docker|node) return 0 ;;
        claude|codex)
          # A native install may need a curl/ca-certificates apt top-up.
          [[ "$op" == install ]] && ! { command -v curl >/dev/null 2>&1 && pkg_installed ca-certificates; } && return 0
          ;;
      esac
      ;;
  esac
  return 1
}

# Warm the sudo credential cache once, on the real terminal, if this op needs it.
preauth_for_op() {
  op_needs_sudo "$1" "$2" || return 0
  command -v sudo >/dev/null 2>&1 || return 0
  sudo -n true 2>/dev/null && return 0
  if have_tty; then
    info "This step needs sudo; you may be asked for your password once now."
    sudo -v </dev/tty || true
  fi
}

# Run a single (software, operation): whiptail gauge (text otherwise), all output to a
# timestamped log, status to <log>.status (the gauge runs in a subshell, so status
# travels through a file), result shown in a box. A failing op records FAIL and points
# at the log — it never aborts the menu loop (re-run to retry; ops are idempotent).
run_op() {
  local sw="$1" op="$2" fn="sw_${1}_${2}"
  local logdir logfile mark body
  logdir="$(resolve_target_home)/.cache/ubuntu-setup"
  ensure_user_dir "$logdir"
  logfile="$logdir/${op}-${sw}-$(date +%Y%m%d-%H%M%S).log"
  : >"$logfile"
  : >"$logfile.status"

  preauth_for_op "$sw" "$op"

  if has_whiptail; then
    {
      # Ignore SIGPIPE: if the gauge closes early, finish the op and record its status
      # rather than dying on the next write to a broken pipe.
      trap '' PIPE
      printf 'XXX\n0\n%s %s\nXXX\n' "$(op_label "$op")" "$(sw_label "$sw")"
      if "$fn" >>"$logfile" 2>&1; then printf 'OK\n' >>"$logfile.status"; else printf 'FAIL\n' >>"$logfile.status"; fi
      printf '100\n'
    } | whiptail --gauge "$(op_label "$op") $(sw_label "$sw")" 8 70 0 || true
  else
    printf '%s %s ...\n' "$(op_label "$op")" "$(sw_label "$sw")" >/dev/tty
    if "$fn" >>"$logfile" 2>&1; then printf 'OK\n' >>"$logfile.status"; else printf 'FAIL\n' >>"$logfile.status"; fi
  fi

  # An install of a CLI drops binaries in ~/.local/bin — keep it on PATH.
  if [[ "$op" == install && ( "$sw" == claude || "$sw" == codex ) ]]; then
    ensure_local_bin_on_path >>"$logfile" 2>&1 || true
  fi
  maybe_chown_user "$logfile" "$logfile.status"

  if grep -q '^OK' "$logfile.status" 2>/dev/null; then mark="[$(t ok_label)]"; else mark="[$(t fail_label)]"; fi
  body="$(printf '%s  %s %s\n\n%s %s' "$mark" "$(op_label "$op")" "$(sw_label "$sw")" "$(t log_at)" "$logfile")"
  if [[ "$op" == install && ( "$sw" == claude || "$sw" == codex ) ]]; then
    body+=$'\n\n'"$(t done_note)"
  fi
  ui_msgbox "$(t summary_title)" "$body"
}

# --- TUI flows -----------------------------------------------------------------

cat_label() {
  case "$1" in
    essentials) t cat_essentials ;;
    common)     t cat_common ;;
    ai)         t cat_ai ;;
    runtime)    t cat_runtime ;;
    assets)     t cat_assets ;;
    *)          printf '%s' "$1" ;;
  esac
}

sw_label() {
  case "$1" in
    claude) t sw_claude ;;
    codex)  t sw_codex ;;
    node)   t sw_node ;;
    skills) t sw_skills ;;
    git)    t sw_git ;;
    curl)   t sw_curl ;;
    zsh)    t sw_zsh ;;
    docker) t sw_docker ;;
    *)      printf '%s' "$1" ;;
  esac
}

# Software label with an [installed] tag when its status probe passes (live, uncached).
sw_installed_tag() {
  if "sw_${1}_status" >/dev/null 2>&1; then
    printf '%s %s' "$(sw_label "$1")" "$(t tag_installed)"
  else
    sw_label "$1"
  fi
}

# Level 3: a software's action menu — only the operations it actually supports.
tui_software() {
  local sw="$1" choice
  local -a args
  while true; do
    args=()
    sw_supports_op "$sw" install   && args+=(install   "$(t op_install)")
    sw_supports_op "$sw" remove    && args+=(remove    "$(t op_remove)")
    sw_supports_op "$sw" configure && args+=(configure "$(t op_configure)")
    args+=(back "$(t s_back)")
    choice="$(ui_menu "$(sw_label "$sw")" "$(t software_prompt)" "${args[@]}")" || return 0
    case "$choice" in
      install|remove|configure) run_op "$sw" "$choice" ;;
      back|"") return 0 ;;
    esac
  done
}

# Level 2: software within a category (each tagged [installed] when present).
tui_category() {
  local cat="$1" choice sw
  local -a items args
  read -ra items <<<"${CAT_ITEMS[$cat]}"
  while true; do
    args=()
    for sw in "${items[@]}"; do
      args+=("$sw" "$(sw_installed_tag "$sw")")
    done
    args+=(back "$(t s_back)")
    choice="$(ui_menu "$(cat_label "$cat")" "$(t category_prompt)" "${args[@]}")" || return 0
    case "$choice" in
      back|"") return 0 ;;
      *) tui_software "$choice" ;;
    esac
  done
}

# Level 1: the category menu (entry point from the main menu).
tui_catalog() {
  local choice c
  local -a args
  while true; do
    args=()
    for c in "${CATALOG[@]}"; do
      args+=("$c" "$(cat_label "$c")")
    done
    args+=(back "$(t s_back)")
    choice="$(ui_menu "$(t m_install)" "$(t catalog_prompt)" "${args[@]}")" || return 0
    case "$choice" in
      back|"") return 0 ;;
      *) tui_category "$choice" ;;
    esac
  done
}

tui_language() {
  local choice
  choice="$(ui_menu "$(t s_language)" "$(t lang_prompt)" \
    zh "中文" \
    en "English" \
    ja "日本語")" || return 0
  case "$choice" in
    zh|en|ja) LANG_CODE="$choice"; save_lang ;;
  esac
}

tui_settings() {
  local choice
  while true; do
    choice="$(ui_menu "$(t m_settings)" "$(t set_prompt)" \
      language "$(t s_language)" \
      sudo     "$(t s_sudo)" \
      back     "$(t s_back)")" || return 0
    case "$choice" in
      language) tui_language ;;
      sudo)     configure_passwordless_sudo ;;
      back|"")  return 0 ;;
    esac
  done
}

run_tui() {
  local choice
  while true; do
    choice="$(ui_menu "$(t app_title)" "$(t main_prompt)" \
      install  "$(t m_install)" \
      settings "$(t m_settings)" \
      quit     "$(t m_quit)")" || break
    case "$choice" in
      install)  tui_catalog ;;
      settings) tui_settings ;;
      quit|"")  break ;;
    esac
  done
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
  3. Manage the machine through the LLM, from any directory, e.g.:
       claude:  "Use the ubuntu-install skill to install docker"
       codex:   type '/ubuntu-install' and then ask it to install docker
       claude:  "Use the zsh-setup skill to install and configure zsh"
       codex:   type '/zsh-setup' and ask it to set zsh up safely

Re-running ./bootstrap.sh at any time is safe — installed components are skipped.
EOF
}

# --- Headless flow -------------------------------------------------------------

run_headless() {
  # Passwordless-sudo toggle up front: you have a terminal now, so if you turn it on,
  # that single password entry also warms the credential cache for the apt steps below.
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
  if [[ $WITH_NODE -eq 1 ]]; then
    install_node
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
  if [[ $WITH_NODE -eq 1 ]]; then
    verify_cli node
  fi

  print_next_steps
}

# --- Main ----------------------------------------------------------------------

main() {
  parse_args "$@"

  if running_as_sudo_wrapper; then
    warn "You ran this script under sudo as a whole. That is not recommended:"
    warn "the CLIs will be installed into root's home, not yours. Prefer running"
    warn "as your normal user — sudo is applied per command only where required."
    warn "Skills will still be deployed to the real user's home: $(resolve_target_home)"
  fi

  load_config

  # TUI when there is a terminal and either nothing forces headless, or --tui overrides.
  if have_tty && { [[ $HEADLESS -eq 0 ]] || [[ $FORCE_TUI -eq 1 ]]; }; then
    run_tui
  else
    run_headless
  fi
}

# Run main only when executed, not when sourced (sourcing enables function-level tests).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
