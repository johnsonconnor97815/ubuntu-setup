"""Facade (core/service.py) tests — scan error channel, prepare_* resolution,
apply recording (incl. dry-run no-record), and the cancel/close contracts."""

from __future__ import annotations

import json
import logging
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

from ubuntu_setup.core import executor as executor_mod
from ubuntu_setup.core import service
from ubuntu_setup.core.errors import CatalogError
from ubuntu_setup.core.events import OutputLine, RunFinished, StepFinished, StepStarted
from ubuntu_setup.core.models import Action, CatalogEntry, Manifest, Op, Plan
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.runner import TerminateOutcome
from tests._fakes import FakeKillableCommand, FakeRun, register_provider, status_query

_LOG = logging.getLogger("test.service")


def _entry(eid: str, **fields) -> CatalogEntry:
    return CatalogEntry(id=eid, description="x", type="apt",
                        fields={"package": eid, **fields})


def _gui_entry(eid: str) -> CatalogEntry:
    return CatalogEntry(id=eid, description="x", type="apt",
                        requires=("desktop",), fields={"package": eid})


def _catalog(*ids: str) -> "dict[str, CatalogEntry]":
    return {i: _entry(i) for i in ids}


def _plan(*ids: str) -> Plan:
    return Plan(actions=tuple(Action(entry=_entry(i), op=Op.INSTALL) for i in ids))


def _pkg_status(pkg: str):
    return lambda a: status_query(a) and pkg in a


class TestScan(unittest.TestCase):
    def test_streams_state_per_entry(self):
        run = (
            FakeRun()
            .when(_pkg_status("ripgrep"), returncode=0, stdout="install ok installed")
            .when(_pkg_status("tree"), returncode=1)  # absent
        )
        results = list(service.scan(_catalog("ripgrep", "tree"), run=run))
        by_id = {r.entry.id: r for r in results}
        self.assertEqual(by_id["ripgrep"].state, State.PRESENT)
        self.assertIsNone(by_id["ripgrep"].error)
        self.assertEqual(by_id["tree"].state, State.ABSENT)

    def test_bad_entry_uses_error_channel_and_scan_continues(self):
        """One bad entry (check raises) must not kill the scan."""
        catalog = {
            "broken": CatalogEntry(id="broken", description="x", type="apt",
                                   fields={}),  # missing 'package' -> CatalogError
            "dberr": _entry("dberr"),           # dpkg rc 2 -> ProviderError
            "good": _entry("good"),
        }
        run = (
            FakeRun()
            .when(_pkg_status("dberr"), returncode=2, stderr="dpkg DB error")
            .when(_pkg_status("good"), returncode=1)
        )
        results = list(service.scan(catalog, run=run))
        self.assertEqual(len(results), 3)  # nothing exploded
        by_id = {r.entry.id: r for r in results}
        self.assertIsNotNone(by_id["broken"].error)
        self.assertIsNone(by_id["broken"].state)
        self.assertIsNotNone(by_id["dberr"].error)
        self.assertEqual(by_id["good"].state, State.ABSENT)


class TestScanRequiresFilter(unittest.TestCase):
    """The browse data-source filter: entries with unmet `requires` are
    invisible — not yielded at all (the judgment lives in core, never the UI)."""

    def test_unmet_requires_entries_are_invisible(self):
        catalog = {"gimp": _gui_entry("gimp"), "tree": _entry("tree")}
        run = FakeRun().when(status_query, returncode=1)
        results = list(service.scan(catalog, run=run, capabilities=frozenset()))
        self.assertEqual([r.entry.id for r in results], ["tree"])

    def test_met_requires_entries_are_scanned(self):
        catalog = {"gimp": _gui_entry("gimp"), "tree": _entry("tree")}
        run = FakeRun().when(status_query, returncode=1)
        results = list(service.scan(catalog, run=run,
                                    capabilities=frozenset({"desktop"})))
        self.assertEqual([r.entry.id for r in results], ["gimp", "tree"])

    def test_detection_is_lazy_and_once(self):
        run = FakeRun().when(status_query, returncode=1)
        with mock.patch.object(service.environment, "detect_capabilities",
                               return_value=frozenset()) as detect:
            list(service.scan(_catalog("tree", "ripgrep"), run=run))
            detect.assert_not_called()  # a requires-free catalog never probes
            catalog = {"gimp": _gui_entry("gimp"), "inkscape": _gui_entry("inkscape")}
            results = list(service.scan(catalog, run=run))
            detect.assert_called_once()  # once per scan, not per entry
        self.assertEqual(results, [])


class TestFilterCatalog(unittest.TestCase):
    def test_filters_unmet_and_keeps_the_rest(self):
        catalog = {"gimp": _gui_entry("gimp"), "tree": _entry("tree")}
        self.assertEqual(
            list(service.filter_catalog(catalog, frozenset())), ["tree"])
        self.assertEqual(
            list(service.filter_catalog(catalog, frozenset({"desktop"}))),
            ["gimp", "tree"])


class TestPrepare(unittest.TestCase):
    def test_prepare_install_plans_one_action_and_records_desired(self):
        prepared = service.prepare_install("ripgrep", _catalog("ripgrep"),
                                           priv=Privilege(run=FakeRun()))
        self.assertEqual(len(prepared.plan), 1)
        self.assertEqual(prepared.plan.actions[0].entry.id, "ripgrep")
        self.assertEqual(prepared.plan.actions[0].op, Op.INSTALL)
        self.assertEqual(prepared.record_desired,
                         ({"id": "ripgrep", "op": "install"},))

    def test_prepare_install_unknown_id_is_catalog_error(self):
        with self.assertRaises(CatalogError):
            service.prepare_install("nope", _catalog("ripgrep"),
                                    priv=Privilege(run=FakeRun()))

    def test_prepare_apply_missing_file_is_catalog_error_and_creates_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            missing = Path(tmp) / "nope.json"
            with self.assertRaises(CatalogError):
                service.prepare_apply(missing, _catalog("ripgrep"))
            self.assertFalse(missing.exists())

    def test_prepare_apply_plans_from_manifest_desired(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "manifest.json"
            path.write_text(json.dumps({
                "version": 1,
                "desired": [{"id": "ripgrep", "op": "install"},
                            {"id": "tree", "op": "install"}],
                "history": [],
            }), encoding="utf-8")
            prepared = service.prepare_apply(path, _catalog("ripgrep", "tree"))
            self.assertEqual(len(prepared.plan), 2)
            self.assertEqual(prepared.record_desired, ())  # desired already in file


class _FakeKeepalive:
    """Duck-typed SudoKeepalive recording its lifecycle (the injection seam)."""

    def __init__(self):
        self.started = 0
        self.stopped = 0

    def start(self):
        self.started += 1

    def stop(self):
        self.stopped += 1


class TestApplyKeepalive(unittest.TestCase):
    """The keep-alive lifecycle is owned by the engine: started for a real
    apply, stopped in the stream's finally — incl. close and crash paths;
    dry runs and empty plans never start it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "manifest.json"

    def _apply(self, plan, run, ka, **kw) -> service.ApplyHandle:
        prepared = service.PreparedRun(plan=plan, manifest=Manifest(),
                                       manifest_path=self.path)
        return service.apply(prepared, priv=Privilege(run=run), logger=_LOG,
                             run=run, keepalive=ka, **kw)

    def test_real_apply_starts_then_stops_keepalive(self):
        ka = _FakeKeepalive()
        run = FakeRun().when(status_query, returncode=1)
        list(self._apply(_plan("ripgrep"), run, ka))
        self.assertEqual((ka.started, ka.stopped), (1, 1))

    def test_dry_run_never_starts_keepalive(self):
        ka = _FakeKeepalive()
        run = FakeRun().when(status_query, returncode=1)
        list(self._apply(_plan("ripgrep"), run, ka, check_mode=True))
        self.assertEqual((ka.started, ka.stopped), (0, 0))

    def test_empty_plan_never_starts_keepalive(self):
        ka = _FakeKeepalive()
        list(self._apply(Plan(actions=()), FakeRun(), ka))
        self.assertEqual((ka.started, ka.stopped), (0, 0))

    def test_keepalive_stops_on_crash_path(self):
        class Buggy:
            type = "fake-buggy"

            def check(self, entry):
                return State.ABSENT

            def install(self, entry, ctx):
                raise RuntimeError("bug, not a typed error")

        ka = _FakeKeepalive()
        entry = CatalogEntry(id="boom", description="x", type="fake-buggy", fields={})
        plan = Plan(actions=(Action(entry=entry, op=Op.INSTALL),))
        with register_provider(Buggy()):
            handle = self._apply(plan, FakeRun(), ka)
            with self.assertRaises(RuntimeError):
                list(handle)
        self.assertEqual((ka.started, ka.stopped), (1, 1))  # finally still ran

    def test_keepalive_stops_when_stream_is_closed(self):
        ka = _FakeKeepalive()
        run = FakeRun().when(status_query, returncode=1)
        handle = self._apply(_plan("one", "two"), run, ka)
        it = iter(handle)
        next(it)  # RunStarted: the generator (and the keep-alive) started
        self.assertEqual((ka.started, ka.stopped), (1, 0))
        handle.close()  # abandon: finally stops the keep-alive after the drain
        self.assertEqual((ka.started, ka.stopped), (1, 1))


class TestApply(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "manifest.json"

    def _prepared(self, plan: Plan, record_desired=()) -> service.PreparedRun:
        return service.PreparedRun(plan=plan, manifest=Manifest(),
                                   manifest_path=self.path,
                                   record_desired=tuple(record_desired))

    def _apply(self, prepared, run, **kw) -> service.ApplyHandle:
        return service.apply(prepared, priv=Privilege(run=run), logger=_LOG,
                             run=run, **kw)

    def test_apply_records_transaction_and_desired_upsert(self):
        run = FakeRun().when(status_query, returncode=1)  # absent; install ok
        prepared = self._prepared(_plan("ripgrep"),
                                   record_desired=({"id": "ripgrep", "op": "install"},))
        events = list(self._apply(prepared, run))
        fin = events[-1]
        self.assertIsInstance(fin, RunFinished)
        self.assertEqual(fin.exit_code, 0)

        data = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(data["desired"], [{"id": "ripgrep", "op": "install"}])
        self.assertEqual(len(data["history"]), 1)
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 0)
        self.assertEqual(tx["actions"],
                         [{"id": "ripgrep", "op": "install", "outcome": "changed"}])

    def test_dry_run_records_nothing(self):
        run = FakeRun().when(status_query, returncode=1)
        prepared = self._prepared(_plan("ripgrep"),
                                   record_desired=({"id": "ripgrep", "op": "install"},))
        events = list(self._apply(prepared, run, check_mode=True))
        self.assertEqual(events[-1].exit_code, 0)
        self.assertFalse(self.path.exists())   # no manifest write on a preview
        self.assertFalse(run.ran("apt-get"))   # and zero mutations

    def test_cancel_finishes_stream_and_records_partial_run(self):
        """cancel(): current step finishes, no further step starts, the stream
        ends with RunFinished(cancelled), and the audit history has the page."""
        run = FakeRun().when(status_query, returncode=1)
        prepared = self._prepared(_plan("one", "two"))
        handle = self._apply(prepared, run)
        events = []
        for event in handle:
            events.append(event)
            if isinstance(event, StepFinished):
                handle.cancel()

        fin = events[-1]
        self.assertIsInstance(fin, RunFinished)
        self.assertTrue(fin.cancelled)
        self.assertEqual(fin.exit_code, 3)
        started = [e for e in events if isinstance(e, StepStarted)]
        self.assertEqual([s.entry_id for s in started], ["one"])

        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 3)
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "changed"}])

    def _cancel_while_in_flight(self, cmd: FakeKillableCommand):
        """Drive an apply of ["one", "two"] and cancel() while step one's
        command is provably in flight (sync primitive, no sleeps)."""
        run = FakeRun().when(status_query, returncode=1)  # both absent
        prepared = self._prepared(_plan("one", "two"))
        handle = self._apply(prepared, run, stream_run=cmd.stream_run)
        outcomes: "list[TerminateOutcome]" = []

        def canceller():
            assert cmd.started.wait(timeout=10.0)
            outcomes.append(handle.cancel())
            if not cmd.was_killed:
                cmd.finish()  # degraded path: natural completion is the only way out

        t = threading.Thread(target=canceller)
        t.start()
        events = list(handle)
        t.join()
        return events, outcomes

    def test_cancel_kills_in_flight_step_and_records(self):
        """ApplyHandle.cancel() reaches the in-flight command's terminate
        handle: the command dies at once, the killed step is recorded failed,
        and the audit page carries exit 3 (cancelled, not fail-fast)."""
        cmd = FakeKillableCommand()
        events, outcomes = self._cancel_while_in_flight(cmd)

        self.assertEqual(outcomes, [TerminateOutcome.TERMINATED])
        self.assertTrue(cmd.was_killed)
        fin = events[-1]
        self.assertIsInstance(fin, RunFinished)
        self.assertTrue(fin.cancelled)
        self.assertEqual(fin.exit_code, 3)
        started = [e for e in events if isinstance(e, StepStarted)]
        self.assertEqual([s.entry_id for s in started], ["one"])  # "two" never starts

        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 3)
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "failed"}])

    def test_cancel_degraded_is_visible_and_waits_out_the_step(self):
        """The degraded path (escalated command not killable) is perceivable:
        cancel() returns DEGRADED, the step finishes with its true outcome,
        and the run still stops with exit 3."""
        cmd = FakeKillableCommand(degraded=True)
        events, outcomes = self._cancel_while_in_flight(cmd)

        self.assertEqual(outcomes, [TerminateOutcome.DEGRADED])
        self.assertFalse(cmd.was_killed)
        fin = events[-1]
        self.assertTrue(fin.cancelled)
        self.assertEqual(fin.exit_code, 3)

        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 3)
        # the step ran to completion: its TRUE outcome is on the page
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "changed"}])

    def test_close_still_records_audit_and_leaks_no_thread(self):
        """Abandoning the stream (close()) still records what happened so far —
        including the in-flight step, which runs to completion during the drain
        and really changed the system (audit never misses a page); a step that
        never started stays absent."""

        class InFlight:
            type = "fake-inflight"

            def __init__(self):
                self.done = threading.Event()

            def check(self, entry):
                return State.ABSENT

            def install(self, entry, ctx):
                for i in range(8):  # far beyond the patched queue bound
                    ctx.emit(OutputLine(entry_id=entry.id, line=f"l{i}"))
                self.done.set()

        provider = InFlight()
        one = CatalogEntry(id="one", description="x", type="fake-inflight", fields={})
        prepared = self._prepared(Plan(actions=(
            Action(entry=one, op=Op.INSTALL),
            Action(entry=_entry("two"), op=Op.INSTALL),
        )))
        threads_before = set(threading.enumerate())
        with register_provider(provider):
            with mock.patch.object(executor_mod, "_EMIT_QUEUE_MAX", 2):
                handle = self._apply(prepared, FakeRun())
                it = iter(handle)
                next(it)  # RunStarted
                self.assertIsInstance(next(it), StepStarted)
                self.assertIsInstance(next(it), OutputLine)
                # sync primitive: install() must push 8 emits through a queue
                # bounded at 2 while we stopped consuming, so it is provably
                # still blocked in flight at the moment close() is called
                self.assertFalse(provider.done.is_set())
                handle.close()  # abandon mid-step; the drain lets it finish

        self.assertTrue(provider.done.is_set())  # the step ran to completion
        self.assertEqual(set(threading.enumerate()), threads_before)  # joined
        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 3)  # interrupted before RunFinished
        # the in-flight step's true outcome is on the page; "two" never started
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "changed"}])

    def test_user_interrupt_through_the_stream_still_records(self):
        """KeyboardInterrupt unwinding the generator (SIGINT landing in the
        consumer thread inside the stream) is a user interrupt, not an engine
        bug: the steps that already happened are still recorded, with the
        interrupted exit code (3) — audit never misses a page."""

        class Interrupted:
            type = "fake-ki"

            def check(self, entry):
                return State.ABSENT

            def install(self, entry, ctx):
                if entry.id == "two":
                    raise KeyboardInterrupt

        one = CatalogEntry(id="one", description="x", type="fake-ki", fields={})
        two = CatalogEntry(id="two", description="x", type="fake-ki", fields={})
        prepared = self._prepared(Plan(actions=(
            Action(entry=one, op=Op.INSTALL),
            Action(entry=two, op=Op.INSTALL),
        )))
        threads_before = set(threading.enumerate())
        with register_provider(Interrupted()):
            handle = self._apply(prepared, FakeRun())
            with self.assertRaises(KeyboardInterrupt):
                list(handle)
        self.assertEqual(set(threading.enumerate()), threads_before)  # joined
        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 3)  # interrupted
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "changed"}])

    def test_unexpected_exception_propagates_and_records_nothing(self):
        """A non-typed exception (a bug) propagates unchanged — same as the old
        inline cli flow: no transaction page, the boundary reports the crash."""

        class Buggy:
            type = "fake"

            def check(self, entry):
                return State.ABSENT

            def install(self, entry, ctx):
                raise RuntimeError("bug, not a typed error")

        entry = CatalogEntry(id="boom", description="x", type="fake", fields={})
        prepared = self._prepared(Plan(actions=(Action(entry=entry, op=Op.INSTALL),)))
        threads_before = set(threading.enumerate())
        with register_provider(Buggy()):
            handle = self._apply(prepared, FakeRun())
            with self.assertRaises(RuntimeError):
                list(handle)
        self.assertEqual(set(threading.enumerate()), threads_before)  # joined
        self.assertFalse(self.path.exists())  # crash != transaction: nothing recorded

    def test_apply_records_explicit_skip_for_unmet_requires(self):
        """Replaying a manifest with a GUI entry on a no-desktop host: the
        entry is visibly skipped (event + audit page), never an error."""
        plan = Plan(actions=(
            Action(entry=_gui_entry("gimp"), op=Op.INSTALL),
            Action(entry=_entry("tree"), op=Op.INSTALL),
        ))
        run = FakeRun().when(status_query, returncode=1)  # tree absent
        prepared = self._prepared(plan)
        events = list(self._apply(prepared, run, capabilities=frozenset()))

        fin = events[-1]
        self.assertIsInstance(fin, RunFinished)
        self.assertEqual(fin.exit_code, 0)  # a skip is not a failure
        skips = [e for e in events
                 if isinstance(e, StepFinished) and e.result.entry_id == "gimp"]
        self.assertEqual(len(skips), 1)  # explicit StepFinished, not silence
        self.assertIn("desktop", skips[0].result.detail)
        data = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(data["history"][0]["actions"],
                         [{"id": "gimp", "op": "install", "outcome": "skipped"},
                          {"id": "tree", "op": "install", "outcome": "changed"}])

    def test_failed_run_records_exit_1(self):
        run = (
            FakeRun()
            .when(status_query, returncode=1)
            .when(lambda a: a[:2] == ["apt-get", "install"], returncode=100, stderr="boom")
        )
        prepared = self._prepared(_plan("one", "two"))
        events = list(self._apply(prepared, run))
        self.assertEqual(events[-1].exit_code, 1)  # fail-fast
        data = json.loads(self.path.read_text(encoding="utf-8"))
        tx = data["history"][0]
        self.assertEqual(tx["exit_code"], 1)
        self.assertEqual(tx["actions"],
                         [{"id": "one", "op": "install", "outcome": "failed"}])


if __name__ == "__main__":
    unittest.main()
