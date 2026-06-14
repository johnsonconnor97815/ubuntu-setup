---
name: ubuntu-install
description: Install, remove, upgrade, or query software on an Ubuntu machine (including Server/headless over SSH) by driving a collection of per-software scripts (run via `swkit`), and authoring or fixing those scripts when none exists or one is stale. Use whenever the user asks to install, uninstall, update, or check any software, package, tool, runtime, or service on Ubuntu.
---

# Ubuntu Software Management

You manage software on a real Ubuntu machine (20.04+), possibly a headless server over SSH. There is no rollback for system changes. Re-running is the only recovery, so every step must be idempotent.

## 1. The model: scripts are the implementation; you USE and EVOLVE them

All install/remove/configure logic lives in a **collection of per-software bash scripts**, one per piece of software, with a uniform interface. They source a shared library, `lib/common.sh`, that encodes this project's safety contract as code — so calling its helpers makes the non-negotiables true by construction. **You do not improvise raw `apt`/`curl | bash`/`sudo` commands; you run a script, and when none fits, you write one.**

- The kit lives at **`$KIT_HOME` = `~/.local/share/ubuntu-setup/`**, which **is a git repo** (every edit is tracked, reversible, PR-able).
- **`swkit`** is on `PATH` — the launcher that runs scripts and discovers the collection.
- Each script also exposes a **`ui` entry mode** — an interactive full-screen management screen (`scripts/<x>.sh ui`, or `swkit <x>`). It is rendered by **`lib/common.sh`'s twin, `lib/ui.sh`** (modern TUI primitives, no whiptail). `ui` is **not** a `meta` op; on your no-TTY shell it prints how to drive the script by explicit op and exits 0 — so you keep the programmatic interface and never get stuck in a menu.
- The repo ships a **seed set** (`git`, `curl`, `zsh`, `fonts`, `docker`, `ghostty`, `tmux`, `node`, `claude`, `codex`) plus the machinery. (`fonts` is a user-space Nerd Font manager — MesloLGS NF etc. into `~/.local/share/fonts` + `fc-cache`, with `apply` / `configure` for saved font, size, and supported local GNOME terminal/desktop targets; `zsh` calls it when you pick a Nerd-Font prompt. `ghostty` installs the Ghostty terminal — apt on 26.04+, else the mkasberg community `.deb`, else snap — `configure` manages theme/font/common settings via a managed drop-in `~/.config/ghostty/ubuntu-setup` that is `config-file=`-included into the user's own `config`, never clobbering it; and `default-terminal [off]` makes Ghostty the default terminal via the user-scope freedesktop xdg-terminal-exec selector (GNOME 25.04+) plus a best-effort, .deb-only `update-alternatives x-terminal-emulator` registration. `tmux` installs tmux (apt) and manages its ecosystem as components, like `zsh`: the Tmux Plugin Manager (TPM), a curated plugin set, a theme, and sensible options — tracked in `~/.config/ubuntu-setup/tmux.conf` and written as a regenerated, marker-delimited block inside `~/.tmux.conf` (TPM reads `@plugin` from the main config and does not follow `source-file`, so the declarations live there rather than in a separate drop-in), with plugins installed/updated/cleaned non-interactively via TPM's `bin/` scripts and the actions `add-plugin`/`remove-plugin`/`theme`/`install-tpm`/`uninstall-tpm`/`update-plugins` plus a `configure --recommended` shortcut. `claude` is more than an installer: it is a **Claude Code extension manager** — beyond installing the CLI it manages MCP servers, plugins/marketplaces, and skills via `swkit claude <action>` (parametric ops like `mcp-add` / `plugin-install` / `skill-install`; deep guidance lives in the **claude-extensions** skill).) Coverage **grows** because you author new scripts and fix stale ones. That is the point: scripts give stable, testable execution; you keep them current and cover the long tail.
- This is **not** a data-driven / YAML / Python catalog engine (that was abandoned). It is pure bash, one hand-written or LLM-authored script per software, each describing itself via its own `meta`.

## 2. USE a script

1. **Discover.** `swkit list` (every script grouped by category, with `[installed]` tags) or `swkit search <term>` (matches key/name/desc). To read details, run `scripts/<x>.sh meta` or open the script. (A human at a terminal can also browse interactively with `swkit ui`, or open one software's screen with `swkit <x>` — but you, on a no-TTY shell, drive scripts by explicit op as below.)
2. **Plan and confirm.** Present the **exact** command(s) you will run — e.g. `swkit docker install`, then `swkit docker configure` — and which steps need root. Run `sudo -n true` and branch on its **exit code**: exit 0 → sudo is passwordless now, the steps run unattended; non-zero → say so up front (see §5). Wait for the user's confirmation. Call out destructive operations loudly (`remove` keeps config, a future `--purge` would not; repo removals).
3. **Run.** `swkit <software> <op> [args]` (or `scripts/<software>.sh <op>` directly). The script gates on its own `status`, so re-running is safe.
4. **Handle the sudo handback.** If a script exits with **`RC_NEED_SUDO` (97)**, `lib/common.sh` has already printed the exact command to run by hand. **Relay it verbatim** and offer the two ways forward in §5 — do not try to work around it.
5. **Verify and report.** Run the script's `status` (exit 0 iff installed/active, and it prints the version). Report the **version present** and the **channel used** (apt, vendor repo, snap, official installer, manual binary) so future upgrades go the same way, plus any follow-up the user must do themselves (open a new shell for `PATH` changes; re-login after being added to the `docker` group; `systemctl status` for services).

## 3. EVOLVE a script (the new core capability)

When **no script covers** the request, or an existing one is **broken/stale** (the vendor changed packaging, a URL, or the steps), **author or fix one**. Borrow from the software's official docs and reputable open-source. Then follow **the authoring contract** below.

### The authoring contract

1. **Start from the template.** `cp $KIT_HOME/scripts/TEMPLATE.sh $KIT_HOME/scripts/<key>.sh`. Keep its skeleton: `#!/usr/bin/env bash`, `set -Eeuo pipefail`, locate and `source lib/common.sh`, define `meta` / `status` / `do_install` / `do_remove` (and `do_configure` only if there is a *safe, minimal* config step), optionally `ui` (see below), `usage`, and **END with `kit_dispatch "$@"`**.
2. **Use lib helpers for ALL privilege / package / file work** — never raw `sudo`, raw `apt-get`, `apt-key`, or `sudo npm`. The unsafe patterns have no helper on purpose. Available: `have_cmd`, `pkg_installed`; `sudo_run`; `apt_install` / `apt_remove` / `apt_update_once`; `backup_file`, `append_once`, `ensure_local_bin_on_path`; `add_apt_keyring` / `add_apt_source`; `npm_global_writable`; `emit_meta_line`.
   - **Optional `ui()`** (the interactive screen): omit it and `kit_dispatch` synthesizes a menu from `meta` ops (`ui_default_menu`) — enough for most scripts. Hand-write `ui()` for a richer screen using `lib/ui.sh` primitives — `ui_run TITLE -- "$0" <op>` (leaves the alt-screen so apt/sudo output is visible + logged, then re-enters), `ui_pick` / `ui_confirm` / `ui_input` / `ui_notify`, `ui_badge` / `ui_header` / `ui_footer` / `ui_row` / `ui_read_key`. Always `if ! ui_supported; then ui_default_menu; return 0; fi` first, `ui_begin`/`ui_end` around the loop, and shell every state change out via `ui_run`. `ui` is an **entry mode, not an op** — keep it OUT of `meta` ops. See `scripts/TEMPLATE.sh` (commented example) and `scripts/zsh.sh` (flagship).
3. **Idempotent and live-observed.** `status` must observe the **live system** (`have_cmd`, `pkg_installed` — true only for dpkg `install ok installed`, a version probe), never a recorded flag. `do_install` / `do_remove` gate on `status` and converge; running twice is a safe no-op.
4. **Channel priority** (pick the highest that works; tell the user which and why): **apt** → **vendor apt repo** (`add_apt_keyring` + `add_apt_source` — keyring in `/etc/apt/keyrings`, referenced by `signed-by=`; never `apt-key`) → **snap** → **official vendor script** (show the URL first; never pipe an unofficial URL to a shell) → **manual binary** (last resort; the user owns upgrades).
5. **`meta` is the contract surface.** `ops=` must list **exactly** the operations implemented (`install,remove` always; add `configure` only if `do_configure` exists). `category` ∈ `essentials | common | ai | runtime` (anything else groups under `other`).
6. **Back up before editing any config file** (`backup_file PATH` — that copy is the only undo); grep-before-append (`append_once`); never clobber content you did not write. Files in `$HOME` must stay user-owned — never create them from inside a `sudo` command.
7. **Plan before apply; fail fast; no rollback** (re-run is the recovery, hence the idempotency).
8. **Test, then commit.** `bash -n scripts/<key>.sh` and `shellcheck -x --source-path=SCRIPTDIR scripts/<key>.sh` (zero warnings — it sources `lib/common.sh`/`lib/ui.sh`); run the script's own `status` **before** and **after**; `scripts/<key>.sh ui` on your no-TTY shell must print guidance and exit 0; only then run it for real, with the user's confirmation. `swkit list` / the bootstrap TUI pick it up automatically once it is executable with valid `meta`. Changes are git-tracked under `$KIT_HOME`: `git commit` with a clear message, and consider a PR upstream.

**Security note:** authoring a privileged (sudo-using) script is a real attack surface on a stranger's machine. The lib primitives make safe patterns the default and give unsafe ones no helper; still — plan before apply, get confirmation, keep every change diff-reviewable in git, and let the user (or upstream) review before trusting an LLM-authored script. **Never** auto-write a NOPASSWD rule.

## 4. The non-negotiables (the contract every script must satisfy; `lib/common.sh` enforces them)

- **① Idempotent live-system checks** — `status` observes reality; install/remove gate on it and converge.
- **② Per-command sudo, never whole-root** — escalate only the single command that needs root, via `sudo_run`. **Never `sudo npm install -g`** (use a user-writable prefix: `npm config set prefix ~/.local`; `npm_global_writable` guards this). **Never `apt-key`** (use `add_apt_keyring` / `add_apt_source`). **Never write a NOPASSWD rule yourself.**
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
