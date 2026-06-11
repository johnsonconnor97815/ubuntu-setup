"""Core data structures — pure, side-effect-free dataclasses.

A ``Plan`` is data (a list of ``Action``); it can be rendered, diffed, and
unit-tested headless. ``CatalogEntry`` keeps the common fields typed and holds
type-specific fields (e.g. ``package`` for apt) in ``fields`` so that adding a
new software *type* never requires changing this model (non-negotiable #6/#7).
"""

from __future__ import annotations

import enum
from dataclasses import dataclass, field
from typing import Any


class Op(str, enum.Enum):
    """An operation requested for an entry. ``str`` subclass -> JSON-friendly."""

    INSTALL = "install"
    REMOVE = "remove"
    UPGRADE = "upgrade"


class Outcome(str, enum.Enum):
    """Per-entry result recorded after (attempting) an action."""

    CHANGED = "changed"   # the action mutated the system
    OK = "ok"             # already in desired state, skipped
    SKIPPED = "skipped"   # not applicable on this host (PreconditionError)
    FAILED = "failed"     # the action errored (ProviderError)


@dataclass(frozen=True)
class CatalogEntry:
    """One declarative software unit, validated against ``catalog/schema.json``."""

    id: str
    description: str
    type: str
    depends_on: tuple[str, ...] = ()
    tags: tuple[str, ...] = ()
    #: host capabilities the entry needs (e.g. "desktop"); the applicability
    #: judgment (``requires ⊆ capabilities``) lives in ``core/environment.py``
    requires: tuple[str, ...] = ()
    source: str = "community"
    #: type-specific fields the provider interprets (e.g. {"package": "ripgrep"})
    fields: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class Action:
    """A single (entry, op) the planner scheduled; ``predicted_state_change`` is
    filled in for plan previews (e.g. ``"absent -> present"``)."""

    entry: CatalogEntry
    op: Op
    predicted_state_change: str | None = None


@dataclass(frozen=True)
class Plan:
    """An ordered list of actions. No side effects."""

    actions: tuple[Action, ...] = ()

    def __iter__(self):
        return iter(self.actions)

    def __len__(self) -> int:
        return len(self.actions)


@dataclass(frozen=True)
class StepResult:
    """The recorded result of one plan step."""

    entry_id: str
    op: Op
    outcome: Outcome
    detail: str = ""


@dataclass
class Manifest:
    """Desired state + append-only transaction history (the manager<->provisioner
    bridge). Serialized as JSON by ``core/state.py``."""

    version: int = 1
    #: the user's intended end-state, e.g. [{"id": "ripgrep", "op": "install"}]
    desired: list[dict[str, str]] = field(default_factory=list)
    #: one entry per apply (run_id / started_at / exit_code / actions+outcome)
    history: list[dict[str, Any]] = field(default_factory=list)
