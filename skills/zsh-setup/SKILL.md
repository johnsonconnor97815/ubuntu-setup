---
name: zsh-setup
description: Use when the user wants to install, set up, configure, customize, or switch to the Z shell (zsh) on Ubuntu/Debian — including making zsh the default login shell, adding autosuggestions / syntax-highlighting / completions, choosing a prompt (Starship, Powerlevel10k, Pure) or a framework (Oh My Zsh), or writing a ~/.zshrc. Covers headless servers reached over SSH.
---

# Zsh Setup on Ubuntu

You are setting up the Z shell on a real Ubuntu/Debian machine (20.04+), possibly a headless server reached over SSH. There is no rollback for system changes. This skill builds on the **ubuntu-install** skill: every apt/sudo step here follows its rules — check the live system first (idempotency), escalate per command with `sudo`, run apt non-interactively (`DEBIAN_FRONTEND=noninteractive ... -y --no-install-recommends`), present the exact plan before applying, back up any config before editing, and verify against the live system afterward.

**The one step that can lock the user out is changing the default login shell.** Treat it with the caution that deserves — read §1 before doing anything else.

**Boundary with bootstrap's TUI.** `bootstrap.sh` ("Install software → zsh → Configure", `sw_zsh_configure`) does one **minimal, safe** thing only: make zsh the default login shell (via `sudo chsh`, after checking it isn't already). Everything deeper — plugins, prompt, `~/.zshrc`, frameworks — is **this skill's** job. When you also change the login shell, follow the same `chsh` lockout rules (§1, §8); the TUI's minimal subset and this skill's prose describe the same action in two places, so if one changes, check the other (same drift caveat as ubuntu-install §3's sudo rule).

## 1. Lockout safety (read this first)

Changing a user's login shell on a remote machine is the only action here that can make them unable to log in. So:

- **Install and fully configure zsh first; change the login shell last.** Build a working `~/.zshrc`, then prove zsh starts cleanly with `zsh -i -c exit` (exit status 0, no errors, no hang). Only then touch `chsh`.
- **Never set a login shell you haven't verified starts cleanly** for that exact user.
- **Keep the current session open.** After changing the shell, have the user open a *fresh* login (new SSH session) and confirm they land in a working zsh *before* closing the session you already have.
- `chsh` changes the shell for **new** sessions only; your current shell does not change. To try zsh in the current session without logging out, run `exec zsh`.

## 2. Install zsh

Check the live system (do not reinstall if present): `command -v zsh`, `zsh --version`, and `dpkg-query -W -f '${Status}\n' zsh` (installed only if `install ok installed`). If present, report the version and move on.

Install from the Ubuntu repository (the default channel — zsh is packaged on every supported release):

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zsh
```

Resolve the binary path with `command -v zsh` (usually `/usr/bin/zsh`) — never hardcode it. Installing the apt package normally registers the path in `/etc/shells` automatically.

These `sudo` steps (here and in §8) are subject to **ubuntu-install §3**: your shell has no terminal to type a sudo password, so probe with `sudo -n true` first. It usually passes (bootstrap offers a TUI toggle to enable passwordless sudo); if it does not, do not try to enter a password — have the user re-run `./bootstrap.sh` and turn that toggle on, or run the `sudo` lines themselves.

## 3. Decide the shape before editing anything

This skill runs on machines whose owner you've never met — do not impose taste. Present a short plan and let the user choose, with conservative recommendations:

- **Default shell:** make zsh the default login shell now, or keep bash and just launch `zsh` on demand?
- **Plugins:** `zsh-autosuggestions` + `zsh-syntax-highlighting` (recommended); extra completions (optional).
- **Prompt:** zsh's built-in prompt (safest, no fonts) / Starship / Powerlevel10k / Pure.
- **Framework:** **framework-free (recommended)** — apt plugins sourced from a plain `~/.zshrc`, fully auditable and apt-upgradable — versus **Oh My Zsh** (popular and feature-rich, but heavier and installed via a `curl | bash` script).

Then show the **exact commands** and the **exact `~/.zshrc`** you intend to write, and wait for confirmation (ubuntu-install §5) before applying.

## 4. Plugins — apt first, git as fallback

Follow the ubuntu-install channel priority:

1. **apt (preferred):** `zsh-autosuggestions` and `zsh-syntax-highlighting` are in Ubuntu *universe*. Confirm each exists with `apt-cache show <pkg>`, install it non-interactively, then find its **real source path** with `dpkg -L <pkg> | grep '\.zsh$'` — paths differ between releases, so don't assume. (Typical: `/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh` and `/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh`.)
2. **git fallback:** apt versions can lag upstream. If the user needs the latest, `git clone` into a user directory (e.g. `~/.zsh/<plugin>`) and source from there — **as the user, never with sudo** — and tell them they now own upgrades (`git pull`).

`zsh-completions` is optional — zsh's built-in completion system already covers most needs. The apt package may be absent on some releases; check first, and if you use it, add its `src` directory to `fpath` **before** `compinit`.

**Load order matters:** source `zsh-autosuggestions` before `zsh-syntax-highlighting`, and source **`zsh-syntax-highlighting` last of all** — it wraps line-editor widgets and upstream requires it be the final plugin sourced.

## 5. Write ~/.zshrc idempotently

- **Back up first.** If `~/.zshrc` exists, copy it timestamped before any change: `cp ~/.zshrc ~/.zshrc.bak.$(date +%s)`. That backup is the only undo.
- **Write it as the user, never via sudo** — `~/.zshrc` must stay user-owned. Writing a complete file yourself also stops zsh's first-run `zsh-newuser-install` wizard from firing (it would **hang a non-interactive/SSH session**).
- **If you only append** (e.g. a single `source` line), `grep -qxF` for the exact line first and append only if absent, so re-runs don't accumulate duplicates.

A sensible framework-free baseline (adjust plugin paths to what `dpkg -L` reported):

```zsh
# ~/.zshrc — managed by the zsh-setup skill. Back up before editing.

# ---- History ----
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000
setopt SHARE_HISTORY        # share history across running sessions
setopt HIST_IGNORE_DUPS     # drop consecutive duplicate commands
setopt HIST_IGNORE_SPACE    # don't record commands that start with a space
setopt HIST_REDUCE_BLANKS
setopt EXTENDED_HISTORY      # record timestamp + duration

# ---- Sensible options ----
setopt AUTO_CD               # type a dir name to cd into it
setopt AUTO_PUSHD PUSHD_IGNORE_DUPS
setopt INTERACTIVE_COMMENTS  # allow # comments at the interactive prompt
setopt NO_BEEP
bindkey -e                   # emacs key bindings

# ---- Completion ----
autoload -Uz compinit
compinit                     # if it warns about insecure directories, see §7
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
bindkey '^[[Z' reverse-menu-complete                        # Shift-Tab cycles back

# ---- History search bound to Up/Down ----
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search

# ---- Plugins (paths from `dpkg -L`; change if installed via git) ----
source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
# zsh-syntax-highlighting MUST be sourced last:
source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
```

**Migration from bash:** zsh does **not** read `~/.bashrc` or `~/.profile`. Copy any PATH additions, aliases, functions, and `export`s the user relies on into `~/.zshrc` (or `~/.zshenv` for environment that non-interactive shells also need). Scripts with a `#!/bin/bash` shebang keep running under bash regardless.

## 6. Prompt (optional) — watch the font on remote/headless boxes

- **Built-in (safest default):** keep zsh's default prompt or set a small `PROMPT`. Works everywhere, needs no fonts — the right choice on a headless server.
- **Starship:** cross-shell, single fast Rust binary. **Not in apt** — install via the official script (show the URL first: `https://starship.rs/install.sh`; it writes to `/usr/local/bin`, so it needs sudo) or snap if available. Add `eval "$(starship init zsh)"` to `~/.zshrc`; config lives in `~/.config/starship.toml`.
- **Powerlevel10k / Pure:** `git clone` + source from `~/.zshrc`. Powerlevel10k has an interactive `p10k configure` wizard.
- **Font caveat (critical over SSH):** Powerline/Nerd-Font glyphs used by Starship and Powerlevel10k render as boxes or `?` unless a Nerd Font is installed **and selected in the user's local terminal emulator (the client side)** — never on the server. On a headless server, prefer the built-in prompt, choose the prompt's ASCII / no-icon mode, or tell the user to install a Nerd Font locally first.

## 7. compinit security & first-run pitfalls

- On first run, `compinit` may print: `zsh compinit: insecure directories, run compaudit for list. Ignore insecure directories and continue [y] or abort compinit [n]?` — this prompt **hangs a non-interactive session**. It means a directory in `fpath` is group/world-writable or not owned by you or root. **Fix the cause, don't silence it:** `compaudit | xargs chmod g-w` (and `chown` to root/the user where needed), then re-run. Avoid `compinit -i` / `-u` — they only hide the check.
- Never trigger the newuser wizard on a headless box: ensure a `~/.zshrc` exists before the user's first interactive zsh (writing the file in §5 already handles this).

## 8. Make zsh the default shell — only after it's verified

This is the risky step from §1. In order:

1. Confirm zsh starts cleanly: `zsh -i -c exit` returns 0 with no error or hang. If it errors, fix `~/.zshrc` first — **do not change the shell.**
2. Ensure the path is an allowed login shell (idempotent — grep before append): `grep -qxF "$(command -v zsh)" /etc/shells || command -v zsh | sudo tee -a /etc/shells`. (apt usually added it already.)
3. Change the shell, preferring the form that won't hang:
   - `chsh -s "$(command -v zsh)"` — prompts for the **user's** password (PAM); may fail or hang without a TTY.
   - If it can't prompt or is refused: `sudo chsh -s "$(command -v zsh)" "$USER"` or `sudo usermod -s "$(command -v zsh)" "$USER"` (escalate per command only).
4. It takes effect on the **next login**, not in the current shell. Verify the stored value immediately: `getent passwd "$USER" | cut -d: -f7` should print the zsh path. Try it now without logging out via `exec zsh`.
5. **Keep your current session open** until the user confirms a fresh login lands in a working zsh.

## 9. Verify and report

Tell the user:

- zsh version (`zsh --version`), the configured login shell (`getent passwd "$USER" | cut -d: -f7`), and that an interactive zsh starts clean (`zsh -i -c exit`).
- The channel each piece came from (apt / git / install script) so future upgrades go the same way; for git and script installs, the user upgrades manually.
- Follow-ups they must do themselves: log out and back in (or open a new SSH session) for the default-shell change to take effect; install a Nerd Font locally if they chose an icon-heavy prompt.

## Rollback

- **Login shell back to bash:** `chsh -s /bin/bash` (or `sudo chsh -s /bin/bash "$USER"`); verify with `getent`.
- **Config:** restore the timestamped `~/.zshrc.bak.<...>`.
- **Remove zsh:** only after the login shell is back to bash for **every** affected user (removing zsh while it is someone's login shell breaks their login). Then `sudo apt-get remove zsh` (`purge` also deletes config); mention leftover dotfiles (`~/.zshrc`, `~/.zsh_history`) so the user can decide about them.

## Quick reference

| Task | Command |
| --- | --- |
| Is zsh installed? | `command -v zsh && zsh --version` |
| Install zsh | `sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends zsh` |
| Find a plugin's source path | `dpkg -L zsh-autosuggestions \| grep '\.zsh$'` |
| Test config without logging in | `zsh -i -c exit` |
| Allow zsh as login shell | `grep -qxF "$(command -v zsh)" /etc/shells \|\| command -v zsh \| sudo tee -a /etc/shells` |
| Set default shell | `chsh -s "$(command -v zsh)"` (fallback: `sudo chsh -s "$(command -v zsh)" "$USER"`) |
| Check configured login shell | `getent passwd "$USER" \| cut -d: -f7` |
| Switch current session now | `exec zsh` |
| Revert to bash | `chsh -s /bin/bash` |

## Common mistakes

- **Changing the login shell before zsh is proven to start cleanly** → lockout on a remote box. Always `zsh -i -c exit` first, and keep a session open.
- Hardcoding plugin source paths instead of reading them from `dpkg -L`.
- Sourcing `zsh-syntax-highlighting` anywhere but **last**.
- Letting the `zsh-newuser-install` wizard or the `compinit` insecure-directories prompt run on a non-interactive/SSH session → it hangs. Write `~/.zshrc` up front; fix `compaudit` permissions rather than suppressing.
- Using `sudo` for user-directory git clones or to write `~/.zshrc` → wrong ownership.
- Expecting `chsh` to change the **current** shell (it only affects new logins; use `exec zsh` to switch now).
- Choosing a Nerd-Font prompt for a server while the font is missing in the **local** terminal → glyphs show as boxes.
