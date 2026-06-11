"""Progress screen: live step header + line log while a plan applies.

A thread worker consumes the brain's :class:`ApplyHandle` event stream with a
**mandatory batch drain** (research-verified: per-line ``call_from_thread``
marshals ~2.4k lines/s, 50-line batches ~60k — a 25x difference): a pump
thread moves events into a bounded queue, the worker takes *everything
available now* per pass, aggregates the ``OutputLine``\\ s into one
``Log.write_lines`` call, and marshals the whole batch with a **single**
``call_from_thread``. Never one marshal per event.

``c`` cancels: ``handle.cancel()`` kills the in-flight command (sudo-aware);
a ``DEGRADED`` outcome stays visible ("cannot kill ... waiting for the
current step"). After ``RunFinished``, ``enter`` dismisses back to browse
with the affected entry ids so their state is re-checked.
"""

from __future__ import annotations

import queue
import threading
from typing import TYPE_CHECKING, cast

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, Log, Static
from textual.worker import get_current_worker

from ...core.events import OutputLine, RunFinished, RunStarted, StepFinished, StepStarted
from ...core.models import Outcome
from ...core.runner import TerminateOutcome

if TYPE_CHECKING:
    from ...core.service import ApplyHandle, PreparedRun
    from ..app import ManagerApp

#: explicit Log bound — the widget's own default is None, i.e. unbounded
LOG_MAX_LINES = 5000
#: bound of the pump queue: preserves the engine's backpressure (a slow UI
#: blocks the producer instead of growing an unbounded buffer)
_PUMP_QUEUE_MAX = 1024

_DONE = object()  # pump sentinel: the event stream ended

_OUTCOME_GLYPH = {
    Outcome.CHANGED: "+",
    Outcome.OK: "=",
    Outcome.SKIPPED: "~",
    Outcome.FAILED: "x",
}


class ProgressScreen(Screen["tuple[str, ...]"]):
    """Apply ``prepared`` and stream its events; dismisses with the affected
    entry ids once the user returns to browse."""

    BINDINGS = [
        Binding("c", "cancel_run", "Cancel"),
        Binding("enter", "done", "Back to browse"),
    ]

    def __init__(self, prepared: "PreparedRun") -> None:
        super().__init__()
        self._prepared = prepared
        self._handle: "ApplyHandle | None" = None
        self._finished: "RunFinished | None" = None
        self._cancel_requested = False
        #: number of UI marshals performed (one per drained batch) — the
        #: observable the throttle acceptance test asserts on
        self.marshalled_batches = 0

    @property
    def manager(self) -> "ManagerApp":
        return cast("ManagerApp", self.app)

    def compose(self) -> ComposeResult:
        yield Static(Text("apply: starting ..."), id="progress-header")
        yield Log(max_lines=LOG_MAX_LINES, id="run-log")
        yield Footer()

    def on_mount(self) -> None:
        self._consume()

    # ------------------------------------------------------------- consuming
    @work(thread=True, exclusive=True, group="apply")
    def _consume(self) -> None:
        """Consume the apply event stream with the batch drain (see module doc)."""
        app = self.manager
        worker = get_current_worker()
        handle = app.svc.apply(
            self._prepared,
            priv=app.priv,
            logger=app.run_logger,
            run=app.run_seam,
            stream_run=app.stream_run_seam,
        )
        self._handle = handle
        q: "queue.Queue[object]" = queue.Queue(maxsize=_PUMP_QUEUE_MAX)

        def pump() -> None:
            # moves events from the (blocking) stream into the drain queue
            try:
                for event in handle:
                    q.put(event)
            finally:
                q.put(_DONE)

        pump_thread = threading.Thread(
            target=pump, name="ubuntu-setup-tui-pump", daemon=True
        )
        pump_thread.start()
        try:
            finished = False
            while not finished:
                if worker.is_cancelled and not self._cancel_requested:
                    # the app is shutting down mid-apply: kill the in-flight
                    # step so the stream (and this worker) ends promptly
                    self._cancel_requested = True
                    handle.cancel()
                try:
                    first = q.get(timeout=0.2)
                except queue.Empty:
                    continue
                batch: "list[object]" = [first]
                while True:  # take everything available NOW — one batch
                    try:
                        batch.append(q.get_nowait())
                    except queue.Empty:
                        break
                if batch[-1] is _DONE:
                    finished = True
                    batch.pop()
                if batch and not worker.is_cancelled:
                    # the single marshal per batch (mandatory throttle)
                    app.call_from_thread(self._render_batch, batch)
        finally:
            handle.close()  # joins the engine bridge; the audit page is recorded
            pump_thread.join()

    # ------------------------------------------------------------- rendering
    def _render_batch(self, batch: "list[object]") -> None:
        """UI-thread render of one drained batch: OutputLines aggregate into a
        single ``write_lines``; step/run events update the header inline."""
        self.marshalled_batches += 1
        log = self.query_one("#run-log", Log)
        lines: "list[str]" = []
        for event in batch:
            if isinstance(event, RunStarted):
                if event.total == 0:
                    lines.append("(nothing to do)")
            elif isinstance(event, StepStarted):
                self._set_header(
                    f"[{event.index}/{event.total}] {event.op.value} {event.entry_id} ..."
                )
                lines.append(
                    f"--- [{event.index}/{event.total}] {event.op.value} {event.entry_id} ---"
                )
            elif isinstance(event, OutputLine):
                glyph = "!" if event.stream == "stderr" else "|"
                lines.append(f"  {glyph} {event.line}")
            elif isinstance(event, StepFinished):
                r = event.result
                glyph = _OUTCOME_GLYPH.get(r.outcome, "?")
                lines.append(
                    f"[{glyph}] {r.entry_id} {r.op.value}: {r.outcome.value} — {r.detail}"
                )
            elif isinstance(event, RunFinished):
                self._finished = event
                lines.extend(self._summary_lines(event))
                self._set_header(self._summary_header(event))
            else:
                # provider ctx.emit payloads pass through the stream verbatim
                lines.append(f"  * {event!r}")
        if lines:
            log.write_lines(lines)

    def _set_header(self, text: str) -> None:
        self.query_one("#progress-header", Static).update(Text(text))

    @staticmethod
    def _summary_header(event: RunFinished) -> str:
        if event.cancelled:
            return "apply cancelled — press ENTER to return"
        if event.exit_code == 0:
            return "apply finished — press ENTER to return"
        return f"apply failed (exit {event.exit_code}) — press ENTER to return"

    @staticmethod
    def _summary_lines(event: RunFinished) -> "list[str]":
        counts: "dict[str, int]" = {}
        for r in event.results:
            counts[r.outcome.value] = counts.get(r.outcome.value, 0) + 1
        tally = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "none"
        if event.cancelled:
            status = "cancelled"
        elif event.exit_code == 0:
            status = "succeeded"
        else:
            status = "failed"
        lines = ["", f"run {status} (exit {event.exit_code}; {tally})"]
        if event.cancelled and any(r.outcome is Outcome.FAILED for r in event.results):
            # the in-flight step was killed mid-mutation (prd decision: make
            # the half-configured risk and its remedy explicit)
            lines.append(
                "the in-flight step was killed: the system may be half-configured;"
            )
            lines.append("consider running `sudo dpkg --configure -a`.")
        lines.append("press ENTER to return to the browse screen")
        return lines

    # --------------------------------------------------------------- actions
    def action_cancel_run(self) -> None:
        """``c``: kill the in-flight step through the brain's cancel seam."""
        if (
            self._handle is None
            or self._finished is not None
            or self._cancel_requested
        ):
            return
        self._cancel_requested = True
        log = self.query_one("#run-log", Log)
        outcome = self._handle.cancel()
        if outcome is TerminateOutcome.DEGRADED:
            # the escalated command cannot be signalled: the step is being
            # waited out — keep that visible (never silently swallowed)
            self._set_header("cancelling (degraded) — waiting for the current step ...")
            log.write_line(
                "cannot kill the escalated command; waiting for the current step to finish ..."
            )
        else:
            self._set_header("cancelling — killing the in-flight command ...")
            log.write_line("cancel requested — killing the in-flight command ...")

    def action_done(self) -> None:
        """``enter`` after the run finished: back to browse (rescan affected)."""
        if self._finished is None:
            return  # still running — enter does nothing
        self.dismiss(tuple(action.entry.id for action in self._prepared.plan))
