"""The ``ppa`` provider — Launchpad PPAs as a thin reuse of the deb repo
machinery.

A PPA is just a third-party APT repository with a fully *derivable* layout, so
this provider subclasses :class:`~.deb.DebProvider`'s repo mode instead of
shelling out to ``add-apt-repository`` (form decided 2026-06-12, prd
06-11-provider-ppa). The entry's single field ``ppa: <owner>/<name>`` is
translated once into the equivalent deb repo-mode view and every mechanism is
shared — never copy-pasted:

- ``repo_url = https://ppa.launchpadcontent.net/<owner>/<name>/ubuntu``,
  ``suite = {codename}`` (resolved from ``/etc/os-release``),
  ``components = [main]``, file basename = the entry id;
- the signing key comes from the Launchpad API
  (``…?ws.op=getSigningKeyData``), which returns **JSON** — a quoted string
  embedding the ASCII-armored key (Content-Type ``application/json``, verified
  live 2026-06-12) — so :meth:`_stage_key` JSON-decodes the download before
  the shared armor-sniff + dearmor + ``sudo install`` flow;
- ``check()`` is deb repo-mode check verbatim: generated ``.sources``
  byte-match + non-empty keyring + the fetched-lists probe against
  ``/var/lib/apt/lists`` — always the live filesystem, never
  ``add-apt-repository --list`` (it ignores legacy ``.list`` files on 24.04,
  Launchpad bug 2106617) and never a command's remembered side effect;
- ``install()`` marks ``ctx.aptcache`` and never updates itself (the
  once-per-batch freshness guard, same as deb repo mode).

Why not ``add-apt-repository``: it requires ``software-properties-common``
(an in-provider apt install outside the entry model), runs its own
``apt-get update`` by default (breaking the once-per-batch guard), and its
output file name/format vary by release (embedded-key ``.sources`` on 24.04,
``.list`` + separate keyring on 22.04) — not byte-for-byte checkable. Direct
placement keeps PPAs inside the exact converged-files contract every other
repo follows.

Accepted limitation: a PPA the user already added via ``add-apt-repository``
lives under a different basename (``<owner>-ubuntu-<name>-<codename>``); ours
converges in parallel (apt warns about the duplicate definition but works) —
the same accepted-duplication class as any externally configured repo.

``remove``/``upgrade`` are deferred (prd: PPA removal is out of scope).
"""

from __future__ import annotations

import json
from pathlib import Path

from ..errors import CatalogError, ProviderError
from ..models import CatalogEntry
from .base import Ctx, State
from .deb import DebProvider

#: every PPA serves from the Launchpad archive host (https since 22.04's
#: launchpadcontent.net migration)
_PPA_URL = "https://ppa.launchpadcontent.net/{owner}/{archive}/ubuntu"

#: the Launchpad web-service op that returns the PPA's signing key. The
#: response is JSON (a quoted string embedding the armored key) — see
#: :meth:`PpaProvider._stage_key`.
_KEY_URL = ("https://api.launchpad.net/devel/~{owner}/+archive/ubuntu/"
            "{archive}?ws.op=getSigningKeyData")

_ARMOR_MARK = "BEGIN PGP PUBLIC KEY BLOCK"


class PpaProvider(DebProvider):
    type = "ppa"

    # -- translation (the single ppa-specific piece besides the key unwrap) ----
    @staticmethod
    def _owner_archive(entry: CatalogEntry) -> "tuple[str, str]":
        raw = str(entry.fields.get("ppa") or "")
        owner, sep, archive = raw.partition("/")
        if not owner or not sep or not archive or "/" in archive:
            # schema should prevent this; guard anyway (and loudly — a
            # multi-slash coordinate would otherwise derive a garbage URL)
            raise CatalogError(
                f"ppa entry {entry.id!r}: 'ppa' must be '<owner>/<name>', "
                f"got {raw!r}"
            )
        return owner, archive

    def _as_repo_entry(self, entry: CatalogEntry) -> CatalogEntry:
        """The deb repo-mode view of a ppa entry (idempotent: an already
        translated entry — no ``ppa`` field — passes through, so the shared
        deb internals can re-enter the overridden public helpers safely)."""
        if "ppa" not in entry.fields:
            return entry
        owner, archive = self._owner_archive(entry)
        return CatalogEntry(
            id=entry.id,
            description=entry.description,
            type=entry.type,
            depends_on=entry.depends_on,
            tags=entry.tags,
            requires=entry.requires,
            source=entry.source,
            fields={
                "name": entry.id,  # file basename: never collides with
                #                    add-apt-repository's <owner>-ubuntu-<name>
                "key_url": _KEY_URL.format(owner=owner, archive=archive),
                "repo_url": _PPA_URL.format(owner=owner, archive=archive),
                "suite": "{codename}",
                "components": ["main"],
            },
        )

    # -- public helpers consumed by tests/integration: translate first ---------
    def sources_content(self, entry: CatalogEntry) -> str:
        return super().sources_content(self._as_repo_entry(entry))

    def lists_release_paths(self, entry: CatalogEntry) -> "tuple[str, ...]":
        return super().lists_release_paths(self._as_repo_entry(entry))

    # -- protocol ---------------------------------------------------------------
    def check(self, entry: CatalogEntry) -> State:
        return super().check(self._as_repo_entry(entry))

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        super().install(self._as_repo_entry(entry), ctx)

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError(
            "ppa remove is deferred (PPA removal is out of scope)")

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("ppa upgrade is deferred in this MVP slice")

    # -- the key unwrap (the deb provider's staging hook) -----------------------
    def _stage_key(self, downloaded: Path, entry: CatalogEntry) -> None:
        """Unwrap Launchpad's JSON envelope in place.

        ``getSigningKeyData`` serves ``application/json``: a quoted string
        whose value is the ASCII-armored public key (verified live
        2026-06-12). Decode it so the shared armor sniff sees a regular
        armored key and dearmors it. A missing file — only possible under a
        test fake that doesn't create it — is left alone, mirroring
        ``_is_armored``'s tolerance: a genuine download failure already
        raised on curl's exit code.
        """
        try:
            raw = downloaded.read_text(encoding="utf-8")
        except OSError:
            return
        try:
            decoded = json.loads(raw)
        except ValueError as exc:
            raise ProviderError(
                f"Launchpad signing-key response is not valid JSON: {exc}",
                entry_id=entry.id,
            ) from exc
        if not isinstance(decoded, str) or _ARMOR_MARK not in decoded:
            # e.g. JSON null: a freshly created PPA generates its key
            # asynchronously and has none to serve yet
            raise ProviderError(
                "Launchpad returned no signing key data for this PPA",
                entry_id=entry.id,
            )
        downloaded.write_text(decoded, encoding="utf-8")
