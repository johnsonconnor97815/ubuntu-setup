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

# Load state into FRAMEWORK / PROMPT / PLUGINS / ALIASES (with defaults).
_zsh_load_state() {
  FRAMEWORK="none"; PROMPT="git"; PLUGINS="autosuggestions syntax-highlighting"; ALIASES="1"
  [[ -f "$_ZCONF" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      FRAMEWORK) FRAMEWORK="$v" ;;
      PROMPT)    PROMPT="$v" ;;
      PLUGINS)   PLUGINS="$v" ;;
      ALIASES)   ALIASES="$v" ;;
    esac
  done <"$_ZCONF"
}

_zsh_save_state() {
  {
    printf '# ubuntu-setup zsh.sh state — managed by swkit zsh actions; do not hand-edit.\n'
    printf 'FRAMEWORK=%s\n' "$FRAMEWORK"
    printf 'PROMPT=%s\n'    "$PROMPT"
    printf 'PLUGINS=%s\n'   "$PLUGINS"
    printf 'ALIASES=%s\n'   "$ALIASES"
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
    cat <<'ZRC'
plugins=(git)
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
    starship)      _zsh_ensure_starship || return 1;
                   log_warn "Starship uses Nerd Font glyphs — install a Nerd Font in your LOCAL terminal." ;;
    powerlevel10k) _zsh_git_clone "$P10K_REPO" "$_ZPLUGDIR/powerlevel10k" "Powerlevel10k" || return 1;
                   log_warn "Powerlevel10k uses Nerd Font glyphs — install one in your LOCAL terminal.";
                   log_info "Run 'p10k configure' yourself to customize it (interactive; not run here)." ;;
    pure)          _zsh_git_clone "$PURE_REPO" "$_ZPLUGDIR/pure" "Pure prompt" || return 1 ;;
  esac
  for p in $PLUGINS; do _zsh_plugin_ensure "$p" || log_warn "Could not install plugin '$p' — its source line will be skipped."; done

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

  local default_shell=0 want_plugins=1 plugins_set=""
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
      *) log_err "Unknown configure option: $1"; return 2 ;;
    esac
  done
  case "$FRAMEWORK" in none|oh-my-zsh) ;; *) log_err "Unknown --framework '$FRAMEWORK' (none|oh-my-zsh)."; return 2 ;; esac
  case "$PROMPT" in git|plain|starship|powerlevel10k|pure) ;; *) log_err "Unknown --prompt '$PROMPT'."; return 2 ;; esac

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
                       --plugins "a b c"   set the enabled plugins (known names below)
                       --no-plugins · --no-aliases · --default-shell
  install-omz        Install the Oh My Zsh framework
  uninstall-omz      Remove Oh My Zsh (deletes ~/.oh-my-zsh)
  add-plugin <name|git-url>   Enable a plugin (installs it). Known names:
                       $ZSH_KNOWN_PLUGINS
                     Any other value is treated as a git repo URL and cloned.
  remove-plugin <name>        Disable a plugin (removes git clones; keeps apt packages)
  prompt <name>      Set the prompt (git|plain|starship|powerlevel10k|pure)
  default-shell      Make zsh the default login shell (lockout-safe)
  status / meta / help

Default config is a conservative, headless-safe baseline (framework-free, git-branch ASCII
prompt, autosuggestions + syntax-highlighting, color aliases). Starship/Powerlevel10k need a
Nerd Font in your LOCAL terminal. The TUI lists the no-argument actions; the argument-taking
ones (add-plugin/remove-plugin/prompt) are run via 'swkit zsh ...' or the LLM.
EOF
}

kit_dispatch "$@"
