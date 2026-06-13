#!/usr/bin/env bash
#
# scripts/zsh.sh — install / configure / manage zsh on Ubuntu.
#
# `configure` is a MANAGEABLE config tool, not a one-time write: it (re)generates a
# managed drop-in `~/.config/zsh/ubuntu-setup.zsh` wholesale on every run and sources it
# from `~/.zshrc` via a single idempotent line, so re-running converges to the latest
# settings without clobbering the user's own `~/.zshrc`. It covers a rich, headless-safe
# baseline (history/options/completion/keybindings/aliases) plus, on request, common
# setups: frameworks (Oh My Zsh) and prompts (git / plain / Starship / Powerlevel10k /
# Pure), and can make zsh the default login shell (lockout-safe).
#
# Extra actions (shown in the TUI / swkit and routed by kit_dispatch): `oh-my-zsh`,
# `starship`, `default-shell` — thin presets over `configure` / the shell switch.
#
# Files are written AS THE USER, never via sudo. Only the login-shell change escalates,
# per command, via sudo_run.

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly OMZ_INSTALL_URL="https://github.com/ohmyzsh/ohmyzsh/raw/master/tools/install.sh"
readonly STARSHIP_INSTALL_URL="https://starship.rs/install.sh"
readonly P10K_REPO="https://github.com/romkatv/powerlevel10k"
readonly PURE_REPO="https://github.com/sindresorhus/pure"
readonly ZSH_OLD_MARKER="# managed by ubuntu-setup zsh.sh"

meta() {
  cat <<'META'
key=zsh
name=zsh
category=essentials
ops=install,remove,configure,oh-my-zsh,starship,default-shell
desc=Z shell + managed config (frameworks: Oh My Zsh; prompts: git/starship/p10k/pure) + default login shell
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
  # Lockout guard: removing zsh while it is someone's login shell breaks their login.
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
    log_err "Switch back to bash first:  chsh -s /bin/bash"
    log_err "(then re-run this remove), and verify with: getent passwd \"$user\" | cut -d: -f7"
    return 1
  fi
  apt_remove zsh
}

# --- Idempotent installers for frameworks / prompts (run as the user) ----------

_zsh_ensure_omz() {
  local home="$1"
  if [[ -d "$home/.oh-my-zsh" ]]; then
    log_info "Oh My Zsh already installed ($home/.oh-my-zsh) — skipping."
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates
  log_info "Installing Oh My Zsh via the official installer: $OMZ_INSTALL_URL"
  log_info "(unattended, keeping your ~/.zshrc — no shell change)."
  # --unattended: no chsh, no interactive shell launch; --keep-zshrc: don't touch ~/.zshrc.
  ZSH="$home/.oh-my-zsh" RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL "$OMZ_INSTALL_URL")" "" --unattended --keep-zshrc
}

_zsh_ensure_starship() {
  local home="$1"
  if have_cmd starship; then
    log_info "Starship already installed ($(starship --version 2>/dev/null | head -n1)) — skipping."
    return 0
  fi
  have_cmd curl || apt_install curl ca-certificates
  mkdir -p "$home/.local/bin"   # the installer requires the bin dir to already exist
  log_info "Installing Starship via the official installer ($STARSHIP_INSTALL_URL) into ~/.local/bin (no sudo)."
  if ! curl -fsSL "$STARSHIP_INSTALL_URL" | sh -s -- --bin-dir "$home/.local/bin" --yes; then
    log_err "Starship installation failed (see output above)."
    return 1
  fi
  ensure_local_bin_on_path
}

_zsh_ensure_git_clone() {
  local repo="$1" dir="$2" what="$3"
  if [[ -d "$dir/.git" ]]; then
    log_info "$what already present ($dir) — skipping."
    return 0
  fi
  have_cmd git || apt_install git
  log_info "Cloning $what: $repo -> $dir"
  git clone --depth=1 "$repo" "$dir"
}

# --- Migrate the old whole-file ~/.zshrc to the drop-in model ------------------

_zsh_migrate_old_zshrc() {
  local zshrc="$1" first=""
  [[ -f "$zshrc" ]] || return 0
  IFS= read -r first <"$zshrc" || first=""
  [[ "$first" == "$ZSH_OLD_MARKER" ]] || return 0
  backup_file "$zshrc"
  : >"$zshrc"
  log_warn "Migrated an older fully-managed ~/.zshrc to the new drop-in model."
  log_warn "It was backed up to ${zshrc}.bak.* — if you had added personal lines, copy"
  log_warn "them from the backup into ~/.zshrc (it is sourced before the managed drop-in)."
}

# --- Emit the managed drop-in to stdout ----------------------------------------
# Args: framework prompt want_plugins want_aliases autosuggest_src syntax_src p10k_dir pure_dir
# Static sections use quoted heredocs (literal $HOME/$terminfo, expanded at shell start);
# dynamic lines use printf so paths/values are interpolated now.
_zsh_emit_dropin() {
  local fw="$1" prompt="$2" want_plugins="$3" want_aliases="$4"
  local autosuggest_src="$5" syntax_src="$6" p10k_dir="$7" pure_dir="$8"

  cat <<'ZRC'
# ubuntu-setup zsh.sh — managed drop-in. DO NOT EDIT.
# Regenerated wholesale on every `zsh configure`. Put personal settings in ~/.zshrc
# (sourced before this file); remove its source line there to disable this.

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

  if [[ "$fw" == "oh-my-zsh" ]]; then
    # Oh My Zsh runs its own compinit, sets the theme and loads plugins. An external
    # prompt (starship/p10k/pure) overrides the theme, so blank it in that case.
    local omz_theme="robbyrussell"
    case "$prompt" in starship|powerlevel10k|pure) omz_theme="" ;; esac
    cat <<'ZRC'

# ---- Oh My Zsh ----
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

  if [[ "$want_aliases" -eq 1 ]]; then
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

  case "$prompt" in
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
      printf '[[ -r "%s/powerlevel10k.zsh-theme" ]] && source "%s/powerlevel10k.zsh-theme"\n' "$p10k_dir" "$p10k_dir"
      # Literal $HOME — expands at shell-startup time.
      # shellcheck disable=SC2016
      printf '[[ -r "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"\n'
      ;;
    pure)
      printf '\n# ---- Prompt (Pure) ----\n'
      printf 'fpath+=("%s")\n' "$pure_dir"
      printf 'autoload -Uz promptinit && promptinit\nprompt pure\n'
      ;;
  esac

  if [[ "$want_plugins" -eq 1 ]]; then
    cat <<'ZRC'

# ---- Plugins (sourced last; syntax-highlighting must be final) ----
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=20
ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets)
ZRC
    [[ -n "$autosuggest_src" ]] && printf 'source %s\n' "$autosuggest_src"
    [[ -n "$syntax_src" ]] && printf 'source %s\n' "$syntax_src"
  fi

  # Always end with a clean exit status — the prompt/plugin guards above can leave a
  # non-zero $? (e.g. a missing optional file), which would otherwise trip a `zsh -i -c
  # exit`-style check by whatever sources this file.
  printf '\ntrue\n'
}

# --- configure -----------------------------------------------------------------

do_configure() {
  if ! status >/dev/null 2>&1; then
    log_info "Install zsh first."
    return 0
  fi

  local framework="none" prompt="git" default_shell=0 want_plugins=1 want_aliases=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --framework)   framework="${2:-}"; shift 2 || { log_err "--framework needs a value (none|oh-my-zsh)."; return 2; } ;;
      --framework=*) framework="${1#--framework=}"; shift ;;
      --prompt)      prompt="${2:-}"; shift 2 || { log_err "--prompt needs a value."; return 2; } ;;
      --prompt=*)    prompt="${1#--prompt=}"; shift ;;
      --default-shell) default_shell=1; shift ;;
      --no-plugins)  want_plugins=0; shift ;;
      --no-aliases)  want_aliases=0; shift ;;
      *) log_err "Unknown configure option: $1"; return 2 ;;
    esac
  done
  case "$framework" in
    none|oh-my-zsh) ;;
    *) log_err "Unknown --framework '$framework' (expected: none|oh-my-zsh)."; return 2 ;;
  esac
  case "$prompt" in
    git|plain|starship|powerlevel10k|pure) ;;
    *) log_err "Unknown --prompt '$prompt' (expected: git|plain|starship|powerlevel10k|pure)."; return 2 ;;
  esac

  # Files must stay user-owned — refuse a sudo-wrapped run (only --default-shell needs
  # root, and it escalates per-command). Genuine root configuring root's own dotfiles is ok.
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run 'zsh configure' as your normal user, not via sudo — ~/.zshrc and the"
    log_err "managed drop-in must stay user-owned. (Only the login-shell change needs root.)"
    return 1
  fi
  # Sudo-wrap is refused above, so $HOME is the invoking user's real home — the correct,
  # standard target for a dotfile tool (and it makes the flow sandbox-testable). Fall back
  # to the passwd entry only if $HOME is somehow unset.
  local user home zshrc dropin_dir dropin p10k_dir pure_dir
  user="${SUDO_USER:-$(id -un)}"
  home="${HOME:-}"
  [[ -n "$home" ]] || home="$(getent passwd "$user" | cut -d: -f6 || true)"
  if [[ -z "$home" ]]; then
    log_err "Could not resolve the home directory for '$user'."
    return 1
  fi
  zshrc="$home/.zshrc"
  dropin_dir="$home/.config/zsh"
  dropin="$dropin_dir/ubuntu-setup.zsh"
  p10k_dir="$dropin_dir/powerlevel10k"
  pure_dir="$dropin_dir/pure"
  mkdir -p "$dropin_dir" "$home/.cache/zsh"

  # The single, guarded source line in ~/.zshrc. Literal $HOME expands at shell start.
  # shellcheck disable=SC2016
  local source_line='[[ -f "$HOME/.config/zsh/ubuntu-setup.zsh" ]] && source "$HOME/.config/zsh/ubuntu-setup.zsh"'

  # Migrate an old whole-file ~/.zshrc, then ensure our source line exists BEFORE
  # installing a framework (so Oh My Zsh's --keep-zshrc keeps our ~/.zshrc, not its own).
  _zsh_migrate_old_zshrc "$zshrc"
  append_once "$source_line" "$zshrc"

  # Install the selected framework / prompt (each idempotent, run as the user).
  if [[ "$framework" == "oh-my-zsh" ]]; then
    _zsh_ensure_omz "$home" || return 1
  fi
  case "$prompt" in
    starship)
      _zsh_ensure_starship "$home" || return 1
      log_warn "Starship uses Nerd Font glyphs — install a Nerd Font in your LOCAL terminal for icons."
      ;;
    powerlevel10k)
      _zsh_ensure_git_clone "$P10K_REPO" "$p10k_dir" "Powerlevel10k" || return 1
      log_warn "Powerlevel10k uses Nerd Font glyphs — install a Nerd Font in your LOCAL terminal."
      log_info "Run 'p10k configure' yourself to customize it (interactive; not run here)."
      ;;
    pure)
      _zsh_ensure_git_clone "$PURE_REPO" "$pure_dir" "Pure prompt" || return 1
      ;;
  esac

  # Resolve apt plugin source paths from the live package layout (never hardcoded).
  local autosuggest_src="" syntax_src=""
  if [[ "$want_plugins" -eq 1 ]]; then
    apt_install zsh-autosuggestions zsh-syntax-highlighting
    # Match the package's MAIN entry-point file by name — never just the first *.zsh
    # (zsh-syntax-highlighting also ships highlighter sub-files that must NOT be sourced directly).
    autosuggest_src="$(dpkg -L zsh-autosuggestions 2>/dev/null | grep -m1 '/zsh-autosuggestions\.zsh$' || true)"
    syntax_src="$(dpkg -L zsh-syntax-highlighting 2>/dev/null | grep -m1 '/zsh-syntax-highlighting\.zsh$' || true)"
    [[ -n "$autosuggest_src" ]] || log_warn "Could not locate zsh-autosuggestions source — skipping it."
    [[ -n "$syntax_src" ]] || log_warn "Could not locate zsh-syntax-highlighting source — skipping it."
  fi

  # (Re)generate the managed drop-in wholesale — re-running converges to the latest.
  backup_file "$dropin"
  _zsh_emit_dropin "$framework" "$prompt" "$want_plugins" "$want_aliases" \
    "$autosuggest_src" "$syntax_src" "$p10k_dir" "$pure_dir" >"$dropin"
  log_info "Wrote managed drop-in $dropin (framework=$framework, prompt=$prompt)."
  log_info "Re-run 'zsh configure …' anytime to update; your own ~/.zshrc edits are kept."

  if [[ "$default_shell" -eq 1 ]]; then
    do_default_shell || return 1
  fi
}

# --- Presets (extra TUI/swkit actions; routed by kit_dispatch) -----------------

do_oh_my_zsh() { do_configure --framework oh-my-zsh "$@"; }   # action: oh-my-zsh
do_starship()  { do_configure --prompt starship "$@"; }       # action: starship

# Make zsh the default login shell — lockout-safe, escalating per command. Used both as
# the `default-shell` action and by `configure --default-shell`.
do_default_shell() {
  if ! status >/dev/null 2>&1; then
    log_info "Install zsh first."
    return 0
  fi
  local user zsh_path current
  user="${SUDO_USER:-$(id -un)}"
  zsh_path="$(command -v zsh)"
  # Lockout safety: never set a login shell that hangs or hard-fails to start. timeout
  # guards against a hang (a stray compinit/newuser prompt); 'exit 0' ignores a benign
  # non-zero status left by the last startup line.
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

Commands:
  install         Install zsh via apt (idempotent)
  remove          Uninstall zsh (refuses if it is your login shell — chsh to bash first)
  configure [opts]  (Re)generate a managed drop-in ~/.config/zsh/ubuntu-setup.zsh and
                  source it from ~/.zshrc (one idempotent line). Re-running updates the
                  managed settings without clobbering your own ~/.zshrc. Options:
                    --framework none|oh-my-zsh        (default: none)
                    --prompt git|plain|starship|powerlevel10k|pure   (default: git)
                    --default-shell                   also make zsh the login shell
                    --no-plugins                      skip apt autosuggest/syntax plugins
                    --no-aliases                      skip the ls/grep color aliases
  oh-my-zsh       Preset: configure with the Oh My Zsh framework
  starship        Preset: configure with the Starship prompt
  default-shell   Make zsh the default login shell (lockout-safe)
  status          Print 'zsh --version'; exit 0 iff installed
  meta            Print machine-readable metadata
  help            Show this help

Default 'configure' (and the TUI's Configure action) is a conservative, headless-safe
baseline: framework-free, a git-branch ASCII prompt, apt plugins, color aliases. Icon
prompts (starship/powerlevel10k) need a Nerd Font in your LOCAL terminal.
EOF
}

kit_dispatch "$@"
