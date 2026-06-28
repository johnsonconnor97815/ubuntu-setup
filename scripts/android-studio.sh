#!/usr/bin/env bash
#
# scripts/android-studio.sh — install / update / manage Android Studio on Ubuntu.
#
# Android Studio (https://developer.android.com/studio) is Google's official IDE for Android,
# an IntelliJ-based desktop GUI app. It is NOT in any apt repo. Channel priority (highest that
# works wins; the chosen one is logged):
#   1. The OFFICIAL Google tarball — resolved from the JetBrains/Google releases feed
#      (jb.gg/android-studio-releases-list.json), which lists, per release, the channel
#      (Release/Patch = stable), the version, and a download list with a per-file SHA-256
#      checksum. We pick the newest stable Linux .tar.gz, download it, VERIFY the sha256 (the
#      trust boundary — same as scripts/nvim.sh) and only then unpack to /opt/android-studio,
#      symlink the launcher onto PATH, and write a desktop entry. This is the most trustworthy
#      route: upstream Google bytes, checksum-pinned.
#   2. snap (`snap install android-studio --classic`) — the lower-priority fallback. Note: this
#      snap is maintained by the Snapcrafters COMMUNITY, "not necessarily endorsed or officially
#      maintained by the upstream developers" — hence it ranks below the checksummed official
#      tarball, not above it.
# Because the tarball has no apt repo to pull upgrades from (snap auto-updates), this script adds
# an `update` action: re-resolve the latest stable .tar.gz and install it over the current one.
#
# Architecture: Android Studio publishes Linux builds for x86_64 (amd64) ONLY — there is no
# arm64 Linux build (neither tarball nor snap), so install fails honestly on other arches.
#
# Relationship to the other Android scripts (no hard dependency on either):
#   - It BUNDLES its own JDK (JetBrains Runtime), so it does NOT need scripts/java.sh.
#   - It MANAGES its own SDK through the first-run setup wizard, which downloads to ~/Android/Sdk
#     by default — the SAME path scripts/android.sh uses for $ANDROID_HOME, so the GUI IDE and
#     the headless SDK toolchain converge naturally. For a headless SDK/CLI toolchain WITHOUT
#     the IDE, use `swkit android`; for a system OpenJDK, use `swkit java`.
#
# Honesty note: Android Studio is a desktop GUI app needing a graphical session. Over SSH / on a
# headless server install still places the files and says so when it detects SSH / no display.
#
# Run it as:  android-studio.sh install|remove|update|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# The JetBrains-maintained Android Studio releases feed (download links + SHA-256 per file).
readonly AS_RELEASES_JSON="https://jb.gg/android-studio-releases-list.json"
# Where the official tarball is unpacked (shared location per the install docs) and wired up.
readonly AS_OPT_DIR="/opt/android-studio"
readonly AS_BIN_LINK="/usr/local/bin/android-studio"
readonly AS_DESKTOP="/usr/share/applications/android-studio.desktop"
readonly AS_SNAP_NAME="android-studio"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The product name "Android Studio" stays
# UNtranslated; only descriptive wording is localized. Resolve a row with _as_t KEY (fallback
# en -> the key itself, just like ui_t).
declare -gA AS_I18N
AS_I18N[en:update_row]="Update to the latest Android Studio"
AS_I18N[en:confirm_remove]="Uninstall Android Studio? (keeps your settings & SDK: ~/.config/Google, ~/.android, ~/Android/Sdk)"
AS_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
AS_I18N[en:foot_manage]="↑↓ move   ↵/space select   esc/q close"
AS_I18N[en:gui_note]="Android Studio is a desktop GUI IDE — it needs a graphical session to run. On a headless/SSH server it installs fine, but launch it on a machine with a display (or via X/RDP forwarding)."
AS_I18N[zh:update_row]="更新到最新版 Android Studio"
AS_I18N[zh:confirm_remove]="卸载 Android Studio?(保留你的设置与 SDK:~/.config/Google、~/.android、~/Android/Sdk)"
AS_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
AS_I18N[zh:foot_manage]="↑↓ 移动   ↵/space 选择   esc/q 关闭"
AS_I18N[zh:gui_note]="Android Studio 是桌面 GUI 应用 — 需要图形会话才能运行。SSH/无显示器的服务器上文件能正常装好,但要在有显示器的机器上启动(或经 X/RDP 转发)。"
AS_I18N[ja:update_row]="最新の Android Studio に更新"
AS_I18N[ja:confirm_remove]="Android Studio をアンインストールしますか?(設定と SDK は保持:~/.config/Google、~/.android、~/Android/Sdk)"
AS_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
AS_I18N[ja:foot_manage]="↑↓ 移動   ↵/space 選択   esc/q 閉じる"
AS_I18N[ja:gui_note]="Android Studio はデスクトップ GUI の IDE です — 起動にはグラフィカルセッションが必要です。ヘッドレス/SSH サーバーでもインストールは完了しますが、ディスプレイのあるマシンで(または X/RDP 転送経由で)起動してください。"

# _as_t KEY — localized Android Studio string for $UI_LANG (en/zh/ja), fallback en -> key.
_as_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${AS_I18N[$lang:$1]:-${AS_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=android-studio
name=Android Studio
category=editors
tags=gui desktop-only
ops=install,remove,update
desc=Android Studio — Google's official Android IDE (official tarball, sha256-verified; else snap)
META
}

# Exit 0 iff Android Studio is installed. Detect the tarball install (our /opt dir), then a snap,
# then any other on-PATH install. Cheap probe: honor KIT_PROBE_ONLY by returning the boolean
# before computing a version string.
status() {
  local src=""
  if [[ -f "$AS_OPT_DIR/bin/studio" || -f "$AS_OPT_DIR/bin/studio.sh" ]]; then
    src=tarball
  elif have_cmd snap && snap list "$AS_SNAP_NAME" >/dev/null 2>&1; then
    src=snap
  elif have_cmd android-studio; then
    src=other
  else
    return 1
  fi
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only
  case "$src" in
    tarball)
      local b=""
      [[ -f "$AS_OPT_DIR/build.txt" ]] && b="$(cat "$AS_OPT_DIR/build.txt" 2>/dev/null || true)"
      printf 'Android Studio (tarball: %s%s)\n' "$AS_OPT_DIR" "${b:+, build $b}"
      ;;
    snap)
      local v=""; v="$(snap list "$AS_SNAP_NAME" 2>/dev/null | awk 'NR==2{print $2}' || true)"
      printf 'Android Studio (snap %s)\n' "${v:-installed}"
      ;;
    other)
      printf 'android-studio (installed, not via this script)\n'
      ;;
  esac
}

# --- GUI / SSH honesty ---------------------------------------------------------
_as_in_ssh()    { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }
_as_no_display() { [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; }
# Emit the GUI caveat only when relevant. MUST end on a true status (this is the last command of
# several install paths): the `if` form returns 0 when not headless, so a fully successful local
# install never reports failure (the same trap scripts/cursor.sh documents).
_as_where_note() { if _as_in_ssh || _as_no_display; then log_warn "$(_as_t gui_note)"; fi; }

# Common post-install hint about the SDK + sibling scripts (the IDE bundles its own JDK).
_as_sdk_note() {
  log_info "First launch downloads the Android SDK (default ~/Android/Sdk) via the setup wizard; the IDE bundles its own JDK."
  log_info "Headless SDK/CLI tooling without the IDE: 'swkit android'   ·   system OpenJDK: 'swkit java'."
}

# True iff this host has an official Linux build (amd64 only).
_as_supported_arch() { [[ "$(dpkg --print-architecture 2>/dev/null || true)" == amd64 ]]; }

# --- Official tarball channel --------------------------------------------------

# Resolve the newest STABLE Linux tarball into _AS_URL / _AS_SHA / _AS_VER / _AS_NAME from the
# releases feed. Stable = channel "Release" or "Patch"; the feed is newest-first, so the first
# such item is the latest stable. The feed is a 1 MB nested JSON, so parse it with jq (installed
# on demand, like scripts/claude.sh) rather than fragile grep/awk. Non-zero (with guidance) if
# the feed is unreachable, has no stable Linux build, or omits the checksum.
_as_resolve_tarball() {
  have_cmd curl || apt_install curl ca-certificates
  have_cmd jq   || apt_install jq
  log_info "Looking up the latest stable Android Studio release…"
  local json
  json="$(curl -fsSL --max-time 60 "$AS_RELEASES_JSON" 2>/dev/null || true)"
  [[ -n "$json" ]] || { log_err "Could not reach the Android Studio releases feed ($AS_RELEASES_JSON)."; return 1; }
  # Pick the newest STABLE item that actually carries a Linux tarball (the `and any(...)` guard
  # means we never settle on a stable release whose download list happens to lack a -linux.tar.gz).
  local tsv
  tsv="$(printf '%s' "$json" | jq -r '
      [.content.item[]
        | select((.channel=="Release" or .channel=="Patch")
                 and any(.download[]?; .link | endswith("-linux.tar.gz")))][0] as $r
      | ($r.download[] | select(.link | endswith("-linux.tar.gz"))) as $d
      | [$d.link, $d.checksum, $r.version, $r.name] | @tsv' 2>/dev/null || true)"
  [[ -n "$tsv" ]] || { log_err "Could not find a stable Linux build in the Android Studio releases feed."; return 1; }
  IFS=$'\t' read -r _AS_URL _AS_SHA _AS_VER _AS_NAME <<<"$tsv"
  [[ -n "$_AS_URL" && -n "$_AS_SHA" ]] || {
    log_err "The releases feed entry is missing a download URL or checksum — refusing to install an unverified tarball."
    return 1
  }
  [[ "$_AS_SHA" =~ ^[0-9a-fA-F]{64}$ ]] || { log_err "Unexpected checksum format from the releases feed: $_AS_SHA"; return 1; }
  return 0
}

# The on-disk launcher script after extraction (renamed studio.sh -> studio in newer releases).
_as_launcher_path() {
  if [[ -f "$AS_OPT_DIR/bin/studio" ]]; then printf '%s' "$AS_OPT_DIR/bin/studio"
  elif [[ -f "$AS_OPT_DIR/bin/studio.sh" ]]; then printf '%s' "$AS_OPT_DIR/bin/studio.sh"
  else return 1
  fi
}

# Write a system-wide desktop entry pointing at the extracted launcher + icon. Best-effort: the
# IDE is fully usable via the symlink/CLI even if this step fails, so never abort install over it.
_as_write_desktop() {
  local launcher icon tmp rc=0
  launcher="$(_as_launcher_path)" || { log_warn "Studio launcher not found; skipping the desktop entry."; return 0; }
  icon="$AS_OPT_DIR/bin/studio.png"; [[ -f "$icon" ]] || icon="$AS_OPT_DIR/bin/studio.svg"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Android Studio
GenericName=Android IDE
Comment=Develop applications for the Android platform
Exec=$launcher %f
Icon=$icon
Categories=Development;IDE;
Terminal=false
StartupNotify=true
StartupWMClass=jetbrains-studio
EOF
  sudo_run install -m 0644 "$tmp" "$AS_DESKTOP" || rc=$?
  rm -f "$tmp"
  (( rc == 0 )) || log_warn "Could not write the desktop entry ($AS_DESKTOP) — Android Studio still runs via 'android-studio'."
  return 0
}

# Download + verify + unpack the official tarball, then wire it up. The trust boundary is the
# sha256 check BEFORE anything touches the system.
_as_install_tarball() {
  if ! _as_supported_arch; then
    log_err "Android Studio publishes Linux builds for x86_64 (amd64) only; this host is $(dpkg --print-architecture 2>/dev/null || uname -m)."
    return 1
  fi
  _as_resolve_tarball || return 1
  log_info "Channel: official Android Studio tarball (${_AS_NAME:-${_AS_VER:-stable}})."
  log_info "Downloading: $_AS_URL"
  local tmp tarball rc=0
  tmp="$(mktemp -d)"
  tarball="$tmp/android-studio-linux.tar.gz"
  # The tarball is large (~1.2 GB) from Google's CDN. Bound the connect phase and a genuine STALL
  # (<1 KB/s for 60s), NOT total elapsed time — a healthy slow-but-progressing transfer must not be
  # killed (the lesson scripts/cursor.sh documents). --retry + -C - retry transient drops and resume.
  if ! curl -fSL \
        --connect-timeout 30 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 5 --retry-all-errors \
        -C - "$_AS_URL" -o "$tarball"; then
    rm -rf "$tmp"; log_err "Failed to download the Android Studio tarball."; return 1
  fi
  if ! printf '%s  %s\n' "$_AS_SHA" "$tarball" | sha256sum -c - >/dev/null 2>&1; then
    rm -rf "$tmp"; log_err "Checksum mismatch on the downloaded tarball — refusing to install."; return 1
  fi
  log_info "Checksum verified (sha256). Installing to $AS_OPT_DIR (needs sudo)…"
  # Replace any previous tarball install so we extract cleanly. Guard the rm (path strictly under
  # /opt) and keep a "${var:?}" belt even though AS_OPT_DIR is a fixed constant.
  if [[ -e "$AS_OPT_DIR" ]]; then
    if kit_path_safe_under "$AS_OPT_DIR" /opt; then
      sudo_run rm -rf "${AS_OPT_DIR:?}" || rc=$?
    else
      rm -rf "$tmp"; log_err "Refusing to replace $AS_OPT_DIR (failed path guard)."; return 1
    fi
  fi
  # The archive has a top-level android-studio/ dir, so -C /opt yields /opt/android-studio.
  if (( rc == 0 )); then sudo_run tar -C /opt -xzf "$tarball" || rc=$?; fi
  rm -rf "$tmp"
  (( rc == 0 )) || { log_err "Failed to extract the Android Studio tarball into /opt."; return "$rc"; }
  [[ -d "$AS_OPT_DIR/bin" ]] || { log_err "Unexpected archive layout: $AS_OPT_DIR/bin not found after extraction."; return 1; }
  local launcher; launcher="$(_as_launcher_path)" || { log_err "No studio launcher found under $AS_OPT_DIR/bin."; return 1; }
  sudo_run ln -sfn "$launcher" "$AS_BIN_LINK" || { log_err "Could not create the $AS_BIN_LINK symlink."; return 1; }
  _as_write_desktop
  return 0
}

# --- snap channel (community) --------------------------------------------------
_as_install_snap() {
  have_cmd snap || return 1
  log_info "Channel: snap, classic confinement (maintained by the Snapcrafters community)."
  sudo_run snap install "$AS_SNAP_NAME" --classic
}

do_install() {
  if status >/dev/null 2>&1; then
    log_info "Android Studio is already installed ($(status 2>/dev/null | head -n1)) — to get the latest, run: ${0##*/} update"
    return 0
  fi
  # 1. Official tarball (primary) — amd64 only.
  if _as_supported_arch; then
    local rc=0
    _as_install_tarball || rc=$?
    if (( rc == 0 )); then
      log_info "Installed $(status 2>/dev/null | head -n1)."
      log_info "Launch it from your application menu or 'android-studio'. Update later with: ${0##*/} update"
      _as_sdk_note
      _as_where_note
      return 0
    fi
    # If the install only stalled because sudo needs a password on a TTY-less host, sudo_run has
    # already printed the exact command to run by hand — propagate that (RC_NEED_SUDO) instead of
    # muddying it with a snap attempt that would hit the identical wall.
    if (( rc == RC_NEED_SUDO )); then return "$rc"; fi
    log_warn "Official tarball install did not complete — trying snap."
  else
    log_warn "No official Linux tarball for this architecture — trying snap."
  fi
  # 2. snap (community) fallback.
  if _as_install_snap; then
    log_info "Installed Android Studio from snap (it auto-updates)."
    _as_sdk_note
    _as_where_note
    return 0
  fi
  log_err "Could not install Android Studio: the official tarball channel failed and snap is unavailable."
  log_err "See https://developer.android.com/studio/install for manual options."
  return 1
}

# update — refresh the snap (it auto-updates) or re-resolve + reinstall the latest tarball over
# the current one. Installs first if Android Studio is absent.
do_update() {
  if ! status >/dev/null 2>&1; then
    log_info "Android Studio is not installed — installing the latest instead."
    do_install
    return $?
  fi
  # Mirror status()'s detection order (tarball first, then snap) so the channel that status
  # reports is the one update acts on.
  if [[ -d "$AS_OPT_DIR" ]]; then
    local cur; cur="$(status 2>/dev/null | head -n1)"
    _as_install_tarball || return 1
    log_info "Android Studio updated. Now: $(status 2>/dev/null | head -n1) (was: ${cur:-unknown})."
    _as_where_note
    return 0
  fi
  if have_cmd snap && snap list "$AS_SNAP_NAME" >/dev/null 2>&1; then
    log_info "Android Studio is a snap (it auto-updates); refreshing now…"
    sudo_run snap refresh "$AS_SNAP_NAME" || { log_err "snap refresh failed."; return 1; }
    log_info "Now: $(status 2>/dev/null | head -n1)."
    return 0
  fi
  log_warn "Android Studio is installed but not via this script's snap/tarball channels; update it the way you installed it."
  return 0
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "Android Studio is not installed — nothing to remove."
    return 0
  fi
  local removed=0
  # Tarball install: remove the /opt dir (guarded), its symlink and desktop entry.
  if [[ -d "$AS_OPT_DIR" ]]; then
    if kit_path_safe_under "$AS_OPT_DIR" /opt; then
      sudo_run rm -rf "${AS_OPT_DIR:?}"
      removed=1
    else
      log_err "Refusing to delete $AS_OPT_DIR (failed path guard)."
      return 1
    fi
    [[ -L "$AS_BIN_LINK" ]] && sudo_run rm -f "$AS_BIN_LINK"
    [[ -f "$AS_DESKTOP" ]] && sudo_run rm -f "$AS_DESKTOP"
    log_info "Removed the Android Studio tarball install ($AS_OPT_DIR), its symlink and desktop entry."
  fi
  # snap install.
  if have_cmd snap && snap list "$AS_SNAP_NAME" >/dev/null 2>&1; then
    sudo_run snap remove "$AS_SNAP_NAME"
    removed=1
    log_info "Removed the Android Studio snap."
  fi
  if (( removed == 0 )); then
    log_warn "Android Studio is on PATH but not managed by this script's tarball or snap channels;"
    log_warn "remove it the way you installed it."
    return 1
  fi
  log_info "Your settings and SDK are kept (~/.config/Google/AndroidStudio*, ~/.android, ~/Android/Sdk) — delete them by hand to fully reset."
}

# --- Interactive management screen (the script's own UI) -----------------------
# A live panel: Install when missing; when installed, a status line plus Update and Uninstall
# actions. State is read live each pass; every change shells out via ui_run (visible + logged) and
# the screen reloads. Non-selectable rows (status line, spacer) are skipped during navigation.
# Limited terminals fall back to the synthesized op menu. `ui` is an entry mode (kit_dispatch).
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
      dkind+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) Android Studio")
    else
      dkind+=(status); dlabel+=("$(printf '%-15s %s' 'android-studio' "${UI_INFO}${ver}${UI_OFF}")")
      dkind+=(spacer); dlabel+=("")
      dkind+=(update); dlabel+=("$(ui_badge check) $(_as_t update_row)")
      dkind+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) Android Studio")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|status)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Android Studio" "$(ui_badge installed) $(ui_t installed)"
    else ui_header "Android Studio" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        status) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_as_t foot_manage)"
    else ui_footer "$(_as_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|status) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) Android Studio" -- "$0" install ;;
          update)  ui_run "$(_as_t update_row)" -- "$0" update ;;
          remove)  ui_confirm "$(_as_t confirm_remove)" n && ui_run "$(ui_t remove) Android Studio" -- "$0" remove ;;
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
  install    Install Android Studio (official sha256-verified tarball; falls back to snap). Idempotent.
  update     Re-fetch the latest stable tarball (or 'snap refresh') and install it over the current one
  remove     Uninstall Android Studio (keeps your settings & SDK under ~/.config/Google, ~/.android, ~/Android/Sdk)
  status     Print the install/version if present; exit code 0 iff installed
  ui         Open the interactive manager (needs a terminal)
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
