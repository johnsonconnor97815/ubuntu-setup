#!/usr/bin/env bash
#
# lib/ui.sh — modern terminal-UI primitives for the ubuntu-setup script collection.
#
# This library is "TUI rendering as code", the visual twin of lib/common.sh's "safety
# contract as code". lib/common.sh sources this file at its end, so bootstrap, swkit and
# every per-software script inherit ONE rendering implementation — no duplicated menu
# code, one consistent look. Authoring a script's own management screen is then a matter
# of composing these helpers (ui_header / ui_footer / ui_row / ui_read_key) or the ready
# loops (ui_pick / ui_confirm / ui_input / ui_run), exactly like a script composes the
# safety helpers from common.sh.
#
# Three terminal tiers (one code path adapts to all):
#   - rich TTY    (openable /dev/tty + cursor-addressable TERM): full-screen alt-screen UI
#   - limited TTY (openable /dev/tty, dumb/no-addressing TERM):  plain numbered menus
#   - no TTY      (the LLM's / cron's non-interactive shell):    refuse; point at swkit/ops
#
# Terminal safety is non-negotiable (it mirrors common.sh's fail-safe ethos): ui_begin
# saves the tty state, enters the alternate screen and installs traps so ANY exit/crash
# restores the cursor, echo and primary screen. ui_end is idempotent.
#
# Meant to be SOURCED, not executed: defines functions + a few globals, sets no shell
# options (the sourcing script owns `set -e`). Idempotent load guard below.

[[ -n "${_KIT_UI_LOADED:-}" ]] && return 0
_KIT_UI_LOADED=1

# --- Global "return" channels (interactive helpers run in the caller's process and
# communicate via these, never via stdout capture — so traps and SIGWINCH stay live). ---
UI_KEY=""        # last key decoded by ui_read_key
UI_PICK=""       # id chosen by ui_pick (empty on cancel)
UI_INPUT=""      # line entered by ui_input
UI_RUN_RC=0      # exit code of the last ui_run command
UI_ROWS=24
UI_COLS=80

# Internal UI state.
_UI_FD=""            # file descriptor open on /dev/tty while a screen is active
_UI_ACTIVE=0         # 1 between ui_begin and ui_end
_UI_WINCH=0          # set by the WINCH trap, cleared by render loops
_UI_STTY_SAVED=""    # `stty -g` snapshot, restored by ui_end
_UI_STYLE_DONE=""    # guards one-time palette/charset init
_UI_ESC_DELAY="0.4"  # seconds to wait for a byte after ESC before treating it as a lone Esc

# --- One-time style init (palette + box charset), deferred so plain `meta` calls stay cheap.
# shellcheck disable=SC2034  # palette vars below are public API consumed by the scripts
_ui_init_palette() {
  local ncolors=0
  if [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1; then
    ncolors="$(tput colors 2>/dev/null || echo 0)"
  fi
  case "$ncolors" in ''|*[!0-9]*) ncolors=0 ;; esac
  if (( ncolors >= 256 )); then
    UI_OFF=$'\033[0m'; UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'
    UI_ACCENT=$'\033[38;5;39m'      # bright azure
    UI_ACCENT_BG=$'\033[48;5;24m\033[38;5;231m'  # deep teal bar, near-white text
    UI_MUTED=$'\033[38;5;245m'
    UI_OK=$'\033[38;5;78m'
    UI_WARN=$'\033[38;5;221m'
    UI_ERR=$'\033[38;5;203m'
    UI_INFO=$'\033[38;5;39m'
  elif (( ncolors >= 8 )); then
    UI_OFF=$'\033[0m'; UI_BOLD=$'\033[1m'; UI_DIM=$'\033[2m'
    UI_ACCENT=$'\033[36m'; UI_ACCENT_BG=$'\033[44m\033[1m'
    UI_MUTED=$'\033[90m'; UI_OK=$'\033[32m'; UI_WARN=$'\033[33m'
    UI_ERR=$'\033[31m'; UI_INFO=$'\033[36m'
  else
    UI_OFF="" UI_BOLD="" UI_DIM="" UI_ACCENT="" UI_ACCENT_BG="" UI_MUTED=""
    UI_OK="" UI_WARN="" UI_ERR="" UI_INFO=""
  fi
}

# shellcheck disable=SC2034  # box/glyph vars below are public API consumed by the scripts
_ui_init_charset() {
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*UTF8*|*utf-8*|*utf8*)
      UI_TL='╭' UI_TR='╮' UI_BL='╰' UI_BR='╯' UI_H='─' UI_V='│'
      UI_DOT_ON='●' UI_DOT_OFF='○' UI_DOT_MID='◐'
      UI_CHECK='✓' UI_CROSS='✗' UI_CARET='▸' UI_ARROW='→'
      UI_CHK_ON='[x]' UI_CHK_OFF='[ ]'
      ;;
    *)
      UI_TL='+' UI_TR='+' UI_BL='+' UI_BR='+' UI_H='-' UI_V='|'
      UI_DOT_ON='*' UI_DOT_OFF='o' UI_DOT_MID='~'
      UI_CHECK='+' UI_CROSS='x' UI_CARET='>' UI_ARROW='->'
      UI_CHK_ON='[x]' UI_CHK_OFF='[ ]'
      ;;
  esac
}

_ui_ensure_style() {
  [[ -n "${_UI_STYLE_DONE:-}" ]] && return 0
  _UI_STYLE_DONE=1
  _ui_init_charset
  _ui_init_palette
}

# --- i18n: generic UI chrome (software/plugin names stay untranslated, per project rule).
declare -gA UI_MSG
UI_MSG[en:install]="Install"        UI_MSG[zh:install]="安装"        UI_MSG[ja:install]="インストール"
UI_MSG[en:remove]="Uninstall"       UI_MSG[zh:remove]="卸载"        UI_MSG[ja:remove]="アンインストール"
UI_MSG[en:configure]="Configure"    UI_MSG[zh:configure]="配置"      UI_MSG[ja:configure]="設定"
UI_MSG[en:back]="Back"              UI_MSG[zh:back]="返回"          UI_MSG[ja:back]="戻る"
UI_MSG[en:apply]="Apply"            UI_MSG[zh:apply]="应用"          UI_MSG[ja:apply]="適用"
UI_MSG[en:cancel]="Cancel"          UI_MSG[zh:cancel]="取消"        UI_MSG[ja:cancel]="キャンセル"
UI_MSG[en:yes]="Yes"                UI_MSG[zh:yes]="是"             UI_MSG[ja:yes]="はい"
UI_MSG[en:no]="No"                  UI_MSG[zh:no]="否"             UI_MSG[ja:no]="いいえ"
UI_MSG[en:installed]="installed"    UI_MSG[zh:installed]="已安装"    UI_MSG[ja:installed]="インストール済み"
UI_MSG[en:not_installed]="not installed" UI_MSG[zh:not_installed]="未安装" UI_MSG[ja:not_installed]="未インストール"
UI_MSG[en:running]="Running"        UI_MSG[zh:running]="执行中"      UI_MSG[ja:running]="実行中"
UI_MSG[en:done]="Done"              UI_MSG[zh:done]="完成"          UI_MSG[ja:done]="完了"
UI_MSG[en:failed]="Failed"          UI_MSG[zh:failed]="失败"        UI_MSG[ja:failed]="失敗"
UI_MSG[en:log_at]="Log:"            UI_MSG[zh:log_at]="日志:"       UI_MSG[ja:log_at]="ログ:"
UI_MSG[en:press_enter]="Press Enter…" UI_MSG[zh:press_enter]="按回车继续…" UI_MSG[ja:press_enter]="Enter で続行…"
UI_MSG[en:press_key]="Press any key…" UI_MSG[zh:press_key]="按任意键…" UI_MSG[ja:press_key]="任意キー…"
UI_MSG[en:choose_action]="Choose an action:" UI_MSG[zh:choose_action]="选择操作:" UI_MSG[ja:choose_action]="操作を選択:"
UI_MSG[en:choose_software]="Choose software:" UI_MSG[zh:choose_software]="选择软件:" UI_MSG[ja:choose_software]="ソフトを選択:"
UI_MSG[en:install_software]="Install software" UI_MSG[zh:install_software]="安装软件" UI_MSG[ja:install_software]="ソフトを導入"
UI_MSG[en:no_scripts]="No scripts found." UI_MSG[zh:no_scripts]="未找到脚本。" UI_MSG[ja:no_scripts]="スクリプトが見つかりません。"
UI_MSG[en:no_tty]="This is the interactive UI, but no terminal was detected." \
UI_MSG[zh:no_tty]="这是交互界面,但未检测到终端。" UI_MSG[ja:no_tty]="対話 UI ですが端末が検出されません。"
UI_MSG[en:use_swkit]="Run a specific action instead, e.g.:" \
UI_MSG[zh:use_swkit]="请改用具体操作,例如:" UI_MSG[ja:use_swkit]="代わりに具体的な操作を実行してください。例:"
UI_MSG[en:cat_essentials]="ESSENTIALS"   UI_MSG[zh:cat_essentials]="装机必备"   UI_MSG[ja:cat_essentials]="必須ツール"
UI_MSG[en:cat_common]="COMMON"           UI_MSG[zh:cat_common]="常用软件"       UI_MSG[ja:cat_common]="よく使うソフト"
UI_MSG[en:cat_ai]="AI CODING CLIS"       UI_MSG[zh:cat_ai]="AI 编码 CLI"        UI_MSG[ja:cat_ai]="AI コーディング CLI"
UI_MSG[en:cat_runtime]="RUNTIME"         UI_MSG[zh:cat_runtime]="运行时"        UI_MSG[ja:cat_runtime]="ランタイム"
UI_MSG[en:cat_other]="OTHER"             UI_MSG[zh:cat_other]="其他"            UI_MSG[ja:cat_other]="その他"
UI_MSG[en:nav_list]="↑↓ move   ↵ select   q back" \
UI_MSG[zh:nav_list]="↑↓ 移动   ↵ 选择   q 返回" UI_MSG[ja:nav_list]="↑↓ 移動   ↵ 選択   q 戻る"
UI_MSG[en:nav_catalog]="↑↓ move   → manage   q quit" \
UI_MSG[zh:nav_catalog]="↑↓ 移动   → 管理   q 退出" UI_MSG[ja:nav_catalog]="↑↓ 移動   → 管理   q 終了"
UI_MSG[en:yn_hint]="←→/y/n choose   ↵ confirm   esc cancel" \
UI_MSG[zh:yn_hint]="←→/y/n 选择   ↵ 确认   esc 取消" UI_MSG[ja:yn_hint]="←→/y/n 選択   ↵ 確定   esc 取消"

# ui_t KEY — translate a chrome key for $UI_LANG (default en), falling back to English then key.
ui_t() {
  local lang="${UI_LANG:-en}" key="$1"
  case "$lang" in en|zh|ja) ;; *) lang="en" ;; esac
  printf '%s' "${UI_MSG[$lang:$key]:-${UI_MSG[en:$key]:-$key}}"
}

# --- Capability probe ----------------------------------------------------------
# kit_have_tty comes from common.sh (it actually OPENs /dev/tty). Provide a fallback so
# this file degrades gracefully if ever sourced on its own.
if ! declare -F kit_have_tty >/dev/null 2>&1; then
  kit_have_tty() { { true </dev/tty; } 2>/dev/null && { true >/dev/tty; } 2>/dev/null; }
fi

# Rich, full-screen UI possible? Need an openable tty AND a cursor-addressable terminal.
ui_supported() {
  kit_have_tty || return 1
  case "${TERM:-dumb}" in dumb|"") return 1 ;; esac
  command -v tput >/dev/null 2>&1 || return 1
  tput cup 0 0 >/dev/null 2>&1 || return 1
  return 0
}

# --- Screen lifecycle ----------------------------------------------------------
ui_size() {
  if [[ -n "${_UI_FD:-}" ]]; then
    UI_ROWS="$(tput lines <&"$_UI_FD" 2>/dev/null || echo 24)"
    UI_COLS="$(tput cols  <&"$_UI_FD" 2>/dev/null || echo 80)"
  else
    UI_ROWS="$(tput lines 2>/dev/null || echo 24)"
    UI_COLS="$(tput cols  2>/dev/null || echo 80)"
  fi
  case "$UI_ROWS" in ''|*[!0-9]*) UI_ROWS=24 ;; esac
  case "$UI_COLS" in ''|*[!0-9]*) UI_COLS=80 ;; esac
}

# Enter the alternate screen. Returns non-zero (without changing the terminal) when a rich
# UI is not possible, so callers can fall back to text helpers.
ui_begin() {
  ui_supported || return 1
  [[ "${_UI_ACTIVE:-0}" == 1 ]] && return 0
  _ui_ensure_style
  exec {_UI_FD}<>/dev/tty || { _UI_FD=""; return 1; }
  _UI_STTY_SAVED="$(stty -g <&"$_UI_FD" 2>/dev/null || true)"
  stty -echo -icanon min 1 time 0 <&"$_UI_FD" 2>/dev/null || true
  printf '\033[?1049h\033[?25l\033[2J' >&"$_UI_FD"   # alt screen, hide cursor, clear
  _UI_ACTIVE=1
  _UI_WINCH=0
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT
  trap '_ui_restore; exit 143' TERM
  trap '_UI_WINCH=1' WINCH
  ui_size
  return 0
}

_ui_restore() {
  [[ "${_UI_ACTIVE:-0}" == 1 ]] || return 0
  _UI_ACTIVE=0
  if [[ -n "${_UI_FD:-}" ]]; then
    printf '\033[0m\033[?25h\033[?1049l' >&"$_UI_FD" || true
    [[ -n "$_UI_STTY_SAVED" ]] && stty "$_UI_STTY_SAVED" <&"$_UI_FD" 2>/dev/null || true
    exec {_UI_FD}>&- 2>/dev/null || true
  fi
  _UI_FD=""
  trap - EXIT INT TERM WINCH
}

ui_end() { _ui_restore; }

# --- Low-level drawing (only valid while a screen is active) -------------------
_ui_rep() {            # _ui_rep CHAR COUNT -> echoes CHAR repeated COUNT times
  local ch="$1" n="$2" i out=""
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  for (( i=0; i<n; i++ )); do out+="$ch"; done
  printf '%s' "$out"
}

ui_move()  { printf '\033[%d;%dH' "$1" "$2" >&"$_UI_FD"; }
ui_clear() { printf '\033[2J' >&"$_UI_FD"; }

# ui_header TITLE [RIGHT] — full-width accent bar on row 1.
ui_header() {
  local title="$1" right="${2:-}" left rpad fill
  left=" $title"
  if [[ -n "$right" ]]; then rpad=" $right "; else rpad=" "; fi
  fill=$(( UI_COLS - ${#left} - ${#rpad} ))
  (( fill < 0 )) && fill=0
  ui_move 1 1
  printf '%s%s%*s%s%s' "$UI_ACCENT_BG" "$left" "$fill" "" "$rpad" "$UI_OFF" >&"$_UI_FD"
}

# ui_footer HINT — muted keybind bar on the last row.
ui_footer() {
  ui_move "$UI_ROWS" 1
  printf '\033[K%s %s%s' "$UI_MUTED" "$1" "$UI_OFF" >&"$_UI_FD"
}

# ui_box ROW COL W H [TITLE] — rounded box.
ui_box() {
  local row="$1" col="$2" w="$3" h="$4" title="${5:-}" hbar r
  hbar="$(_ui_rep "$UI_H" $(( w - 2 )))"
  ui_move "$row" "$col"; printf '%s%s%s%s%s' "$UI_MUTED" "$UI_TL" "$hbar" "$UI_TR" "$UI_OFF" >&"$_UI_FD"
  for (( r=1; r<h-1; r++ )); do
    ui_move $(( row + r )) "$col";          printf '%s%s%s' "$UI_MUTED" "$UI_V" "$UI_OFF" >&"$_UI_FD"
    ui_move $(( row + r )) $(( col+w-1 ));   printf '%s%s%s' "$UI_MUTED" "$UI_V" "$UI_OFF" >&"$_UI_FD"
  done
  ui_move $(( row + h - 1 )) "$col"; printf '%s%s%s%s%s' "$UI_MUTED" "$UI_BL" "$hbar" "$UI_BR" "$UI_OFF" >&"$_UI_FD"
  [[ -n "$title" ]] && { ui_move "$row" $(( col + 2 )); printf '%s %s %s' "$UI_ACCENT$UI_BOLD" "$title" "$UI_OFF" >&"$_UI_FD"; }
}

# ui_badge STATE -> echoes a colored glyph. STATE: installed|on|active|missing|off|mid|check|cross
ui_badge() {
  _ui_ensure_style
  case "$1" in
    installed|on|active|yes|ok) printf '%s%s%s' "$UI_OK"    "$UI_DOT_ON"  "$UI_OFF" ;;
    missing|off|no|inactive)    printf '%s%s%s' "$UI_MUTED" "$UI_DOT_OFF" "$UI_OFF" ;;
    mid|partial)                printf '%s%s%s' "$UI_WARN"  "$UI_DOT_MID" "$UI_OFF" ;;
    check)                      printf '%s%s%s' "$UI_OK"    "$UI_CHECK"   "$UI_OFF" ;;
    cross)                      printf '%s%s%s' "$UI_ERR"   "$UI_CROSS"   "$UI_OFF" ;;
    *)                          printf '%s' "$UI_DOT_OFF" ;;
  esac
}

# ui_row ROW INDEX SEL LABEL — one selectable list line (caret + accent when selected).
ui_row() {
  local row="$1" idx="$2" sel="$3" label="$4"
  ui_move "$row" 1
  printf '\033[K' >&"$_UI_FD"
  if (( idx == sel )); then
    printf ' %s%s%s %s%s%s' "$UI_ACCENT$UI_BOLD" "$UI_CARET" "$UI_OFF" "$UI_BOLD" "$label" "$UI_OFF" >&"$_UI_FD"
  else
    printf '   %s' "$label" >&"$_UI_FD"
  fi
}

# --- Input: decode one logical keypress into UI_KEY ----------------------------
ui_read_key() {
  local c b1 b2 seq
  UI_KEY=""
  IFS= read -rsn1 c <&"$_UI_FD" 2>/dev/null || { UI_KEY="enter"; return 0; }
  case "$c" in
    $'\x1b')
      if IFS= read -rsn1 -t "$_UI_ESC_DELAY" b1 <&"$_UI_FD" 2>/dev/null && [[ -n "$b1" ]]; then
        if [[ "$b1" == '[' || "$b1" == 'O' ]]; then
          seq="$b1"
          while IFS= read -rsn1 b2 <&"$_UI_FD" 2>/dev/null; do
            seq+="$b2"
            case "$b2" in [A-Za-z~]) break ;; esac
            (( ${#seq} > 8 )) && break
          done
        else
          UI_KEY="esc"; return 0
        fi
      else
        UI_KEY="esc"; return 0
      fi
      case "$seq" in
        '[A'|'OA') UI_KEY="up" ;;
        '[B'|'OB') UI_KEY="down" ;;
        '[C'|'OC') UI_KEY="right" ;;
        '[D'|'OD') UI_KEY="left" ;;
        '[H'|'OH'|'[1~'|'[7~') UI_KEY="home" ;;
        '[F'|'OF'|'[4~'|'[8~') UI_KEY="end" ;;
        '[5~') UI_KEY="pgup" ;;
        '[6~') UI_KEY="pgdn" ;;
        '[3~') UI_KEY="delete" ;;
        *)     UI_KEY="esc" ;;
      esac
      ;;
    $'\n'|$'\r'|'') UI_KEY="enter" ;;
    ' ')            UI_KEY="space" ;;
    $'\t')          UI_KEY="tab" ;;
    $'\x7f'|$'\x08') UI_KEY="backspace" ;;
    *)              UI_KEY="$c" ;;
  esac
  return 0
}

# --- ui_pick: single-select menu loop -----------------------------------------
# ui_pick TITLE SUBTITLE FOOTER -- id1 label1 [id2 label2 ...]
# Sets UI_PICK to the chosen id; returns 0 if chosen, 1 if cancelled (UI_PICK="").
# Labels may embed color/badges (e.g. "$(ui_badge installed) docker").
ui_pick() {
  local title="$1" sub="$2" footer="$3"; shift 3
  [[ "${1:-}" == "--" ]] && shift
  local -a ids=() labels=()
  while (( $# >= 2 )); do ids+=("$1"); labels+=("$2"); shift 2; done
  local n=${#ids[@]}
  UI_PICK=""
  (( n == 0 )) && return 1
  [[ -z "$footer" ]] && footer="$(ui_t nav_list)"
  _ui_ensure_style

  if ! ui_supported; then
    kit_have_tty || { UI_PICK=""; return 1; }   # truly headless: quiet cancel
    _ui_pick_text "$title" "$sub" ids labels
    return $?
  fi

  local own=0
  if [[ "${_UI_ACTIVE:-0}" != 1 ]]; then
    ui_begin || { _ui_pick_text "$title" "$sub" ids labels; return $?; }
    own=1
  fi

  local sel=0 top=0 i row listrow avail rc=1
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    listrow=4
    avail=$(( UI_ROWS - listrow - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    printf '\033[2J' >&"$_UI_FD"
    ui_header "$title"
    [[ -n "$sub" ]] && { ui_move 3 2; printf '%s%s%s' "$UI_MUTED" "$sub" "$UI_OFF" >&"$_UI_FD"; }
    row=$listrow
    for (( i=top; i<n && i<top+avail; i++ )); do
      ui_row "$row" "$i" "$sel" "${labels[$i]}"
      (( row++ ))
    done
    ui_footer "$footer"
    ui_read_key
    case "$UI_KEY" in
      up|k)    (( sel = (sel - 1 + n) % n )) ;;
      down|j)  (( sel = (sel + 1) % n )) ;;
      pgup)    (( sel -= avail )); (( sel < 0 )) && sel=0 ;;
      pgdn)    (( sel += avail )); (( sel >= n )) && sel=$(( n - 1 )) ;;
      home)    sel=0 ;;
      end)     sel=$(( n - 1 )) ;;
      enter|right|l) UI_PICK="${ids[$sel]}"; rc=0; break ;;
      q|esc|left|h)  UI_PICK=""; rc=1; break ;;
    esac
  done
  [[ $own == 1 ]] && ui_end
  return $rc
}

# Plain numbered fallback for ui_pick (limited TTY). Arrays passed by name.
_ui_pick_text() {
  local title="$1" sub="$2"; local -n _ids="$3" _labels="$4"
  local n=${#_ids[@]} i reply
  {
    printf '\n=== %s ===\n' "$title"
    [[ -n "$sub" ]] && printf '%s\n' "$sub"
    for (( i=0; i<n; i++ )); do printf '  %d) %s\n' "$(( i+1 ))" "${_labels[$i]}"; done
    printf '  0) %s\n  > ' "$(ui_t back)"
  } >/dev/tty 2>/dev/null
  IFS= read -r reply </dev/tty 2>/dev/null || { UI_PICK=""; return 1; }
  case "$reply" in
    ''|0) UI_PICK=""; return 1 ;;
    *[!0-9]*) UI_PICK=""; return 1 ;;
  esac
  (( reply >= 1 && reply <= n )) || { UI_PICK=""; return 1; }
  UI_PICK="${_ids[$(( reply-1 ))]}"
  return 0
}

# --- ui_confirm: yes/no ---------------------------------------------------------
# ui_confirm QUESTION [default y|n] -> returns 0 (yes) / 1 (no).
ui_confirm() {
  local q="$1" def="${2:-y}"
  _ui_ensure_style
  if ! ui_supported; then
    if ! kit_have_tty; then case "$def" in n|N) return 1 ;; *) return 0 ;; esac; fi
    local hint reply
    case "$def" in n|N) hint="[y/N]" ;; *) hint="[Y/n]" ;; esac
    while true; do
      printf '%s %s ' "$q" "$hint" >/dev/tty 2>/dev/null
      IFS= read -r reply </dev/tty 2>/dev/null || reply=""
      [[ -z "$reply" ]] && reply="$def"
      case "$reply" in y|Y|yes|Yes|YES) return 0 ;; n|N|no|No|NO) return 1 ;; esac
    done
  fi
  local own=0
  if [[ "${_UI_ACTIVE:-0}" != 1 ]]; then ui_begin || return 1; own=1; fi
  local choice rc
  case "$def" in n|N) choice=1 ;; *) choice=0 ;; esac   # 0=Yes 1=No
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    _ui_modal_draw "$q" "$(ui_t yes_no_title)" 2
    # buttons line: drawn by helper below
    _ui_confirm_buttons "$choice"
    ui_footer "$(ui_t yn_hint)"
    ui_read_key
    case "$UI_KEY" in
      left|right|h|l|tab) (( choice = 1 - choice )) ;;
      y|Y) choice=0; rc=0; break ;;
      n|N) choice=1; rc=1; break ;;
      enter) rc=$choice; break ;;
      esc|q) rc=1; break ;;
    esac
  done
  [[ $own == 1 ]] && ui_end
  return $rc
}

# --- ui_notify: modal info box (any key) ---------------------------------------
ui_notify() {
  local title="$1" body="$2"
  _ui_ensure_style
  if ! ui_supported || [[ "${_UI_ACTIVE:-0}" != 1 ]]; then
    kit_have_tty || return 0
    { printf '\n=== %s ===\n%s\n%s ' "$title" "$body" "$(ui_t press_enter)"; } >/dev/tty 2>/dev/null
    IFS= read -r _ </dev/tty 2>/dev/null || true
    return 0
  fi
  [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
  _ui_modal_draw "$body" "$title" 1
  ui_footer "$(ui_t press_key)"
  ui_read_key
  return 0
}

# Draw a centered box holding BODY (may contain \n); TITLE on the border. EXTRA reserves
# rows at the bottom (for a buttons line). Leaves _UI_MR/_UI_MC/_UI_MW/_UI_MH globals for
# helpers that draw inside it.
_ui_modal_draw() {
  local body="$1" title="$2" extra="${3:-0}"
  ui_size
  local -a lines=()
  local ln
  while IFS= read -r ln; do lines+=("$ln"); done <<<"$body"
  local maxw=${#title} l
  for l in "${lines[@]}"; do (( ${#l} > maxw )) && maxw=${#l}; done
  local bw=$(( maxw + 6 ))
  (( bw > UI_COLS - 2 )) && bw=$(( UI_COLS - 2 ))
  (( bw < 16 )) && bw=16
  local bh=$(( ${#lines[@]} + 3 + extra ))
  local br=$(( (UI_ROWS - bh) / 2 )); (( br < 1 )) && br=1
  local bc=$(( (UI_COLS - bw) / 2 )); (( bc < 1 )) && bc=1
  printf '\033[2J' >&"$_UI_FD"
  ui_box "$br" "$bc" "$bw" "$bh" "$title"
  local i r=$(( br + 1 ))
  for (( i=0; i<${#lines[@]}; i++ )); do
    ui_move "$r" $(( bc + 2 )); printf '%s' "${lines[$i]}" >&"$_UI_FD"
    (( r++ ))
  done
  _UI_MR=$br _UI_MC=$bc _UI_MW=$bw _UI_MH=$bh
}

_ui_confirm_buttons() {
  local choice="$1" yrow y n
  yrow=$(( _UI_MR + _UI_MH - 2 ))
  y=" $(ui_t yes) "; n=" $(ui_t no) "
  ui_move "$yrow" $(( _UI_MC + 2 ))
  if (( choice == 0 )); then
    printf '%s%s%s   %s%s%s' "$UI_ACCENT_BG" "$y" "$UI_OFF" "$UI_MUTED" "$n" "$UI_OFF" >&"$_UI_FD"
  else
    printf '%s%s%s   %s%s%s' "$UI_MUTED" "$y" "$UI_OFF" "$UI_ACCENT_BG" "$n" "$UI_OFF" >&"$_UI_FD"
  fi
}
UI_MSG[en:yes_no_title]="Confirm" UI_MSG[zh:yes_no_title]="确认" UI_MSG[ja:yes_no_title]="確認"

# --- ui_input: single-line text entry ------------------------------------------
# ui_input PROMPT [default] -> sets UI_INPUT; returns 0 if non-empty, 1 otherwise.
ui_input() {
  local prompt="$1" def="${2:-}" line
  UI_INPUT=""
  _ui_ensure_style
  if ! ui_supported || [[ "${_UI_ACTIVE:-0}" != 1 ]]; then
    if ! kit_have_tty; then UI_INPUT="$def"; [[ -n "$def" ]]; return; fi
    local hint=""; [[ -n "$def" ]] && hint=" [$def]"
    printf '%s%s: ' "$prompt" "$hint" >/dev/tty 2>/dev/null
    IFS= read -r line </dev/tty 2>/dev/null || line=""
    [[ -z "$line" ]] && line="$def"
    # shellcheck disable=SC2034  # UI_INPUT is read by callers (scripts)
    UI_INPUT="$line"; [[ -n "$line" ]]; return
  fi
  ui_size
  ui_move "$UI_ROWS" 1; printf '\033[K' >&"$_UI_FD"
  printf '%s%s%s ' "$UI_ACCENT" "$prompt" "$UI_OFF" >&"$_UI_FD"
  [[ -n "$def" ]] && printf '%s[%s]%s ' "$UI_MUTED" "$def" "$UI_OFF" >&"$_UI_FD"
  printf '\033[?25h' >&"$_UI_FD"
  stty "${_UI_STTY_SAVED:-}" <&"$_UI_FD" 2>/dev/null || stty echo icanon <&"$_UI_FD" 2>/dev/null || true
  IFS= read -r line <&"$_UI_FD" 2>/dev/null || line=""
  stty -echo -icanon min 1 time 0 <&"$_UI_FD" 2>/dev/null || true
  printf '\033[?25l' >&"$_UI_FD"
  [[ -z "$line" ]] && line="$def"
  # shellcheck disable=SC2034  # UI_INPUT is read by callers (scripts)
  UI_INPUT="$line"; [[ -n "$line" ]]
}

# --- ui_run: run a command on the real terminal, with a log + result line ------
# ui_run TITLE [--log FILE] -- cmd...   Leaves the alt screen so apt/sudo prompts work,
# streams real output, tees to a log, shows ✓/✗, waits for Enter, then re-enters the UI.
# Never aborts the caller's menu loop; returns/saves the command's exit code.
ui_run() {
  local title="$1"; shift
  local logfile=""
  if [[ "${1:-}" == "--log" ]]; then logfile="$2"; shift 2; fi
  [[ "${1:-}" == "--" ]] && shift
  _ui_ensure_style
  [[ -z "$logfile" ]] && logfile="$(_ui_logfile "$title")"
  local wasactive="${_UI_ACTIVE:-0}" rc=0
  [[ "$wasactive" == 1 ]] && ui_end
  printf '\n%s%s %s%s\n\n' "$UI_ACCENT$UI_BOLD" "$UI_ARROW" "$title" "$UI_OFF"
  if [[ -n "$logfile" ]]; then
    "$@" 2>&1 | tee "$logfile"; rc=${PIPESTATUS[0]}
  else
    "$@"; rc=$?
  fi
  printf '\n'
  if (( rc == 0 )); then
    printf '%s%s %s%s\n' "$UI_OK" "$UI_CHECK" "$(ui_t 'done')" "$UI_OFF"
  else
    printf '%s%s %s (rc=%d)%s\n' "$UI_ERR" "$UI_CROSS" "$(ui_t failed)" "$rc" "$UI_OFF"
    [[ -n "$logfile" ]] && printf '%s%s %s%s\n' "$UI_MUTED" "$(ui_t log_at)" "$logfile" "$UI_OFF"
  fi
  if kit_have_tty; then
    printf '%s%s%s ' "$UI_DIM" "$(ui_t press_enter)" "$UI_OFF"
    IFS= read -r _ </dev/tty 2>/dev/null || true
  fi
  [[ "$wasactive" == 1 ]] && ui_begin
  # shellcheck disable=SC2034  # UI_RUN_RC is read by callers (scripts)
  UI_RUN_RC=$rc
  return "$rc"
}

_ui_logfile() {
  local title="$1" slug dir ts
  slug="$(printf '%s' "$title" | tr -c 'A-Za-z0-9' '-' | tr -s '-')"
  slug="${slug#-}"; slug="${slug%-}"; [[ -n "$slug" ]] || slug="op"
  dir="${HOME:-/tmp}/.cache/ubuntu-setup"
  mkdir -p "$dir" 2>/dev/null || dir="/tmp"
  ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
  printf '%s/ui-%s-%s.log' "$dir" "$slug" "$ts"
}

# --- ui_default_menu: synthesized action menu from the calling script's meta ----
# Used by kit_dispatch when a script defines no ui(), and as the limited-TTY fallback a
# bespoke ui() can defer to. Runs in the script's process: meta/status/$0 are in scope.
ui_default_menu() {
  local self="${0}" blob name ops
  blob="$(meta 2>/dev/null || true)"
  name="$(printf '%s\n' "$blob" | _ui_meta_field name)"; [[ -n "$name" ]] || name="${self##*/}"
  ops="$(printf '%s\n' "$blob" | _ui_meta_field ops)"
  local -a oplist=()
  IFS=',' read -ra oplist <<<"$ops"
  while true; do
    local installed sub
    if status >/dev/null 2>&1; then installed="$(ui_badge installed) $(ui_t installed)"; else installed="$(ui_badge missing) $(ui_t not_installed)"; fi
    sub="$installed"
    local -a args=() op opl
    for op in "${oplist[@]}"; do
      op="${op//[[:space:]]/}"; [[ -n "$op" ]] || continue
      opl="$(_ui_op_label "$op")"
      args+=("$op" "$opl")
    done
    ui_pick "$name" "$sub" "" -- "${args[@]}" || return 0
    [[ -z "$UI_PICK" ]] && return 0
    ui_run "$(_ui_op_label "$UI_PICK") · $name" -- "$self" "$UI_PICK" || true
  done
}

_ui_op_label() {
  case "$1" in
    install)   ui_t install ;;
    remove)    ui_t remove ;;
    configure) ui_t configure ;;
    *)         printf '%s' "$1" ;;
  esac
}

_ui_meta_field() {   # read "key=value" blob on stdin; $1=key -> value of first match
  awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
}

# --- ui_catalog: browse the whole script collection ----------------------------
# ui_catalog [DIR] — list scripts by category, mark installed, drill into "<script> ui".
_KIT_UI_CAT_ORDER=(essentials common ai runtime)

_ui_cat_label() {
  case "$1" in
    essentials) ui_t cat_essentials ;;
    common)     ui_t cat_common ;;
    ai)         ui_t cat_ai ;;
    runtime)    ui_t cat_runtime ;;
    *)          ui_t cat_other ;;
  esac
}

ui_catalog() {
  local dir="${1:-${KIT_SCRIPTS_DIR:-}}"
  _ui_ensure_style
  if [[ ! -d "$dir" ]]; then ui_notify "$(ui_t install_software)" "$(ui_t no_scripts)"; return 0; fi
  if ! ui_supported; then kit_have_tty || return 0; _ui_catalog_text "$dir"; return $?; fi

  local own=0
  if [[ "${_UI_ACTIVE:-0}" != 1 ]]; then ui_begin || { _ui_catalog_text "$dir"; return $?; }; own=1; fi

  local sel=0
  while true; do
    # Gather fresh each pass (install state can change after an action).
    local -a keys=() labels=() paths=()
    _ui_catalog_collect "$dir" keys labels paths
    local n=${#keys[@]}
    if (( n == 0 )); then ui_notify "$(ui_t install_software)" "$(ui_t no_scripts)"; break; fi
    (( sel >= n )) && sel=$(( n - 1 )); (( sel < 0 )) && sel=0
    [[ -n "${keys[$sel]}" ]] || _ui_catalog_step keys sel 1   # never rest on a section header

    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    local listrow=3 avail=$(( UI_ROWS - 3 - 1 )) top=0 i row
    (( avail < 1 )) && avail=1
    # keep selection in view (skip headers when computing, but headers are interleaved)
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    printf '\033[2J' >&"$_UI_FD"
    ui_header "ubuntu-setup" "$(ui_t install_software)"
    row=$listrow
    for (( i=top; i<n && i<top+avail; i++ )); do
      if [[ -z "${keys[$i]}" ]]; then       # section header (non-selectable)
        ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${labels[$i]}" "$UI_OFF" >&"$_UI_FD"
      else
        ui_row "$row" "$i" "$sel" "${labels[$i]}"
      fi
      (( row++ ))
    done
    ui_footer "$(ui_t nav_catalog)"
    ui_read_key
    case "$UI_KEY" in
      up|k)   _ui_catalog_step keys sel -1 ;;
      down|j) _ui_catalog_step keys sel 1 ;;
      home)   sel=0; [[ -z "${keys[0]}" ]] && _ui_catalog_step keys sel 1 ;;
      end)    sel=$(( n - 1 )) ;;
      enter|right|l)
        if [[ -n "${keys[$sel]}" ]]; then
          ui_end
          "${paths[$sel]}" ui || true
          ui_begin
        fi
        ;;
      q|esc|left|h) break ;;
    esac
  done
  [[ $own == 1 ]] && ui_end
  return 0
}

# Move sel by DIR (±1) over array NAME, skipping section-header slots (empty key).
_ui_catalog_step() {
  local -n _keys="$1" _sel_ref="$2"; local dir="$3"
  local n=${#_keys[@]} i=$_sel_ref guard=0
  while (( guard++ < n )); do
    (( i = (i + dir + n) % n ))
    [[ -n "${_keys[$i]}" ]] && break
  done
  _sel_ref=$i
}

# Fill KEYS/LABELS/PATHS (by name) with interleaved section headers (empty key) + items.
_ui_catalog_collect() {
  local dir="$1"; local -n _keys="$2" _labels="$3" _paths="$4"
  _keys=(); _labels=(); _paths=()
  local f blob key name category inst
  local -a rk=() rn=() rp=() rc=() ri=()
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    [[ -x "$f" ]] || continue
    [[ "$(basename "$f")" == "TEMPLATE.sh" ]] && continue
    blob="$("$f" meta 2>/dev/null)" || continue
    key="$(printf '%s\n' "$blob" | _ui_meta_field key)"
    [[ -n "$key" ]] || continue
    name="$(printf '%s\n' "$blob" | _ui_meta_field name)"; [[ -n "$name" ]] || name="$key"
    category="$(printf '%s\n' "$blob" | _ui_meta_field category)"; [[ -n "$category" ]] || category="other"
    if "$f" status >/dev/null 2>&1; then inst=1; else inst=0; fi
    rk+=("$key"); rn+=("$name"); rp+=("$f"); rc+=("$category"); ri+=("$inst")
  done
  shopt -u nullglob
  # Ordered categories first, then any extras.
  local -a cats=("${_KIT_UI_CAT_ORDER[@]}")
  local c seen
  for c in "${rc[@]}"; do
    seen=0; local e; for e in "${cats[@]}"; do [[ "$e" == "$c" ]] && { seen=1; break; }; done
    (( seen )) || cats+=("$c")
  done
  local cat i lbl tag
  for cat in "${cats[@]}"; do
    local any=0
    for (( i=0; i<${#rk[@]}; i++ )); do [[ "${rc[$i]}" == "$cat" ]] && { any=1; break; }; done
    (( any )) || continue
    _keys+=(""); _labels+=("$(_ui_cat_label "$cat")"); _paths+=("")
    for (( i=0; i<${#rk[@]}; i++ )); do
      [[ "${rc[$i]}" == "$cat" ]] || continue
      if (( ri[i] )); then tag="$(ui_badge installed)"; else tag="$(ui_badge missing)"; fi
      printf -v lbl '%s %-12s %s' "$tag" "${rn[$i]}" "${UI_MUTED}$( (( ri[i] )) && ui_t installed )${UI_OFF}"
      _keys+=("${rk[$i]}"); _labels+=("$lbl"); _paths+=("${rp[$i]}")
    done
  done
}

# Plain numbered catalog for limited TTY.
_ui_catalog_text() {
  local dir="$1"
  local -a keys=() labels=() paths=()
  _ui_catalog_collect "$dir" keys labels paths
  local -a sk=() sl=()
  local i
  for (( i=0; i<${#keys[@]}; i++ )); do
    [[ -n "${keys[$i]}" ]] || continue
    sk+=("${paths[$i]}"); sl+=("${labels[$i]}")
  done
  (( ${#sk[@]} == 0 )) && { printf '%s\n' "$(ui_t no_scripts)" >/dev/tty 2>/dev/null; return 0; }
  while true; do
    _ui_pick_text "ubuntu-setup — $(ui_t install_software)" "" sk sl || return 0
    [[ -n "$UI_PICK" ]] || return 0
    "$UI_PICK" ui || true
  done
}
