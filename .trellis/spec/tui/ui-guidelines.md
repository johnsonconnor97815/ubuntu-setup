# TUI Guidelines (Textual)

> Coding conventions for `ubuntu_setup/tui/`: a Textual front-end that shows state and collects intent, and contains **no install/business logic**.

---

## Status: design-derived, not yet code-backed

Prescriptive. Verified against Textual 8.x (latest 8.2.7, May 2026; requires Python ≥3.9). Pin `textual>=8,<9` and read the CHANGELOG before a major bump — Textual ships frequent releases with occasional breaking changes (and snapshot baselines shift between majors).

---

## The boundary: no business logic in the UI

The single most important rule (it is the other half of the brain/face split in `../core/directory-structure.md`):

> If a module imports `textual`, it must not contain install/business decisions. If a module contains install/business logic, it must not import `textual`.

The TUI only: composes widgets, holds **UI** state in `reactive()` attributes, dispatches messages, and drives **workers** that call the import-`textual`-free `core/` brain.

```python
# tui/app.py
from textual import work
from textual.app import App
from ubuntu_setup.core.executor import Executor      # brain: ZERO textual imports

class ManagerApp(App[None]):
    def __init__(self, executor: Executor) -> None:
        super().__init__()
        self._executor = executor                     # inject the brain
```

Putting install logic in an event handler or `compose()` blocks the event loop and freezes the UI. Handlers only dispatch to a worker; long work lives in `@work` methods that call `core/`.

---

## Structure: App / Screen / Widget

- **`App`** (`tui/app.py`) owns the event loop and the screen stack; subclass `App[ReturnType]`.
- **`Screen`** = a full-window page on the stack (`tui/screens/`): browse, plan-confirm, progress, installed. Use `ModalScreen[T]` for the confirm dialog and `self.dismiss(value)` / `await self.push_screen_wait(screen)` to get a result back.
- **`Widget`** (`tui/widgets/`) = reusable UI elements.
- Declare the tree in `compose()` (`yield` children, or `with Container():` to nest). Keep `compose()` declarative — no business calls. Map keys via `BINDINGS` to `action_*` methods.

---

## State: `reactive()` for UI, plain objects for domain

- Hold **UI** state (selection, progress %, filter text) in `reactive()` class attributes; assignment auto-refreshes and fires `watch_<name>(old, new)` / `validate_<name>` / `compute_<name>`.
- Use `var(...)` for internal state that should **not** trigger a refresh.
- **Domain state stays in plain `core/` objects**, not in reactives. The TUI mirrors what the brain reports; it is not the source of truth.

---

## Long-running work: workers only

Installs are blocking subprocess work. They must run in a **worker** so the UI never freezes:

```python
from textual import work                              # NOTE: top-level import, not textual.work
from textual.worker import get_current_worker

class ManagerApp(App[None]):
    @work(thread=True, exclusive=True, group="apply")  # thread=True for blocking work
    def apply_plan(self, plan) -> None:
        worker = get_current_worker()
        for event in self._executor.run(plan):         # brain yields progress events
            if worker.is_cancelled():
                return
            self.call_from_thread(self._append_event, event)   # marshal UI update back
```

Rules (verified):

- **`@work(thread=True)` for synchronous/blocking work** (apt, subprocess). Plain `@work` (async) is only for awaitable I/O. `@work` on a non-async function *without* `thread=True` raises `WorkerDeclarationError`.
- **Inside a thread worker, never touch widgets directly** — it is not thread-safe. Marshal updates with `self.call_from_thread(callable, *args)` or `post_message(...)`.
- The brain exposes install progress as an **iterator/generator of events** the worker consumes — that is the seam between blocking logic and the UI.
- Use `exclusive=True` + a consistent `group=` to cancel a superseded worker (e.g. re-triggered search/apply). `exclusive` only cancels within the same group.
- Cooperative cancel: long loops check `get_current_worker().is_cancelled()`.

---

## Component communication: messages bubble up

Children talk to parents via custom `Message` subclasses, not direct calls:

```python
from textual.message import Message

class InstallRow(Widget):
    class Selected(Message):
        def __init__(self, entry_id: str) -> None:
            self.entry_id = entry_id
            super().__init__()                          # modern Textual: NO sender arg
    def on_click(self) -> None:
        self.post_message(self.Selected(self.id))

# parent handler, auto-named on_<sender>_<message>:
def on_install_row_selected(self, event: InstallRow.Selected) -> None:
    event.stop()
    self._stage(event.entry_id)
```

`Message.__init__` takes **no** sender argument in modern Textual (the old `emit`/`Message(sender)` API is removed); read the originator via `event.control` or `self`.

---

## Interaction model: immediate ops + recorded manifest

Per `design-direction.md`, the UX is **immediate operations that auto-record an exportable manifest** (not a batch-only cart, not desired-state-file editing):

- The user installs/removes/upgrades an item; the action is staged into a **plan**, previewed (plan-by-default is the trust primitive — see `../core/idempotency-and-execution.md`), confirmed, then applied.
- Every applied action updates the manifest via `core/state.py`, so the same setup can be replayed on another machine.
- The TUI surfaces live `check()`-derived state per row (installed / available / upgradable), a plan-confirm step, a progress+log view during apply, and an installed view. State comes from the brain's live queries, not a cache the UI keeps.

---

## Testing: headless with Pilot

Textual testing is first-class and headless — TUI logic must be tested:

```python
import pytest
@pytest.mark.asyncio
async def test_stage_and_confirm():
    app = ManagerApp(fake_executor())
    async with app.run_test() as pilot:
        await pilot.press("i")
        await pilot.click("#install")
        await pilot.pause()                             # flush messages/refresh before asserting
        assert app.query_one("#status").renderable == "Planned"
```

- Drive via `Pilot` (`press`, `click`, `hover`, `pause`); always `await pilot.pause()` before asserting or tests flake (messages/refresh/worker results are async).
- Tests are `async` (`pytest.mark.asyncio` or `anyio`). Inject a fake/in-memory brain so UI tests don't shell out.
- Optional visual regression: `pytest-textual-snapshot`'s `snap_compare` fixture (SVG baselines; `pytest --snapshot-update` to accept).

---

## Anti-patterns (forbidden)

- Any `subprocess`/`sudo`/install logic inside `tui/`. Call `core/` from a worker instead.
- Running blocking work directly in an event handler or `compose()` (freezes the UI).
- Touching widgets from inside a `thread=True` worker without `call_from_thread`/`post_message`.
- `from textual.work import work` — the decorator is `from textual import work`.
- `@work` on a sync function without `thread=True` (raises `WorkerDeclarationError`).
- Treating a `reactive()` as the source of truth for domain state, or passing a sender to `Message.__init__`.
