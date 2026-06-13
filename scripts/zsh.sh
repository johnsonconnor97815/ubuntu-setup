#!/usr/bin/env bash
#
# scripts/zsh.sh — install / configure / manage zsh on Ubuntu.
#
# install + a SAFE baseline configuration only. Deep/opinionated config (Starship,
# Powerlevel10k, Oh My Zsh, Nerd Fonts) is NOT this script's job — that stays a
# conversation in the zsh-setup skill.

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

meta() {
  cat <<'META'
key=zsh
name=zsh
category=essentials
ops=install,remove,configure
desc=Z shell plus a safe baseline config (plugins, optional default login shell)
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

# Safe baseline configuration only:
#   [--default-shell]  make zsh the default login shell (lockout-safe; verified first)
#   [--no-plugins]     skip apt plugins and their source lines in ~/.zshrc
do_configure() {
  if ! status >/dev/null 2>&1; then
    log_info "Install zsh first."
    return 0
  fi

  local default_shell=0 want_plugins=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --default-shell) default_shell=1 ;;
      --no-plugins)    want_plugins=0 ;;
      *) log_err "Unknown configure option: $1"; return 2 ;;
    esac
    shift
  done

  # Resolve the real target user/home — never trust $HOME under sudo.
  local user home zshrc
  user="${SUDO_USER:-$(id -un)}"
  home="$(getent passwd "$user" | cut -d: -f6 || true)"
  if [[ -z "$home" ]]; then
    log_err "Could not resolve the home directory for '$user' (not in passwd?)."
    return 1
  fi
  zshrc="$home/.zshrc"

  # Plugin source paths, resolved from the live package layout (never hardcoded).
  local autosuggest_src="" syntax_src=""
  if [[ "$want_plugins" -eq 1 ]]; then
    apt_install zsh-autosuggestions zsh-syntax-highlighting
    autosuggest_src="$(dpkg -L zsh-autosuggestions 2>/dev/null | grep -m1 '\.zsh$' || true)"
    syntax_src="$(dpkg -L zsh-syntax-highlighting 2>/dev/null | grep -m1 '\.zsh$' || true)"
    [[ -n "$autosuggest_src" ]] || log_warn "Could not locate zsh-autosuggestions source file — skipping its source line."
    [[ -n "$syntax_src" ]] || log_warn "Could not locate zsh-syntax-highlighting source file — skipping its source line."
  fi

  # Write ~/.zshrc as the user — NEVER sudo (it must stay user-owned). Writing a full
  # file also prevents the zsh-newuser-install wizard from hanging a non-interactive
  # session. Idempotent via the marker.
  local marker="# managed by ubuntu-setup zsh.sh"
  if [[ -f "$zshrc" ]] && grep -qF "$marker" "$zshrc"; then
    log_info "$zshrc already managed by zsh.sh — leaving it untouched."
  else
    backup_file "$zshrc"
    {
      printf '%s\n\n' "$marker"

      printf '# ---- History ----\n'
      # Literal $HOME — must expand at shell-startup time, not now.
      # shellcheck disable=SC2016
      printf 'HISTFILE="$HOME/.zsh_history"\n'
      printf 'HISTSIZE=50000\n'
      printf 'SAVEHIST=50000\n'
      printf 'setopt SHARE_HISTORY\n'
      printf 'setopt HIST_IGNORE_DUPS\n'
      printf 'setopt HIST_IGNORE_SPACE\n'
      printf 'setopt HIST_REDUCE_BLANKS\n'
      printf 'setopt EXTENDED_HISTORY\n\n'

      printf '# ---- Sensible options ----\n'
      printf 'setopt AUTO_CD\n'
      printf 'setopt AUTO_PUSHD PUSHD_IGNORE_DUPS\n'
      printf 'setopt INTERACTIVE_COMMENTS\n'
      printf 'setopt NO_BEEP\n'
      printf 'bindkey -e\n\n'

      printf '# ---- Completion ----\n'
      printf 'autoload -Uz compinit\n'
      printf 'compinit\n'
      printf "zstyle ':completion:*' menu select\n"
      printf "zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'\n\n"

      if [[ "$want_plugins" -eq 1 ]]; then
        printf '# ---- Plugins (paths from dpkg -L) ----\n'
        # zsh-autosuggestions FIRST.
        [[ -n "$autosuggest_src" ]] && printf 'source %s\n' "$autosuggest_src"
        # zsh-syntax-highlighting MUST be sourced LAST of all.
        [[ -n "$syntax_src" ]] && printf 'source %s\n' "$syntax_src"
      fi
    } >"$zshrc"
    log_info "Wrote baseline $zshrc (backed up any previous version)."
  fi

  if [[ "$default_shell" -eq 1 ]]; then
    local zsh_path
    zsh_path="$(command -v zsh)"
    # Lockout safety: never set a login shell that doesn't start cleanly.
    if ! zsh -i -c exit >/dev/null 2>&1; then
      log_err "An interactive zsh did not start cleanly ('zsh -i -c exit' failed)."
      log_err "Not changing the login shell. Fix $zshrc first, then re-run with --default-shell."
      return 1
    fi
    # Ensure zsh is an allowed login shell (idempotent).
    if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
      printf '%s\n' "$zsh_path" | sudo_run tee -a /etc/shells >/dev/null
    fi
    # Already the login shell? Then nothing to change.
    local current
    current="$(getent passwd "$user" | cut -d: -f7 || true)"
    if [[ "$current" == "$zsh_path" ]]; then
      log_info "zsh is already the login shell for '$user'."
    else
      sudo_run chsh -s "$zsh_path" "$user"
      log_info "Set zsh as login shell for '$user' — takes effect on next login."
      log_info "Keep this session open; try now with: exec zsh"
    fi
  fi
}

usage() {
  cat <<EOF
Usage: ${0##*/} <command>

Commands:
  install    Install zsh via apt (idempotent)
  remove     Uninstall zsh (refuses if it is your login shell — chsh back to bash first)
  configure [--default-shell] [--no-plugins]
             Write a safe baseline ~/.zshrc (history, completion, apt plugins) as the
             user; with --default-shell, make zsh the default login shell only after a
             clean 'zsh -i -c exit'. Idempotent.
  status     Print 'zsh --version'; exit 0 iff installed
  meta       Print machine-readable metadata
  help       Show this help
EOF
}

kit_dispatch "$@"
