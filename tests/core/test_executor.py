"""Executor tests — generator event stream, check-before-act, fail-fast,
dry-run, idempotent re-run, thread-bridge liveness, cancel/close contracts."""

from __future__ import annotations

import logging
import threading
import unittest
from types import SimpleNamespace
from unittest import mock

from ubuntu_setup.core import executor as executor_mod
from ubuntu_setup.core.errors import PreconditionError, ProviderError
from ubuntu_setup.core.events import (
    OutputLine,
    RunFinished,
    RunStarted,
    StepFinished,
    StepStarted,
)
from ubuntu_setup.core.executor import execute
from ubuntu_setup.core.models import Action, CatalogEntry, Op, Outcome, Plan
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.runner import RunResult
from tests._fakes import FakeRun, apt_install, register_provider, status_query

_LOG = logging.getLogger("test.executor")


def _entry(eid: str, type: str = "apt") -> CatalogEntry:
    return CatalogEntry(id=eid, description="x", type=type, fields={"package": eid})


def _plan(*ids: str, type: str = "apt") -> Plan:
    return Plan(actions=tuple(Action(entry=_entry(i, type), op=Op.INSTALL) for i in ids))


def _drain(gen) -> "tuple[list, int, list]":
    """Consume the event stream; return (results, exit_code, events)."""
    events = list(gen)
    fin = events[-1]
    assert isinstance(fin, RunFinished), f"stream must end with RunFinished, got {fin!r}"
    return list(fin.results), fin.exit_code, events


def _run(plan, run, *, check_mode=False):
    gen = execute(plan, priv=Privilege(run=run), logger=_LOG, run=run, check_mode=check_mode)
    results, code, _ = _drain(gen)
    return results, code


class _FakeProviderBase:
    """Scriptable provider for bridge/cancel tests (install overridden per test)."""

    type = "fake"

    def check(self, entry: CatalogEntry) -> State:
        return State.ABSENT

    def install(self, entry, ctx) -> None:  # pragma: no cover - overridden
        pass

    def remove(self, entry, ctx) -> None:
        raise NotImplementedError("fake")

    def upgrade(self, entry, ctx) -> None:
        raise NotImplementedError("fake")


class TestExecutor(unittest.TestCase):
    def test_absent_entry_is_installed_and_changed(self):
        run = FakeRun().when(status_query, returncode=1)  # absent; apt-get rc 0
        results, code = _run(_plan("ripgrep"), run)
        self.assertEqual(code, 0)
        self.assertEqual(results[0].outcome, Outcome.CHANGED)
        self.assertTrue(run.ran("apt-get install"))

    def test_present_entry_is_skipped_as_ok(self):
        run = FakeRun().when(status_query, returncode=0, stdout="install ok installed")
        results, code = _run(_plan("ripgrep"), run)
        self.assertEqual(code, 0)
        self.assertEqual(results[0].outcome, Outcome.OK)
        self.assertFalse(run.ran("apt-get install"))  # no mutation

    def test_fail_fast_stops_at_first_failure(self):
        run = (
            FakeRun()
            .when(status_query, returncode=1)              # both absent
            .when(apt_install, returncode=100, stderr="boom")
        )
        results, code = _run(_plan("first", "second"), run)
        self.assertEqual(code, 1)
        self.assertEqual(len(results), 1)                  # stopped after the failure
        self.assertEqual(results[0].entry_id, "first")
        self.assertEqual(results[0].outcome, Outcome.FAILED)

    def test_dry_run_predicts_change_without_mutating(self):
        run = FakeRun().when(status_query, returncode=1)   # absent
        results, code = _run(_plan("ripgrep"), run, check_mode=True)
        self.assertEqual(code, 0)
        self.assertEqual(results[0].outcome, Outcome.CHANGED)
        self.assertIn("would install", results[0].detail)
        self.assertFalse(run.ran("apt-get"))              # ZERO changes in dry-run

    def test_check_error_fails_fast(self):
        run = FakeRun().when(status_query, returncode=2, stderr="dpkg DB error")
        results, code = _run(_plan("ripgrep"), run)
        self.assertEqual(code, 1)
        self.assertEqual(results[0].outcome, Outcome.FAILED)
        self.assertFalse(run.ran("apt-get"))

    def test_second_run_is_a_skipped_no_op(self):
        """Run the same install twice; the second run must be a skipped no-op."""

        class StatefulFake(FakeRun):
            def __init__(self):
                super().__init__()
                self.installed = False

            def __call__(self, argv, *, sudo=False, **kw):
                a = list(argv)
                self.calls.append(SimpleNamespace(argv=a, sudo=sudo, kw=kw))
                if status_query(a):
                    out = "install ok installed" if self.installed else ""
                    return RunResult(a, 0 if self.installed else 1, out, "", 0.0)
                if apt_install(a):
                    self.installed = True
                    return RunResult(a, 0, "", "", 0.0)
                return RunResult(a, 0, "", "", 0.0)

        run = StatefulFake()
        r1, c1 = _run(_plan("ripgrep"), run)
        r2, c2 = _run(_plan("ripgrep"), run)
        self.assertEqual((c1, c2), (0, 0))
        self.assertEqual(r1[0].outcome, Outcome.CHANGED)
        self.assertEqual(r2[0].outcome, Outcome.OK)
        self.assertEqual(run.count(apt_install), 1)        # installed exactly once


class TestEventStream(unittest.TestCase):
    """The event vocabulary: shapes, ordering, skip-vs-fail visibility."""

    def test_sequence_distinguishes_skip_from_fail_fast(self):
        """skipped (detect-and-skip, run continues) vs failed (fail-fast, run
        stops) must be visible in the stream — and no step starts after a fail."""

        class Scripted(_FakeProviderBase):
            def install(self, entry, ctx) -> None:
                if entry.id == "skipme":
                    raise PreconditionError("tool unavailable", entry_id=entry.id)
                if entry.id == "failme":
                    raise ProviderError("boom", entry_id=entry.id)

        plan = _plan("skipme", "okme", "failme", "neverme", type="fake")
        with register_provider(Scripted()):
            gen = execute(plan, priv=Privilege(run=FakeRun()), logger=_LOG, run=FakeRun())
            results, code, events = _drain(gen)

        self.assertEqual(code, 1)
        self.assertEqual(
            [type(e).__name__ for e in events],
            [
                "RunStarted",
                "StepStarted", "StepFinished",   # skipme  -> skipped, continues
                "StepStarted", "StepFinished",   # okme    -> changed
                "StepStarted", "StepFinished",   # failme  -> failed, stops
                "RunFinished",                   # neverme never starts
            ],
        )
        run_started = events[0]
        self.assertIsInstance(run_started, RunStarted)
        self.assertEqual(run_started.total, 4)
        finished = [e for e in events if isinstance(e, StepFinished)]
        self.assertEqual(
            [f.result.outcome for f in finished],
            [Outcome.SKIPPED, Outcome.CHANGED, Outcome.FAILED],
        )
        self.assertEqual([(f.index, f.total) for f in finished], [(1, 4), (2, 4), (3, 4)])
        started = [e for e in events if isinstance(e, StepStarted)]
        self.assertEqual([s.entry_id for s in started], ["skipme", "okme", "failme"])
        self.assertEqual(started[0].op, Op.INSTALL)
        self.assertEqual([r.outcome for r in results],
                         [Outcome.SKIPPED, Outcome.CHANGED, Outcome.FAILED])

    def test_output_lines_are_live_not_buffered_after_the_call(self):
        """Interleaving: the consumer must receive emitted events BEFORE the
        provider call returns. A buffered-replay implementation (flush emits
        after install() returns) cannot pass: install blocks until the consumer
        confirms receipt, which only the live bridge makes possible."""
        proceed = threading.Event()
        saw_lines_mid_call: "list[bool]" = []

        class Live(_FakeProviderBase):
            def install(self, entry, ctx) -> None:
                ctx.emit(OutputLine(entry_id=entry.id, line="one"))
                ctx.emit(OutputLine(entry_id=entry.id, line="two"))
                # block inside the provider call until the CONSUMER saw both
                saw_lines_mid_call.append(proceed.wait(timeout=5.0))

        events = []
        with register_provider(Live()):
            gen = execute(_plan("live", type="fake"), priv=Privilege(run=FakeRun()),
                          logger=_LOG, run=FakeRun())
            lines = 0
            for event in gen:
                events.append(event)
                if isinstance(event, OutputLine):
                    lines += 1
                    if lines == 2:
                        proceed.set()

        self.assertEqual(saw_lines_mid_call, [True])  # received before install returned
        names = [type(e).__name__ for e in events]
        self.assertEqual(
            names,
            ["RunStarted", "StepStarted", "OutputLine", "OutputLine",
             "StepFinished", "RunFinished"],
        )
        self.assertEqual(events[-2].result.outcome, Outcome.CHANGED)


class TestCancelAndClose(unittest.TestCase):
    def test_cancel_between_steps_stops_run_and_reports(self):
        """cancel during step 1: step 1 finishes, step 2 never starts, the
        stream still terminates normally with RunFinished(cancelled, exit 3)."""
        cancel = threading.Event()
        run = FakeRun().when(status_query, returncode=1)  # absent; install ok
        gen = execute(_plan("one", "two"), priv=Privilege(run=run), logger=_LOG,
                      run=run, cancel=cancel)
        events = []
        for event in gen:
            events.append(event)
            if isinstance(event, StepFinished):
                cancel.set()  # cancel after the first step finished

        fin = events[-1]
        self.assertIsInstance(fin, RunFinished)
        self.assertTrue(fin.cancelled)
        self.assertEqual(fin.exit_code, 3)  # UserAbort semantics
        self.assertEqual(len(fin.results), 1)
        self.assertEqual(fin.results[0].entry_id, "one")
        started = [e for e in events if isinstance(e, StepStarted)]
        self.assertEqual([s.entry_id for s in started], ["one"])  # "two" never started

    def test_close_mid_step_unblocks_producer_and_joins_thread(self):
        """Abandoning the generator (close()) while the producer is blocked on
        the bounded queue must not deadlock or leak the bridge thread; the
        in-flight step runs to completion."""
        finished: "list[bool]" = []

        class Chatty(_FakeProviderBase):
            def install(self, entry, ctx) -> None:
                for i in range(20):  # far beyond the patched queue bound
                    ctx.emit(OutputLine(entry_id=entry.id, line=f"l{i}"))
                finished.append(True)

        threads_before = set(threading.enumerate())
        with register_provider(Chatty()):
            with mock.patch.object(executor_mod, "_EMIT_QUEUE_MAX", 2):
                gen = execute(_plan("chatty", type="fake"), priv=Privilege(run=FakeRun()),
                              logger=_LOG, run=FakeRun())
                for event in gen:
                    if isinstance(event, OutputLine):
                        break  # producer is now (or soon) blocked on the full queue
                gen.close()  # must drain to the sentinel, join the worker, return

        self.assertEqual(finished, [True])  # the step ran to completion
        self.assertEqual(set(threading.enumerate()), threads_before)  # no leak


if __name__ == "__main__":
    unittest.main()
