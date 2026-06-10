"""Execute a :class:`Plan`: check-before-act, fail-fast, dry-run aware.

For each action: ``check()`` -> skip if already satisfied -> otherwise apply via
the provider -> record a :class:`StepResult`. The failure policy is **fail-fast**:
the first :class:`ProviderError` stops the run (exit 1). A
:class:`PreconditionError` is *not* a failure — the entry is recorded
``skipped`` and the run continues (detect-and-skip).

Plan mode (``check_mode=True``) is the dry-run mutation guard: every provider op
must make zero changes; the "would change" signal comes from comparing each
entry's ``check()`` state to the desired op (no parallel simulation path).
"""

from __future__ import annotations

import logging
from typing import Any, Callable

from .errors import PreconditionError, ProviderError
from .models import Op, Outcome, Plan, StepResult
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


def execute(
    plan: Plan,
    *,
    priv: Privilege,
    logger: logging.Logger,
    run: "Callable[..., RunResult] | None" = None,
    check_mode: bool = False,
    emit: Callable[[Any], None] | None = None,
) -> tuple[list[StepResult], int]:
    """Run ``plan`` and return ``(step_results, exit_code)``.

    ``exit_code`` is 0 when every step was ok/changed/skipped, or 1 when a step
    failed (the run stopped there — fail-fast).
    """
    run = run or default_run
    emit = emit or (lambda event: None)
    results: list[StepResult] = []
    exit_code = 0

    for action in plan.actions:
        entry = action.entry
        op = action.op
        provider = get_provider(entry.type, run=run)

        # check() reads live state; a real check error (not "absent") fails fast
        try:
            state = provider.check(entry)
        except ProviderError as exc:
            results.append(StepResult(entry.id, op, Outcome.FAILED, str(exc)))
            logger.error("check failed for %s: %s", entry.id, exc)
            exit_code = 1
            break

        if state in _SATISFIED.get(op, set()):
            results.append(StepResult(entry.id, op, Outcome.OK, f"already {state.value}"))
            logger.info("ok: %s already %s", entry.id, state.value)
            continue

        change = f"{state.value} -> {_TARGET[op].value}"
        ctx = Ctx(run=run, priv=priv, log=logger, check_mode=check_mode, emit=emit)
        method = getattr(provider, op.value)
        try:
            method(entry, ctx)  # in check_mode the provider makes ZERO changes
        except PreconditionError as exc:
            results.append(StepResult(entry.id, op, Outcome.SKIPPED, str(exc)))
            logger.warning("skipped %s: %s", entry.id, exc)
            continue
        except ProviderError as exc:
            results.append(StepResult(entry.id, op, Outcome.FAILED, str(exc)))
            logger.error("failed %s: %s", entry.id, exc)
            exit_code = 1
            break
        except NotImplementedError as exc:
            msg = f"op {op.value!r} not implemented for type {entry.type!r}: {exc}"
            results.append(StepResult(entry.id, op, Outcome.FAILED, msg))
            logger.error("failed %s: %s", entry.id, msg)
            exit_code = 1
            break

        verb = f"would {op.value}" if check_mode else op.value
        results.append(StepResult(entry.id, op, Outcome.CHANGED, f"{verb} ({change})"))
        logger.info("%s: %s (%s)", verb, entry.id, change)

    return results, exit_code
