"""Turn a set of desired actions into an ordered :class:`Plan`.

Each desired ``{id, op}`` is validated, its ``depends_on`` closure expanded
(an install/upgrade pulls its dependencies in automatically — selecting docker
brings docker's repo entry along), and the whole set is topologically sorted so
every entry is acted on after its dependencies, while independent entries keep
their input order (deterministic, stable). A dependency cycle raises
:class:`CatalogError` carrying the cycle path (exit 2).
"""

from __future__ import annotations

from collections.abc import Mapping as AbcMapping
from typing import Iterable, Mapping

from .errors import CatalogError
from .models import Action, CatalogEntry, Op, Plan

#: ops whose dependencies must converge first (closure expansion). A REMOVE
#: needs nothing installed for it, so it never pulls dependencies in.
_EXPANDING_OPS = frozenset({Op.INSTALL, Op.UPGRADE})


def build_plan(
    desired: Iterable[Mapping[str, str]],
    catalog: Mapping[str, CatalogEntry],
) -> Plan:
    """Build a :class:`Plan` from ``desired`` (``[{"id": ..., "op": ...}]``).

    - **Closure expansion:** an install/upgrade automatically schedules its
      (transitive) ``depends_on`` with op ``install``; an explicit desired op
      for the same id wins over that implicit install.
    - **Stable topological order:** entries are emitted depth-first in input
      order, dependencies before dependents, each id exactly once (shared
      dependencies are deduped) — independent entries keep their listed order.
    - Raises :class:`CatalogError` for an unknown id, an unsupported op, the
      same id desired twice with conflicting ops, a dependency that is not in
      ``catalog``, or a dependency cycle (the message carries the cycle path).
    """
    explicit: "dict[str, Op]" = {}
    roots: "list[str]" = []
    for item in desired:
        if not isinstance(item, AbcMapping):
            raise CatalogError(
                f"manifest desired item must be a mapping like {{'id': ..., 'op': ...}}, got {item!r}"
            )
        entry_id = item.get("id")
        if not entry_id:
            raise CatalogError(f"manifest desired item missing 'id': {item!r}")
        if entry_id not in catalog:
            raise CatalogError(f"desired id {entry_id!r} is not in the catalog")
        try:
            op = Op(item.get("op", Op.INSTALL.value))
        except ValueError:
            raise CatalogError(f"desired id {entry_id!r} has unknown op {item.get('op')!r}") from None
        if entry_id in explicit:
            if explicit[entry_id] is not op:
                raise CatalogError(
                    f"desired id {entry_id!r} appears twice with conflicting ops "
                    f"({explicit[entry_id].value} vs {op.value})"
                )
            continue  # exact duplicate -> dedupe
        explicit[entry_id] = op
        roots.append(entry_id)

    ordered: "list[str]" = []
    done: "set[str]" = set()

    def visit(entry_id: str, path: "tuple[str, ...]") -> None:
        """DFS: emit ``entry_id`` after its dependencies (cycle-guarded)."""
        if entry_id in done:
            return
        if entry_id in path:
            cycle = (*path[path.index(entry_id):], entry_id)
            raise CatalogError("dependency cycle: " + " -> ".join(cycle))
        entry = catalog.get(entry_id)
        if entry is None:
            # the loader resolves depends_on against the FULL catalog, so this
            # only happens when planning against a filtered subset
            raise CatalogError(
                f"entry {path[-1]!r} depends_on {entry_id!r}, which is not in the catalog"
            )
        if explicit.get(entry_id, Op.INSTALL) in _EXPANDING_OPS:
            for dep in entry.depends_on:
                visit(dep, (*path, entry_id))
        done.add(entry_id)
        ordered.append(entry_id)

    for entry_id in roots:
        visit(entry_id, ())

    return Plan(actions=tuple(
        Action(entry=catalog[eid], op=explicit.get(eid, Op.INSTALL))
        for eid in ordered
    ))
