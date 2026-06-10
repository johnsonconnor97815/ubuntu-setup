"""Structured progress events the executor yields — the brain/UI progress seam.

The executor exposes a run as a *generator of these events* (the seam the spec
``.trellis/spec/tui/ui-guidelines.md`` requires: "the brain exposes install
progress as an iterator/generator of events"). Consumers (the CLI today, a TUI
worker later) render them; the brain never renders anything itself.

The ``Outcome`` carried by :class:`StepFinished` keeps the two kinds of
"didn't run" distinguishable right in the stream (see
``.trellis/spec/core/idempotency-and-execution.md``): ``skipped`` is
detect-and-skip (the run continues), ``failed`` is fail-fast (the run stops).

Provider ``ctx.emit`` payloads pass through the stream verbatim, so consumers
may also see provider-defined objects; :class:`OutputLine` is the predefined
type for live per-line output, produced by the executor's per-step ``ctx.run``
binding over the streaming runner (``runner.run_streaming``): each line a
provider's command prints arrives in the stream while the command runs.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Union

from .models import Op, StepResult


@dataclass(frozen=True)
class RunStarted:
    """The run begins; ``total`` is the number of planned steps."""

    total: int


@dataclass(frozen=True)
class StepStarted:
    """Work on one plan step begins (yielded before its ``check()``)."""

    index: int  # 1-based position in the plan
    total: int
    entry_id: str
    op: Op


@dataclass(frozen=True)
class OutputLine:
    """One live line of output from the step currently in progress."""

    entry_id: str
    line: str
    stream: str = "stdout"  # "stdout" | "stderr"


@dataclass(frozen=True)
class StepFinished:
    """One plan step ended; ``result.outcome`` is changed/ok/skipped/failed."""

    index: int
    total: int
    result: StepResult


@dataclass(frozen=True)
class RunFinished:
    """The run ended. Always the final event, even on fail-fast or cancel.

    ``exit_code`` follows the headless table (0 ok, 1 fail-fast, 3 cancelled,
    4 sudo credential lapsed mid-run — the "interactive escalation required"
    signal); ``cancelled`` is True when ``cancel()`` stopped the run before
    its last step.
    """

    results: "tuple[StepResult, ...]"
    exit_code: int
    cancelled: bool = False


#: everything the executor itself yields (provider ``emit`` payloads excluded)
Event = Union[RunStarted, StepStarted, OutputLine, StepFinished, RunFinished]
