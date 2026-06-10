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
missing a page); programmatically terminating its command is the streaming
runner's kill handle (a later commit point — ``cancel`` is its injection seam).
"""

from __future__ import annotations

import logging
import queue
import threading
from typing import Any, Callable, Iterator

from .errors import PreconditionError, PrivilegeError, ProviderError, UserAbort
from .events import Event, RunFinished, RunStarted, StepFinished, StepStarted
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
    check_mode: bool = False,
    cancel: "threading.Event | None" = None,
    results_sink: "list[StepResult] | None" = None,
) -> Iterator[Event]:
    """Run ``plan``, yielding events; the final event is :class:`RunFinished`.

    ``cancel`` (a ``threading.Event``) is the cooperative stop signal: once set,
    no further step starts; the step already in flight finishes normally, then
    the stream terminates with ``RunFinished(cancelled=True, exit_code=3)``.
    Provider ``ctx.emit`` payloads are yielded live, interleaved between the
    step's ``StepStarted`` and ``StepFinished`` (see the bridge note above).

    ``results_sink`` is the out-of-band results channel: when given, every
    step's :class:`StepResult` is appended to it the moment it forms — so a
    caller recording the transaction still sees a step that ran to completion
    while the stream was being closed/abandoned (no ``StepFinished`` can be
    yielded then). On a fully consumed stream the sink's content equals
    ``RunFinished.results``.
    """
    run = run or default_run
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

        # thread bridge: the op blocks in a worker; we drain its emits live
        q: "queue.Queue[Any]" = queue.Queue(maxsize=_EMIT_QUEUE_MAX)
        ctx = Ctx(run=run, priv=priv, log=logger, check_mode=check_mode, emit=q.put)
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
            exit_code = 1
        yield StepFinished(index=index, total=total, result=result)
        if result.outcome is Outcome.FAILED:
            break

    yield RunFinished(results=tuple(results), exit_code=exit_code, cancelled=cancelled)
