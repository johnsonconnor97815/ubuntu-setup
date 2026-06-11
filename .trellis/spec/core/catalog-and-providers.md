# Catalog & Providers

> The declarative catalog entry and the typed provider that knows how to realize it. This is the heart of the system; read it before touching `core/catalog.py` or anything under `core/providers/`.

---

## Status: design-derived, not yet code-backed

Prescriptive. Field names and provider keys defined here are the contract the first implementation must follow. The command idioms below were verified against current Ubuntu (22.04 / 24.04+), apt/dpkg, snapd, flatpak, and systemd documentation — keep them current, do not regress to the deprecated forms called out as anti-patterns.

---

## The declarative entry

One software unit = one declarative entry, authored in YAML under `ubuntu_setup/catalog/*.yaml`, validated against `catalog/schema.json` at load time in `core/catalog.py`. The engine interprets fields; it does not run arbitrary code except inside the `script` escape hatch.

```yaml
- id: nodejs                 # unique key; also the name other entries depend_on
  description: "Node.js LTS via apt"
  type: apt                  # selects the provider (see registry below)
  package: nodejs            # type-specific field
  depends_on: []             # ids that must converge before this one
  tags: [web-dev]            # grouping / profiles in the TUI
  source: official           # official | community | ai-generated  (trust marker)

- id: rust
  description: "Rust toolchain (rustup)"
  type: script               # the escape hatch — arbitrary commands
  check: "command -v rustc"  # REQUIRED for script: the idempotency probe
  install: "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  source: official

- id: zsh-env
  description: "Editor env in ~/.zshrc"
  type: dotfile-block        # marked managed block + backup
  file: "~/.zshrc"
  marker: "ubuntu-setup:zsh-env"
  content: |
    export EDITOR=vim
  source: official
```

Common fields on every entry: `id`, `description`, `type`, `depends_on` (default `[]`), `tags` (default `[]`), `requires` (default `[]`), `source` (default `community`). Type-specific fields are validated per `type` by the schema. See `../catalog/authoring-guidelines.md` for the authoring rules and the full field list per type.

`requires` (code-backed) lists host capabilities the entry needs; the schema enum currently allows only `"desktop"` (kept in sync with `core/environment.py::KNOWN_CAPABILITIES` — the list form is the extension point for future conditions like arch). The applicability judgment `requires ⊆ capabilities` lives in `core/environment.py` only: `service.scan`/`service.filter_catalog` hide inapplicable entries from browse surfaces, and the executor skips them explicitly at plan/apply time (see [idempotency-and-execution.md](./idempotency-and-execution.md)). `desktop` means *the machine has a desktop stack installed*, not "the current session is graphical" — `DISPLAY`/`WAYLAND_DISPLAY` set, **or** `systemctl get-default` == `graphical.target`, **or** a non-empty `/usr/share/xsessions` / `/usr/share/wayland-sessions`; any one signal suffices (an SSH login into a desktop machine can still install GUI software).

---

## The Provider protocol

Each `type` maps to exactly one provider in `core/providers/`, implementing the protocol in `base.py`. A provider is the *only* place that knows install mechanics for its type.

```python
# core/providers/base.py
class State(enum.Enum):
    ABSENT = "absent"          # not installed / not applied
    PRESENT = "present"        # installed / applied and current
    OUTDATED = "present_outdated"  # installed but an upgrade is available (optional)

class Provider(Protocol):
    type: str                              # registry key, e.g. "apt"
    def check(self, entry: CatalogEntry) -> State: ...   # live system query — NO mutation
    def install(self, entry, ctx) -> None: ...           # converge to PRESENT (idempotent)
    def remove(self, entry, ctx) -> None: ...            # converge to ABSENT (idempotent)
    def upgrade(self, entry, ctx) -> None: ...           # PRESENT -> latest (idempotent)
```

Contract for every provider:

- **`check()` is the idempotency engine.** It observes *real* system state (queries dpkg, `snap list`, the filesystem) and returns `State`. It never mutates. The executor calls `check()` before acting and skips the action when the entry is already in the desired state. This mirrors Homebrew's structural `latest_version_installed?` (does the keg dir exist) and Ansible's read-state-then-decide model — **never trust a recorded flag or a state ledger; ask the system.** See [idempotency-and-execution.md](./idempotency-and-execution.md).
- **All four operations are idempotent.** `install` on an already-present entry is a successful no-op; `remove` on an absent one is a successful no-op.
- **All external commands go through `core/runner.py`** (non-interactive env, argv list, `shell=False`, logged). Privileged steps escalate per-command via `sudo`; the provider never assumes it is root. See [privilege-and-safety.md](./privilege-and-safety.md).
- **Adding a type is local.** New type = new file + one line in the `core/providers/__init__.py` registry. Nothing else in the brain may branch on `entry.type`.

### The execution context (`ctx`)

`install`/`remove`/`upgrade` receive a `ctx` — the execution context the executor passes down, and the provider's only handle to shared services (so it never reaches for globals):

| `ctx` member | What it provides |
|--------------|------------------|
| `ctx.run(argv, *, sudo=False, **kw)` | the one subprocess boundary (`core/runner.py`): non-interactive env, `LC_ALL=C`, logging, timeout. For a mutating op the executor binds it to the **streaming** variant (`run_streaming`): each output line is forwarded live as an `OutputLine` event, and the running command's terminate handle is published so the consumer's `cancel()` can kill the current step — the provider still just calls `ctx.run` and gets the same aggregated result (`returncode`/`stdout`/`stderr`/`duration`). `check()` uses the plain capturing runner |
| `ctx.priv` | privilege helper: `real_user()`, `real_home()`, sudo validation — see [privilege-and-safety.md](./privilege-and-safety.md) |
| `ctx.log` | the run logger (audit trail) — see [error-and-logging.md](./error-and-logging.md) |
| `ctx.check_mode: bool` | **dry-run guard** — when `True`, the operation must make **zero** changes (see below) |
| `ctx.emit(event)` | report progress / predicted change to the executor and TUI |

`check()` takes only `entry` and never mutates, so it does not need `ctx`'s mutating members.

**Dry-run / `check_mode`:** the *prediction* "would this change?" comes from `check()` (compare its `State` to the desired op) — providers need no parallel simulation path for that. `ctx.check_mode` is the **mutation guard**: in plan mode the executor sets `ctx.check_mode=True`, and every `install`/`remove`/`upgrade` must honor it by making no irreversible change (it may still compute and `emit` the intended change). A provider whose state can't be fully captured by `check()` alone (e.g. a `dotfile-block` content diff) signals that via `emit`, so the UI shows "cannot fully simulate" instead of a confident no-op. See [idempotency-and-execution.md](./idempotency-and-execution.md).

---

## Provider registry (the typed `type` values)

| `type` | File | What it manages |
|--------|------|-----------------|
| `apt` | `apt.py` | Standard apt packages |
| `ppa` | `ppa.py` | A Launchpad PPA (often paired with an `apt` entry that `depends_on` it) |
| `deb` | `deb.py` | A third-party APT repo (deb822 + key) or a local/remote `.deb` |
| `snap` | `snap.py` | Snap packages |
| `flatpak` | `flatpak.py` | Flatpak apps (+ the flathub remote) |
| `dotfile-block` | `dotfile_block.py` | A marked managed block in a user config file |
| `service` | `service.py` | A systemd unit (enable/disable/start/stop) |
| `script` | `script.py` | **Escape hatch** — arbitrary `check`/`install`/`remove`/`upgrade` commands |

---

## Verified command idioms per provider

These are the exact, current idioms each provider must use. Run everything through `runner.py` (argv list, `shell=False`, `env` with `DEBIAN_FRONTEND=noninteractive` and `LC_ALL=C`).

### `apt`

- **check:** `dpkg-query -W -f='${Status}' <pkg>` and test the output equals `install ok installed` (exit 1 / mismatch ⇒ ABSENT). Do **not** use `apt-cache policy` (always exits 0; reports the repo candidate, not installed state). Plain `dpkg -s` can report a removed-not-purged package as present — gate on the `${Status}` string. For a version-pinned entry (`version:` set), also read the installed version with `dpkg-query -W -f='${Version}' <pkg>` and compare ⇒ OUTDATED if it differs.
- **install:** `apt-get install -y --no-install-recommends <pkg>`, with `-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"` to survive modified-conffile prompts non-interactively. The install op passes its own widened `timeout` (code-backed: `apt.py::_INSTALL_TIMEOUT`, 3600s): the runner's blanket 600s default provably kills heavy meta-package downloads (libreoffice/qemu/dotnet class) mid-flight on slow or contended links — installing is the one op that legitimately downloads hundreds of MB (found by the catalog real-install verification, 2026-06-11).
- **remove / purge:** `apt-get remove -y <pkg>` (keeps config) / `apt-get purge -y <pkg>` (drops config).
- **upgrade:** `apt-get install -y --only-upgrade <pkg>` (upgrades the package only if already installed; a **no-op success** if it is absent — safe to re-run, not an error to guard against). Install a pinned version with `<pkg>=<version>`.
- **hold (optional):** `apt-mark hold <pkg>` / `apt-mark unhold <pkg>`; check with `apt-mark showhold | grep -qx <pkg>`.
- Use **`apt-get`**, not `apt` — apt(8)'s CLI/output is explicitly an unstable interface. Branch on exit codes, not parsed stdout.

### `ppa`

- **add:** `add-apt-repository -y ppa:<user>/<name>` (fetches the key, writes a deb822 `.sources` on 24.04, a `.list` on 22.04), then `apt-get update`.
- **check:** glob `/etc/apt/sources.list.d/` for `*<user>-ubuntu-<name>*.{list,sources}`, or grep the dir for `ppa.launchpadcontent.net/<user>/<name>`. Do **not** rely on `add-apt-repository --list` — on 24.04 it ignores legacy `.list` files (Launchpad bug 2106617).
- **prerequisite:** `add-apt-repository` is provided by `software-properties-common`, which is not guaranteed on a minimal install. `install()` ensures it first (`apt-get install -y software-properties-common`) before adding the PPA; if it cannot be installed, raise `PreconditionError` (the entry is skipped — see [error-and-logging.md](./error-and-logging.md)).

### `deb` (third-party APT repo — the MODERN deb822 + signed-by way)

```
install -m 0755 -d /etc/apt/keyrings
curl -fsSL <key-url> | gpg --dearmor -o /etc/apt/keyrings/<name>.gpg
chmod a+r /etc/apt/keyrings/<name>.gpg
# write /etc/apt/sources.list.d/<name>.sources (deb822):
#   Types: deb
#   URIs: <repo-url>
#   Suites: <codename>           # $(. /etc/os-release && echo $VERSION_CODENAME)
#   Components: <component>
#   Architectures: <arch>        # $(dpkg --print-architecture)
#   Signed-By: /etc/apt/keyrings/<name>.gpg
apt-get update
```

- Key **must** be dearmored binary (`gpg --dearmor`) and **world-readable** (`chmod a+r`) so the `_apt` user can read it, or `apt-get update` fails with a permission error.
- Operator-managed keys go in **`/etc/apt/keyrings`** (available since apt 2.4, i.e. 22.04+); `/usr/share/keyrings` is reserved for package-shipped keys.
- Filenames under `sources.list.d`/keyrings may contain only `[A-Za-z0-9._-]` — others are silently ignored.
- A local `.deb`: `apt-get install -y ./pkg.deb` (the leading `./` or an absolute path is required, else apt treats it as a repo package name) — this resolves dependencies in one step; prefer it over `dpkg -i` + `apt-get -f install`.
- **check:** the repo is added iff its `.sources`/key files exist with the expected content; the package is installed per the `apt` check above.

### `snap`

- **install (strict):** `snap install <name>`; **classic:** `snap install <name> --classic`.
- **check:** `snap list <name>` (exit 0 = installed). **Install one snap per command** — passing 2+ already-installed snaps in a single command fails with exit 1.
- **classic detection:** before install, `snap info <name>` and read the `confinement:` line (`classic` vs `strict`); omitting `--classic` on a classic snap fails. Confinement is set by the packager — you cannot change it.
- **remove:** `snap remove <name>` (add `--purge` to drop data). **upgrade:** `snap refresh <name>` (errors if not installed — there is no install-or-refresh; use the `snap list` guard then refresh-or-install).
- snap needs `sudo`; there is no per-user snap.

### `flatpak`

- **prerequisite:** flatpak is **not** preinstalled on Ubuntu (snapd is). The provider must ensure `apt-get install -y flatpak` first, then add the remote: `flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo` (the `--if-not-exists` flag is what makes it idempotent).
- **install:** `flatpak install -y flathub <app-id>` (system scope, needs sudo) or `flatpak install -y --user flathub <app-id>`. If the entry's `scope` is unspecified, **default to `system`**. `--user` and system are **separate scopes** — add the flathub remote in the *same* scope as the install (a `--user` remote is invisible to a system install and vice-versa).
- **check:** `flatpak info <app-id>` (exit 0 = installed; queries user+system). **upgrade:** `flatpak update -y <app-id>`, or install with `--or-update`. **remove:** `flatpak uninstall -y <app-id>` (`--delete-data` to purge).

### `dotfile-block`

- Write a **marked managed block** so re-runs replace rather than append (Ansible `blockinfile` semantics). Use a distinct begin/end marker pair derived from `entry.marker`, e.g.:
  ```
  # >>> ubuntu-setup managed: <marker> >>>
  ...content...
  # <<< ubuntu-setup managed: <marker> <<<
  ```
- **Back up before writing** (`cp -a <file> <file>.ubuntu-setup.<ISO-timestamp>.bak`). Splice only the text between *your* markers — never touch the user's surrounding lines.
- **check:** the block is PRESENT iff the file contains both markers and the content between them matches. **remove:** delete the block and its markers (idempotent).
- Resolve `~`/`$HOME` to the **real user's** home (see [privilege-and-safety.md](./privilege-and-safety.md)); never write user dotfiles as root.

### `service`

- **check:** `systemctl is-enabled <unit>` — but its exit code is **not** a boolean. `enabled`/`static`/`indirect`/`alias`/`enabled-runtime` exit 0; `disabled`/`masked`/`linked`/absent exit non-zero. Inspect the printed string when the distinction matters; `static` units cannot be enabled.
- **enable+start:** `systemctl enable --now <unit>` (idempotent; runs an internal reload). **disable+stop:** `systemctl disable --now <unit>`.
- Run `systemctl daemon-reload` only after creating/editing a unit **file** on disk. **User units** use `systemctl --user …` (no sudo, as the real user) and need their own `--user daemon-reload`; a system reload does not touch them. `mask` is stronger than disable — `unmask` before re-enabling.

### `script` (escape hatch)

- The only provider that runs author-supplied commands. Requires an explicit `check` command (the idempotency probe, e.g. `command -v rustc`); `install` required; `remove`/`upgrade` optional.
- Highest-risk type: it is the one place arbitrary `sudo`/shell runs. **The future LLM phase must never generate `script` entries**, and human review is mandatory for them. See `../catalog/authoring-guidelines.md`.

---

## Anti-patterns (forbidden)

- `apt-key add` — dead. apt stopped using it for verification (apt 2.9.15, Nov 2024); Debian 13 removed it. Use `gpg --dearmor` into `/etc/apt/keyrings` + `Signed-By`.
- A one-line `deb …` source **without** `signed-by=` — apt 2.9.24 (Jan 2025) deprecated it and stopped trusting `/etc/apt/trusted.gpg{,.d}`. Every third-party repo carries its own scoped key.
- Parsing human-readable `apt` (not `apt-get`) stdout to make decisions — unstable interface; use `apt-get`/`apt-cache`/`apt-mark` + exit codes.
- Installing multiple snaps in one `snap install` command — fails when 2+ are already installed.
- `flatpak remote-add` without `--if-not-exists`, or installing before adding the remote.
- Trusting a stored "installed" flag instead of a live `check()` — drifts from reality and breaks idempotency.
- Branching on `entry.type` anywhere outside `core/providers/` — type dispatch belongs in the registry only.
