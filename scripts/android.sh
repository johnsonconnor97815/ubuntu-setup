#!/usr/bin/env bash
#
# scripts/android.sh — install / manage a headless Android SDK toolchain on Ubuntu.
#
# The Android SDK has NO apt package: the command-line tools come as an official zip that we
# extract to $ANDROID_HOME/cmdline-tools/latest/, and everything else (platform-tools, platforms,
# build-tools, emulator, system-images, NDK, CMake) is driven by `sdkmanager` from inside it. This
# is the *headless* toolchain — NO Android Studio (that GUI IDE is a separate, future concern;
# $ANDROID_HOME=~/Android/Sdk aligns with Studio's default so the two converge naturally).
#
# Like scripts/zsh.sh / tmux.sh / rime.sh this is a *component manager*: cmdline-tools + platform-
# tools are the install baseline, and platforms / build-tools / emulator / system-images / NDK /
# CMake / scrcpy are each opt-in. The whole SDK download → extract → sdkmanager flow runs
# USER-SPACE (no sudo); only a few conditional apt items (curl/ca-certificates/unzip, optional
# libgl1 for the emulator, scrcpy) escalate per-command via the shared library.
#
# One-way dependency android → java (java.sh does NOT know android exists, like claude → node):
# every sdkmanager JVM spawn needs a compatible JDK (>=17, AGP's minimum). _android_java_gate
# resolves one via "$KIT_SCRIPTS_DIR/java.sh" (using its read-only `home`/`status` API, ZERO JVM)
# and runs sdkmanager under that JAVA_HOME — process-local, NEVER touching the global default.
# When no >=17 JDK exists the gate points the user at `swkit java install` and stops; it NEVER
# auto-installs Java in the headless path (only ui() delegates an install, via ui_run for sudo).
#
# Honesty note: the emulator / system-images / KVM acceleration are DESKTOP-GUI concerns. Over
# SSH / on a headless box (no /dev/kvm) install/configure say so and the emulator is dropped from
# --recommended. Google's native Linux SDK binaries (adb/aapt2/emulator/NDK) are x86_64-only;
# on arm64 hosts status/install warn honestly (the JAR-based sdkmanager itself still runs on a JVM).
#
# Run it as:  android.sh install|remove|configure|accept-licenses|purge|status|meta|ui|help   plus
#             add-package <pkg> / remove-package <pkg> / add-platform <N> / remove-platform <N> /
#             set-mirror <name|url>   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

# --- Curated knowledge ---------------------------------------------------------
# The compatible JDK threshold: AGP 8.x–9.x require JDK 17 (min = default); sdkmanager accepts
# JDK 11+, but we gate on the build threshold so the SDK we lay down can actually build.
readonly ANDROID_JDK_MIN=17
# The official repository base + the package manifest sdkmanager reads (host = dl.google.com).
readonly ANDROID_REPO_BASE_DEFAULT="https://dl.google.com/android/repository/"
readonly ANDROID_REPO_MANIFEST="repository2-3.xml"   # current schema; falls back to -1/-2 on 404
# Markers for the managed env block in the user's shell rc (tmux.sh begin/end-marker paradigm).
readonly ANDROID_BLOCK_BEGIN="# >>> ubuntu-setup android (managed block) >>>"
readonly ANDROID_BLOCK_END="# <<< ubuntu-setup android (managed block) <<<"
# Marker for the managed SDK-mirror line in the rc (so set-mirror can find/replace just our line).
readonly ANDROID_MIRROR_MARKER="# ubuntu-setup (android SDK mirror)"

# Curated SDK-download mirror. Only tencent is curated — it is the one live-verified mirror of the
# repository2 layout (mirrors.cloud.tencent.com/AndroidSDK/ → 200). tsinghua (TUNA), ustc and aliyun
# are intentionally absent: tsinghua declines to mirror the SDK for copyright reasons, ustc now only
# mirrors AOSP source, and the aliyun android.googlesource.com path is the git source — none host the
# repository2-*.xml binary index (selecting them would silently yield no packages). set-mirror still
# accepts any raw URL. Default = direct to dl.google.com. Each base ends with '/' (the
# SDK_TEST_BASE_URL contract). key -> mirror base.
declare -gA ANDROID_MIRROR_PRESET=(
  [default]="$ANDROID_REPO_BASE_DEFAULT"
  [tencent]="https://mirrors.cloud.tencent.com/AndroidSDK/"
)
readonly ANDROID_MIRROR_ORDER="default tencent"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as scripts/go.sh's GO_I18N / rime.sh's RIME_I18N, kept local. Proper nouns —
# sdkmanager, platform-tools, build-tools, emulator, ndk, cmake, scrcpy, system-images, ABI
# tokens, ANDROID_HOME, the mirror names — stay UNtranslated; only descriptive/operational
# wording is localized. Resolve with _android_t KEY (fallback en -> key, like ui_t).
declare -gA ANDROID_I18N
ANDROID_I18N[en:sec_components]="SDK components"
ANDROID_I18N[en:sec_actions]="Actions"
ANDROID_I18N[en:sec_settings]="Settings"
ANDROID_I18N[en:java_ok]="Java {V} — compatible (>=$ANDROID_JDK_MIN) ✓"
ANDROID_I18N[en:java_missing]="No compatible JDK (>=$ANDROID_JDK_MIN) — sdkmanager operations are blocked"
ANDROID_I18N[en:install_java]="Install Java $ANDROID_JDK_MIN (swkit java install)"
ANDROID_I18N[en:desc_platform-tools]="adb / fastboot (the device tools)"
ANDROID_I18N[en:desc_emulator]="the Android emulator (GUI / KVM)"
ANDROID_I18N[en:desc_scrcpy]="mirror/control an Android device (apt)"
ANDROID_I18N[en:add_package]="add a package by id…"
ANDROID_I18N[en:add_platform]="add a platform (android-NN)…"
ANDROID_I18N[en:mirror]="SDK download mirror"
ANDROID_I18N[en:env_path]="ANDROID_HOME + PATH on rc"
ANDROID_I18N[en:apply_recommended]="Apply recommended setup (platform + build-tools + emulator)"
ANDROID_I18N[en:accept_licenses]="Accept the SDK licenses"
ANDROID_I18N[en:install_baseline]="Install the baseline (cmdline-tools + platform-tools)"
ANDROID_I18N[en:purge]="Purge the whole SDK (~/Android/Sdk)"
ANDROID_I18N[en:confirm_remove]="Remove the kit-installed cmdline-tools + env block? (downloaded SDK data is KEPT)"
ANDROID_I18N[en:confirm_purge]="PURGE: delete the ENTIRE Android SDK at {DIR}? This cannot be undone."
ANDROID_I18N[en:prompt_package]="package id (e.g. ndk;27.0.12077973, system-images;android-35;google_apis;x86_64)"
ANDROID_I18N[en:prompt_platform]="platform API level (e.g. 35)"
ANDROID_I18N[en:foot_main]="↑↓ move   space add/remove   a add   ↵ select   esc/q close"
ANDROID_I18N[en:invalid_package]="Invalid package id (allowed: letters, digits . _ - and ; separators)."
ANDROID_I18N[en:invalid_platform]="Invalid platform API level (digits only, e.g. 35)."
ANDROID_I18N[en:invalid_mirror]="Invalid mirror URL (no shell metacharacters; must be http(s)://…/)."
ANDROID_I18N[en:mirror_trust]="Trust note: a non-default mirror becomes the source of the SDK binaries you run. Google's index is unsigned (SHA-1), so a mirror can swap a package AND its checksum — there is no independent trust anchor. Use a mirror you trust; switch back to direct (dl.google.com) on any doubt."
ANDROID_I18N[en:mirror_lag]="Mirrors can lag dl.google.com and often miss system-images; on failures switch to direct or use a proxy."
ANDROID_I18N[en:need_java]="No compatible JDK (>=$ANDROID_JDK_MIN). sdkmanager needs one — install it first: swkit java install"
ANDROID_I18N[en:ssh_note]="The emulator/system-images are desktop-GUI concerns — over SSH/headless these apply on a machine with a display + /dev/kvm."
ANDROID_I18N[en:no_kvm]="No usable /dev/kvm — the emulator falls back to the (slow) software path; on a server use a physical device or a remote/cloud emulator instead."
ANDROID_I18N[en:arm_warn]="This host is arm64; Google's Linux SDK binaries (adb/aapt2/emulator/NDK) are x86_64-only and will not run here (the JAR-based sdkmanager still works on a JVM)."
ANDROID_I18N[en:abi_default]="No ABI in the system-image id — defaulting to this host's ABI ({ABI}): {PKG}"
ANDROID_I18N[en:abi_mismatch]="The requested ABI ({REQ}) differs from this host's ABI ({HOST}) — that system image runs only under emulation (slow) and may not launch here."
ANDROID_I18N[en:prereq_chain]="Prerequisite chain before platform-tools: swkit java install → swkit android accept-licenses → swkit android install"
ANDROID_I18N[en:license_terms]="License terms: https://developer.android.com/studio/terms"
ANDROID_I18N[en:purge_studio_warn]="Note: ~/Android/Sdk is also Android Studio's default SDK — purging it removes the SDK shared with Android Studio too (your AVDs under ~/.android/avd are left untouched)."

ANDROID_I18N[zh:sec_components]="SDK 组件"
ANDROID_I18N[zh:sec_actions]="操作"
ANDROID_I18N[zh:sec_settings]="设置"
ANDROID_I18N[zh:java_ok]="Java {V} —— 兼容(>=$ANDROID_JDK_MIN)✓"
ANDROID_I18N[zh:java_missing]="无兼容 JDK(>=$ANDROID_JDK_MIN)—— sdkmanager 操作被阻断"
ANDROID_I18N[zh:install_java]="安装 Java $ANDROID_JDK_MIN(swkit java install)"
ANDROID_I18N[zh:desc_platform-tools]="adb / fastboot(设备工具)"
ANDROID_I18N[zh:desc_emulator]="Android 模拟器(GUI / KVM)"
ANDROID_I18N[zh:desc_scrcpy]="投屏/控制 Android 设备(apt)"
ANDROID_I18N[zh:add_package]="按 id 添加一个包…"
ANDROID_I18N[zh:add_platform]="添加一个平台(android-NN)…"
ANDROID_I18N[zh:mirror]="SDK 下载镜像"
ANDROID_I18N[zh:env_path]="ANDROID_HOME + PATH 写入 rc"
ANDROID_I18N[zh:apply_recommended]="应用推荐配置(platform + build-tools + emulator)"
ANDROID_I18N[zh:accept_licenses]="接受 SDK 许可"
ANDROID_I18N[zh:install_baseline]="安装基线(cmdline-tools + platform-tools)"
ANDROID_I18N[zh:purge]="清空整个 SDK(~/Android/Sdk)"
ANDROID_I18N[zh:confirm_remove]="移除 kit 安装的 cmdline-tools + env 块?(已下载的 SDK 数据保留)"
ANDROID_I18N[zh:confirm_purge]="清空:删除位于 {DIR} 的整个 Android SDK?此操作不可撤销。"
ANDROID_I18N[zh:prompt_package]="包 id(如 ndk;27.0.12077973、system-images;android-35;google_apis;x86_64)"
ANDROID_I18N[zh:prompt_platform]="平台 API 级别(如 35)"
ANDROID_I18N[zh:foot_main]="↑↓ 移动   space 增删   a 添加   ↵ 选择   esc/q 关闭"
ANDROID_I18N[zh:invalid_package]="非法的包 id(允许:字母、数字、. _ - 与 ; 分隔符)。"
ANDROID_I18N[zh:invalid_platform]="非法的平台 API 级别(只允许数字,如 35)。"
ANDROID_I18N[zh:invalid_mirror]="非法的镜像 URL(不得含 shell 元字符;须为 http(s)://…/)。"
ANDROID_I18N[zh:mirror_trust]="信任提示:非默认镜像将成为你所运行 SDK 二进制的来源。Google 索引无签名(SHA-1),镜像可同时替换包与校验值 —— 没有独立信任锚。请使用你信任的镜像;有任何疑虑请切回直连(dl.google.com)。"
ANDROID_I18N[zh:mirror_lag]="镜像可能滞后于 dl.google.com,且常缺 system-images;失败时切回直连或挂代理。"
ANDROID_I18N[zh:need_java]="无兼容 JDK(>=$ANDROID_JDK_MIN)。sdkmanager 需要它 —— 请先安装:swkit java install"
ANDROID_I18N[zh:ssh_note]="模拟器/system-images 属桌面 GUI 范畴 —— 经 SSH/无头时这些设置在有显示器 + /dev/kvm 的机器上生效。"
ANDROID_I18N[zh:no_kvm]="无可用的 /dev/kvm —— 模拟器退回(很慢的)软件路径;服务器上请改用真机或远程/云模拟器。"
ANDROID_I18N[zh:arm_warn]="本机为 arm64;Google 的 Linux SDK 二进制(adb/aapt2/emulator/NDK)仅 x86_64,无法在此运行(基于 JAR 的 sdkmanager 仍可在 JVM 上跑)。"
ANDROID_I18N[zh:abi_default]="system-image id 未含 ABI —— 默认采用本机 ABI({ABI}):{PKG}"
ANDROID_I18N[zh:abi_mismatch]="请求的 ABI({REQ})与本机 ABI({HOST})不同 —— 该系统镜像只能在模拟下运行(很慢),且可能无法在此启动。"
ANDROID_I18N[zh:prereq_chain]="装 platform-tools 前的前置链:swkit java install → swkit android accept-licenses → swkit android install"
ANDROID_I18N[zh:license_terms]="许可条款:https://developer.android.com/studio/terms"
ANDROID_I18N[zh:purge_studio_warn]="注意:~/Android/Sdk 也是 Android Studio 的默认 SDK —— 清空会一并删除与 Android Studio 共用的 SDK(~/.android/avd 下的 AVD 不动)。"

ANDROID_I18N[ja:sec_components]="SDK コンポーネント"
ANDROID_I18N[ja:sec_actions]="操作"
ANDROID_I18N[ja:sec_settings]="設定"
ANDROID_I18N[ja:java_ok]="Java {V} —— 互換(>=$ANDROID_JDK_MIN)✓"
ANDROID_I18N[ja:java_missing]="互換 JDK(>=$ANDROID_JDK_MIN)なし —— sdkmanager 操作はブロックされます"
ANDROID_I18N[ja:install_java]="Java $ANDROID_JDK_MIN をインストール(swkit java install)"
ANDROID_I18N[ja:desc_platform-tools]="adb / fastboot(デバイスツール)"
ANDROID_I18N[ja:desc_emulator]="Android エミュレータ(GUI / KVM)"
ANDROID_I18N[ja:desc_scrcpy]="Android デバイスのミラー/操作(apt)"
ANDROID_I18N[ja:add_package]="id でパッケージを追加…"
ANDROID_I18N[ja:add_platform]="プラットフォームを追加(android-NN)…"
ANDROID_I18N[ja:mirror]="SDK ダウンロードミラー"
ANDROID_I18N[ja:env_path]="ANDROID_HOME + PATH を rc に追加"
ANDROID_I18N[ja:apply_recommended]="推奨セットアップを適用(platform + build-tools + emulator)"
ANDROID_I18N[ja:accept_licenses]="SDK ライセンスに同意"
ANDROID_I18N[ja:install_baseline]="ベースラインをインストール(cmdline-tools + platform-tools)"
ANDROID_I18N[ja:purge]="SDK 全体を削除(~/Android/Sdk)"
ANDROID_I18N[ja:confirm_remove]="kit が入れた cmdline-tools + env ブロックを削除しますか?(DL 済み SDK データは保持)"
ANDROID_I18N[ja:confirm_purge]="パージ:{DIR} の Android SDK 全体を削除しますか?元に戻せません。"
ANDROID_I18N[ja:prompt_package]="パッケージ id(例: ndk;27.0.12077973、system-images;android-35;google_apis;x86_64)"
ANDROID_I18N[ja:prompt_platform]="プラットフォーム API レベル(例: 35)"
ANDROID_I18N[ja:foot_main]="↑↓ 移動   space 追加/削除   a 追加   ↵ 選択   esc/q 閉じる"
ANDROID_I18N[ja:invalid_package]="不正なパッケージ id(許可: 英数字・. _ - と ; 区切り)。"
ANDROID_I18N[ja:invalid_platform]="不正なプラットフォーム API レベル(数字のみ、例: 35)。"
ANDROID_I18N[ja:invalid_mirror]="不正なミラー URL(shell メタ文字不可; http(s)://…/ が必要)。"
ANDROID_I18N[ja:mirror_trust]="信頼に関する注意: 非デフォルトのミラーは実行する SDK バイナリの供給元になります。Google のインデックスは未署名(SHA-1)で、ミラーはパッケージとチェックサムを同時に差し替えられます —— 独立した信頼アンカーはありません。信頼できるミラーのみ使用し、疑わしければ直結(dl.google.com)へ。"
ANDROID_I18N[ja:mirror_lag]="ミラーは dl.google.com より遅れることがあり、system-images が欠けがちです; 失敗時は直結かプロキシを。"
ANDROID_I18N[ja:need_java]="互換 JDK(>=$ANDROID_JDK_MIN)なし。sdkmanager に必要です —— 先にインストール: swkit java install"
ANDROID_I18N[ja:ssh_note]="エミュレータ/system-images はデスクトップ GUI の領域 —— SSH/ヘッドレスではディスプレイ + /dev/kvm のあるマシンで有効になります。"
ANDROID_I18N[ja:no_kvm]="使える /dev/kvm がありません —— エミュレータは(遅い)ソフトウェア経路に退きます; サーバーでは実機か遠隔/クラウドのエミュレータを。"
ANDROID_I18N[ja:arm_warn]="このホストは arm64; Google の Linux SDK バイナリ(adb/aapt2/emulator/NDK)は x86_64 専用でここでは動きません(JAR ベースの sdkmanager は JVM 上で動作)。"
ANDROID_I18N[ja:abi_default]="system-image id に ABI がありません —— このホストの ABI({ABI})を既定にします:{PKG}"
ANDROID_I18N[ja:abi_mismatch]="要求された ABI({REQ})はこのホストの ABI({HOST})と異なります —— そのシステムイメージはエミュレーション(低速)でのみ動作し、ここでは起動しない場合があります。"
ANDROID_I18N[ja:prereq_chain]="platform-tools の前提チェーン: swkit java install → swkit android accept-licenses → swkit android install"
ANDROID_I18N[ja:license_terms]="ライセンス条項: https://developer.android.com/studio/terms"
ANDROID_I18N[ja:purge_studio_warn]="注意: ~/Android/Sdk は Android Studio の既定 SDK でもあります —— パージすると Android Studio と共有する SDK も削除されます(~/.android/avd の AVD はそのまま)。"

# _android_t KEY — localized string for $UI_LANG (en/zh/ja), fallback en -> key.
_android_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${ANDROID_I18N[$lang:$1]:-${ANDROID_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=android
name=Android SDK
category=runtime
ops=install,remove,configure,accept-licenses,purge
desc=Headless Android SDK toolchain — cmdline-tools + sdkmanager (platform-tools/platforms/build-tools/emulator/NDK); needs a JDK >=17 (swkit java)
META
}

# --- User-space guard, real home & paths ---------------------------------------
# Refuse a sudo-wrapped run: the whole SDK lives under the user's HOME and must stay user-owned
# (apt curl/unzip steps escalate per-command on their own via sudo_run). Mirrors _go_user_guard.
_android_user_guard() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run Android SDK management as your normal user, not via sudo — the SDK and your"
    log_err "shell rc live under your HOME and must stay user-owned (the curl/unzip apt steps"
    log_err "escalate per-command on their own)."
    return 1
  fi
}

# Resolve the real user's home (honors SUDO_USER; never trusts root's ~/$HOME). Echoes the path.
_android_real_home() {
  local home="${HOME:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)"
  fi
  [[ -n "$home" ]] || home="$(getent passwd "$(id -un)" | cut -d: -f6 2>/dev/null || true)"
  printf '%s' "$home"
}

# $ANDROID_HOME (default ~/Android/Sdk, aligned with Android Studio). Always resolved explicitly
# from the real home — never relies on an inherited ANDROID_HOME (which a sudo wrapper would taint).
_android_home() {
  local home; home="$(_android_real_home)"
  printf '%s/Android/Sdk' "$home"
}

# The user's shell rc file (honors SUDO_USER's real home; never edits another user's dotfile).
_android_rc_file() {
  local home shell="${SHELL:-}"
  home="$(_android_real_home)"
  [[ -n "$home" ]] || home="${HOME:-}"
  case "$shell" in */zsh) printf '%s/.zshrc' "$home" ;; *) printf '%s/.bashrc' "$home" ;; esac
}

# Path to the sdkmanager that we extract under cmdline-tools/latest/.
_android_sdkmanager_bin() { printf '%s/cmdline-tools/latest/bin/sdkmanager' "$(_android_home)"; }

# True when the SDK licenses are already accepted: sdkmanager writes a hash file per accepted license
# under $ANDROID_HOME/licenses/. Pure fs (zero JVM); a non-empty licenses/ dir means install can
# proceed without re-prompting (re-run idempotency).
_android_licenses_accepted() {
  local licdir; licdir="$(_android_home)/licenses"
  [[ -d "$licdir" ]] && [[ -n "$(find "$licdir" -mindepth 1 -maxdepth 1 -type f -print -quit 2>/dev/null)" ]]
}

# Assert $1 is a deletion-safe path under the real user's HOME — the FULL guard set shared by both
# do_remove (before its rm of cmdline-tools/latest) and do_purge (before its rm of the whole SDK):
# non-empty; the original is not a symlink (rm wouldn't follow it, but a symlinked parent like
# ~/Android -> /mnt/data/Android would let realpath escape); canonicalize with realpath -m; absolute;
# != / ; != the real $HOME ; strictly UNDER the real $HOME. Exit 0 when safe, non-zero (with a log)
# otherwise. Callers still keep the ${VAR:?} belt-and-suspenders on the rm itself.
_android_path_safe_under_home() {
  local path="$1" real_home target
  real_home="$(_android_real_home)"
  [[ -n "$path" ]] || { log_err "Refusing to delete an empty path."; return 1; }
  [[ -n "$real_home" ]] || { log_err "Could not resolve your home directory — refusing to delete."; return 1; }
  # Reject a symlinked path (rm -rf would not follow it, but realpath could escape elsewhere).
  if [[ -L "$path" ]]; then
    log_err "Refusing to delete: $path is a symlink. Inspect and remove it manually if intended."
    return 1
  fi
  target="$(realpath -m "$path" 2>/dev/null || true)"
  [[ -n "$target" ]] || { log_err "Refusing to delete: could not canonicalize $path."; return 1; }
  case "$target" in
    /) log_err "Refusing to delete '/' — aborting."; return 1 ;;
    /*) ;;
    *) log_err "Refusing to delete a non-absolute path: $target"; return 1 ;;
  esac
  [[ "$target" == "$real_home" ]] && { log_err "Refusing to delete your home directory itself ($real_home)."; return 1; }
  case "$target" in
    "$real_home"/*) ;;   # must live strictly under the real home
    *) log_err "Refusing to delete a path outside your home ($real_home): $target"; return 1 ;;
  esac
}

# --- Environment / arch probes (best-effort; honest disclosure) ----------------

# dpkg architecture -> the matching emulator/system-image ABI token.
_android_arch() {
  local a; a="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$a" in
    amd64) printf 'x86_64' ;;
    arm64) printf 'arm64-v8a' ;;
    *)     printf '%s' "${a:-x86_64}" ;;
  esac
}

# True on an arm64 host (Google's native Linux SDK binaries are x86_64-only there).
_android_is_arm() { [[ "$(dpkg --print-architecture 2>/dev/null || true)" == arm64 ]]; }

# True in an SSH session (no local graphical display to run the emulator on).
_android_in_ssh() { [[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]; }

# True when there is NO local graphical session to run the emulator on: an SSH session OR no display
# at all (both DISPLAY and WAYLAND_DISPLAY empty). Mirrors rime.sh's _rime_no_display idiom — the
# emulator is a GUI component, so a missing display (not just SSH) is also headless.
_android_headless() {
  _android_in_ssh && return 0
  [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]
}

# True when there is NO usable /dev/kvm (emulator hardware acceleration unavailable).
_android_no_kvm() { [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; }

# Honest disclosure woven through install / emulator selection / status. These ALWAYS return 0
# (a trailing `cond && log_warn` that is false would otherwise return 1 and, called unguarded under
# `set -e`, abort the caller — the classic errexit-on-&&-false trap).
_android_emulator_notes() {
  # Headless (SSH or no DISPLAY/WAYLAND_DISPLAY) — these GUI/KVM settings apply on a machine with a
  # display + /dev/kvm, not here (design §B: 无 DISPLAY/dev/kvm).
  _android_headless && log_warn "$(_android_t ssh_note)"
  _android_no_kvm && log_warn "$(_android_t no_kvm)"
  return 0
}
_android_arch_note() { _android_is_arm && log_warn "$(_android_t arm_warn)"; return 0; }

# --- Validation (block shell-injection before any string is interpolated) -------
# A safe sdkmanager package id: letters/digits/. _ - grouped by ';' (the SDK's own grammar).
# sdkmanager receives an argv array (no shell), so this is hygiene/consistency + a clean error.
_android_valid_pkg() { [[ "$1" =~ ^[A-Za-z0-9._-]+(\;[A-Za-z0-9._-]+)*$ ]]; }
# A platform API level: digits only (we wrap it as platforms;android-<N>).
_android_valid_platform() { [[ "$1" =~ ^[0-9]+$ ]]; }

# A safe mirror base URL. We persist it in a SOURCED shell rc line AND interpolate it into curl URLs
# (the bootstrap zip / manifest), so reject anything shell-significant or whitespace and require a
# plain http(s) base ending in '/' (the SDK_TEST_BASE_URL contract). A double quote / backtick / $ /
# backslash / newline would break out of the "…" rc assignment and inject a command at every login;
# a ';' / space / control char is meaningless in a URL base and shell-significant when the value is
# ever used unquoted — so we constrain to a strict URL charset, not just a metacharacter blocklist.
# Mirrors python.sh's set-index validator (tightened to a positive charset).
_android_valid_mirror() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  # Positive charset: an http(s) base over the unreserved/sub-delim/path URL characters only,
  # ending in '/'. No spaces, ';', quotes, backticks, '$', backslash, '<>|&', control chars, etc.
  [[ "$url" =~ ^https?://[A-Za-z0-9._~:/?#@!*+,=%()-]+/$ ]]
}

# --- Mirror base (preset / persisted rc line) ----------------------------------
# Read the persisted SDK mirror base from the managed rc line, falling back to direct. We parse
# our own marked line (grep, never source — the rc is user-writable). Echoes the base (ends in '/').
_android_mirror_base() {
  local rc line base; rc="$(_android_rc_file)"
  if [[ -f "$rc" ]]; then
    line="$(grep -F "$ANDROID_MIRROR_MARKER" "$rc" 2>/dev/null | tail -n1 || true)"
    if [[ -n "$line" ]]; then
      # line shape: export SDK_TEST_BASE_URL="<base>" # marker
      base="${line#*SDK_TEST_BASE_URL=\"}"; base="${base%%\"*}"
      # Fail CLOSED: a marked-but-malformed line (e.g. no well-formed assignment) leaves $base as the
      # whole comment, which the non-empty check would wrongly accept — validate it as a real mirror
      # base and only then return it; otherwise fall through to the direct default.
      _android_valid_mirror "$base" && { printf '%s' "$base"; return 0; }
    fi
  fi
  printf '%s' "$ANDROID_REPO_BASE_DEFAULT"
}

# Installed OpenJDK major versions (one per line, DESCENDING), discovered the same UNBOUNDED way
# java.sh's _java_installed_versions does — a dpkg glob of openjdk-*-jdk* — so the gate and the
# status banner survive future releases without a hard-coded ceiling (matches java.sh's discovery).
# Zero JVM. Empty output when none are installed.
_android_installed_jdk_majors() {
  dpkg-query -W -f '${Package} ${Status}\n' 'openjdk-*-jdk*' 2>/dev/null \
    | awk '$NF=="installed" && $2=="install"' \
    | sed -n 's/^openjdk-\([0-9][0-9]*\)-jdk\(-headless\)\? .*/\1/p' \
    | sort -rn -u
}

# --- Java gate (the one-way android -> java edge) ------------------------------
# Resolve a JDK home (>=$ANDROID_JDK_MIN) WITHOUT spawning a JVM and WITHOUT changing the global
# default, setting _ANDROID_JAVA_HOME for the sdkmanager wrapper to prefix. Strategy (design C):
#   1. default JDK (parsed from `java.sh home`, ZERO JVM) is >=MIN  -> use it (no JAVA_HOME prefix).
#   2. else some installed openjdk-<N> (N>=MIN) exists              -> JAVA_HOME=$(java.sh home N),
#      process-local; the home result MUST be non-empty before use (export VAR=$(fail) does NOT
#      abort under errexit — it silently yields ""), so we check it explicitly.
#   3. else                                                        -> point at `swkit java install`,
#      return non-zero, NEVER auto-install.
# Called before EVERY sdkmanager JVM spawn (install, --uninstall, add/remove package/platform,
# accept-licenses, AND --recommended's `sdkmanager --list`) — so the kit's clean guidance beats
# sdkmanager's raw die. status() NEVER calls this (keeps the catalog probe JVM-free).
_android_java_gate() {
  _ANDROID_JAVA_HOME=""
  local java_sh="$KIT_SCRIPTS_DIR/java.sh"
  [[ -x "$java_sh" || -f "$java_sh" ]] || { log_err "$(_android_t need_java)"; return 1; }

  # 1. Default JDK home -> parse its major version from the path (java-<N>-openjdk). Zero JVM.
  local def_home def_major=""
  if def_home="$(bash "$java_sh" home 2>/dev/null)" && [[ -n "$def_home" ]]; then
    def_major="$(printf '%s' "$def_home" | sed -n 's#.*/java-\([0-9][0-9]*\)-openjdk.*#\1#p')"
    if [[ -n "$def_major" ]] && (( def_major >= ANDROID_JDK_MIN )); then
      # Pin the resolved compatible home as the process-local prefix (parallel to step 2). The
      # sdkmanager launcher prefers $JAVA_HOME over PATH, so an incompatible inherited
      # `export JAVA_HOME=<jdk11>` from the user shell would otherwise silently override the
      # alternatives default — always pin so the wrapper wins.
      _ANDROID_JAVA_HOME="$def_home"
      return 0
    fi
  fi

  # 2. Any other installed JDK >=MIN? Discover candidate majors the SAME way java.sh does — an
  #    UNBOUNDED dpkg glob (zero JVM), descending — so a newer-than-LTS sidecar (e.g. a future
  #    openjdk-26 that is not the default) is found without a hard-coded ceiling. Resolve each home
  #    via `java.sh home <N>` (fs-derived) and use the first non-empty one.
  local n home
  for n in $(_android_installed_jdk_majors); do
    (( n >= ANDROID_JDK_MIN )) || continue
    home="$(bash "$java_sh" home "$n" 2>/dev/null || true)"
    if [[ -n "$home" ]]; then
      _ANDROID_JAVA_HOME="$home"   # process-local prefix for sdkmanager; never the global default
      return 0
    fi
  done

  # 3. No compatible JDK at all — point the way, never auto-install (matches the node gate).
  log_err "$(_android_t need_java)"
  return 1
}

# sdkmanager wrapper: gate -> run sdkmanager with a process-local JAVA_HOME (when needed) and the
# SDK download root (SDK_TEST_BASE_URL = the persisted mirror base; defaults to dl.google.com).
# All sdkmanager spawns go through here so the gate is never bypassed.
_android_sdkmanager() {
  _android_java_gate || return 1
  local sm; sm="$(_android_sdkmanager_bin)"
  [[ -x "$sm" ]] || { log_err "sdkmanager is not installed yet — run: ${0##*/} install"; return 1; }
  local home; home="$(_android_home)"
  local base; base="$(_android_mirror_base)"
  # ANDROID_USER_HOME keeps adb/avd metadata under the user; ANDROID_HOME/SDK_ROOT point sdkmanager
  # at the SDK; SDK_TEST_BASE_URL rewrites the download root (the mirror, or dl.google.com default).
  if [[ -n "${_ANDROID_JAVA_HOME:-}" ]]; then
    JAVA_HOME="$_ANDROID_JAVA_HOME" ANDROID_HOME="$home" ANDROID_SDK_ROOT="$home" \
      SDK_TEST_BASE_URL="$base" "$sm" --sdk_root="$home" "$@"
  else
    ANDROID_HOME="$home" ANDROID_SDK_ROOT="$home" \
      SDK_TEST_BASE_URL="$base" "$sm" --sdk_root="$home" "$@"
  fi
}

# --- status (read-only; pure fs; ZERO JVM; NEVER calls the gate) ---------------
# Exit 0 iff cmdline-tools are present (the sdkmanager binary exists). KIT_PROBE_ONLY early-returns
# the boolean; otherwise append component counts + a Java-compat banner. The banner is computed
# ONLY from read-only signals (java.sh home / pkg_installed) — never `java -version` — so the probe
# and full paths spawn ZERO JVM and return the SAME exit code.
status() {
  local sm; sm="$(_android_sdkmanager_bin)"
  [[ -x "$sm" ]] || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0   # catalog probe: boolean only, skip the scan below

  # arm64 honesty disclosure (design §B: status AND install). Logs to stderr (log_warn), so the
  # single parsed stdout line below is unchanged and the probe path stays silent (early-returned above).
  _android_arch_note

  local home; home="$(_android_home)"
  # Component counts (pure fs scan — zero JVM). Each is the count of installed entries under its dir.
  local pt=0 plat=0 bt=0 emu=0 si=0 ndk=0 cmk=0 lic=0
  [[ -x "$home/platform-tools/adb" ]] && pt=1
  [[ -d "$home/platforms" ]]    && plat="$(find "$home/platforms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
  [[ -d "$home/build-tools" ]]  && bt="$(find "$home/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
  [[ -d "$home/emulator" ]]     && emu=1
  [[ -d "$home/system-images" ]] && si="$(find "$home/system-images" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | grep -c . || true)"
  [[ -d "$home/ndk" ]]          && ndk="$(find "$home/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
  [[ -d "$home/cmake" ]]        && cmk="$(find "$home/cmake" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
  [[ -d "$home/licenses" ]]     && lic="$(find "$home/licenses" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | grep -c . || true)"

  # Java-compat banner from read-only signals only (zero JVM). _android_java_compat sets _AJC_*.
  local jbanner
  if _android_java_compat; then
    if [[ -n "$_AJC_VERSION" ]]; then jbanner="java>=$ANDROID_JDK_MIN($_AJC_VERSION)"; else jbanner="java>=$ANDROID_JDK_MIN"; fi
  else
    jbanner="java<$ANDROID_JDK_MIN!"
  fi

  printf 'cmdline-tools · platform-tools %s · platforms %s · build-tools %s · emulator %s · system-images %s · ndk %s · cmake %s · licenses %s · %s\n' \
    "$pt" "$plat" "$bt" "$emu" "$si" "$ndk" "$cmk" "$lic" "$jbanner"
}

# Read-only Java compatibility probe for the status banner (NEVER spawns a JVM, NEVER calls the
# gate). Sets _AJC_VERSION to the chosen major version. Exit 0 iff a JDK >=MIN is available:
# default JDK (parsed from java.sh home) is >=MIN, OR some installed openjdk-<N> with N>=MIN exists.
_android_java_compat() {
  _AJC_VERSION=""
  local java_sh="$KIT_SCRIPTS_DIR/java.sh" def_home def_major n
  if [[ -f "$java_sh" ]]; then
    if def_home="$(bash "$java_sh" home 2>/dev/null)" && [[ -n "$def_home" ]]; then
      def_major="$(printf '%s' "$def_home" | sed -n 's#.*/java-\([0-9][0-9]*\)-openjdk.*#\1#p')"
      if [[ -n "$def_major" ]] && (( def_major >= ANDROID_JDK_MIN )); then _AJC_VERSION="$def_major"; return 0; fi
    fi
  fi
  for n in $(_android_installed_jdk_majors); do
    (( n >= ANDROID_JDK_MIN )) || continue
    _AJC_VERSION="$n"; return 0
  done
  return 1
}

# --- cmdline-tools bootstrap: resolve + download + VERIFY + extract -------------

# Resolve the latest stable command-line-tools linux archive from the repository2 manifest.
# Sets _ANDROID_CLT_URL (absolute), _ANDROID_CLT_SHA1 (bare 40-hex), _ANDROID_CLT_SIZE (bytes).
# BLOCK-SCOPED awk: <url> is RELATIVE, <checksum> is a BARE SHA-1, <size>/<checksum>/<url> live in
# the SAME <complete> block, and the manifest lists multiple revisions + linux/mac/win back-to-back
# — so we scope to ONE <archive>, accept it only when its sibling <host-os> is linux, and take the
# FIRST stable (non -alpha/-beta/-rc/-dev) cmdline-tools package (highest revision, listed first).
# NOT three independent grep|head -1. Tries repository2-3/-2/-1.xml (schema variants) until one parses.
_android_resolve_cmdline_zip() {
  local base; base="$(_android_mirror_base)"
  local tmp fields rel
  tmp="$(mktemp)"
  local m got=0
  for m in "$ANDROID_REPO_MANIFEST" repository2-2.xml repository2-1.xml; do
    if curl -fsSL "${base}${m}" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then got=1; break; fi
  done
  if (( ! got )); then
    # Mirror may not host the manifest at this base — fall back to the direct manifest, but the zip
    # itself is still fetched from <base> (the mirror) by the caller.
    for m in "$ANDROID_REPO_MANIFEST" repository2-2.xml repository2-1.xml; do
      if curl -fsSL "${ANDROID_REPO_BASE_DEFAULT}${m}" -o "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then got=1; break; fi
    done
  fi
  (( got )) || { rm -f "$tmp"; log_err "Could not download the Android SDK manifest (repository2-*.xml)."; return 1; }

  fields="$(awk '
    committed==0 && /<remotePackage path="cmdline-tools;/ {
      line=$0
      if (match(line, /path="cmdline-tools;[^"]*"/)) {
        p=substr(line, RSTART, RLENGTH); gsub(/path="/,"",p); gsub(/"$/,"",p)
        if (p !~ /-(alpha|beta|rc|dev)/) { committed=1; inpkg=1 }
      }
      next
    }
    inpkg && /<archive>/ { in_arch=1; a_size=""; a_sum=""; a_url=""; a_os=""; next }
    inpkg && in_arch {
      if ($0 ~ /<size>/)     { s=$0; sub(/.*<size>/,"",s); sub(/<\/size>.*/,"",s); a_size=s }
      if ($0 ~ /<checksum/)  { s=$0; sub(/.*<checksum[^>]*>/,"",s); sub(/<\/checksum>.*/,"",s); a_sum=s }
      if ($0 ~ /<url>/)      { s=$0; sub(/.*<url>/,"",s); sub(/<\/url>.*/,"",s); a_url=s }
      if ($0 ~ /<host-os>/)  { s=$0; sub(/.*<host-os>/,"",s); sub(/<\/host-os>.*/,"",s); a_os=s }
      if ($0 ~ /<\/archive>/) {
        in_arch=0
        if (a_os=="linux" && a_url!="" && a_sum!="" && a_size!="") { print a_size"\t"a_sum"\t"a_url; exit }
      }
    }
  ' "$tmp")"
  rm -f "$tmp"

  [[ -n "$fields" ]] || { log_err "Could not parse the linux command-line-tools archive from the manifest."; return 1; }
  _ANDROID_CLT_SIZE="$(printf '%s' "$fields" | cut -f1)"
  _ANDROID_CLT_SHA1="$(printf '%s' "$fields" | cut -f2)"
  rel="$(printf '%s' "$fields" | cut -f3)"
  # <url> is relative — prefix the repository base. Expose the relative path too so the caller can
  # build a direct (dl.google.com) fallback URL when a mirror's zip 404s (design §B: 404 回退直连).
  _ANDROID_CLT_REL="$rel"
  _ANDROID_CLT_URL="${base}${rel}"
  # Sanity-check the parsed pieces (a 40-hex SHA-1, an integer size, a .zip url).
  [[ "$_ANDROID_CLT_SHA1" =~ ^[0-9a-fA-F]{40}$ ]] || { log_err "Unexpected checksum from the manifest (expected a 40-hex SHA-1): $_ANDROID_CLT_SHA1"; return 1; }
  [[ "$_ANDROID_CLT_SIZE" =~ ^[0-9]+$ ]]          || { log_err "Unexpected archive size from the manifest: $_ANDROID_CLT_SIZE"; return 1; }
  case "$rel" in *.zip) ;; *) log_err "Unexpected archive name from the manifest: $rel"; return 1 ;; esac
  return 0
}

# Verify a downloaded zip against the manifest: compare <size> first, then sha1sum vs <checksum>.
# The cmdline-tools zip is extracted = executed with NO dpkg gate (unlike a .deb via apt_install,
# which dpkg verifies), so this integrity check is the trust boundary. A mismatch deletes the temp
# file and aborts. (Future-proof: if a 64-hex checksum ever appears, switch to sha256sum by length.)
_android_verify_zip() {
  local zip="$1" want_size="$2" want_sum="$3" got_size got_sum
  [[ -f "$zip" ]] || { log_err "Downloaded archive is missing: $zip"; return 1; }
  got_size="$(stat -c %s "$zip" 2>/dev/null || wc -c <"$zip")"
  if [[ "$got_size" != "$want_size" ]]; then
    log_err "Archive size mismatch (got $got_size, expected $want_size) — refusing to extract."
    rm -f "$zip"; return 1
  fi
  if [[ "${#want_sum}" -eq 40 ]]; then
    got_sum="$(sha1sum "$zip" 2>/dev/null | awk '{print $1}')"
  else
    got_sum="$(sha256sum "$zip" 2>/dev/null | awk '{print $1}')"
  fi
  # Case-insensitive hex compare.
  if [[ "${got_sum,,}" != "${want_sum,,}" ]]; then
    log_err "Archive checksum mismatch — refusing to extract (possible tampering or a corrupt download)."
    log_err "  expected: $want_sum"
    log_err "  got:      $got_sum"
    rm -f "$zip"; return 1
  fi
  log_info "Verified the command-line-tools archive (size + SHA-1)."
}

# Download + verify + extract cmdline-tools into $ANDROID_HOME/cmdline-tools/latest/ (no Java needed).
# The zip extracts to a top-level cmdline-tools/ dir; we relocate it to cmdline-tools/latest/ (the
# layout sdkmanager requires). Idempotent: skip if the sdkmanager binary already exists.
_android_install_cmdline_tools() {
  local home sm; home="$(_android_home)"; sm="$(_android_sdkmanager_bin)"
  if [[ -x "$sm" ]]; then
    log_info "cmdline-tools already present ($sm) — skipping the bootstrap download."
    return 0
  fi
  _android_resolve_cmdline_zip || return 1
  # When a non-default mirror is in effect it becomes the source of the vendor zip we extract+run —
  # re-emit the trust disclosure at the actual download moment (not just at set-mirror time), so a
  # user who set a mirror weeks ago is reminded that unsigned vendor code is about to be fetched+run.
  local base; base="$(_android_mirror_base)"
  if [[ "$base" != "$ANDROID_REPO_BASE_DEFAULT" ]]; then
    log_warn "$(_android_t mirror_trust)"
  fi
  log_info "Downloading command-line-tools: $_ANDROID_CLT_URL"
  local tmpdir zip; tmpdir="$(mktemp -d)"; zip="$tmpdir/cmdline-tools.zip"
  if ! curl -fSL "$_ANDROID_CLT_URL" -o "$zip"; then
    # Mirror zip 404/failure: fall back to the direct dl.google.com URL (design §B: 404 回退直连).
    # The relative path + SHA-1/size come from the manifest, so integrity verification still applies.
    if [[ "$base" != "$ANDROID_REPO_BASE_DEFAULT" && -n "${_ANDROID_CLT_REL:-}" ]]; then
      log_warn "Mirror download failed — falling back to direct: ${ANDROID_REPO_BASE_DEFAULT}${_ANDROID_CLT_REL}"
      rm -f "$zip"
      if ! curl -fSL "${ANDROID_REPO_BASE_DEFAULT}${_ANDROID_CLT_REL}" -o "$zip"; then
        rm -rf "$tmpdir"; log_err "Failed to download the command-line-tools archive (mirror and direct)."; return 1
      fi
    else
      rm -rf "$tmpdir"; log_err "Failed to download the command-line-tools archive."; return 1
    fi
  fi
  _android_verify_zip "$zip" "$_ANDROID_CLT_SIZE" "$_ANDROID_CLT_SHA1" || { rm -rf "$tmpdir"; return 1; }

  # Extract, then relocate the top-level cmdline-tools/ to cmdline-tools/latest/.
  if ! unzip -q "$zip" -d "$tmpdir/x"; then
    rm -rf "$tmpdir"; log_err "Failed to extract the command-line-tools archive."; return 1
  fi
  [[ -d "$tmpdir/x/cmdline-tools" ]] || { rm -rf "$tmpdir"; log_err "Unexpected archive layout (no top-level cmdline-tools/)."; return 1; }
  mkdir -p "$home/cmdline-tools"
  rm -rf "${home:?}/cmdline-tools/latest"
  mv "$tmpdir/x/cmdline-tools" "$home/cmdline-tools/latest" || { rm -rf "$tmpdir"; log_err "Could not place cmdline-tools/latest."; return 1; }
  rm -rf "$tmpdir"
  [[ -x "$sm" ]] || { log_err "sdkmanager not found after extraction — the archive layout may have changed."; return 1; }
  log_info "Installed command-line-tools to $home/cmdline-tools/latest."
}

# --- Managed env block on the shell rc -----------------------------------------
# Emit the managed env block (markers included) to stdout. ANDROID_HOME is the CURRENT spec var;
# ANDROID_SDK_ROOT is the DEPRECATED-but-still-honored alias (commented so a future cleanup keeps
# ANDROID_HOME). PATH gets cmdline-tools/latest/bin, platform-tools and emulator.
_android_emit_block() {
  local home; home="$(_android_home)"
  printf '%s\n' "$ANDROID_BLOCK_BEGIN"
  printf '# Android SDK environment (managed by ubuntu-setup: swkit android). Do not edit by hand.\n'
  # ANDROID_HOME is the current, canonical variable — keep it.
  printf 'export ANDROID_HOME="%s"\n' "$home"
  # ANDROID_SDK_ROOT is DEPRECATED but still honored by older tools; an alias of ANDROID_HOME.
  # (Do NOT delete ANDROID_HOME above thinking this replaces it — this is the legacy alias.)
  # shellcheck disable=SC2016
  printf 'export ANDROID_SDK_ROOT="$ANDROID_HOME"\n'
  # shellcheck disable=SC2016
  printf 'export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"\n'
  printf '%s\n' "$ANDROID_BLOCK_END"
}

# Add ($1=on, default) or remove ($1=off) the managed env block in the shell rc. 'on' regenerates
# the block (so it follows a changed ANDROID_HOME), backing up first; everything outside the markers
# is preserved (tmux.sh paradigm). The mirror line (a separate marked line) is left untouched here.
do_ensure_path() {
  _android_user_guard || return 1
  local mode="${1:-on}" rc tmp; rc="$(_android_rc_file)"
  case "$mode" in
    on)
      local newblock; newblock="$(_android_emit_block)"
      # Already present and identical? Nothing to do (idempotent).
      if [[ -f "$rc" ]] && grep -qxF "$ANDROID_BLOCK_BEGIN" "$rc"; then
        local cur; cur="$(awk -v b="$ANDROID_BLOCK_BEGIN" -v e="$ANDROID_BLOCK_END" \
          '$0==b{inblk=1} inblk{print} $0==e{inblk=0}' "$rc")"
        [[ "$cur" == "$newblock" ]] && { log_info "ANDROID_HOME env block already current in $rc — nothing to do."; return 0; }
      fi
      [[ -s "$rc" ]] && backup_file "$rc"
      tmp="$(mktemp)"
      # Strip any existing block, then append the fresh one at the end.
      if [[ -f "$rc" ]]; then
        awk -v b="$ANDROID_BLOCK_BEGIN" -v e="$ANDROID_BLOCK_END" \
          '$0==b{inblk=1} inblk==0{print} $0==e{inblk=0}' "$rc" >"$tmp"
      fi
      printf '%s\n' "$newblock" >>"$tmp"
      mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
      log_info "Wrote the ANDROID_HOME env block to $rc — open a new shell or 'source $rc'."
      ;;
    off)
      if [[ ! -f "$rc" ]] || ! grep -qxF "$ANDROID_BLOCK_BEGIN" "$rc"; then
        log_info "No managed Android env block in $rc — nothing to remove."
        return 0
      fi
      backup_file "$rc"
      tmp="$(mktemp)"
      awk -v b="$ANDROID_BLOCK_BEGIN" -v e="$ANDROID_BLOCK_END" \
        '$0==b{inblk=1} inblk==0{print} $0==e{inblk=0}' "$rc" >"$tmp"
      mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
      log_info "Removed the managed Android env block from $rc."
      ;;
    *) log_err "ensure-path takes on|off."; return 2 ;;
  esac
}

# --- install / remove / purge --------------------------------------------------

# install (no-arg) = the baseline: ensure curl/unzip -> bootstrap cmdline-tools (download + VERIFY
# + extract; NO Java needed) -> Java gate -> sdkmanager installs platform-tools. Licenses are NOT
# implicit: only `--accept-licenses` accepts them. On a machine with no JDK, steps 1–3 still succeed
# and status shows tools-present/Java-missing; the gate then points cleanly at `swkit java install`.
do_install() {
  _android_user_guard || return 1
  local accept=0 a
  for a in "$@"; do
    case "$a" in
      --accept-licenses) accept=1 ;;
      *) log_err "Unknown install option: $a"; usage; return 2 ;;
    esac
  done

  # 1. Prerequisites for the bootstrap download (these are the only sudo steps in install).
  have_cmd curl  || apt_install curl ca-certificates
  have_cmd unzip || apt_install unzip

  # 2-3. Bootstrap cmdline-tools (no Java needed). Lands sdkmanager even on a JDK-less machine.
  _android_install_cmdline_tools || return 1
  do_ensure_path on || log_warn "Could not write the ANDROID_HOME env block."
  _android_arch_note

  # 4-5. From here every step spawns a JVM (sdkmanager) and so passes the Java gate. If no
  #      compatible JDK exists, lay down the tools, print the full prerequisite chain, and stop
  #      cleanly (tools are present; status will show Java-missing).
  if ! _android_java_gate; then
    log_warn "$(_android_t prereq_chain)"
    log_info "cmdline-tools are installed. Once a JDK >=$ANDROID_JDK_MIN is present, re-run: ${0##*/} install"
    return 0
  fi

  # Licenses (explicit only). sdkmanager refuses to install packages until they are accepted, so we
  # never silently spawn platform-tools without acceptance: accept when --accept-licenses was passed,
  # otherwise proceed only if licenses are ALREADY accepted (re-run idempotency); if neither holds,
  # lay down cmdline-tools, print the full prerequisite chain, and STOP cleanly (design §B / prd R4).
  if (( accept )); then
    do_accept_licenses || return 1
  elif ! _android_licenses_accepted; then
    log_warn "Licenses are NOT accepted yet — platform-tools is NOT installed."
    log_warn "$(_android_t prereq_chain)"
    log_info "Accept them with: ${0##*/} accept-licenses   (or re-run: ${0##*/} install --accept-licenses)"
    log_info "$(_android_t license_terms)"
    return 0
  fi

  log_info "Installing platform-tools (adb / fastboot)…"
  _android_sdkmanager "platform-tools" || {
    log_err "platform-tools install failed. If it stopped on licenses, run: ${0##*/} accept-licenses"
    return 1
  }
  log_info "Android SDK baseline ready (cmdline-tools + platform-tools). Add more with:"
  log_info "    ${0##*/} add-platform 35   ·   ${0##*/} add-package \"build-tools;35.0.0\"   ·   swkit android"
  _android_emulator_notes
}

# accept-licenses — accept all SDK licenses non-interactively (yes | sdkmanager --licenses), with a
# prominent disclosure + the terms URL, then echo the accepted license ids (the files sdkmanager
# writes under $ANDROID_HOME/licenses/). Spawns a JVM, so it passes the Java gate first.
do_accept_licenses() {
  _android_user_guard || return 1
  local sm; sm="$(_android_sdkmanager_bin)"
  [[ -x "$sm" ]] || { log_err "cmdline-tools are not installed yet — run: ${0##*/} install"; return 1; }
  log_warn "You are about to ACCEPT all Android SDK licenses non-interactively."
  log_info "$(_android_t license_terms)"
  _android_java_gate || return 1
  log_info "Accepting SDK licenses (yes | sdkmanager --licenses)…"
  yes | _android_sdkmanager --licenses || true   # `yes` closing the pipe makes sdkmanager exit non-zero
  # Echo the accepted license ids (the hash files sdkmanager just wrote).
  local home licdir; home="$(_android_home)"; licdir="$home/licenses"
  if [[ -d "$licdir" ]]; then
    local f ids=""
    for f in "$licdir"/*; do [[ -e "$f" ]] && ids="${ids:+$ids }${f##*/}"; done
    [[ -n "$ids" ]] && log_info "Accepted licenses: $ids"
  fi
}

# remove (conservative, like rime.sh): delete the env block + the kit-installed cmdline-tools, but
# KEEP downloaded SDK data (platforms/build-tools/etc. may be shared with Android Studio). Prints
# the full-delete guidance (purge).
do_remove() {
  _android_user_guard || return 1
  local home sm; home="$(_android_home)"; sm="$(_android_sdkmanager_bin)"
  # Same FULL hardening as purge before any rm: a symlinked parent (~/Android -> /mnt/data/Android)
  # would otherwise let rm escape HOME despite the ${home:?} belt-and-suspenders kept below.
  _android_path_safe_under_home "$home/cmdline-tools/latest" || return 1
  if [[ ! -x "$sm" ]] && { [[ ! -f "$(_android_rc_file)" ]] || ! grep -qxF "$ANDROID_BLOCK_BEGIN" "$(_android_rc_file)"; }; then
    log_info "Nothing kit-managed to remove (no cmdline-tools, no env block)."
    return 0
  fi
  do_ensure_path off || true
  _android_clear_mirror_line || true   # leave no stale SDK_TEST_BASE_URL mirror line behind
  if [[ -d "$home/cmdline-tools/latest" ]]; then
    rm -rf "${home:?}/cmdline-tools/latest"
    rmdir "$home/cmdline-tools" 2>/dev/null || true
    log_info "Removed the kit-installed cmdline-tools."
  fi
  log_info "Kept your downloaded SDK data under $home (platforms/build-tools/etc. may be shared with Android Studio)."
  log_info "To delete the WHOLE SDK:  ${0##*/} purge   (or: rm -rf \"$home\")"
}

# purge (DESTRUCTIVE): rm -rf the entire $ANDROID_HOME, with FULL guardrails before the delete —
# user guard, then path validation: non-empty; realpath -m absolute; strictly UNDER the real $HOME;
# != / ; != $HOME ; the original path is not a symlink; ${VAR:?} so an empty var can never expand to
# a bare `rm -rf`. AVDs under ~/.android/avd are left untouched (a different tree).
do_purge() {
  _android_user_guard || return 1
  local home target; home="$(_android_home)"

  # --- path guardrails (the FULL shared guard set; all must hold before any rm) ---
  _android_path_safe_under_home "$home" || return 1
  target="$(realpath -m "$home" 2>/dev/null || true)"   # canonical form for the rm + the logs

  if [[ ! -d "$target" ]]; then
    log_info "No SDK directory at $target — nothing to purge."
    return 0
  fi
  # ~/Android/Sdk is also Android Studio's default SDK — be loud that this removes the shared SDK.
  log_warn "$(_android_t purge_studio_warn)"
  log_warn "Purging the ENTIRE Android SDK at $target (this cannot be undone)…"
  rm -rf "${target:?}"
  do_ensure_path off || true
  _android_clear_mirror_line || true   # leave no stale SDK_TEST_BASE_URL mirror line behind
  log_info "Purged $target. (AVDs under ~/.android/avd were left untouched.)"
}

# --- component / package actions (every sdkmanager spawn passes the gate) -------

do_add_package() {
  _android_user_guard || return 1
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || { log_err "Usage: ${0##*/} add-package <id>  (e.g. \"build-tools;35.0.0\")"; return 2; }
  # scrcpy is an apt package (curated convenience), NOT an sdkmanager one — route it to apt.
  if [[ "$pkg" == scrcpy ]]; then apt_install scrcpy; return $?; fi
  _android_valid_pkg "$pkg" || { log_err "$(_android_t invalid_package) ($pkg)"; return 2; }
  # system-image ABI handling (design §B: default = dpkg --print-architecture; cross-ABI warning).
  # The sdkmanager grammar is system-images;android-NN;<tag>;<abi> (4 ';'-fields). When the ABI is
  # omitted (3 fields) default it to the host ABI; when an ABI is given that differs from the host,
  # warn (that image only runs under emulation). Non-system-image ids are untouched.
  if [[ "$pkg" == system-images* ]]; then
    local host_abi; host_abi="$(_android_arch)"
    local nfields; nfields="$(awk -F';' '{print NF}' <<<"$pkg")"
    if (( nfields == 3 )); then
      pkg="${pkg};${host_abi}"
      local m; m="$(_android_t abi_default)"; m="${m//\{ABI\}/$host_abi}"; m="${m//\{PKG\}/$pkg}"
      log_info "$m"
    elif (( nfields >= 4 )); then
      local req_abi="${pkg##*;}"
      if [[ -n "$req_abi" && "$req_abi" != "$host_abi" ]]; then
        local m; m="$(_android_t abi_mismatch)"; m="${m//\{REQ\}/$req_abi}"; m="${m//\{HOST\}/$host_abi}"
        log_warn "$m"
      fi
    fi
  fi
  case "$pkg" in emulator|system-images*) _android_emulator_notes ;; esac
  _android_arch_note
  _android_sdkmanager "$pkg"
}

do_remove_package() {
  _android_user_guard || return 1
  local pkg="${1:-}"
  [[ -n "$pkg" ]] || { log_err "Usage: ${0##*/} remove-package <id>"; return 2; }
  if [[ "$pkg" == scrcpy ]]; then apt_remove scrcpy; return $?; fi
  _android_valid_pkg "$pkg" || { log_err "$(_android_t invalid_package) ($pkg)"; return 2; }
  _android_sdkmanager --uninstall "$pkg"
}

do_add_platform() {
  _android_user_guard || return 1
  local n="${1:-}"
  [[ -n "$n" ]] || { log_err "Usage: ${0##*/} add-platform <N>  (e.g. 35)"; return 2; }
  _android_valid_platform "$n" || { log_err "$(_android_t invalid_platform) ($n)"; return 2; }
  _android_sdkmanager "platforms;android-$n"
}

do_remove_platform() {
  _android_user_guard || return 1
  local n="${1:-}"
  [[ -n "$n" ]] || { log_err "Usage: ${0##*/} remove-platform <N>"; return 2; }
  _android_valid_platform "$n" || { log_err "$(_android_t invalid_platform) ($n)"; return 2; }
  _android_sdkmanager --uninstall "platforms;android-$n"
}

# --- mirror (persisted managed rc line; trust disclosure on non-default) --------
# Strip our managed SDK_TEST_BASE_URL line from the shell rc (the exact path `set-mirror default`
# uses), backing up first. Shared by set-mirror default AND remove/purge teardown so no stale
# `export SDK_TEST_BASE_URL` pointing at a third-party mirror survives. No-op when no line exists.
_android_clear_mirror_line() {
  local rc tmp; rc="$(_android_rc_file)"
  [[ -f "$rc" ]] && grep -qF "$ANDROID_MIRROR_MARKER" "$rc" || return 0
  backup_file "$rc"
  tmp="$(mktemp)"; grep -vF "$ANDROID_MIRROR_MARKER" "$rc" >"$tmp" || true
  mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
}

# set-mirror <name|url> — point sdkmanager's download root at a curated preset or a raw base URL by
# writing a managed SDK_TEST_BASE_URL line in the shell rc (read live by _android_mirror_base, and
# exported into each sdkmanager spawn). 'default' clears the override (back to dl.google.com).
do_set_mirror() {
  _android_user_guard || return 1
  local arg="${1:-}" rc tmp base; rc="$(_android_rc_file)"
  [[ -n "$arg" ]] || { log_err "Usage: ${0##*/} set-mirror <${ANDROID_MIRROR_ORDER// /|}|URL>"; return 2; }

  if [[ "$arg" == "default" ]]; then
    # Remove our managed mirror line (back to direct).
    _android_clear_mirror_line || return 1
    log_info "SDK download mirror reset to direct ($ANDROID_REPO_BASE_DEFAULT)."
    return 0
  fi

  base="${ANDROID_MIRROR_PRESET[$arg]:-$arg}"
  _android_valid_mirror "$base" || { log_err "$(_android_t invalid_mirror) ($base)"; return 2; }

  local line; line="export SDK_TEST_BASE_URL=\"$base\" $ANDROID_MIRROR_MARKER"
  if [[ -f "$rc" ]] && grep -qxF "$line" "$rc"; then
    log_info "SDK download mirror already set to $base — nothing to do."
  else
    [[ -s "$rc" ]] && backup_file "$rc"
    if [[ -f "$rc" ]] && grep -qF "$ANDROID_MIRROR_MARKER" "$rc"; then
      tmp="$(mktemp)"; grep -vF "$ANDROID_MIRROR_MARKER" "$rc" >"$tmp" || true
      printf '%s\n' "$line" >>"$tmp"
      mv "$tmp" "$rc" || { rm -f "$tmp"; return 1; }
    else
      printf '%s\n' "$line" >>"$rc"
    fi
    log_info "Set the SDK download mirror to $base (in $rc — open a new shell or 'source $rc')."
  fi
  # Trust disclosure (a non-default mirror is now an executable-code source).
  log_warn "$(_android_t mirror_trust)"
  log_warn "$(_android_t mirror_lag)"
}

# --- configure -----------------------------------------------------------------
# No flags = conservative baseline (ensure curl/unzip + cmdline-tools + the env block; NO platform
# / build-tools / emulator — nothing extra downloaded). --recommended layers on the latest stable
# platform + matching build-tools (resolved dynamically from `sdkmanager --list`, never hard-coded)
# + emulator (DROPPED when headless / no /dev/kvm). Flags: --accept-licenses / --mirror / --ensure-path.
do_configure() {
  _android_user_guard || return 1
  local recommended=0 accept=0 mirror="" ensure=""
  while (( $# > 0 )); do
    case "$1" in
      --recommended)       recommended=1; shift ;;
      --accept-licenses)   accept=1; shift ;;
      --mirror)   [[ $# -ge 2 ]] || { log_err "--mirror needs a value/preset."; return 2; }; mirror="$2"; shift 2 ;;
      --mirror=*) mirror="${1#--mirror=}"; shift ;;
      --ensure-path)   [[ $# -ge 2 ]] || { log_err "--ensure-path needs on|off."; return 2; }; ensure="$2"; shift 2 ;;
      --ensure-path=*) ensure="${1#--ensure-path=}"; shift ;;
      -h|--help) usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done

  # Mirror first (so a subsequent bootstrap/sdkmanager honors it).
  [[ -n "$mirror" ]] && { do_set_mirror "$mirror" || return $?; }

  # Baseline: ensure the bootstrap is in place (idempotent).
  have_cmd curl  || apt_install curl ca-certificates
  have_cmd unzip || apt_install unzip
  _android_install_cmdline_tools || return 1

  # PATH/env block (explicit override, else default on).
  if [[ -n "$ensure" ]]; then do_ensure_path "$ensure" || return $?
  else do_ensure_path on || log_warn "Could not write the ANDROID_HOME env block."; fi

  (( accept )) && { do_accept_licenses || return 1; }

  if (( ! recommended )); then
    log_info "Baseline ensured (cmdline-tools + env block). Use --recommended for a platform + build-tools + emulator, or: swkit android"
    return 0
  fi

  # --recommended: dynamically resolve the latest stable platform + build-tools from sdkmanager,
  # capturing `--list` ONCE for both (the resolver relies on this up-front gate + each spawn's gate).
  _android_java_gate || { log_warn "$(_android_t prereq_chain)"; return 1; }
  _android_resolve_recommended_versions
  local -a want=("platform-tools")
  [[ -n "$_ANDROID_LATEST_PLAT" ]] && want+=("platforms;android-$_ANDROID_LATEST_PLAT")
  [[ -n "$_ANDROID_LATEST_BT" ]]   && want+=("build-tools;$_ANDROID_LATEST_BT")
  # emulator only when there is a display + KVM (drop it on headless / no-KVM).
  if _android_headless || _android_no_kvm; then
    _android_emulator_notes
    log_info "Skipping the emulator (headless / no /dev/kvm)."
  else
    want+=("emulator")
  fi
  (( accept )) || { log_warn "If install stops on licenses, run: ${0##*/} accept-licenses"; }
  log_info "Installing recommended packages: ${want[*]}"
  _android_sdkmanager "${want[@]}"
  _android_arch_note
}

# Resolve the latest stable platform + build-tools from ONE `sdkmanager --list` capture (never
# hard-coded). Sets _ANDROID_LATEST_PLAT (highest android-<N>) and _ANDROID_LATEST_BT (highest stable
# X.Y.Z). --recommended used to spawn `--list` TWICE (once per version); a single capture halves the
# JVM cost. No explicit gate here — every _android_sdkmanager spawn already gates, and --recommended
# gates up front, so an extra per-helper gate would re-spawn java.sh redundantly (status() must still
# never reach this path). PREVIEW lines (-alpha/-beta/-rc/-dev) are SKIPPED ENTIRELY before the pick
# (like _android_resolve_cmdline_zip) — we do NOT strip an -rcN suffix, which would invent a possibly
# nonexistent stable (e.g. build-tools;36.0.0-rc1 → 36.0.0).
_android_resolve_recommended_versions() {
  _ANDROID_LATEST_PLAT=""; _ANDROID_LATEST_BT=""
  local list; list="$(_android_sdkmanager --list 2>/dev/null || true)"
  [[ -n "$list" ]] || return 0
  # Drop preview lines outright, then extract each kind from the cleaned list.
  local stable; stable="$(printf '%s\n' "$list" | grep -vE -- '-(alpha|beta|rc|dev)')"
  _ANDROID_LATEST_PLAT="$(printf '%s\n' "$stable" \
    | sed -n 's/.*platforms;android-\([0-9][0-9]*\).*/\1/p' \
    | sort -n -u | tail -n1)"
  _ANDROID_LATEST_BT="$(printf '%s\n' "$stable" \
    | sed -n 's/.*build-tools;\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)[^0-9].*/\1/p' \
    | sort -t. -k1,1n -k2,2n -k3,3n -u | tail -n1)"
}

# --- Interactive management screen (the script's own UI) -----------------------
# A component manager: a Java-compat banner + an "Install Java 17" delegate at the top (it runs
# java.sh install via ui_run so the sudo prompt lands on the real terminal — the AUTO-INSTALL
# DELEGATE pattern, ui_run because it needs sudo); the SDK components as a space-to-add/remove
# checklist; add-package / add-platform; the mirror selector; accept-licenses; recommended; remove;
# and the destructive purge behind a confirm. State is read live each pass (pure fs + read-only Java
# signals — ZERO JVM); every change shells out via ui_run then the screen reloads. `ui` is an entry
# mode — never in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  _android_user_guard >/dev/null 2>&1 || { ui_default_menu; return 0; }
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  # The components shown as a directly-togglable checklist: ONLY bare-id-installable sdkmanager
  # packages (platform-tools / emulator) + the apt-routed scrcpy. ndk / cmake are VERSIONED
  # sdkmanager packages (ndk;<ver> / cmake;<ver>) with no bare-id install form, so — like platforms
  # / build-tools / system-images — they are count-only here and added via the free-text add-package
  # prompt (where the user supplies the version). Toggling a bare 'ndk'/'cmake' would fail in sdkmanager.
  local comp_simple="platform-tools emulator scrcpy"
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state (zero JVM) ----
    local home sm installed=0; home="$(_android_home)"; sm="$(_android_sdkmanager_bin)"
    [[ -x "$sm" ]] && installed=1
    local java_ok=0 jver=""
    if _android_java_compat; then java_ok=1; jver="$_AJC_VERSION"; fi
    local mbase mname; mbase="$(_android_mirror_base)"; mname="$mbase"
    local mk
    for mk in $ANDROID_MIRROR_ORDER; do [[ "${ANDROID_MIRROR_PRESET[$mk]}" == "$mbase" ]] && { mname="$mk"; break; }; done

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()

    # Java banner + delegate.
    local jb
    if (( java_ok )); then jb="$(_android_t java_ok)"; jb="${jb//\{V\}/$jver}"
      dkind+=(jbanner); did+=(""); dlabel+=("$(ui_badge installed) $jb")
    else
      jb="$(_android_t java_missing)"
      dkind+=(jbanner); did+=(""); dlabel+=("$(ui_badge cross) $jb")
      dkind+=(install_java); did+=(install_java); dlabel+=("${UI_ACCENT}${UI_ARROW}${UI_OFF} $(_android_t install_java)")
    fi
    dkind+=(spacer); did+=(""); dlabel+=("")

    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(_android_t install_baseline)")
    else
      dkind+=(header); did+=(""); dlabel+=("$(_android_t sec_components)")
      local c badge present
      for c in $comp_simple; do
        present=0
        case "$c" in
          platform-tools) [[ -x "$home/platform-tools/adb" ]] && present=1 ;;
          scrcpy)         have_cmd scrcpy && present=1 ;;
          *)              [[ -d "$home/$c" ]] && present=1 ;;
        esac
        if (( present )); then badge="$(ui_badge installed)"; else badge="$(ui_badge missing)"; fi
        dkind+=(comp); did+=("$c"); dlabel+=("$badge $(printf '%-15s' "$c") ${UI_MUTED}$(_android_t "desc_$c")${UI_OFF}")
      done
      # platforms / build-tools / system-images / ndk / cmake counts (all versioned — managed via
      # add-platform / add-package, where the user supplies the version; shown here count-only).
      local np nb nsi nnd ncm
      np=0;  [[ -d "$home/platforms" ]]   && np="$(find "$home/platforms" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
      nb=0;  [[ -d "$home/build-tools" ]] && nb="$(find "$home/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
      nsi=0; [[ -d "$home/system-images" ]] && nsi="$(find "$home/system-images" -mindepth 3 -maxdepth 3 -type d 2>/dev/null | grep -c . || true)"
      nnd=0; [[ -d "$home/ndk" ]]         && nnd="$(find "$home/ndk" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
      ncm=0; [[ -d "$home/cmake" ]]       && ncm="$(find "$home/cmake" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -c . || true)"
      dkind+=(info); did+=(""); dlabel+=("${UI_MUTED}platforms: $np · build-tools: $nb · system-images: $nsi · ndk: $nnd · cmake: $ncm${UI_OFF}")
      dkind+=(add_platform); did+=(add_platform); dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_android_t add_platform)")
      dkind+=(add_package);  did+=(add_package);  dlabel+=("${UI_ACCENT}＋${UI_OFF} $(_android_t add_package)")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_android_t sec_settings)")
      dkind+=(mirror); did+=(mirror); dlabel+=("$(_android_t mirror): ${UI_INFO}${mname}${UI_OFF}  $UI_ARROW")
      local eb; if [[ -f "$(_android_rc_file)" ]] && grep -qxF "$ANDROID_BLOCK_BEGIN" "$(_android_rc_file)"; then eb="$(ui_badge on)"; else eb="$(ui_badge off)"; fi
      dkind+=(env); did+=(env); dlabel+=("$eb $(_android_t env_path)")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("$(_android_t sec_actions)")
      dkind+=(licenses);    did+=(licenses);    dlabel+=("${UI_ACCENT}${UI_ARROW}${UI_OFF} $(_android_t accept_licenses)")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) $(_android_t apply_recommended)")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove)")
      dkind+=(purge);  did+=(purge);  dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(_android_t purge)")
    fi

    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header|jbanner|info)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header|jbanner|info) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "Android SDK" "cmdline-tools $(ui_badge installed)"
    else ui_header "Android SDK" "$(ui_badge missing) $(ui_t not_installed)"; fi
    local i row=3 top=0 avail=$(( UI_ROWS - 3 - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        jbanner|info) ui_move "$row" 2; printf '\033[K%s' "${dlabel[$i]}" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    ui_footer "$(_android_t foot_main)"

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header|jbanner|info) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header|jbanner|info) ;; *) break ;; esac; done ;;
      enter|space)
        case "${dkind[$sel]}" in
          install_java) ui_run "$(_android_t install_java)" -- "$KIT_SCRIPTS_DIR/java.sh" install ;;
          install)      ui_run "$(_android_t install_baseline)" -- "$0" install ;;
          comp)
            local c="${did[$sel]}" present=0
            case "$c" in
              platform-tools) [[ -x "$home/platform-tools/adb" ]] && present=1 ;;
              scrcpy)         have_cmd scrcpy && present=1 ;;
              *)              [[ -d "$home/$c" ]] && present=1 ;;
            esac
            # add/remove-package routes scrcpy to apt and everything else through sdkmanager.
            if (( present )); then ui_run "remove-package $c" -- "$0" remove-package "$c"
            else ui_run "add-package $c" -- "$0" add-package "$c"; fi ;;
          add_platform) ui_input "$(_android_t prompt_platform)" "" && [[ -n "$UI_INPUT" ]] && ui_run "add-platform $UI_INPUT" -- "$0" add-platform "$UI_INPUT" ;;
          add_package)  ui_input "$(_android_t prompt_package)" "" && [[ -n "$UI_INPUT" ]] && ui_run "add-package $UI_INPUT" -- "$0" add-package "$UI_INPUT" ;;
          mirror)
            local -a parg=()
            for mk in $ANDROID_MIRROR_ORDER; do parg+=("$mk" "$mk  ${UI_MUTED}${ANDROID_MIRROR_PRESET[$mk]}${UI_OFF}"); done
            parg+=(__custom "$(_android_t mirror)…")
            if ui_pick "$(_android_t mirror)" "" "" -- "${parg[@]}"; then
              if [[ "$UI_PICK" == "__custom" ]]; then
                ui_input "URL (https://…/)" "$mbase" && ui_run "set-mirror" -- "$0" set-mirror "$UI_INPUT"
              elif [[ -n "$UI_PICK" ]]; then
                ui_run "set-mirror $UI_PICK" -- "$0" set-mirror "$UI_PICK"
              fi
            fi ;;
          env)
            if [[ -f "$(_android_rc_file)" ]] && grep -qxF "$ANDROID_BLOCK_BEGIN" "$(_android_rc_file)"; then ui_run "env off" -- "$0" configure --ensure-path off
            else ui_run "env on" -- "$0" configure --ensure-path on; fi ;;
          licenses)    ui_run "$(_android_t accept_licenses)" -- "$0" accept-licenses ;;
          recommended) ui_run "$(_android_t apply_recommended)" -- "$0" configure --recommended ;;
          remove)      ui_confirm "$(_android_t confirm_remove)" n && ui_run "$(ui_t remove) Android SDK" -- "$0" remove ;;
          purge)
            # ~/Android/Sdk is also Android Studio's default SDK — fold the shared-SDK warning into
            # the confirm prompt so the user sees it before agreeing (design §B: ui_confirm+Studio 警告).
            local cmsg; cmsg="$(_android_t confirm_purge)"; cmsg="${cmsg//\{DIR\}/$home}"
            cmsg="$cmsg"$'\n'"$(_android_t purge_studio_warn)"
            ui_confirm "$cmsg" n && ui_run "$(_android_t purge)" -- "$0" purge ;;
        esac ;;
      a)
        case "${dkind[$sel]}" in
          *) ui_input "$(_android_t prompt_package)" "" && [[ -n "$UI_INPUT" ]] && ui_run "add-package $UI_INPUT" -- "$0" add-package "$UI_INPUT" ;;
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

Headless Android SDK toolchain (cmdline-tools + sdkmanager). NO Android Studio. The whole SDK
download/extract/sdkmanager flow runs as YOU (no sudo); only curl/unzip (and optional scrcpy)
escalate per-command. sdkmanager needs a JDK >=$ANDROID_JDK_MIN — provided by 'swkit java' (this
script never auto-installs Java in the headless path; it points you at: swkit java install).

Commands:
  install [--accept-licenses]
                        Install the baseline: cmdline-tools (downloaded + SHA-1/size-verified) +
                        platform-tools. Licenses are NOT accepted unless you pass --accept-licenses.
                        On a JDK-less machine it still lays down cmdline-tools (status: tools/no-Java).
  remove                Conservative: remove the kit-installed cmdline-tools + env block; KEEP
                        downloaded SDK data (may be shared with Android Studio). Prints purge guidance.
  purge                 DESTRUCTIVE: delete the ENTIRE SDK at \$ANDROID_HOME (~/Android/Sdk), behind
                        path guardrails (under \$HOME, not /, not a symlink). AVDs are left untouched.
  configure [opts]      No flags: ensure cmdline-tools + the env block (nothing extra downloaded).
                          --recommended       latest platform + build-tools (dynamic) + emulator
                                              (emulator dropped when headless / no /dev/kvm)
                          --accept-licenses   accept the SDK licenses
                          --mirror <name|url> set the SDK download mirror (${ANDROID_MIRROR_ORDER// /|}|URL)
                          --ensure-path on|off add/remove the ANDROID_HOME + PATH env block
  accept-licenses       Accept all SDK licenses non-interactively (yes | sdkmanager --licenses)
  add-package <id>      Install one sdkmanager package (e.g. "build-tools;35.0.0", "ndk;…")
  remove-package <id>   Uninstall one sdkmanager package
  add-platform <N>      Install platforms;android-<N> (e.g. 35)
  remove-platform <N>   Uninstall platforms;android-<N>
  set-mirror <v>        Set the SDK download mirror (preset name or http(s) base URL; 'default' = direct)
  ensure-path on|off    Add/remove the ANDROID_HOME + PATH env block in your shell rc
  status                Print component counts + a Java-compat banner; exit 0 iff cmdline-tools present
  ui                    Open the interactive manager (needs a terminal)
  meta                  Print machine-readable metadata
  help                  Show this help

Notes: the emulator/system-images are desktop-GUI concerns — over SSH / on a headless box they
apply where a display + /dev/kvm exist. Google's native Linux SDK binaries are x86_64-only; arm64
hosts get an honest warning. A non-default mirror becomes a code source (unsigned SHA-1 index) —
use one you trust, or switch back to direct (dl.google.com) on any doubt.
EOF
}

kit_dispatch "$@"
