#!/usr/bin/env bash
#
# bootstrap.sh — turn a fresh Ubuntu machine into an LLM-driven software manager.
#
# The real work of installing/configuring software lives in a COLLECTION OF SCRIPTS
# (lib/ + scripts/) — one script per piece of software, with a uniform interface
# (install/remove/configure/status/meta). Three entry points drive those scripts:
#   1. this TUI (whiptail, with a plain-text fallback),
#   2. a human running `swkit <software> <op>` directly,
#   3. the LLM, via the bundled skills.
# The LLM is special: besides RUNNING scripts it ORGANISES, RECOMMENDS, and EVOLVES
# them — authoring a new script for software not yet covered, fixing stale ones. So
# "coverage" grows over time; this bootstrap ships a seed set plus the machinery.
#
# bootstrap.sh itself: ensures a few dependencies (git/curl/ca-certificates), DEPLOYS
# the script collection to a git-tracked dir ($KIT_HOME = ~/.local/share/ubuntu-setup)
# so the LLM's edits are versioned and survive updates (vendor-branch + merge, never a
# blind clobber), deploys the skills, then opens the TUI: "Install software" browses the
# scripts (category → software → action, discovered dynamically from each script's meta)
# and a Settings page switches language and toggles passwordless sudo for the LLM.
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

# Category labels (keys match each script's meta `category` field).
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

MSG[en:cat_other]="Other"
MSG[zh:cat_other]="其他"
MSG[ja:cat_other]="その他"

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

MSG[en:no_scripts]="No scripts found. Re-run ./bootstrap.sh to (re)deploy the collection."
MSG[zh:no_scripts]="未找到脚本。重跑 ./bootstrap.sh 以(重新)部署脚本集合。"
MSG[ja:no_scripts]="スクリプトが見つかりません。./bootstrap.sh を再実行してコレクションを(再)展開してください。"

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

Sets up a fresh Ubuntu (20.04+) machine for LLM-driven software management. The actual
install/configure logic lives in a collection of scripts (scripts/*.sh) backed by a
shared library (lib/common.sh); bootstrap deploys that collection to a git-tracked dir
(~/.local/share/ubuntu-setup), deploys the skills, and provides a TUI front end.

With a terminal and no scripting flags it opens the TUI: "Install software" browses the
script collection (category -> software -> install/remove/configure, discovered from each
script's metadata) and a Settings page switches language and toggles passwordless sudo
for the LLM. Run scripts directly with `swkit <software> <op>` (deployed onto your PATH),
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

has_whiptail() { command -v whiptail >/dev/null 2>&1; }

# Interactive yes/no on the controlling terminal. $1 = question, $2 = default ("y"/"n").
# Returns 0 for yes, 1 for no. Reads/writes /dev/tty directly (works under curl | bash).
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

# --- TUI primitives ------------------------------------------------------------
# Each falls back to a plain-text equivalent on /dev/tty when whiptail is absent, so a
# minimal server with no whiptail still gets a usable menu. whiptail draws to the terminal
# device, so menu results are captured off its stderr via the 3>&1 1>&2 2>&3 fd-swap.

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

# Present the toggle (whiptail yes/no, text fallback) and flip it to match the choice.
# Reflects the current state. Non-interactive runs are left untouched. UI-only, no flag.
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

# Read one "key=value" field from a script's `meta` output (first match). Tolerant: a
# script whose `meta` exits non-zero (a broken/stale one — expected, since the LLM
# authors/evolves scripts) yields an empty field instead of aborting the caller under
# `set -e`/pipefail. kit_each_script additionally skips such scripts entirely.
kit_meta_field() {
  "$1" meta 2>/dev/null | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}' || true
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

# --- Operation runner (progress bar + log) -------------------------------------

op_label() {
  case "$1" in
    install)   t op_install ;;
    remove)    t op_remove ;;
    configure) t op_configure ;;
    *)         printf '%s' "$1" ;;
  esac
}

# Warm the sudo credential cache once, on the real terminal, before an op runs inside the
# progress-bar pipe (which can't show a password prompt). We can't cheaply know whether a
# given script will escalate, so warm for any op when sudo isn't already passwordless.
preauth_for_op() {
  command -v sudo >/dev/null 2>&1 || return 0
  sudo -n true 2>/dev/null && return 0
  if have_tty; then
    info "This step may need sudo; you may be asked for your password once now."
    # /dev/tty is sudo's own stdin (so it can read the password) — not a privileged file.
    # shellcheck disable=SC2024
    sudo -v </dev/tty || true
  fi
}

# Run a single (software, operation) by invoking its script: whiptail gauge (text
# otherwise), all output to a timestamped log, status to <log>.status, result in a box.
# A failing op records FAIL and points at the log — it never aborts the menu loop.
run_op() {
  local sw="$1" op="$2"
  local script name logdir logfile mark body
  script="$(kit_scripts_dir)/${sw}.sh"
  name="$(kit_meta_field "$script" name)"; [[ -n "$name" ]] || name="$sw"

  logdir="$(resolve_target_home)/.cache/ubuntu-setup"
  ensure_user_dir "$logdir"
  logfile="$logdir/${op}-${sw}-$(date +%Y%m%d-%H%M%S).log"
  : >"$logfile"
  : >"$logfile.status"

  preauth_for_op

  if has_whiptail; then
    {
      # Ignore SIGPIPE: if the gauge closes early, finish the op and record its status
      # rather than dying on the next write to a broken pipe.
      trap '' PIPE
      printf 'XXX\n0\n%s %s\nXXX\n' "$(op_label "$op")" "$name"
      if "$script" "$op" >>"$logfile" 2>&1; then printf 'OK\n' >>"$logfile.status"; else printf 'FAIL\n' >>"$logfile.status"; fi
      printf '100\n'
    } | whiptail --gauge "$(op_label "$op") $name" 8 70 0 || true
  else
    printf '%s %s ...\n' "$(op_label "$op")" "$name" >/dev/tty
    if "$script" "$op" >>"$logfile" 2>&1; then printf 'OK\n' >>"$logfile.status"; else printf 'FAIL\n' >>"$logfile.status"; fi
  fi

  maybe_chown_user "$logfile" "$logfile.status"

  if grep -q '^OK' "$logfile.status" 2>/dev/null; then mark="[$(t ok_label)]"; else mark="[$(t fail_label)]"; fi
  body="$(printf '%s  %s %s\n\n%s %s' "$mark" "$(op_label "$op")" "$name" "$(t log_at)" "$logfile")"
  if [[ "$op" == install && ( "$sw" == claude || "$sw" == codex ) ]]; then
    body+=$'\n\n'"$(t done_note)"
  fi
  ui_msgbox "$(t summary_title)" "$body"
}

# --- TUI flows (catalog discovered dynamically from script metadata) -----------

# Known categories, in display order. A script reporting anything else groups under "other".
KNOWN_CATEGORIES=(essentials common ai runtime)

cat_label() {
  case "$1" in
    essentials) t cat_essentials ;;
    common)     t cat_common ;;
    ai)         t cat_ai ;;
    runtime)    t cat_runtime ;;
    other)      t cat_other ;;
    *)          printf '%s' "$1" ;;
  esac
}

# Print "<category>\t<path>" for each runnable software script (skips TEMPLATE.sh). A
# script whose `meta` fails is skipped with a warning (mirroring swkit) rather than
# truncating the whole list — one broken/stale script must never hide the working ones.
kit_each_script() {
  local dir f blob cat
  dir="$(kit_scripts_dir)"
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    [[ -x "$f" ]] || continue
    [[ "$(basename "$f")" == "TEMPLATE.sh" ]] && continue
    if ! blob="$("$f" meta 2>/dev/null)"; then
      warn "Skipping $(basename "$f"): its 'meta' failed."
      continue
    fi
    cat="$(printf '%s\n' "$blob" | awk -F= '$1=="category"{sub(/^[^=]*=/,"");print;exit}')"
    [[ -n "$cat" ]] || cat="other"
    printf '%s\t%s\n' "$cat" "$f"
  done
  shopt -u nullglob
}

# Level 3: a software's action menu — every operation its meta advertises (install/
# remove/configure get translated labels; any custom action shows its raw op id).
tui_software() {
  local sw="$1" script name ops choice op
  script="$(kit_scripts_dir)/${sw}.sh"
  if [[ ! -x "$script" ]]; then ui_msgbox "$(t summary_title)" "No script: $sw"; return 0; fi
  name="$(kit_meta_field "$script" name)"; [[ -n "$name" ]] || name="$sw"
  ops="$(kit_meta_field "$script" ops)"
  while true; do
    local -a args=() oplist=()
    IFS=',' read -ra oplist <<<"$ops"
    for op in "${oplist[@]}"; do
      op="${op//[[:space:]]/}"
      [[ -n "$op" ]] || continue
      args+=("$op" "$(op_label "$op")")
    done
    args+=(back "$(t s_back)")
    choice="$(ui_menu "$name" "$(t software_prompt)" "${args[@]}")" || return 0
    case "$choice" in
      back|"") return 0 ;;
      *) run_op "$sw" "$choice" ;;
    esac
  done
}

# Level 2: software within a category (each tagged [installed] when its status passes).
tui_category() {
  local cat="$1" choice c f key name
  while true; do
    local -a args=()
    while IFS=$'\t' read -r c f; do
      [[ "$c" == "$cat" ]] || continue
      key="$(basename "$f" .sh)"
      name="$(kit_meta_field "$f" name)"; [[ -n "$name" ]] || name="$key"
      if "$f" status >/dev/null 2>&1; then name="$name $(t tag_installed)"; fi
      args+=("$key" "$name")
    done < <(kit_each_script)
    args+=(back "$(t s_back)")
    choice="$(ui_menu "$(cat_label "$cat")" "$(t category_prompt)" "${args[@]}")" || return 0
    case "$choice" in
      back|"") return 0 ;;
      *) tui_software "$choice" ;;
    esac
  done
}

# Level 1: the category menu — categories that actually have at least one script.
tui_catalog() {
  local choice c f cat
  while true; do
    # Gather which categories are present.
    local -A have=()
    while IFS=$'\t' read -r cat f; do
      have["$cat"]=1
    done < <(kit_each_script)

    if [[ ${#have[@]} -eq 0 ]]; then
      ui_msgbox "$(t m_install)" "$(t no_scripts)"
      return 0
    fi

    # Ordered: known categories first, then any others seen.
    local -a cats=()
    for c in "${KNOWN_CATEGORIES[@]}"; do [[ -n "${have[$c]:-}" ]] && cats+=("$c"); done
    for c in "${!have[@]}"; do
      case " ${KNOWN_CATEGORIES[*]} " in *" $c "*) ;; *) cats+=("$c") ;; esac
    done

    local -a args=()
    for c in "${cats[@]}"; do args+=("$c" "$(cat_label "$c")"); done
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
