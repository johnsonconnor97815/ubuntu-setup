"""TUI test doubles: a fake brain facade driven through the real ManagerApp.

The fake service mirrors the ``core.service`` call shapes exactly (``scan`` /
``prepare_install`` / ``apply``) but never shells out; the injected runner
seams raise on touch, so any TUI code path that tried to run a subprocess
fails the test loudly (the brain/face boundary, enforced).
"""

from __future__ import annotations

import logging
import threading
import time
from pathlib import Path
from typing import Mapping, Sequence

from ubuntu_setup.core.errors import CatalogError, PrivilegeError
from ubuntu_setup.core.events import (
    Event,
    OutputLine,
    RunFinished,
    RunStarted,
    StepFinished,
    StepStarted,
)
from ubuntu_setup.core.models import CatalogEntry, Manifest, Op, Outcome, StepResult
from ubuntu_setup.core.planner import build_plan
from ubuntu_setup.core.privilege import CredentialStatus, Privilege
from ubuntu_setup.core.providers import State
from ubuntu_setup.core.runner import TerminateOutcome
from ubuntu_setup.core.service import PreparedRun, ScanResult
from ubuntu_setup.tui.app import ManagerApp


def _forbidden_run(*args: object, **kwargs: object) -> None:
    raise AssertionError("the TUI tried to run a subprocess (brain/face violation)")


def make_catalog(*entry_ids: str) -> "dict[str, CatalogEntry]":
    return {
        eid: CatalogEntry(
            id=eid,
            description=f"the {eid} command-line tool",
            type="apt",
            tags=("cli",),
            source="official",
            fields={"package": eid},
        )
        for eid in entry_ids
    }


class FakePriv(Privilege):
    """Scripted credential strategy; the runner seam is never reachable."""

    def __init__(
        self,
        *,
        status: CredentialStatus = CredentialStatus.CACHED,
        ensure_error: "str | None" = None,
    ) -> None:
        super().__init__(run=_forbidden_run)
        self.status = status
        self.ensure_error = ensure_error
        self.probe_calls = 0
        self.ensure_calls = 0

    def probe_credentials(self) -> CredentialStatus:
        self.probe_calls += 1
        return self.status

    def ensure_sudo(self) -> None:
        self.ensure_calls += 1
        if self.ensure_error is not None:
            raise PrivilegeError(self.ensure_error)

    def ensure_sudo_noninteractive(self) -> None:  # pragma: no cover - unused
        pass


class FakeApplyHandle:
    """Scripted ApplyHandle: yields ``pre``, blocks on a gate when ``blocking``
    (a long in-flight step), then yields ``post``. ``cancel()`` releases the
    gate (mirroring the real kill) unless the outcome is DEGRADED — then only
    :meth:`finish` (natural completion) releases it."""

    def __init__(
        self,
        pre: Sequence[Event],
        post: Sequence[Event] = (),
        *,
        blocking: bool = False,
        terminate_outcome: TerminateOutcome = TerminateOutcome.TERMINATED,
    ) -> None:
        self._pre = list(pre)
        self._post = list(post)
        self._outcome = terminate_outcome
        self.release = threading.Event()
        if not blocking:
            self.release.set()
        self.cancel_calls = 0
        self.closed = False

    def __iter__(self):
        yield from self._pre
        assert self.release.wait(timeout=10.0), "fake apply was never released"
        yield from self._post

    def cancel(self) -> TerminateOutcome:
        self.cancel_calls += 1
        if self._outcome is not TerminateOutcome.DEGRADED:
            self.release.set()
        return self._outcome

    def finish(self) -> None:
        """Natural completion of the in-flight step (the degraded path's exit)."""
        self.release.set()

    def close(self) -> None:
        self.closed = True


class FakeService:
    """Stands in for the ``core.service`` facade — same shapes, zero subprocess."""

    def __init__(
        self,
        *,
        states: "Mapping[str, State] | None" = None,
        errors: "Mapping[str, Exception] | None" = None,
        handle: "FakeApplyHandle | None" = None,
    ) -> None:
        self.states = dict(states or {})
        self.errors = dict(errors or {})
        self.handle = handle if handle is not None else FakeApplyHandle(
            ok_run_events("tree")
        )
        self.scan_calls: "list[tuple[str, ...]]" = []
        self.prepare_calls: "list[str]" = []
        self.apply_calls: "list[PreparedRun]" = []

    def scan(self, catalog, *, run=None):
        self.scan_calls.append(tuple(catalog))
        for entry in catalog.values():
            if entry.id in self.errors:
                yield ScanResult(entry=entry, error=self.errors[entry.id])
            else:
                yield ScanResult(
                    entry=entry, state=self.states.get(entry.id, State.ABSENT)
                )

    def prepare_install(self, entry_id, catalog, *, priv) -> PreparedRun:
        self.prepare_calls.append(entry_id)
        if entry_id not in catalog:
            raise CatalogError(f"unknown id {entry_id!r}")
        desired = ({"id": entry_id, "op": Op.INSTALL.value},)
        return PreparedRun(
            plan=build_plan(desired, catalog),
            manifest=Manifest(),
            manifest_path=Path("/nonexistent/never-written/manifest.json"),
            record_desired=desired,
        )

    def apply(self, prepared, *, priv, logger, run=None, stream_run=None,
              check_mode=False, keepalive=None) -> FakeApplyHandle:
        self.apply_calls.append(prepared)
        return self.handle


# --------------------------------------------------------------------------- #
# scripted event streams
# --------------------------------------------------------------------------- #
def ok_run_events(entry_id: str, *, output_lines: int = 2) -> "list[Event]":
    result = StepResult(
        entry_id, Op.INSTALL, Outcome.CHANGED, "install (absent -> present)"
    )
    events: "list[Event]" = [
        RunStarted(total=1),
        StepStarted(index=1, total=1, entry_id=entry_id, op=Op.INSTALL),
    ]
    events.extend(
        OutputLine(entry_id=entry_id, line=f"Unpacking {entry_id} ({i}) ...")
        for i in range(output_lines)
    )
    events.append(StepFinished(index=1, total=1, result=result))
    events.append(RunFinished(results=(result,), exit_code=0))
    return events


def flood_events(entry_id: str, *, lines: int = 5000) -> "list[Event]":
    """A >=5k-line output flood (the throttle acceptance fixture)."""
    result = StepResult(
        entry_id, Op.INSTALL, Outcome.CHANGED, "install (absent -> present)"
    )
    events: "list[Event]" = [
        RunStarted(total=1),
        StepStarted(index=1, total=1, entry_id=entry_id, op=Op.INSTALL),
    ]
    events.extend(
        OutputLine(entry_id=entry_id, line=f"line {i} of streaming output ......")
        for i in range(lines)
    )
    events.append(StepFinished(index=1, total=1, result=result))
    events.append(RunFinished(results=(result,), exit_code=0))
    return events


def cancelled_run_split(entry_id: str, *, killed: bool) -> "tuple[list[Event], list[Event]]":
    """(pre, post) for a run cancelled mid-step. ``killed=True`` means the
    in-flight command died (step failed); ``False`` means it completed
    naturally first (the degraded path)."""
    pre: "list[Event]" = [
        RunStarted(total=1),
        StepStarted(index=1, total=1, entry_id=entry_id, op=Op.INSTALL),
        OutputLine(entry_id=entry_id, line="Unpacking ..."),
    ]
    if killed:
        result = StepResult(entry_id, Op.INSTALL, Outcome.FAILED, "terminated (rc -15)")
    else:
        result = StepResult(
            entry_id, Op.INSTALL, Outcome.CHANGED, "install (absent -> present)"
        )
    post: "list[Event]" = [
        StepFinished(index=1, total=1, result=result),
        RunFinished(results=(result,), exit_code=3, cancelled=True),
    ]
    return pre, post


# --------------------------------------------------------------------------- #
# app factory + async wait helper
# --------------------------------------------------------------------------- #
def make_app(
    *,
    catalog: "Mapping[str, CatalogEntry] | None" = None,
    svc: "FakeService | None" = None,
    priv: "FakePriv | None" = None,
) -> ManagerApp:
    return ManagerApp(
        catalog if catalog is not None else make_catalog("tree", "ripgrep"),
        priv=priv if priv is not None else FakePriv(),
        logger=logging.getLogger("test-tui"),
        svc=svc if svc is not None else FakeService(),
        run=_forbidden_run,
        stream_run=_forbidden_run,
    )


async def wait_for(pilot, predicate, *, timeout: float = 10.0, message: str = "condition") -> None:
    """Poll ``predicate`` between pilot pauses (thread workers finish async)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        await pilot.pause(0.05)
    raise AssertionError(f"timed out waiting for {message}")
