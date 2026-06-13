---
name: zsh-setup
description: Use when the user wants to install, set up, configure, customize, or switch to the Z shell (zsh) on Ubuntu/Debian — including making zsh the default login shell, adding autosuggestions / syntax-highlighting / completions, choosing a prompt (Starship, Powerlevel10k, Pure) or a framework (Oh My Zsh), or writing a ~/.zshrc. Drives scripts/zsh.sh in the ubuntu-setup kit (which installs the frameworks/prompts and manages the config) and extends it when a capability is missing. Covers headless servers reached over SSH.
---

# Zsh Setup on Ubuntu

The mechanics of installing and configuring zsh live in a script — **`scripts/zsh.sh`** in
the ubuntu-setup kit, runnable as `swkit zsh <action>`. That script, not this prose, is the
single implementation: it sources `lib/common.sh` (per-command sudo, idempotency probes,
non-interactive apt, back-up-before-edit) so the safety non-negotiables are met by
construction.

**`configure` is manageable, not one-time.** It (re)generates a managed drop-in
`~/.config/zsh/ubuntu-setup.zsh` **wholesale on every run** and sources it from `~/.zshrc`
via a single idempotent line. Re-running updates the managed settings to the latest without
clobbering the user's own `~/.zshrc`. The old arrangement (one-shot write, duplicated in
`bootstrap.sh`'s bash) is gone.

**The script already covers the common setups** — a rich headless-safe baseline plus, on
request, frameworks (**Oh My Zsh**) and prompts (**git / plain / Starship / Powerlevel10k /
Pure**), and the lockout-safe default-shell switch. So your job here is:

1. **Help the user choose** among those options — prompt, framework, whether to switch the
   login shell — on a machine whose owner you've never met (§2), then invoke the right
   action/flags. Don't impose taste; recommend conservative defaults for headless servers.
2. **Evolve `scripts/zsh.sh`** when the user wants something it doesn't do yet — a new
   prompt, an extra plugin, `zsh-completions` — by *extending the script* under the
   **ubuntu-install** authoring contract (§4), not improvising raw commands.

Everything `zsh.sh` does is subject to **ubuntu-install §5** for sudo: your shell has no
terminal to type a password; the lib's `sudo_run` probes with `sudo -n true` and, if a
password is needed, prints the exact command and returns exit code 97 instead of hanging.
Relay that — have the user enable passwordless sudo (re-run `./bootstrap.sh`, toggle it on)
or run the printed `sudo` line themselves. Never enter/pipe/store a password or write NOPASSWD.

**Read §3 (lockout safety) before changing anyone's login shell** — the one action here that
can lock a user out of a remote box.

## 1. What the script does — actions, flags, channels

Run as `swkit zsh <action>` (or `scripts/zsh.sh <action>`). Probe first; the script is
idempotent (re-running is a safe no-op / converge), so when in doubt, run it.

**Actions (also shown in the bootstrap TUI):**
- **`status`** — `zsh --version`; exit 0 iff installed. The idempotency probe.
- **`install`** — install zsh via apt.
- **`configure [flags]`** — (re)generate `~/.config/zsh/ubuntu-setup.zsh` and source it from
  `~/.zshrc`. With no flags this is the **conservative headless-safe baseline**:
  - history (50k, `SHARE_HISTORY` + dedup/space/verify options), sensible `setopt`s
    (`AUTO_CD`, `AUTO_PUSHD`, `EXTENDED_GLOB`, `INTERACTIVE_COMMENTS`, `NO_BEEP`, …),
  - completion (`compinit` with a daily-cached dump in `~/.cache/zsh`, case-insensitive +
    partial matching, `LS_COLORS` via `dircolors`, menu select, completer chain),
  - keybindings (`bindkey -e`, terminfo-guarded Home/End/Delete/PageUp-Down, Up/Down history
    search via `up/down-line-or-beginning-search`, Shift-Tab),
  - color aliases (`ls/grep/diff --color=auto`, `ll/la/l`) — **not** `rm -i`/`cp -i`/`mv -i`,
  - a **git-branch ASCII prompt** (vcs_info; no Nerd Font needed),
  - the apt plugins **zsh-autosuggestions** then **zsh-syntax-highlighting** (sourced **last**).
- **`oh-my-zsh`** — preset = `configure --framework oh-my-zsh`.
- **`starship`** — preset = `configure --prompt starship`.
- **`default-shell`** — make zsh the default login shell, lockout-safe (§3). Also reachable as
  `configure --default-shell`.
- **`remove`** — uninstall zsh via apt (refuses if zsh is the login shell — `chsh` back to bash first).

**`configure` flags (for `swkit`/you; full control):**
- `--framework none|oh-my-zsh` (default `none`)
- `--prompt git|plain|starship|powerlevel10k|pure` (default `git`)
- `--default-shell` · `--no-plugins` · `--no-aliases`

**Install channels the script uses (idempotent; skipped if already present):**
- **Oh My Zsh** — official installer (`https://github.com/ohmyzsh/ohmyzsh/raw/master/tools/install.sh`)
  run **unattended, `--keep-zshrc`** (no shell change, keeps our `~/.zshrc`); clones to `~/.oh-my-zsh`.
  The drop-in then sources `oh-my-zsh.sh` and still sources the apt plugins after it (syntax-highlighting last).
- **Starship** — official installer into **`~/.local/bin` (no sudo)**; drop-in adds `eval "$(starship init zsh)"`.
- **Powerlevel10k / Pure** — `git clone` into `~/.config/zsh/{powerlevel10k,pure}`; sourced from the drop-in.
- **Font caveat (critical over SSH):** Starship and Powerlevel10k default to Nerd-Font glyphs that
  render as boxes unless a Nerd Font is installed in the user's **local** terminal. Pure and the
  git/plain prompts need no fonts — prefer them on headless boxes. Powerlevel10k's `p10k configure`
  wizard is interactive — the script installs+sources p10k; tell the user to run `p10k configure` themselves.

## 2. Helping the user choose (this skill's real value)

You're on a stranger's machine — **don't impose taste.** Lay out the choices, recommend
conservative defaults (especially for a headless server), then run the matching action/flags.

- **Default shell or not?** `swkit zsh default-shell` (or `configure --default-shell`), read §3.
- **Prompt:**
  - **git (default) / plain** — ASCII, no fonts, safe everywhere (recommended for headless).
  - **Starship** — `--prompt starship` (Nerd Font for icons).
  - **Powerlevel10k** — `--prompt powerlevel10k` (Nerd Font; then `p10k configure`).
  - **Pure** — `--prompt pure` (minimal, no fonts — a good "fancy but headless-safe" pick).
- **Framework:** **framework-free (default, recommended)** — apt plugins from a clean drop-in,
  auditable and apt-upgradable — versus **Oh My Zsh** (`--framework oh-my-zsh`; popular and
  feature-rich, heavier, installed via the official `curl | sh` script).

Present the exact plan (which `swkit zsh …` command, what it will install/write, which steps
need sudo and whether `sudo -n true` passes) and wait for confirmation — ubuntu-install §5.

## 3. Lockout safety (read before changing the login shell)

Changing a user's login shell on a remote machine is the one action that can make them unable
to log in. `default-shell` / `configure --default-shell` already does the in-script guards —
it verifies an interactive zsh starts cleanly (`timeout … zsh -i -c 'exit 0'`) **before** any
`chsh`, ensures the zsh path is in `/etc/shells`, and resolves the real target user — but **the
operational discipline is still yours**:

- **Install and fully configure first; change the login shell last.** Get a working config (run
  `configure` and confirm a clean interactive start) before `default-shell`.
- **Keep the current session open.** `chsh` only affects *new* logins. After the switch, have
  the user open a *fresh* login (new SSH session) and confirm they land in a working zsh **before**
  closing the session you already have.
- Try zsh in the current session without logging out: `exec zsh`. Verify the stored shell:
  `getent passwd "$USER" | cut -d: -f7`.

If a fresh login is broken, the still-open session is the escape hatch: `chsh -s /bin/bash`
(or `sudo chsh -s /bin/bash "$USER"`) reverts it.

## 4. Evolving `scripts/zsh.sh` (for what it doesn't cover yet)

The common setups are built in (above). For anything else — a new prompt option, an extra
plugin, `zsh-completions`, a richer `~/.zshrc` setting — add it **to the script**, not as one-off
commands, so every entry point (the TUI, `swkit`, you) shares one tested, idempotent, git-tracked
implementation. Follow the **ubuntu-install** authoring contract:

1. Edit `scripts/zsh.sh` in the kit at `~/.local/share/ubuntu-setup/` (a git repo). It already
   sources `lib/common.sh` and ends with `kit_dispatch "$@"`. Add behaviour as a new value in
   `do_configure`'s `--prompt`/`--framework` parsing and a matching branch in `_zsh_emit_dropin`
   (and an installer like `_zsh_ensure_*`), or expose a new top-level action by adding it to
   `meta`'s `ops=` and defining `do_<action>` (hyphens map to underscores; e.g. a `prezto` action
   → `do_prezto`). Keep the drop-in's load order: `compinit` and all `zle -N` widget defs before
   sourcing plugins; **zsh-syntax-highlighting sourced last**.
2. **Use lib helpers for all privilege/package/file work** — `apt_install`, `add_apt_keyring`/
   `add_apt_source` for a vendor repo, `backup_file`, `append_once`, `sudo_run`. Never raw `sudo`,
   `apt-get`, `apt-key`, or `sudo npm`. Resolve plugin paths from `dpkg -L` (match the **main**
   entry-point file by name, not just the first `*.zsh`).
3. **Channel priority:** apt → vendor apt repo → snap → official vendor script (show the URL) →
   manual binary. Install into user space where possible (no sudo); the drop-in/`~/.zshrc` are
   written as the user — never via sudo.
4. **Idempotent & safe:** gate installs on the live system; back up before editing; the drop-in is
   regenerated wholesale (no in-place edits). Test (`bash -n`, then `timeout … zsh -i -c 'exit 0'`),
   commit with a clear message, consider a PR upstream.

## 5. Boundary with bootstrap's TUI

The bootstrap TUI lists zsh's actions dynamically from its `meta` — **install / configure /
oh-my-zsh / starship / default-shell / remove**. The TUI's plain **Configure** runs `configure`
with no args = the **safe baseline** (framework-free, git prompt, plugins, color aliases), **no
shell change**. Picking **oh-my-zsh** / **starship** / **default-shell** runs those presets. Finer
combinations (e.g. `--framework oh-my-zsh --prompt starship`, `--no-aliases`) and prompts without a
dedicated action (Powerlevel10k, Pure) go through `swkit zsh configure --…` or you. There is no zsh
logic duplicated in the bootstrap bash — every entry point invokes this one script. Truly bespoke
configuration is the taste conversation (§2) plus, where a capability is missing, evolving the script (§4).

## 6. Reference — understanding behind the script

Details to *understand* (and preserve when you evolve the script); most are already handled by
`zsh.sh`, noted inline.

- **Plugin load order.** Source `zsh-autosuggestions` before `zsh-syntax-highlighting`, and source
  **`zsh-syntax-highlighting` last of all** — it wraps line-editor widgets and must be final.
  With Oh My Zsh, the apt plugins are sourced *after* `oh-my-zsh.sh`, syntax-highlighting still last.
  *(`zsh.sh` emits them in this order.)*
- **Plugin source paths from `dpkg -L`,** never hardcoded — and match the **main** file by name
  (`/zsh-syntax-highlighting.zsh$`), since the package also ships `highlighters/*/*.zsh` that must
  NOT be sourced directly. *(`zsh.sh` resolves them this way.)*
- **`compinit` insecure-directories pitfall.** On first run `compinit` may prompt about insecure
  directories — which **hangs a non-interactive/SSH session**. Fix the cause, don't silence it:
  `compaudit | xargs chmod g-w` (and `chown` where needed), then re-run. Avoid `compinit -i`/`-u`.
  With Oh My Zsh, omz runs its own `compinit` (the drop-in skips ours to avoid a double init).
- **Newuser wizard.** Never let `zsh-newuser-install` fire on a headless box — it hangs. The source
  line in `~/.zshrc` means the file always exists, which prevents it. *(handled by `zsh.sh`.)*
- **Migration.** An older fully-managed `~/.zshrc` (first line `# managed by ubuntu-setup zsh.sh`)
  is backed up and replaced by the one-line source model; if the user had personal lines, they are
  in the `.bak` — tell them to copy any back into `~/.zshrc` (sourced before the drop-in).
- **Migration from bash.** zsh does not read `~/.bashrc`/`~/.profile`. Copy PATH/aliases/functions/
  `export`s into `~/.zshrc` (or `~/.zshenv`). The baseline does not migrate these — flag it, or
  evolve the script if the user wants it automated.
- **Rollback.** No automatic rollback. Login shell back to bash: `chsh -s /bin/bash`. Config: remove
  the source line from `~/.zshrc` and delete `~/.config/zsh/ubuntu-setup.zsh` (the user's own
  `~/.zshrc` is untouched), or restore a timestamped `.bak`. Remove zsh only after the login shell
  is back to bash for every affected user — `swkit zsh remove` enforces this and uses apt `remove`
  (not `purge`), so dotfiles survive.

## 7. Verify and report

After any change, verify against the live system and tell the user:
- `swkit zsh status` (or `zsh --version`), the configured login shell
  (`getent passwd "$USER" | cut -d: -f7`), and that an interactive zsh starts clean
  (`zsh -i -c 'exit 0'`).
- Which channel each piece came from (apt / official installer / git clone) so upgrades go the same
  way — and that you recorded the *how* in `scripts/zsh.sh` if you evolved it.
- Follow-ups the user must do themselves: log out / open a new SSH session for a default-shell change
  to take effect; install a Nerd Font locally for Starship/Powerlevel10k icons; run `p10k configure`.

## Common mistakes

- **Improvising raw install commands** instead of running or evolving `scripts/zsh.sh` — the whole
  point of the kit is one tested, idempotent, reviewable implementation.
- **Editing the managed drop-in by hand** — it's regenerated wholesale on every `configure`; put
  personal settings in `~/.zshrc` (sourced before it) instead.
- **Changing the login shell before zsh is proven to start cleanly** → lockout on a remote box.
  `default-shell` checks `zsh -i -c 'exit 0'` (with a timeout), but still keep a session open and
  confirm a fresh login.
- Hardcoding plugin source paths, or grabbing the first `*.zsh` instead of the main entry-point.
- Sourcing `zsh-syntax-highlighting` anywhere but **last**.
- Letting the `zsh-newuser-install` wizard or the `compinit` insecure-dirs prompt run on a
  non-interactive/SSH session → it hangs. (The source line keeps `~/.zshrc` present; fix
  `compaudit` permissions rather than suppressing.)
- Choosing a Nerd-Font prompt (Starship/Powerlevel10k) for a server while the font is missing in
  the **local** terminal → glyphs show as boxes. Prefer git/plain/Pure on headless boxes.
- Expecting `chsh` to change the **current** shell (it only affects new logins; use `exec zsh`).
