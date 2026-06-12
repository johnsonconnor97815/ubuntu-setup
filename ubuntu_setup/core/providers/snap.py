"""The ``snap`` provider — snap packages from the Snap Store.

Entry fields (spec ``.trellis/spec/core/catalog-and-providers.md``; schema
``catalog/schema.json``):

- ``snap`` (optional) — the store name; defaults to the entry id (the common
  case: ``chromium``/``thunderbird``). Declared only when the two differ
  (entry ``telegram`` -> store ``telegram-desktop``).
- ``classic`` (optional bool, default ``false``) — the confinement flag.
  Authored, never auto-detected: ``classic: true`` is set iff the store page /
  ``snap info`` shows ``confinement: classic`` (verified per shipped entry;
  confinement is the packager's choice and cannot be changed at install time).
- ``channel`` (optional) — a non-default ``--channel=<track/risk>``; omitted
  for ``latest/stable`` (every shipped entry).

Verified idioms:

- **check:** ``snap list <name>`` — exit 0 = installed, any non-zero = ABSENT.
  snap has no machine-readable rc band (``no matching snaps installed`` and a
  daemon error both exit 1), so every non-zero reads "not converged" and errs
  toward a loud install attempt rather than faking convergence (the same
  reasoning as the ``script`` provider). Never OUTDATED — refresh semantics
  belong to the deferred ``upgrade`` op.
- **install:** ``snap install <name> [--classic] [--channel=…]`` — one snap
  per command (passing 2+ already-installed snaps in one command fails with
  exit 1; structurally guaranteed here: one entry = one snap), per-command
  ``sudo`` (there is no per-user snap), and the widened install timeout
  (IDE-class snaps are 1.3–1.7 GB).

snapd precondition (prd 06-11-provider-snap: detect-and-skip, never install
snapd ourselves):

- snapd ships preinstalled on Ubuntu Desktop/Server, but not in containers or
  on Debian-family hosts that removed it. When the ``snap`` CLI is absent,
  ``check()`` reads ABSENT (a snap cannot be present without snapd — still
  "ask the system") and ``install()`` raises :class:`PreconditionError` — the
  executor records the entry ``skipped`` and the run continues (spec
  ``idempotency-and-execution.md``). The probe fires *before* the
  ``check_mode`` guard so a dry run on a snapd-less host shows the visible
  skip too (consistent with the ``requires`` gate's dry-run visibility).
- A present CLI with a broken/unseeded daemon is NOT a precondition miss:
  ``check()`` reads ABSENT and the install fails loudly (``ProviderError``)
  with snapd's own error in the stderr tail — a real problem on a
  snapd-having host should stop the run, not skip the entry.

``remove`` / ``upgrade`` are deferred in this MVP slice (prd out-of-scope),
matching the apt provider's posture.
"""

from __future__ import annotations

import shutil
from typing import Callable

from ..errors import PreconditionError, ProviderError
from ..models import CatalogEntry
from ..runner import RunResult
from ..runner import run as default_run
from .apt import _INSTALL_TIMEOUT
from .base import Ctx, State


class SnapProvider:
    type = "snap"

    def __init__(
        self,
        run: "Callable[..., RunResult] | None" = None,
        *,
        which: "Callable[[str], str | None] | None" = None,
    ) -> None:
        # the single subprocess boundary, injected for testability
        self._run: Callable[..., RunResult] = run or default_run
        # the snapd presence probe (a PATH lookup, not a subprocess — running
        # a missing binary through the runner would raise OSError instead of
        # returning a branchable rc); injectable so tests fake a snapd-less host
        self._which = which or shutil.which

    # -- helpers --------------------------------------------------------------
    @staticmethod
    def _name(entry: CatalogEntry) -> str:
        """The store name — the ``snap`` field, defaulting to the entry id."""
        return str(entry.fields.get("snap") or entry.id)

    def _snapd_missing(self) -> bool:
        return self._which("snap") is None

    # -- protocol -------------------------------------------------------------
    def check(self, entry: CatalogEntry) -> State:
        if self._snapd_missing():
            # no snapd -> no snap can be installed; the "host can't do snaps"
            # signal itself surfaces at install time as PreconditionError
            return State.ABSENT
        res = self._run(["snap", "list", self._name(entry)])
        return State.PRESENT if res.returncode == 0 else State.ABSENT

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        # detect-and-skip BEFORE the dry-run guard: a dry run on a snapd-less
        # host must show the visible skip, never a confident "would change"
        if self._snapd_missing():
            raise PreconditionError(
                "snapd is not available on this host (no `snap` CLI); install "
                "snapd to enable snap entries — this tool never installs snapd "
                "itself",
                entry_id=entry.id,
            )
        if ctx.check_mode:
            return  # dry-run mutation guard: make ZERO changes
        name = self._name(entry)
        argv = ["snap", "install", name]
        if entry.fields.get("classic"):
            argv.append("--classic")
        channel = entry.fields.get("channel")
        if channel:
            argv.append(f"--channel={channel}")
        res = ctx.run(argv, sudo=True, timeout=_INSTALL_TIMEOUT)
        if res.returncode != 0:
            raise ProviderError(
                f"snap install {name!r} failed (exit {res.returncode})",
                entry_id=entry.id,
                stderr_tail=res.stderr[-500:],
            )

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("snap remove is deferred in this MVP slice")

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("snap upgrade is deferred in this MVP slice")
