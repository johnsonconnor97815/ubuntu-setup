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
        res = self._run(["dpkg-query", "-W", "-f=${Status}", pkg])

        if res.returncode == 0:
            if res.stdout.strip() == _INSTALLED_STATUS:
                # optional version pin -> OUTDATED when the installed version differs
                version = entry.fields.get("version")
                if version:
                    vres = self._run(["dpkg-query", "-W", "-f=${Version}", pkg])
                    if vres.returncode == 0 and vres.stdout.strip() != str(version):
                        return State.OUTDATED
                return State.PRESENT
            # e.g. "deinstall ok config-files" — removed but not purged -> ABSENT
            return State.ABSENT

        # rc 1 = "no packages found matching <pkg>" -> ABSENT.
        if res.returncode == 1:
            return State.ABSENT

        # rc >= 2 = a real dpkg-query/database error — do NOT call it "absent".
        raise ProviderError(
            f"dpkg-query failed for {pkg!r} (exit {res.returncode})",
            entry_id=entry.id,
            stderr_tail=res.stderr[-500:],
        )

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        if ctx.check_mode:
            return  # dry-run mutation guard: make ZERO changes
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
