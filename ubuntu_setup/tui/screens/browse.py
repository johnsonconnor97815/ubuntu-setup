"""Browse screen: two-pane catalog view with live ``check()``-derived state.

Left pane lists every catalog entry with a state badge; the right pane shows
the highlighted entry's details. State comes from the brain's live scan
(``service.scan`` consumed in a thread worker), never from a cache the UI
keeps. ``i`` starts the install flow: prepare -> modal plan-confirm ->
probe-adaptive sudo -> progress screen -> rescan the affected entries.
"""

from __future__ import annotations

import asyncio
from typing import TYPE_CHECKING, Iterable, cast

from rich.text import Text
from textual import work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal
from textual.screen import Screen
from textual.widgets import Footer, Input, OptionList, Static
from textual.widgets.option_list import Option, OptionDoesNotExist
from textual.worker import get_current_worker

from ...core.errors import PrivilegeError, UbuntuSetupError
from ...core.privilege import CredentialStatus
from ...core.providers import State
from ...core.service import ScanResult
from .confirm import ConfirmScreen
from .progress import ProgressScreen

if TYPE_CHECKING:
    from ..app import ManagerApp

#: state badges (prd decision): ✓ installed / · absent / ↑ upgradable
_STATE_BADGE = {
    State.PRESENT: "✓",
    State.ABSENT: "·",
    State.OUTDATED: "↑",
}
CHECKING_BADGE = "⟳"  #: scan in flight for this entry
ERROR_BADGE = "!"  #: this entry's check() raised


class BrowseScreen(Screen[None]):
    """Two-pane browse: entry list (left) + detail (right), live state badges."""

    BINDINGS = [
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("i", "install", "Install"),
        Binding("slash", "filter", "Filter"),
        Binding("escape", "clear_filter", "Clear filter", show=False),
        Binding("q", "quit_app", "Quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        #: entry id -> latest ScanResult; ``None`` value = check in flight
        self._results: "dict[str, ScanResult | None]" = {}
        self._filter = ""

    @property
    def manager(self) -> "ManagerApp":
        return cast("ManagerApp", self.app)

    # ----------------------------------------------------------------- layout
    def compose(self) -> ComposeResult:
        yield Static("ubuntu-setup — browse", id="browse-title")
        yield Input(
            placeholder="filter by id / type / tag / description (esc clears)",
            id="filter",
        )
        with Horizontal(id="browse-body"):
            yield OptionList(id="entry-list")
            yield Static(id="detail")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#filter", Input).display = False
        self._rebuild_list()
        self.query_one("#entry-list", OptionList).focus()
        self.rescan()

    # ------------------------------------------------------------------ scan
    def rescan(self, entry_ids: "Iterable[str] | None" = None) -> None:
        """Re-derive live state for ``entry_ids`` (default: whole catalog).

        Rows flip back to the checking badge immediately; the worker streams
        fresh results in. ``exclusive`` within the ``scan`` group: a new scan
        supersedes one still in flight.
        """
        app = self.manager
        targets = (
            tuple(app.catalog)
            if entry_ids is None
            else tuple(eid for eid in entry_ids if eid in app.catalog)
        )
        for eid in targets:
            self._results[eid] = None
        self._refresh_rows(targets)
        self._scan_worker(targets)

    @work(thread=True, exclusive=True, group="scan")
    def _scan_worker(self, entry_ids: "tuple[str, ...]") -> None:
        """Consume the brain's streaming scan; one marshal per arriving row."""
        app = self.manager
        worker = get_current_worker()
        subset = {eid: app.catalog[eid] for eid in entry_ids}
        for result in app.svc.scan(subset, run=app.run_seam):
            if worker.is_cancelled:
                return
            app.call_from_thread(self._apply_scan_result, result)

    def _apply_scan_result(self, result: ScanResult) -> None:
        self._results[result.entry.id] = result
        self._refresh_rows((result.entry.id,))

    # ------------------------------------------------------------- list/detail
    def _badge(self, entry_id: str) -> str:
        result = self._results.get(entry_id)
        if result is None:
            return CHECKING_BADGE
        if result.error is not None:
            return ERROR_BADGE
        return _STATE_BADGE.get(result.state, "?")  # type: ignore[arg-type]

    def _row_prompt(self, entry_id: str) -> Text:
        entry = self.manager.catalog[entry_id]
        return Text(f"{self._badge(entry_id)} {entry.id:<24} {entry.type}")

    def _visible_ids(self) -> "list[str]":
        needle = self._filter.lower()
        if not needle:
            return list(self.manager.catalog)
        return [
            eid
            for eid, entry in self.manager.catalog.items()
            if needle in eid.lower()
            or needle in entry.type.lower()
            or needle in entry.description.lower()
            or any(needle in tag.lower() for tag in entry.tags)
        ]

    def _rebuild_list(self) -> None:
        option_list = self.query_one("#entry-list", OptionList)
        keep = self._highlighted_id()
        visible = self._visible_ids()
        option_list.clear_options()
        option_list.add_options(
            [Option(self._row_prompt(eid), id=eid) for eid in visible]
        )
        if visible:
            try:
                option_list.highlighted = visible.index(keep)  # type: ignore[arg-type]
            except ValueError:
                option_list.highlighted = 0
        else:
            self._update_detail(None)

    def _refresh_rows(self, entry_ids: "tuple[str, ...]") -> None:
        option_list = self.query_one("#entry-list", OptionList)
        for eid in entry_ids:
            try:
                option_list.replace_option_prompt(eid, self._row_prompt(eid))
            except OptionDoesNotExist:
                continue  # currently filtered out
        current = self._highlighted_id()
        if current is not None and current in entry_ids:
            self._update_detail(current)

    def _highlighted_id(self) -> "str | None":
        option_list = self.query_one("#entry-list", OptionList)
        if option_list.highlighted is None:
            return None
        return option_list.get_option_at_index(option_list.highlighted).id

    def _update_detail(self, entry_id: "str | None") -> None:
        detail = self.query_one("#detail", Static)
        if entry_id is None:
            detail.update(Text("no matching entry"))
            return
        entry = self.manager.catalog[entry_id]
        result = self._results.get(entry_id)
        if result is None:
            state_line = f"{CHECKING_BADGE} checking ..."
        elif result.error is not None:
            state_line = f"{ERROR_BADGE} check failed: {result.error}"
        else:
            state_line = f"{self._badge(entry_id)} {result.state.value}"  # type: ignore[union-attr]
        detail.update(
            Text(
                "\n".join(
                    [
                        entry.id,
                        "",
                        f"type:       {entry.type}",
                        f"state:      {state_line}",
                        f"tags:       {', '.join(entry.tags) or '(none)'}",
                        f"source:     {entry.source}",
                        f"depends_on: {', '.join(entry.depends_on) or '(none)'}",
                        "",
                        entry.description,
                    ]
                )
            )
        )

    def on_option_list_option_highlighted(
        self, event: OptionList.OptionHighlighted
    ) -> None:
        event.stop()
        self._update_detail(event.option_id)

    # ---------------------------------------------------------------- filter
    def action_filter(self) -> None:
        box = self.query_one("#filter", Input)
        box.display = True
        box.focus()

    def action_clear_filter(self) -> None:
        box = self.query_one("#filter", Input)
        box.value = ""
        box.display = False
        self._filter = ""
        self._rebuild_list()
        self.query_one("#entry-list", OptionList).focus()

    def on_input_changed(self, event: Input.Changed) -> None:
        event.stop()
        self._filter = event.value.strip()
        self._rebuild_list()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        event.stop()  # keep the filter applied; hand focus back to the list
        self.query_one("#entry-list", OptionList).focus()

    # ------------------------------------------------------------ navigation
    def action_cursor_down(self) -> None:
        self.query_one("#entry-list", OptionList).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#entry-list", OptionList).action_cursor_up()

    def action_quit_app(self) -> None:
        self.app.exit()

    # ---------------------------------------------------------- install flow
    def action_install(self) -> None:
        entry_id = self._highlighted_id()
        if entry_id is not None:
            self._install_flow(entry_id)

    @work(exclusive=True, group="flow")
    async def _install_flow(self, entry_id: str) -> None:
        """prepare -> plan-confirm (modal) -> probe-adaptive sudo -> progress.

        An async worker: ``push_screen_wait`` needs a worker, and the suspend/
        sudo handover must run on the event-loop thread (research §2). The
        blocking brain calls go through ``asyncio.to_thread`` so the UI never
        freezes; any expected brain error flashes and stays on browse.
        """
        app = self.manager
        try:
            prepared = await asyncio.to_thread(
                app.svc.prepare_install, entry_id, app.catalog, priv=app.priv
            )
        except UbuntuSetupError as exc:
            app.flash_error(f"cannot prepare install: {exc}")
            return

        confirmed = await app.push_screen_wait(
            ConfirmScreen(prepared.plan, dict(self._results))
        )
        if not confirmed:
            return

        if len(prepared.plan) > 0:
            # probe-adaptive sudo (spec privilege Rule 2): silent probe first;
            # only a missing credential hands the terminal over for `sudo -v`.
            status = await asyncio.to_thread(app.priv.probe_credentials)
            if status is not CredentialStatus.CACHED:
                try:
                    app.acquire_sudo_interactive()
                except PrivilegeError as exc:
                    app.flash_error(str(exc))
                    return  # back on browse; the app keeps running

        affected = await app.push_screen_wait(ProgressScreen(prepared))
        self.rescan(affected)
