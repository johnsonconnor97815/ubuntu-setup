---
name: zsh-setup
description: Use when the user wants to install, set up, configure, customize, or switch to the Z shell (zsh) on Ubuntu/Debian — including making zsh the default login shell, adding/removing autosuggestions / syntax-highlighting / completions / fzf / zoxide or any plugin, installing or uninstalling Oh My Zsh, choosing a prompt (Starship, Powerlevel10k, Pure), or writing a ~/.zshrc. Drives scripts/zsh.sh in the ubuntu-setup kit (a zsh component manager) and extends it when a capability is missing. Covers headless servers reached over SSH.
---

# Zsh Setup on Ubuntu

The mechanics of installing and configuring zsh live in a script — **`scripts/zsh.sh`** in
the ubuntu-setup kit, a **component manager** runnable as `swkit zsh <action>` (or, for a human at a
terminal, an interactive full-screen screen via `swkit zsh` / the bootstrap catalog — see §5). That
script, not this prose, is the single implementation: it sources `lib/common.sh` (per-command sudo,
idempotency probes, non-interactive apt, back-up-before-edit) so the safety non-negotiables are met
by construction.

**It manages zsh's components independently and statefully.** The framework (Oh My Zsh), the
prompt, and each plugin can be **installed / uninstalled / added / removed** on their own. The
enabled set is tracked in `~/.config/zsh/ubuntu-setup.conf` (`FRAMEWORK` / `PROMPT` / `PLUGINS`).
Any change **regenerates** a managed drop-in `~/.config/zsh/ubuntu-setup.zsh` wholesale and
sources it from `~/.zshrc` via one idempotent line. So re-running converges to the latest, and
the user's own `~/.zshrc` is never clobbered.

So your job here is:

1. **Help the user choose** components on a machine whose owner you've never met (§2) —
   framework, prompt, which plugins, whether to switch the login shell — then invoke the right
   action. Don't impose taste; recommend conservative defaults for headless servers.
2. **When `scripts/zsh.sh` doesn't support something** the user wants — a new prompt, or a plugin in
   the *named* set — that is a change to the script **in the project repo** (§4), not a runtime edit on
   the user's machine. (For any arbitrary plugin you can always `add-plugin <git-url>` — no code change.)

Everything `zsh.sh` does is subject to **ubuntu-install §5** for sudo: your shell has no terminal
to type a password; `sudo_run` probes with `sudo -n true` and, if a password is needed, prints
the exact command and returns exit code 97 instead of hanging. Relay that — have the user enable
passwordless sudo (re-run `./bootstrap.sh`, toggle it on) or run the printed `sudo` line. Never
enter/pipe/store a password or write NOPASSWD.

**Read §3 (lockout safety) before changing anyone's login shell.**

## 1. Actions (the component manager)

Run as `swkit zsh <action>` (or `scripts/zsh.sh <action>`). Everything is idempotent; any change
regenerates the drop-in and converges.

- **`status`** — `zsh --version`; exit 0 iff installed.
- **`install`** / **`remove`** — install / uninstall zsh itself via apt (remove refuses if zsh is
  the login shell).
- **`install-omz`** / **`uninstall-omz`** — install the Oh My Zsh framework (official installer,
  unattended, `--keep-zshrc`, clones `~/.oh-my-zsh`) / uninstall it (deletes `~/.oh-my-zsh`). Sets
  `FRAMEWORK` and regenerates. With Oh My Zsh active, the drop-in emits OMZ's `ZSH_THEME`, the
  **OMZ settings** (see `omz-setting` below), and **`plugins=($OMZ_PLUGINS)`** (OMZ-native plugins),
  then sources `oh-my-zsh.sh` (which runs its own compinit), then **still** sources the kit's own
  named plugins after it (syntax-highlighting last). The two plugin axes are distinct: the kit's
  `add-plugin` set (apt/git, sourced by the kit) vs OMZ's `add-omz-plugin` set (bundled with OMZ,
  enabled by name in the array).
- **`add-omz-plugin <name>`** / **`remove-omz-plugin <name>`** — enable/disable an **Oh My Zsh-native**
  plugin in `OMZ_PLUGINS` (needs OMZ; `add` validates the name exists in `~/.oh-my-zsh/plugins` or
  `custom/plugins`, the live-system idempotency probe). Curated set: `git sudo extract
  colored-man-pages command-not-found docker docker-compose kubectl z` (any plugin present in the OMZ
  install is also accepted). Deliberately **excludes** `zsh-autosuggestions`/`zsh-syntax-highlighting`
  — those are the kit's own `add-plugin` plugins (sourced after `oh-my-zsh.sh`); listing them as OMZ
  plugins too would double-load them.
- **`omz-setting <key> <value>`** — tune one OMZ setting (state in `ubuntu-setup.conf`, regenerated):
  `update disabled|auto|reminder` (default **disabled** — the kit manages OMZ via git, and an
  auto-update prompt would block a non-interactive shell), `magic on|off` (magic paste; default off =
  faster), `untracked-dirty on|off` (VCS dirty on untracked files; default off = faster `git status`),
  `correction on|off` (default off), `wait-dots on|off` (default on), `hist-stamps
  yyyy-mm-dd|mm/dd/yyyy|dd.mm.yyyy|none` (default ISO). Each is individually overridable; defaults are
  conservative, performance/non-interactive-safe best practices.
- **`add-plugin <name|git-url>`** — enable a plugin: install it, add to `PLUGINS`, regenerate.
  **Known names** (installed the right way, placed in the right load slot):
  - `autosuggestions` — apt `zsh-autosuggestions`
  - `syntax-highlighting` — apt `zsh-syntax-highlighting` (always sourced **last**)
  - `completions` — git `zsh-users/zsh-completions` (its `src/` added to `fpath` **before** compinit)
  - `history-substring-search` — git `zsh-users/...` (sourced **after** syntax-highlighting; binds Up/Down)
  - `fzf` — apt `fzf` (sources `fzf --zsh` if new enough, else the example key-bindings/completion)
  - `zoxide` — apt `zoxide` (or official installer to `~/.local/bin`); `eval "$(zoxide init zsh)"`
  Any **other value is treated as a git repo URL** — cloned to `~/.config/zsh/plugins/<name>` and
  the conventional entry file (`*.plugin.zsh` → `<name>.zsh` → `init.zsh`) is sourced.
- **`remove-plugin <name>`** — disable a plugin: drop it from `PLUGINS`, regenerate, and remove its
  git clone. Shared apt packages/tools (autosuggestions, syntax-highlighting, fzf, zoxide) are left
  installed (cheap to re-enable; remove with apt if the user truly wants them gone).
- **`prompt <git|plain|starship|powerlevel10k|pure>`** — set the prompt (installs Starship /
  clones Powerlevel10k or Pure if needed), regenerate.
- **`default-shell`** — make zsh the default login shell, lockout-safe (§3).
- **`configure [flags]`** — full re-spec of the whole config in one shot (for when you want to set
  everything at once rather than incrementally):
  - `--framework none|oh-my-zsh` (default `none`)
  - `--prompt git|plain|starship|powerlevel10k|pure` (default `git`)
  - `--plugins "a b c"` set the enabled (kit) plugins to exactly this (known names); `--no-plugins` clears
  - `--omz-plugins "git sudo …"` set the OMZ-native plugins (curated names or any present in the OMZ install)
  - `--omz-update disabled|auto|reminder` · `--omz-magic on|off` · `--omz-untracked-dirty on|off`
    · `--omz-correction on|off` · `--omz-wait-dots on|off` · `--omz-hist-stamps yyyy-mm-dd|…|none`
  - `--no-aliases` · `--default-shell`
  No-arg `configure` = the conservative baseline (framework-free, git-branch ASCII prompt,
  autosuggestions + syntax-highlighting, color aliases).

**Channels (all idempotent, run as the user; install only if missing):** Oh My Zsh & Starship via
their official `curl | sh` (Starship into `~/.local/bin`, no sudo); Powerlevel10k / Pure /
completions / history-substring-search via `git clone`; the apt ones via `apt_install`. **Fonts
(over SSH):** choosing Starship or Powerlevel10k now **installs the recommended Nerd Font (MesloLGS
NF) on this box** by delegating to the kit's `fonts.sh` (`~/.local/share/fonts` + `fc-cache`, no
sudo) — but glyphs are rendered by the user's **local** terminal, so over SSH the box-side install
only helps a local display; tell the user to **also install/select that font in their client
terminal** (`fonts.sh` prints the download URLs and the family name). Manage fonts directly with
`swkit fonts install [name]` / `swkit fonts apply [name] [size] [target]` /
`swkit fonts configure --font <name> --size <pt> --target <target>` / `swkit fonts ui` (curated:
`meslolgs`, `jetbrains-mono`, `firacode`, `hack`; targets: `auto`, `ptyxis`, `gnome-terminal`,
`gnome-desktop`, `instructions`). Powerlevel10k's `p10k configure` wizard is interactive, so tell the user to run it themselves.

## 2. Helping the user choose

You're on a stranger's machine — **don't impose taste.** Lay out choices, recommend conservative
defaults (especially headless), then run the matching action.

- **Framework:** framework-free (default) vs Oh My Zsh → `swkit zsh install-omz` / `uninstall-omz`.
- **Prompt:** git (default) / plain (ASCII, safe) · Pure (fancy, no fonts) · Starship / Powerlevel10k
  (Nerd Font) → `swkit zsh prompt <name>`.
- **Plugins (kit):** suggest `autosuggestions` + `syntax-highlighting` (the default pair), optionally
  `completions`, `history-substring-search`, `fzf`, `zoxide` → `swkit zsh add-plugin <name>` /
  `remove-plugin <name>`; any other plugin by git URL.
- **Oh My Zsh plugins** (only with OMZ on): offer the OMZ-native ones for the user's workflow —
  `sudo`, `extract`, `colored-man-pages`, `command-not-found`, `docker`, `kubectl`, `z`, … →
  `swkit zsh add-omz-plugin <name>` / `remove-omz-plugin <name>`. Tune OMZ behavior with
  `swkit zsh omz-setting <key> <value>` (defaults are already sane; only change on request).
- **Fonts:** `swkit fonts install [meslolgs|jetbrains-mono|firacode|hack]` /
  `swkit fonts apply [name] [size] [auto|ptyxis|gnome-terminal|gnome-desktop|instructions]` /
  `swkit fonts ui` — needed for Starship/Powerlevel10k glyphs (and selected automatically when you
  pick those prompts); over SSH, applying means instructing the client terminal, not changing it remotely.
- **Default shell:** `swkit zsh default-shell` (read §3).

Present the exact plan (which `swkit zsh …`, what it installs/writes, which steps need sudo and
whether `sudo -n true` passes) and wait for confirmation — ubuntu-install §5.

## 3. Lockout safety (read before changing the login shell)

Changing a user's login shell on a remote machine is the one action that can make them unable to
log in. `default-shell` / `configure --default-shell` already guards it — verifies an interactive
zsh starts cleanly (`timeout … zsh -i -c 'exit 0'`) **before** any `chsh`, ensures the zsh path is
in `/etc/shells`, resolves the real target user — but **the operational discipline is still yours**:

- **Install and fully configure first; change the login shell last.**
- **Keep the current session open.** `chsh` only affects *new* logins. After the switch, have the
  user open a *fresh* login and confirm they land in a working zsh **before** closing the open one.
- Try it now without logging out: `exec zsh`. Verify: `getent passwd "$USER" | cut -d: -f7`.
- Escape hatch if a fresh login breaks: `chsh -s /bin/bash` (or `sudo chsh -s /bin/bash "$USER"`).

## 4. Extending `scripts/zsh.sh` (a repo change, not a runtime action)

For a plugin not in the named set, you can always `add-plugin <git-url>` (no code change). But to
make a new component **first-class** (a named plugin with the right install/slot, a new prompt, a
new framework), the script must be extended **in the project repo** — a contributor change, then
re-deployed with `bootstrap.sh`. Do **not** edit the script on the user's machine at runtime. The
how-to (follow the authoring contract in the repo's `CLAUDE.md`):

1. Edit `scripts/zsh.sh` in the project repo. To add a named plugin: add
   its key to `ZSH_KNOWN_PLUGINS`, an install case in `_zsh_plugin_ensure`, a purge case in
   `_zsh_plugin_purge`, an emit case in `_zsh_emit_plugin`, and a slot in `_zsh_plugins_in_slot`
   (fpath / normal / eval / syntax / post-syntax — get the load order right). For a new prompt: a
   `--prompt` value, an installer, an `_zsh_apply` case, and an emit case. New top-level action:
   add it to `meta` `ops=` and define `do_<action>` (hyphens map to underscores); to surface it on
   the interactive screen, also add a row + a key/Enter handler in `ui()` (it shells out via `ui_run`).
2. **Use lib helpers** — `apt_install`, `add_apt_keyring`/`add_apt_source`, `backup_file`,
   `append_once`, `sudo_run`. Never raw `sudo`, `apt-get`, `apt-key`, `sudo npm`. Resolve apt plugin
   paths by the **main** entry file (`/<name>.zsh$`), not the first `*.zsh`.
3. **Channel priority:** apt → vendor apt repo → snap → official script (show URL) → manual binary.
   Install into user space where possible; the drop-in/`~/.zshrc` are written as the user, never sudo.
4. **Idempotent & safe:** install only if missing; the drop-in is regenerated wholesale (no in-place
   edits); keep syntax-highlighting last and history-substring-search after it. Test (`bash -n`, then
   `timeout … zsh -i -c 'exit 0'`), commit in the repo, and re-run `bootstrap.sh` to deploy.

## 5. The interactive screen, and the boundary with bootstrap

`scripts/zsh.sh` defines its **own full-screen `ui()`** (the flagship example for the kit). A human
opens it with **`swkit zsh`** (no action) or by drilling into zsh from the bootstrap catalog
(`./bootstrap.sh` → Install software → zsh). It is a live **component manager**: toggle the framework
(Oh My Zsh on/off), pick the prompt from a submenu, **check plugins on/off with Space**, add an
arbitrary git plugin with the **`a`** key, set the default login shell, install/remove zsh — every
change shells out via `ui_run` (visible output + log) and the screen reloads. So the argument-taking
actions are fully reachable interactively now; there is **no** "the TUI can't pass arguments"
limitation anymore.

`ui` is an **entry mode**, not a `meta` op — it is never in `ops=`, and on a no-TTY shell
`scripts/zsh.sh ui` just prints how to drive it by explicit op and exits 0. **You (the LLM)** still
drive zsh by explicit action — `swkit zsh add-plugin <…>`, `swkit zsh prompt <…>`, etc. — exactly as
in §1; the `ui` screen is for the human at a terminal. There is no zsh logic duplicated in the
bootstrap bash: every entry point (the `ui` screen, `swkit`, you) invokes this one script. Truly
bespoke configuration is the taste conversation (§2) plus, where a capability is missing, a change
to the script in the repo (§4).

## 6. Reference — understanding behind the script

Details to *understand* (and preserve when the script is changed in the repo); most are handled by `zsh.sh`.

- **Plugin load order.** fpath additions (completions) **before** compinit; `zsh-autosuggestions`
  before `zsh-syntax-highlighting`; **`zsh-syntax-highlighting` last** of the highlighters;
  `history-substring-search` **after** syntax-highlighting (then its Up/Down bindkeys). With Oh My
  Zsh, the named plugins are sourced *after* `oh-my-zsh.sh`, syntax-highlighting still last.
- **Plugin source paths.** apt plugins resolved by the **main** entry file via `dpkg -L`
  (`/zsh-syntax-highlighting.zsh$`, not the `highlighters/*/*.zsh`). git plugins: prefer any
  `*.plugin.zsh` in the clone, then `<name>.zsh` / `init.zsh`.
- **fzf version.** Ubuntu's apt fzf (0.29 / 0.44) predates `fzf --zsh` (needs 0.48+); the emitted
  line tries `fzf --zsh` and falls back to sourcing the example `key-bindings.zsh` / `completion.zsh`.
- **`compinit` insecure-dirs / newuser wizard** — both **hang** non-interactive/SSH sessions. The
  source line keeps `~/.zshrc` present (prevents the wizard). For insecure dirs, fix the cause
  (`compaudit | xargs chmod g-w`), don't `compinit -i`. With Oh My Zsh, omz runs its own compinit
  (the drop-in skips ours to avoid a double init).
- **Migration.** An older fully-managed `~/.zshrc` (first line `# managed by ubuntu-setup zsh.sh`)
  is backed up and replaced by the one-line source model; personal lines are preserved in the `.bak`.
- **Migration from bash.** zsh doesn't read `~/.bashrc`/`~/.profile`; copy PATH/aliases/functions into
  `~/.zshrc` (or `~/.zshenv`). The baseline doesn't migrate these — flag it (or change the script in the repo).
- **Rollback.** Remove the source line from `~/.zshrc` + delete `~/.config/zsh/ubuntu-setup.zsh` (the
  user's own `~/.zshrc` is untouched), or restore a `.bak`. Login shell back to bash: `chsh -s /bin/bash`.
  Remove zsh only after the login shell is back to bash for every affected user (`swkit zsh remove`
  enforces this; apt `remove`, not purge, so dotfiles survive).

## 7. Verify and report

After any change: `swkit zsh status`, the login shell (`getent passwd "$USER" | cut -d: -f7`), a
clean interactive start (`zsh -i -c 'exit 0'`); the channel each piece came from (apt / official
installer / git) so upgrades go the same way; follow-ups (new login for a default-shell change; a
Nerd Font locally for Starship/Powerlevel10k icons; `p10k configure`).

## Common mistakes

- **Improvising raw install/config commands** instead of running `scripts/zsh.sh` — the
  whole point is one tested, idempotent, reviewable implementation, with state tracked.
- **Editing the managed drop-in or the state file by hand** — they're regenerated on every change;
  use the actions, and put personal settings in `~/.zshrc` (sourced before the drop-in).
- **Changing the login shell before zsh is proven to start cleanly** → lockout. `default-shell`
  checks it (with a timeout), but still keep a session open and confirm a fresh login.
- Sourcing `zsh-syntax-highlighting` anywhere but **last**, or `history-substring-search` before it.
- Hardcoding apt plugin paths / grabbing the first `*.zsh` instead of the main entry file.
- Choosing a Nerd-Font prompt (Starship/Powerlevel10k) for a server while the font is missing in the
  **local** terminal → boxes. Prefer git/plain/Pure on headless boxes.
- Expecting `chsh` to change the **current** shell (only new logins; use `exec zsh`).
