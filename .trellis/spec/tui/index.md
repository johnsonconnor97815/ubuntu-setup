# TUI (the Face) — Spec Index

> Coding guidelines for `ubuntu_setup/tui/`: the Textual terminal UI. It shows state and collects intent; it holds no install/business logic.

---

## Status

No source code yet. These specs are **prescriptive**, derived from `design-direction.md` and verified against Textual 8.x. Pin `textual>=8,<9`.

---

## Guidelines

| Guide | What it covers |
|-------|----------------|
| [TUI Guidelines](./ui-guidelines.md) | The no-business-logic boundary; App/Screen/Widget structure; `reactive()` state; the `@work(thread=True)` worker seam; message bubbling; the immediate-ops + manifest interaction model; headless Pilot testing |

---

## The non-negotiables

1. **No install/business logic in the UI.** A module that imports `textual` must not make install decisions.
2. **Long work runs in a `@work(thread=True)` worker** that calls the `core/` brain; update widgets only via `call_from_thread`/`post_message`.
3. **Plan-by-default**: stage → preview → confirm → apply; every apply updates the exportable manifest.
4. **UI state lives in `reactive()`; domain state lives in `core/`.**
5. **Test headlessly with `run_test()` + `Pilot`**, injecting a fake brain.

Why a TUI (not GTK/web): the target is a fresh Ubuntu that may have no desktop (Server) and may be reached over SSH — a terminal UI runs everywhere with the fewest dependencies. See `design-direction.md`.
