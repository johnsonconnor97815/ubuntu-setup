"""The install flow: i -> plan-confirm modal -> probe-adaptive sudo -> progress.

Covers the prd decisions: decline applies nothing; a cached credential never
prompts; a missing credential prompts via the (headless-fallback) suspend path
exactly once; a failed prompt flashes the error and stays on browse.
"""

from __future__ import annotations

import unittest

from ubuntu_setup.core.models import Op, Plan
from ubuntu_setup.core.planner import build_plan
from ubuntu_setup.core.privilege import CredentialStatus
from ubuntu_setup.core.providers import State
from ubuntu_setup.core.service import ScanResult
from ubuntu_setup.tui.screens.browse import BrowseScreen
from ubuntu_setup.tui.screens.confirm import ConfirmScreen
from ubuntu_setup.tui.screens.progress import ProgressScreen

from tests.tui._fakes import (
    FakePriv,
    FakeService,
    make_app,
    make_catalog,
    wait_for,
)


def _scan_done(screen: BrowseScreen):
    return lambda: bool(screen._results) and all(
        v is not None for v in screen._results.values()
    )


class TestConfirmRendering(unittest.TestCase):
    """plan_lines is pure — unit-test the three prediction labels directly."""

    @staticmethod
    def _plan(catalog) -> Plan:
        return build_plan([{"id": "tree", "op": "install"}], catalog)

    def test_absent_entry_would_change(self):
        catalog = make_catalog("tree")
        results = {"tree": ScanResult(entry=catalog["tree"], state=State.ABSENT)}
        lines = ConfirmScreen(self._plan(catalog), results).plan_lines()
        self.assertIn("Install:", lines[0])
        self.assertIn("absent -> present (would change)", lines[1])

    def test_present_entry_is_no_change(self):
        catalog = make_catalog("tree")
        results = {"tree": ScanResult(entry=catalog["tree"], state=State.PRESENT)}
        lines = ConfirmScreen(self._plan(catalog), results).plan_lines()
        self.assertIn("already present (no change)", lines[1])

    def test_unknown_state_is_cannot_fully_simulate(self):
        # never render an unknown state as a confirmed change (spec idempotency)
        catalog = make_catalog("tree")
        lines = ConfirmScreen(self._plan(catalog), {}).plan_lines()
        self.assertIn("cannot fully simulate", lines[1])
        self.assertNotIn("would change", lines[1])


class TestInstallFlow(unittest.IsolatedAsyncioTestCase):
    async def test_decline_applies_nothing(self):
        svc = FakeService()
        app = make_app(svc=svc)
        async with app.run_test() as pilot:
            screen = app.screen
            await wait_for(pilot, _scan_done(screen), message="scan")
            await pilot.press("i")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ConfirmScreen),
                message="confirm modal",
            )
            await pilot.press("n")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, BrowseScreen),
                message="back on browse",
            )
            self.assertEqual(svc.apply_calls, [])
            self.assertEqual(app.priv.probe_calls, 0)  # declined before sudo

    async def test_confirm_with_cached_credential_never_prompts(self):
        svc = FakeService()
        priv = FakePriv(status=CredentialStatus.CACHED)
        app = make_app(svc=svc, priv=priv)
        async with app.run_test() as pilot:
            screen = app.screen
            await wait_for(pilot, _scan_done(screen), message="scan")
            await pilot.press("i")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ConfirmScreen),
                message="confirm modal",
            )
            await pilot.press("y")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ProgressScreen),
                message="progress screen",
            )
            await wait_for(pilot, lambda: len(svc.apply_calls) == 1, message="apply")
            self.assertEqual(priv.probe_calls, 1)
            self.assertEqual(priv.ensure_calls, 0)  # probe-adaptive: no prompt
            # the plan that is applied is the prepared one (tree only)
            plan = svc.apply_calls[0].plan
            self.assertEqual([a.entry.id for a in plan], ["tree"])
            self.assertEqual([a.op for a in plan], [Op.INSTALL])

    async def test_missing_credential_prompts_once_then_applies(self):
        svc = FakeService()
        priv = FakePriv(status=CredentialStatus.NONE)
        app = make_app(svc=svc, priv=priv)
        async with app.run_test() as pilot:
            await wait_for(pilot, _scan_done(app.screen), message="scan")
            await pilot.press("i")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ConfirmScreen),
                message="confirm modal",
            )
            await pilot.press("y")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ProgressScreen),
                message="progress screen",
            )
            # headless: suspend is unsupported, the fallback still validates
            self.assertEqual(priv.ensure_calls, 1)
            await wait_for(pilot, lambda: len(svc.apply_calls) == 1, message="apply")

    async def test_failed_sudo_flashes_error_and_stays_on_browse(self):
        svc = FakeService()
        priv = FakePriv(
            status=CredentialStatus.NONE,
            ensure_error="sudo is required but unavailable: `sudo -v` failed (exit 1).",
        )
        app = make_app(svc=svc, priv=priv)
        async with app.run_test() as pilot:
            await wait_for(pilot, _scan_done(app.screen), message="scan")
            await pilot.press("i")
            await wait_for(
                pilot,
                lambda: isinstance(app.screen, ConfirmScreen),
                message="confirm modal",
            )
            await pilot.press("y")
            await wait_for(
                pilot, lambda: app.last_error is not None, message="error flash"
            )
            self.assertIn("sudo", app.last_error)
            self.assertIsInstance(app.screen, BrowseScreen)  # never left browse
            self.assertTrue(app.is_running)  # the app did not exit
            self.assertEqual(svc.apply_calls, [])  # nothing was applied

    async def test_unknown_entry_flashes_error(self):
        svc = FakeService()
        app = make_app(svc=svc)
        async with app.run_test() as pilot:
            screen = app.screen
            await wait_for(pilot, _scan_done(screen), message="scan")
            screen._install_flow("no-such-id")  # direct dispatch: id not in catalog
            await wait_for(
                pilot, lambda: app.last_error is not None, message="error flash"
            )
            self.assertIn("cannot prepare install", app.last_error)
            self.assertIsInstance(app.screen, BrowseScreen)


if __name__ == "__main__":
    unittest.main()
