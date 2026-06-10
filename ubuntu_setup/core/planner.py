"""Turn a set of desired actions into an ordered :class:`Plan`.

This MVP slice maps each desired ``{id, op}`` to an ``Action`` in listed order.
``depends_on`` closure expansion + topological sort are deferred (single-entry
runs); the ``Plan`` shape is unchanged when they land, so it is an additive step.
"""

from __future__ import annotations

from collections.abc import Mapping as AbcMapping
from typing import Iterable, Mapping

from .errors import CatalogError
from .models import Action, CatalogEntry, Op, Plan


def build_plan(
    desired: Iterable[Mapping[str, str]],
    catalog: Mapping[str, CatalogEntry],
) -> Plan:
    """Build a :class:`Plan` from ``desired`` (``[{"id": ..., "op": ...}]``).

    Raises :class:`CatalogError` for an unknown id or an unsupported op.
    """
    actions: list[Action] = []
    for item in desired:
        if not isinstance(item, AbcMapping):
            raise CatalogError(
                f"manifest desired item must be a mapping like {{'id': ..., 'op': ...}}, got {item!r}"
            )
        entry_id = item.get("id")
        if not entry_id:
            raise CatalogError(f"manifest desired item missing 'id': {item!r}")
        entry = catalog.get(entry_id)
        if entry is None:
            raise CatalogError(f"desired id {entry_id!r} is not in the catalog")
        try:
            op = Op(item.get("op", Op.INSTALL.value))
        except ValueError:
            raise CatalogError(f"desired id {entry_id!r} has unknown op {item.get('op')!r}") from None
        actions.append(Action(entry=entry, op=op))
    return Plan(actions=tuple(actions))
