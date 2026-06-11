"""Browse screen: live scan badges, two-pane detail linkage, filter, navigation.

All driven headless via Pilot against the fake facade — no subprocess, ever
(the injected runner seams raise on touch).
"""

from __future__ import annotations

import asyncio
import unittest

from textual.widgets import Input, OptionList, Static

from ubuntu_setup.core.errors import ProviderError
from ubuntu_setup.core.providers import State
from ubuntu_setup.tui.screens.browse import BrowseScreen

from tests.tui._fakes import FakeService, make_app, make_catalog, wait_for


def _scan_done(screen: BrowseScreen):
    return lambda: all(v is not None for v in screen._results.values()) and bool(
        screen._results
    )


def _prompt(app, entry_id: str) -> str:
    # NB: App.query_one targets the *default* screen, so query the active one
    option = app.screen.query_one(OptionList).get_option(entry_id)
    return str(option.prompt)


class TestBrowseScan(unittest.IsolatedAsyncioTestCase):
    async def test_scan_streams_state_badges_per_row(self):
        svc = FakeService(
            states={"tree": State.PRESENT, "ripgrep": State.ABSENT, "docker": State.OUTDATED},
            errors={"broken": ProviderError("dpkg database is locked")},
        )
        app = make_app(
            catalog=make_catalog("tree", "ripgrep", "docker", "broken"), svc=svc
        )
        async with app.run_test() as pilot:
            screen = app.screen
            assert isinstance(screen, BrowseScreen)
            await wait_for(pilot, _scan_done(screen), message="scan to finish")
            self.assertTrue(_prompt(app, "tree").startswith("✓"))
            self.assertTrue(_prompt(app, "ripgrep").startswith("·"))
            self.assertTrue(_prompt(app, "docker").startswith("↑"))
            self.assertTrue(_prompt(app, "broken").startswith("!"))
            # the scan went through the brain facade, whole catalog at once
            self.assertEqual(
                svc.scan_calls, [("tree", "ripgrep", "docker", "broken")]
            )

    async def test_detail_pane_follows_highlight(self):
        svc = FakeService(states={"tree": State.PRESENT, "ripgrep": State.ABSENT})
        app = make_app(svc=svc)
        async with app.run_test() as pilot:
            screen = app.screen
            assert isinstance(screen, BrowseScreen)
            await wait_for(pilot, _scan_done(screen), message="scan to finish")
            detail = app.screen.query_one("#detail", Static)
            self.assertIn("tree", str(detail.content))
            self.assertIn("present", str(detail.content))
            await pilot.press("j")  # vim-style down
            await pilot.pause()
            self.assertIn("ripgrep", str(detail.content))
            self.assertIn("absent", str(detail.content))
            await pilot.press("k")  # and back up
            await pilot.pause()
            self.assertIn("tree", str(detail.content))


class TestBrowseFilter(unittest.IsolatedAsyncioTestCase):
    async def test_slash_filters_and_escape_clears(self):
        app = make_app(svc=FakeService())
        async with app.run_test() as pilot:
            screen = app.screen
            assert isinstance(screen, BrowseScreen)
            await wait_for(pilot, _scan_done(screen), message="scan to finish")
            option_list = app.screen.query_one(OptionList)
            self.assertEqual(option_list.option_count, 2)

            await pilot.press("slash")
            await pilot.pause()
            self.assertTrue(app.screen.query_one("#filter", Input).has_focus)
            await pilot.press("r", "i", "p")
            await pilot.pause()
            self.assertEqual(option_list.option_count, 1)
            self.assertEqual(option_list.get_option_at_index(0).id, "ripgrep")

            await pilot.press("escape")  # clear + hide, focus back to the list
            await pilot.pause()
            self.assertEqual(option_list.option_count, 2)
            self.assertFalse(app.screen.query_one("#filter", Input).display)
            self.assertTrue(option_list.has_focus)

    async def test_enter_keeps_filter_and_refocuses_list(self):
        app = make_app(svc=FakeService())
        async with app.run_test() as pilot:
            screen = app.screen
            assert isinstance(screen, BrowseScreen)
            await wait_for(pilot, _scan_done(screen), message="scan to finish")
            await pilot.press("slash")
            await pilot.press("t", "r", "e", "e")
            await pilot.press("enter")
            await pilot.pause()
            option_list = app.screen.query_one(OptionList)
            self.assertEqual(option_list.option_count, 1)
            self.assertTrue(option_list.has_focus)


class TestBrowseQuit(unittest.IsolatedAsyncioTestCase):
    async def test_q_exits_the_app(self):
        app = make_app(svc=FakeService())
        async with app.run_test() as pilot:
            await pilot.press("q")
            for _ in range(200):  # the exit lands asynchronously
                if not app.is_running:
                    break
                await asyncio.sleep(0.05)
            self.assertFalse(app.is_running)


if __name__ == "__main__":
    unittest.main()
