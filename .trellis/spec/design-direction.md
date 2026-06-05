# Design Decisions & Rationale

> The locked product/architecture decisions the specs in this directory encode. When a spec states a rule, it references this doc for the *why*. These came from a structured design interview; `CLAUDE.md` holds the project goals and domain constraints.

---

## Status: settled inputs, not open questions

Prescriptive and pre-code, like the rest of `.trellis/spec/`. Each item below is a **decided** input to the specs. If one is revisited, change it **here first**, then propagate to the affected spec file(s) listed in the last section.

---

## Decisions

### Audience & target machine
- **Open-source product for strangers.** Therefore trust and safety are first-class constraints, not polish — the tool runs `sudo` on machines its authors will never see.
- **Target is a freshly-installed Ubuntu**, including **Server / no-desktop / SSH**. No assumption of a graphical environment or preinstalled tooling beyond the base system.

### Product shape
- **Terminal TUI (Textual).** Runs everywhere a fresh box does (Server, SSH) with the fewest dependencies — chosen over GTK (needs a desktop) and a local web UI (needs a browser).
- **Persistent manager, not a one-shot provisioner.** Install / remove / upgrade / list at any time. Consequence: every provider implements `check` + `install` + `remove` + `upgrade`.
- **Immediate operations + an auto-recorded, exportable manifest.** The user acts ad-hoc; each action is recorded into a manifest. Replaying that manifest on a fresh machine reproduces the setup — so one tool is both a **manager** (interactive lifecycle) and a **provisioner** (reproducible setup). The manifest is the bridge between the two.

### Architecture
- **Python "brain" + bash/subprocess "hands".** Pure-bash was rejected: the brain (idempotency, a declarative catalog, planning, and the later LLM phase) is too heavy for bash. Python orchestrates; the actual install steps shell out.
- **Declarative catalog + escape hatch.** Typed providers cover the ~90% (apt/ppa/deb/snap/flatpak/dotfile-block/service); a `script` type covers the rest. This keeps entries readable/reviewable and is what makes the future LLM phase safe (it generates *declarative* entries, never scripts).
- **Idempotency by live query.** Each entry's `check()` observes the real system; there is no state-ledger treated as truth (a ledger drifts the moment the user changes something by hand).

### Safety
- **Never run the whole app as root; escalate per command** via `sudo`. Whole-app-root makes user dotfiles `root`-owned and points `$HOME` at `/root`.
- **Config edits use a marked managed block + a backup**, and never clobber unmanaged content. Assume the machine may **not** be pristine (an open-source user runs this over an existing setup) — assume-fresh-but-fail-safe.
- **Fail-fast** on the first error; fix the cause and re-run to resume. There is **no rollback** for system changes (the only reversible thing is config we backed up first).
- **Plan/preview before apply, full audit log, no `curl | bash` self-install.** These are what earn trust for an open-source `sudo`-running tool.

### LLM (post-MVP)
- **Not in the MVP.** When it lands, it drafts **declarative catalog entries only — never `script`**. Preferred topology: maintainer drafts offline → human review → merge into the repo catalog. AI drafts are marked `source: ai-generated` and never auto-promoted into the trusted set. The declarative + schema-bounded catalog is what makes an AI draft a reviewable, diffable artifact.

---

## Where each decision is enforced

| Decision | Enforced in |
|----------|-------------|
| TUI / no business logic in UI | [tui/ui-guidelines.md](./tui/ui-guidelines.md) |
| Python brain / bash hands; layout | [core/directory-structure.md](./core/directory-structure.md) |
| Declarative catalog + escape hatch; providers | [core/catalog-and-providers.md](./core/catalog-and-providers.md), [catalog/authoring-guidelines.md](./catalog/authoring-guidelines.md) |
| Idempotency, planning, fail-fast, manifest | [core/idempotency-and-execution.md](./core/idempotency-and-execution.md) |
| Never-root, per-command sudo, config backup | [core/privilege-and-safety.md](./core/privilege-and-safety.md) |
| Subprocess boundary, errors, audit log | [core/error-and-logging.md](./core/error-and-logging.md) |
| LLM constraints | [catalog/authoring-guidelines.md](./catalog/authoring-guidelines.md) |
