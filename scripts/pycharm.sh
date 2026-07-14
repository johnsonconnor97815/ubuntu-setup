#!/usr/bin/env bash
#
# scripts/pycharm.sh — install / update / manage PyCharm on Ubuntu.
#
# PyCharm (https://www.jetbrains.com/pycharm/) is JetBrains' Python IDE, an IntelliJ-based
# desktop GUI app. Since 2025.3 it ships as ONE unified product — the former Community and
# Professional editions merged: the core (former Community) feature set stays free, Pro
# features unlock with a subscription/trial chosen inside the IDE. So this script manages a
# single "pycharm", no edition flag. It is NOT in any apt repo. Channel priority (highest
# that works wins; the chosen one is logged):
#   1. snap (`snap install pycharm --classic`) — published by JetBrains themselves (verified
#      publisher on snapcraft.io) and their documented install route on Ubuntu, so unlike
#      scripts/android-studio.sh (whose snap is community-maintained and therefore ranks
#      LAST) the kit's normal channel order applies: snap before manual binary. Auto-updates
#      through snapd. The legacy `pycharm-community` / `pycharm-professional` snap names now
#      also deliver the unified product; we detect them for status/remove but always install
#      the canonical `pycharm`.
#   2. The OFFICIAL JetBrains tarball — resolved from the JetBrains releases API
#      (data.services.jetbrains.com, product code PCP = the unified PyCharm), which lists per
#      release the Linux x86_64 and ARM64 tarballs with a .sha256 checksum link. We download,
#      VERIFY the sha256 (the trust boundary — same as scripts/nvim.sh / android-studio.sh)
#      and only then unpack to /opt/pycharm, symlink the launcher onto PATH, and write a
#      desktop entry.
# Because the tarball has no repo to pull upgrades from (the snap auto-updates), this script
# adds an `update` action: re-resolve the latest stable tarball and install it over the
# current one (or `snap refresh` a snap install).
#
# Architecture: official Linux builds exist for x86_64 (amd64) and aarch64 (arm64) — the
# tarball channel picks the right one; other arches fail honestly.
#
# Honesty note: PyCharm is a desktop GUI app needing a graphical session. Over SSH / on a
# headless server install still places the files and says so when it detects SSH / no
# display (JetBrains' remote story is Remote Development / Gateway — the IDE window runs on
# the machine with the display).
#
# Run it as:  pycharm.sh install|remove|update|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# JetBrains releases API for the unified PyCharm. NOTE: the response's top-level key is
# "PCP" (the unified product kept Professional's code; PCC is frozen at the last
# pre-unification release, so it must NOT be used here).
readonly PC_RELEASES_API="https://data.services.jetbrains.com/products/releases?code=PCP&latest=true&type=release"
# Where the official tarball is unpacked and wired up (mirrors scripts/android-studio.sh).
readonly PC_OPT_DIR="/opt/pycharm"
readonly PC_BIN_LINK="/usr/local/bin/pycharm"
readonly PC_DESKTOP="/usr/share/applications/pycharm.desktop"
# The canonical JetBrains snap, plus the legacy edition names it superseded (still published,
# now delivering the same unified product) — detected for status/remove, never installed.
readonly PC_SNAP_NAME="pycharm"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "PyCharm" stays
# UNtranslated; only descriptive wording is localized. Resolve a row with _pc_t KEY
# (fallback en -> the key itself, just like ui_t).
declare -gA PC_I18N
PC_I18N[en:update_row]="Update to the latest PyCharm"
PC_I18N[en:confirm_remove]="Uninstall PyCharm? (keeps your settings & projects: ~/.config/JetBrains, ~/.local/share/JetBrains)"
PC_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
PC_I18N[en:foot_manage]="↑↓ move   ↵/space select   esc/q close"
PC_I18N[en:gui_note]="PyCharm is a desktop GUI IDE — it needs a graphical session to run. On a headless/SSH server it installs fine, but launch it on a machine with a display (or use JetBrains Remote Development / Gateway)."
PC_I18N[en:license_note]="PyCharm is one unified product: pick the free mode or a Pro subscription/trial at first launch (the former Community features stay free)."
PC_I18N[zh:update_row]="更新到最新版 PyCharm"
PC_I18N[zh:confirm_remove]="卸载 PyCharm?(保留你的设置与项目:~/.config/JetBrains、~/.local/share/JetBrains)"
PC_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
PC_I18N[zh:foot_manage]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
PC_I18N[zh:gui_note]="PyCharm 是桌面 GUI IDE — 需要图形会话才能运行。SSH/无显示器的服务器上文件能正常装好,但要在有显示器的机器上启动(或用 JetBrains Remote Development / Gateway)。"
PC_I18N[zh:license_note]="PyCharm 现为单一统一产品:首次启动时选择免费模式或 Pro 订阅/试用(原 Community 功能保持免费)。"
PC_I18N[ja:update_row]="最新の PyCharm に更新"
PC_I18N[ja:confirm_remove]="PyCharm をアンインストールしますか?(設定とプロジェクトは保持:~/.config/JetBrains、~/.local/share/JetBrains)"
PC_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
PC_I18N[ja:foot_manage]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"
PC_I18N[ja:gui_note]="PyCharm はデスクトップ GUI の IDE です — 起動にはグラフィカルセッションが必要です。ヘッドレス/SSH サーバーでもインストールは完了しますが、ディスプレイのあるマシンで(または JetBrains Remote Development / Gateway 経由で)起動してください。"
PC_I18N[ja:license_note]="PyCharm は統合された単一製品です:初回起動時に無料モードか Pro サブスクリプション/トライアルを選択します(旧 Community 機能は無料のまま)。"

# _pc_t KEY — localized PyCharm string for $UI_LANG (en/zh/ja), fallback en -> key.
_pc_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${PC_I18N[$lang:$1]:-${PC_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=pycharm
name=PyCharm
category=editors
tags=gui desktop-only
desktop_hint=Gateway
ops=install,remove,update
recommends=python
desc=PyCharm Python IDE — unified free+Pro (official JetBrains snap; else sha256-verified tarball)
META
}

# Print "name version" for every installed pycharm-family snap (canonical + legacy edition
# names), one per line; exit 0 iff at least one is installed. One `snap list` spawn; column
# positions are stable across locales (never match translated header text).
_pc_snap_names() {
  have_cmd snap || return 1
  local out
  out="$(snap list 2>/dev/null | awk 'NR>1 && ($1=="pycharm" || $1=="pycharm-community" || $1=="pycharm-professional"){print $1, $2}')"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Exit 0 iff PyCharm is installed. Detect the tarball install (our /opt dir), then a snap
# (canonical or legacy name), then any other on-PATH install. Cheap probe: honor
# KIT_PROBE_ONLY by returning the boolean before computing version strings.
status() {
  local src="" snaps=""
  if [[ -x "$PC_OPT_DIR/bin/pycharm" || -f "$PC_OPT_DIR/bin/pycharm.sh" ]]; then
    src=tarball
  elif snaps="$(_pc_snap_names)"; then
    src=snap
  elif have_cmd pycharm; then
    src=other
  else
    return 1
  fi
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only
  case "$src" in
    tarball)
      local b=""
      [[ -f "$PC_OPT_DIR/build.txt" ]] && b="$(cat "$PC_OPT_DIR/build.txt" 2>/dev/null || true)"
      printf 'PyCharm (tarball: %s%s)\n' "$PC_OPT_DIR" "${b:+, build $b}"
      ;;
    snap)
      local name ver
      while read -r name ver; do
        printf 'PyCharm (snap %s %s)\n' "$name" "$ver"
      done <<<"$snaps"
      ;;
    other)
      printf 'pycharm (installed, not via this script)\n'
      ;;
  esac
}

# --- GUI / SSH honesty ---------------------------------------------------------
_pc_in_ssh()     { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
_pc_no_display() { [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }
# Emit the GUI caveat only when relevant. MUST end on a true status (this is the last command
# of several install paths): the `if` form returns 0 when not headless, so a fully successful
# local install never reports failure (the same trap scripts/cursor.sh documents).
_pc_where_note() { if _pc_in_ssh || _pc_no_display; then log_warn "$(_pc_t gui_note)"; fi; }
# Post-install pointer about the unified free/Pro licensing choice.
_pc_license_note() { log_info "$(_pc_t license_note)"; }

# True iff this host has an official Linux build (amd64/arm64) — the tarball channel only.
_pc_arch_key() {
  case "$(dpkg --print-architecture 2>/dev/null || true)" in
    amd64) printf 'linux' ;;
    arm64) printf 'linuxARM64' ;;
    *)     return 1 ;;
  esac
}

# --- snap channel (official, primary) -------------------------------------------
_pc_install_snap() {
  have_cmd snap || return 1
  log_info "Channel: snap, classic confinement (published by JetBrains — their documented Ubuntu route; auto-updates)."
  sudo_run snap install "$PC_SNAP_NAME" --classic
}

# --- Official tarball channel (fallback) -----------------------------------------

# Resolve the newest stable Linux tarball for this arch into _PC_URL / _PC_SUMURL / _PC_VER
# from the releases API. Small nested JSON — parse it with jq (installed on demand, like
# scripts/android-studio.sh). Non-zero (with guidance) if the API is unreachable, has no
# build for this arch, or omits the checksum link.
_pc_resolve_tarball() {
  local dlkey
  dlkey="$(_pc_arch_key)" || {
    log_err "PyCharm publishes Linux builds for x86_64/aarch64 only; this host is $(dpkg --print-architecture 2>/dev/null || uname -m)."
    return 1
  }
  have_cmd curl || apt_install curl ca-certificates
  have_cmd jq   || apt_install jq
  log_info "Looking up the latest stable PyCharm release…"
  local json
  json="$(curl -fsSL --max-time 60 "$PC_RELEASES_API" 2>/dev/null || true)"
  [[ -n "$json" ]] || { log_err "Could not reach the JetBrains releases API ($PC_RELEASES_API)."; return 1; }
  local tsv
  tsv="$(printf '%s' "$json" | jq -r --arg dl "$dlkey" '
      .PCP[0] as $r
      | $r.downloads[$dl] as $d
      | select($d != null)
      | [$d.link, $d.checksumLink, $r.version] | @tsv' 2>/dev/null || true)"
  [[ -n "$tsv" ]] || { log_err "Could not find a stable Linux ($dlkey) build in the JetBrains releases API."; return 1; }
  IFS=$'\t' read -r _PC_URL _PC_SUMURL _PC_VER <<<"$tsv"
  [[ -n "$_PC_URL" && -n "$_PC_SUMURL" ]] || {
    log_err "The releases API entry is missing a download URL or checksum link — refusing to install an unverified tarball."
    return 1
  }
  return 0
}

# Fetch the .sha256 companion file and extract the checksum (first 64-hex token — the file
# body is "<sha256>  <filename>" and we download to a temp name, so build our own check line).
_pc_fetch_sha() {
  local sum
  sum="$(curl -fsSL --max-time 60 "$_PC_SUMURL" 2>/dev/null | awk '{print $1; exit}' || true)"
  [[ "$sum" =~ ^[0-9a-fA-F]{64}$ ]] || { log_err "Unexpected checksum format from $_PC_SUMURL — refusing to install."; return 1; }
  printf '%s' "$sum"
}

# The on-disk launcher script after extraction (bin/pycharm.sh renamed to bin/pycharm in
# newer releases).
_pc_launcher_path() {
  if [[ -f "$PC_OPT_DIR/bin/pycharm" ]]; then printf '%s' "$PC_OPT_DIR/bin/pycharm"
  elif [[ -f "$PC_OPT_DIR/bin/pycharm.sh" ]]; then printf '%s' "$PC_OPT_DIR/bin/pycharm.sh"
  else return 1
  fi
}

# Write a system-wide desktop entry pointing at the extracted launcher + icon. Best-effort:
# the IDE is fully usable via the symlink/CLI even if this step fails, so never abort over it.
_pc_write_desktop() {
  local launcher icon tmp rc=0
  launcher="$(_pc_launcher_path)" || { log_warn "PyCharm launcher not found; skipping the desktop entry."; return 0; }
  icon="$PC_OPT_DIR/bin/pycharm.png"; [[ -f "$icon" ]] || icon="$PC_OPT_DIR/bin/pycharm.svg"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=PyCharm
GenericName=Python IDE
Comment=Python IDE for professional developers
Exec=$launcher %f
Icon=$icon
Categories=Development;IDE;
Terminal=false
StartupNotify=true
StartupWMClass=jetbrains-pycharm
EOF
  sudo_run install -m 0644 "$tmp" "$PC_DESKTOP" || rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || log_warn "Could not write the desktop entry ($PC_DESKTOP) — PyCharm still runs via 'pycharm'."
  return 0
}

# Download + verify + unpack the official tarball, then wire it up. The trust boundary is the
# sha256 check BEFORE anything touches the system.
_pc_install_tarball() {
  _pc_resolve_tarball || return 1
  local sha
  sha="$(_pc_fetch_sha)" || return 1
  log_info "Channel: official JetBrains tarball (PyCharm ${_PC_VER:-stable})."
  log_info "Downloading: $_PC_URL"
  local tmp tarball rc=0
  tmp="$(mktemp -d)"
  tarball="$tmp/pycharm-linux.tar.gz"
  # The tarball is large (~1.2 GB). Bound the connect phase and a genuine STALL (<1 KB/s for
  # 60s), NOT total elapsed time — a healthy slow-but-progressing transfer must not be killed
  # (the lesson scripts/cursor.sh documents). --retry + -C - retry transient drops and resume.
  if ! curl -fSL \
        --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$_PC_URL" -o "$tarball"; then
    rm -rf "$tmp"; log_err "Failed to download the PyCharm tarball."; return 1
  fi
  if ! printf '%s  %s\n' "$sha" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
    rm -rf "$tmp"; log_err "Checksum mismatch on the downloaded tarball — refusing to install."; return 1
  fi
  log_info "Checksum verified (sha256). Installing to $PC_OPT_DIR (needs sudo)…"
  # Replace any previous tarball install so we extract cleanly. Guard the rm (path strictly
  # under /opt) and keep a "${var:?}" belt even though PC_OPT_DIR is a fixed constant.
  if [[ -e "$PC_OPT_DIR" ]]; then
    if kit_path_safe_under "$PC_OPT_DIR" /opt; then
      sudo_run rm -rf "${PC_OPT_DIR:?}" || rc=$?
    else
      rm -rf "$tmp"; log_err "Refusing to replace $PC_OPT_DIR (failed path guard)."; return 1
    fi
  fi
  # The archive's top-level dir is versioned (pycharm-<ver>/), so strip it into our fixed dir.
  if (( rc == 0 )); then sudo_run mkdir -p "$PC_OPT_DIR" || rc=$?; fi
  if (( rc == 0 )); then sudo_run tar -C "$PC_OPT_DIR" --strip-components=1 -xzf "$tarball" || rc=$?; fi
  rm -rf "$tmp"
  (( rc == 0 )) || { log_err "Failed to extract the PyCharm tarball into $PC_OPT_DIR."; return "$rc"; }
  [[ -d "$PC_OPT_DIR/bin" ]] || { log_err "Unexpected archive layout: $PC_OPT_DIR/bin not found after extraction."; return 1; }
  local launcher; launcher="$(_pc_launcher_path)" || { log_err "No pycharm launcher found under $PC_OPT_DIR/bin."; return 1; }
  sudo_run ln -sfn "$launcher" "$PC_BIN_LINK" || { log_err "Could not create the $PC_BIN_LINK symlink."; return 1; }
  _pc_write_desktop
  return 0
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "PyCharm is already installed ($(status 2>/dev/null | head -n1)) — to get the latest, run: ${0##*/} update"
    return 0
  fi
  # 1. snap (official JetBrains publisher) — primary.
  if have_cmd snap; then
    local rc=0
    _pc_install_snap || rc=$?
    if (( rc == 0 )); then
      log_info "Installed $(status 2>/dev/null | head -n1) — it auto-updates through snapd."
      _pc_license_note
      _pc_where_note
      return 0
    fi
    # If the install only stalled because sudo needs a password on a TTY-less host, sudo_run
    # has already printed the exact command to run by hand — propagate that (RC_NEED_SUDO)
    # instead of muddying it with a tarball attempt that would hit the identical wall (after
    # a ~1.2 GB download, no less).
    if (( rc == RC_NEED_SUDO )); then return "$rc"; fi
    log_warn "snap install failed — trying the official tarball."
  else
    log_warn "snap is unavailable here — trying the official tarball."
  fi
  # 2. Official sha256-verified tarball fallback.
  if _pc_install_tarball; then
    log_info "Installed $(status 2>/dev/null | head -n1)."
    log_info "Launch it from your application menu or 'pycharm'. Update later with: ${0##*/} update"
    _pc_license_note
    _pc_where_note
    return 0
  fi
  log_err "Could not install PyCharm: snap is unavailable and the official tarball channel failed."
  log_err "See https://www.jetbrains.com/help/pycharm/installation-guide.html for manual options."
  return 1
}

# update — refresh the snap (it auto-updates anyway) or re-resolve + reinstall the latest
# tarball over the current one. Installs first if PyCharm is absent.
do_update() {
  if ! status >/dev/null 2>&1; then
    log_info "PyCharm is not installed — installing the latest instead."
    do_install
    return $?
  fi
  # Mirror status()'s detection order (tarball first, then snap) so the channel that status
  # reports is the one update acts on.
  if [[ -d "$PC_OPT_DIR" ]]; then
    local cur; cur="$(status 2>/dev/null | head -n1)"
    _pc_install_tarball || return 1
    log_info "PyCharm updated. Now: $(status 2>/dev/null | head -n1) (was: ${cur:-unknown})."
    _pc_where_note
    return 0
  fi
  local snaps=""
  if snaps="$(_pc_snap_names)"; then
    log_info "PyCharm is a snap (it auto-updates); refreshing now…"
    local name _ver
    while read -r name _ver; do
      sudo_run snap refresh "$name" || { log_err "snap refresh $name failed."; return 1; }
    done <<<"$snaps"
    log_info "Now: $(status 2>/dev/null | head -n1)."
    return 0
  fi
  log_warn "PyCharm is installed but not via this script's snap/tarball channels; update it the way you installed it."
  return 0
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "PyCharm is not installed — nothing to remove."
    return 0
  fi
  local removed=0
  # Tarball install: remove the /opt dir (guarded), its symlink and desktop entry.
  if [[ -d "$PC_OPT_DIR" ]]; then
    if kit_path_safe_under "$PC_OPT_DIR" /opt; then
      sudo_run rm -rf "${PC_OPT_DIR:?}"
      removed=1
    else
      log_err "Refusing to delete $PC_OPT_DIR (failed path guard)."
      return 1
    fi
    [[ -L "$PC_BIN_LINK" ]] && sudo_run rm -f "$PC_BIN_LINK"
    [[ -f "$PC_DESKTOP" ]] && sudo_run rm -f "$PC_DESKTOP"
    log_info "Removed the PyCharm tarball install ($PC_OPT_DIR), its symlink and desktop entry."
  fi
  # snap install(s) — canonical and/or legacy edition names.
  local snaps=""
  if snaps="$(_pc_snap_names)"; then
    local name _ver
    while read -r name _ver; do
      sudo_run snap remove "$name"
      removed=1
      log_info "Removed the $name snap."
    done <<<"$snaps"
  fi
  if (( removed == 0 )); then
    log_warn "PyCharm is on PATH but not managed by this script's snap or tarball channels;"
    log_warn "remove it the way you installed it."
    return 1
  fi
  log_info "Your settings and projects are kept (~/.config/JetBrains, ~/.local/share/JetBrains, ~/.cache/JetBrains) — delete them by hand to fully reset."
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live panel: Install when missing; when installed, a status line plus Update and Uninstall
# actions. State is read live each pass; every change shells out via ui_run (visible + logged)
# and the screen reloads. Non-selectable rows (status line, spacer) are skipped during
# navigation. Limited terminals fall back to the synthesized op menu. `ui` is an entry mode
# (kit_dispatch) — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver=""
    if status >/dev/null 2>&1; then installed=1; ver="$(status 2>/dev/null | head -n1)"; fi

    # ---- build display rows (parallel arrays: kind / label) ----
    local -a dkind=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) PyCharm")
    else
      dkind+=(status); dlabel+=("$(printf '%-10s %s' 'pycharm' "${UI_INFO}${ver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(update); dlabel+=("$(ui_badge check) $(_pc_t update_row)")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) PyCharm")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "PyCharm" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "PyCharm" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_pc_t foot_manage)"
    else ui_footer "$(_pc_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) PyCharm" -- "$0" install ;;
          update)  ui_run "$(_pc_t update_row)" -- "$0" update ;;
          remove)  ui_confirm "$(_pc_t confirm_remove)" n && ui_run "$(ui_t remove) PyCharm" -- "$0" remove ;;
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

Commands:
  install    Install PyCharm (official JetBrains snap; falls back to the sha256-verified
             official tarball). One unified product — free mode / Pro chosen in the IDE. Idempotent.
  update     'snap refresh' a snap install, or re-fetch the latest stable tarball over the current one
  remove     Uninstall PyCharm (keeps your settings & projects under ~/.config/JetBrains, ~/.local/share/JetBrains)
  status     Print the install/version if present; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
