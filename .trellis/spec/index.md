# Project Spec Index

> Project-specific coding guidelines for this repository, loaded into `trellis-implement` / `trellis-check` sub-agents. Read the layer index relevant to what you're about to write.

---

## What this project is

An **idempotent software manager for Ubuntu** with a terminal UI. It installs and configures software on freshly-installed Ubuntu machines (including Server / no-desktop / SSH), as a persistent **manager** (install / remove / upgrade / list) whose every action is recorded into an exportable **manifest** — so the same manifest replays on a new machine (the manager doubles as a **provisioner**). Distributed as an **open-source product**, so trust and safety for strangers running `sudo` are first-class constraints. An **LLM phase is post-MVP** and generates declarative catalog entries only. Project goals and constraints live in `CLAUDE.md`; the locked design decisions these specs encode live in [design-direction.md](./design-direction.md).

---

## ⚠️ Status: prescriptive, not yet code-backed

This repository has **no product source code yet** — only `CLAUDE.md`, `README.md`, `LICENSE`. Normal Trellis specs *describe* an existing codebase; these specs **prescribe** the codebase to be written, derived from the approved design and from current (2026) Ubuntu/apt/snap/flatpak/systemd/sudo/Textual documentation that was verified while writing them.

Consequences for anyone using these specs:
- Treat file paths and module names as the **intended** layout (see [core/directory-structure.md](./core/directory-structure.md)), not as existing files.
- When the first code lands, **reconcile each spec with reality** — replace planned paths with real ones, keep the rules. Use `trellis-update-spec` to capture anything learned.
- The command idioms (apt/snap/flatpak/sudo/systemd) were verified current; the anti-patterns (e.g. `apt-key`) are genuinely dead — don't reintroduce them.

---

## Architecture at a glance

```
cli ──► tui (Textual, the "face") ──► core (the "brain")
                                        ├─ catalog.py     load + validate declarative YAML
                                        ├─ providers/     typed handlers: apt/ppa/deb/snap/
                                        │                  flatpak/dotfile-block/service/script
                                        ├─ planner.py     depends_on → topological Plan
                                        ├─ executor.py    plan-by-default, fail-fast, idempotent
                                        ├─ privilege.py   per-command sudo, never whole-app root
                                        ├─ runner.py      the one subprocess boundary
                                        └─ state.py       live queries + exportable manifest
catalog/*.yaml ─ declarative data the engine interprets (LLM target, post-MVP)
```

Dependencies point one way: `cli → tui → core`. **`core/` never imports `textual`.**

---

## Layer specs

| Layer | Index | Read before writing… |
|-------|-------|----------------------|
| Core (brain) | [core/index.md](./core/index.md) | catalog loading, providers, planning/execution, privilege, runner/logging |
| TUI (face) | [tui/index.md](./tui/index.md) | anything under `tui/` (Textual) |
| Catalog (data) | [catalog/index.md](./catalog/index.md) | authoring `catalog/*.yaml` entries |
| Thinking guides | [guides/index.md](./guides/index.md) | idempotency, safety, cross-layer, code-reuse — skim before coding |
| Design rationale | [design-direction.md](./design-direction.md) | understanding *why* a rule exists, before changing one |

---

## Project-wide non-negotiables

1. **Brain / face split** — a module imports `textual` **or** contains install logic, never both.
2. **`check()` is the idempotency engine** — query the live system, never a state ledger; every step is safe to run twice.
3. **Never run as root** — escalate per command via `sudo`; resolve user paths via `SUDO_USER`, never `~`/`$HOME` under sudo.
4. **Plan before apply; fail fast** — show what will happen, stop on first error, re-run to resume (no rollback).
5. **One subprocess boundary** — every external command goes through `core/runner.py` (argv list, non-interactive env, `LC_ALL=C`, logged).
6. **Type dispatch only in the provider registry** — adding a software type is a local change; nothing else branches on `entry.type`.
7. **Catalog is data, not code** — declarative + escape hatch; the LLM phase emits declarative, schema-valid entries only, never `script`.

---

## Global conventions

- **Language:** spec docs and code/comments in **English** (open-source product). Python ≥ 3.9.
- **Style:** `snake_case` modules/functions, `PascalCase` classes; one `<Type>Provider` per provider file; tests mirror source paths under `tests/`.
- **Dependencies:** `textual>=8,<9`, `pyyaml`, `jsonschema`; pin majors and read CHANGELOGs before bumping. No `curl | bash` self-install — distribute via pip/pipx or a signed `.deb`.
- **Tests:** brain is headless-unit-testable (no terminal); TUI tested with Textual's `run_test()` + `Pilot` and a fake brain; assert the second run of any action is a skipped no-op.

---

## A note for `trellis-check`

When reviewing code against these specs, weight the safety and idempotency rules heavily — they protect a stranger's machine. A change that runs `sudo` without a plan/confirm, writes user files as root, appends to a dotfile without markers, trusts a flag instead of a live `check()`, or branches on `entry.type` outside the registry is a spec violation, not a style nit.
