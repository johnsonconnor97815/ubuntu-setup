"""The ``apt`` provider — standard apt packages.

Verified idioms (see ``.trellis/spec/core/catalog-and-providers.md``):

- check:   ``dpkg-query -W -f='${Status}' <pkg>`` == ``install ok installed``
           (gate on the Status string; ``dpkg -s`` would call a removed-but-not
           -purged package "present"). Distinguish ABSENT (no match, rc 1) from
           a real dpkg error (rc >= 2).
- install: ``apt-get install -y --no-install-recommends <pkg>`` with the
           force-conf options so a modified conffile never blocks non-interactively.

This MVP slice implements ``check`` + ``install`` only; ``remove`` / ``upgrade``
are deferred (the protocol keeps their signatures).
"""

from __future__ import annotations

from typing import Callable

from ..errors import CatalogError, ProviderError
from ..models import CatalogEntry
from ..runner import RunResult
from ..runner import run as default_run
from .base import Ctx, State

_INSTALLED_STATUS = "install ok installed"

#: per-command cap for the install op. The runner's blanket DEFAULT_TIMEOUT
#: (600s) is right for checks/repo ops but provably too tight for heavy
#: meta-packages: the catalog real-install verification (2026-06-11) saw
#: libreoffice/qemu/dotnet-class installs exceed 600s on a contended/slow
#: link and die mid-download with exit 124. Installing is the one op that
#: legitimately downloads hundreds of MB, so it carries its own wider cap.
_INSTALL_TIMEOUT = 3600.0


def dpkg_state(
    run: "Callable[..., RunResult]",
    package: str,
    *,
    entry_id: "str | None" = None,
) -> State:
    """The one dpkg installed-state idiom, shared by every dpkg-backed check
    (``apt`` packages, ``deb`` direct mode): gate on the ``${Status}`` string,
    distinguish "no match" (rc 1 -> ABSENT) from a real dpkg error (rc >= 2)."""
    res = run(["dpkg-query", "-W", "-f=${Status}", package])
    if res.returncode == 0:
        if res.stdout.strip() == _INSTALLED_STATUS:
            return State.PRESENT
        # e.g. "deinstall ok config-files" — removed but not purged -> ABSENT
        return State.ABSENT
    # rc 1 = "no packages found matching <pkg>" -> ABSENT.
    if res.returncode == 1:
        return State.ABSENT
    # rc >= 2 = a real dpkg-query/database error — do NOT call it "absent".
    raise ProviderError(
        f"dpkg-query failed for {package!r} (exit {res.returncode})",
        entry_id=entry_id,
        stderr_tail=res.stderr[-500:],
    )


class AptProvider:
    type = "apt"

    def __init__(self, run: "Callable[..., RunResult] | None" = None) -> None:
        # the single subprocess boundary, injected for testability
        self._run: Callable[..., RunResult] = run or default_run

    # -- helpers --------------------------------------------------------------
    @staticmethod
    def _package(entry: CatalogEntry) -> str:
        pkg = entry.fields.get("package")
        if not pkg:
            # schema should prevent this; guard anyway (single identity source)
            raise CatalogError(f"apt entry {entry.id!r} is missing required field 'package'")
        return str(pkg)

    # -- protocol -------------------------------------------------------------
    def check(self, entry: CatalogEntry) -> State:
        pkg = self._package(entry)
        state = dpkg_state(self._run, pkg, entry_id=entry.id)
        if state is State.PRESENT:
            # optional version pin -> OUTDATED when the installed version differs
            version = entry.fields.get("version")
            if version:
                vres = self._run(["dpkg-query", "-W", "-f=${Version}", pkg])
                if vres.returncode == 0 and vres.stdout.strip() != str(version):
                    return State.OUTDATED
        return state

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        if ctx.check_mode:
            return  # dry-run mutation guard: make ZERO changes
        # consume a pending repo change: a repo entry that converged earlier in
        # this run marked the apt cache, and the index must be refreshed before
        # the first install that may resolve from it (once per batch, never per
        # package — see providers/aptcache.py)
        ctx.aptcache.ensure_fresh(ctx.run, entry_id=entry.id)
        pkg = self._package(entry)
        version = entry.fields.get("version")
        target = f"{pkg}={version}" if version else pkg
        res = ctx.run(
            [
                "apt-get", "install", "-y", "--no-install-recommends",
                "-o", "Dpkg::Options::=--force-confdef",
                "-o", "Dpkg::Options::=--force-confold",
                target,
            ],
            sudo=True,
            timeout=_INSTALL_TIMEOUT,
        )
        if res.returncode != 0:
            raise ProviderError(
                f"apt-get install {target!r} failed (exit {res.returncode})",
                entry_id=entry.id,
                stderr_tail=res.stderr[-500:],
            )

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("apt remove is deferred in this MVP slice")

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("apt upgrade is deferred in this MVP slice")
