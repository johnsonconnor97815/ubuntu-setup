"""The ``script`` provider — the declarative escape hatch.

The one provider that runs *author-supplied* commands (spec:
``.trellis/spec/core/catalog-and-providers.md``). An entry carries:

- ``check`` (required) — the idempotency probe. A real probe, never ``true``
  (the schema rejects a missing/empty/non-string ``check``; a vacuous one is
  rejected in human review — every shipped ``script`` entry is reviewed).
- ``install`` (required) — the upstream's official install command, recorded
  verbatim (the "trust the official source" decision) with its sourcing
  comment in the catalog.
- ``remove`` / ``upgrade`` (optional) — **reserved fields, not implemented**
  in this MVP slice (prd 06-11-provider-script: field kept, op deferred).
- ``sudo`` (optional bool, default ``false``) — the privilege declaration.

Execution form (decided here, reconciled to the spec):

- Commands are author-written **shell strings**, so they run as
  ``["bash", "-o", "pipefail", "-c", <command>]`` through the runner — the
  spec's sanctioned ``bash -c`` form for ``script``, argv list + ``shell=False``,
  the exact string audit-logged via ``shlex.join``. ``pipefail`` is not
  optional: the official ``curl … | sh`` idiom would otherwise report the
  *interpreter's* exit code and swallow a failed download as success.
- Deliberately **not** a login shell (``bash -lc``): sourcing the user's
  profile would make probes depend on login-shell PATH (forbidden — probes
  use absolute paths / explicit env) and make installs depend on machine-local
  rc files.

Privilege (spec ``privilege-and-safety.md``, prd: explicit declaration):

- Default is the **plain user** — most script entries are user-level installs
  into ``$HOME`` (rustup/uv/starship class). The runner is never escalated for
  them, and ``HOME`` is pinned to the *real* user's home from the passwd DB
  (``privilege.real_home``) so ``$HOME``/``~`` in an author command never
  resolves to ``/root`` under a (discouraged) sudo'd app launch (Rule 3).
- ``sudo: true`` escalates the **whole command string** per command via the
  runner's ``sudo -n env …`` variant (root-level installers: ollama, rclone,
  npm -g class). Root-level commands must not use ``~``/``$HOME`` (authoring
  rule; sudo's ``env_reset`` would hand them root's anyway).
- ``check`` runs under the **same identity** as the mutating ops (prd: 同身份)
  so observations match what install/remove would see. Caveat, accepted: a
  ``sudo: true`` check without a cached credential fails ``sudo -n`` and reads
  ABSENT — conservative (the run then hits the executor's per-step credential
  probe, which surfaces the real problem as a clean ``PrivilegeError``).

``check()`` state mapping: exit 0 -> PRESENT, any non-zero -> ABSENT. The
author's probe IS the contract — unlike dpkg there is no machine-readable
"real error" band to distinguish (a probe like ``some-tool --version`` exits
127 when the tool is absent), so every non-zero reads "not converged", which
errs toward attempting the install (whose failure is loud) rather than
faking convergence. ``script`` never returns OUTDATED (no version semantics;
``upgrade`` is a reserved field).
"""

from __future__ import annotations

from typing import Callable

from ..errors import CatalogError, ProviderError
from ..models import CatalogEntry
from ..privilege import Privilege
from ..runner import RunResult
from ..runner import run as default_run
from .apt import _INSTALL_TIMEOUT
from .base import Ctx, State


def shell_argv(command: str) -> "list[str]":
    """The controlled execution form for an author command string: argv list,
    ``shell=False`` at the runner, ``pipefail`` so a failed ``curl`` in the
    official ``curl … | sh`` idiom fails the step instead of vanishing."""
    return ["bash", "-o", "pipefail", "-c", command]


class ScriptProvider:
    type = "script"

    def __init__(self, run: "Callable[..., RunResult] | None" = None) -> None:
        # the single subprocess boundary, injected for testability
        self._run: Callable[..., RunResult] = run or default_run
        self._priv = Privilege(run=self._run)

    # -- field access -----------------------------------------------------------
    @staticmethod
    def _required(entry: CatalogEntry, field: str) -> str:
        value = entry.fields.get(field)
        if not value or not isinstance(value, str):
            # schema should prevent this; guard anyway
            raise CatalogError(
                f"script entry {entry.id!r} is missing required field {field!r}"
            )
        return value

    @staticmethod
    def _sudo(entry: CatalogEntry) -> bool:
        """The explicit privilege declaration (default: the plain user)."""
        return bool(entry.fields.get("sudo", False))

    def _extra_env(self, entry: CatalogEntry) -> "dict[str, str] | None":
        """Pin ``HOME`` to the real user's home for unprivileged commands, so
        ``$HOME`` in author commands stays authoritative even if the app was
        (against Rule 1) launched under sudo. Pointless for ``sudo: true``
        commands — sudo's ``env_reset`` strips the parent env, and root-level
        commands must not use ``$HOME`` at all."""
        if self._sudo(entry):
            return None
        return {"HOME": self._priv.real_home()}

    # -- protocol -------------------------------------------------------------
    def check(self, entry: CatalogEntry) -> State:
        res = self._run(
            shell_argv(self._required(entry, "check")),
            sudo=self._sudo(entry),
            extra_env=self._extra_env(entry),
        )
        return State.PRESENT if res.returncode == 0 else State.ABSENT

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        if ctx.check_mode:
            return  # dry-run mutation guard: make ZERO changes
        # official installers legitimately download hundreds of MB (the rust
        # toolchain / ollama bundle class) — the same widened cap as apt install
        res = ctx.run(
            shell_argv(self._required(entry, "install")),
            sudo=self._sudo(entry),
            extra_env=self._extra_env(entry),
            timeout=_INSTALL_TIMEOUT,
        )
        if res.returncode != 0:
            raise ProviderError(
                f"install command failed (exit {res.returncode})",
                entry_id=entry.id,
                stderr_tail=res.stderr[-500:],
            )

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        # the `remove` field is reserved by the schema but the op is deferred
        # (prd 06-11-provider-script: out of scope for this MVP slice)
        raise NotImplementedError("script remove is deferred in this MVP slice")

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("script upgrade is deferred in this MVP slice")
