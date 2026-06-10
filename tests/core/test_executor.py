"""Executor tests — check-before-act, fail-fast, dry-run, idempotent re-run."""

from __future__ import annotations

import logging
import unittest
from types import SimpleNamespace

from ubuntu_setup.core.executor import execute
from ubuntu_setup.core.models import Action, CatalogEntry, Op, Outcome, Plan
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.runner import RunResult
from tests._fakes import FakeRun, apt_install, status_query

_LOG = logging.getLogger("test.executor")


def _entry(eid: str) -> CatalogEntry:
    return CatalogEntry(id=eid, description="x", type="apt", fields={"package": eid})


def _plan(*ids: str) -> Plan:
    return Plan(actions=tuple(Action(entry=_entry(i), op=Op.INSTALL) for i in ids))


def _run(plan, run, *, check_mode=False):
    return execute(plan, priv=Privilege(run=run), logger=_LOG, run=run, check_mode=check_mode)


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


if __name__ == "__main__":
    unittest.main()
