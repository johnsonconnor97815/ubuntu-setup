#!/usr/bin/env bash
#
# scripts/java.sh — install / manage OpenJDK on Ubuntu (apt), with multi-version management.
#
# Channel = apt OpenJDK (first-tier channel, like scripts/go.sh / node.sh — no vendor repo, no
# SDKMAN). This installs `openjdk-<N>-jdk-headless` (the compiler-complete JDK without the X/GUI
# bits) and manages it as components, like scripts/zsh.sh / tmux.sh / go.sh:
#   - JDK versions       — curated {17, 21} plus `add-version <N>` for anything apt offers
#                          (probed live with `apt-cache policy`, never a hard-coded list).
#   - the default JDK    — `set-default <N>` switches the WHOLE alternatives group via
#                          `update-java-alternatives` (apt registers java/javac/jar/keytool/… as
#                          INDEPENDENT alternatives links, so a bare `--set java` would leave javac
#                          pointing at another JVM and break Android/Gradle builds).
#   - JAVA_HOME on rc    — a managed line in your shell rc (go.sh do_ensure_path paradigm) pointing
#                          at the current default JDK; `--ensure-java-home on|off`.
#   - `home [<N>]`       — a read-only query op that prints a JDK home path on stdout (the API that
#                          scripts/android.sh consumes for its sdkmanager Java gate). Zero JVM spawn.
#
# Everything is observed live (no recorded flags): installed JDKs via dpkg, the default via
# update-alternatives, the JAVA_HOME line by reading the shell rc. Re-running converges.
# "Installed" = at least one managed openjdk JDK is present.
#
# Baseline JDK is 17 — AGP 8.x–9.x require JDK 17 (min = default) and Gradle accepts 17+. This is a
# pure JDK manager: it does NOT touch Maven/Gradle (those are separate, future concerns).
#
# Run it as:  java.sh install|remove|configure|status|meta|ui|help   plus
#             add-version <N> / remove-version <N> / set-default <N> /
#             ensure-java-home <on|off> / home [<N>]   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- Curated JDK versions ------------------------------------------------------
# Curated set offered in the UI; legacy 8/11 etc. still reachable via `add-version <N>`. We never
# hard-code which versions are *installable* — _java_apt_available probes apt live.
readonly JAVA_VERSIONS_ORDER="17 21"
readonly JAVA_BASELINE=17          # the install / configure baseline (AGP min = default)

# Marker for the managed JAVA_HOME line in the user's shell rc (go.sh do_ensure_path paradigm).
readonly JAVA_HOME_MARKER="# ubuntu-setup (JAVA_HOME)"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local. The names JDK, openjdk-<N>, java/javac,
# JAVA_HOME stay UNtranslated; only descriptive wording is localized. Resolve with _java_t KEY.
declare -gA JAVA_I18N
JAVA_I18N[en:jdk_versions]="JDK versions (apt openjdk)"
JAVA_I18N[en:java_home]="JAVA_HOME on rc (points at the default JDK)"
JAVA_I18N[en:add_version]="Add a JDK version…"
JAVA_I18N[en:prompt_version]="JDK major version (e.g. 17, 21, 11)"
JAVA_I18N[en:apply_recommended]="Apply recommended setup (JDK 17 + default + JAVA_HOME)"
JAVA_I18N[en:confirm_remove]="Uninstall all managed OpenJDK JDKs? (apt remove; clears the JAVA_HOME line)"
JAVA_I18N[en:confirm_remove_version]="Uninstall the openjdk-{X} JDK?"
JAVA_I18N[en:foot_main]="↑↓ move   space add/remove   d default   a add   enter select   esc/q close"
JAVA_I18N[en:tag_default]="default"
JAVA_I18N[en:invalid_version]="Invalid JDK version (digits only, e.g. 17)."
JAVA_I18N[en:not_available]="openjdk-{X}-jdk is not available from apt on this release."
JAVA_I18N[zh:jdk_versions]="JDK 版本(apt openjdk)"
JAVA_I18N[zh:java_home]="JAVA_HOME 写入 rc(指向默认 JDK)"
JAVA_I18N[zh:add_version]="添加一个 JDK 版本…"
JAVA_I18N[zh:prompt_version]="JDK 主版本号(如 17、21、11)"
JAVA_I18N[zh:apply_recommended]="应用推荐配置(JDK 17 + 默认 + JAVA_HOME)"
JAVA_I18N[zh:confirm_remove]="卸载所有受管的 OpenJDK JDK?(apt remove;清除 JAVA_HOME 行)"
JAVA_I18N[zh:confirm_remove_version]="卸载 openjdk-{X} JDK?"
JAVA_I18N[zh:foot_main]="↑↓ 移动   space 增删   d 默认   a 添加   ↵ 选择   esc/q 关闭"
JAVA_I18N[zh:tag_default]="默认"
JAVA_I18N[zh:invalid_version]="非法的 JDK 版本(只允许数字,如 17)。"
JAVA_I18N[zh:not_available]="本系统的 apt 没有 openjdk-{X}-jdk。"
JAVA_I18N[ja:jdk_versions]="JDK バージョン(apt openjdk)"
JAVA_I18N[ja:java_home]="JAVA_HOME を rc に追加(デフォルト JDK を指す)"
JAVA_I18N[ja:add_version]="JDK バージョンを追加…"
JAVA_I18N[ja:prompt_version]="JDK メジャーバージョン(例:17、21、11)"
JAVA_I18N[ja:apply_recommended]="推奨セットアップを適用(JDK 17 + デフォルト + JAVA_HOME)"
JAVA_I18N[ja:confirm_remove]="管理下の OpenJDK JDK をすべてアンインストールしますか?(apt remove;JAVA_HOME 行も削除)"
JAVA_I18N[ja:confirm_remove_version]="openjdk-{X} JDK をアンインストールしますか?"
JAVA_I18N[ja:foot_main]="↑↓ 移動   space 追加/削除   d 既定   a 追加   ↵ 選択   esc/q 閉じる"
JAVA_I18N[ja:tag_default]="デフォルト"
JAVA_I18N[ja:invalid_version]="不正な JDK バージョン(数字のみ、例:17)。"
JAVA_I18N[ja:not_available]="この環境の apt には openjdk-{X}-jdk がありません。"

# _java_t KEY — localized Java string for $UI_LANG (en/zh/ja), fallback en -> key.
_java_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${JAVA_I18N[$lang:$1]:-${JAVA_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=java
name=Java (OpenJDK)
category=languages
tags=cli
ops=install,remove,configure
desc=OpenJDK dev environment — apt openjdk JDK (headless), multi-version + grouped default switch + JAVA_HOME
META
}

# --- User-space guard & rc file ------------------------------------------------
# Refuse a sudo-wrapped run for the user-owned steps (shell rc / JAVA_HOME). apt install/remove and
# the alternatives switch escalate per-command via sudo_run and are fine under any user.
_java_user_guard() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run this as your normal user, not via sudo — it writes the JAVA_HOME line into your shell rc."
    return 1
  fi
}

# The user's shell rc file (honors SUDO_USER's real home; never edits another user's dotfile).
_java_rc_file() {
  local home="${HOME:-}" shell="${SHELL:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || home="${HOME:-}"
  case "$shell" in */zsh) printf '%s/.zshrc' "$home" ;; *) printf '%s/.bashrc' "$home" ;; esac
}

# --- Probes (live; cheap, zero JVM spawn) --------------------------------------
# A safe JDK major version: digits only. Blocks shell metacharacters before <N> is ever interpolated
# into a package name or an alternatives path (apt itself receives an argv array via sudo_run "$@",
# so this is consistency/hygiene rather than the only line of defence).
_java_valid_version() { [[ "$1" =~ ^[0-9]+$ ]]; }

# The dpkg package for the managed (compiler-complete, headless) JDK of major version <N>.
_java_pkg() { printf 'openjdk-%s-jdk-headless' "$1"; }

# Is openjdk-<N>-jdk-headless installable from apt on THIS release? Decide on the candidate (stable
# field), forcing LC_ALL=C so a localized "Candidate:" label never makes a probe falsely fail — the
# same locale-proofing rule the lib applies to sudo_passwordless (judge stable text, not translated
# wording). We probe the -jdk-headless package we actually install.
_java_apt_available() {
  local cand
  cand="$(LC_ALL=C apt-cache policy "$(_java_pkg "$1")" 2>/dev/null | awk '/Candidate:/{print $2; exit}')"
  [[ -n "$cand" && "$cand" != "(none)" ]]
}

# Is a managed openjdk JDK of major version <N> installed? True for either the headless or the full
# JDK (configure --full-jdk may have installed the latter); both register the same alternatives group.
_java_version_installed() {
  pkg_installed "openjdk-$1-jdk-headless" || pkg_installed "openjdk-$1-jdk"
}

# Every managed JDK major version currently installed (one <N> per line, ascending). Pure dpkg —
# cheap, zero JVM. We discover versions by listing matching openjdk-*-jdk* packages from dpkg, not a
# hard-coded set, so add-version'd legacy JDKs (8/11) are seen too.
_java_installed_versions() {
  dpkg-query -W -f '${Package} ${Status}\n' 'openjdk-*-jdk*' 2>/dev/null \
    | awk '$NF=="installed" && $2=="install"' \
    | sed -n 's/^openjdk-\([0-9][0-9]*\)-jdk\(-headless\)\? .*/\1/p' \
    | sort -n -u
}
_java_count() { _java_installed_versions | grep -c . || true; }
# Any managed JDK at all? (the install boolean; pure dpkg, zero JVM)
_java_any_installed() { [[ -n "$(_java_installed_versions)" ]]; }

# The major version of the current default `java` (via /etc/alternatives, NOT by spawning java).
# Resolves the alternatives symlink and parses the java-<N>-openjdk dir name. Echoes nothing if no
# default is set. Zero JVM.
_java_default_version() {
  local link real
  link="/etc/alternatives/java"
  [[ -e "$link" ]] || return 0
  real="$(readlink -f "$link" 2>/dev/null || true)"
  [[ -n "$real" ]] || return 0
  printf '%s' "$real" | sed -n 's#.*/java-\([0-9][0-9]*\)-openjdk.*#\1#p'
}

# _java_default_home — the CURRENT DEFAULT JDK's home, derived purely from the alternatives symlink
# (readlink -f /etc/alternatives/java stripped of /bin/java). Zero JVM. Prints the path + exit 0 on a
# hit; exit 1 if no default java is set / it cannot be resolved. (Shared by `home` and ensure-java-home.)
_java_default_home() {
  local link real
  link="/etc/alternatives/java"
  [[ -e "$link" ]] || return 1
  real="$(readlink -f "$link" 2>/dev/null || true)"
  [[ -n "$real" && "$real" == */bin/java ]] || return 1
  printf '%s' "${real%/bin/java}"
}

# _java_jvm_home <N> — the JDK home (the dir whose bin/ holds java+javac) for major version <N>, by
# FILESYSTEM inspection only (zero JVM, never `java -version`). Primary: glob the canonical apt
# layout /usr/lib/jvm/java-<N>-openjdk-<arch> and verify bin/javac. Fallback: parse the per-candidate
# `Alternative:` segments of `update-alternatives --query java` (each candidate path, NOT Value:/Best:)
# for one containing java-<N>-openjdk, then strip /bin/java. Prints the path + exit 0 on a hit;
# exit 1 if not found. All diagnostics would go to stderr — but this prints ONLY the path on success.
_java_jvm_home() {
  local n="$1" arch d real
  _java_valid_version "$n" || return 1
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  # Primary: canonical layout. Modern OpenJDK 17/21 is a single home (bin/ holds java AND javac).
  if [[ -n "$arch" ]]; then
    d="/usr/lib/jvm/java-${n}-openjdk-${arch}"
    [[ -d "$d" && -x "$d/bin/javac" ]] && { printf '%s' "$d"; return 0; }
  fi
  # Fallback: any /usr/lib/jvm/java-<N>-openjdk* dir with a javac (arch unknown / nonstandard).
  for d in /usr/lib/jvm/java-"${n}"-openjdk*; do
    [[ -d "$d" && -x "$d/bin/javac" ]] && { printf '%s' "$d"; return 0; }
  done
  # Last resort: walk the per-candidate Alternative: lines of `update-alternatives --query java`.
  while IFS= read -r real; do
    case "$real" in
      */java-"${n}"-openjdk*/bin/java)
        real="${real%/bin/java}"
        [[ -d "$real" && -x "$real/bin/javac" ]] && { printf '%s' "$real"; return 0; }
        ;;
    esac
  done < <(update-alternatives --query java 2>/dev/null | sed -n 's/^Alternative: //p')
  return 1
}

# Exit 0 iff at least one managed openjdk JDK is installed (pure dpkg, cheap, zero JVM). KIT_PROBE_ONLY
# returns the boolean and stops; otherwise append the default major version + the count of managed JDKs.
# Both paths return the SAME exit code and spawn ZERO JVM (no java -version anywhere).
status() {
  _java_any_installed || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip the counting below
  local def n
  def="$(_java_default_version)"
  n="$(_java_count)"
  printf 'default %s · jdks %s\n' "${def:-?}" "$n"
}

# --- install / remove ----------------------------------------------------------

# install (no-arg) = the baseline: JDK 17 (headless) + make it the default + write the JAVA_HOME line.
# Pure JDK — Maven/Gradle are intentionally untouched.
do_install() {
  if _java_version_installed "$JAVA_BASELINE"; then
    log_info "openjdk-$JAVA_BASELINE JDK already installed — converging default + JAVA_HOME."
  else
    _java_apt_available "$JAVA_BASELINE" || {
      log_err "openjdk-$JAVA_BASELINE-jdk-headless is not available from apt on this release."; return 1; }
    apt_install "$(_java_pkg "$JAVA_BASELINE")"
  fi
  do_set_default "$JAVA_BASELINE"
  # The JAVA_HOME rc write runs AS THE USER; under a sudo-wrapped run, skip it (the guard would
  # abort mid-flow after the JDK is already installed + defaulted) and tell the user how to finish.
  if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
    do_ensure_java_home on
  else
    log_warn "JDK installed and the default set, but JAVA_HOME was NOT written: this is a sudo-wrapped run."
    log_warn "Re-run as your normal user to add it: ${0##*/} ensure-java-home on"
  fi
  log_info "JDK $JAVA_BASELINE ready. Add another version with: ${0##*/} add-version 21   (or open: swkit java)"
}

# remove (no-arg) = uninstall ALL managed openjdk JDKs (apt remove, keeps config) + clear the
# JAVA_HOME line + reset the alternatives group so no dangling default remains.
do_remove() {
  if ! _java_any_installed; then
    log_info "No managed OpenJDK JDK is installed — nothing to remove."
    return 0
  fi
  local v; local -a pkgs=()
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    pkg_installed "openjdk-$v-jdk-headless" && pkgs+=("openjdk-$v-jdk-headless")
    pkg_installed "openjdk-$v-jdk"          && pkgs+=("openjdk-$v-jdk")
  done < <(_java_installed_versions)
  [[ ${#pkgs[@]} -gt 0 ]] && apt_remove "${pkgs[@]}"
  # Clear the managed JAVA_HOME line (best-effort; runs as the user when not sudo-wrapped).
  if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
    do_ensure_java_home off || true
  else
    log_warn "The managed JAVA_HOME line was NOT cleared: this is a sudo-wrapped run, and it lives in your shell rc."
    log_warn "Re-run as your normal user to clear it: ${0##*/} ensure-java-home off"
  fi
  # Reset the alternatives group: with all openjdk JDKs gone, auto mode drops the stale java/javac links.
  sudo_run update-alternatives --auto java 2>/dev/null || true
  sudo_run update-alternatives --auto javac 2>/dev/null || true
  log_info "Removed the managed OpenJDK JDKs. (apt remove keeps any user config under /etc.)"
}

# --- default switch (grouped) --------------------------------------------------
# set-default <N> — switch the WHOLE toolchain (java/javac/jar/keytool/…) to openjdk-<N>. apt
# registers each tool as an INDEPENDENT alternatives link, so a bare `--set java` would leave javac
# on a different JVM (a real Android/Gradle breaker). Prefer the grouped switch via
# `update-java-alternatives --set <id>` (id parsed from --list); fall back, when the .jinfo is not
# registered (a known -jdk-headless gap), to enumerating every link and --set'ing it individually.
# AFTER switching, ASSERT java and javac report the same major version — fail fast if they diverge.
do_set_default() {
  local n="${1:-}"
  [[ -n "$n" ]] || { log_err "Usage: ${0##*/} set-default <N>"; return 2; }
  _java_valid_version "$n" || { log_err "$(_java_t invalid_version) ($n)"; return 2; }
  _java_version_installed "$n" || { log_err "openjdk-$n JDK is not installed (add it with: ${0##*/} add-version $n)."; return 1; }

  # Preferred: the grouped switch. Parse the exact .jinfo id from `update-java-alternatives --list`
  # (e.g. "java-1.17.0-openjdk-amd64  1711  /usr/lib/jvm/java-17-openjdk-amd64"): the FIRST field of
  # the row whose path contains java-<N>-openjdk. Stable across releases/arch (don't hard-code the id).
  local id=""
  if have_cmd update-java-alternatives; then
    id="$(update-java-alternatives --list 2>/dev/null \
            | awk -v n="$n" '$NF ~ ("/java-" n "-openjdk") {print $1; exit}')"
  fi
  local switched=0
  if [[ -n "$id" ]]; then
    if sudo_run update-java-alternatives --set "$id"; then switched=1
    else log_warn "update-java-alternatives --set $id failed — falling back to per-link switching."; fi
  fi

  # Headless fallback: no grouped .jinfo (or the grouped switch failed). Enumerate EVERY registered
  # alternatives master (via --get-selections, whose first field is the master name) — not a fixed
  # tool list, since openjdk-<N>-jdk-headless registers many more links (jlink/jcmd/jmod/jstack/jmap/
  # jstat/jfr/jdeprscan/…); a hard-coded subset would leave deep-tool links on the old JVM silently.
  # For each master, if --list offers a candidate path under java-<N>-openjdk, --set it, one at a time.
  if (( ! switched )); then
    local link cand chosen any=0
    if have_cmd update-alternatives; then
      while IFS= read -r link; do
        [[ -n "$link" ]] || continue
        chosen=""
        while IFS= read -r cand; do
          case "$cand" in */java-"${n}"-openjdk*) chosen="$cand"; break ;; esac
        done < <(update-alternatives --list "$link" 2>/dev/null || true)
        [[ -n "$chosen" ]] || continue
        if sudo_run update-alternatives --set "$link" "$chosen"; then any=1
        else log_warn "Could not set the alternatives link for '$link'."; fi
      done < <(update-alternatives --get-selections 2>/dev/null | awk '{print $1}')
    fi
    (( any )) || { log_err "Could not switch the default JDK to openjdk-$n (no alternatives links found)."; return 1; }
  fi

  # Assert java and javac now agree on the major version — the whole point of the grouped switch.
  # We read versions ONLY here (an explicit verification of a write), never in status/home.
  # A missing java/javac after the switch IS the inconsistency this guard exists to catch (a
  # -jdk-headless gap can leave one link unset), so treat it as a fail-fast, not a silent pass.
  if ! have_cmd java || ! have_cmd javac; then
    log_err "After switching, java and/or javac is not on PATH — the alternatives group is inconsistent."
    log_err "Inspect with: update-alternatives --query java ; update-alternatives --query javac"
    return 1
  fi
  local jv cv
  jv="$(java -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -n1)"
  # Older OpenJDK prints 1.8.0 style; normalize "1.X" -> X for the comparison.
  [[ "$jv" == 1 ]] && jv="$(java -version 2>&1 | sed -n 's/.*version "1\.\([0-9][0-9]*\).*/\1/p' | head -n1)"
  cv="$(javac -version 2>&1 | sed -n 's/.*javac \([0-9][0-9]*\).*/\1/p' | head -n1)"
  [[ "$cv" == 1 ]] && cv="$(javac -version 2>&1 | sed -n 's/.*javac 1\.\([0-9][0-9]*\).*/\1/p' | head -n1)"
  if [[ -z "$jv" || -z "$cv" || "$jv" != "$cv" ]]; then
    log_err "After switching, java reports ${jv:-?} but javac reports ${cv:-?} — the alternatives group is inconsistent."
    log_err "Inspect with: update-alternatives --query java ; update-alternatives --query javac"
    return 1
  fi
  log_info "Default JDK is now openjdk-$n (java + javac = $jv)."

  # Re-point the managed JAVA_HOME line at the new default if it is currently active.
  if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then
    local rc; rc="$(_java_rc_file)"
    if [[ -f "$rc" ]] && grep -qF "$JAVA_HOME_MARKER" "$rc"; then do_ensure_java_home on || true; fi
  fi
}

# --- managed versions (add / remove) -------------------------------------------

# add-version <N> — validate + probe apt, then install openjdk-<N>-jdk-headless (additive; does NOT
# change the default — use set-default <N> for that).
do_add_version() {
  local n="${1:-}"
  [[ -n "$n" ]] || { log_err "Usage: ${0##*/} add-version <N>"; return 2; }
  _java_valid_version "$n" || { log_err "$(_java_t invalid_version) ($n)"; return 2; }
  if _java_version_installed "$n"; then
    log_info "openjdk-$n JDK is already installed — nothing to do."
    return 0
  fi
  if ! _java_apt_available "$n"; then
    local msg; msg="$(_java_t not_available)"; log_err "${msg//\{X\}/$n}"
    return 1
  fi
  apt_install "$(_java_pkg "$n")"
  log_info "Installed openjdk-$n JDK. Make it the default with: ${0##*/} set-default $n"
}

# remove-version <N> — uninstall a single managed JDK. If it is the CURRENT default and other JDKs
# survive, re-point the default at the lowest survivor and regenerate JAVA_HOME. If it was the last
# one, clear the JAVA_HOME line.
do_remove_version() {
  local n="${1:-}"
  [[ -n "$n" ]] || { log_err "Usage: ${0##*/} remove-version <N>"; return 2; }
  _java_valid_version "$n" || { log_err "$(_java_t invalid_version) ($n)"; return 2; }
  if ! _java_version_installed "$n"; then
    log_info "openjdk-$n JDK is not installed — nothing to remove."
    return 0
  fi
  local was_default=0; [[ "$(_java_default_version)" == "$n" ]] && was_default=1

  local -a pkgs=()
  pkg_installed "openjdk-$n-jdk-headless" && pkgs+=("openjdk-$n-jdk-headless")
  pkg_installed "openjdk-$n-jdk"          && pkgs+=("openjdk-$n-jdk")
  apt_remove "${pkgs[@]}"

  # Decide what remains and converge the default / JAVA_HOME.
  local survivor=""
  survivor="$(_java_installed_versions | head -n1 || true)"
  if [[ -z "$survivor" ]]; then
    # That was the last JDK — drop the stale alternatives default and clear the JAVA_HOME line.
    sudo_run update-alternatives --auto java 2>/dev/null || true
    sudo_run update-alternatives --auto javac 2>/dev/null || true
    if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then do_ensure_java_home off || true; fi
    log_info "Removed openjdk-$n JDK — no managed JDK remains; cleared the JAVA_HOME line."
  elif (( was_default )); then
    # Removed the current default but others survive — re-point to the lowest survivor + regenerate.
    log_info "Removed the default (openjdk-$n) — re-pointing the default at openjdk-$survivor."
    do_set_default "$survivor"
  else
    log_info "Removed openjdk-$n JDK. The default (openjdk-$(_java_default_version)) is unchanged."
  fi
}

# --- JAVA_HOME on the shell rc -------------------------------------------------
# Add ($1=on, default) or remove ($1=off) the managed JAVA_HOME line. 'on' always REGENERATES the
# line to point at the current default JDK home (so it follows set-default), backing up first.
do_ensure_java_home() {
  _java_user_guard || return 1
  local mode="${1:-on}" rc home tmp
  rc="$(_java_rc_file)"
  case "$mode" in
    on)
      home="$(_java_default_home 2>/dev/null || true)"
      [[ -n "$home" ]] || { log_err "No default JDK home found — set a default first (${0##*/} set-default <N>)."; return 1; }
      export JAVA_HOME="$home"
      local line; line="export JAVA_HOME=\"$home\" $JAVA_HOME_MARKER"
      # If an identical managed line is already present, nothing to do; otherwise regenerate it.
      if [[ -f "$rc" ]] && grep -qxF "$line" "$rc"; then
        log_info "JAVA_HOME already set to $home via $rc — nothing to do."
        return 0
      fi
      [[ -s "$rc" ]] && backup_file "$rc"   # back up only a real (non-empty) rc; printf creates it if missing
      if [[ -f "$rc" ]] && grep -qF "$JAVA_HOME_MARKER" "$rc"; then
        # Replace the stale managed line (default changed) in place.
        tmp="$(mktemp)"
        grep -vF "$JAVA_HOME_MARKER" "$rc" >"$tmp" || true
        printf '%s\n' "$line" >>"$tmp"
        mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
      else
        printf '%s\n' "$line" >>"$rc"
      fi
      log_info "Set JAVA_HOME=$home in $rc — open a new shell or 'source $rc'."
      ;;
    off)
      if [[ ! -f "$rc" ]] || ! grep -qF "$JAVA_HOME_MARKER" "$rc"; then
        log_info "No managed JAVA_HOME line in $rc — nothing to remove."
        return 0
      fi
      backup_file "$rc"
      tmp="$(mktemp)"
      grep -vF "$JAVA_HOME_MARKER" "$rc" >"$tmp" || true
      mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
      log_info "Removed the managed JAVA_HOME line from $rc."
      ;;
    *) log_err "ensure-java-home takes on|off."; return 2 ;;
  esac
}

# --- home [<N>]: the read-only query op that android.sh consumes ---------------
# Prints ONLY the JDK home path to stdout (all diagnostics / log_* go to stderr, so
# `JAVA_HOME=$(java.sh home <N>)` stays clean). Zero JVM — NEVER java -version.
#   no arg / default : readlink -f /etc/alternatives/java, stripped of /bin/java (the current default).
#   <N> (non-default): _java_jvm_home <N> (fs glob + javac verify; alternatives candidate fallback).
# Exit 0 on a hit (path printed); nonzero if absent.
do_home() {
  local n="${1:-}"
  if [[ -z "$n" ]]; then
    # The current default's home (alternatives symlink only, no JVM).
    local home
    if home="$(_java_default_home)" && [[ -n "$home" ]]; then
      printf '%s\n' "$home"
      return 0
    fi
    log_err "No default java is set / could not resolve the default JDK home."
    return 1
  fi
  _java_valid_version "$n" || { log_err "$(_java_t invalid_version) ($n)"; return 2; }
  local home
  if home="$(_java_jvm_home "$n")" && [[ -n "$home" ]]; then
    printf '%s\n' "$home"
    return 0
  fi
  log_err "No openjdk-$n JDK home found on this system."
  return 1
}

# --- configure -----------------------------------------------------------------
# With NO flags: the conservative baseline = ensure JDK 17 + default + JAVA_HOME (same as install).
# --recommended is also 17-centric. Flags layer on a specific default, the JAVA_HOME toggle, and the
# full (non-headless) JDK choice.
#
# Flags are first COLLECTED into locals, then APPLIED in a fixed precedence AFTER the parse loop — so
# argv order never decides the outcome. Precedence: (1) --recommended baseline; (2) --full-jdk installs
# the COMPLETE JDK for the effective target (the chosen --default, else 17) + makes it default + writes
# JAVA_HOME — a full do_install analogue for ANY version (so --full-jdk never leaves a bare set-default
# on a missing version); (3) an explicit --default <N> (so --default wins over --recommended either way);
# (4) the JAVA_HOME toggle, last. Thus `--default 21 --recommended` and `--recommended --default 21` both
# end at 21, and `--full-jdk --default 21` installs+defaults 21 (not 17).
do_configure() {
  if [[ $# -eq 0 ]]; then
    do_install
    return 0
  fi
  local recommended=0 full=0 default_n="" ensure_mode=""
  while (( $# > 0 )); do
    case "$1" in
      --recommended)        recommended=1; shift ;;
      --default)   [[ $# -ge 2 ]] || { log_err "--default needs a JDK major version (e.g. 17)."; return 2; }; default_n="$2"; shift 2 ;;
      --default=*) default_n="${1#--default=}"; shift ;;
      --ensure-java-home)   [[ $# -ge 2 ]] || { log_err "--ensure-java-home needs on|off."; return 2; }; ensure_mode="$2"; shift 2 ;;
      --ensure-java-home=*) ensure_mode="${1#--ensure-java-home=}"; shift ;;
      --full-jdk)  full=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done

  # Effective target for --full-jdk = the chosen --default, else the 17 baseline.
  local full_target="${default_n:-$JAVA_BASELINE}"

  # 1) --recommended: the 17-centric baseline (install + default + JAVA_HOME).
  if (( recommended )); then
    do_install
  fi
  # 2) --full-jdk: install the COMPLETE (X/GUI-bearing) JDK for the target version, then make it the
  # default and write JAVA_HOME — the full-setup analogue of do_install for ANY version (the full pkg
  # supersets the headless toolchain, so the target ends up installed + defaulted). This is why both
  # `--full-jdk` alone and `--full-jdk --default <N>` yield a coherent install with no bare set-default
  # on a missing version. The JAVA_HOME write follows do_install's sudo-wrap guard.
  if (( full )); then
    if _java_apt_available "$full_target"; then apt_install "openjdk-$full_target-jdk"
    elif _java_version_installed "$full_target"; then log_warn "openjdk-$full_target-jdk (full) is unavailable from apt; keeping the installed headless openjdk-$full_target."
    else log_err "openjdk-$full_target-jdk is not available from apt on this release."; return 1; fi
    do_set_default "$full_target"
    if [[ $EUID -ne 0 || -z "${SUDO_USER:-}" ]]; then do_ensure_java_home on
    else log_warn "Full JDK installed + defaulted, but JAVA_HOME was NOT written (sudo-wrapped run). Re-run as your user: ${0##*/} ensure-java-home on"; fi
  fi
  # 3) An explicit --default <N> wins regardless of argv order. With --full-jdk it is already the default
  # (full_target==N, a harmless re-assert); without --full-jdk it switches to an already-installed N.
  [[ -n "$default_n" ]] && do_set_default "$default_n"
  # 4) The JAVA_HOME toggle, applied LAST so on/off is the final word over any write above.
  [[ -n "$ensure_mode" ]] && do_ensure_java_home "$ensure_mode"
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager (go.sh paradigm): the curated + installed JDK versions as a space-to-add/remove
# checklist with `d` to set the default and `a` to add an arbitrary version, the JAVA_HOME-on-rc
# toggle, "Apply recommended setup", and Uninstall-all. State is read live each pass (pure dpkg +
# alternatives — zero JVM); every change shells out via ui_run (visible + logged, so the sudo password
# prompt lands on the real terminal) then the screen reloads. `ui` is an entry mode — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g v
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state (zero JVM) ----
    local any=0 def=""
    if _java_any_installed; then any=1; def="$(_java_default_version)"; fi
    # The version set shown = curated order ∪ anything installed outside it.
    local -a shown=() seen=""
    for v in $JAVA_VERSIONS_ORDER; do shown+=("$v"); seen="$seen $v "; done
    local iv
    while IFS= read -r iv; do
      [[ -n "$iv" ]] || continue
      case "$seen" in *" $iv "*) ;; *) shown+=("$iv"); seen="$seen $iv " ;; esac
    done < <(_java_installed_versions)

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    dkind+=(header); did+=(""); dlabel+=("$(_java_t jdk_versions)")
    for v in "${shown[@]}"; do
      local badge star
      if _java_version_installed "$v"; then badge="$(ui_badge installed)"; else badge="$(ui_badge missing)"; fi
      star=""; [[ -n "$def" && "$v" == "$def" ]] && star=" ${UI_ACCENT}★ $(_java_t tag_default)${UI_OFF}"
      dkind+=(ver); did+=("$v"); dlabel+=("$badge $(printf 'openjdk-%-3s' "$v")${star}")
    done
    dkind+=(add); did+=(add); dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_java_t add_version)")
    dkind+=(spacer); did+=(""); dlabel+=("")
    if (( any )); then
      local hb; hb="$(_java_rc_file)"
      if [[ -f "$hb" ]] && grep -qF "$JAVA_HOME_MARKER" "$hb"; then hb="$(ui_badge on)"; else hb="$(ui_badge off)"; fi
      dkind+=(java_home); did+=(java_home); dlabel+=("$hb $(_java_t java_home)")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_java_t apply_recommended)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove)")
    else
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_java_t apply_recommended)")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( any )); then ui_header "Java (OpenJDK)" "default openjdk-${def:-?} $(ui_badge installed)"
    else ui_header "Java (OpenJDK)" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_java_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          ver)
            local vv="${did[$sel]}"
            if _java_version_installed "$vv"; then
              local cmsg; cmsg="$(_java_t confirm_remove_version)"; cmsg="${cmsg//\{X\}/$vv}"
              ui_confirm "$cmsg" n && ui_run "remove-version $vv" -- "$0" remove-version "$vv"
            else
              ui_run "add-version $vv" -- "$0" add-version "$vv"
            fi ;;
          add)         ui_input "$(_java_t prompt_version)" "" && [[ -n "$UI_INPUT" ]] && ui_run "add-version $UI_INPUT" -- "$0" add-version "$UI_INPUT" ;;
          java_home)
            local hb; hb="$(_java_rc_file)"
            if [[ -f "$hb" ]] && grep -qF "$JAVA_HOME_MARKER" "$hb"; then ui_run "JAVA_HOME off" -- "$0" ensure-java-home off
            else ui_run "JAVA_HOME on" -- "$0" ensure-java-home on; fi ;;
          recommended) ui_run "$(_java_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_java_t confirm_remove)" n && ui_run "$(ui_t remove) Java" -- "$0" remove ;;
        esac ;;
      d)
        if [[ "${dkind[$sel]}" == ver ]]; then
          local vv="${did[$sel]}"
          _java_version_installed "$vv" && ui_run "set-default $vv" -- "$0" set-default "$vv"
        fi ;;
      a)  ui_input "$(_java_t prompt_version)" "" && [[ -n "$UI_INPUT" ]] && ui_run "add-version $UI_INPUT" -- "$0" add-version "$UI_INPUT" ;;
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
  install               Install the baseline JDK $JAVA_BASELINE (apt openjdk-$JAVA_BASELINE-jdk-headless) + default + JAVA_HOME. Idempotent.
  remove                Uninstall ALL managed OpenJDK JDKs (apt remove); clear the JAVA_HOME line + reset alternatives
  configure [opts]      Set up the JDK. With no flags: ensure JDK $JAVA_BASELINE + default + JAVA_HOME.
                          --recommended            JDK $JAVA_BASELINE + default + JAVA_HOME (17-centric)
                          --default <N>            switch the default JDK (grouped: java + javac together)
                          --ensure-java-home on|off  add/remove the JAVA_HOME line in your shell rc
                          --full-jdk               also install the complete (non-headless) openjdk-$JAVA_BASELINE-jdk
  add-version <N>       Install openjdk-<N>-jdk-headless (curated: ${JAVA_VERSIONS_ORDER// /, }; any apt-available N)
  remove-version <N>    Uninstall one JDK (re-points the default + JAVA_HOME if it was the default)
  set-default <N>       Make openjdk-<N> the default — grouped switch, then asserts java + javac agree
  ensure-java-home on|off  Add/remove the JAVA_HOME line (points at the default JDK) in your shell rc
  home [<N>]            Print a JDK home path on stdout (default's, or version <N>'s). Read-only, no JVM.
  status                Print 'default <N> · jdks <N>'; exit 0 iff at least one managed JDK is installed
  ui                    Open the interactive manager (needs a terminal)
  meta                  Print machine-readable metadata
  help                  Show this help

Notes: ensure-java-home runs AS YOU (never sudo) — it writes the JAVA_HOME line into your shell rc.
apt install/remove and the alternatives switch escalate per-command via sudo. 'home' prints ONLY the
path to stdout (diagnostics to stderr), so JAVA_HOME=\$(${0##*/} home) is safe to embed.
EOF
}

kit_dispatch "$@"
