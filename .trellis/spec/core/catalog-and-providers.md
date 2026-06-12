# Catalog & Providers

> The declarative catalog entry and the typed provider that knows how to realize it. This is the heart of the system; read it before touching `core/catalog.py` or anything under `core/providers/`.

---

## Status: `apt` + `deb` + `ppa` + `script` (and the `ctx` contract incl. `aptcache`) code-backed; the rest design-derived

Prescriptive. Field names and provider keys defined here are the contract the first implementation must follow; the `apt`, `deb`, `ppa` and `script` sections (and the freshness guard) now describe shipped code (`core/providers/apt.py`, `deb.py`, `ppa.py`, `script.py`, `aptcache.py`; tests `tests/providers/`, `tests/core/test_aptcache.py`). The command idioms below were verified against current Ubuntu (22.04 / 24.04+), apt/dpkg, snapd, flatpak, and systemd documentation — keep them current, do not regress to the deprecated forms called out as anti-patterns.

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
  check: test -x "$HOME/.cargo/bin/rustc"   # REQUIRED: the idempotency probe (absolute path, never login-shell PATH)
  install: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  depends_on: [curl]
  source: official           # sudo: true would declare a root-level installer (default: plain user)

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
| `ctx.aptcache` | the per-run apt list freshness guard (`providers/aptcache.py`, code-backed): repo-changing ops (`deb` repo mode, `ppa`) call `mark_repo_changed()`; package-installing ops (`apt`, `deb` direct mode) call `ensure_fresh()` before `apt-get install` — `apt-get update` runs once per batch of repo changes, never per package. The executor creates ONE instance per run and shares it across every step's ctx |

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

### `ppa` (code-backed: `ppa.py` — a thin subclass of the deb repo machinery)

A PPA is a third-party APT repo with a fully *derivable* layout, so the provider **subclasses `deb`'s repo mode** instead of shelling out to `add-apt-repository` (form decided 2026-06-12, prd 06-11-provider-ppa). The entry carries a single field `ppa: <owner>/<name>` (bare coordinate, never the `ppa:` prefix; the schema forbids declaring any derived repo field alongside it); the provider translates it once to the equivalent deb repo-mode view, and everything else is shared code — never a copy:

- **translation:** `repo_url = https://ppa.launchpadcontent.net/<owner>/<name>/ubuntu`, `suite = {codename}` (resolved from `/etc/os-release`), `components = [main]`, file basename = the entry id (deliberately NOT `add-apt-repository`'s `<owner>-ubuntu-<name>-<codename>`, so a manually added copy never collides with ours). The signing key comes from the Launchpad API (`https://api.launchpad.net/devel/~<owner>/+archive/ubuntu/<name>?ws.op=getSigningKeyData`), which returns **JSON** — a quoted string embedding the ASCII-armored key (Content-Type `application/json`, verified live 2026-06-12) — so the provider JSON-decodes the download in the deb provider's `_stage_key` hook before the shared armor-sniff + dearmor + `sudo install` flow. JSON `null` (a freshly created PPA whose key is still generating) is a loud `ProviderError`.
- **check:** deb repo-mode check verbatim through the translation — the generated `.sources` byte-match + non-empty keyring + the fetched-lists probe (`/var/lib/apt/lists/ppa.launchpadcontent.net_<owner>_<name>_ubuntu_dists_<codename>_{InRelease,Release}`). Always the live filesystem; never `add-apt-repository --list` (on 24.04 it ignores legacy `.list` files, Launchpad bug 2106617) and never a command's remembered side effect.
- **freshness:** `install()` marks `ctx.aptcache` and never updates itself — the once-per-batch guard, same as deb repo mode; the consuming `apt` package entry triggers the single `apt-get update`.
- **why not `add-apt-repository`:** it requires `software-properties-common` (an in-provider apt install outside the entry model — the spec's earlier `PreconditionError` design is superseded), runs its own `apt-get update` by default (breaking the once-per-batch guard), and its output file name/format vary by release (embedded-key `.sources` on 24.04, `.list` + separate keyring on 22.04) — not byte-for-byte checkable. Direct placement keeps PPAs inside the exact converged-files contract every other repo follows.
- **accepted limitation:** a PPA the user already added via `add-apt-repository` lives under its own basename; ours converges in parallel (apt warns about the duplicate definition but works) — the same accepted-duplication class as any externally configured repo.
- **catalog shape:** repo entry + `apt` package entry linked by `depends_on` (one responsibility per entry, like `deb`); every PPA repo entry `depends_on` curl + gnupg (the key download is curl, and Launchpad keys are always armored). `remove`/`upgrade` are deferred (PPA removal out of scope).

### `deb` (third-party APT repo — the MODERN deb822 + signed-by way; code-backed: `deb.py`)

Two mutually exclusive modes, enforced by `schema.json` and dispatched inside the provider (never outside the registry):

**Repo mode** — fields `key_url` (https only — it is the trust root) + `repo_url` + `suite`, optional `components` / `architectures` / `pin` / `name` (the file basename, default = entry id, charset `[A-Za-z0-9._-]`). Install performs (each privileged step its own `sudo`, no shell pipes — the key is staged in a user-owned temp dir):

```
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL -o <tmp>/<name>.key <key-url>            # unprivileged download
gpg --batch --yes --dearmor -o <tmp>/<name>.gpg …   # ONLY if the key is ASCII-armored (sniffed); a binary keyring (e.g. Brave's) is kept as-is
sudo install -m 0644 <tmp>/… /etc/apt/keyrings/<name>.gpg     # world-readable in one step
sudo install -m 0644 <tmp>/… /etc/apt/sources.list.d/<name>.sources
sudo install -m 0644 <tmp>/… /etc/apt/preferences.d/<name>    # only when `pin` is declared
# NO apt-get update here — the provider marks ctx.aptcache instead (see below)
```

The generated `.sources` body (one function is the source of truth for install *and* the check comparison):

```
Types: deb
URIs: <repo_url>
Suites: <suite>            # may embed {codename} -> resolved from /etc/os-release (UBUNTU_CODENAME, falling back to VERSION_CODENAME)
Components: <components>   # space-joined; the line is omitted entirely for flat repos (kubectl `Suites: /`, Sublime `Suites: apt/stable/`)
Architectures: <archs>     # space-joined; default = the host's `dpkg --print-architecture`
Signed-By: /etc/apt/keyrings/<name>.gpg
```

- Key **must** be dearmored binary (`gpg --dearmor`) and **world-readable** so the `_apt` user can read it, or `apt-get update` fails with a permission error (the `install -m 0644` covers both placement and mode).
- Operator-managed keys go in **`/etc/apt/keyrings`** (available since apt 2.4, i.e. 22.04+); `/usr/share/keyrings` is reserved for package-shipped keys.
- Filenames under `sources.list.d`/keyrings may contain only `[A-Za-z0-9._-]` — others are silently ignored (schema-enforced on `name`).
- `pin` (`{package, pin, priority}`) writes an apt preference — the Firefox official-repo case (`Pin: origin packages.mozilla.org`, priority 1000, so Ubuntu's snap-transition stub never shadows the real deb).
- **check (repo mode):** PRESENT iff the `.sources` file matches the generated content **byte-for-byte**, the keyring exists non-empty, the pin (when declared) matches, **and** the repo's index has actually been fetched (its `InRelease`/`Release` file exists in `/var/lib/apt/lists` under the **exact** apt-mangled name — apt's `URItoFileName`: scheme stripped, `_` and the QuoteString bad set %-quoted, `/`→`_`; computed from `repo_url`+suite for both dists-style and flat repos, never a prefix glob, which would false-match a sibling repo whose URI merely extends this one). Anything else — including content drift — is **ABSENT**: `install()` is the convergence op and rewrites everything. Drift is deliberately *not* OUTDATED (OUTDATED satisfies an install and would never converge); OUTDATED stays reserved for version semantics. The fetched-lists probe is what makes a repo converged without a follow-up `apt-get update` (e.g. a repo-only run) self-heal on the next run. A key changed upstream is not detectable offline (we compare existence, not remote bytes) — accepted limitation.
- **A repo entry never installs packages.** The package is a separate `apt` entry that `depends_on` the repo entry (one responsibility per entry); the planner orders repo before package. A multi-package official install (docker's five) = one entry per package, linked by `depends_on` — never a multi-package `apt` field (decision 06-11-provider-deb; dpkg-level dependencies like docker-ce-cli/containerd.io are left to apt's own resolver).

**Direct mode** — fields `deb_url` (https) + `package` (the binary package the `.deb` provides — required: it is the idempotency probe). Install downloads to a user-owned temp file and runs `apt-get install -y --no-install-recommends -o Dpkg::Options::=… /abs/path.deb` (the leading `./` or an absolute path is required, else apt treats it as a repo package name) — this resolves dependencies in one step; prefer it over `dpkg -i` + `apt-get -f install`. It consumes `ctx.aptcache.ensure_fresh()` first (its dependencies may resolve from a repo converged earlier in the run), and **both the curl download and the apt install use the widened install timeout** — vendor `.deb`s are 100-200MB and the runner's 600s default provably kills the download on slow links (entries-deb full run, 2026-06-12: obsidian's GitHub download died at exit 124). **check (direct mode):** the shared dpkg `${Status}` gate (`apt.py::dpkg_state`).

**The freshness guard (`providers/aptcache.py`, code-backed):** one `AptCache` per executor run, shared via `ctx.aptcache`. Repo-mode install calls `mark_repo_changed()` and never updates itself; every package-installing op (`apt` install, `deb` direct install) calls `ensure_fresh()` right before `apt-get install` — the update runs **iff a repo change is pending**, once per batch, then clears. N repo entries converging back-to-back cost exactly one `apt-get update`; a repo added later in the run still gets its own update before its first consumer. A failed update raises `ProviderError` with the pending flag intact (a retry updates again). See the apt-cache section in [idempotency-and-execution.md](./idempotency-and-execution.md).

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

### `script` (escape hatch — code-backed: `script.py`, tests `tests/providers/test_script.py`)

- The only provider that runs author-supplied commands. Fields: `check` (REQUIRED — the idempotency probe; the schema rejects a missing/empty/non-string one, and a vacuous probe is rejected in review), `install` (required), `remove`/`upgrade` (**reserved**: schema-accepted, op raises `NotImplementedError` — deferred by prd 06-11-provider-script), `sudo` (optional bool, default `false` — the explicit privilege declaration).
- **Execution form (decided 06-11):** author commands are shell strings, run as `["bash", "-o", "pipefail", "-c", <command>]` through the runner — argv list + `shell=False`, the exact string audit-logged via `shlex.join`. `pipefail` is mandatory: the official `curl … | sh` idiom would otherwise swallow a failed download as the interpreter's exit 0. Deliberately **not** a login shell (`-l` would make probes/installs depend on the user's rc files and login-shell PATH — forbidden; probes use absolute paths).
- **Privilege:** default is the **plain user** (most script entries are user-level installs into `$HOME`: rustup/uv/starship class) — for those the provider pins `HOME` to the real user's passwd-DB home (`extra_env`, privilege Rule 3) so `$HOME` in author commands never resolves to `/root` under a sudo'd app launch. `sudo: true` escalates the **whole command string** per command via the runner's `sudo -n env …` variant (root-level installers: ollama/rclone/npm -g class); root-level commands never use `~`/`$HOME` (authoring rule). `check` runs under the **same identity** as the mutating ops, so observations match what install would see. Accepted caveat: a `sudo: true` check without a cached credential fails `sudo -n` and reads ABSENT — conservative; the executor's per-step credential probe then surfaces the real problem as a clean `PrivilegeError` (exit 4).
- **State mapping:** check exit 0 -> PRESENT, any non-zero -> ABSENT — the author's probe IS the contract; there is no machine-readable "real error" band to distinguish (a `tool --version` probe exits 127 when absent), so every non-zero reads "not converged" and errs toward a loud install attempt. `script` never returns OUTDATED (no version semantics). `install` carries the widened install timeout (`apt.py::_INSTALL_TIMEOUT`) — official installers legitimately download hundreds of MB (rust toolchain / ollama bundle class).
- Highest-risk type: it is the one place arbitrary `sudo`/shell runs. **The future LLM phase must never generate `script` entries**, and human review is mandatory for them (every shipped entry's check/install was reviewed with its privilege declaration). See `../catalog/authoring-guidelines.md`.

---

## Anti-patterns (forbidden)

- `apt-key add` — dead. apt stopped using it for verification (apt 2.9.15, Nov 2024); Debian 13 removed it. Use `gpg --dearmor` into `/etc/apt/keyrings` + `Signed-By`.
- A one-line `deb …` source **without** `signed-by=` — apt 2.9.24 (Jan 2025) deprecated it and stopped trusting `/etc/apt/trusted.gpg{,.d}`. Every third-party repo carries its own scoped key.
- Parsing human-readable `apt` (not `apt-get`) stdout to make decisions — unstable interface; use `apt-get`/`apt-cache`/`apt-mark` + exit codes.
- Installing multiple snaps in one `snap install` command — fails when 2+ are already installed.
- `flatpak remote-add` without `--if-not-exists`, or installing before adding the remote.
- Trusting a stored "installed" flag instead of a live `check()` — drifts from reality and breaks idempotency.
- Branching on `entry.type` anywhere outside `core/providers/` — type dispatch belongs in the registry only.
