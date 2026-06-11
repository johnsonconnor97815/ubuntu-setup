# TUI Guidelines (Textual)

> Coding conventions for `ubuntu_setup/tui/`: a Textual front-end that shows state and collects intent, and contains **no install/business logic**.

---

## Status: code-backed (the browse → confirm → progress loop)

`ubuntu_setup/tui/` exists: `app.py` (`ManagerApp`) + `screens/{browse,confirm,progress}.py`, entered by the bare `python -m ubuntu_setup` (the `textual` import is local to that CLI branch — headless runs never load it). Covered by the Pilot suite in `tests/tui/` (fake facade, no subprocess) plus boundary-guard tests. The snippets below show the real shapes. Verified against Textual 8.2.7 (requires Python ≥3.9); `textual>=8,<9` is pinned in `pyproject.toml` — read the CHANGELOG before a major bump (Textual ships frequent releases with occasional breaking changes, and snapshot baselines shift between majors). Not yet code-backed: the installed screen, remove/upgrade key bindings, reusable `widgets/` (deliberately deferred).

---

## The boundary: no business logic in the UI

The single most important rule (it is the other half of the brain/face split in `../core/directory-structure.md`):

> If a module imports `textual`, it must not contain install/business decisions. If a module contains install/business logic, it must not import `textual`.

The TUI only: composes widgets, holds **UI** state in `reactive()` attributes, dispatches messages, and drives **workers** that call the import-`textual`-free `core/` brain.

```python
# tui/app.py (the real shape)
from textual.app import App, SuspendNotSupported
from ubuntu_setup.core import runner, service         # brain facade: ZERO textual imports

class ManagerApp(App[None]):
    """Drives the core/service.py seams (scan / prepare_install / apply) from
    workers; renders state and collects intent, nothing more."""

    def __init__(self, catalog, *, priv, logger=None, svc=service,
                 run=None, stream_run=None) -> None:
        ...  # everything constructor-injected: Pilot tests swap in a fake facade
```

Dependency injection is the testing seam: `svc` defaults to the real `core.service` module, `run`/`stream_run` to the real runner — `tests/tui/_fakes.py` injects a `FakeService` plus runner seams that *raise on touch*, so any UI code path that tried to shell out fails loudly.

Putting install logic in an event handler or `compose()` blocks the event loop and freezes the UI. Handlers only dispatch to a worker; long work lives in `@work` methods that call `core/`.

---

## Structure: App / Screen / Widget

- **`App`** (`tui/app.py`, `ManagerApp`) owns the event loop and the screen stack; subclass `App[ReturnType]`.
- **`Screen`** = a full-window page on the stack (`tui/screens/`). Real screens: `browse.py` (two-pane list + detail, live badges, `/`-filter, `i` install), `confirm.py` (`ConfirmScreen(ModalScreen[bool])` — the plan preview), `progress.py` (`ProgressScreen(Screen[tuple[str, ...]])` — header + `Log`, dismisses with the affected entry ids so browse rescans them). The installed screen is a later task.
- `self.dismiss(value)` / `await app.push_screen_wait(screen)` to get a result back. **`push_screen_wait` is `async` and requires an active worker** — the install flow is therefore an *async* `@work` method (blocking brain calls wrapped in `asyncio.to_thread`); from a thread worker it is not directly reachable.
- **`Widget`** (`tui/widgets/`) = reusable UI elements. Add one only when actually reused — none exist yet.
- Declare the tree in `compose()` (`yield` children, or `with Container():` to nest). Keep `compose()` declarative — no business calls. Map keys via `BINDINGS` to `action_*` methods (note `/` binds as the key name `"slash"`).
- **`App.query_one` targets the *default* screen**, not the active pushed one — production code and tests must query via the active screen (`screen.query_one(...)`).

---

## State: `reactive()` for UI, plain objects for domain

- Hold **UI** state (selection, progress %, filter text) in `reactive()` class attributes; assignment auto-refreshes and fires `watch_<name>(old, new)` / `validate_<name>` / `compute_<name>`.
- Use `var(...)` for internal state that should **not** trigger a refresh.
- **Domain state stays in plain `core/` objects**, not in reactives. The TUI mirrors what the brain reports; it is not the source of truth.

---

## Long-running work: workers only

Installs are blocking subprocess work. They must run in a **worker** so the UI never freezes — and the event stream must be consumed with a **batch drain** (measured on 8.2.7, headless, 5000 lines: one `call_from_thread` per line ≈ 2,400 lines/s vs one per 50-line batch ≈ 60,000 lines/s — a 25× difference; the real screen marshals a 5k-line flood in ~5 batches). The real consumer (`screens/progress.py`):

```python
from textual import work                              # NOTE: top-level import, not textual.work
from textual.worker import get_current_worker

class ProgressScreen(Screen["tuple[str, ...]"]):
    @work(thread=True, exclusive=True, group="apply")  # thread=True for blocking work
    def _consume(self) -> None:
        app, worker = self.manager, get_current_worker()
        handle = app.svc.apply(self._prepared, priv=app.priv, logger=app.run_logger,
                               run=app.run_seam, stream_run=app.stream_run_seam)
        self._handle = handle                          # the `c` key calls handle.cancel()
        q: queue.Queue[object] = queue.Queue(maxsize=1024)   # bounded: keeps backpressure

        def pump() -> None:                            # stream -> queue (blocking iteration)
            try:
                for event in handle:
                    q.put(event)
            finally:
                q.put(_DONE)

        threading.Thread(target=pump, daemon=True).start()
        try:
            finished = False
            while not finished:
                if worker.is_cancelled and not self._cancel_requested:
                    self._cancel_requested = True
                    handle.cancel()                    # app exiting: kill the in-flight step
                try:
                    batch = [q.get(timeout=0.2)]
                except queue.Empty:
                    continue
                while True:                            # take everything available NOW
                    try:
                        batch.append(q.get_nowait())
                    except queue.Empty:
                        break
                if batch[-1] is _DONE:
                    finished = True
                    batch.pop()
                if batch and not worker.is_cancelled:
                    app.call_from_thread(self._render_batch, batch)   # ONE marshal per batch
        finally:
            handle.close()                             # joins the bridge + records the audit page
```

`_render_batch` runs on the UI thread: it aggregates the batch's `OutputLine`s into **one** `Log.write_lines(...)` call and applies step/run events to the header inline.

Rules (verified):

- **`@work(thread=True)` for synchronous/blocking work** (apt, subprocess). Plain `@work` (async) is only for awaitable I/O. `@work` on a non-async function *without* `thread=True` raises `WorkerDeclarationError`. The install *flow* (prepare → `push_screen_wait` confirm → sudo → push progress) is the async-worker exception: `push_screen_wait` is awaitable-only, so blocking brain calls go through `asyncio.to_thread`.
- **Inside a thread worker, never touch widgets directly** — it is not thread-safe. Marshal updates with `self.call_from_thread(callable, *args)` or `post_message(...)` — and **never one marshal per event**: drain everything currently available and marshal the batch (above). For the line log use `Log` (plain text, `write_lines`, **explicit `max_lines`** — the default is `None`, unbounded) rather than `RichLog`.
- The brain exposes install progress as an **iterator/generator of events** the worker consumes — that is the seam between blocking logic and the UI. The real interface is `service.apply(...) -> ApplyHandle` (iterable of `RunStarted … RunFinished` with live `OutputLine`s interleaved, plus `cancel()`).
- Use `exclusive=True` + a consistent `group=` to cancel a superseded worker (e.g. re-triggered scan/apply). `exclusive` only cancels within the same group (real groups: `"scan"`, `"flow"`, `"apply"`).
- Cooperative cancel: check `get_current_worker().is_cancelled` (a property), then call **`handle.cancel()` and keep consuming until `RunFinished`** — cancel kills the in-flight command (sudo-aware), so the stream ends promptly; a `TerminateOutcome.DEGRADED` return means the escalated command can't be signalled and the current step is being waited out (tell the user — the progress screen prints "cannot kill the escalated command; waiting for the current step to finish"). After a *killed* step, the end-of-run summary must surface the half-configured risk (`dpkg --configure -a` hint). Do **not** bare-`return` out of the loop to cancel: abandoning the generator (GeneratorExit) is *safe* — the engine drains the bridge, lets the in-flight step finish, and still records the audit page — but it **waits out** the in-flight step instead of killing it (killing is `cancel()`'s semantics), and your UI would stop rendering while apt keeps running.

---

## Sudo acquisition: probe first, suspend to prompt

Acquisition timing is the TUI's job (the engine only keeps an acquired credential alive — see `../core/privilege-and-safety.md` Rule 2). The real flow (`browse.py::_install_flow`, after the plan is confirmed and before apply):

```python
status = await asyncio.to_thread(app.priv.probe_credentials)   # silent, never prompts
if status is not CredentialStatus.CACHED:
    try:
        app.acquire_sudo_interactive()      # ON the loop thread — see below
    except PrivilegeError as exc:
        app.flash_error(str(exc))           # stay on browse; never exit the app
        return
```

`acquire_sudo_interactive` hands the terminal to `sudo -v` via `App.suspend()`:

```python
def acquire_sudo_interactive(self) -> None:
    try:
        with self.suspend():                # blocking the loop is the point:
            self.priv.ensure_sudo()         # the terminal belongs to sudo now
    except SuspendNotSupported:             # headless drivers (tests) can't suspend
        self.priv.ensure_sudo()
```

`suspend()` manipulates the driver and must run on the event-loop thread — fine from an async worker; from a thread worker it would need `call_from_thread` wrapping the *whole* `with` block.

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

- The user installs/removes/upgrades an item; the action is staged into a **plan**, previewed (plan-by-default is the trust primitive — see `../core/idempotency-and-execution.md`), confirmed, then applied. The confirm modal renders one prediction per action via `service.predict_change(op, state)` (derived from the browse scan's `check()` states): "would change" / "no change" / "cannot fully simulate" stay distinct — an unknown state is never rendered as a confirmed change. Deriving that label is brain logic; the UI only prints it.
- Every applied action updates the manifest via `core/state.py` (the engine records it when the apply stream finishes), so the same setup can be replayed on another machine.
- The TUI surfaces live `check()`-derived state per row (`✓` installed / `·` absent / `↑` upgradable / `⟳` checking / `!` check error), a plan-confirm step, a progress+log view during apply, and (later) an installed view. State comes from the brain's live queries, not a cache the UI keeps: after a run, browse rescans exactly the affected entry ids (the progress screen's dismiss value). This slice exposes only the `i` (install) binding; remove/upgrade state still displays.

---

## Testing: headless with Pilot

Textual testing is first-class and headless — TUI logic must be tested. The real suite (`tests/tui/`) is stdlib `unittest` (the project's runner), driven via `IsolatedAsyncioTestCase`:

```python
class TestInstallFlow(unittest.IsolatedAsyncioTestCase):
    async def test_confirm_with_cached_credential_never_prompts(self):
        app = make_app(svc=FakeService(), priv=FakePriv())   # fake facade, no subprocess
        async with app.run_test() as pilot:
            await wait_for(pilot, _scan_done(app.screen), message="scan")
            await pilot.press("i")
            await wait_for(pilot, lambda: isinstance(app.screen, ConfirmScreen),
                           message="confirm modal")
            await pilot.press("y")
            ...
```

- Drive via `Pilot` (`press`, `click`, `hover`, `pause`); thread-worker results land asynchronously, so poll a predicate between `pilot.pause(0.05)` calls (the `wait_for` helper in `tests/tui/_fakes.py`) instead of a single pause.
- Inject a fake/in-memory brain (`FakeService`/`FakePriv`/`FakeApplyHandle`) so UI tests never shell out; the injected runner seams *raise* if touched.
- The boundary itself is tested (`tests/tui/test_boundary.py`): a fresh subprocess imports every `ubuntu_setup.core` module and asserts `textual` is absent from `sys.modules`; the headless CLI path is guarded the same way; `tui/` sources are scanned for subprocess idioms.
- Throttle acceptance is objective: a ≥5k-line fake flood asserts `marshalled_batches` ≪ event count.
- Optional visual regression (when pytest is in the dev env): `pytest-textual-snapshot`'s `snap_compare` fixture (SVG baselines; `pytest --snapshot-update` to accept).

---

## Anti-patterns (forbidden)

- Any `subprocess`/`sudo`/install logic inside `tui/`. Call `core/` from a worker instead.
- Running blocking work directly in an event handler or `compose()` (freezes the UI).
- Touching widgets from inside a `thread=True` worker without `call_from_thread`/`post_message`.
- **One `call_from_thread` per stream event** (the 25× throughput trap) — drain a batch, marshal once, aggregate `OutputLine`s into one `write_lines`.
- A `Log` without an explicit `max_lines` (the default is unbounded — memory grows with apt output).
- `from textual.work import work` — the decorator is `from textual import work`.
- `@work` on a sync function without `thread=True` (raises `WorkerDeclarationError`).
- Calling `push_screen_wait` outside a worker, or `App.suspend()` off the event-loop thread.
- Letting a `sudo` password prompt fire while the TUI owns the terminal — probe first, then `suspend()` for the prompt.
- Treating a `reactive()` as the source of truth for domain state, or passing a sender to `Message.__init__`.
