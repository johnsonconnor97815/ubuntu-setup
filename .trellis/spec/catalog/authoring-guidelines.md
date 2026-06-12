# Catalog Authoring Guidelines

> How to write entries in `ubuntu_setup/catalog/*.yaml`. Catalog entries are **data, not code** — adding normal software must never require touching Python. This is also the contract the future LLM phase generates against.

---

## Status: design-derived, not yet code-backed

Prescriptive. The field set and `type` keys here must match `core/catalog.py` / `catalog/schema.json` and the providers in [../core/catalog-and-providers.md](../core/catalog-and-providers.md). The schema is the enforcement mechanism; this doc is the human guide.

---

## An entry is declarative data

Each software unit is one YAML mapping, validated against `catalog/schema.json` at load. The engine interprets fields — it does not execute author-supplied commands except inside the `script` escape hatch.

```yaml
- id: ripgrep            # required: unique, kebab-case; the depends_on reference key
  description: "Fast recursive grep"   # required: one human line (shown in the TUI)
  type: apt              # required: selects the provider
  package: ripgrep       # type-specific
  depends_on: []         # optional (default []): ids that must converge first
  tags: [cli, search]    # optional (default []): grouping / profiles
  requires: []           # optional (default []): host capabilities needed; enum: desktop
  source: official       # optional (default community): official | community | ai-generated
```

---

## Fields per `type`

Common to all: `id`, `description`, `type`, `depends_on`, `tags`, `requires`, `source`. Type-specific required fields:

| `type` | Required type fields | Optional | Notes |
|--------|----------------------|----------|-------|
| `apt` | `package` | `version`, `hold` | Standard package. `version` pins to `<pkg>=<version>`; the check compares the installed version. |
| `ppa` | `ppa` (`<owner>/<name>` — the bare Launchpad coordinate, never the `ppa:` prefix) | — | A `depends_on` target of an `apt` entry (code-backed: `ppa.py` + `schema.json`). Everything else is derived by the provider (launchpadcontent.net URL, `{codename}` suite, `main` component, Launchpad-API signing key, basename = entry id); the schema rejects any declared repo field alongside `ppa`. |
| `deb` | **repo mode:** `repo_url`, `key_url`, `suite` — **or** — **direct mode:** `deb_url`, `package` | repo mode: `components`, `architectures`, `pin`, `name` | Two mutually exclusive modes (code-backed: `deb.py` + `schema.json`): a third-party APT repo (deb822 + key) **or** a remote `.deb`. `key_url` must be https (the trust root). `suite` may embed `{codename}` (resolved from `/etc/os-release` — the Docker/HashiCorp pattern); omit `components` for flat repos (`Suites: /`); `architectures` defaults to the host arch; `pin` (`{package, pin, priority}`) writes `/etc/apt/preferences.d/<name>` (the Firefox pin-priority-1000 case); `name` is the file basename under keyrings/sources.list.d (default: entry id). Direct mode requires `package` — the dpkg idempotency probe for the installed `.deb`. |
| `snap` | — (the store name defaults to the entry id) | `snap` (store name when it differs from the id), `classic: true`, `channel` | Code-backed: `snap.py` + `schema.json`. Set `classic: true` **iff** `snap info` shows `confinement: classic` (verified per entry at review). `channel` only for a non-default track (`latest/stable` is implied). The schema rejects other types' identity fields (`package`, `deb_url`, repo fields, `ppa`, `check`/`install`/`sudo`) on a snap entry. snapd is a host precondition (PreconditionError skip), never a catalog entry or `depends_on` edge. |
| `flatpak` | `app_id` | `scope: system\|user` (default `system`) | The provider ensures flatpak + the flathub remote (in the chosen scope) first. |
| `dotfile-block` | `file`, `marker`, `content` | — | `file` may use `~` (resolved to the real user's home). |
| `service` | `unit` | `scope: system\|user` | enable/start a systemd unit. |
| `script` | `check`, `install` | `sudo: true`, (`remove`, `upgrade` — reserved, ops deferred) | **Escape hatch.** `check` is mandatory (idempotency probe; schema-rejected when missing/empty). `sudo: true` declares a root-level installer — the engine escalates the whole command per-command; default is the plain user (user-level installs into `$HOME`). Commands run as `bash -o pipefail -c` (code-backed: `script.py`). |

`depends_on` lists `id`s that must reach the desired state first; the planner topologically orders them (see [../core/idempotency-and-execution.md](../core/idempotency-and-execution.md)). Don't encode ordering any other way.

`requires` declares host applicability (currently only `desktop`): mark GUI software `requires: [desktop]` so a Server/SSH machine without a desktop stack hides it in browse and *visibly skips* it on a manifest replay instead of erroring. Repo entries (`ppa`/`deb`) a GUI package depends on usually need no `requires` of their own — the dependent carries it.

---

## File organization & sourcing comments (code-backed)

The shipped catalog is split into **one YAML file per domain** under `ubuntu_setup/catalog/` (`ai-tools.yaml`, `bedrock.yaml`, `build-toolchain.yaml`, `cli-tools.yaml`, `containers-devops.yaml`, `databases.yaml`, `editors.yaml`, `gui-apps.yaml`, `languages.yaml`, `media-graphics.yaml`, `network-tools.yaml`, `package-managers.yaml`, `shell-and-monitoring.yaml`, `vcs.yaml`). The loader globs `*.yaml`, so the split is purely organizational — ids stay globally unique across files (loader-enforced), and a new file needs zero code.

Sourcing discipline (the trust narrative's zero-engineering half): **every shipped entry carries a comment** above it citing (a) the upstream official install doc URL and (b) its intersection-research hits (`.trellis/tasks/06-10-intersection-research/research/final-list.json`), plus any actionable caveat (renamed binaries like `batcat`/`fdfind`/`7zz`, conflicts like mysql↔mariadb, "usually preinstalled" notes). Entries added outside the research pipeline state their provenance instead (e.g. `bedrock whitelist (approved <date>)`, `dependency citation: prerequisite of N entries`). `tests/core/test_catalog_content.py` locks ids/packages/`requires` to the research annotations.

---

## Authoring rules

1. **Prefer a declarative `type` over `script`.** If a thing can be expressed as `apt`/`snap`/`flatpak`/`deb`/`dotfile-block`/`service`, use it. Reach for `script` only when nothing else fits — it is the one type whose body runs arbitrary commands.
2. **Every entry must be idempotently checkable.** For `script`, that means a real `check` (e.g. `command -v rustc`, a version probe) — not `true`. If you can't write a check, the entry isn't ready.
3. **No interactive or `apt-key`-style commands.** Installs must be non-interactive; third-party repos use the deb822 + `signed-by` pattern; never `apt-key add`, never a sourceless `deb` line, never `curl | bash` for things expressible as a provider. (See the anti-patterns in [../core/catalog-and-providers.md](../core/catalog-and-providers.md).)
4. **One responsibility per entry.** A repo (`ppa`/`deb`) and the package it provides are separate entries linked by `depends_on`, so each has its own `check` and can be reused. When the upstream's official command installs **several packages from one repo** (docker's five), keep one `apt` entry per package, all `depends_on` the repo entry; the user-facing entry may `depends_on` the sibling plugins so installing it converges the official set (decision 06-11-provider-deb: docker -> docker-buildx + docker-compose). Never model dpkg-level `Depends` (docker-ce-cli, containerd.io) as catalog entries — apt's resolver owns those.
5. **Set `source` honestly.** `official` = maintainer-curated and reviewed; `community` = contributed, reviewed; `ai-generated` = produced by the LLM phase, **not** yet promoted into the trusted set.
6. **Write a real `description`.** It is what the user reads in the TUI to decide; one concrete line, no marketing.
7. **`deb` conventions from the shipped batch** (code-backed: entries-deb, 2026-06-11; locked by `tests/core/test_catalog_content.py`):
   - **Bootstrap tools are `depends_on` edges:** a repo entry depends on `curl` (the provider downloads the key with it) plus `gnupg` *only when the key is ASCII-armored* (binary keyrings — brave, gh — skip the dearmor); a direct-mode entry depends on `curl` (it downloads the `.deb`).
   - **A direct-mode entry IS the package**, so a GUI one carries `requires: [desktop]` itself (repo entries still never carry `requires` — their GUI dependent does).
   - **Versioned `deb_url` maintenance note:** when upstream has no unversioned permalink (obsidian, vivaldi), pin the current versioned URL and say in the sourcing comment that upgrading the entry means bumping the URL. Same idea for rotating trust roots (spotify's key id is embedded in `key_url`) and minor-pinned repo URLs (kubectl's `v1.36`): the comment must name what to edit when upstream moves.
   - **Never reuse a vendor-managed sources basename.** Some vendor packages (the Google-derived postinst family: edge, chrome) hardcode and *rewrite* their own `/etc/apt/sources.list.d/<basename>.sources|.list` on every install — a repo entry whose `name` collides (e.g. `microsoft-edge`) fails the byte-match `check()` forever and never converges (found 2026-06-12). Pick a distinct basename (`edge-repo`); the vendor postinst then detects the existing source and comments out its own copy.
8. **`script` conventions from the shipped batch** (code-backed: 06-11-provider-script; locked by `tests/core/test_catalog_content.py`):
   - **Install commands are the upstream's official ones, quoted verbatim** (the "trust the official source" decision), with only reviewed, comment-documented adaptations: non-interactive flags the installer itself documents (rustup `-y`, starship `--yes`), staging in `mktemp -d` instead of the invoker's cwd (lazygit), a `pipefail`-safe `-fsSL` on curl, and environment fallbacks the script needs in non-login contexts (pnpm's `SHELL`). The sourcing comment names every adaptation.
   - **The privilege declaration mirrors where the artifact lands:** user-level installers (`$HOME` targets: rustup, uv, bun, deno, pnpm, starship, zoxide, pipx apps, zed) never declare `sudo`; root-path installers (/usr/local, /opt, /usr/bin, npm -g's /usr/local prefix: lazygit, gradle, rclone, typescript, yarn, ollama) declare `sudo: true` — and **never carry an inline `sudo` in the command** (the engine escalates per-command; an upstream line like `… | sudo bash` becomes `… | bash` + `sudo: true`).
   - **Probes are absolute-path executable tests** (`test -x /usr/local/bin/x`, `test -x "$HOME/.cargo/bin/rustc"`), never login-shell-PATH lookups (`command -v x` only works when the rc files ran). Root-level probes never use `$HOME`; user-level ones do (the provider pins `HOME` from the passwd DB).
   - **Hard installer prerequisites become `depends_on` edges**, including ones upstream forgot to document — found by real-install verification: pnpm v11's standalone binary needs `libatomic1`; ollama's `.tar.zst` bundles need `zstd`; Ubuntu's `nodejs` ships without `npm` (typescript/yarn need the separate package); bun/deno/rclone need `unzip`; gradle's doc requires a JDK 17+ (`openjdk`).
   - **Version-pinned installs pin the probe too** (gradle's `/opt/gradle/gradle-9.5.1`): bumping the version means editing install AND check together (the stale probe then reads ABSENT and the entry re-converges) — say so in the sourcing comment.
   - Shell-rc edits (PATH exports, `starship init`, `zoxide init`) belong to the user or to the official script itself — never to the entry.
9. **`ppa` conventions from the shipped batch** (code-backed: 06-11-provider-ppa; locked by `tests/core/test_catalog_content.py`):
   - **The entry is ONLY the coordinate.** Everything else (URL, key, suite, basename) is derived by the provider — never hand-write a `deb` entry for a Launchpad PPA, and never declare repo fields on a `ppa` entry (schema-rejected).
   - **Every PPA repo entry `depends_on` curl + gnupg**: the signing key is downloaded with curl from the Launchpad API and is always ASCII-armored (the binary-keyring exception of the deb batch cannot occur here).
   - **The PPA must be the upstream's documented channel** — cite the official page that names it in the sourcing comment (inkscape's release page, OBS's linux-installation kb, yt-dlp's install wiki, fastfetch's README). A PPA run by a third party the upstream doc cites (yt-dlp's tomtomtom) is acceptable but the comment must say so.
10. **`snap` conventions from the shipped batch** (code-backed: 06-11-provider-snap; locked by `tests/core/test_catalog_content.py`):
    - **Store name, publisher and confinement are verified against the Snap Store at review time** (`snap info` / snapcraft.io), and the sourcing comment records the publisher's verification status (Canonical/jetbrains/Telegram FZ-LLC are verified accounts; yq's `mikefarah` is the upstream author himself, unverified — said so explicitly).
    - **Declare `snap` only when the store name differs from the entry id** (telegram -> telegram-desktop, jetbrains-idea -> intellij-idea, jetbrains-pycharm -> pycharm); ids keep following the final-list keys.
    - **`classic: true` mirrors the store's confinement exactly** (the three JetBrains snaps); never set it speculatively. No shipped entry pins a `channel` — latest/stable throughout.
    - **snapd is never an entry or a `depends_on` edge**: it ships preinstalled on real Ubuntu, and a snapd-less host (container, de-snapped install) is a visible PreconditionError skip — the tool never installs snapd itself.
    - The snap is chosen per the project priority (apt > ppa/deb > snap > script) only when no apt/deb channel is usable: stale-beyond-usable apt (kotlin 1.3), snap-stub apt packages (chromium, thunderbird), wrong same-named apt package (yq is kislyuk/yq), or no Linux package at all (telegram, the JetBrains IDEs).

---

## The LLM phase (post-MVP) generates against this contract

The LLM is **not in the MVP**. When it lands, its job is to draft *declarative entries* for software not yet in the catalog — and the safety of that phase comes entirely from the constraints here:

- **The LLM emits declarative entries only**, validated against `catalog/schema.json` before a human ever sees them. A draft that fails schema validation is rejected, not patched by hand into something unreviewed.
- **The LLM may never emit a `script` entry.** The escape hatch is the one place arbitrary `sudo`/shell runs; AI-generated arbitrary commands on a stranger's machine is exactly the failure mode the design forbids. `script` entries are human-authored and human-reviewed only.
- **AI drafts are marked `source: ai-generated`** and never auto-promoted into the trusted (`official`/`community`) set.
- **Preferred topology:** maintainer-offline drafting → human review → merge into the repo catalog; end users receive only reviewed entries. A future "generate locally" feature must still produce a schema-valid declarative entry shown as a diff and never auto-applied. See `design-direction.md`.

Because entries are declarative and schema-bounded, an AI draft is a reviewable, diffable artifact — that is the whole point of choosing "declarative + escape hatch" over "generate a shell script".

---

## Anti-patterns (forbidden)

- Using `type: script` for something a real provider already handles.
- A `script` entry with `check: true` (or no meaningful check) — defeats idempotency.
- Encoding install order via file ordering or comments instead of `depends_on`.
- Embedding `apt-key`, a `deb` line without `signed-by`, or an interactive installer.
- Marking a contributed/AI entry as `source: official` to bypass review.
- An LLM-generated `script` entry (must never exist).
