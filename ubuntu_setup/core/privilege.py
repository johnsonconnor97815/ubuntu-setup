"""Privilege escalation & real-user resolution.

Rules (see ``.trellis/spec/core/privilege-and-safety.md``):

- Never run the whole app as root; escalate individual commands via ``sudo``
  (the runner's ``sudo=True`` variant).
- Resolve the real invoking user from ``SUDO_USER`` and the real home from the
  passwd DB — never ``~`` / ``$HOME`` / ``expanduser`` (which may be ``/root``
  under sudo).

This MVP slice validates ``sudo`` up front (``sudo -v``); the keep-alive daemon
thread and per-step ``-Nnv`` status probe are deferred (single-package runs).
"""

from __future__ import annotations

import os
import pwd
from typing import Callable

from .errors import PrivilegeError
from .runner import RunResult
from .runner import run as default_run


class Privilege:
    """Resolves the real user/home and acquires ``sudo`` up front."""

    def __init__(self, run: "Callable[..., RunResult] | None" = None) -> None:
        self._run: Callable[..., RunResult] = run or default_run

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

    def ensure_sudo(self) -> None:
        """Validate ``sudo`` up front (``sudo -v``); raise :class:`PrivilegeError`
        if the user is not a sudoer / the credential cannot be acquired.

        Routed through the runner (the single subprocess boundary). ``sudo`` reads
        any password from the controlling tty, so this works for a headless CLI;
        with no tty and no cached credential it fails cleanly to exit code 4.
        """
        # interactive validation: pass ``sudo -v`` as literal argv (NOT the
        # runner's non-interactive ``sudo -n`` variant, which could never prompt).
        res = self._run(["sudo", "-v"])
        if res.returncode != 0:
            raise PrivilegeError(
                "sudo is required but unavailable: `sudo -v` failed "
                f"(exit {res.returncode}). Are you a sudoer?"
            )
