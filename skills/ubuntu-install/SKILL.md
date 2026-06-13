---
name: ubuntu-install
description: Install, remove, upgrade, or query software on an Ubuntu machine (including Server/headless over SSH). Use whenever the user asks to install, uninstall, update, or check any software, package, tool, runtime, or service on Ubuntu.
---

# Ubuntu Software Management Rules

You are operating on a real Ubuntu machine (20.04+), possibly a headless server reached over SSH. There is no rollback for system changes. Follow every rule below — they protect the user's machine.

## 1. Check the live system first (idempotency)

Before installing anything, determine whether it is already in place by querying the **live system** — never assume, never trust memory or notes:

- CLIs: `command -v <cmd>` and `<cmd> --version`
- apt packages: `dpkg-query -W -f '${Status} ${Version}\n' <pkg>` — installed only if status is exactly `install ok installed` (removed-but-not-purged also produces output; don't be fooled)
- snaps: `snap list <name>`
- services: `systemctl status <unit>` (read the printed state; don't treat the exit code as a boolean)
- repos/keys/config: check the actual file on disk

If it is already installed: **report the version and stop — do not reinstall.** The same applies to each individual step of a multi-step install (keyring files, sources.list.d entries, config blocks, group memberships): the whole procedure must be safe to run twice, converging instead of accumulating.

## 2. Channel priority

Choose the install channel in this order, and tell the user which one you picked and why:

1. **Ubuntu apt repository** (`apt-get install`) — the default. Auditable, easily removed and upgraded. Use unless the packaged version is too old for the user's need.
2. **Vendor official apt repository** — when a current version matters (docker, nodejs, postgresql, …). Put the key in `/etc/apt/keyrings/` (dearmored, `chmod a+r`), reference it with `signed-by=` in `/etc/apt/sources.list.d/<name>.list`. **Never use `apt-key`** — it is dead.
3. **snap** — when there is no good apt option or the vendor's primary channel is snap. One snap per `snap install` command (a multi-snap install fails if some are already present).
4. **Official vendor install script** (`curl | bash`) — only when the vendor documents no better channel. Show the user the URL first; never pipe an unofficial URL to a shell.
5. **Manual binary** (e.g. GitHub releases into `/usr/local/bin` or `~/.local/bin`) — last resort; note that the user must handle upgrades manually.

## 3. Privilege and non-interactive rules

- Escalate **per command** with `sudo`. Never tell the user to open a root shell, and never run long scripts wholesale as root.
- Every apt mutation must be non-interactive and lean:
  `sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends <pkg>`
  (`DEBIAN_FRONTEND` goes **after** `sudo` — sudo strips the caller's environment.)
- Run `sudo apt-get update` only when you are about to install something, not as a ritual.
- **Never** `sudo npm install -g`, `sudo pip install`, or similar language-package-manager-as-root commands. Use user-writable prefixes (`npm config set prefix ~/.local`, `pip install --user`, pipx) instead.
- User-level files must end up owned by the user — never create files in `$HOME` from inside a sudo command.

**You have no interactive terminal, so you cannot type a sudo password.** A `sudo` that needs one will error (`a terminal is required` / `no tty present` / sudo-rs: `interactive authentication is required`) or hang. Before any sudo step:

- **Probe first:** run `sudo -n true` and branch on its **exit status**, never the message text (the wording differs between classic sudo and sudo-rs and may be localized). Exit 0 → sudo is passwordless right now — proceed. This is the common case: the project's `bootstrap.sh` offers to set up passwordless sudo (a `/etc/sudoers.d/ubuntu-setup-llm` NOPASSWD rule) and cloud images often ship it too. Exit non-zero → a password is required and you cannot supply it.
- **When a password is required, never** echo / pipe / here-string it into `sudo -S`, store it in a file or env var, or write a NOPASSWD rule yourself. Stop, explain that your shell can't enter a sudo password, and offer: **(1)** re-run the project bootstrap, `./bootstrap.sh`, and turn passwordless sudo **ON** in its TUI toggle (revoke later by toggling it off, or `sudo rm /etc/sudoers.d/ubuntu-setup-llm`) — the normal way to make LLM-driven installs work unprompted; or **(2)** have the user run the exact `sudo …` command(s) you present **themselves** in their own terminal and confirm.
- Passwordless root is a security boundary: it is established only with the user's consent at the bootstrap prompt, never silently by you.

## 4. Back up before editing any config file

Before modifying an existing configuration file, make a timestamped copy next to it:

- System file: `sudo cp /etc/foo/foo.conf /etc/foo/foo.conf.bak.$(date +%s)`
- User dotfile: `cp ~/.bashrc ~/.bashrc.bak.$(date +%s)`

When appending to shell rc files, grep for the exact line first and only append if absent (otherwise re-runs accumulate duplicates). Prefer editing in place over rewriting whole files; never clobber content you did not write.

## 5. Plan before apply; fail fast

- Before executing, present the **exact list of commands** you intend to run (including every `sudo` command) and wait for the user's confirmation. Say which steps need `sudo` and whether `sudo -n true` shows it is currently passwordless, so the user knows up front whether they must enable passwordless sudo (§3) or run the privileged steps themselves.
- Surface destructive actions loudly: `remove` vs `purge` (purge deletes config), repo removals, `--reinstall`. Get explicit confirmation for these.
- Execute step by step; **stop at the first failure**. Report which step failed, show the relevant stderr, and suggest concrete diagnosis commands (e.g. `apt-get install -y <pkg> 2>&1 | tail`, `journalctl -u <unit> -n 50`, `systemctl status <unit>`). Do not improvise risky fixes; ask the user.
- After a failure is fixed, re-running the plan is safe because every step checks the live system first (rule 1).

## 6. Verify and report

After installing or upgrading, verify against the live system and tell the user:

- the version actually present (`<cmd> --version`, `dpkg-query -W <pkg>`)
- for services: `systemctl is-active <unit>` / `systemctl status <unit>`, and whether it is enabled at boot
- the channel used (so future upgrades go through the same channel)
- any follow-up the user must do themselves: open a new shell for PATH changes, re-login after `sudo usermod -aG docker $USER`, etc.

For removals, verify the artifact is gone and mention any leftovers (config files kept by `remove`, data directories) so the user can decide about them.
