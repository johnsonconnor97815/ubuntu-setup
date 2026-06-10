"""Privilege escalation & real-user resolution.

Rules (see ``.trellis/spec/core/privilege-and-safety.md``):

- Never run the whole app as root; escalate individual commands via ``sudo``
  (the runner's ``sudo=True`` variant).
- Resolve the real invoking user from ``SUDO_USER`` and the real home from the
  passwd DB — never ``~`` / ``$HOME`` / ``expanduser`` (which may be ``/root``
  under sudo).
- Acquire ``sudo`` up front, keep it alive, probe before each step (Rule 2):

  - :meth:`Privilege.probe_credentials` — the **silent probe**: read the
    cached-credential state via ``sudo -Nnv`` (no prompt, no TTL reset; ``-N``
    needs sudo >= 1.9.12, detected once via ``sudo -h`` and cached), falling
    back to ``sudo -n true`` on a stock 22.04 (renews the TTL — the
    spec-acknowledged cost). Returns an explicit :class:`CredentialStatus`,
    never a bare bool tri-state.
  - :meth:`Privilege.ensure_sudo` — interactive validation up front
    (``sudo -v``); with no tty and no cached credential it fails cleanly to
    :class:`PrivilegeError` (exit 4).
  - :meth:`Privilege.ensure_sudo_noninteractive` — the **per-step probe**
    (``sudo -n true``): a lapsed credential raises :class:`PrivilegeError`
    instead of letting a password prompt ambush the consumer mid-run.
  - :meth:`Privilege.keepalive` / :class:`SudoKeepalive` — daemon thread
    refreshing the credential under the 5-minute sudoers TTL while an apply
    runs; lifecycle is owned by ``core/service.py``.

Every command goes through the injected runner seam (the single subprocess
boundary, non-negotiable #5) — never bare ``subprocess``.
"""

from __future__ import annotations

import enum
import os
import pwd
import threading
from typing import Callable

from .errors import PrivilegeError
from .runner import RunResult
from .runner import run as default_run

#: keep-alive refresh period — comfortably under the sudoers default 5-minute
#: credential TTL (the spec's example value).
KEEPALIVE_INTERVAL = 50.0


class CredentialStatus(enum.Enum):
    """Result of the silent credential probe (:meth:`Privilege.probe_credentials`).

    An explicit enum rather than a bool tri-state: consumers branch on it to
    decide whether interactive validation is needed before an apply.
    """

    CACHED = "cached"  #: escalation will run silently (cached timestamp or NOPASSWD)
    NONE = "none"  #: no usable cached credential — interactive validation required
    UNAVAILABLE = "unavailable"  #: the probe itself could not run (sudo missing/broken)


class SudoKeepalive:
    """Refresh the cached ``sudo`` credential while an apply runs (Rule 2).

    A daemon thread runs ``sudo -n true`` every ``interval`` seconds (< the
    5-minute sudoers TTL) through the runner seam. :meth:`stop` sets the stop
    ``Event`` (the wait returns immediately) and joins the thread;
    ``daemon=True`` still guarantees the thread dies with the process if
    cleanup is skipped. Lifecycle is owned by ``core/service.py``: started for
    a real apply (never a dry run / empty plan), stopped in the event stream's
    ``finally`` — including on cancel, close, and a crash.
    """

    def __init__(
        self,
        run: Callable[..., RunResult],
        *,
        interval: float = KEEPALIVE_INTERVAL,
    ) -> None:
        self._run = run
        self._interval = interval
        self._stop = threading.Event()
        self._thread: "threading.Thread | None" = None

    def start(self) -> None:
        """Start the refresh thread (idempotent while running)."""
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._loop, name="ubuntu-setup-sudo-keepalive", daemon=True
        )
        self._thread.start()

    def _loop(self) -> None:
        while not self._stop.wait(self._interval):
            # a failed refresh is not fatal here: the per-step probe
            # (ensure_sudo_noninteractive) is what surfaces a lapsed credential
            self._run(["sudo", "-n", "true"])

    def stop(self) -> None:
        """Stop and join the thread (idempotent; safe if never started)."""
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
            self._thread = None


class Privilege:
    """Resolves the real user/home and owns the ``sudo`` credential strategy."""

    def __init__(self, run: "Callable[..., RunResult] | None" = None) -> None:
        self._run: Callable[..., RunResult] = run or default_run
        #: one-time `-N` support detection result (sudo >= 1.9.12); None = unknown
        self._supports_no_update: "bool | None" = None

    def real_user(self) -> tuple[str, int, int]:
        """(name, uid, gid) of the real invoker, even when running under sudo."""
        if os.geteuid() == 0 and os.environ.get("SUDO_USER"):
            name = os.environ["SUDO_USER"]
            return name, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"])
        pw = pwd.getpwuid(os.getuid())
        return pw.pw_name, pw.pw_uid, pw.pw_gid

    def real_home(self, name: str | None = None) -> str:
        """The real user's home from the passwd DB — authoritative, NOT ``~``."""
        if name is None:
            name = self.real_user()[0]
        return pwd.getpwnam(name).pw_dir

    # -- credential strategy (spec Rule 2) ------------------------------------

    def probe_credentials(self) -> CredentialStatus:
        """Silently read the cached-credential state — **never prompts**.

        Uses ``sudo -Nnv`` where supported so the probe does not reset the
        5-minute TTL (plain ``sudo -nv`` would silently re-extend it). ``-N``
        was added in sudo 1.9.12 (24.04 yes, stock 22.04 no): support is
        detected once via ``sudo -h`` and cached; without it we fall back to
        ``sudo -n true`` (renews the TTL — the spec-acknowledged 22.04 cost).
        NOPASSWD users probe as :attr:`CredentialStatus.CACHED` (validation
        succeeds without a password).
        """
        try:
            res = self._run(self._probe_argv())
        except OSError:
            return CredentialStatus.UNAVAILABLE
        return CredentialStatus.CACHED if res.returncode == 0 else CredentialStatus.NONE

    def _probe_argv(self) -> list[str]:
        if self._supports_no_update is None:
            # the spec's `sudo -h 2>&1 | grep -q -- -N`, via the runner: read
            # both output streams for the `-N, --no-update` flag
            res = self._run(["sudo", "-h"])
            self._supports_no_update = "-N" in (res.stdout + res.stderr)
        if self._supports_no_update:
            return ["sudo", "-Nnv"]  # read-only: does NOT extend the TTL
        return ["sudo", "-n", "true"]  # 22.04 fallback (renews the TTL)

    def ensure_sudo(self) -> None:
        """Validate ``sudo`` up front (``sudo -v``); raise :class:`PrivilegeError`
        if the user is not a sudoer / the credential cannot be acquired.

        Routed through the runner (the single subprocess boundary). ``sudo`` reads
        any password from the controlling tty, so this works for a headless CLI;
        with no tty and no cached credential it fails cleanly to exit code 4.
        """
        # interactive validation: pass ``sudo -v`` as literal argv (NOT the
        # runner's non-interactive ``sudo -n`` variant, which could never prompt).
        try:
            res = self._run(["sudo", "-v"])
        except OSError as exc:
            raise PrivilegeError(f"sudo is required but could not be run: {exc}") from exc
        if res.returncode != 0:
            raise PrivilegeError(
                "sudo is required but unavailable: `sudo -v` failed "
                f"(exit {res.returncode}). Are you a sudoer?"
            )

    def ensure_sudo_noninteractive(self) -> None:
        """The per-step probe (Rule 2): assert the next escalation runs without
        prompting (``sudo -n true``, exit 0 ⇒ silent).

        A lapsed/absent credential raises :class:`PrivilegeError` (exit-4
        semantics) — the clean "interactive escalation required" signal —
        instead of letting ``sudo`` surprise the consumer with a password
        prompt mid-run. Note the probe deliberately renews the TTL (unlike
        :meth:`probe_credentials`); during an apply that is desirable.
        """
        try:
            res = self._run(["sudo", "-n", "true"])
        except OSError as exc:
            raise PrivilegeError(f"sudo is required but could not be run: {exc}") from exc
        if res.returncode != 0:
            raise PrivilegeError(
                "sudo credential expired or unavailable (`sudo -n true` exited "
                f"{res.returncode}); interactive escalation required (`sudo -v`)"
            )

    def keepalive(self, *, interval: float = KEEPALIVE_INTERVAL) -> SudoKeepalive:
        """A :class:`SudoKeepalive` bound to this instance's runner seam."""
        return SudoKeepalive(self._run, interval=interval)
