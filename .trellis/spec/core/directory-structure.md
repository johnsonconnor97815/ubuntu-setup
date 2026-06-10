# Core Directory Structure

> How the application is organized, and the hard boundary between the Python "brain" and the install "hands".

---

## Status: design-derived, not yet code-backed

This repository has **no product source code yet** (only `CLAUDE.md`, `README.md`, `LICENSE`). Every rule here is **prescriptive**: it defines the layout the first code must adopt, derived from the approved design in `CLAUDE.md` and the project memory `design-direction.md`. When code lands, reconcile this file with reality and replace planned paths with real ones — but do not silently drop a rule; change the design on purpose.

---

## The one boundary that matters

Two responsibilities, never mixed in one module:

- **Brain** (`ubuntu_setup/core/`, `ubuntu_setup/cli.py`): decide *what* to do — load the catalog, compute a plan, check current state, order steps, record the manifest. Pure logic. No `textual` imports. No interactive prompts.
- **Hands** (provider `install`/`remove` bodies, `core/runner.py`): actually run `apt-get`, `snap`, file writes — always through the one subprocess runner, never with ad-hoc `os.system`.
- **Face** (`ubuntu_setup/tui/`): show state and collect intent. No install logic, no `subprocess`, no `sudo`. The TUI calls the brain inside Textual workers and renders events; it never shells out itself. See `../tui/ui-guidelines.md`.

Rule of thumb (verified against Textual's own guidance): **if a module imports `textual`, it must not contain install/business decisions; if a module contains install/business logic, it must not import `textual`.**

---

## Directory Layout

The top-level package is `ubuntu_setup/` (rename consistently if the project is renamed; keep it one import root). Distribution is a `pyproject.toml` package — never a `curl | bash` self-installer (see [privilege-and-safety.md](./privilege-and-safety.md)).

```
ubuntu_setup/
├── __init__.py
├── __main__.py            # `python -m ubuntu_setup` → cli.main()
├── cli.py                 # arg parsing, bootstrap checks, launch TUI or run headless --apply
├── core/                  # THE BRAIN — pure logic, no UI, no direct terminal I/O
│   ├── __init__.py
│   ├── models.py          # dataclasses: CatalogEntry, Action, Plan, StepResult, Manifest
│   ├── catalog.py         # load + validate the declarative catalog (YAML → models)
│   ├── providers/         # one typed handler per entry `type`
│   │   ├── __init__.py    # registry: type string → Provider
│   │   ├── base.py        # Provider protocol: check / install / remove / upgrade
│   │   ├── apt.py
│   │   ├── ppa.py
│   │   ├── deb.py
│   │   ├── snap.py
│   │   ├── flatpak.py
│   │   ├── dotfile_block.py
│   │   ├── service.py
│   │   └── script.py      # the escape hatch — see ../catalog/authoring-guidelines.md
│   ├── planner.py         # desired actions → ordered Plan (dependency sort) + dry-run diff
│   ├── executor.py        # run a Plan as a generator of events: fail-fast, check-before-act
│   ├── events.py          # the progress-event dataclasses the executor yields (RunStarted … RunFinished)
│   ├── service.py         # orchestration facade: load → plan → apply (+ cancel) → record; full-status scan — shared by CLI & TUI
│   ├── runner.py          # the ONLY subprocess wrapper: env, logging, capture, timeout
│   ├── privilege.py       # sudo validate + keep-alive, real-user/home resolution
│   ├── state.py           # live system queries + manifest (desired-state) read/write
│   └── errors.py          # exception taxonomy (see error-and-logging.md)
├── tui/                   # THE FACE — Textual only, no business logic
│   ├── __init__.py
│   ├── app.py             # the Textual App + key bindings
│   ├── screens/           # browse, plan-confirm, progress, installed
│   └── widgets/           # reusable widgets
├── catalog/               # shipped declarative catalog DATA (YAML) + schema
│   ├── schema.json        # JSON Schema the loader validates every entry against
│   └── *.yaml             # catalog entries grouped by tag/domain
└── llm/                   # POST-MVP. Empty/stub until the LLM phase. See ../catalog/authoring-guidelines.md
    └── __init__.py

tests/                     # mirrors the package: tests/core/, tests/providers/, tests/tui/
pyproject.toml             # package metadata, deps (textual>=8,<9, pyyaml, jsonschema), entry point
```

---

## Module Rules

- **`core/` never imports `tui/`.** Dependencies point one way: `cli` → `tui` → `core`. The brain is usable headless (`--apply <manifest>`), which is also how the catalog is unit-tested without a terminal.
- **Every external command goes through `core/runner.py`.** No bare `subprocess.run` / `os.system` scattered in providers. The runner centralizes the non-interactive environment (`DEBIAN_FRONTEND=noninteractive`, forced `LC_ALL=C` so apt output is parseable), `argv`-list invocation with `shell=False`, logging of the exact argv, output capture, and timeouts — see [error-and-logging.md](./error-and-logging.md).
- **Providers are the only place that knows install mechanics.** A new software *type* = a new file in `core/providers/` implementing the protocol in `base.py` + one registry entry. Nothing else in the brain branches on `entry.type`. See [catalog-and-providers.md](./catalog-and-providers.md).
- **Catalog data is not code.** Entries live in `ubuntu_setup/catalog/*.yaml`, validated against `catalog/schema.json`. Adding a normal package must not require touching Python — that is the whole point of the declarative + escape-hatch model, and what keeps the future LLM phase safe.
- **Runtime state lives outside the package**, in the user's XDG state dir: logs and the manifest go to `~/.local/state/ubuntu-setup/` (resolved via `privilege.real_home()`, never `/root` under sudo), not under `ubuntu_setup/`. The package ships code and the catalog only. See [error-and-logging.md](./error-and-logging.md) and [idempotency-and-execution.md](./idempotency-and-execution.md).

---

## Naming Conventions

- Modules and functions: `snake_case`. Classes and dataclasses: `PascalCase`. Provider files are named after the `type` string they handle (`type: dotfile-block` → `dotfile_block.py`, registered under the key `"dotfile-block"`).
- One provider class per file, named `<Type>Provider` (`AptProvider`, `ScriptProvider`).
- Tests mirror source paths: `core/providers/apt.py` → `tests/providers/test_apt.py`.
