"""Execute a :class:`Plan` as a generator of events: check-before-act,
fail-fast, dry-run aware, live per-step output.

For each action: yield :class:`StepStarted` -> ``check()`` -> skip if already
satisfied -> otherwise apply via the provider -> yield :class:`StepFinished`.
The failure policy is **fail-fast**: the first :class:`ProviderError` stops the
run (exit 1). A :class:`PreconditionError` is *not* a failure — the entry is
recorded ``skipped`` and the run continues (detect-and-skip). The stream always
terminates with :class:`RunFinished` (see ``core/events.py`` and
``.trellis/spec/core/idempotency-and-execution.md``).

Before every mutating op (never in ``check_mode``) the executor probes the sudo
credential (``priv.ensure_sudo_noninteractive()``, spec privilege Rule 2) so a
password prompt can never ambush the consumer mid-run: a lapsed credential is a
clean, recognizable termination — ``StepFinished(failed)`` then
``RunFinished(exit_code=4)`` (:class:`PrivilegeError` semantics), consistent
with fail-fast.

Plan mode (``check_mode=True``) is the dry-run mutation guard: every provider op
must make zero changes; the "would change" signal comes from comparing each
entry's ``check()`` state to the desired op (no parallel simulation path).

The thread bridge (sync generator x intra-step live events)
-----------------------------------------------------------
``provider.install(entry, ctx)`` is one blocking call, yet ``ctx.emit`` events
(e.g. :class:`OutputLine`) are produced *inside* it. A plain generator cannot
yield while blocked in that call, so each mutating op runs in a worker thread
whose ``ctx.emit`` puts into a **bounded** queue; the generator drains the
queue and yields each item live — never buffered until after the call returns.
The bound gives backpressure: a slow consumer blocks the producer instead of
growing an unbounded buffer. When the consumer abandons the generator
(``close()`` / GeneratorExit) the drain continues without yielding so the
producer can never block forever on a full queue, then the thread is joined —
no leak. In that case the in-flight step runs to completion and its true
outcome is still pushed into the caller's ``results_sink`` (no ``StepFinished``
can be yielded anymore — the out-of-band channel is what keeps the audit from
missing a page).

Live output and the kill seam
-----------------------------
For each mutating op the executor binds ``ctx.run`` to the **streaming** runner
(:func:`runner.run_streaming`): every output line of the provider's commands
becomes a live :class:`OutputLine` event in the bridge queue, and the running
command's terminate handle is published into an
:class:`runner.InFlightCommand` slot. ``ApplyHandle.cancel()`` terminates the
current step through that slot (sudo-aware: an escalated child is killed via
``sudo -n kill``; a failed privileged kill degrades to "wait the step out" —
see ``core/runner.py``). A step whose command was killed fails with rc != 0
(``StepFinished(failed)``), but under a cancel request the run terminates with
``RunFinished(cancelled=True, exit_code=3)`` — a genuine failure *before* the
cancel keeps exit 1 (fail-fast). ``close()`` keeps the abandon semantics
above: the in-flight step is waited out, never killed — killing is explicit
``cancel()``'s job. The provider protocol is untouched: ``check()`` keeps the
plain capturing runner, and providers keep calling ``ctx.run(argv, sudo=...)``.
"""

from __future__ import annotations

import logging
import queue
import threading
from typing import Any, Callable, Iterator

from . import runner as runner_mod
from .errors import PreconditionError, PrivilegeError, ProviderError, UserAbort
from .events import Event, OutputLine, RunFinished, RunStarted, StepFinished, StepStarted
from .models import CatalogEntry, Op, Outcome, Plan, StepResult
from .privilege import Privilege
from .providers import Ctx, State, get_provider
from .runner import RunResult
from .runner import run as default_run

# which observed states already satisfy a desired op (-> skip as a no-op)
_SATISFIED: dict[Op, set[State]] = {
    Op.INSTALL: {State.PRESENT, State.OUTDATED},
    Op.UPGRADE: {State.PRESENT},
    Op.REMOVE: {State.ABSENT},
}
# the state an op converges toward (for the predicted-change label)
_TARGET: dict[Op, State] = {
    Op.INSTALL: State.PRESENT,
    Op.UPGRADE: State.PRESENT,
    Op.REMOVE: State.ABSENT,
}

#: bound of the per-step emit queue (backpressure — never an unbounded buffer)
_EMIT_QUEUE_MAX = 64


def predict_change(op: Op, state: "State | None") -> "tuple[bool | None, str]":
    """The plan-preview signal for one action, derived from its ``check()``
    state (spec idempotency: prediction comes from ``check()`` — no parallel
    simulation path). Returns ``(would_change, label)``.

    ``would_change`` is ``None`` when ``state`` is unknown (a failed or not yet
    run ``check()``): the consumer must render that as "cannot fully simulate",
    never as a confirmed change *or* a confirmed no-op (the Ansible check-mode
    pitfall). This is presentation-feeding brain logic — it lives here so the
    TUI/CLI never re-derive op-vs-state semantics themselves.
    """
    if state is None:
        return None, "state unknown (cannot fully simulate)"
    if state in _SATISFIED.get(op, set()):
        return False, f"already {state.value} (no change)"
    return True, f"{state.value} -> {_TARGET[op].value} (would change)"


class _StepDone:
    """Worker-thread sentinel: the provider op returned (``exc is None``) or
    raised ``exc`` (marshalled to the generator thread)."""

    __slots__ = ("exc",)

    def __init__(self, exc: "BaseException | None") -> None:
        self.exc = exc


def _bridge(
    method: Callable[..., None],
    entry: Any,
    ctx: Ctx,
    q: "queue.Queue[Any]",
) -> None:
    """Worker-thread body: run the provider op, then post the sentinel last."""
    try:
        method(entry, ctx)
    except BaseException as exc:  # marshalled, re-raised/mapped by the generator
        q.put(_StepDone(exc))
    else:
        q.put(_StepDone(None))


def _step_run(
    stream_run: "Callable[..., RunResult]",
    inflight: "runner_mod.InFlightCommand",
    entry_id: str,
    emit: "Callable[[Any], None]",
) -> "Callable[..., RunResult]":
    """Bind ``ctx.run`` for one mutating step: stream by default, forwarding
    each output line as a live :class:`OutputLine` event into the bridge
    queue, and publishing the running command's terminate handle so
    ``cancel()`` can kill the current step. Providers keep calling
    ``ctx.run(argv, sudo=...)`` unchanged (zero protocol intrusion); the
    ``check()`` path keeps the plain capturing runner."""

    def step_run(argv, *, sudo=False, on_line=None, on_start=None, **kw) -> RunResult:
        def forward(line: str, stream: str) -> None:
            emit(OutputLine(entry_id=entry_id, line=line, stream=stream))
            if on_line is not None:
                on_line(line, stream)

        def started(handle) -> None:
            inflight.publish(handle)
            if on_start is not None:
                on_start(handle)

        try:
            return stream_run(argv, sudo=sudo, on_line=forward, on_start=started, **kw)
        finally:
            inflight.clear()

    return step_run


def _completed_result(
    entry: CatalogEntry,
    op: Op,
    exc: "BaseException | None",
    change: str,
    check_mode: bool,
) -> "StepResult | None":
    """Map a completed provider op (returned or raised ``exc``) to its true
    :class:`StepResult` — the ONE outcome mapping, shared by the normal path
    and the abandoned-stream drain. Returns ``None`` for an unexpected
    exception: a bug propagates unchanged and never becomes a transaction line.
    """
    if exc is None:
        verb = f"would {op.value}" if check_mode else op.value
        return StepResult(entry.id, op, Outcome.CHANGED, f"{verb} ({change})")
    if isinstance(exc, PreconditionError):
        return StepResult(entry.id, op, Outcome.SKIPPED, str(exc))
    if isinstance(exc, ProviderError):
        return StepResult(entry.id, op, Outcome.FAILED, str(exc))
    if isinstance(exc, NotImplementedError):
        msg = f"op {op.value!r} not implemented for type {entry.type!r}: {exc}"
        return StepResult(entry.id, op, Outcome.FAILED, msg)
    return None


def execute(
    plan: Plan,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None" = None,
    stream_run: "Callable[..., RunResult] | None" = None,
    check_mode: bool = False,
    cancel: "threading.Event | None" = None,
    results_sink: "list[StepResult] | None" = None,
    inflight: "runner_mod.InFlightCommand | None" = None,
) -> Iterator[Event]:
    """Run ``plan``, yielding events; the final event is :class:`RunFinished`.

    ``cancel`` (a ``threading.Event``) is the cooperative stop signal: once
    set, no further step starts and the stream terminates with
    ``RunFinished(cancelled=True, exit_code=3)``. Killing the step already in
    flight is ``inflight``'s job (see below): a killed command fails its step
    (``StepFinished(failed)``) but keeps cancelled semantics (exit 3); without
    a kill — or on the degraded path — the in-flight step finishes normally
    first. A genuine failure *before* the cancel keeps exit 1 (fail-fast).
    Provider ``ctx.emit`` payloads and each command's :class:`OutputLine`\\ s
    are yielded live, interleaved between the step's ``StepStarted`` and
    ``StepFinished`` (see the bridge note above).

    ``stream_run`` is the streaming-runner seam bound into ``ctx.run`` for
    mutating ops. It defaults to the injected ``run`` when one is given (so
    test fakes keep the single ``run=`` seam — extra ``on_line``/``on_start``
    kwargs are simply ignored by fakes that don't stream), else to
    :func:`runner.run_streaming`.

    ``inflight`` is the :class:`runner.InFlightCommand` slot through which the
    consumer's ``cancel()`` reaches the current command's terminate handle;
    the facade owns it (``service.apply``) and wires it to ``ApplyHandle``.

    ``results_sink`` is the out-of-band results channel: when given, every
    step's :class:`StepResult` is appended to it the moment it forms — so a
    caller recording the transaction still sees a step that ran to completion
    while the stream was being closed/abandoned (no ``StepFinished`` can be
    yielded then). On a fully consumed stream the sink's content equals
    ``RunFinished.results``.
    """
    if stream_run is None:
        stream_run = run if run is not None else runner_mod.run_streaming
    run = run or default_run
    inflight = inflight if inflight is not None else runner_mod.InFlightCommand()
    cancel = cancel if cancel is not None else threading.Event()
    total = len(plan)
    results: list[StepResult] = results_sink if results_sink is not None else []
    exit_code = 0
    cancelled = False

    yield RunStarted(total=total)

    for index, action in enumerate(plan.actions, start=1):
        if cancel.is_set():
            cancelled = True
            exit_code = UserAbort.exit_code
            logger.warning("cancelled before step %d/%d", index, total)
            break

        entry = action.entry
        op = action.op
        provider = get_provider(entry.type, run=run)
        yield StepStarted(index=index, total=total, entry_id=entry.id, op=op)

        # check() reads live state; a real check error (not "absent") fails fast
        try:
            state = provider.check(entry)
        except ProviderError as exc:
            result = StepResult(entry.id, op, Outcome.FAILED, str(exc))
            results.append(result)
            logger.error("check failed for %s: %s", entry.id, exc)
            exit_code = 1
            yield StepFinished(index=index, total=total, result=result)
            break

        if state in _SATISFIED.get(op, set()):
            result = StepResult(entry.id, op, Outcome.OK, f"already {state.value}")
            results.append(result)
            logger.info("ok: %s already %s", entry.id, state.value)
            yield StepFinished(index=index, total=total, result=result)
            continue

        # probe before each privileged step (privilege-and-safety Rule 2): a
        # lapsed credential fails the run cleanly (exit 4) instead of letting a
        # password prompt ambush the consumer. Satisfied steps above never
        # probe; a dry run never touches sudo at all.
        if not check_mode:
            try:
                priv.ensure_sudo_noninteractive()
            except PrivilegeError as exc:
                result = StepResult(entry.id, op, Outcome.FAILED, str(exc))
                results.append(result)
                logger.error("credential lapsed before %s: %s", entry.id, exc)
                exit_code = PrivilegeError.exit_code
                yield StepFinished(index=index, total=total, result=result)
                break

        change = f"{state.value} -> {_TARGET[op].value}"

        # thread bridge: the op blocks in a worker; we drain its emits live.
        # ctx.run is the streaming binding: command output -> OutputLine events,
        # the running command's terminate handle -> the inflight slot (cancel).
        q: "queue.Queue[Any]" = queue.Queue(maxsize=_EMIT_QUEUE_MAX)
        ctx = Ctx(run=_step_run(stream_run, inflight, entry.id, q.put),
                  priv=priv, log=logger, check_mode=check_mode, emit=q.put)
        method = getattr(provider, op.value)
        worker = threading.Thread(
            target=_bridge,
            args=(method, entry, ctx, q),
            name=f"ubuntu-setup-step-{entry.id}",
            daemon=True,
        )
        worker.start()
        done: "_StepDone | None" = None
        abandoned = True  # cleared when the drain loop completes normally
        try:
            while done is None:
                item = q.get()
                if isinstance(item, _StepDone):
                    done = item
                else:
                    yield item  # live pass-through; in check_mode the op made ZERO changes
            abandoned = False
        finally:
            # GeneratorExit (consumer close()/abandon) can escape the yield
            # above while the producer blocks on the bounded queue: keep
            # draining WITHOUT yielding until the sentinel so it finishes,
            # then join — no leaked thread, no producer deadlock.
            while done is None:
                item = q.get()
                if isinstance(item, _StepDone):
                    done = item
            worker.join()
            if abandoned:
                # The stream was abandoned mid-step, but the op above ran to
                # completion and may have really changed the system. No
                # StepFinished can be yielded anymore, so push the step's true
                # outcome out-of-band into ``results`` (the caller's
                # ``results_sink``) — the audit never misses a page. An
                # unexpected exception stays a crash, not a transaction line
                # (the same rule as the consumed path below).
                result = _completed_result(entry, op, done.exc, change, check_mode)
                if result is not None:
                    results.append(result)
                    logger.warning("stream abandoned mid-step; recorded %s as %s",
                                   entry.id, result.outcome.value)
                elif done.exc is not None:
                    logger.error("stream abandoned mid-step; %s raised: %s",
                                 entry.id, done.exc)

        exc = done.exc
        result = _completed_result(entry, op, exc, change, check_mode)
        if result is None:
            raise exc  # unexpected — propagate unchanged (no transaction recorded)
        results.append(result)
        if result.outcome is Outcome.CHANGED:
            verb = f"would {op.value}" if check_mode else op.value
            logger.info("%s: %s (%s)", verb, entry.id, change)
        elif result.outcome is Outcome.SKIPPED:
            logger.warning("skipped %s: %s", entry.id, result.detail)
        else:  # FAILED — fail-fast below
            logger.error("failed %s: %s", entry.id, result.detail)
            if cancel.is_set():
                # the failure happened under a cancel request — typically our
                # own kill of the in-flight command (rc != 0): cancelled
                # semantics (exit 3). A genuine failure BEFORE cancel() keeps
                # the fail-fast exit 1 via the branch below.
                cancelled = True
                exit_code = UserAbort.exit_code
            else:
                exit_code = 1
        yield StepFinished(index=index, total=total, result=result)
        if result.outcome is Outcome.FAILED:
            break

    yield RunFinished(results=tuple(results), exit_code=exit_code, cancelled=cancelled)
