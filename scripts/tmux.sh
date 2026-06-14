#!/usr/bin/env bash
#
# scripts/tmux.sh — install / configure / manage tmux on Ubuntu, as a COMPONENT MANAGER.
#
# Beyond installing tmux, this script manages tmux's ecosystem as discrete, independently
# toggle-able components — the Tmux Plugin Manager (TPM), a curated set of popular plugins,
# a theme, and a broad set of best-practice OPTIONS (mouse, clipboard, vi copy mode, scrollback,
# escape-time, status bar, ergonomic keybindings, …) — tracking everything in a small
# KEY=VALUE state file (~/.config/ubuntu-setup/tmux.conf). Every change regenerates a single
# MANAGED BLOCK inside the user's ~/.tmux.conf (delimited by markers, rewritten wholesale,
# convergent) while preserving everything the user wrote OUTSIDE the markers.
#
# Why a managed block (not a separate sourced drop-in, unlike zsh.sh/ghostty.sh): TPM
# discovers plugins by reading the `set -g @plugin '...'` lines in the MAIN tmux config file
# (~/.tmux.conf or $XDG_CONFIG_HOME/tmux/tmux.conf) — it does NOT follow `source-file` into an
# included file. So the @plugin declarations and the final `run '.../tpm'` line must live in
# ~/.tmux.conf itself; the marker block is how we own a region there without clobbering the
# rest. Plugin install/update/clean is driven non-interactively via TPM's bin/ scripts
# (install_plugins / update_plugins / clean_plugins), which work without a running tmux server.
#
# The settings are grounded in widely-recommended tmux best practices (escape-time for
# vim/neovim, 1-based indexing, true-color, OSC52 clipboard, vi copy bindings, split/nav
# keybindings, …) and are all exposed as quick toggles/pickers/inputs in the ui().
#
# Actions (kit_dispatch routes <op> -> do_<op>, hyphens -> underscores):
#   install / remove / status            tmux itself (apt)
#   configure [flags]                    re-spec options/plugins/theme (see usage); --recommended
#   install-tpm / uninstall-tpm          install / remove the Tmux Plugin Manager
#   update-plugins                       update all installed plugins (TPM)
#   add-plugin <name|owner/repo|git-url> enable a plugin (curated name or any git repo)
#   remove-plugin <name>                 disable a plugin (removes its clone)
#   theme <none|catppuccin|dracula|themepack> [flavor]   set the theme
#
# Files are written AS THE USER, never via sudo (~/.tmux.conf, ~/.tmux/plugins, the state
# file). Only `apt install/remove tmux` escalates, per command, via the lib's sudo_run.
# tmux is a terminal multiplexer (not a GUI app): it works perfectly headless / over SSH.
#
# Run it as:  tmux.sh install|remove|configure|status|meta|ui|help   (or via `swkit`).

set -Eeuo pipefail

# Locate and load the shared library (scripts/ sits next to lib/ under the kit root).
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"

readonly TPM_REPO="https://github.com/tmux-plugins/tpm"

# Curated, first-class plugin keys (short names). Anything else add-plugin accepts as an
# arbitrary "owner/repo", "owner/repo#branch", or git URL (TPM clones it the same way).
readonly TMUX_KNOWN_PLUGINS="sensible resurrect continuum yank pain-control vim-navigator open fzf battery cpu prefix-highlight"

# The popular "batteries-included" set applied by `configure --recommended` (and the UI's
# "Apply recommended setup" row) — a conservative bare `configure` enables NONE of these.
readonly TMUX_RECOMMENDED_PLUGINS="sensible resurrect continuum yank pain-control"

# Markers delimiting the region we own inside ~/.tmux.conf. Matched as EXACT lines.
readonly TMUX_BLOCK_BEGIN="# >>> ubuntu-setup tmux (managed block) >>>"
readonly TMUX_BLOCK_END="# <<< ubuntu-setup tmux (managed block) <<<"

meta() {
  cat <<'META'
key=tmux
name=tmux
category=common
ops=install,remove,configure,install-tpm,uninstall-tpm,update-plugins
desc=Terminal multiplexer — component manager: TPM, curated plugins, themes, best-practice settings
META
}

status() { have_cmd tmux && tmux -V; }

do_install() {
  if status >/dev/null 2>&1; then
    log_info "tmux already installed ($(tmux -V 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install tmux
}

do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "tmux is not installed — nothing to remove."
    return 0
  fi
  apt_remove tmux
  log_info "Removed the tmux package (apt remove keeps your ~/.tmux.conf, ~/.tmux/plugins and TPM)."
  log_info "Delete those by hand if you want a clean slate."
}

# --- Target user / home + state ------------------------------------------------
# Sets globals: _THOME _TCONF _TPREF _TPREF_DIR _TPLUGDIR _TPM_DIR. Refuses a sudo-wrapped run
# so dotfiles stay user-owned. $HOME is correct in the (only allowed) non-sudo case.
_tmux_resolve_paths() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    log_err "Run tmux configuration as your normal user, not via sudo — ~/.tmux.conf and the"
    log_err "managed files must stay user-owned. (Only 'apt install/remove tmux' needs root.)"
    return 1
  fi
  local user; user="${SUDO_USER:-$(id -un)}"
  _THOME="${HOME:-}"
  [[ -n "$_THOME" ]] || _THOME="$(getent passwd "$user" | cut -d: -f6 || true)"
  [[ -n "$_THOME" ]] || { log_err "Could not resolve the home directory for '$user'."; return 1; }
  _TCONF="$_THOME/.tmux.conf"                       # the user's real tmux config (we own a marked block)
  _TPREF_DIR="$_THOME/.config/ubuntu-setup"
  _TPREF="$_TPREF_DIR/tmux.conf"                    # the kit's own KEY=VALUE preference store
  _TPLUGDIR="$_THOME/.tmux/plugins"
  _TPM_DIR="$_TPLUGDIR/tpm"
  mkdir -p "$_TPREF_DIR" "$_TPLUGDIR"
}

# --- Validation ----------------------------------------------------------------
_tmux_valid_onoff()      { case "$1" in on|off) return 0 ;; *) return 1 ;; esac; }
_tmux_valid_keymode()    { case "$1" in vi|emacs) return 0 ;; *) return 1 ;; esac; }
_tmux_valid_theme()      { case "$1" in none|catppuccin|dracula|themepack) return 0 ;; *) return 1 ;; esac; }
_tmux_valid_status_pos() { case "$1" in top|bottom) return 0 ;; *) return 1 ;; esac; }
_tmux_valid_int()        { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
_tmux_valid_key()        { case "$1" in ''|*[[:space:]]*) return 1 ;; *) return 0 ;; esac; }
# A modifier chord (C-/M-/S-…) is meant as a DIRECT shortcut (bound with no prefix); a plain
# key (v, w) is bound under the prefix. Used to decide `bind` vs `bind -n` for the entry keys.
_tmux_key_is_chord()     { case "$1" in [CMS]-*) return 0 ;; *) return 1 ;; esac; }

# --- Preference store ----------------------------------------------------------
# Conservative defaults: a tasteful best-practice baseline (mouse, vi mode, true-color, big
# scrollback, low escape-time, 1-based indexing) but NO plugins / NO theme / NO ergonomic
# keybinding remaps / NO TPM (a bare `configure` is a safe headless baseline that does not
# touch the network or rebind keys). The popular bundle is one `--recommended` away.
_tmux_defaults() {
  PLUGINS=""
  THEME="none"; THEME_FLAVOR="mocha"
  MOUSE="on"; KEYMODE="vi"; PREFIX="default"
  HISTORY="50000"; ESCAPE_TIME="10"
  BASE_INDEX="on"; RENUMBER="on"; FOCUS_EVENTS="on"
  AGGRESSIVE_RESIZE="off"; CLIPBOARD="on"
  STATUS_POSITION="bottom"; STATUS_INTERVAL="5"
  MONITOR_ACTIVITY="off"; SET_TITLES="off"; KEYBINDINGS="off"
  WINDOW_NAV="off"; COPY_MODE_KEY="default"; TREE_KEY="default"
}

_tmux_load_state() {
  _tmux_defaults
  [[ -f "${_TPREF:-}" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      PLUGINS)           PLUGINS="$v" ;;
      THEME)             THEME="$v" ;;
      THEME_FLAVOR)      THEME_FLAVOR="$v" ;;
      MOUSE)             _tmux_valid_onoff "$v" && MOUSE="$v" ;;
      KEYMODE)           _tmux_valid_keymode "$v" && KEYMODE="$v" ;;
      PREFIX)            PREFIX="$v" ;;
      HISTORY)           _tmux_valid_int "$v" && HISTORY="$v" ;;
      ESCAPE_TIME)       _tmux_valid_int "$v" && ESCAPE_TIME="$v" ;;
      BASE_INDEX)        _tmux_valid_onoff "$v" && BASE_INDEX="$v" ;;
      RENUMBER)          _tmux_valid_onoff "$v" && RENUMBER="$v" ;;
      FOCUS_EVENTS)      _tmux_valid_onoff "$v" && FOCUS_EVENTS="$v" ;;
      AGGRESSIVE_RESIZE) _tmux_valid_onoff "$v" && AGGRESSIVE_RESIZE="$v" ;;
      CLIPBOARD)         _tmux_valid_onoff "$v" && CLIPBOARD="$v" ;;
      STATUS_POSITION)   _tmux_valid_status_pos "$v" && STATUS_POSITION="$v" ;;
      STATUS_INTERVAL)   _tmux_valid_int "$v" && STATUS_INTERVAL="$v" ;;
      MONITOR_ACTIVITY)  _tmux_valid_onoff "$v" && MONITOR_ACTIVITY="$v" ;;
      SET_TITLES)        _tmux_valid_onoff "$v" && SET_TITLES="$v" ;;
      KEYBINDINGS)       _tmux_valid_onoff "$v" && KEYBINDINGS="$v" ;;
      WINDOW_NAV)        _tmux_valid_onoff "$v" && WINDOW_NAV="$v" ;;
      COPY_MODE_KEY)     _tmux_valid_key "$v" && COPY_MODE_KEY="$v" ;;
      TREE_KEY)          _tmux_valid_key "$v" && TREE_KEY="$v" ;;
    esac
  done <"$_TPREF"
}

_tmux_save_state() {
  mkdir -p "$_TPREF_DIR"
  {
    printf '# ubuntu-setup tmux.sh state — managed by swkit tmux actions; do not hand-edit.\n'
    printf 'PLUGINS=%s\n'           "$PLUGINS"
    printf 'THEME=%s\n'             "$THEME"
    printf 'THEME_FLAVOR=%s\n'      "$THEME_FLAVOR"
    printf 'MOUSE=%s\n'             "$MOUSE"
    printf 'KEYMODE=%s\n'           "$KEYMODE"
    printf 'PREFIX=%s\n'            "$PREFIX"
    printf 'HISTORY=%s\n'           "$HISTORY"
    printf 'ESCAPE_TIME=%s\n'       "$ESCAPE_TIME"
    printf 'BASE_INDEX=%s\n'        "$BASE_INDEX"
    printf 'RENUMBER=%s\n'          "$RENUMBER"
    printf 'FOCUS_EVENTS=%s\n'      "$FOCUS_EVENTS"
    printf 'AGGRESSIVE_RESIZE=%s\n' "$AGGRESSIVE_RESIZE"
    printf 'CLIPBOARD=%s\n'         "$CLIPBOARD"
    printf 'STATUS_POSITION=%s\n'   "$STATUS_POSITION"
    printf 'STATUS_INTERVAL=%s\n'   "$STATUS_INTERVAL"
    printf 'MONITOR_ACTIVITY=%s\n'  "$MONITOR_ACTIVITY"
    printf 'SET_TITLES=%s\n'        "$SET_TITLES"
    printf 'KEYBINDINGS=%s\n'       "$KEYBINDINGS"
    printf 'WINDOW_NAV=%s\n'        "$WINDOW_NAV"
    printf 'COPY_MODE_KEY=%s\n'     "$COPY_MODE_KEY"
    printf 'TREE_KEY=%s\n'          "$TREE_KEY"
  } >"$_TPREF"
}

# --- Plugin/theme resolution ---------------------------------------------------

# Membership test: is $1 a word in the space-separated list $2?
_tmux_list_has() {
  local needle="$1" hay=" $2 "
  [[ "$hay" == *" $needle "* ]]
}

# Map a curated short name to its GitHub "owner/repo". Non-zero for anything else.
_tmux_known_spec() {
  case "$1" in
    sensible)         printf 'tmux-plugins/tmux-sensible' ;;
    resurrect)        printf 'tmux-plugins/tmux-resurrect' ;;
    continuum)        printf 'tmux-plugins/tmux-continuum' ;;
    yank)             printf 'tmux-plugins/tmux-yank' ;;
    pain-control)     printf 'tmux-plugins/tmux-pain-control' ;;
    vim-navigator)    printf 'christoomey/vim-tmux-navigator' ;;
    open)             printf 'tmux-plugins/tmux-open' ;;
    fzf)              printf 'sainnhe/tmux-fzf' ;;
    battery)          printf 'tmux-plugins/tmux-battery' ;;
    cpu)              printf 'tmux-plugins/tmux-cpu' ;;
    prefix-highlight) printf 'tmux-plugins/tmux-prefix-highlight' ;;
    *) return 1 ;;
  esac
}

# A one-line description of a curated plugin (for the UI). Empty for unknown keys.
_tmux_known_desc() {
  case "$1" in
    sensible)         printf 'sane defaults everyone agrees on' ;;
    resurrect)        printf 'save/restore sessions across reboots' ;;
    continuum)        printf 'auto-save sessions every 15 min' ;;
    yank)             printf 'copy to the system clipboard' ;;
    pain-control)     printf 'standard pane split/resize bindings' ;;
    vim-navigator)    printf 'Ctrl-h/j/k/l across vim + tmux' ;;
    open)             printf 'open highlighted URLs / files' ;;
    fzf)              printf 'fuzzy-find sessions/windows/panes' ;;
    battery)          printf 'battery indicator in the status bar' ;;
    cpu)              printf 'CPU indicator in the status bar' ;;
    prefix-highlight) printf 'show when prefix is pressed' ;;
    *)                printf '' ;;
  esac
}

# Resolve a plugin key to the spec TPM understands (curated -> owner/repo; else the key is
# already an "owner/repo[#branch]" or git URL).
_tmux_plugin_spec() {
  local s
  if s="$(_tmux_known_spec "$1")"; then printf '%s' "$s"; else printf '%s' "$1"; fi
}

# The on-disk plugin directory name TPM uses = basename of the repo (sans #branch and .git).
_tmux_plugin_dir() {
  local spec; spec="$(_tmux_plugin_spec "$1")"
  spec="${spec%%#*}"; spec="${spec%.git}"
  printf '%s' "${spec##*/}"
}

# The plugin spec for a theme (none/unknown -> non-zero, no theme plugin).
_tmux_theme_spec() {
  case "$1" in
    catppuccin) printf 'catppuccin/tmux' ;;
    dracula)    printf 'dracula/tmux' ;;
    themepack)  printf 'jimeh/tmux-themepack' ;;
    *) return 1 ;;
  esac
}

# --- TPM (Tmux Plugin Manager) -------------------------------------------------
_tmux_tpm_installed() { [[ -f "${_TPM_DIR:-/nonexistent}/tpm" ]]; }

_tmux_ensure_tpm() {
  _tmux_tpm_installed && return 0
  have_cmd git || apt_install git
  log_info "Installing Tmux Plugin Manager (TPM): $TPM_REPO -> $_TPM_DIR"
  git clone --depth=1 "$TPM_REPO" "$_TPM_DIR"
}

# Drive TPM's command-line interface (works without a running tmux server). Best-effort:
# a failure only warns — re-running is the recovery, or the user can press <prefix> I in tmux.
_tmux_run_install_plugins() {
  _tmux_tpm_installed || return 0
  [[ -x "$_TPM_DIR/bin/install_plugins" ]] || { log_warn "TPM has no bin/install_plugins — skipping plugin clone."; return 0; }
  log_info "Installing declared plugins via TPM (bin/install_plugins)…"
  "$_TPM_DIR/bin/install_plugins" || log_warn "TPM could not install some plugins (see above) — re-run, or open tmux and press <prefix> I."
}

_tmux_run_clean_plugins() {
  _tmux_tpm_installed || return 0
  [[ -x "$_TPM_DIR/bin/clean_plugins" ]] || return 0
  log_info "Removing plugins no longer declared (bin/clean_plugins)…"
  "$_TPM_DIR/bin/clean_plugins" || log_warn "TPM clean reported a problem (see above)."
}

# --- Managed block generation --------------------------------------------------

# Emit the whole managed block to stdout (markers included). The plugin section (the @plugin
# declarations + TPM bootstrap/init) is emitted only when TPM is actually installed, so
# `uninstall-tpm` cleanly drops it while the user's plugin selection is preserved in state.
_tmux_emit_block() {
  printf '%s\n' "$TMUX_BLOCK_BEGIN"
  cat <<'TMUXHEAD'
# Managed by ubuntu-setup (swkit tmux). Do NOT edit between these markers — this block is
# regenerated wholesale on every change. Put personal tmux config OUTSIDE the markers; it is
# always preserved. Manage options/plugins/theme with:  swkit tmux   (or: swkit tmux <action>)
TMUXHEAD

  printf '\n# ---- General ----\n'
  printf 'set -g mouse %s\n'           "$MOUSE"
  printf 'setw -g mode-keys %s\n'      "$KEYMODE"
  printf 'set -g history-limit %s\n'   "$HISTORY"
  printf 'set -sg escape-time %s\n'    "$ESCAPE_TIME"
  printf 'set -g set-clipboard %s\n'   "$CLIPBOARD"
  [[ "$BASE_INDEX" == on ]]        && printf 'set -g base-index 1\nsetw -g pane-base-index 1\n'
  [[ "$RENUMBER" == on ]]          && printf 'set -g renumber-windows on\n'
  [[ "$FOCUS_EVENTS" == on ]]      && printf 'set -g focus-events on\n'
  [[ "$AGGRESSIVE_RESIZE" == on ]] && printf 'setw -g aggressive-resize on\n'
  [[ "$MONITOR_ACTIVITY" == on ]]  && printf 'setw -g monitor-activity on\nset -g visual-activity off\n'
  [[ "$SET_TITLES" == on ]]        && printf 'set -g set-titles on\nset -g set-titles-string "#S  #I:#W"\n'

  cat <<'TMUXSTATIC'

# ---- Colors / true color ----
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB,*256col*:RGB,alacritty:RGB,xterm-ghostty:RGB"
set -g display-time 2000
set -g display-panes-time 2000

# ---- Reload (prefix r) ----
bind r source-file ~/.tmux.conf \; display-message "tmux.conf reloaded"
TMUXSTATIC

  printf '\n# ---- Status bar ----\n'
  printf 'set -g status-position %s\n' "$STATUS_POSITION"
  printf 'set -g status-interval %s\n' "$STATUS_INTERVAL"

  if [[ -n "$PREFIX" && "$PREFIX" != "default" && "$PREFIX" != "C-b" ]]; then
    printf '\n# ---- Prefix ----\n'
    printf 'set -g prefix %s\n' "$PREFIX"
    printf 'unbind C-b\n'
    printf 'bind %s send-prefix\n' "$PREFIX"
  fi

  if [[ "$WINDOW_NAV" == on ]]; then
    cat <<'TMUXWIN'

# ---- Window switching ----
# Alt+<number> jumps to a window (no prefix); Shift+Left / Shift+Right = previous / next window.
bind -n M-1 select-window -t :1
bind -n M-2 select-window -t :2
bind -n M-3 select-window -t :3
bind -n M-4 select-window -t :4
bind -n M-5 select-window -t :5
bind -n M-6 select-window -t :6
bind -n M-7 select-window -t :7
bind -n M-8 select-window -t :8
bind -n M-9 select-window -t :9
bind -n S-Left previous-window
bind -n S-Right next-window
TMUXWIN
  fi

  # Entry keys: a modifier chord (C-Space, C-Enter, M-x …) binds WITHOUT prefix (press it
  # directly); a plain key binds under the prefix. C-Enter and similar need extended keys —
  # enable them when a chord is in use (the OUTER terminal must also support extended keys).
  if _tmux_key_is_chord "$COPY_MODE_KEY" || _tmux_key_is_chord "$TREE_KEY"; then
    printf '\n# ---- Extended keys (so chords like C-Enter are distinct; needs terminal support) ----\n'
    printf 'set -s extended-keys on\n'
    printf "set -as terminal-features '*:extkeys'\n"
  fi

  if [[ -n "$COPY_MODE_KEY" && "$COPY_MODE_KEY" != "default" ]]; then
    printf '\n# ---- Enter copy mode (default prefix [ still works) ----\n'
    if _tmux_key_is_chord "$COPY_MODE_KEY"; then printf 'bind -n %s copy-mode\n' "$COPY_MODE_KEY"
    else                                         printf 'bind %s copy-mode\n'    "$COPY_MODE_KEY"; fi
  fi

  if [[ -n "$TREE_KEY" && "$TREE_KEY" != "default" ]]; then
    printf '\n# ---- Window/session tree picker (default prefix w still works) ----\n'
    if _tmux_key_is_chord "$TREE_KEY"; then printf 'bind -n %s choose-tree -Zw\n' "$TREE_KEY"
    else                                    printf 'bind %s choose-tree -Zw\n'    "$TREE_KEY"; fi
  fi

  if [[ "$KEYBINDINGS" == on ]]; then
    cat <<'TMUXKEYS'

# ---- Ergonomic keybindings ----
# Split keeping the current path: | vertical, - horizontal; new window keeps the path too.
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"
# vim-style pane navigation (note: rebinds prefix-l away from last-window)
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
# vim-style pane resize (repeatable)
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5
# vi copy-mode: v begin, C-v rectangle, y copy (system clipboard via set-clipboard/OSC52)
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi C-v send -X rectangle-toggle
bind -T copy-mode-vi y send -X copy-selection-and-cancel
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-selection-and-cancel
TMUXKEYS
  fi

  if _tmux_tpm_installed; then
    local k tspec
    printf '\n# ---- Plugins (Tmux Plugin Manager) ----\n'
    printf "set -g @plugin '%s'\n" "tmux-plugins/tpm"
    for k in $PLUGINS; do
      printf "set -g @plugin '%s'\n" "$(_tmux_plugin_spec "$k")"
    done
    if tspec="$(_tmux_theme_spec "$THEME")"; then
      printf "set -g @plugin '%s'\n" "$tspec"
    fi

    printf '\n# ---- Plugin settings ----\n'
    _tmux_list_has resurrect "$PLUGINS" && printf "set -g @resurrect-capture-pane-contents 'on'\n"
    if _tmux_list_has continuum "$PLUGINS"; then
      printf "set -g @continuum-restore 'on'\n"
      printf "set -g @continuum-save-interval '15'\n"
    fi
    case "$THEME" in
      catppuccin) printf "set -g @catppuccin_flavor '%s'\n"  "${THEME_FLAVOR:-mocha}" ;;
      themepack)  printf "set -g @themepack '%s'\n"          "${THEME_FLAVOR:-powerline/default/cyan}" ;;
    esac

    cat <<'TMUXTPM'

# Auto-install TPM + the declared plugins on a fresh machine (skipped once TPM exists).
if "test ! -d ~/.tmux/plugins/tpm" \
   "run 'git clone --depth=1 https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm && ~/.tmux/plugins/tpm/bin/install_plugins'"

# Initialize TPM — keep this the LAST line of the managed block.
run '~/.tmux/plugins/tpm/tpm'
TMUXTPM
  fi

  printf '%s\n' "$TMUX_BLOCK_END"
}

# Rewrite the managed block inside ~/.tmux.conf: strip any existing block (anywhere), then
# append a freshly generated one at the END (so TPM's `run` stays last). Everything outside
# the markers is preserved. Backs up before any change; no-op when content is unchanged.
_tmux_write_block() {
  mkdir -p "$(dirname "$_TCONF")"
  local tmp body newf
  tmp="$(mktemp)"
  if [[ -f "$_TCONF" ]]; then
    awk -v b="$TMUX_BLOCK_BEGIN" -v e="$TMUX_BLOCK_END" \
      '$0==b{inblk=1} inblk==0{print} $0==e{inblk=0}' "$_TCONF" >"$tmp"
  fi
  body="$(cat "$tmp")"; rm -f "$tmp"
  newf="$(mktemp)"
  { [[ -n "$body" ]] && printf '%s\n\n' "$body"; _tmux_emit_block; } >"$newf"
  if [[ -f "$_TCONF" ]] && cmp -s "$newf" "$_TCONF"; then rm -f "$newf"; return 0; fi
  backup_file "$_TCONF"
  mv "$newf" "$_TCONF" || { rm -f "$newf"; return 1; }
  log_info "Updated the managed block in $_TCONF (your own config outside the markers is preserved)."
}

# continuum is useless without resurrect — enable it implicitly (in front, so it loads first).
_tmux_imply_resurrect() {
  if _tmux_list_has continuum "$PLUGINS" && ! _tmux_list_has resurrect "$PLUGINS"; then
    PLUGINS="resurrect${PLUGINS:+ $PLUGINS}"
    log_info "Enabled 'resurrect' (required by 'continuum')."
  fi
}

# Whether the config should carry a plugin manager + plugins at all.
_tmux_want_plugins() { [[ -n "$PLUGINS" || "$THEME" != "none" ]]; }

# Resolve everything enabled, (re)generate the block, install declared plugins.
_tmux_apply() {
  _tmux_imply_resurrect
  if _tmux_want_plugins; then _tmux_ensure_tpm || return 1; fi
  _tmux_write_block || return 1
  _tmux_save_state
  if _tmux_tpm_installed && _tmux_want_plugins; then _tmux_run_install_plugins; fi
  log_info "Applied tmux config — theme=$THEME, mouse=$MOUSE, keys=$KEYMODE, plugins=[${PLUGINS:-none}]."
  log_info "Reload a running tmux with:  tmux source-file ~/.tmux.conf   (or just start a new tmux)."
}

# --- configure -----------------------------------------------------------------
# Validate-and-assign helpers for the on/off and integer flags (nameref into the state var).
_tmux_set_onoff() { local v="$1"; local -n _r="$2"; _tmux_valid_onoff "$v" || { log_err "$3 needs on|off."; return 2; }; _r="$v"; }
_tmux_set_int()   { local v="$1"; local -n _r="$2"; _tmux_valid_int "$v"   || { log_err "$3 needs a non-negative integer."; return 2; }; _r="$v"; }

do_configure() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first (swkit tmux install)."; return 0; fi
  _tmux_resolve_paths || return 1
  _tmux_load_state

  local want_plugins=1 plugins_set="" recommended=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recommended) recommended=1; shift ;;
      # appearance
      --theme)            _tmux_valid_theme "${2:-}" || { log_err "--theme: none|catppuccin|dracula|themepack."; return 2; }; THEME="$2"; shift 2 ;;
      --theme=*)          THEME="${1#*=}"; _tmux_valid_theme "$THEME" || { log_err "--theme: none|catppuccin|dracula|themepack."; return 2; }; shift ;;
      --theme-flavor)     THEME_FLAVOR="${2:-}"; shift 2 || { log_err "--theme-flavor needs a value."; return 2; } ;;
      --theme-flavor=*)   THEME_FLAVOR="${1#*=}"; shift ;;
      --status-position)   _tmux_valid_status_pos "${2:-}" || { log_err "--status-position: top|bottom."; return 2; }; STATUS_POSITION="$2"; shift 2 ;;
      --status-position=*) STATUS_POSITION="${1#*=}"; _tmux_valid_status_pos "$STATUS_POSITION" || { log_err "--status-position: top|bottom."; return 2; }; shift ;;
      --status-interval)   _tmux_set_int "${2:-}" STATUS_INTERVAL --status-interval || return 2; shift 2 ;;
      --status-interval=*) _tmux_set_int "${1#*=}" STATUS_INTERVAL --status-interval || return 2; shift ;;
      # behavior toggles
      --mouse)             _tmux_set_onoff "${2:-}" MOUSE --mouse || return 2; shift 2 ;;
      --mouse=*)           _tmux_set_onoff "${1#*=}" MOUSE --mouse || return 2; shift ;;
      --clipboard)         _tmux_set_onoff "${2:-}" CLIPBOARD --clipboard || return 2; shift 2 ;;
      --clipboard=*)       _tmux_set_onoff "${1#*=}" CLIPBOARD --clipboard || return 2; shift ;;
      --focus-events)      _tmux_set_onoff "${2:-}" FOCUS_EVENTS --focus-events || return 2; shift 2 ;;
      --focus-events=*)    _tmux_set_onoff "${1#*=}" FOCUS_EVENTS --focus-events || return 2; shift ;;
      --aggressive-resize)   _tmux_set_onoff "${2:-}" AGGRESSIVE_RESIZE --aggressive-resize || return 2; shift 2 ;;
      --aggressive-resize=*) _tmux_set_onoff "${1#*=}" AGGRESSIVE_RESIZE --aggressive-resize || return 2; shift ;;
      --renumber)          _tmux_set_onoff "${2:-}" RENUMBER --renumber || return 2; shift 2 ;;
      --renumber=*)        _tmux_set_onoff "${1#*=}" RENUMBER --renumber || return 2; shift ;;
      --base-index)        _tmux_set_onoff "${2:-}" BASE_INDEX --base-index || return 2; shift 2 ;;
      --base-index=*)      _tmux_set_onoff "${1#*=}" BASE_INDEX --base-index || return 2; shift ;;
      --monitor-activity)   _tmux_set_onoff "${2:-}" MONITOR_ACTIVITY --monitor-activity || return 2; shift 2 ;;
      --monitor-activity=*) _tmux_set_onoff "${1#*=}" MONITOR_ACTIVITY --monitor-activity || return 2; shift ;;
      --set-titles)        _tmux_set_onoff "${2:-}" SET_TITLES --set-titles || return 2; shift 2 ;;
      --set-titles=*)      _tmux_set_onoff "${1#*=}" SET_TITLES --set-titles || return 2; shift ;;
      # keys
      --keymode)           _tmux_valid_keymode "${2:-}" || { log_err "--keymode: vi|emacs."; return 2; }; KEYMODE="$2"; shift 2 ;;
      --keymode=*)         KEYMODE="${1#*=}"; _tmux_valid_keymode "$KEYMODE" || { log_err "--keymode: vi|emacs."; return 2; }; shift ;;
      --prefix)            PREFIX="${2:-}"; [[ -n "$PREFIX" ]] || { log_err "--prefix needs a key (e.g. C-a) or 'default'."; return 2; }; shift 2 ;;
      --prefix=*)          PREFIX="${1#*=}"; [[ -n "$PREFIX" ]] || { log_err "--prefix needs a key or 'default'."; return 2; }; shift ;;
      --keybindings)       _tmux_set_onoff "${2:-}" KEYBINDINGS --keybindings || return 2; shift 2 ;;
      --keybindings=*)     _tmux_set_onoff "${1#*=}" KEYBINDINGS --keybindings || return 2; shift ;;
      --window-nav)        _tmux_set_onoff "${2:-}" WINDOW_NAV --window-nav || return 2; shift 2 ;;
      --window-nav=*)      _tmux_set_onoff "${1#*=}" WINDOW_NAV --window-nav || return 2; shift ;;
      --copy-mode-key)     COPY_MODE_KEY="${2:-}"; _tmux_valid_key "$COPY_MODE_KEY" || { log_err "--copy-mode-key needs a single key (e.g. v) or 'default'."; return 2; }; shift 2 ;;
      --copy-mode-key=*)   COPY_MODE_KEY="${1#*=}"; _tmux_valid_key "$COPY_MODE_KEY" || { log_err "--copy-mode-key needs a single key (e.g. v) or 'default'."; return 2; }; shift ;;
      --tree-key)          TREE_KEY="${2:-}"; _tmux_valid_key "$TREE_KEY" || { log_err "--tree-key needs a single key (e.g. w) or 'default'."; return 2; }; shift 2 ;;
      --tree-key=*)        TREE_KEY="${1#*=}"; _tmux_valid_key "$TREE_KEY" || { log_err "--tree-key needs a single key (e.g. w) or 'default'."; return 2; }; shift ;;
      # history
      --history)           _tmux_set_int "${2:-}" HISTORY --history || return 2; shift 2 ;;
      --history=*)         _tmux_set_int "${1#*=}" HISTORY --history || return 2; shift ;;
      --escape-time)       _tmux_set_int "${2:-}" ESCAPE_TIME --escape-time || return 2; shift 2 ;;
      --escape-time=*)     _tmux_set_int "${1#*=}" ESCAPE_TIME --escape-time || return 2; shift ;;
      # plugins
      --plugins)           plugins_set="${2:-}"; shift 2 || { log_err "--plugins needs a value."; return 2; } ;;
      --plugins=*)         plugins_set="${1#*=}"; shift ;;
      --no-plugins)        want_plugins=0; shift ;;
      -h|--help)           usage; return 0 ;;
      *) log_err "Unknown configure option: $1"; usage; return 2 ;;
    esac
  done

  if (( recommended )); then
    PLUGINS="$TMUX_RECOMMENDED_PLUGINS"
    [[ "$THEME" == "none" ]] && THEME="catppuccin"
    KEYBINDINGS="on"
    WINDOW_NAV="on"
  fi
  if (( ! want_plugins )); then
    PLUGINS=""
  elif [[ -n "$plugins_set" ]]; then
    local list p; list="${plugins_set//,/ }"; PLUGINS=""
    for p in $list; do
      if _tmux_list_has "$p" "$TMUX_KNOWN_PLUGINS"; then PLUGINS="${PLUGINS:+$PLUGINS }$p"
      else log_err "Unknown plugin '$p' for --plugins (known: $TMUX_KNOWN_PLUGINS). Use add-plugin <owner/repo|git-url> for arbitrary repos."; return 2; fi
    done
  fi

  _tmux_apply
}

# --- TPM + plugin + theme actions ----------------------------------------------

do_install_tpm() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first (swkit tmux install)."; return 0; fi
  _tmux_resolve_paths || return 1
  _tmux_load_state
  _tmux_ensure_tpm || return 1
  _tmux_apply
}

do_uninstall_tpm() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first."; return 0; fi
  _tmux_resolve_paths || return 1
  _tmux_load_state
  if [[ -d "$_TPM_DIR" ]]; then
    rm -rf "$_TPM_DIR"
    log_info "Removed TPM ($_TPM_DIR)."
  else
    log_info "TPM was not installed."
  fi
  # TPM is gone now, so the regenerated block drops the plugin section; the user's plugin
  # selection stays in the state file and re-activates after install-tpm. (Do not call
  # _tmux_apply here — it would re-install TPM because plugins are still enabled in state.)
  _tmux_write_block || return 1
  _tmux_save_state
  log_info "Cloned plugins remain under $_TPLUGDIR (remove them by hand if you want)."
  log_info "Reload a running tmux with:  tmux source-file ~/.tmux.conf"
}

do_update_plugins() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first."; return 0; fi
  _tmux_resolve_paths || return 1
  if ! _tmux_tpm_installed; then log_info "TPM is not installed — run 'swkit tmux install-tpm' first."; return 0; fi
  [[ -x "$_TPM_DIR/bin/update_plugins" ]] || { log_err "TPM has no bin/update_plugins."; return 1; }
  log_info "Updating all tmux plugins via TPM…"
  "$_TPM_DIR/bin/update_plugins" all
}

do_add_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first."; return 0; fi
  local arg="${1:-}"
  if [[ -z "$arg" ]]; then
    log_err "Usage: tmux add-plugin <name|owner/repo[#branch]|git-url>"
    log_err "Known names: $TMUX_KNOWN_PLUGINS"
    return 2
  fi
  _tmux_resolve_paths || return 1
  _tmux_load_state
  local key
  if _tmux_list_has "$arg" "$TMUX_KNOWN_PLUGINS"; then
    key="$arg"
  elif [[ "$arg" == */* || "$arg" == *://* || "$arg" == git@* ]]; then
    key="$arg"   # arbitrary "owner/repo[#branch]" or git URL — TPM clones it as-is
  else
    log_err "Unknown plugin '$arg'. Known: $TMUX_KNOWN_PLUGINS."
    log_err "For others pass an 'owner/repo' or a git URL."
    return 2
  fi
  if _tmux_list_has "$key" "$PLUGINS"; then
    log_info "Plugin '$key' already enabled — refreshing config."
  else
    PLUGINS="${PLUGINS:+$PLUGINS }$key"
  fi
  _tmux_apply
}

do_remove_plugin() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first."; return 0; fi
  local key="${1:-}"
  if [[ -z "$key" ]]; then log_err "Usage: tmux remove-plugin <name|owner/repo|git-url>"; return 2; fi
  _tmux_resolve_paths || return 1
  _tmux_load_state
  if ! _tmux_list_has "$key" "$PLUGINS"; then
    log_info "Plugin '$key' is not enabled — nothing to remove."
    return 0
  fi
  local p new=""
  for p in $PLUGINS; do [[ "$p" == "$key" ]] || new="${new:+$new }$p"; done
  PLUGINS="$new"
  _tmux_apply
  _tmux_run_clean_plugins   # drop the now-undeclared clone from ~/.tmux/plugins
}

do_theme() {
  if ! status >/dev/null 2>&1; then log_info "Install tmux first."; return 0; fi
  local name="${1:-}" flavor="${2:-}"
  if [[ -z "$name" ]]; then log_err "Usage: tmux theme <none|catppuccin|dracula|themepack> [flavor]"; return 2; fi
  _tmux_valid_theme "$name" || { log_err "Unknown theme '$name' (none|catppuccin|dracula|themepack)."; return 2; }
  _tmux_resolve_paths || return 1
  _tmux_load_state
  THEME="$name"
  [[ -n "$flavor" ]] && THEME_FLAVOR="$flavor"
  _tmux_apply
}

# --- UI helpers ----------------------------------------------------------------
_tmux_flip_onoff() { case "$1" in on) printf 'off' ;; *) printf 'on' ;; esac; }

# A toggle-row label: name + colored ●/○ + on/off.
_tmux_onoff_label() {
  local name="$1" val="$2"
  if [[ "$val" == "on" ]]; then printf '%-18s %s %son%s'  "$name" "$(ui_badge on)"  "$UI_OK"    "$UI_OFF"
  else                          printf '%-18s %s %soff%s' "$name" "$(ui_badge off)" "$UI_MUTED" "$UI_OFF"; fi
}

# A picker/input-row label: name + accented current value + arrow.
_tmux_value_label() {
  printf '%-18s %s%s%s  %s' "$1" "$UI_INFO" "$2" "$UI_OFF" "$UI_ARROW"
}

# Current value of a toggle setting, keyed by its configure flag name (used by the UI handler).
_tmux_setting_val() {
  case "$1" in
    mouse)             printf '%s' "$MOUSE" ;;
    clipboard)         printf '%s' "$CLIPBOARD" ;;
    focus-events)      printf '%s' "$FOCUS_EVENTS" ;;
    aggressive-resize) printf '%s' "$AGGRESSIVE_RESIZE" ;;
    renumber)          printf '%s' "$RENUMBER" ;;
    base-index)        printf '%s' "$BASE_INDEX" ;;
    monitor-activity)  printf '%s' "$MONITOR_ACTIVITY" ;;
    set-titles)        printf '%s' "$SET_TITLES" ;;
    keybindings)       printf '%s' "$KEYBINDINGS" ;;
    window-nav)        printf '%s' "$WINDOW_NAV" ;;
  esac
}

# --- Interactive management screen (the script's own UI) -----------------------
# A bespoke full-screen component manager with a scrolling viewport (many settings): toggle
# TPM, pick a theme/status position/key mode, flip behavior toggles, set scrollback/escape-
# time/prefix/status-interval, enable ergonomic keybindings, check plugins on/off (curated +
# arbitrary git via `a`), apply/update, install/remove tmux. State is read live each pass;
# every change shells out via ui_run (so apt/git/TPM output is visible and logged) and the
# screen reloads. Limited terminals fall back to the synthesized op menu. `ui` is an entry
# mode (kit_dispatch) — never listed in meta ops.
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }

  local sel=0 top=0 g
  while true; do
    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }

    # ---- live state ----
    local installed=0 ver="" tpm=0
    if status >/dev/null 2>&1; then
      installed=1
      ver="$(tmux -V 2>/dev/null | awk '{print $2}')"
      if _tmux_resolve_paths >/dev/null 2>&1; then _tmux_load_state; _tmux_tpm_installed && tpm=1; fi
    fi

    # ---- build display rows (parallel arrays: kind / id / label) ----
    local -a dkind=() did=() dlabel=()
    if (( ! installed )); then
      dkind+=(install); did+=(install); dlabel+=("$(ui_badge missing) $(ui_t install) tmux — terminal multiplexer")
    else
      dkind+=(note); did+=(""); dlabel+=("Settings write a managed block in ~/.tmux.conf; your own config is preserved.")
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Plugin manager")
      local tpm_badge
      if (( tpm )); then tpm_badge="${UI_OK}[on]${UI_OFF}"; else tpm_badge="${UI_MUTED}[off]${UI_OFF}"; fi
      dkind+=(tpm); did+=(tpm); dlabel+=("$(printf '%-18s %s' 'TPM' "$tpm_badge")")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Appearance")
      dkind+=(theme);   did+=(theme);   dlabel+=("$(_tmux_value_label 'Theme' "$THEME")")
      dkind+=(statuspos); did+=(statuspos); dlabel+=("$(_tmux_value_label 'Status bar' "$STATUS_POSITION")")
      dkind+=(statusint); did+=(statusint); dlabel+=("$(_tmux_value_label 'Status refresh' "${STATUS_INTERVAL}s")")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Behavior")
      local fl
      for fl in mouse clipboard focus-events aggressive-resize renumber base-index monitor-activity set-titles; do
        local nm
        case "$fl" in
          mouse) nm="Mouse" ;; clipboard) nm="System clipboard" ;; focus-events) nm="Focus events" ;;
          aggressive-resize) nm="Aggressive resize" ;; renumber) nm="Renumber windows" ;;
          base-index) nm="1-based index" ;; monitor-activity) nm="Monitor activity" ;; set-titles) nm="Set window title" ;;
        esac
        dkind+=(toggle); did+=("$fl"); dlabel+=("$(_tmux_onoff_label "$nm" "$(_tmux_setting_val "$fl")")")
      done

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Keys")
      dkind+=(keymode); did+=(keymode); dlabel+=("$(_tmux_value_label 'Mode keys' "$KEYMODE")")
      dkind+=(prefix);  did+=(prefix);  dlabel+=("$(_tmux_value_label 'Prefix key' "$PREFIX")")
      dkind+=(toggle);  did+=(keybindings); dlabel+=("$(_tmux_onoff_label 'Ergonomic keys' "$KEYBINDINGS")")
      dkind+=(toggle);  did+=(window-nav);  dlabel+=("$(_tmux_onoff_label 'Window switch keys' "$WINDOW_NAV")")
      local cmk_disp
      if [[ "$COPY_MODE_KEY" == "default" ]]; then cmk_disp="prefix [ (default)"
      elif _tmux_key_is_chord "$COPY_MODE_KEY"; then cmk_disp="$COPY_MODE_KEY (no prefix)"
      else cmk_disp="prefix $COPY_MODE_KEY"; fi
      dkind+=(copymodekey); did+=(copymodekey); dlabel+=("$(_tmux_value_label 'Enter copy-mode' "$cmk_disp")")
      local tree_disp
      if [[ "$TREE_KEY" == "default" ]]; then tree_disp="prefix w (default)"
      elif _tmux_key_is_chord "$TREE_KEY"; then tree_disp="$TREE_KEY (no prefix)"
      else tree_disp="prefix $TREE_KEY"; fi
      dkind+=(treekey); did+=(treekey); dlabel+=("$(_tmux_value_label 'Window tree' "$tree_disp")")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("History")
      dkind+=(history); did+=(history); dlabel+=("$(_tmux_value_label 'Scrollback lines' "$HISTORY")")
      dkind+=(escape);  did+=(escape);  dlabel+=("$(_tmux_value_label 'Escape time' "${ESCAPE_TIME}ms")")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(recommended); did+=(recommended); dlabel+=("$(ui_badge check) Apply recommended setup (TPM + popular plugins + theme + ergonomic keys)")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(header); did+=(""); dlabel+=("Plugins")
      local p on
      for p in $TMUX_KNOWN_PLUGINS; do
        on=0; _tmux_list_has "$p" "$PLUGINS" && on=1
        dkind+=(plugin); did+=("$p")
        if (( on )); then dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $(printf '%-16s' "$p")${UI_MUTED}$(_tmux_known_desc "$p")${UI_OFF}")
        else              dlabel+=("  ${UI_MUTED}${UI_CHK_OFF}${UI_OFF} $(printf '%-16s' "$p")${UI_MUTED}$(_tmux_known_desc "$p")${UI_OFF}"); fi
      done
      for p in $PLUGINS; do
        _tmux_list_has "$p" "$TMUX_KNOWN_PLUGINS" && continue
        dkind+=(plugin); did+=("$p"); dlabel+=("  ${UI_OK}${UI_CHK_ON}${UI_OFF} $p ${UI_MUTED}(custom)${UI_OFF}")
      done
      dkind+=(plugin_add); did+=(plugin_add); dlabel+=("  ${UI_ACCENT}+${UI_OFF} add plugin (owner/repo or git URL)…")

      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(apply); did+=(apply); dlabel+=("$(ui_badge check) Apply config now")
      if (( tpm )); then dkind+=(update); did+=(update); dlabel+=("$(ui_badge check) Update plugins"); fi
      dkind+=(spacer); did+=(""); dlabel+=("")
      dkind+=(remove); did+=(remove); dlabel+=("${UI_ERR}${UI_CROSS}${UI_OFF} $(ui_t remove) tmux")
    fi

    # ---- clamp selection, skip non-selectable rows, compute viewport ----
    local n=${#dkind[@]}
    (( sel < 0 )) && sel=0; (( sel >= n )) && sel=$(( n - 1 ))
    case "${dkind[$sel]}" in note|spacer|header)
      for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
    esac
    local listrow=3 avail=$(( UI_ROWS - 3 - 1 ))
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    (( top < 0 )) && top=0

    # ---- render (viewport rows top..top+avail) ----
    printf '\033[2J' >&"$_UI_FD"
    if (( installed )); then ui_header "tmux · component manager" "v$ver ${UI_OK}${UI_CHECK}${UI_OFF}"
    else ui_header "tmux · component manager" "$(ui_t not_installed)"; fi
    local i row=$listrow
    for (( i=top; i<n && i<top+avail; i++ )); do
      case "${dkind[$i]}" in
        spacer) : ;;
        header) ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        note)   ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_MUTED" "${dlabel[$i]}" "$UI_OFF" >&"$_UI_FD" ;;
        *)      ui_row "$row" "$i" "$sel" "${dlabel[$i]}" ;;
      esac
      (( row++ ))
    done
    local more=""
    (( top > 0 )) && more="↑ "
    (( top + avail < n )) && more="${more}↓ "
    if (( installed )); then ui_footer "${more}↑↓ move   ↵/space toggle·edit   a add-plugin   esc/q close"
    else ui_footer "↑↓ move   ↵/space install   esc/q close"; fi

    # ---- input ----
    ui_read_key
    case "$UI_KEY" in
      up|k)   for (( g=0; g<n; g++ )); do sel=$(( (sel-1+n)%n )); case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      down|j) for (( g=0; g<n; g++ )); do sel=$(( (sel+1)%n ));   case "${dkind[$sel]}" in note|spacer|header) ;; *) break ;; esac; done ;;
      a|A)
        if (( installed )) && ui_input "owner/repo or git URL" ""; then
          [[ -n "$UI_INPUT" ]] && ui_run "add-plugin · tmux" -- "$0" add-plugin "$UI_INPUT"
        fi ;;
      enter|space)
        case "${dkind[$sel]}" in
          install) ui_run "$(ui_t install) tmux" -- "$0" install ;;
          remove)  ui_confirm "Uninstall tmux? (apt remove — your ~/.tmux.conf and plugins are kept)" n && ui_run "$(ui_t remove) tmux" -- "$0" remove ;;
          tpm)
            if (( tpm )); then
              ui_confirm "Remove TPM? (disables managed plugins; clones are kept)" n && ui_run "uninstall-tpm · tmux" -- "$0" uninstall-tpm
            else
              ui_run "install-tpm · tmux" -- "$0" install-tpm
            fi ;;
          theme)
            ui_pick "tmux — theme" "current: $THEME" "" -- \
              none "none (no theme plugin)" catppuccin "Catppuccin" dracula "Dracula" themepack "Themepack (powerline)"
            if [[ -n "$UI_PICK" ]]; then
              if [[ "$UI_PICK" == "catppuccin" ]]; then
                ui_pick "Catppuccin flavor" "current: $THEME_FLAVOR" "" -- \
                  mocha "Mocha (dark)" macchiato "Macchiato" frappe "Frappe" latte "Latte (light)"
                [[ -n "$UI_PICK" ]] && ui_run "theme catppuccin $UI_PICK · tmux" -- "$0" theme catppuccin "$UI_PICK"
              else
                ui_run "theme $UI_PICK · tmux" -- "$0" theme "$UI_PICK"
              fi
            fi ;;
          statuspos)
            ui_pick "tmux — status bar position" "current: $STATUS_POSITION" "" -- top "top" bottom "bottom"
            [[ -n "$UI_PICK" ]] && ui_run "status-position $UI_PICK · tmux" -- "$0" configure --status-position "$UI_PICK" ;;
          statusint)
            if ui_input "status bar refresh (seconds)" "$STATUS_INTERVAL"; then
              [[ -n "$UI_INPUT" ]] && ui_run "status-interval · tmux" -- "$0" configure --status-interval "$UI_INPUT"
            fi ;;
          keymode)
            ui_pick "tmux — copy mode keys" "current: $KEYMODE" "" -- vi "vi" emacs "emacs"
            [[ -n "$UI_PICK" ]] && ui_run "keymode $UI_PICK · tmux" -- "$0" configure --keymode "$UI_PICK" ;;
          prefix)
            if ui_input "prefix key (e.g. C-a; 'default' = C-b)" "$PREFIX"; then
              [[ -n "$UI_INPUT" ]] && ui_run "prefix $UI_INPUT · tmux" -- "$0" configure --prefix "$UI_INPUT"
            fi ;;
          copymodekey)
            if ui_input "copy-mode key — chord e.g. C-Space (direct), plain key e.g. v (prefix+key), 'default' = [" "$COPY_MODE_KEY"; then
              [[ -n "$UI_INPUT" ]] && ui_run "copy-mode key · tmux" -- "$0" configure --copy-mode-key "$UI_INPUT"
            fi ;;
          treekey)
            if ui_input "window-tree key — chord e.g. C-Enter (direct), plain key e.g. w (prefix+key), 'default' = w" "$TREE_KEY"; then
              [[ -n "$UI_INPUT" ]] && ui_run "window-tree key · tmux" -- "$0" configure --tree-key "$UI_INPUT"
            fi ;;
          history)
            if ui_input "scrollback lines" "$HISTORY"; then
              [[ -n "$UI_INPUT" ]] && ui_run "history-limit · tmux" -- "$0" configure --history "$UI_INPUT"
            fi ;;
          escape)
            if ui_input "escape-time ms (10 is good for vim/neovim)" "$ESCAPE_TIME"; then
              [[ -n "$UI_INPUT" ]] && ui_run "escape-time · tmux" -- "$0" configure --escape-time "$UI_INPUT"
            fi ;;
          toggle)
            local tf="${did[$sel]}" cur
            cur="$(_tmux_setting_val "$tf")"
            ui_run "$tf $(_tmux_flip_onoff "$cur") · tmux" -- "$0" configure "--$tf" "$(_tmux_flip_onoff "$cur")" ;;
          recommended) ui_run "recommended setup · tmux" -- "$0" configure --recommended ;;
          plugin)
            local pn="${did[$sel]}"
            if _tmux_list_has "$pn" "$PLUGINS"; then ui_run "remove-plugin $pn · tmux" -- "$0" remove-plugin "$pn"
            else ui_run "add-plugin $pn · tmux" -- "$0" add-plugin "$pn"; fi ;;
          plugin_add)
            if ui_input "owner/repo or git URL" ""; then
              [[ -n "$UI_INPUT" ]] && ui_run "add-plugin · tmux" -- "$0" add-plugin "$UI_INPUT"
            fi ;;
          apply)  ui_run "apply config · tmux" -- "$0" configure ;;
          update) ui_run "update-plugins · tmux" -- "$0" update-plugins ;;
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

tmux component manager. State lives in ~/.config/ubuntu-setup/tmux.conf; every change
regenerates a marked block inside ~/.tmux.conf (your own config outside the markers is
preserved). Plugins are driven by the Tmux Plugin Manager (TPM) via its non-interactive
bin/ scripts. Re-running converges; safe to run twice.

  install            Install tmux via apt
  remove             Uninstall tmux (apt remove — keeps ~/.tmux.conf, plugins and TPM)
  configure [opts]   Re-spec options/plugins/theme. Options:
                       --recommended            TPM + popular plugins + Catppuccin + ergonomic keys
                     Appearance:
                       --theme none|catppuccin|dracula|themepack   (default: none)
                       --theme-flavor <flavor>  Catppuccin: mocha|macchiato|frappe|latte
                       --status-position top|bottom                (default: bottom)
                       --status-interval <seconds>                 (default: 5)
                     Behavior (on|off):
                       --mouse              mouse support            (default: on)
                       --clipboard          set-clipboard / OSC52    (default: on)
                       --focus-events       focus events for vim     (default: on)
                       --aggressive-resize  resize to smallest client viewing the window (default: off)
                       --renumber           renumber windows on close (default: on)
                       --base-index         windows/panes start at 1  (default: on)
                       --monitor-activity   highlight active windows  (default: off)
                       --set-titles         set the terminal title    (default: off)
                     Keys:
                       --keymode vi|emacs   copy-mode keys           (default: vi)
                       --prefix <key>|default   remap prefix (e.g. C-a); default = C-b
                       --keybindings on|off ergonomic splits/nav/copy bindings (default: off)
                       --window-nav on|off  Alt+1..9 jump to window + Shift-Left/Right prev/next (default: off)
                       --copy-mode-key <key>|default   key to enter copy-mode. A modifier chord
                                            (e.g. C-Space) binds directly (no prefix); a plain key
                                            (e.g. v) binds under the prefix. default = just [
                       --tree-key <key>|default        key to open the window/session tree. Chord
                                            (e.g. C-Enter) = direct; plain key = prefix+key. default = w
                                            (chords like C-Enter need a terminal with extended-keys)
                     History:
                       --history <lines>    scrollback buffer        (default: 50000)
                       --escape-time <ms>   key wait after Esc       (default: 10)
                     Plugins:
                       --plugins "a b c"    set enabled (curated) plugins; known names:
                                            $TMUX_KNOWN_PLUGINS
                       --no-plugins         disable all kit plugins
  install-tpm        Install the Tmux Plugin Manager (~/.tmux/plugins/tpm)
  uninstall-tpm      Remove TPM (keeps plugin clones + your plugin selection in state)
  update-plugins     Update all installed plugins (TPM)
  add-plugin <name|owner/repo[#branch]|git-url>
                     Enable a plugin (installs it). Known names: $TMUX_KNOWN_PLUGINS
                     Any other value is treated as an owner/repo or git URL.
  remove-plugin <name|owner/repo|git-url>
                     Disable a plugin (removes its clone from ~/.tmux/plugins)
  theme <none|catppuccin|dracula|themepack> [flavor]
                     Set the theme (and optional flavor)
  ui                 Open the interactive component manager (needs a terminal)
  status             Print 'tmux -V'; exit code 0 iff installed
  meta               Print machine-readable metadata (for the TUI / swkit list)
  help               Show this help

A bare 'configure' writes a tasteful best-practice baseline (mouse on, vi copy mode, true
color, 50k scrollback, 10ms escape-time, 1-based indexing) but NO plugins/theme and NO key
remaps — safe and headless. Opt into the popular bundle with 'configure --recommended' (or
the UI's "Apply recommended setup"). The interactive manager ('swkit tmux') exposes every
setting as a quick toggle/picker/input. Plugins load on the next tmux start, or immediately
after 'tmux source-file ~/.tmux.conf'. tmux runs headless / over SSH — settings apply here.
EOF
}

kit_dispatch "$@"
