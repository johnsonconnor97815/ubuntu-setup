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
  an iterable event stream (see ``core/events.py``) plus ``cancel()`` — one
  consumer call that stops the run *and* kills the step in flight (through the
  :class:`runner.InFlightCommand` slot; sudo-aware, with an explicit degraded
  outcome when an escalated command cannot be signalled).
  Recording (``record_transaction`` + manifest save) happens when the stream
  finishes — including on cancel and on an abandoned/closed stream, so the
  audit history never misses a page. A dry run (``check_mode=True``) records
  nothing.

The sudo keep-alive lifecycle is owned here (spec privilege Rule 2): a real
apply (non-dry-run, non-empty plan) starts the :class:`SudoKeepalive` daemon
thread with its first event and stops it in the stream's ``finally`` — on
success, cancel, close, and crash alike. Dry runs and empty plans never touch
sudo.
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
from .privilege import Privilege, SudoKeepalive
from .providers import State, get_provider
from .runner import InFlightCommand, RunResult, TerminateOutcome


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
      with live per-command ``OutputLine``\\ s and provider ``emit`` payloads
      interleaved).
    - ``cancel()``: one consumer call terminates the run — no further step
      starts, and the command in flight is killed through the
      :class:`runner.InFlightCommand` slot (sudo-aware: an escalated child is
      killed via ``sudo -n kill``). The killed step finishes ``failed``, the
      stream still ends normally with ``RunFinished(cancelled=True,
      exit_code=3)``, and the transaction is recorded as usual. The return
      value keeps the degraded path visible: :attr:`TerminateOutcome.DEGRADED`
      means the escalated command could not be signalled (e.g. lapsed sudo
      credential) — the in-flight step runs to completion before the run
      stops ("cannot cancel; waiting for the current step"). ``IDLE`` means no
      command was in flight at that instant; a command started later in this
      run is killed on arrival, so the cancel still takes effect.
    - ``close()``: abandon the stream early; bridge threads are joined and the
      steps that already happened — including an in-flight step that runs to
      completion during the drain — are still recorded with their true outcome
      (audit never misses a page). ``close()`` deliberately does **not** kill
      anything: killing is explicit ``cancel()``'s semantics.
    """

    def __init__(
        self,
        events: Iterator[Event],
        cancel_event: threading.Event,
        terminate: "Callable[[], TerminateOutcome] | None" = None,
    ) -> None:
        self._events = events
        self._cancel = cancel_event
        self._terminate = terminate  # InFlightCommand.terminate — kills the current step

    def __iter__(self) -> Iterator[Event]:
        return self._events

    def cancel(self) -> TerminateOutcome:
        self._cancel.set()
        if self._terminate is None:
            return TerminateOutcome.IDLE
        return self._terminate()

    def close(self) -> None:
        self._events.close()  # type: ignore[attr-defined]  # generator close


def apply(
    prepared: PreparedRun,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None" = None,
    stream_run: "Callable[..., RunResult] | None" = None,
    check_mode: bool = False,
    keepalive: "SudoKeepalive | None" = None,
) -> ApplyHandle:
    """Run ``prepared.plan`` and record the transaction (unless ``check_mode``).

    ``stream_run`` is the streaming-runner seam for mutating ops (see
    :func:`executor.execute`); like ``run`` it defaults to the real runner,
    and to the injected ``run`` when only that is given (test fakes keep one
    seam).

    Privilege *acquisition* (``priv.ensure_sudo()``) deliberately stays with
    the caller: each surface owns *when* to prompt (the CLI before applying,
    the TUI via its own suspend/prompt flow). Keeping the acquired credential
    *alive* is owned here: a real apply starts a keep-alive thread for the
    duration of the event stream (``keepalive`` is the injection seam for
    tests; default ``priv.keepalive()``).
    """
    cancel_event = threading.Event()
    inflight = InFlightCommand()  # the cancel seam into the in-flight command
    events = _apply_events(
        prepared,
        priv=priv,
        logger=logger,
        run=run,
        stream_run=stream_run,
        check_mode=check_mode,
        cancel=cancel_event,
        inflight=inflight,
        keepalive=keepalive,
    )
    return ApplyHandle(events, cancel_event, terminate=inflight.terminate)


def _apply_events(
    prepared: PreparedRun,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None",
    stream_run: "Callable[..., RunResult] | None",
    check_mode: bool,
    cancel: threading.Event,
    inflight: InFlightCommand,
    keepalive: "SudoKeepalive | None",
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
    # sudo keep-alive for the duration of a real apply (Rule 2): dry runs and
    # empty plans never touch sudo
    ka: "SudoKeepalive | None" = None
    if not check_mode and len(prepared.plan) > 0:
        ka = keepalive if keepalive is not None else priv.keepalive()
        ka.start()
    gen = execute(
        prepared.plan,
        priv=priv,
        logger=logger,
        run=run,
        stream_run=stream_run,
        check_mode=check_mode,
        cancel=cancel,
        inflight=inflight,
        results_sink=results,
    )
    try:
        for event in gen:
            if isinstance(event, RunFinished):
                exit_code = event.exit_code
            yield event
    except GeneratorExit:
        raise  # abandoned stream: still record below (audit never misses a page)
    except (KeyboardInterrupt, UserAbort):
        # a user interrupt unwinding the stream (SIGINT reaching the consumer
        # thread inside the generator) is not an engine bug: the steps that
        # already happened really changed the system and are still recorded
        # (with the interrupted exit code) — audit never misses a page
        raise
    except BaseException:
        record = False  # unexpected raise (a bug) propagates; never a transaction
        raise
    finally:
        try:
            # joins the bridge worker; an in-flight step completes and its
            # outcome is appended to ``results`` (the sink) before close()
            # returns
            gen.close()
        finally:
            # only after the drain: the in-flight step may still escalate
            if ka is not None:
                ka.stop()
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
