"""The provider registry — the ONE place that maps ``type`` -> provider.

Nothing else in the brain may branch on ``entry.type`` (non-negotiable #6).
Adding a software type is local: a new module + one line in ``_REGISTRY``.
"""

from __future__ import annotations

from typing import Callable

from ..errors import CatalogError
from ..runner import RunResult
from .apt import AptProvider
from .aptcache import AptCache
from .base import Ctx, Provider, State
from .deb import DebProvider
from .ppa import PpaProvider
from .script import ScriptProvider

#: type string -> provider class. The single source of dispatch knowledge;
#: ``core/catalog.py`` asks :func:`known_types` to validate entry types.
_REGISTRY: dict[str, type] = {
    AptProvider.type: AptProvider,
    DebProvider.type: DebProvider,
    PpaProvider.type: PpaProvider,
    ScriptProvider.type: ScriptProvider,
}


def known_types() -> frozenset[str]:
    """The set of registered ``type`` values (used by the catalog loader)."""
    return frozenset(_REGISTRY)


def get_provider(entry_type: str, *, run: "Callable[..., RunResult] | None" = None) -> Provider:
    """Construct the provider for ``entry_type`` (injecting the subprocess runner).

    Raises :class:`CatalogError` for an unregistered type — the boundary bug the
    cross-layer guide warns about ("a type with no registered provider").
    """
    try:
        cls = _REGISTRY[entry_type]
    except KeyError:
        raise CatalogError(
            f"unknown entry type {entry_type!r}; registered: {sorted(_REGISTRY)}"
        ) from None
    return cls(run=run)


__all__ = ["AptCache", "Ctx", "Provider", "State", "get_provider", "known_types"]
