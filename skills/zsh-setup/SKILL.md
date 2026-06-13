---
name: zsh-setup
description: Use when the user wants to install, set up, configure, customize, or switch to the Z shell (zsh) on Ubuntu/Debian — including making zsh the default login shell, adding autosuggestions / syntax-highlighting / completions, choosing a prompt (Starship, Powerlevel10k, Pure) or a framework (Oh My Zsh), or writing a ~/.zshrc. Drives scripts/zsh.sh in the ubuntu-setup kit and extends it when a capability is missing. Covers headless servers reached over SSH.
---

# Zsh Setup on Ubuntu

The mechanics of installing and safely configuring zsh now live in a script —
**`scripts/zsh.sh`** in the ubuntu-setup kit, runnable as `swkit zsh <op>`. That script,
not this prose, is the single implementation: it sources `lib/common.sh` (per-command
sudo, idempotency probes, non-interactive apt, back-up-before-edit) so every safety
non-negotiable is met by construction. The old arrangement, where the same config logic
was duplicated in `bootstrap.sh`'s bash *and* spelled out here, is gone.

So this skill has two jobs the script can't do for itself:

1. **The taste conversation** — choosing prompt, framework, and what to put in `~/.zshrc`
   on a machine whose owner you've never met (§2). The script ships one conservative,
   safe baseline; everything opinionated is a conversation.
2. **Evolving `scripts/zsh.sh`** — when the user wants something the script doesn't do yet
   (a Starship prompt option, Oh My Zsh, an extra plugin), you *extend the script* under
   the **ubuntu-install** authoring contract, rather than improvising raw commands (§4).

Everything `zsh.sh` does is subject to **ubuntu-install §3** for sudo. Your shell has no
terminal to type a password; the lib's `sudo_run` probes with `sudo -n true` and, if a
password is needed, prints the exact command and returns exit code 97 instead of hanging.
If that happens, have the user enable passwordless sudo (re-run `./bootstrap.sh`, turn on
the toggle) or run the printed `sudo` line themselves — never enter, pipe, or store a
password, never write a NOPASSWD rule.

**Read §3 (lockout safety) before changing anyone's login shell.** It is the only action
here that can lock a user out of a remote box.

## 1. What the script already does — point the user at it

Probe first, then run only what's needed (the script is idempotent — re-running is a safe
no-op, so when in doubt, run it):

- **`swkit zsh status`** — prints `zsh --version`; exit 0 iff zsh is installed. The
  idempotency probe.
- **`swkit zsh install`** — installs zsh via apt (skips if already present).
- **`swkit zsh configure`** — writes a **safe baseline** and stops there. Specifically it:
  - apt-installs `zsh-autosuggestions` and `zsh-syntax-highlighting`, then resolves each
    plugin's source path from the **live package layout** (`dpkg -L … | grep '\.zsh$'`),
    never hardcoded;
  - writes `~/.zshrc` **as the user** (never via sudo, so it stays user-owned) with
    sensible history, options, and completion settings, then the two plugin `source`
    lines — autosuggestions first, **syntax-highlighting sourced last** (upstream requires
    it be the final plugin). Writing a full file also stops the `zsh-newuser-install`
    wizard from hanging a non-interactive session;
  - is guarded by a marker line (`# managed by ubuntu-setup zsh.sh`): if `~/.zshrc`
    already has it, the script leaves the file untouched; otherwise it backs up any
    existing `~/.zshrc` first.
  - It does **not** change the login shell.
- **`swkit zsh configure --no-plugins`** — same baseline `~/.zshrc` without the two apt
  plugins or their source lines.
- **`swkit zsh configure --default-shell`** — the lockout-safe shell switch (still read
  §3): it verifies an interactive zsh starts cleanly with `zsh -i -c exit` *before* it
  touches `chsh`, ensures the zsh path is in `/etc/shells`, then `sudo chsh -s` for the
  real target user (resolved via `SUDO_USER`, never a blind `$HOME`). If `zsh -i -c exit`
  fails it refuses and tells the user to fix `~/.zshrc` first.
- **`swkit zsh remove`** — uninstalls zsh via apt, but **refuses if zsh is the user's login
  shell** (that would break their login); it tells them to `chsh -s /bin/bash` first.

When the user just wants "set up zsh," that's usually `install` → `configure` → (after the
taste conversation and the lockout check) `configure --default-shell`.

## 2. The taste conversation (this skill's real value)

You're on a stranger's machine — **don't impose taste.** Lay out the choices, recommend
conservative defaults (especially for a headless server), and let the user decide. The
script's baseline is deliberately minimal; these are the decisions it can't make:

- **Default shell or not?** Make zsh the login shell now (`configure --default-shell`,
  read §3), or keep bash and just launch `zsh` on demand?
- **Prompt:**
  - **Built-in (safest default, recommended for headless servers):** zsh's own prompt or a
    small `PROMPT`. Works everywhere, needs no fonts.
  - **Starship:** cross-shell, single fast Rust binary; not in apt (official installer
    writes to `/usr/local/bin`; show the URL `https://starship.rs/install.sh`).
  - **Powerlevel10k / Pure:** `git clone` + source; p10k has an interactive `p10k
    configure` wizard.
  - None of these are in `zsh.sh` yet — adding one means **evolving the script** (§4).
- **Framework:** **framework-free (recommended)** — apt plugins sourced from a plain
  `~/.zshrc`, fully auditable and apt-upgradable; this is what `zsh.sh configure` already
  does — versus **Oh My Zsh** (popular, feature-rich, but heavier and installed via a
  `curl | bash` script). Oh My Zsh is also not in the script (§4).
- **Nerd Font caveat (critical over SSH):** Powerline/Nerd-Font glyphs used by Starship and
  Powerlevel10k render as boxes or `?` unless a Nerd Font is installed and selected in the
  user's **local** terminal emulator (the client side) — never on the server. On a headless
  box, prefer the built-in prompt or the prompt's ASCII/no-icon mode, or tell the user to
  install a Nerd Font locally first.

Present the exact plan (which `swkit` commands, what `~/.zshrc` will contain, which steps
need sudo and whether `sudo -n true` currently passes) and wait for confirmation before
applying — ubuntu-install §5.

## 3. Lockout safety (still critical to understand)

Changing a user's login shell on a remote machine is the one action that can make them
unable to log in. `zsh.sh configure --default-shell` already does the in-script guards
(verifies `zsh -i -c exit`, ensures `/etc/shells`, resolves the real user), but **the
operational discipline is still yours**:

- **Install and fully configure first; change the login shell last.** Get a working
  `~/.zshrc` in place (and a clean `zsh -i -c exit`) before running `--default-shell`.
- **Keep the current session open.** `chsh` only affects *new* logins — your current shell
  doesn't change. After the switch, have the user open a *fresh* login (new SSH session)
  and confirm they land in a working zsh **before** closing the session you already have.
- To try zsh in the current session without logging out: `exec zsh`.
- Verify the stored value: `getent passwd "$USER" | cut -d: -f7` should print the zsh path.

If anything is wrong on the fresh login, the still-open session is the escape hatch:
`chsh -s /bin/bash` (or `sudo chsh -s /bin/bash "$USER"`) reverts it.

## 4. Evolving `scripts/zsh.sh` (don't run raw commands instead)

Anything the script doesn't do yet — a `--prompt starship` option, an Oh My Zsh install, an
extra plugin, `zsh-completions`, richer `~/.zshrc` settings — should be added **to the
script**, not improvised as one-off commands. Functionality stays in the script so every
entry point (the TUI, `swkit`, you) shares one tested, idempotent, git-tracked
implementation. Follow the **ubuntu-install** authoring contract:

1. Edit `scripts/zsh.sh` in the kit at `~/.local/share/ubuntu-setup/` (it's a git repo).
   Keep the structure: it already sources `lib/common.sh` and ends with `kit_dispatch "$@"`.
   Add new behaviour as a flag in `do_configure`'s option loop (mirroring `--default-shell`
   / `--no-plugins`), or as a new helper; if you add a brand-new operation, update `meta`'s
   `ops` to list exactly what's implemented.
2. **Use lib helpers for all privilege/package/file work** — `apt_install`, `apt_remove`,
   `add_apt_keyring`/`add_apt_source` for a vendor apt repo, `backup_file`, `append_once`,
   `sudo_run`. Never write a raw `sudo`, raw `apt-get`, `apt-key`, or `sudo npm`. Unsafe
   patterns have no helper on purpose.
3. **Channel priority:** apt → vendor apt repo → snap → official vendor script (show the
   URL) → manual binary (last resort). E.g. Starship has no apt package, so it's the
   official-script tier — `do_configure` should print the URL and use `sudo_run` for the
   `/usr/local/bin` install, never a blind `curl | sudo bash`.
4. **Idempotent & safe:** gate on `status`/the live system; `backup_file` before editing any
   config; grep-before-append (`append_once`); never write `~/.zshrc` via sudo. Plan before
   apply, fail fast, no rollback — re-run is the recovery (hence idempotency).
5. **Test, then commit:** `bash -n scripts/zsh.sh`, run the script's own `status` and the new
   path before/after, then run for real. Changes are git-tracked under the kit; commit with
   a clear message and consider a PR upstream so other machines get the improvement.

If the user only wants a one-off experiment they don't want recorded, say so explicitly —
but the default is: extend the script.

## 5. Boundary with bootstrap's TUI

`bootstrap.sh`'s TUI ("Install software → zsh → Configure") runs `zsh.sh configure` with
no extra args — i.e. the **safe baseline only** (plugins + `~/.zshrc`), **no shell change**.
There is no longer any zsh logic duplicated in the bootstrap bash: the TUI just invokes the
same script you do. Deep or opinionated configuration — a non-default prompt, a framework,
the login-shell switch, anything bespoke in `~/.zshrc` — is this skill's job: the taste
conversation (§2) plus, where the capability is missing, evolving the script (§4).

## 6. Reference — understanding behind the script

These are the details to *understand* (and to preserve when you evolve the script); most are
already handled by `zsh.sh`, noted inline.

- **Plugin load order.** Source `zsh-autosuggestions` *before* `zsh-syntax-highlighting`, and
  source **`zsh-syntax-highlighting` last of all** — it wraps line-editor widgets and
  upstream requires it be the final plugin. *(`zsh.sh configure` already emits them in this
  order.)*
- **Plugin source paths come from `dpkg -L`,** never hardcoded — they differ between Ubuntu
  releases (typically `/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh` and
  `/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh`, but verify). *(`zsh.sh`
  resolves them at configure time.)*
- **`compinit` insecure-directories pitfall.** On first run `compinit` may print
  *"insecure directories, run compaudit … Ignore … [y] or abort [n]?"* — a prompt that
  **hangs a non-interactive/SSH session**. It means a directory in `fpath` is group/world-
  writable. **Fix the cause, don't silence it:** `compaudit | xargs chmod g-w` (and `chown`
  to root/the user where needed), then re-run. Avoid `compinit -i`/`-u`, which only hide the
  check. If you add `zsh-completions` (or any `fpath` entry), add its dir to `fpath` *before*
  `compinit`.
- **Newuser wizard.** Never let `zsh-newuser-install` fire on a headless box — it hangs.
  Ensuring `~/.zshrc` exists before the first interactive zsh prevents it. *(`zsh.sh` writes
  a complete `~/.zshrc`, so this is covered.)*
- **Migration from bash.** zsh does **not** read `~/.bashrc` or `~/.profile`. Copy any PATH
  additions, aliases, functions, and `export`s the user relies on into `~/.zshrc` (or
  `~/.zshenv` for environment non-interactive shells also need). `#!/bin/bash` scripts keep
  running under bash regardless. *(The baseline `zsh.sh` writes does not migrate these — flag
  it to the user, or evolve the script if they want it automated.)*
- **Rollback.** There's no automatic rollback. Login shell back to bash: `chsh -s /bin/bash`
  (or `sudo chsh -s /bin/bash "$USER"`), verify with `getent`. Config: restore the
  timestamped `~/.zshrc.bak.<…>` that `backup_file` left. Removing zsh: only after the login
  shell is back to bash for every affected user — `swkit zsh remove` enforces this and uses
  apt `remove` (not `purge`), so `~/.zshrc` / `~/.zsh_history` survive for the user to decide
  about.

## 7. Verify and report

After any change, verify against the live system and tell the user:

- `swkit zsh status` (or `zsh --version`), the configured login shell
  (`getent passwd "$USER" | cut -d: -f7`), and that an interactive zsh starts clean
  (`zsh -i -c exit`).
- Which channel each piece came from (apt / git / install script) so future upgrades go the
  same way — and that you recorded the *how* in `scripts/zsh.sh` if you evolved it.
- Follow-ups the user must do themselves: log out and back in (or open a new SSH session) for
  a default-shell change to take effect; install a Nerd Font locally if they chose an
  icon-heavy prompt.

## Common mistakes

- **Improvising raw install commands** instead of running or evolving `scripts/zsh.sh` — the
  whole point of the kit is one tested, idempotent, reviewable implementation.
- **Changing the login shell before zsh is proven to start cleanly** → lockout on a remote
  box. `--default-shell` checks `zsh -i -c exit`, but still keep a session open and confirm a
  fresh login.
- Hardcoding plugin source paths instead of reading them from `dpkg -L`.
- Sourcing `zsh-syntax-highlighting` anywhere but **last**.
- Letting the `zsh-newuser-install` wizard or the `compinit` insecure-dirs prompt run on a
  non-interactive/SSH session → it hangs. Write `~/.zshrc` up front; fix `compaudit`
  permissions rather than suppressing.
- Using `sudo` to write `~/.zshrc` or for user-directory git clones → wrong ownership.
- Expecting `chsh` to change the **current** shell (it only affects new logins; use
  `exec zsh` to switch now).
