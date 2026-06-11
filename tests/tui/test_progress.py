"""Progress screen: batch-drain throttle (acceptance), cancel paths, summary,
and the return-to-browse rescan of affected entries."""

from __future__ import annotations

import unittest

from textual.widgets import Log, Static

from ubuntu_setup.core.runner import TerminateOutcome
from ubuntu_setup.tui.screens.browse import BrowseScreen
from ubuntu_setup.tui.screens.confirm import ConfirmScreen
from ubuntu_setup.tui.screens.progress import LOG_MAX_LINES, ProgressScreen

from tests.tui._fakes import (
    FakeApplyHandle,
    FakeService,
    cancelled_run_split,
    flood_events,
    make_app,
    ok_run_events,
    wait_for,
)


def _scan_done(screen):
    return lambda: bool(screen._results) and all(
        v is not None for v in screen._results.values()
    )


async def _drive_to_progress(app, pilot) -> ProgressScreen:
    """i -> confirm -> y; returns once the ProgressScreen is on top."""
    await wait_for(pilot, _scan_done(app.screen), message="scan")
    await pilot.press("i")
    await wait_for(
        pilot, lambda: isinstance(app.screen, ConfirmScreen), message="confirm"
    )
    await pilot.press("y")
    await wait_for(
        pilot, lambda: isinstance(app.screen, ProgressScreen), message="progress"
    )
    return app.screen


def _log_text(app) -> str:
    return "\n".join(app.screen.query_one(Log).lines)


class TestProgressHappyPath(unittest.IsolatedAsyncioTestCase):
    async def test_full_loop_renders_and_rescans_affected(self):
        handle = FakeApplyHandle(ok_run_events("tree"))
        svc = FakeService(handle=handle)
        app = make_app(svc=svc)
        async with app.run_test() as pilot:
            browse = app.screen
            screen = await _drive_to_progress(app, pilot)
            await wait_for(
                pilot, lambda: screen._finished is not None, message="run finished"
            )
            text = _log_text(app)
            self.assertIn("[1/1] install tree", text)
            self.assertIn("| Unpacking tree", text)
            self.assertIn("[+] tree install: changed", text)
            self.assertIn("run succeeded (exit 0; changed=1)", text)
            header = str(app.screen.query_one("#progress-header", Static).content)
            self.assertIn("finished", header)

            scans_before = len(svc.scan_calls)
            await pilot.press("enter")
            await wait_for(
                pilot, lambda: isinstance(app.screen, BrowseScreen), message="browse"
            )
            self.assertIs(app.screen, browse)
            # the affected entry (and only it) is re-checked on return
            await wait_for(
                pilot,
                lambda: len(svc.scan_calls) == scans_before + 1,
                message="rescan",
            )
            self.assertEqual(svc.scan_calls[-1], ("tree",))
            self.assertTrue(handle.closed)

    async def test_enter_does_nothing_while_running(self):
        handle = FakeApplyHandle(
            [], post=ok_run_events("tree"), blocking=True
        )
        app = make_app(svc=FakeService(handle=handle))
        async with app.run_test() as pilot:
            screen = await _drive_to_progress(app, pilot)
            await pilot.press("enter")  # still running: must be ignored
            await pilot.pause()
            self.assertIs(app.screen, screen)
            handle.finish()
            await wait_for(
                pilot, lambda: screen._finished is not None, message="finish"
            )
            await pilot.press("enter")
            await wait_for(
                pilot, lambda: isinstance(app.screen, BrowseScreen), message="browse"
            )


class TestProgressThrottle(unittest.IsolatedAsyncioTestCase):
    """Acceptance: a >=5k-line flood must be marshalled in batches, never
    per event (research: 25x throughput difference)."""

    async def test_flood_is_batch_marshalled(self):
        lines = 5000
        events = flood_events("tree", lines=lines)
        svc = FakeService(handle=FakeApplyHandle(events))
        app = make_app(svc=svc)
        async with app.run_test() as pilot:
            screen = await _drive_to_progress(app, pilot)
            await wait_for(
                pilot,
                lambda: screen._finished is not None,
                timeout=30.0,
                message="flood consumed",
            )
            total_events = len(events)
            self.assertGreaterEqual(screen.marshalled_batches, 1)
            # one marshal per batch, far fewer than one per event
            self.assertLess(screen.marshalled_batches, total_events / 10)
            # the explicit max_lines bound held (memory stays bounded)
            self.assertLessEqual(app.screen.query_one(Log).line_count, LOG_MAX_LINES)


class TestProgressCancel(unittest.IsolatedAsyncioTestCase):
    async def test_cancel_kills_step_and_summary_warns_half_configured(self):
        pre, post = cancelled_run_split("tree", killed=True)
        handle = FakeApplyHandle(pre, post, blocking=True)
        app = make_app(svc=FakeService(handle=handle))
        async with app.run_test() as pilot:
            screen = await _drive_to_progress(app, pilot)
            await wait_for(
                pilot, lambda: "Unpacking" in _log_text(app), message="step output"
            )
            await pilot.press("c")
            await wait_for(
                pilot, lambda: screen._finished is not None, message="cancelled end"
            )
            self.assertEqual(handle.cancel_calls, 1)
            text = _log_text(app)
            self.assertIn("cancel requested — killing the in-flight command", text)
            self.assertIn("run cancelled (exit 3", text)
            # the killed step warning + remedy (prd decision)
            self.assertIn("may be half-configured", text)
            self.assertIn("dpkg --configure -a", text)
            # a second c is a no-op
            await pilot.press("c")
            await pilot.pause()
            self.assertEqual(handle.cancel_calls, 1)

    async def test_degraded_cancel_stays_visible_and_waits_step_out(self):
        pre, post = cancelled_run_split("tree", killed=False)
        handle = FakeApplyHandle(
            pre, post, blocking=True, terminate_outcome=TerminateOutcome.DEGRADED
        )
        app = make_app(svc=FakeService(handle=handle))
        async with app.run_test() as pilot:
            screen = await _drive_to_progress(app, pilot)
            await wait_for(
                pilot, lambda: "Unpacking" in _log_text(app), message="step output"
            )
            await pilot.press("c")
            await wait_for(
                pilot,
                lambda: "cannot kill the escalated command" in _log_text(app),
                message="degraded notice",
            )
            self.assertIsNone(screen._finished)  # the step is being waited out
            header = str(app.screen.query_one("#progress-header", Static).content)
            self.assertIn("degraded", header)

            handle.finish()  # the in-flight step completes naturally
            await wait_for(
                pilot, lambda: screen._finished is not None, message="run end"
            )
            text = _log_text(app)
            self.assertIn("run cancelled (exit 3", text)
            # nothing was killed: no half-configured warning
            self.assertNotIn("dpkg --configure -a", text)


if __name__ == "__main__":
    unittest.main()
