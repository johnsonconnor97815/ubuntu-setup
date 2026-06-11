"""The Textual App — THE FACE's entry point.

``ManagerApp`` owns the screen stack (browse -> plan-confirm modal -> progress)
and the injected brain seams. It contains **zero** install logic and never
shells out: every decision and every command belongs to ``core/`` (the
brain/face split, non-negotiable #1 — see
``.trellis/spec/tui/ui-guidelines.md``). Dependencies are constructor-injected
so Pilot tests drive the whole UI against a fake facade without touching
apt/sudo.
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Mapping

from textual.app import App, SuspendNotSupported

from ..core import runner, service
from ..core.models import CatalogEntry
from ..core.privilege import Privilege
from ..core.runner import RunResult
from .screens.browse import BrowseScreen


class ManagerApp(App[None]):
    """Drives the ``core/service.py`` seams (scan / prepare_install / apply)
    from workers; renders state and collects intent, nothing more."""

    TITLE = "ubuntu-setup"

    CSS = """
    #browse-title, #progress-header {
        height: 1;
        padding: 0 1;
        background: $primary;
        color: $text;
        text-style: bold;
    }
    #filter { margin: 0 1; }
    #browse-body { height: 1fr; }
    #entry-list {
        width: 2fr;
        height: 100%;
        border: round $panel;
    }
    #detail {
        width: 3fr;
        height: 100%;
        border: round $panel;
        padding: 0 1;
    }
    ConfirmScreen {
        align: center middle;
    }
    #confirm-box {
        width: 80%;
        max-width: 100;
        height: auto;
        max-height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }
    #confirm-title { text-style: bold; }
    #confirm-hint { color: $text-muted; margin-top: 1; }
    #run-log { height: 1fr; border: round $panel; }
    """

    def __init__(
        self,
        catalog: Mapping[str, CatalogEntry],
        *,
        priv: Privilege,
        logger: "logging.Logger | None" = None,
        svc: Any = service,
        run: "Callable[..., RunResult] | None" = None,
        stream_run: "Callable[..., RunResult] | None" = None,
    ) -> None:
        """``svc`` is the brain facade (the ``core.service`` module by default;
        tests inject a fake with the same ``scan``/``prepare_install``/``apply``
        shape). ``run``/``stream_run`` default to the real runner seams, resolved
        late so test patches of ``core.runner`` still take effect."""
        super().__init__()
        self.catalog: dict[str, CatalogEntry] = dict(catalog)
        self.priv = priv
        self.run_logger = logger if logger is not None else logging.getLogger("ubuntu_setup")
        self.svc = svc
        self._run = run
        self._stream_run = stream_run
        #: the last brain error surfaced to the user (also shown via notify)
        self.last_error: "str | None" = None

    # -- injected seams (resolved late: patching core.runner still works) -----
    @property
    def run_seam(self) -> Callable[..., RunResult]:
        return self._run if self._run is not None else runner.run

    @property
    def stream_run_seam(self) -> Callable[..., RunResult]:
        return self._stream_run if self._stream_run is not None else runner.run_streaming

    def on_mount(self) -> None:
        self.push_screen(BrowseScreen())

    def flash_error(self, message: str) -> None:
        """Surface a brain error without leaving the app (toast + record)."""
        self.last_error = message
        self.notify(message, title="error", severity="error", timeout=8)

    def acquire_sudo_interactive(self) -> None:
        """Hand the terminal to ``sudo -v`` (spec privilege Rule 2 / research §2).

        Must run on the event-loop thread: blocking the loop is the point —
        the screen is suspended and the terminal belongs to sudo until the
        prompt resolves. Raises :class:`PrivilegeError` on failure (the caller
        stays on browse; the app never exits for a failed prompt). Headless
        drivers cannot suspend; there is no screen to corrupt there, so the
        validation simply runs directly.
        """
        try:
            with self.suspend():
                self.priv.ensure_sudo()
        except SuspendNotSupported:
            self.priv.ensure_sudo()
