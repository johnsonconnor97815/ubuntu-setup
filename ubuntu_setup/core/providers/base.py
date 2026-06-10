"""The provider protocol, the ``State`` enum, and the execution context ``Ctx``.

A provider is the *only* place that knows install mechanics for its ``type``.
``check()`` is the idempotency engine: it observes real system state and never
mutates, so it does not take ``ctx``. The mutating ops (``install`` / ``remove``
/ ``upgrade``) receive ``ctx`` — their only handle to shared services.
"""

from __future__ import annotations

import enum
import logging
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Any, Callable, Protocol, runtime_checkable

from ..models import CatalogEntry

if TYPE_CHECKING:  # avoid importing privilege at module load (keep base light)
    from ..privilege import Privilege
    from ..runner import RunResult


class State(enum.Enum):
    """What ``check()`` observed about an entry on the live system."""

    ABSENT = "absent"               # not installed / not applied
    PRESENT = "present"             # installed / applied and current
    OUTDATED = "present_outdated"   # installed but an upgrade is available


def _noop_emit(event: Any) -> None:
    """Default ``ctx.emit`` — drops events (headless runs need no UI sink)."""


@dataclass
class Ctx:
    """Execution context the executor passes to mutating provider ops.

    ``run`` is the single subprocess boundary (``core/runner.run``); ``check_mode``
    is the dry-run mutation guard — when ``True`` an op must make ZERO changes
    (it may still compute and ``emit`` the intended change).
    """

    run: "Callable[..., RunResult]"
    priv: "Privilege"
    log: logging.Logger
    check_mode: bool = False
    emit: Callable[[Any], None] = field(default=_noop_emit)


@runtime_checkable
class Provider(Protocol):
    """One typed handler per entry ``type`` (see ``providers/__init__.py``)."""

    type: str

    def check(self, entry: CatalogEntry) -> State:
        """Live system query — NO mutation, no ``ctx`` needed."""
        ...

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        """Converge to PRESENT (idempotent)."""

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        """Converge to ABSENT (idempotent)."""

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        """PRESENT -> latest (idempotent)."""
