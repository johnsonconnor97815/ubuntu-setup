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
| `ppa` | `ppa` (`user/name`) | — | Usually a `depends_on` target of an `apt` entry. |
| `deb` | **repo mode:** `repo_url`, `key_url`, `suite`, `components` — **or** — **direct mode:** `deb_url` | `arch` (repo mode) | Two mutually exclusive modes: a third-party APT repo (deb822 + key) **or** a direct `.deb`. Supply the fields for exactly one mode. |
| `snap` | `name` | `classic: true` | Set `classic: true` only if `snap info` shows `confinement: classic`. |
| `flatpak` | `app_id` | `scope: system\|user` (default `system`) | The provider ensures flatpak + the flathub remote (in the chosen scope) first. |
| `dotfile-block` | `file`, `marker`, `content` | — | `file` may use `~` (resolved to the real user's home). |
| `service` | `unit` | `scope: system\|user` | enable/start a systemd unit. |
| `script` | `check`, `install` | `remove`, `upgrade` | **Escape hatch.** `check` is mandatory (idempotency probe). |

`depends_on` lists `id`s that must reach the desired state first; the planner topologically orders them (see [../core/idempotency-and-execution.md](../core/idempotency-and-execution.md)). Don't encode ordering any other way.

`requires` declares host applicability (currently only `desktop`): mark GUI software `requires: [desktop]` so a Server/SSH machine without a desktop stack hides it in browse and *visibly skips* it on a manifest replay instead of erroring. Repo entries (`ppa`/`deb`) a GUI package depends on usually need no `requires` of their own — the dependent carries it.

---

## Authoring rules

1. **Prefer a declarative `type` over `script`.** If a thing can be expressed as `apt`/`snap`/`flatpak`/`deb`/`dotfile-block`/`service`, use it. Reach for `script` only when nothing else fits — it is the one type whose body runs arbitrary commands.
2. **Every entry must be idempotently checkable.** For `script`, that means a real `check` (e.g. `command -v rustc`, a version probe) — not `true`. If you can't write a check, the entry isn't ready.
3. **No interactive or `apt-key`-style commands.** Installs must be non-interactive; third-party repos use the deb822 + `signed-by` pattern; never `apt-key add`, never a sourceless `deb` line, never `curl | bash` for things expressible as a provider. (See the anti-patterns in [../core/catalog-and-providers.md](../core/catalog-and-providers.md).)
4. **One responsibility per entry.** A repo (`ppa`/`deb`) and the package it provides are separate entries linked by `depends_on`, so each has its own `check` and can be reused.
5. **Set `source` honestly.** `official` = maintainer-curated and reviewed; `community` = contributed, reviewed; `ai-generated` = produced by the LLM phase, **not** yet promoted into the trusted set.
6. **Write a real `description`.** It is what the user reads in the TUI to decide; one concrete line, no marketing.

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
