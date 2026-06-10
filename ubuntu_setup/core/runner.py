"""The ONE subprocess boundary.

Every external command — in providers, the privilege helper, state queries —
goes through :func:`run`. No bare ``subprocess.run`` / ``os.system`` /
``shell=True`` elsewhere (see ``.trellis/spec/core/error-and-logging.md``).

Guarantees:
- argv list, ``shell=False`` (never build a shell string from entry fields).
- a forced non-interactive, parseable environment (``DEBIAN_FRONTEND`` etc.,
  ``LC_ALL=C``) that callers can extend but not drop.
- a privileged variant that prefixes ``sudo -n`` and *re-asserts* the forced
  env inside the sudo invocation (sudo's ``env_reset`` strips the parent's).
- captured output + timeout, returning a small :class:`RunResult`.
- the exact argv logged before running (the audit trail).
"""

from __future__ import annotations

import logging
import os
import shlex
import subprocess
import time
from dataclasses import dataclass
from typing import Mapping, Sequence

from .errors import UserAbort

_LOG = logging.getLogger("ubuntu_setup.runner")

#: forced env applied last so callers cannot drop it. Single source of truth for
#: both the non-sudo env and the ``VAR=val`` prefix re-asserted inside sudo.
FORCED_ENV: dict[str, str] = {
    "DEBIAN_FRONTEND": "noninteractive",
    "DEBIAN_PRIORITY": "critical",
    "LC_ALL": "C",
    "LANG": "C",
}

#: exit code used to signal a timeout (mirrors the shell's 128+SIGKILL-ish 124).
TIMEOUT_RETURNCODE = 124

DEFAULT_TIMEOUT = 600.0


@dataclass(frozen=True)
class RunResult:
    """The result of one external command. Decisions branch on ``returncode``."""

    argv: list[str]
    returncode: int
    stdout: str
    stderr: str
    duration: float

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def build_argv(argv: Sequence[str], *, sudo: bool) -> list[str]:
    """Construct the final argv. For the privileged variant, prefix ``sudo -n``
    and re-assert the forced env *inside* sudo via ``env(1)`` (testable without
    running sudo).

    We wrap with ``env`` rather than the bare ``sudo VAR=val cmd`` form because
    the latter requires the sudoers ``setenv`` option / a ``SETENV`` tag (only
    implied when the matched command is ``ALL``); under a restricted sudoers it
    fails with "not allowed to set the following environment variables". Passing
    the variables as arguments to ``env`` is not subject to sudo's env
    restrictions and works for every sudoers configuration. Verified against
    sudoers(5)/sudo(8)."""
    cmd = list(argv)
    if not sudo:
        return cmd
    env_prefix = [f"{k}={v}" for k, v in FORCED_ENV.items()]
    return ["sudo", "-n", "env", *env_prefix, *cmd]


def _build_env(extra_env: Mapping[str, str] | None) -> dict[str, str]:
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    # forced keys win last — callers can add (e.g. HOME) but never drop these
    env.update(FORCED_ENV)
    return env


def run(
    argv: Sequence[str],
    *,
    sudo: bool = False,
    timeout: float | None = DEFAULT_TIMEOUT,
    extra_env: Mapping[str, str] | None = None,
    logger: logging.Logger | None = None,
) -> RunResult:
    """Run ``argv`` and return a :class:`RunResult`.

    Does not raise on a non-zero exit — callers branch on ``returncode`` (the
    ``check()`` "absent vs errored" distinction lives in the provider). A
    timeout yields ``returncode == TIMEOUT_RETURNCODE`` rather than raising, so
    a provider surfaces it as a normal command failure.

    ``KeyboardInterrupt`` (Ctrl-C) aborts the run as :class:`UserAbort`; the
    child shares our process group and receives the terminal's SIGINT.
    """
    log = logger or _LOG
    final_argv = build_argv(argv, sudo=sudo)
    env = _build_env(extra_env)

    log.info("run: %s", shlex.join(final_argv))  # audit trail: exact argv, unambiguously quoted
    start = time.monotonic()
    try:
        proc = subprocess.run(
            final_argv,
            shell=False,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        duration = time.monotonic() - start
        stdout = exc.stdout or ""
        stderr = (exc.stderr or "") + f"\n[timeout after {timeout}s]"
        if isinstance(stdout, bytes):
            stdout = stdout.decode(errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        log.warning("timeout: %s (%.1fs)", shlex.join(final_argv), duration)
        return RunResult(final_argv, TIMEOUT_RETURNCODE, stdout, stderr, duration)
    except KeyboardInterrupt as exc:  # pragma: no cover - interactive only
        raise UserAbort("interrupted (SIGINT)") from exc

    duration = time.monotonic() - start
    log.info("done: rc=%d (%.1fs)", proc.returncode, duration)
    return RunResult(final_argv, proc.returncode, proc.stdout, proc.stderr, duration)
