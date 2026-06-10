"""Core orchestration facade — the shared entry for the CLI and the future TUI.

One place owns the load -> plan -> apply -> record flow so neither surface
re-inlines it: the CLI consumes these seams headless today; a TUI worker calls
the very same functions later. Pure logic — this module (like all of ``core/``)
NEVER imports ``textual`` (non-negotiable #1, see
``.trellis/spec/core/directory-structure.md``).

Seams provided:

- :func:`scan` — full-status scan: stream every catalog entry's live
  ``check()`` state (the browse screen's first call).
- :func:`prepare_install` / :func:`prepare_apply` — resolve manifest + desired
  state into a :class:`PreparedRun` (plan + where/what to record).
- :func:`apply` — run a :class:`PreparedRun`; returns an :class:`ApplyHandle`:
  an iterable event stream (see ``core/events.py``) plus ``cancel()``.
  Recording (``record_transaction`` + manifest save) happens when the stream
  finishes — including on cancel and on an abandoned/closed stream, so the
  audit history never misses a page. A dry run (``check_mode=True``) records
  nothing.
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, Mapping

from . import state as state_mod
from .errors import CatalogError, UbuntuSetupError, UserAbort
from .events import Event, RunFinished
from .executor import execute
from .models import CatalogEntry, Manifest, Op, Plan, StepResult
from .planner import build_plan
from .privilege import Privilege
from .providers import State, get_provider
from .runner import RunResult


# --------------------------------------------------------------------------- #
# full-status scan (the browse-screen seam)
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class ScanResult:
    """One entry's live ``check()`` outcome: exactly one of ``state``/``error``.

    ``error`` is the per-entry error channel: ``check()`` may raise (e.g. a
    real dpkg DB error -> :class:`ProviderError`, a malformed entry ->
    :class:`CatalogError`); one bad entry must never kill the whole scan.
    """

    entry: CatalogEntry
    state: "State | None" = None
    error: "UbuntuSetupError | None" = None


def scan(
    catalog: Mapping[str, CatalogEntry],
    *,
    run: "Callable[..., RunResult] | None" = None,
) -> Iterator[ScanResult]:
    """Stream every entry's live state (a generator — consumers render rows as
    they arrive). Read-only: ``check()`` never mutates."""
    for entry in catalog.values():
        try:
            state = get_provider(entry.type, run=run).check(entry)
        except UbuntuSetupError as exc:
            yield ScanResult(entry=entry, error=exc)
        else:
            yield ScanResult(entry=entry, state=state)


# --------------------------------------------------------------------------- #
# prepare: resolve manifest + desired state into a plan
# --------------------------------------------------------------------------- #
@dataclass(frozen=True)
class PreparedRun:
    """Everything :func:`apply` needs: the plan plus where/what to record."""

    plan: Plan
    manifest: Manifest
    manifest_path: Path
    #: ``{"id", "op"}`` items upserted into ``manifest.desired`` when the
    #: transaction is recorded (ad-hoc ops update the user's intended end-state)
    record_desired: "tuple[Mapping[str, str], ...]" = ()


def prepare_install(
    entry_id: str,
    catalog: Mapping[str, CatalogEntry],
    *,
    priv: Privilege,
) -> PreparedRun:
    """Ad-hoc install of one catalog id, recorded into the user's state manifest.

    The state manifest may legitimately start empty on a fresh machine, so a
    missing file bootstraps an empty :class:`Manifest` here (unlike
    :func:`prepare_apply`). Raises :class:`CatalogError` for an unknown id.
    """
    manifest_path = state_mod.manifest_path(priv)
    manifest = state_mod.load_manifest(manifest_path)
    desired: "tuple[Mapping[str, str], ...]" = ({"id": entry_id, "op": Op.INSTALL.value},)
    return PreparedRun(
        plan=build_plan(desired, catalog),
        manifest=manifest,
        manifest_path=manifest_path,
        record_desired=desired,
    )


def prepare_apply(
    manifest_file: "Path | str",
    catalog: Mapping[str, CatalogEntry],
) -> PreparedRun:
    """Replay a user-supplied manifest's ``desired`` list.

    A missing path is :class:`CatalogError` (exit 2) — an explicit replay of a
    user-supplied file is never silently bootstrapped (a typo'd path must not
    "succeed" with zero actions; see the spec's manifest load behavior).
    """
    path = Path(manifest_file)
    if not path.exists():
        raise CatalogError(f"manifest not found: {path}")
    manifest = state_mod.load_manifest(path)
    return PreparedRun(
        plan=build_plan(manifest.desired, catalog),
        manifest=manifest,
        manifest_path=path,
    )


# --------------------------------------------------------------------------- #
# apply: event stream + cancel() + record
# --------------------------------------------------------------------------- #
class ApplyHandle:
    """The apply product: an iterable event stream plus a cancel seam.

    - Iterating yields the executor's events (``RunStarted`` ... ``RunFinished``,
      with provider ``emit`` payloads such as ``OutputLine`` interleaved live).
    - ``cancel()``: one consumer call terminates the run — no further step
      starts; the step in flight finishes (killing its command is the streaming
      runner's handle, a later commit point: ``_terminate`` is the injection
      seam) and the stream still ends normally with ``RunFinished(cancelled=
      True)``; the transaction is recorded as usual.
    - ``close()``: abandon the stream early; bridge threads are joined and the
      steps that already happened — including an in-flight step that runs to
      completion during the drain — are still recorded with their true outcome
      (audit never misses a page).
    """

    def __init__(
        self,
        events: Iterator[Event],
        cancel_event: threading.Event,
        terminate: "Callable[[], None] | None" = None,
    ) -> None:
        self._events = events
        self._cancel = cancel_event
        self._terminate = terminate  # commit point c: kill the in-flight command

    def __iter__(self) -> Iterator[Event]:
        return self._events

    def cancel(self) -> None:
        self._cancel.set()
        if self._terminate is not None:
            self._terminate()

    def close(self) -> None:
        self._events.close()  # type: ignore[attr-defined]  # generator close


def apply(
    prepared: PreparedRun,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None" = None,
    check_mode: bool = False,
) -> ApplyHandle:
    """Run ``prepared.plan`` and record the transaction (unless ``check_mode``).

    Privilege acquisition (``priv.ensure_sudo()``) deliberately stays with the
    caller: each surface owns *when* to prompt (the CLI before applying, the
    TUI via its own suspend/prompt flow).
    """
    cancel_event = threading.Event()
    events = _apply_events(
        prepared,
        priv=priv,
        logger=logger,
        run=run,
        check_mode=check_mode,
        cancel=cancel_event,
    )
    return ApplyHandle(events, cancel_event)


def _apply_events(
    prepared: PreparedRun,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None",
    check_mode: bool,
    cancel: threading.Event,
) -> Iterator[Event]:
    # the executor's out-of-band results channel: each StepResult is appended
    # the moment it forms, so the recording below sees every step that actually
    # ran — even one that completes while the stream is being closed/abandoned
    # (its StepFinished is never consumed; the sink is what keeps the audit
    # from missing a page)
    results: list[StepResult] = []
    # what we record when the consumer abandons the stream before RunFinished
    exit_code = UserAbort.exit_code
    record = not check_mode  # a dry run records nothing
    started_at = state_mod.now_iso()
    gen = execute(
        prepared.plan,
        priv=priv,
        logger=logger,
        run=run,
        check_mode=check_mode,
        cancel=cancel,
        results_sink=results,
    )
    try:
        for event in gen:
            if isinstance(event, RunFinished):
                exit_code = event.exit_code
            yield event
    except GeneratorExit:
        raise  # abandoned stream: still record below (audit never misses a page)
    except BaseException:
        record = False  # unexpected raise propagates; the boundary reports it
        raise
    finally:
        # joins the bridge worker; an in-flight step completes and its outcome
        # is appended to ``results`` (the sink) before close() returns
        gen.close()
        if record:
            manifest = prepared.manifest
            for item in prepared.record_desired:
                state_mod.update_desired(manifest, item["id"], item["op"])
            state_mod.record_transaction(
                manifest,
                run_id=state_mod.new_run_id(),
                started_at=started_at,
                exit_code=exit_code,
                results=results,
            )
            state_mod.save_manifest(prepared.manifest_path, manifest)
