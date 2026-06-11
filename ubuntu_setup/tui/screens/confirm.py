"""Plan-confirm modal — the trust primitive, rendered before anything runs.

A ``ModalScreen[bool]`` over the browse screen: it renders the plan (entry /
op / predicted state change) and dismisses ``True`` only on an explicit
confirm. The prediction labels come from the brain
(``service.predict_change``, derived from ``check()`` state — spec
idempotency): "would change" and "cannot fully simulate" stay distinct, and an
unknown state is never rendered as a confirmed change.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Mapping

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical
from textual.screen import ModalScreen
from textual.widgets import Static

from ...core.models import Action, Op, Plan
from ...core.service import predict_change

if TYPE_CHECKING:
    from ...core.service import ScanResult


class ConfirmScreen(ModalScreen[bool]):
    """Render the plan; ``y``/``enter`` applies, ``n``/``esc`` cancels."""

    BINDINGS = [
        Binding("y,enter", "confirm", "Apply"),
        Binding("n,escape", "decline", "Cancel"),
    ]

    def __init__(
        self,
        plan: Plan,
        results: "Mapping[str, ScanResult | None]",
    ) -> None:
        """``results`` is the browse screen's latest scan (id -> ScanResult or
        ``None`` while a check is in flight) — the ``check()`` states the
        prediction derives from."""
        super().__init__()
        self._plan = plan
        self._results = dict(results)

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-box"):
            yield Static(
                Text("Plan — confirm before applying"), id="confirm-title"
            )
            yield Static(Text("\n".join(self.plan_lines())), id="confirm-plan")
            yield Static(
                Text("y / enter  apply        n / esc  cancel"),
                id="confirm-hint",
            )

    def plan_lines(self) -> "list[str]":
        """The rendered plan: actions grouped by op, one prediction per entry."""
        if len(self._plan) == 0:
            return ["(nothing to do)"]
        by_op: "dict[Op, list[Action]]" = {}
        for action in self._plan:
            by_op.setdefault(action.op, []).append(action)
        lines: "list[str]" = []
        for op, actions in by_op.items():
            lines.append(f"{op.value.capitalize()}:")
            for action in actions:
                result = self._results.get(action.entry.id)
                state = None if result is None or result.error is not None else result.state
                _, label = predict_change(op, state)
                lines.append(f"  {action.entry.id:<24} {label}")
        return lines

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_decline(self) -> None:
        self.dismiss(False)
