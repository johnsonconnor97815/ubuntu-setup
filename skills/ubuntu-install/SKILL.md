---
name: ubuntu-install
description: Install, remove, upgrade, or query software on an Ubuntu machine (including Server/headless over SSH) by driving a collection of per-software scripts (run via `swkit`). Use whenever the user asks to install, uninstall, update, or check any software, package, tool, runtime, or service on Ubuntu.
---

# Ubuntu Software Management

You manage software on a real Ubuntu machine (20.04+), possibly a headless server over SSH. There is no rollback for system changes. Re-running is the only recovery, so every step must be idempotent.

## 1. The model: scripts are the implementation; you USE them

All install/remove/configure logic lives in a **collection of per-software bash scripts**, one per piece of software, with a uniform interface. They source a shared library, `lib/common.sh`, that encodes this project's safety contract as code — so calling its helpers makes the non-negotiables true by construction. **You do not improvise raw `apt`/`curl | bash`/`sudo` commands; you run a script.** When no script fits, that is a gap to fill in the repo (see §3), not something to improvise on the user's machine.

- The kit **runs in place from the clone** of the project repo (wherever it was cloned). There is no separate deployed copy; `swkit` on `PATH` is a symlink into that clone.
- **`swkit`** is on `PATH` — the launcher that runs scripts and discovers the collection.
- Each script also exposes a **`ui` entry mode** — an interactive full-screen management screen (`scripts/<x>.sh ui`, or `swkit <x>`). It is rendered by **`lib/common.sh`'s twin, `lib/ui.sh`** (modern TUI primitives, no whiptail). `ui` is **not** a `meta` op; on your no-TTY shell it prints how to drive the script by explicit op and exits 0 — so you keep the programmatic interface and never get stuck in a menu.
- The repo ships a growing **seed set** plus the machinery — run `swkit list` for the current set (it includes editors `vscode` / `cursor`, runtimes `node` / `go` / `python`, `git`, `curl`, `zsh`, `fonts`, `docker`, the terminals `ghostty` / `tmux`, the `rime` input method, and the AI CLIs `claude` / `codex` / `codegraph` / `trellis`). (`fonts` is a user-space Nerd Font manager — MesloLGS NF etc. into `~/.local/share/fonts` + `fc-cache`, with `apply` / `configure` for saved font, size, and supported local GNOME terminal/desktop targets; `zsh` calls it when you pick a Nerd-Font prompt. `ghostty` installs the Ghostty terminal — apt on 26.04+, else the mkasberg community `.deb`, else snap — `configure` manages theme/font/common settings via a managed drop-in `~/.config/ghostty/ubuntu-setup` that is `config-file=`-included into the user's own `config`, never clobbering it; and `default-terminal [off]` makes Ghostty the default terminal via the user-scope freedesktop xdg-terminal-exec selector (GNOME 25.04+) plus a best-effort, .deb-only `update-alternatives x-terminal-emulator` registration. `tmux` installs tmux (apt) and manages its ecosystem as components, like `zsh`: the Tmux Plugin Manager (TPM), a curated plugin set, a theme, and sensible options — tracked in `~/.config/ubuntu-setup/tmux.conf` and written as a regenerated, marker-delimited block inside `~/.tmux.conf` (TPM reads `@plugin` from the main config and does not follow `source-file`, so the declarations live there rather than in a separate drop-in), with plugins installed/updated/cleaned non-interactively via TPM's `bin/` scripts and the actions `add-plugin`/`remove-plugin`/`theme`/`install-tpm`/`uninstall-tpm`/`update-plugins` plus a `configure --recommended` shortcut. `claude` is more than an installer: it is a **Claude Code extension manager** — beyond installing the CLI it manages MCP servers, plugins/marketplaces, and skills via `swkit claude <action>` (parametric ops like `mcp-add` / `plugin-install` / `skill-install`; deep guidance lives in the **claude-extensions** skill).) Coverage grows as scripts are added in the repo; at runtime you run the existing ones — scripts give stable, testable execution.
- This is **not** a data-driven / YAML / Python catalog engine (that was abandoned). It is pure bash, one hand-written script per software, each describing itself via its own `meta`.

## 2. USE a script

1. **Discover.** `swkit list` (every script grouped by category, with `[installed]` tags) or `swkit search <term>` (matches key/name/desc). To read details, run `scripts/<x>.sh meta` or open the script. (A human at a terminal can also browse interactively with `swkit ui`, or open one software's screen with `swkit <x>` — but you, on a no-TTY shell, drive scripts by explicit op as below.)
2. **Plan and confirm.** Present the **exact** command(s) you will run — e.g. `swkit docker install`, then `swkit docker configure` — and which steps need root. Run `sudo -n true` and branch on its **exit code**: exit 0 → sudo is passwordless now, the steps run unattended; non-zero → say so up front (see §5). Wait for the user's confirmation. Call out destructive operations loudly (`remove` keeps config, a future `--purge` would not; repo removals).
3. **Run.** `swkit <software> <op> [args]` (or `scripts/<software>.sh <op>` directly). The script gates on its own `status`, so re-running is safe.
4. **Handle the sudo handback.** If a script exits with **`RC_NEED_SUDO` (97)**, `lib/common.sh` has already printed the exact command to run by hand. **Relay it verbatim** and offer the two ways forward in §5 — do not try to work around it.
5. **Verify and report.** Run the script's `status` (exit 0 iff installed/active, and it prints the version). Report the **version present** and the **channel used** (apt, vendor repo, snap, official installer, manual binary) so future upgrades go the same way, plus any follow-up the user must do themselves (open a new shell for `PATH` changes; re-login after being added to the `docker` group; `systemctl status` for services).

## 3. When no script covers it

If **no script covers** the request, or an existing one is **broken/stale** (the vendor changed packaging, a URL, or the steps): **do not improvise** raw install commands and **do not write an ad-hoc script on the user's machine**. The scripts are maintained in the project repo, not authored at runtime.

- Tell the user it isn't covered yet, and what you would otherwise run, so they can decide how to proceed (e.g. install it once by hand, or have a script added).
- Adding or fixing a script is a **repo change** (a contributor task, not a runtime action): in the project repo, `cp scripts/TEMPLATE.sh scripts/<key>.sh`, follow the **authoring contract in the repo's `CLAUDE.md`** (lib helpers for all privilege/package/file work — never raw `sudo`/`apt-get`/`apt-key`/`sudo npm`; idempotent live-observed `status`; conservative channel priority apt → vendor apt repo → snap → official script → manual binary; back up before editing config; `bash -n` + `shellcheck -x` + the script's own `status`), commit, then re-run `bootstrap.sh` to deploy. After that it runs like any other script (§2).

## 4. The non-negotiables (the contract every script you run satisfies; `lib/common.sh` enforces them)

- **① Idempotent live-system checks** — `status` observes reality; install/remove gate on it and converge.
- **② Per-command sudo, never whole-root** — escalate only the single command that needs root, via `sudo_run`. **Never `sudo npm install -g`** — `npm_global_writable` is the predicate, and npm-only installers call `npm_ensure_user_prefix`, which (no sudo) sets a user-writable prefix in `~/.local` (writes `~/.npmrc`) when the prefix is a system default, or refuses a custom unwritable one. **Never `apt-key`** (use `add_apt_keyring` / `add_apt_source`). **Never write a NOPASSWD rule yourself.**
- **③ Non-interactive apt** — `apt_install` / `apt_remove` already run `DEBIAN_FRONTEND=noninteractive apt-get … -y --no-install-recommends` and use `remove` (not `purge`). Never trigger a debconf prompt on a headless server.
- **④ Fail-fast, resumable, no rollback** — `set -Eeuo pipefail`; stop at the first failure and report which step; back up before editing; re-run to recover.

## 5. sudo and the missing interactive TTY

Your shell usually has **no controlling terminal**, so you **cannot type a sudo password**. A `sudo` that needs one will error or hang.

- **Probe with `sudo -n true` and branch on the EXIT CODE, never the message text** (classic sudo and sudo-rs word it differently and may be localized). Exit 0 → passwordless now (the common case: bootstrap's TUI toggle writes `/etc/sudoers.d/ubuntu-setup-llm`, and cloud images often ship it). Non-zero → a password is required and you cannot supply it.
- **`lib/common.sh`'s `sudo_run` already does the right thing**: root → run directly; passwordless or a usable TTY → `sudo CMD`; otherwise it **prints the exact `sudo …` command to run by hand and returns `RC_NEED_SUDO` (97)**. Your job is to **relay that handback**, then offer:
  1. **Enable passwordless sudo via bootstrap's toggle** — re-run `./bootstrap.sh` and turn the toggle **ON** in its TUI Settings (revoke later by toggling it OFF, or `sudo rm /etc/sudoers.d/ubuntu-setup-llm`). This is the normal way to let LLM-driven installs run unattended.
  2. **Have the user run the printed command(s) themselves** in their own terminal, then re-try.
- **Never** echo / pipe / here-string a password into `sudo -S`, store it in a file or env var, or write a NOPASSWD rule yourself. Passwordless root is a security boundary, established only with the user's consent at the bootstrap prompt.

## 6. Always

- **Plan before apply.** Show the exact commands (and which need sudo) and get confirmation before changing the system.
- **Fail fast.** Stop at the first error; report the failing step and its stderr; suggest concrete diagnosis (`apt-get install -y <pkg> 2>&1 | tail`, `journalctl -u <unit> -n 50`, `systemctl status <unit>`). Don't improvise risky fixes — ask.
- **Verify against the live system**, not against what you intended — use the script's `status`.
- **Report the channel and follow-ups** so upgrades stay on the same channel and the user knows about a new shell for `PATH`, re-login after the `docker` group, services to enable, or config left behind by `remove`.
