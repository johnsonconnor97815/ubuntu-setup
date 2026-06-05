# Cross-Layer Thinking Guide

> **Purpose**: Think through how data and control move across this project's layers before implementing.

---

## The Problem

**Most bugs happen at layer boundaries**, not within a layer. In this project the layers are:

```
catalog (YAML)  →  core/catalog.py (models)  →  planner  →  executor  →  provider  →  runner (subprocess)
                                                    │                          │
                                                    └────────── tui (workers, events) ◄┘
```

The boundaries that bite here:

| Boundary | Common issue |
|----------|--------------|
| catalog YAML ↔ `models` | A field the schema allows but no provider reads; a `type` with no registered provider |
| `core` ↔ `providers` | A provider that mutates in `check()`, or branches on `type` outside the registry |
| `executor` ↔ `runner` | Decisions made on scraped stdout instead of exit codes; missing non-interactive env |
| `core` (brain) ↔ `tui` (face) | Business logic leaking into the UI; the UI holding domain state instead of mirroring the brain |
| process ↔ OS (sudo) | Writing user files as root; `$HOME` resolving to `/root` |

---

## Before implementing a cross-layer feature

### Step 1: Map the flow

Trace one entry end to end. Example — installing an `apt` package:

```
YAML entry → validated CatalogEntry → planner expands depends_on + topo-sorts
→ executor calls provider.check() → ABSENT → provider.install() → runner (sudo, noninteractive)
→ StepResult → executor records manifest transaction → tui renders the event
```

For each arrow ask: what's the data shape, who validates it, what can go wrong?

### Step 2: Respect the dependency direction

Dependencies point **one way**: `cli → tui → core`. `core/` never imports `tui/`.

- [ ] Did I keep install logic in `core/`/providers, callable headless?
- [ ] Is the TUI only composing widgets, holding UI state, and driving workers?
- [ ] Does any module import *both* `textual` and `subprocess`? (Wrong layer.)

### Step 3: Define the contract at each boundary

- **catalog ↔ core:** the JSON Schema is the contract. New field → update schema *and* the provider that consumes it, together.
- **core ↔ provider:** the `Provider` protocol — `check()` never mutates; the four ops are idempotent; type dispatch is registry-only.
- **executor ↔ runner:** branch on `returncode`, not localized text (force `LC_ALL=C`); all commands through the runner.
- **brain ↔ tui:** the brain yields **events**; the worker marshals them to the UI via `call_from_thread`/`post_message`. State the user sees is derived from the brain's live `check()`, not a UI-kept cache.

---

## Common cross-layer mistakes here

### Mistake 1: The UI becomes the source of truth

**Bad**: the TUI tracks "installed" in a reactive and trusts it.
**Good**: the TUI renders what `core` reports from a live `check()`; the manifest records *desired* state, not current state.

### Mistake 2: Type knowledge leaks out of the registry

**Bad**: the planner or TUI does `if entry.type == "apt": ...`.
**Good**: only `core/providers/__init__.py` maps `type → Provider`; everyone else calls the protocol.

### Mistake 3: Privilege/home assumptions cross the boundary silently

**Bad**: a provider calls `os.path.expanduser("~")` and the executor happened to run under sudo → writes to `/root`.
**Good**: user paths resolve through `privilege.real_home()` regardless of how the process was launched.

---

## Checklist for cross-layer features

Before implementation:
- [ ] Mapped the full flow for one representative entry
- [ ] Confirmed dependency direction (`core` imports nothing from `tui`)
- [ ] Defined the contract at each boundary (schema, protocol, exit codes, events)
- [ ] Decided where validation happens (once, at the catalog/load boundary)

After implementation:
- [ ] Tested the brain headless (no terminal) and the TUI with a fake brain
- [ ] Verified decisions use exit codes, not scraped text
- [ ] Verified user paths never resolve to `/root` under sudo
- [ ] Ran the action twice to confirm idempotent skip

---

**Core Principle**: each layer should know only its neighbors. The catalog doesn't know about Textual; the TUI doesn't know how apt works; the runner doesn't know what a "PPA" is.
