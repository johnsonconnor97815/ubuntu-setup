"""Host capability detection — the ``requires`` applicability judgment (brain).

A catalog entry may declare ``requires: [desktop]``: it is applicable only on a
host that has every named capability. The judgment itself
(``entry.requires ⊆ capabilities``, exposed as :func:`unmet_requires`) lives
HERE and is consumed by the facade's scan/browse filter and the executor's
plan/apply skip — the UI never re-derives it (non-negotiable #1).

``desktop`` means *the machine has a desktop stack installed*, not "the current
session is graphical": an SSH login into a desktop machine must still be able
to install GUI software. Any one signal suffices:

1. ``DISPLAY`` / ``WAYLAND_DISPLAY`` is set (we are inside a graphical session);
2. ``systemctl get-default`` prints ``graphical.target`` (boots into a DM);
3. ``/usr/share/xsessions`` or ``/usr/share/wayland-sessions`` is non-empty
   (a desktop session is installed even when booted into a text target).

The probe is read-only and cheap (two env lookups, at most one ``systemctl``
call and two directory peeks). The external command goes through
``core/runner.py`` (non-negotiable #5), and every probe input is injectable
for tests.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Callable, Iterable, Mapping

from .models import CatalogEntry
from .runner import RunResult
from .runner import run as default_run

#: the one capability defined today; ``requires`` stays a list purely as the
#: extension point for future conditions (arch, ubuntu release, ...)
DESKTOP = "desktop"

#: every capability :func:`detect_capabilities` can report — kept in sync with
#: the ``requires`` enum in ``catalog/schema.json``
KNOWN_CAPABILITIES = frozenset({DESKTOP})

#: where installed desktop sessions register themselves (probe 3)
SESSION_DIRS: "tuple[Path, ...]" = (
    Path("/usr/share/xsessions"),
    Path("/usr/share/wayland-sessions"),
)

_GRAPHICAL_TARGET = "graphical.target"


def detect_capabilities(
    *,
    run: "Callable[..., RunResult] | None" = None,
    env: "Mapping[str, str] | None" = None,
    session_dirs: "Iterable[Path] | None" = None,
) -> frozenset[str]:
    """Probe the host once and return the set of available capabilities.

    The three desktop signals are OR-ed; each probe input is injectable
    (``run`` for the systemctl query, ``env`` for the display variables,
    ``session_dirs`` for the session registries). Read-only — never mutates.
    """
    run = run or default_run
    environ = os.environ if env is None else env
    dirs = SESSION_DIRS if session_dirs is None else tuple(session_dirs)

    capabilities: set[str] = set()
    if _has_desktop_stack(run, environ, dirs):
        capabilities.add(DESKTOP)
    return frozenset(capabilities)


def _has_desktop_stack(
    run: "Callable[..., RunResult]",
    environ: "Mapping[str, str]",
    session_dirs: "tuple[Path, ...]",
) -> bool:
    # 1. inside a graphical session right now
    if environ.get("DISPLAY") or environ.get("WAYLAND_DISPLAY"):
        return True
    # 2. the machine boots into a display manager
    try:
        res = run(["systemctl", "get-default"])
    except OSError:
        pass  # no systemd (e.g. a container) — not a desktop signal
    else:
        if res.returncode == 0 and res.stdout.strip() == _GRAPHICAL_TARGET:
            return True
    # 3. a desktop session is installed, even if booted headless
    for directory in session_dirs:
        try:
            if any(directory.iterdir()):
                return True
        except OSError:
            continue  # missing/unreadable dir — not a desktop signal
    return False


def unmet_requires(entry: CatalogEntry, capabilities: frozenset[str]) -> tuple[str, ...]:
    """The capabilities ``entry`` needs but this host lacks (empty ⇒ applicable).

    The ONE place the ``requires ⊆ capabilities`` judgment lives: scan/browse
    filtering and the executor's plan/apply skip both call this — surfaces
    only render the result.
    """
    return tuple(c for c in entry.requires if c not in capabilities)
