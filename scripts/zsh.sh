#!/usr/bin/env bash
#
# scripts/zsh.sh — install / configure / manage zsh on Ubuntu, as a COMPONENT MANAGER.
#
# Beyond installing zsh, `configure` and a set of discrete actions manage zsh's components
# independently — the framework (Oh My Zsh), the prompt, and individual plugins — and track
# the enabled set in a small state file (~/.config/zsh/ubuntu-setup.conf). Any change
# regenerates a managed drop-in (~/.config/zsh/ubuntu-setup.zsh) wholesale and sources it
# from ~/.zshrc via one idempotent line, so re-running converges to the latest without
# clobbering the user's own ~/.zshrc.
#
# Actions (kit_dispatch routes <op> -> do_<op>, hyphens -> underscores):
#   install / remove / status            zsh itself (apt)
#   configure [flags]                    full re-spec of the whole state (see usage)
#   install-omz / uninstall-omz          install / remove the Oh My Zsh framework
#   add-plugin <name|git-url>            enable a plugin (installs it; known names or any git repo)
#   remove-plugin <name>                 disable a plugin (removes git clones; keeps apt packages)
#   prompt <git|plain|starship|powerlevel10k|pure>   set the prompt
#   default-shell                        make zsh the default login shell (lockout-safe)
#
# Files are written AS THE USER, never via sudo. Only the login-shell change escalates,
# per command, via sudo_run.

set -Eeuo pipefail

_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly OMZ_INSTALL_URL="https://github.com/ohmyzsh/ohmyzsh/raw/master/tools/install.sh"
readonly STARSHIP_INSTALL_URL="https://starship.rs/install.sh"
readonly ZOXIDE_INSTALL_URL="https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh"
readonly P10K_REPO="https://github.com/romkatv/powerlevel10k"
readonly PURE_REPO="https://github.com/sindresorhus/pure"
readonly COMPLETIONS_REPO="https://github.com/zsh-users/zsh-completions"
readonly HSS_REPO="https://github.com/zsh-users/zsh-history-substring-search"
readonly ZSH_OLD_MARKER="# managed by ubuntu-setup zsh.sh"

# Known plugin keys (named, first-class). Anything else is treated as an arbitrary git repo
# cloned under ~/.config/zsh/plugins/<name>.
readonly ZSH_KNOWN_PLUGINS="autosuggestions syntax-highlighting completions history-substring-search fzf zoxide"

# OMZ-native bundled plugins, enabled via Oh My Zsh's plugins=(...) array (a separate axis
# from the kit's own plugins above). Curated to ones that ship with OMZ and are broadly
# useful on dev/server boxes. DELIBERATELY EXCLUDES zsh-autosuggestions / zsh-syntax-
# highlighting: the kit installs and sources those itself (after oh-my-zsh.sh, highlighting
# last), so listing them here too would double-load them.
readonly ZSH_OMZ_KNOWN_PLUGINS="git sudo extract colored-man-pages command-not-found docker docker-compose kubectl z"

# --- i18n (software-specific strings) ------------------------------------------
# Same shape as lib/ui.sh's UI_MSG/ui_t, kept local so the generic UI library stays free of
# zsh-specific text. Proper nouns stay UNtranslated: "zsh", "Oh My Zsh", prompt names
# (Starship/Powerlevel10k/Pure), plugin names, setting keys, date-stamp formats. Only the
# descriptive/operational wording is localized. Resolve with _zsh_t KEY (fallback en -> key).
declare -gA ZSH_I18N
# Rows / headers / status tags / hints
ZSH_I18N[en:zsh_suffix]="zsh — Z shell"
ZSH_I18N[en:framework]="Framework"
ZSH_I18N[en:prompt]="Prompt"
ZSH_I18N[en:login_shell]="Login shell"
ZSH_I18N[en:plugins]="Plugins"
ZSH_I18N[en:tag_git]="git"
ZSH_I18N[en:tag_custom]="custom"
ZSH_I18N[en:omz_plugins]="Oh My Zsh plugins"
ZSH_I18N[en:omz_settings]="Oh My Zsh settings"
ZSH_I18N[en:add_omz_plugin]="add Oh My Zsh plugin…"
ZSH_I18N[en:set_update]="Auto-update"
ZSH_I18N[en:set_magic]="Magic paste"
ZSH_I18N[en:set_untracked]="Untracked dirty"
ZSH_I18N[en:set_correction]="Correction"
ZSH_I18N[en:set_wait_dots]="Waiting dots"
ZSH_I18N[en:set_hist_stamps]="History stamps"
ZSH_I18N[en:foot_main]="↑↓ move   ↵/space toggle   a add-plugin   esc/q close"
ZSH_I18N[en:foot_install]="↑↓ move   ↵/space install   esc/q close"
# Prompts / pickers / confirms
ZSH_I18N[en:prompt_add_plugin]="git URL or plugin name"
ZSH_I18N[en:prompt_omz_plugin]="Oh My Zsh plugin name"
ZSH_I18N[en:confirm_remove]="Uninstall zsh? (refused if it is your login shell)"
ZSH_I18N[en:current]="current:"
ZSH_I18N[en:pick_prompt]="zsh — prompt"
ZSH_I18N[en:pr_git]="git (ASCII branch)"
ZSH_I18N[en:pr_plain]="plain"
ZSH_I18N[en:pr_starship]="Starship (Nerd Font)"
ZSH_I18N[en:pr_p10k]="Powerlevel10k (Nerd Font)"
ZSH_I18N[en:pr_pure]="Pure"
ZSH_I18N[en:pick_update]="OMZ auto-update"
ZSH_I18N[en:up_disabled]="disabled (kit manages updates via git)"
ZSH_I18N[en:up_auto]="auto"
ZSH_I18N[en:up_reminder]="reminder"
ZSH_I18N[en:pick_hist]="OMZ history stamps"
ZSH_I18N[en:hs_none]="none (off)"

ZSH_I18N[zh:zsh_suffix]="zsh — Z shell"
ZSH_I18N[zh:framework]="框架"
ZSH_I18N[zh:prompt]="提示符"
ZSH_I18N[zh:login_shell]="登录 shell"
ZSH_I18N[zh:plugins]="插件"
ZSH_I18N[zh:tag_git]="git"
ZSH_I18N[zh:tag_custom]="自定义"
ZSH_I18N[zh:omz_plugins]="Oh My Zsh 插件"
ZSH_I18N[zh:omz_settings]="Oh My Zsh 设置"
ZSH_I18N[zh:add_omz_plugin]="添加 Oh My Zsh 插件…"
ZSH_I18N[zh:set_update]="自动更新"
ZSH_I18N[zh:set_magic]="魔术粘贴"
ZSH_I18N[zh:set_untracked]="未跟踪即视为脏"
ZSH_I18N[zh:set_correction]="命令纠错"
ZSH_I18N[zh:set_wait_dots]="等待点提示"
ZSH_I18N[zh:set_hist_stamps]="历史时间戳"
ZSH_I18N[zh:foot_main]="↑↓ 移动   ↵/space 切换   a 加插件   esc/q 关闭"
ZSH_I18N[zh:foot_install]="↑↓ 移动   ↵/space 安装   esc/q 关闭"
ZSH_I18N[zh:prompt_add_plugin]="git URL 或插件名"
ZSH_I18N[zh:prompt_omz_plugin]="Oh My Zsh 插件名"
ZSH_I18N[zh:confirm_remove]="卸载 zsh?(若它是你的登录 shell 则拒绝)"
ZSH_I18N[zh:current]="当前:"
ZSH_I18N[zh:pick_prompt]="zsh — 提示符"
ZSH_I18N[zh:pr_git]="git(ASCII 分支)"
ZSH_I18N[zh:pr_plain]="plain(纯文本)"
ZSH_I18N[zh:pr_starship]="Starship(需 Nerd Font)"
ZSH_I18N[zh:pr_p10k]="Powerlevel10k(需 Nerd Font)"
ZSH_I18N[zh:pr_pure]="Pure"
ZSH_I18N[zh:pick_update]="OMZ 自动更新"
ZSH_I18N[zh:up_disabled]="disabled(由 kit 经 git 管理更新)"
ZSH_I18N[zh:up_auto]="auto(自动)"
ZSH_I18N[zh:up_reminder]="reminder(提醒)"
ZSH_I18N[zh:pick_hist]="OMZ 历史时间戳"
ZSH_I18N[zh:hs_none]="none(关闭)"

ZSH_I18N[ja:zsh_suffix]="zsh — Z shell"
ZSH_I18N[ja:framework]="フレームワーク"
ZSH_I18N[ja:prompt]="プロンプト"
ZSH_I18N[ja:login_shell]="ログインシェル"
ZSH_I18N[ja:plugins]="プラグイン"
ZSH_I18N[ja:tag_git]="git"
ZSH_I18N[ja:tag_custom]="カスタム"
ZSH_I18N[ja:omz_plugins]="Oh My Zsh プラグイン"
ZSH_I18N[ja:omz_settings]="Oh My Zsh 設定"
ZSH_I18N[ja:add_omz_plugin]="Oh My Zsh プラグインを追加…"
ZSH_I18N[ja:set_update]="自動更新"
ZSH_I18N[ja:set_magic]="マジックペースト"
ZSH_I18N[ja:set_untracked]="未追跡を dirty 扱い"
ZSH_I18N[ja:set_correction]="コマンド訂正"
ZSH_I18N[ja:set_wait_dots]="待機ドット表示"
ZSH_I18N[ja:set_hist_stamps]="履歴タイムスタンプ"
ZSH_I18N[ja:foot_main]="↑↓ 移動   ↵/space 切替   a プラグイン追加   esc/q 閉じる"
ZSH_I18N[ja:foot_install]="↑↓ 移動   ↵/space インストール   esc/q 閉じる"
ZSH_I18N[ja:prompt_add_plugin]="git URL またはプラグイン名"
ZSH_I18N[ja:prompt_omz_plugin]="Oh My Zsh プラグイン名"
ZSH_I18N[ja:confirm_remove]="zsh をアンインストールしますか?(ログインシェルの場合は拒否)"
ZSH_I18N[ja:current]="現在:"
ZSH_I18N[ja:pick_prompt]="zsh — プロンプト"
ZSH_I18N[ja:pr_git]="git(ASCII ブランチ)"
ZSH_I18N[ja:pr_plain]="plain(プレーン)"
ZSH_I18N[ja:pr_starship]="Starship(Nerd Font 必要)"
ZSH_I18N[ja:pr_p10k]="Powerlevel10k(Nerd Font 必要)"
ZSH_I18N[ja:pr_pure]="Pure"
ZSH_I18N[ja:pick_update]="OMZ 自動更新"
ZSH_I18N[ja:up_disabled]="disabled(kit が git で更新を管理)"
ZSH_I18N[ja:up_auto]="auto(自動)"
ZSH_I18N[ja:up_reminder]="reminder(リマインド)"
ZSH_I18N[ja:pick_hist]="OMZ 履歴タイムスタンプ"
ZSH_I18N[ja:hs_none]="none(オフ)"

# _zsh_t KEY — localized zsh string for $UI_LANG (en/zh/ja), fallback en -> key.
_zsh_t() {
  local lang; lang="$(ui_lang)"
  printf '%s' "${ZSH_I18N[$lang:$1]:-${ZSH_I18N[en:$1]:-$1}}"
}

meta() {
  cat <<'META'
key=zsh
name=zsh
category=essentials
ops=install,remove,configure,install-omz,uninstall-omz,default-shell
desc=Z shell — component manager: Oh My Zsh, prompts (git/starship/p10k/pure), plugins, default shell
META
}

status() { have_cmd zsh && zsh --version; }

do_install() {
  if status >/dev/null 2>&1; then
    log_info "zsh already installed ($(zsh --version 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install zsh
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "zsh is not installed — nothing to remove."
    return 0
  fi
  local user shell zsh_path
  user="${SUDO_USER:-$(id -un)}"
  zsh_path="$(command -v zsh)"
  shell="$(getent passwd "$user" | cut -d: -f7 || true)"
  if [[ -z "$shell" ]]; then
    log_err "Could not resolve the login shell for '$user' (not in passwd?) — refusing to remove zsh to be safe."
    return 1
  fi
  if [[ "$shell" == "$zsh_path" ]]; then
    log_err "zsh is the login shell for '$user'; removing it would break their login."
    log_err "Switch back to bash first:  chsh -s /bin/bash  (then re-run this remove)."
    return 1
  fi
  apt_remove zsh
}

# --- Target user / home + state -------------------------------------------------
# Sets globals: _ZHOME _ZSHRC _ZCONF _ZDROPIN _ZPLUGDIR. Refuses a sudo-wrapped run so
# dotfiles stay user-owned. $HOME is correct in the (only allowed) non-sudo case.
_zsh_resolve_paths() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run zsh configuration as your normal user, not via sudo — ~/.zshrc and the"
    log_err "managed files must stay user-owned. (Only the login-shell change needs root.)"
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _ZHOME="${HOME:-}"
  [[ -n "$_ZHOME" ]] || _ZHOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_ZHOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _ZSHRC="$_ZHOME/.zshrc"
  _ZCONF="$_ZHOME/.config/zsh/ubuntu-setup.conf"
  _ZDROPIN="$_ZHOME/.config/zsh/ubuntu-setup.zsh"
  _ZPLUGDIR="$_ZHOME/.config/zsh/plugins"
  mkdir -p "$_ZHOME/.config/zsh" "$_ZHOME/.cache/zsh" "$_ZPLUGDIR"
}

# Load state into FRAMEWORK / PROMPT / PLUGINS / ALIASES + the OMZ_* knobs (with defaults).
# OMZ defaults are conservative, performance/non-interactive-safe best practices (each is
# individually overridable via `omz-setting` / configure --omz-*): updates disabled (the kit
# manages OMZ via git; an auto-update prompt would block a non-interactive shell), magic
# functions off (faster paste), untracked-files-dirty off (faster git status in big repos),
# correction off (intrusive), waiting dots on, ISO history stamps.
_zsh_load_state() {
  FRAMEWORK="none"; PROMPT="git"; PLUGINS="autosuggestions syntax-highlighting"; ALIASES="1"
  OMZ_PLUGINS="git"
  OMZ_UPDATE="disabled"; OMZ_MAGIC="0"; OMZ_UNTRACKED_DIRTY="0"
  OMZ_CORRECTION="0"; OMZ_WAIT_DOTS="1"; OMZ_HIST_STAMPS="yyyy-mm-dd"
  [[ -f "$_ZCONF" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      FRAMEWORK)           FRAMEWORK="$v" ;;
      PROMPT)              PROMPT="$v" ;;
      PLUGINS)             PLUGINS="$v" ;;
      ALIASES)             ALIASES="$v" ;;
      OMZ_PLUGINS)         OMZ_PLUGINS="$v" ;;
      OMZ_UPDATE)          OMZ_UPDATE="$v" ;;
      OMZ_MAGIC)           OMZ_MAGIC="$v" ;;
      OMZ_UNTRACKED_DIRTY) OMZ_UNTRACKED_DIRTY="$v" ;;
      OMZ_CORRECTION)      OMZ_CORRECTION="$v" ;;
      OMZ_WAIT_DOTS)       OMZ_WAIT_DOTS="$v" ;;
      OMZ_HIST_STAMPS)     OMZ_HIST_STAMPS="$v" ;;
    esac
  done <"$_ZCONF"
}

_zsh_save_state() {
  {
    printf '# ubuntu-setup zsh.sh state — managed by swkit zsh actions; do not hand-edit.\n'
    printf 'FRAMEWORK=%s\n'           "$FRAMEWORK"
    printf 'PROMPT=%s\n'              "$PROMPT"
    printf 'PLUGINS=%s\n'             "$PLUGINS"
    printf 'ALIASES=%s\n'             "$ALIASES"
    printf 'OMZ_PLUGINS=%s\n'         "$OMZ_PLUGINS"
    printf 'OMZ_UPDATE=%s\n'          "$OMZ_UPDATE"
    printf 'OMZ_MAGIC=%s\n'           "$OMZ_MAGIC"
    printf 'OMZ_UNTRACKED_DIRTY=%s\n' "$OMZ_UNTRACKED_DIRTY"
    printf 'OMZ_CORRECTION=%s\n'      "$OMZ_CORRECTION"
    printf 'OMZ_WAIT_DOTS=%s\n'       "$OMZ_WAIT_DOTS"
    printf 'OMZ_HIST_STAMPS=%s\n'     "$OMZ_HIST_STAMPS"
  } >"$_ZCONF"
}

# --- Component installers (idempotent; install only if missing; run as the user) ----

_zsh_ensure_omz() {
  if [[ -d "$_ZHOME/.oh-my-zsh" ]]; then
    log_info "Oh My Zsh already installed — skipping."
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates
  log_info "Installing Oh My Zsh via the official installer ($OMZ_INSTALL_URL) — unattended, keeping ~/.zshrc."
  if ! ZSH="$_ZHOME/.oh-my-zsh" RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
        sh -c "$(curl -fsSL "$OMZ_INSTALL_URL")" "" --unattended --keep-zshrc; then
    log_err "Oh My Zsh installation failed (see output above)."
    return 1
  fi
}

_zsh_ensure_starship() {
  have_cmd starship && { log_info "Starship already installed — skipping."; return 0; }
  have_cmd curl || apt_install curl ca-certificates
  mkdir -p "$_ZHOME/.local/bin"   # the installer requires the bin dir to already exist
  log_info "Installing Starship ($STARSHIP_INSTALL_URL) into ~/.local/bin (no sudo)."
  if ! curl -fsSL "$STARSHIP_INSTALL_URL" | sh -s -- --bin-dir "$_ZHOME/.local/bin" --yes; then
    log_err "Starship installation failed (see output above)."
    return 1
  fi
  ensure_local_bin_on_path
}

_zsh_ensure_zoxide() {
  have_cmd zoxide && { log_info "zoxide already installed — skipping."; return 0; }
  apt_install zoxide || log_warn "apt could not install zoxide; trying the official installer."
  have_cmd zoxide && return 0
  have_cmd curl || apt_install curl ca-certificates
  mkdir -p "$_ZHOME/.local/bin"
  if ! curl -fsSL "$ZOXIDE_INSTALL_URL" | sh; then
    log_err "zoxide installation failed."
    return 1
  fi
  ensure_local_bin_on_path
}

# One-time migration: import the legacy rupa/z database (~/.z, written by Oh My Zsh's `z`
# plugin) into zoxide. When zoxide is enabled it owns the `z` command (see _zsh_emit_dropin),
# so without this the directories the user accumulated under OMZ `z` would be invisible to
# `z`. Sentinel-guarded — `zoxide import --merge` ADDS scores, so re-running would double-count.
_zsh_import_legacy_z() {
  local legacy="$_ZHOME/.z" sentinel="$_ZHOME/.config/zsh/.zoxide-imported-from-z"
  [[ -s "$legacy" ]] || return 0          # nothing to migrate (fresh machine / no OMZ-z history)
  [[ -e "$sentinel" ]] && return 0        # already imported once
  have_cmd zoxide || return 0
  if zoxide import --from z --merge "$legacy"; then
    : >"$sentinel"
    log_info "Imported existing ~/.z directory history into zoxide (one-time migration)."
  else
    log_warn "Could not import ~/.z into zoxide — old 'z' history may be missing."
    log_warn "Retry manually with:  zoxide import --from z --merge ~/.z"
  fi
}

# Ensure the recommended Nerd Font (MesloLGS NF) is installed, by delegating to the kit's
# dedicated fonts.sh — so Starship / Powerlevel10k glyphs render on a LOCAL display. Font
# logic lives in ONE place (fonts.sh), not duplicated here. Best-effort: a failure (e.g. no
# sudo for fontconfig) only warns; the zsh config still applies. Over SSH the font that
# matters is on the CLIENT terminal — fonts.sh prints that guidance.
_zsh_ensure_nerd_font() {
  local fonts="$KIT_SCRIPTS_DIR/fonts.sh"
  if [[ -x "$fonts" ]]; then
    if "$fonts" status >/dev/null 2>&1; then
      log_info "Recommended Nerd Font (MesloLGS NF) already installed."
    else
      log_info "Installing the recommended Nerd Font (MesloLGS NF) via fonts.sh…"
      "$fonts" install meslolgs || log_warn "Could not install the Nerd Font automatically — run 'swkit fonts install' yourself."
    fi
  else
    log_warn "fonts.sh not found; install a Nerd Font with 'swkit fonts install' for $PROMPT glyphs."
  fi
  log_warn "Nerd Font glyphs render in your LOCAL terminal — over SSH, also install/select MesloLGS NF on your client."
}

# git clone <repo> into <dir> if absent (run as the user). $3 = friendly name.
_zsh_git_clone() {
  local repo="$1" dir="$2" what="$3"
  [[ -d "$dir/.git" ]] && { log_info "$what already present — skipping."; return 0; }
  have_cmd git || apt_install git
  log_info "Cloning $what: $repo -> $dir"
  git clone --depth=1 "$repo" "$dir"
}

# Ensure a single enabled plugin is installed (install only if missing).
_zsh_plugin_ensure() {
  case "$1" in
    autosuggestions)          pkg_installed zsh-autosuggestions || apt_install zsh-autosuggestions ;;
    syntax-highlighting)      pkg_installed zsh-syntax-highlighting || apt_install zsh-syntax-highlighting ;;
    completions)              _zsh_git_clone "$COMPLETIONS_REPO" "$_ZPLUGDIR/zsh-completions" "zsh-completions" ;;
    history-substring-search) _zsh_git_clone "$HSS_REPO" "$_ZPLUGDIR/zsh-history-substring-search" "zsh-history-substring-search" ;;
    fzf)                      have_cmd fzf || apt_install fzf ;;
    zoxide)                   _zsh_ensure_zoxide ;;
    *)                        return 0 ;;   # arbitrary git plugin — cloned by add-plugin
  esac
}

# Uninstall a plugin's artifact. Git clones are removed; shared apt packages/tools are
# left installed (just disabled) — they're cheap to re-enable and may be used elsewhere.
_zsh_plugin_purge() {
  case "$1" in
    completions)              rm -rf "$_ZPLUGDIR/zsh-completions" ;;
    history-substring-search) rm -rf "$_ZPLUGDIR/zsh-history-substring-search" ;;
    autosuggestions)          log_info "Disabled; apt package 'zsh-autosuggestions' left installed (remove with apt if desired)." ;;
    syntax-highlighting)      log_info "Disabled; apt package 'zsh-syntax-highlighting' left installed (remove with apt if desired)." ;;
    fzf)                      log_info "Disabled; 'fzf' left installed (remove with apt if desired)." ;;
    zoxide)                   log_info "Disabled; 'zoxide' left installed (remove with apt if desired)." ;;
    *)                        rm -rf "${_ZPLUGDIR:?}/$1" ;;   # arbitrary git clone
  esac
}

# --- Drop-in generation ---------------------------------------------------------

# Emit the source/fpath/eval line(s) for one plugin (resolved live; empty if unresolved).
_zsh_emit_plugin() {
  local key="$1" src
  case "$key" in
    autosuggestions)
      src="$(dpkg -L zsh-autosuggestions 2>/dev/null | grep -m1 '/zsh-autosuggestions\.zsh$' || true)"
      [[ -n "$src" ]] && printf 'source %s\n' "$src"
      ;;
    syntax-highlighting)
      src="$(dpkg -L zsh-syntax-highlighting 2>/dev/null | grep -m1 '/zsh-syntax-highlighting\.zsh$' || true)"
      [[ -n "$src" ]] && printf 'source %s\n' "$src"
      ;;
    completions)
      [[ -d "$_ZPLUGDIR/zsh-completions/src" ]] && printf 'fpath+=("%s/zsh-completions/src")\n' "$_ZPLUGDIR"
      ;;
    history-substring-search)
      src="$_ZPLUGDIR/zsh-history-substring-search/zsh-history-substring-search.zsh"
      if [[ -r "$src" ]]; then
        printf 'source %s\n' "$src"
        printf 'bindkey "%s" history-substring-search-up\n'   '^[[A'
        printf 'bindkey "%s" history-substring-search-down\n' '^[[B'
        # shellcheck disable=SC2016
        printf '[[ -n "${terminfo[kcuu1]}" ]] && bindkey "${terminfo[kcuu1]}" history-substring-search-up\n'
        # shellcheck disable=SC2016
        printf '[[ -n "${terminfo[kcud1]}" ]] && bindkey "${terminfo[kcud1]}" history-substring-search-down\n'
      fi
      ;;
    fzf)
      # apt fzf (22.04/24.04) predates `fzf --zsh`; try it, else source the example files.
      cat <<'ZRC'
if command -v fzf >/dev/null 2>&1; then
  if fzf --zsh >/dev/null 2>&1; then
    source <(fzf --zsh)
  else
    for _f in /usr/share/doc/fzf/examples/key-bindings.zsh /usr/share/fzf/key-bindings.zsh; do [[ -r $_f ]] && source "$_f"; done
    for _f in /usr/share/doc/fzf/examples/completion.zsh /usr/share/fzf/completion.zsh; do [[ -r $_f ]] && source "$_f"; done
    unset _f
  fi
fi
ZRC
      ;;
    zoxide)
      # shellcheck disable=SC2016
      printf 'command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"\n'
      ;;
    *)
      # Arbitrary git plugin: resolve the conventional entry file (the file name often
      # differs from the repo name, so prefer any *.plugin.zsh). nullglob is off, so a
      # non-matching glob stays literal and fails the -r test.
      local dir="$_ZPLUGDIR/$key" f
      for f in "$dir"/*.plugin.zsh "$dir/$key.zsh" "$dir/init.zsh" "$dir"/*.zsh; do
        if [[ -r "$f" ]]; then printf 'source %s\n' "$f"; break; fi
      done
      ;;
  esac
}

# Print the names in PLUGINS whose slot matches $1 (fpath|normal|eval|syntax|post-syntax).
_zsh_plugins_in_slot() {
  local want="$1" p slot
  for p in $PLUGINS; do
    case "$p" in
      completions)              slot="fpath" ;;
      syntax-highlighting)      slot="syntax" ;;
      history-substring-search) slot="post-syntax" ;;
      fzf|zoxide)               slot="eval" ;;
      *)                        slot="normal" ;;
    esac
    [[ "$slot" == "$want" ]] && printf '%s\n' "$p"
  done
}

_zsh_emit_dropin() {
  local p

  cat <<'ZRC'
# ubuntu-setup zsh.sh — managed drop-in. DO NOT EDIT.
# Regenerated wholesale on every change. Put personal settings in ~/.zshrc (sourced before
# this file). Manage components with `swkit zsh <action>`; state in ./ubuntu-setup.conf.

# ---- History ----
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_IGNORE_SPACE HIST_REDUCE_BLANKS \
       HIST_FIND_NO_DUPS EXTENDED_HISTORY HIST_VERIFY

# ---- Options ----
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT INTERACTIVE_COMMENTS \
       NO_BEEP EXTENDED_GLOB NOTIFY ALWAYS_TO_END COMPLETE_IN_WORD
ZRC

  # fpath-slot plugins MUST be added before compinit (ours or Oh My Zsh's).
  for p in $(_zsh_plugins_in_slot fpath); do _zsh_emit_plugin "$p"; done

  if [[ "$FRAMEWORK" == "oh-my-zsh" ]]; then
    local omz_theme="robbyrussell"
    case "$PROMPT" in starship|powerlevel10k|pure) omz_theme="" ;; esac
    cat <<'ZRC'

# ---- Oh My Zsh (runs its own compinit) ----
export ZSH="$HOME/.oh-my-zsh"
ZRC
    printf 'ZSH_THEME="%s"\n' "$omz_theme"
    # Update behavior — the kit manages OMZ via git; the default 'disabled' keeps a
    # non-interactive shell from ever blocking on an auto-update prompt. Change with
    # `swkit zsh omz-setting update auto|reminder|disabled`.
    printf "zstyle ':omz:update' mode %s\n" "${OMZ_UPDATE:-disabled}"
    # Behavior / performance toggles (change with `swkit zsh omz-setting <key> <v>`).
    [[ "${OMZ_MAGIC:-0}" == "0" ]]           && printf 'DISABLE_MAGIC_FUNCTIONS="true"\n'
    [[ "${OMZ_UNTRACKED_DIRTY:-0}" == "0" ]] && printf 'DISABLE_UNTRACKED_FILES_DIRTY="true"\n'
    [[ "${OMZ_WAIT_DOTS:-1}" == "1" ]]       && printf 'COMPLETION_WAITING_DOTS="true"\n'
    [[ "${OMZ_CORRECTION:-0}" == "1" ]]      && printf 'ENABLE_CORRECTION="true"\n'
    case "${OMZ_HIST_STAMPS:-yyyy-mm-dd}" in none|"") ;; *) printf 'HIST_STAMPS="%s"\n' "$OMZ_HIST_STAMPS" ;; esac
    # zoxide (a kit plugin, sourced in the eval slot BELOW) and Oh My Zsh's bundled `z` plugin
    # BOTH bind the `z` command; whichever loads last wins. zoxide loads after oh-my-zsh.sh, so
    # it silently shadows OMZ `z` while using a SEPARATE database — `z` then "forgets" the
    # directories OMZ `z` recorded in ~/.z. When zoxide is enabled it owns `z`, so drop `z` from
    # the OMZ plugin list (same reason autosuggestions/syntax-highlighting aren't OMZ plugins:
    # avoid a double-load). Disable zoxide to fall back to the classic OMZ `z`.
    local omz_plugins="${OMZ_PLUGINS:-git}"
    if _zsh_plugin_in zoxide "$PLUGINS" && _zsh_plugin_in z "$omz_plugins"; then
      local _op _kept=""
      for _op in $omz_plugins; do [[ "$_op" == "z" ]] || _kept="${_kept:+$_kept }$_op"; done
      omz_plugins="$_kept"
      printf '# NOTE: OMZ z plugin omitted here — zoxide (below) provides the z command.\n'
    fi
    printf 'plugins=(%s)\n' "$omz_plugins"
    cat <<'ZRC'
source "$ZSH/oh-my-zsh.sh"
ZRC
  else
    cat <<'ZRC'

# ---- Completion ----
autoload -Uz compinit
_zcd="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
if [[ -n $_zcd(#qN.mh+24) ]]; then compinit -d "$_zcd"; else compinit -C -d "$_zcd"; fi
unset _zcd
[[ -x /usr/bin/dircolors ]] && eval "$(dircolors -b)"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*:default' list-colors ${(s.:.)LS_COLORS}
zstyle ':completion:*' group-name ''
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompcache"
zstyle ':completion:*' completer _complete _approximate
zstyle ':completion:*' verbose yes
ZRC
  fi

  cat <<'ZRC'

# ---- Keybindings ----
bindkey -e
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
[[ -n "${terminfo[kcuu1]}" ]] && bindkey "${terminfo[kcuu1]}" up-line-or-beginning-search
[[ -n "${terminfo[kcud1]}" ]] && bindkey "${terminfo[kcud1]}" down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
[[ -n "${terminfo[khome]}" ]] && bindkey "${terminfo[khome]}" beginning-of-line
[[ -n "${terminfo[kend]}"  ]] && bindkey "${terminfo[kend]}"  end-of-line
[[ -n "${terminfo[kdch1]}" ]] && bindkey "${terminfo[kdch1]}" delete-char
[[ -n "${terminfo[kpp]}"   ]] && bindkey "${terminfo[kpp]}"   beginning-of-buffer-or-history
[[ -n "${terminfo[knp]}"   ]] && bindkey "${terminfo[knp]}"   end-of-buffer-or-history
bindkey '^[[Z' reverse-menu-complete
ZRC

  if [[ "$ALIASES" == "1" ]]; then
    cat <<'ZRC'

# ---- Aliases / colors ---- (color only; rm/cp/mv left at stock behavior)
alias ls='ls --color=auto'
alias ll='ls -lFh'
alias la='ls -lAFh'
alias l='ls -CF'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias diff='diff --color=auto'
ZRC
  fi

  case "$PROMPT" in
    git)
      cat <<'ZRC'

# ---- Prompt (git branch, ASCII, no fonts) ----
autoload -Uz vcs_info
zstyle ':vcs_info:git:*' formats ' (%b)'
zstyle ':vcs_info:git:*' actionformats ' (%b|%a)'
_ubuntu_setup_vcs() { vcs_info }
precmd_functions+=(_ubuntu_setup_vcs)
setopt PROMPT_SUBST
PROMPT='%F{green}%n@%m%f:%F{blue}%~%f%F{yellow}${vcs_info_msg_0_}%f %# '
ZRC
      ;;
    plain)
      cat <<'ZRC'

# ---- Prompt (plain) ----
PROMPT='%n@%m:%~ %# '
ZRC
      ;;
    starship)
      cat <<'ZRC'

# ---- Prompt (Starship) ----
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"
ZRC
      ;;
    powerlevel10k)
      printf '\n# ---- Prompt (Powerlevel10k) ----\n'
      printf '[[ -r "%s/powerlevel10k/powerlevel10k.zsh-theme" ]] && source "%s/powerlevel10k/powerlevel10k.zsh-theme"\n' "$_ZPLUGDIR" "$_ZPLUGDIR"
      # shellcheck disable=SC2016
      printf '[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"\n'
      ;;
    pure)
      printf '\n# ---- Prompt (Pure) ----\n'
      printf 'fpath+=("%s/pure")\n' "$_ZPLUGDIR"
      printf 'autoload -Uz promptinit && promptinit\nprompt pure\n'
      ;;
  esac

  # Plugins by slot, in load order: normal (autosuggestions, arbitrary git) -> eval tools
  # (fzf, zoxide) -> syntax-highlighting -> history-substring-search (must be after it).
  local emitted=0
  for p in $(_zsh_plugins_in_slot normal) $(_zsh_plugins_in_slot eval) \
           $(_zsh_plugins_in_slot syntax) $(_zsh_plugins_in_slot post-syntax); do
    if [[ $emitted -eq 0 ]]; then printf '\n# ---- Plugins ----\n'; emitted=1; fi
    [[ "$p" == "autosuggestions" ]] && {
      printf "ZSH_AUTOSUGGEST_STRATEGY=(history completion)\n"
      printf "ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'\n"
      printf "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)\n"
    }
    _zsh_emit_plugin "$p"
  done

  # Always end with a clean exit status (prompt/plugin guards above may end non-zero).
  printf '\ntrue\n'
}

# Resolve everything that's enabled, regenerate the drop-in, and wire ~/.zshrc.
_zsh_apply() {
  local source_line p
  # Migrate an old whole-file ~/.zshrc, then ensure the source line exists BEFORE installing
  # a framework (so Oh My Zsh's --keep-zshrc keeps ours).
  _zsh_migrate_old_zshrc
  # shellcheck disable=SC2016
  source_line='[[ -f "$HOME/.config/zsh/ubuntu-setup.zsh" ]] && source "$HOME/.config/zsh/ubuntu-setup.zsh"'
  append_once "$source_line" "$_ZSHRC"

  # Ensure every enabled component is actually installed (idempotent; only if missing).
  [[ "$FRAMEWORK" == "oh-my-zsh" ]] && { _zsh_ensure_omz || return 1; }
  case "$PROMPT" in
    starship)      _zsh_ensure_starship || return 1; _zsh_ensure_nerd_font ;;
    powerlevel10k) _zsh_git_clone "$P10K_REPO" "$_ZPLUGDIR/powerlevel10k" "Powerlevel10k" || return 1;
                   _zsh_ensure_nerd_font;
                   log_info "Run 'p10k configure' yourself to customize it (interactive; not run here)." ;;
    pure)          _zsh_git_clone "$PURE_REPO" "$_ZPLUGDIR/pure" "Pure prompt" || return 1 ;;
  esac
  for p in $PLUGINS; do _zsh_plugin_ensure "$p" || log_warn "Could not install plugin '$p' — its source line will be skipped."; done

  # zoxide owns the `z` command when enabled: migrate any legacy ~/.z history into it once, and
  # warn if Oh My Zsh's `z` plugin is also enabled (both bind `z`; zoxide wins — see _zsh_emit_dropin).
  if _zsh_plugin_in zoxide "$PLUGINS"; then
    _zsh_import_legacy_z
    if [[ "$FRAMEWORK" == "oh-my-zsh" ]] && _zsh_plugin_in z "$OMZ_PLUGINS"; then
      log_warn "zoxide and Oh My Zsh's 'z' plugin are both enabled — both provide 'z'; zoxide wins."
      log_warn "Prefer the classic OMZ 'z'? Disable zoxide:  swkit zsh remove-plugin zoxide"
    fi
  fi

  backup_file "$_ZDROPIN"
  _zsh_emit_dropin >"$_ZDROPIN"
  _zsh_save_state
  log_info "Applied zsh config: framework=$FRAMEWORK, prompt=$PROMPT, plugins=[${PLUGINS}]."
  log_info "Re-run any 'swkit zsh ...' action to update; your own ~/.zshrc is kept."
}

_zsh_migrate_old_zshrc() {
  local first=""
  [[ -f "$_ZSHRC" ]] || return 0
  IFS= read -r first <"$_ZSHRC" || first=""
  [[ "$first" == "$ZSH_OLD_MARKER" ]] || return 0
  backup_file "$_ZSHRC"
  : >"$_ZSHRC"
  log_warn "Migrated an older fully-managed ~/.zshrc to the drop-in model (backed up to ${_ZSHRC}.bak.*)."
  log_warn "If you had personal lines there, copy them from the backup into ~/.zshrc."
}

# --- Actions -------------------------------------------------------------------

do_configure() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  _zsh_resolve_paths || return 1
  _zsh_load_state

  local default_shell=0 want_plugins=1 plugins_set="" omz_plugins_set=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --framework)   FRAMEWORK="${2:-}"; shift 2 || { log_err "--framework needs a value."; return 2; } ;;
      --framework=*) FRAMEWORK="${1#--framework=}"; shift ;;
      --prompt)      PROMPT="${2:-}"; shift 2 || { log_err "--prompt needs a value."; return 2; } ;;
      --prompt=*)    PROMPT="${1#--prompt=}"; shift ;;
      --plugins)     plugins_set="${2:-}"; shift 2 || { log_err "--plugins needs a value."; return 2; } ;;
      --plugins=*)   plugins_set="${1#--plugins=}"; shift ;;
      --no-plugins)  want_plugins=0; shift ;;
      --no-aliases)  ALIASES=0; shift ;;
      --default-shell) default_shell=1; shift ;;
      --omz-plugins)   omz_plugins_set="${2:-}"; shift 2 || { log_err "--omz-plugins needs a value."; return 2; } ;;
      --omz-plugins=*) omz_plugins_set="${1#--omz-plugins=}"; shift ;;
      --omz-update)    OMZ_UPDATE="${2:-}"; shift 2 || { log_err "--omz-update needs a value."; return 2; } ;;
      --omz-update=*)  OMZ_UPDATE="${1#--omz-update=}"; shift ;;
      --omz-magic)     _zsh_bool "${2:-}" OMZ_MAGIC || return 2; shift 2 ;;
      --omz-magic=*)   _zsh_bool "${1#--omz-magic=}" OMZ_MAGIC || return 2; shift ;;
      --omz-untracked-dirty)   _zsh_bool "${2:-}" OMZ_UNTRACKED_DIRTY || return 2; shift 2 ;;
      --omz-untracked-dirty=*) _zsh_bool "${1#--omz-untracked-dirty=}" OMZ_UNTRACKED_DIRTY || return 2; shift ;;
      --omz-correction)   _zsh_bool "${2:-}" OMZ_CORRECTION || return 2; shift 2 ;;
      --omz-correction=*) _zsh_bool "${1#--omz-correction=}" OMZ_CORRECTION || return 2; shift ;;
      --omz-wait-dots)    _zsh_bool "${2:-}" OMZ_WAIT_DOTS || return 2; shift 2 ;;
      --omz-wait-dots=*)  _zsh_bool "${1#--omz-wait-dots=}" OMZ_WAIT_DOTS || return 2; shift ;;
      --omz-hist-stamps)   OMZ_HIST_STAMPS="${2:-}"; shift 2 || { log_err "--omz-hist-stamps needs a value."; return 2; } ;;
      --omz-hist-stamps=*) OMZ_HIST_STAMPS="${1#--omz-hist-stamps=}"; shift ;;
      *) log_err "Unknown configure option: $1"; return 2 ;;
    esac
  done
  case "$FRAMEWORK" in none|oh-my-zsh) ;; *) log_err "Unknown --framework '$FRAMEWORK' (none|oh-my-zsh)."; return 2 ;; esac
  case "$PROMPT" in git|plain|starship|powerlevel10k|pure) ;; *) log_err "Unknown --prompt '$PROMPT'."; return 2 ;; esac
  case "$OMZ_UPDATE" in disabled|auto|reminder) ;; *) log_err "--omz-update: disabled|auto|reminder."; return 2 ;; esac
  case "$OMZ_HIST_STAMPS" in yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none) ;; *) log_err "--omz-hist-stamps: yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none."; return 2 ;; esac
  if [[ -n "$omz_plugins_set" ]]; then
    local _omzp; _omzp="$(_zsh_omz_plugins_validate "$omz_plugins_set")" || return 2
    OMZ_PLUGINS="$_omzp"
  fi

  # Plugin set: --no-plugins clears; --plugins replaces (comma/space separated, known keys);
  # otherwise keep the current set (default on a fresh machine = autosuggestions+syntax).
  if [[ "$want_plugins" -eq 0 ]]; then
    PLUGINS=""
  elif [[ -n "$plugins_set" ]]; then
    local list p; list="${plugins_set//,/ }"; PLUGINS=""
    for p in $list; do
      if _zsh_plugin_in "$p" "$ZSH_KNOWN_PLUGINS"; then PLUGINS="${PLUGINS:+$PLUGINS }$p"
      else log_err "Unknown plugin '$p' for --plugins (known: $ZSH_KNOWN_PLUGINS). Use add-plugin <git-url> for arbitrary."; return 2; fi
    done
  fi

  _zsh_apply || return 1
  if [[ "$default_shell" -eq 1 ]]; then do_default_shell || return 1; fi
  return 0
}

# Membership test: is $1 a word in the space-separated list $2?
_zsh_plugin_in() {
  local needle="$1" hay=" $2 "
  [[ "$hay" == *" $needle "* ]]
}

do_install_omz() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  FRAMEWORK="oh-my-zsh"
  _zsh_apply
}

do_uninstall_omz() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  FRAMEWORK="none"
  if [[ -d "$_ZHOME/.oh-my-zsh" ]]; then
    rm -rf "$_ZHOME/.oh-my-zsh"
    log_info "Removed $_ZHOME/.oh-my-zsh."
  else
    log_info "Oh My Zsh was not installed."
  fi
  _zsh_apply
}

do_add_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: zsh add-plugin <name|git-url>"
    log_err "Known names: $ZSH_KNOWN_PLUGINS"
    return 2
  fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  local key
  if [[ "$arg" == *://* || "$arg" == git@* ]]; then
    # Arbitrary git plugin: derive a name and clone it.
    key="$(basename "$arg")"; key="${key%.git}"
    _zsh_git_clone "$arg" "$_ZPLUGDIR/$key" "$key" || { log_err "Clone failed for $arg."; return 1; }
  elif _zsh_plugin_in "$arg" "$ZSH_KNOWN_PLUGINS"; then
    key="$arg"
  else
    log_err "Unknown plugin '$arg'. Known: $ZSH_KNOWN_PLUGINS. For others pass a git URL."
    return 2
  fi
  if _zsh_plugin_in "$key" "$PLUGINS"; then
    log_info "Plugin '$key' already enabled — refreshing config."
  else
    PLUGINS="${PLUGINS:+$PLUGINS }$key"
  fi
  _zsh_apply
}

do_remove_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local key="${1:-}"
  if [[ -z "$key" ]]; then log_err "Usage: zsh remove-plugin <name>"; return 2; fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  if ! _zsh_plugin_in "$key" "$PLUGINS"; then
    log_info "Plugin '$key' is not enabled — nothing to remove."
    return 0
  fi
  local p new=""
  for p in $PLUGINS; do [[ "$p" == "$key" ]] || new="${new:+$new }$p"; done
  PLUGINS="$new"
  _zsh_plugin_purge "$key"
  _zsh_apply
}

# --- Oh My Zsh native plugins (the plugins=(...) array) -------------------------
# A separate axis from the kit's own plugins: these ship with OMZ and are enabled by name.
# Probe the live OMZ install (idempotency contract) to know what's a real plugin.

_zsh_omz_plugin_available() {
  local name="$1"
  [[ -d "$_ZHOME/.oh-my-zsh/plugins/$name" || -d "$_ZHOME/.oh-my-zsh/custom/plugins/$name" ]]
}

do_add_omz_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    log_err "Usage: zsh add-omz-plugin <name>"
    log_err "Curated OMZ plugins: $ZSH_OMZ_KNOWN_PLUGINS"
    return 2
  fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  if [[ "$FRAMEWORK" != "oh-my-zsh" ]]; then
    log_err "Oh My Zsh is not enabled — run 'swkit zsh install-omz' first (OMZ plugins need the framework)."
    return 2
  fi
  if ! _zsh_omz_plugin_available "$name"; then
    log_err "'$name' is not an Oh My Zsh plugin (not in ~/.oh-my-zsh/plugins or custom/plugins)."
    log_err "Curated OMZ plugins: $ZSH_OMZ_KNOWN_PLUGINS"
    return 2
  fi
  if _zsh_plugin_in "$name" "$OMZ_PLUGINS"; then
    log_info "OMZ plugin '$name' already enabled — refreshing config."
  else
    OMZ_PLUGINS="${OMZ_PLUGINS:+$OMZ_PLUGINS }$name"
  fi
  _zsh_apply
}

do_remove_omz_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local name="${1:-}"
  if [[ -z "$name" ]]; then log_err "Usage: zsh remove-omz-plugin <name>"; return 2; fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  if ! _zsh_plugin_in "$name" "$OMZ_PLUGINS"; then
    log_info "OMZ plugin '$name' is not enabled — nothing to remove."
    return 0
  fi
  local p new=""
  for p in $OMZ_PLUGINS; do [[ "$p" == "$name" ]] || new="${new:+$new }$p"; done
  OMZ_PLUGINS="$new"
  _zsh_apply
}

# Validate/normalize a space/comma OMZ plugin list: each must be curated or live in the OMZ
# install. Echoes the normalized space list; non-zero (with guidance) on an unknown name.
_zsh_omz_plugins_validate() {
  local raw="${1//,/ }" p out=""
  for p in $raw; do
    if _zsh_plugin_in "$p" "$ZSH_OMZ_KNOWN_PLUGINS" || _zsh_omz_plugin_available "$p"; then
      out="${out:+$out }$p"
    else
      log_err "Unknown OMZ plugin '$p' (not curated and not in ~/.oh-my-zsh/plugins)."
      log_err "Curated: $ZSH_OMZ_KNOWN_PLUGINS"
      return 2
    fi
  done
  printf '%s' "$out"
}

# Parse on/off/1/0/true/false/yes/no into 1/0 via nameref OUTVAR.
_zsh_bool() {
  local v="$1"; local -n _out="$2"
  case "$v" in
    on|1|true|yes|y|Y)  _out=1 ;;
    off|0|false|no|n|N) _out=0 ;;
    *) log_err "Expected on|off, got '$v'."; return 1 ;;
  esac
}

# Granular OMZ setting control: omz-setting <key> <value>.
do_omz_setting() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local key="${1:-}" val="${2:-}"
  if [[ -z "$key" || -z "$val" ]]; then
    log_err "Usage: zsh omz-setting <key> <value>"
    log_err "  update          disabled|auto|reminder   (OMZ auto-update mode)"
    log_err "  magic           on|off                   (magic paste functions; off = faster)"
    log_err "  untracked-dirty on|off                   (VCS dirty on untracked files; off = faster)"
    log_err "  correction      on|off                   (command auto-correction)"
    log_err "  wait-dots       on|off                   (dots while completing)"
    log_err "  hist-stamps     yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none"
    return 2
  fi
  _zsh_resolve_paths || return 1
  _zsh_load_state
  case "$key" in
    update)          case "$val" in disabled|auto|reminder) OMZ_UPDATE="$val" ;; *) log_err "update: disabled|auto|reminder"; return 2 ;; esac ;;
    magic)           _zsh_bool "$val" OMZ_MAGIC || return 2 ;;
    untracked-dirty) _zsh_bool "$val" OMZ_UNTRACKED_DIRTY || return 2 ;;
    correction)      _zsh_bool "$val" OMZ_CORRECTION || return 2 ;;
    wait-dots)       _zsh_bool "$val" OMZ_WAIT_DOTS || return 2 ;;
    hist-stamps)     case "$val" in yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none) OMZ_HIST_STAMPS="$val" ;; *) log_err "hist-stamps: yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none"; return 2 ;; esac ;;
    *) log_err "Unknown omz-setting key '$key' (update|magic|untracked-dirty|correction|wait-dots|hist-stamps)."; return 2 ;;
  esac
  _zsh_apply
}

do_prompt() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local p="${1:-}"
  case "$p" in
    git|plain|starship|powerlevel10k|pure) ;;
    *) log_err "Usage: zsh prompt <git|plain|starship|powerlevel10k|pure>"; return 2 ;;
  esac
  _zsh_resolve_paths || return 1
  _zsh_load_state
  PROMPT="$p"
  _zsh_apply
}

# Make zsh the default login shell — lockout-safe, escalating per command.
do_default_shell() {
  if ! status >/dev/null 2>&1; then log_info "Install zsh first."; return 0; fi
  local user zsh_path current
  user="${SUDO_USER:-$(id -un)}"
  zsh_path="$(command -v zsh)"
  if ! timeout 15 zsh -i -c 'exit 0' >/dev/null 2>&1; then
    log_err "An interactive zsh did not start cleanly (it hung or errored)."
    log_err "Not changing the login shell. Run 'zsh configure' / fix your zsh config first."
    return 1
  fi
  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    printf '%s\n' "$zsh_path" | sudo_run tee -a /etc/shells >/dev/null
  fi
  current="$(getent passwd "$user" | cut -d: -f7 || true)"
  if [[ "$current" == "$zsh_path" ]]; then
    log_info "zsh is already the login shell for '$user'."
  else
    sudo_run chsh -s "$zsh_path" "$user"
    log_info "Set zsh as login shell for '$user' — takes effect on next login."
    log_info "Keep this session open; try now with: exec zsh"
  fi
}

# --- UI label helpers (OMZ settings rows) --------------------------------------
_zsh_onoff()        { [[ "$1" == "1" ]] && printf 'on' || printf 'off'; }
_zsh_toggle_onoff() { [[ "$1" == "1" ]] && printf 'off' || printf 'on'; }
_zsh_omz_setting_row() { printf '  %-16s %s%s%s' "$1" "$UI_INFO" "$2" "$UI_OFF"; }

# --- Interactive management screen (the script's own UI) -----------------------
# A bespoke full-screen component manager: toggle the framework, pick a prompt, check
# plugins on/off, manage Oh My Zsh's native plugins + settings (when OMZ is on), set the
# default shell, install/remove zsh. State is read live from ubuntu-setup.conf each pass;
# every change shells out via ui_run (so apt/git/sudo output is visible and logged) and then
# the screen reloads. Limited terminals fall back to the synthesized op menu. `ui` is an
# entry mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" user zsh_path cur_shell is_default=0
    user="${SUDO_USER:-$(id -un)}"
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(zsh --version 2>/dev/null | awk '{print $2}')"
      zsh_path="$(command -v zsh)"
      cur_shell="$(getent passwd "$user" | cut -d: -f7 2>/dev/null || true)"
      [[ "$cur_shell" == "$zsh_path" ]] && is_default=1
      if _zsh_resolve_paths >/dev/null 2>&1; then _zsh_load_state; fi
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) $(_zsh_t zsh_suffix)")
    else
      local fw_badge
      if [[ "${FRAMEWORK:-none}" == "oh-my-zsh" ]]; then fw_badge="${UI_OK}[on]${UI_OFF}"; else fw_badge="${UI_MUTED}[off]${UI_OFF}"; fi
      dkind+=(framework); did+=(framework); dlabel+=("$(printf '%-13s %s' "$(_zsh_t framework)" "Oh My Zsh  $fw_badge")")
      dkind+=(prompt);    did+=(prompt);    dlabel+=("$(printf '%-13s %s%s%s  %s' "$(_zsh_t prompt)" "$UI_INFO" "${PROMPT:-git}" "$UI_OFF" "$UI_ARROW")")
      dkind+=(spacer);    did+=("");        dlabel+=("")
      dkind+=(header);    did+=("");        dlabel+=("$(_zsh_t plugins)")
      local -a known=(autosuggestions syntax-highlighting completions history-substring-search fzf zoxide)
      local p on
      for p in "${known[@]}"; do
        on=0; _zsh_plugin_in "$p" "$PLUGINS" && on=1
        dkind+=(plugin); did+=("$p")
        if (( on )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $p"); else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $p"); fi
      done
      for p in $PLUGINS; do
        _zsh_plugin_in "$p" "${known[*]}" && continue
        dkind+=(plugin); did+=("$p"); dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $p ${UI_MUTED}($(_zsh_t tag_git))${UI_OFF}")
      done

      # ---- Oh My Zsh native plugins + settings (only when the framework is on) ----
      if [[ "${FRAMEWORK:-none}" == "oh-my-zsh" ]]; then
        local op oon
        dkind+=(spacer); did+=(""); dlabel+=("")
        dkind+=(header); did+=(""); dlabel+=("$(_zsh_t omz_plugins)")
        for op in $ZSH_OMZ_KNOWN_PLUGINS; do
          oon=0; _zsh_plugin_in "$op" "$OMZ_PLUGINS" && oon=1
          dkind+=(omzplugin); did+=("$op")
          if (( oon )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $op"); else dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $op"); fi
        done
        for op in $OMZ_PLUGINS; do
          _zsh_plugin_in "$op" "$ZSH_OMZ_KNOWN_PLUGINS" && continue
          dkind+=(omzplugin); did+=("$op"); dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $op ${UI_MUTED}($(_zsh_t tag_custom))${UI_OFF}")
        done
        dkind+=(omzplugin_add); did+=(omzplugin_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} $(_zsh_t add_omz_plugin)")
        dkind+=(spacer); did+=(""); dlabel+=("")
        dkind+=(header); did+=(""); dlabel+=("$(_zsh_t omz_settings)")
        dkind+=(omzsetting); did+=(update);          dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_update)"      "$OMZ_UPDATE")")
        dkind+=(omzsetting); did+=(magic);           dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_magic)"       "$(_zsh_onoff "$OMZ_MAGIC")")")
        dkind+=(omzsetting); did+=(untracked-dirty); dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_untracked)"   "$(_zsh_onoff "$OMZ_UNTRACKED_DIRTY")")")
        dkind+=(omzsetting); did+=(correction);      dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_correction)"  "$(_zsh_onoff "$OMZ_CORRECTION")")")
        dkind+=(omzsetting); did+=(wait-dots);       dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_wait_dots)"   "$(_zsh_onoff "$OMZ_WAIT_DOTS")")")
        dkind+=(omzsetting); did+=(hist-stamps);     dlabel+=("$(_zsh_omz_setting_row "$(_zsh_t set_hist_stamps)" "$OMZ_HIST_STAMPS")")
      fi

      dkind+=(spacer);   did+=("");        dlabel+=("")
      dkind+=(defshell); did+=(defshell)
      if (( is_default )); then dlabel+=("$(printf '%-13s %s' "$(_zsh_t login_shell)" "zsh ${UI_OK}${UI_CHECK}${UI_OFF}")")
      else dlabel+=("$(printf '%-13s %s' "$(_zsh_t login_shell)" "${UI_MUTED}${cur_shell}${UI_OFF}  ${UI_ARROW} zsh")"); fi
      dkind+=(spacer);   did+=("");        dlabel+=("")
      dkind+=(remove);   did+=(remove);    dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) zsh")
    fi
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
    esac

    # ---- render ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "zsh · component manager" "v$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "zsh · component manager" "$(ui_t not_installed)"; fi
    local i row=3
    for (( i=0; i<n; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    if (( installed )); then ui_footer "$(_zsh_t foot_main)"
    else ui_footer "$(_zsh_t foot_install)"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in spacer|header) ;; *) break ;; esac; done ;;
      a|A)
        if (( installed )) && ui_input "$(_zsh_t prompt_add_plugin)" ""; then
          ui_run "add-plugin · zsh" -- "$0" add-plugin "$UI_INPUT"
        fi ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) zsh" -- "$0" install ;;
          remove)  ui_confirm "$(_zsh_t confirm_remove)" n && ui_run "$(ui_t remove) zsh" -- "$0" remove ;;
          framework)
            if [[ "${FRAMEWORK:-none}" == "oh-my-zsh" ]]; then ui_run "uninstall-omz · zsh" -- "$0" uninstall-omz
            else ui_run "install-omz · zsh" -- "$0" install-omz; fi ;;
          prompt)
            ui_pick "$(_zsh_t pick_prompt)" "$(_zsh_t current) ${PROMPT:-git}" "" -- \
              git "$(_zsh_t pr_git)" plain "$(_zsh_t pr_plain)" starship "$(_zsh_t pr_starship)" \
              powerlevel10k "$(_zsh_t pr_p10k)" pure "$(_zsh_t pr_pure)"
            [[ -n "$UI_PICK" ]] && ui_run "prompt $UI_PICK · zsh" -- "$0" prompt "$UI_PICK" ;;
          plugin)
            local pn="${did[$sel]}"
            if _zsh_plugin_in "$pn" "$PLUGINS"; then ui_run "remove-plugin $pn · zsh" -- "$0" remove-plugin "$pn"
            else ui_run "add-plugin $pn · zsh" -- "$0" add-plugin "$pn"; fi ;;
          omzplugin)
            local opn="${did[$sel]}"
            if _zsh_plugin_in "$opn" "$OMZ_PLUGINS"; then ui_run "remove-omz-plugin $opn · zsh" -- "$0" remove-omz-plugin "$opn"
            else ui_run "add-omz-plugin $opn · zsh" -- "$0" add-omz-plugin "$opn"; fi ;;
          omzplugin_add)
            if ui_input "$(_zsh_t prompt_omz_plugin)" ""; then
              ui_run "add-omz-plugin · zsh" -- "$0" add-omz-plugin "$UI_INPUT"
            fi ;;
          omzsetting)
            local sk="${did[$sel]}"
            case "$sk" in
              update)
                ui_pick "$(_zsh_t pick_update)" "$(_zsh_t current) $OMZ_UPDATE" "" -- \
                  disabled "$(_zsh_t up_disabled)" auto "$(_zsh_t up_auto)" reminder "$(_zsh_t up_reminder)"
                [[ -n "$UI_PICK" ]] && ui_run "omz-setting update $UI_PICK · zsh" -- "$0" omz-setting update "$UI_PICK" ;;
              hist-stamps)
                ui_pick "$(_zsh_t pick_hist)" "$(_zsh_t current) $OMZ_HIST_STAMPS" "" -- \
                  yyyy-mm-dd "yyyy-mm-dd" mm/dd/yyyy "mm/dd/yyyy" dd.mm.yyyy "dd.mm.yyyy" none "$(_zsh_t hs_none)"
                [[ -n "$UI_PICK" ]] && ui_run "omz-setting hist-stamps $UI_PICK · zsh" -- "$0" omz-setting hist-stamps "$UI_PICK" ;;
              magic)           ui_run "omz-setting magic · zsh"           -- "$0" omz-setting magic           "$(_zsh_toggle_onoff "$OMZ_MAGIC")" ;;
              untracked-dirty) ui_run "omz-setting untracked-dirty · zsh" -- "$0" omz-setting untracked-dirty "$(_zsh_toggle_onoff "$OMZ_UNTRACKED_DIRTY")" ;;
              correction)      ui_run "omz-setting correction · zsh"      -- "$0" omz-setting correction      "$(_zsh_toggle_onoff "$OMZ_CORRECTION")" ;;
              wait-dots)       ui_run "omz-setting wait-dots · zsh"       -- "$0" omz-setting wait-dots       "$(_zsh_toggle_onoff "$OMZ_WAIT_DOTS")" ;;
            esac ;;
          defshell) ui_run "default-shell · zsh" -- "$0" default-shell ;;
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

zsh component manager. State lives in ~/.config/zsh/ubuntu-setup.conf; every change
regenerates ~/.config/zsh/ubuntu-setup.zsh and is sourced from ~/.zshrc (one idempotent
line). Re-running converges; your own ~/.zshrc is never clobbered.

  install            Install zsh via apt
  remove             Uninstall zsh (refuses if it is your login shell)
  configure [opts]   Full re-spec of the whole config. Options:
                       --framework none|oh-my-zsh                 (default: none)
                       --prompt git|plain|starship|powerlevel10k|pure   (default: git)
                       --plugins "a b c"   set the enabled (kit) plugins (known names below)
                       --no-plugins · --no-aliases · --default-shell
                       --omz-plugins "git sudo …"   set OMZ-native plugins (curated below)
                       --omz-update disabled|auto|reminder        (default: disabled)
                       --omz-magic on|off · --omz-untracked-dirty on|off
                       --omz-correction on|off · --omz-wait-dots on|off
                       --omz-hist-stamps yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none
  install-omz        Install the Oh My Zsh framework
  uninstall-omz      Remove Oh My Zsh (deletes ~/.oh-my-zsh)
  add-plugin <name|git-url>   Enable a (kit) plugin (installs it). Known names:
                       $ZSH_KNOWN_PLUGINS
                     Any other value is treated as a git repo URL and cloned.
  remove-plugin <name>        Disable a (kit) plugin (removes git clones; keeps apt packages)
  add-omz-plugin <name>       Enable an Oh My Zsh-native plugin (needs OMZ). Curated:
                       $ZSH_OMZ_KNOWN_PLUGINS
                     Any plugin present in ~/.oh-my-zsh/plugins is also accepted.
  remove-omz-plugin <name>    Disable an Oh My Zsh-native plugin
  omz-setting <key> <value>   Tune one OMZ setting:
                       update disabled|auto|reminder · magic on|off
                       untracked-dirty on|off · correction on|off · wait-dots on|off
                       hist-stamps yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none
  prompt <name>      Set the prompt (git|plain|starship|powerlevel10k|pure)
  default-shell      Make zsh the default login shell (lockout-safe)
  ui                 Open the interactive component manager (needs a terminal)
  status / meta / help

Default config is a conservative, headless-safe baseline (framework-free, git-branch ASCII
prompt, autosuggestions + syntax-highlighting, color aliases). Choosing Starship/Powerlevel10k
installs the recommended Nerd Font (MesloLGS NF) on this box via fonts.sh — but glyphs render
in your LOCAL terminal, so over SSH also install/select that font on your client (run
'swkit fonts install' / 'swkit fonts ui' to manage fonts). With Oh My Zsh on, manage its
native plugins and settings via the TUI, 'swkit zsh add-omz-plugin/omz-setting', or the LLM.
EOF
}

kit_dispatch "$@"
