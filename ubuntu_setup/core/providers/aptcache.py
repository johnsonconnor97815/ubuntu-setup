"""The per-run apt list freshness guard (``apt-get update`` batching).

``apt-get update`` is the one non-idempotent apt step (no stable end-state —
see ``.trellis/spec/core/idempotency-and-execution.md``): it must run after a
repo change and *before* the first package install that consumes the new repo,
but never once per package. :class:`AptCache` encodes that as a per-run
mark/consume pair:

- a repo-changing provider (``deb`` repo mode, the future ``ppa``) calls
  :meth:`mark_repo_changed` after writing its key/sources — it never updates
  itself;
- a package-installing provider (``apt``, ``deb`` direct mode) calls
  :meth:`ensure_fresh` right before its ``apt-get install`` — the update runs
  **iff a repo change is pending**, then the pending flag clears.

So N repo entries converging before the next package install cost exactly ONE
``apt-get update`` (the dedupe the prd locks with a unit test), while a repo
added later in the same run still triggers its own update before its first
consumer. A run that only converges repo entries leaves the pending change
unconsumed — the ``deb`` provider's ``check()`` detects that (the fetched-lists
probe) and reports the repo ABSENT, so the next run re-converges and updates:
self-healing, never a silently stale cache.

The executor creates one instance per run and hands it to every step's ``ctx``
(``ctx.aptcache``); providers never share globals.
"""

from __future__ import annotations

from typing import Callable

from ..errors import ProviderError
from ..runner import RunResult

#: ``apt-get update`` fetches every configured index — give it more room than
#: the runner's blanket default, but far less than a heavy install.
_UPDATE_TIMEOUT = 900.0


class AptCache:
    """Per-run guard: ``apt-get update`` once per batch of repo changes."""

    def __init__(self) -> None:
        self._pending_repo_change = False

    @property
    def pending(self) -> bool:
        """A repo changed this run and no ``apt-get update`` has run since."""
        return self._pending_repo_change

    def mark_repo_changed(self) -> None:
        """Record that a repo definition (key/sources) was added or rewritten."""
        self._pending_repo_change = True

    def ensure_fresh(
        self,
        run: "Callable[..., RunResult]",
        *,
        entry_id: "str | None" = None,
    ) -> None:
        """Run ``apt-get update`` iff a repo change is pending, then clear it.

        Called by package-installing ops right before ``apt-get install`` (the
        consumption side of the guard). A failed update raises
        :class:`ProviderError` (the consuming entry fails fast and the pending
        flag stays set, so a retry updates again).
        """
        if not self._pending_repo_change:
            return
        res = run(["apt-get", "update"], sudo=True, timeout=_UPDATE_TIMEOUT)
        if res.returncode != 0:
            raise ProviderError(
                f"apt-get update failed (exit {res.returncode})",
                entry_id=entry_id,
                stderr_tail=res.stderr[-500:],
            )
        self._pending_repo_change = False
