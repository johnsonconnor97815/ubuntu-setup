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
- a **streaming variant** (:func:`run_streaming` / :class:`StreamingRun`) with
  the same contract, plus per-line ``on_line`` forwarding while the command
  runs and a thread-safe, escalating **programmatic terminate handle**
  (SIGTERM -> grace -> SIGKILL on the child's process group; a ``sudo=True``
  command is killed *through the runner boundary itself* — ``sudo -n kill``
  — because a normal user cannot signal a root child: kill(2) EPERM).
"""

from __future__ import annotations

import enum
import logging
import os
import shlex
import signal
import subprocess
import threading
import time
from dataclasses import dataclass
from typing import IO, Callable, Mapping, Sequence

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

#: how long :meth:`StreamingRun.terminate` waits after SIGTERM before
#: escalating to SIGKILL (injectable per run for tests).
TERMINATE_GRACE = 2.0


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


# --------------------------------------------------------------------------- #
# streaming variant + programmatic termination
# --------------------------------------------------------------------------- #
class TerminateOutcome(enum.Enum):
    """How a programmatic terminate request was handled.

    The consumer-visible cancel signal: "kill delivered" and "degraded wait"
    must stay distinguishable (the degraded path means the in-flight step runs
    to completion before the run stops — never silently swallowed).
    """

    TERMINATED = "terminated"  #: kill delivered (or the command had already finished)
    DEGRADED = "degraded"      #: cannot signal the escalated command — wait the step out
    IDLE = "idle"              #: no command in flight (a later one is killed on arrival)


def build_privileged_kill_argv(pgid: int, *, hard: bool = False) -> list[str]:
    """The argv that kills the process group of a ``sudo``-escalated command.

    A privileged step's child is ``sudo -n env ... apt-get`` — root for its
    whole life after authentication — and kill(2) forbids a normal user
    signalling a root process (the terminal's Ctrl-C only reaches it via the
    kernel's foreground-process-group delivery, which bypasses the uid check;
    programmatic signals get no such pass). So terminating a ``sudo=True``
    command escalates through the runner boundary itself:
    ``sudo -n kill [-9] -- -<pgid>``. Pure (like :func:`build_argv`) so tests
    cover the construction without running sudo.
    """
    sig = ["-9"] if hard else []
    return ["sudo", "-n", "kill", *sig, "--", f"-{pgid}"]


def _kill_process_group(
    pgid: int,
    sig: int,
    *,
    sudo: bool,
    kill_run: "Callable[..., RunResult]",
    logger: logging.Logger,
) -> bool:
    """Deliver ``sig`` to a streaming command's process group; ``False`` means
    the signal could not be delivered (the **degraded** path).

    For a ``sudo=True`` command the privileged kill runs first (through
    ``kill_run`` — the runner boundary, so it is audit-logged like any other
    command); on failure (e.g. a lapsed ``sudo -n`` credential) we still try a
    direct ``killpg`` — the command may never have escalated (sudo failed
    before exec) — before reporting degradation.
    """
    if sudo:
        argv = build_privileged_kill_argv(pgid, hard=(sig == signal.SIGKILL))
        try:
            res = kill_run(argv)
        except OSError as exc:
            logger.warning("privileged kill could not run: %s", exc)
        else:
            if res.returncode == 0:
                return True
            logger.warning(
                "privileged kill failed (rc=%d): %s", res.returncode, shlex.join(argv)
            )
    try:
        os.killpg(pgid, sig)
        return True
    except ProcessLookupError:
        return True  # the group is already gone — nothing left to kill
    except PermissionError:
        logger.warning(
            "cannot signal process group %d (EPERM — escalated child); "
            "waiting for the command to finish", pgid,
        )
        return False


class StreamingRun:
    """One live external command: the same runner contract as :func:`run`
    (argv list + ``shell=False``, forced non-interactive env, ``shlex.join``
    audit log, total-duration timeout), plus:

    - **per-line forwarding**: ``on_line(line, stream)`` is invoked from
      internal reader threads as each line arrives (``stream`` is
      ``"stdout"`` | ``"stderr"``; the trailing newline is stripped).
      Backpressure is the callback's: blocking in ``on_line`` blocks the pipe
      (and eventually the child), never an unbounded buffer here. A callback
      that *raises* is a consumer bug: it is never swallowed — the pipe keeps
      draining (without forwarding) so the child still finishes and is reaped,
      then :meth:`wait` re-raises the exception.
    - **programmatic termination**: the child starts in a new session (its own
      process group), so :meth:`terminate` can signal the whole group without
      touching us — including from another thread while :meth:`wait` blocks.

    :meth:`wait` returns the same aggregated :class:`RunResult` as :func:`run`
    (``returncode``/``stdout``/``stderr``/``duration``), so provider decision
    contracts (branch on rc, stderr tail) do not change.
    """

    def __init__(
        self,
        argv: Sequence[str],
        *,
        sudo: bool = False,
        timeout: "float | None" = DEFAULT_TIMEOUT,
        extra_env: "Mapping[str, str] | None" = None,
        logger: "logging.Logger | None" = None,
        on_line: "Callable[[str, str], None] | None" = None,
        grace: float = TERMINATE_GRACE,
        kill_run: "Callable[..., RunResult] | None" = None,
    ) -> None:
        self._log = logger or _LOG
        self._sudo = sudo
        self._timeout = timeout
        self._grace = grace
        self._on_line = on_line
        self._kill_run = kill_run or run  # the privileged-kill path's runner seam
        self.argv = build_argv(argv, sudo=sudo)
        self._log.info("run: %s", shlex.join(self.argv))  # audit trail
        self._start = time.monotonic()
        self._proc = subprocess.Popen(
            self.argv,
            shell=False,
            env=_build_env(extra_env),
            stdin=subprocess.DEVNULL,  # non-interactive: never read our terminal
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            start_new_session=True,  # own process group -> killable as a unit
        )
        self._stdout_parts: list[str] = []
        self._stderr_parts: list[str] = []
        #: first exception raised by ``on_line`` (a consumer bug) — re-raised
        #: from :meth:`wait` so it is never swallowed (benign write race: with
        #: two readers either exception surfacing is acceptable)
        self._callback_exc: "BaseException | None" = None
        self._readers = [
            threading.Thread(
                target=self._read,
                args=(self._proc.stdout, "stdout", self._stdout_parts),
                name="ubuntu-setup-stdout-reader",
                daemon=True,
            ),
            threading.Thread(
                target=self._read,
                args=(self._proc.stderr, "stderr", self._stderr_parts),
                name="ubuntu-setup-stderr-reader",
                daemon=True,
            ),
        ]
        for t in self._readers:
            t.start()
        self._terminate_lock = threading.Lock()
        self._terminate_outcome: "TerminateOutcome | None" = None

    @property
    def pid(self) -> int:
        """The child's pid — also its pgid (``start_new_session=True``)."""
        return self._proc.pid

    def _read(self, pipe: "IO[str]", stream: str, parts: "list[str]") -> None:
        forward = self._on_line
        try:
            for line in pipe:
                parts.append(line)
                if forward is not None:
                    try:
                        forward(line.rstrip("\n"), stream)
                    except BaseException as exc:
                        # A broken callback must neither be swallowed nor hang
                        # the child: letting it escape would close the pipe and
                        # SIGPIPE-kill the child mid-write (a misleading rc),
                        # while merely stopping the read would block the child
                        # on a full pipe. So record the bug (re-raised by
                        # wait()) and keep draining without forwarding.
                        if self._callback_exc is None:
                            self._callback_exc = exc
                        forward = None
        finally:
            pipe.close()

    def _remaining(self) -> "float | None":
        if self._timeout is None:
            return None
        return max(self._start + self._timeout - time.monotonic(), 0.0)

    # -- termination ----------------------------------------------------------
    def terminate(self) -> TerminateOutcome:
        """Kill the command's process group: SIGTERM -> ``grace`` -> SIGKILL.

        Thread-safe and idempotent: a delivered kill is cached; a
        :attr:`TerminateOutcome.DEGRADED` outcome is *not* cached, so a retry
        (e.g. after the consumer re-acquired the sudo credential) attempts the
        kill again. A ``sudo=True`` command is signalled via the privileged
        kill (``sudo -n kill -- -<pgid>``, audit-logged through the runner);
        when that fails the outcome is DEGRADED — the command runs on and the
        caller must wait the step out.
        """
        with self._terminate_lock:
            if self._terminate_outcome is TerminateOutcome.TERMINATED:
                return self._terminate_outcome
            outcome = self._do_terminate()
            self._terminate_outcome = outcome
            return outcome

    def _do_terminate(self) -> TerminateOutcome:
        if self._group_finished():
            return TerminateOutcome.TERMINATED  # already fully finished
        if not self._signal_group(signal.SIGTERM):
            return TerminateOutcome.DEGRADED
        if self._await_group(self._grace):
            return TerminateOutcome.TERMINATED
        self._log.warning(
            "terminate: %s ignored SIGTERM for %.1fs; escalating to SIGKILL",
            shlex.join(self.argv), self._grace,
        )
        if not self._signal_group(signal.SIGKILL):
            return TerminateOutcome.DEGRADED
        return TerminateOutcome.TERMINATED

    def _group_finished(self) -> bool:
        """The leader exited AND the readers hit EOF (no surviving group
        member holds the pipes open)."""
        return self._proc.poll() is not None and not any(t.is_alive() for t in self._readers)

    def _await_group(self, grace: float) -> bool:
        """``True`` once the whole *group* is done within ``grace`` seconds.

        The leader dying alone is not enough to call a SIGTERM successful: a
        surviving group member (e.g. a spawned helper) can ignore SIGTERM
        while holding the pipes open — judging by the leader would skip the
        SIGKILL escalation and leave it running (and :meth:`wait` blocked
        until the total-duration timeout)."""
        deadline = time.monotonic() + grace
        try:
            self._proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            return False
        for t in self._readers:
            t.join(timeout=max(deadline - time.monotonic(), 0.0))
        return not any(t.is_alive() for t in self._readers)

    def _signal_group(self, sig: int) -> bool:
        return _kill_process_group(
            self._proc.pid, sig, sudo=self._sudo,
            kill_run=self._kill_run, logger=self._log,
        )

    # -- completion -----------------------------------------------------------
    def wait(self) -> RunResult:
        """Block until the command finishes; return the aggregated result.

        The timeout is **total duration** (decided: same semantics as
        :func:`run`): when it expires the process group is killed via
        :meth:`terminate` and the result reports ``returncode ==
        TIMEOUT_RETURNCODE`` (124) instead of raising. A degraded termination
        (an escalated child we cannot signal) waits the command out and still
        reports 124.

        The one thing that *does* raise: an exception from the consumer's
        ``on_line`` callback (a bug, not a command failure) is re-raised here
        after the child has been drained and reaped — never swallowed into a
        misleading ``RunResult``.
        """
        timed_out = False
        try:
            self._proc.wait(timeout=self._remaining())
        except subprocess.TimeoutExpired:
            timed_out = True
        if not timed_out:
            # the process exited; readers finish at pipe EOF — but an orphaned
            # grandchild can hold the pipes open, so the total-duration
            # deadline applies to the drain as well
            for t in self._readers:
                t.join(timeout=self._remaining())
            if any(t.is_alive() for t in self._readers):
                timed_out = True
        if timed_out:
            self.terminate()   # escalating group kill (sudo-aware)
            self._proc.wait()  # degraded path: cannot kill -> wait it out
            for t in self._readers:
                t.join(timeout=self._grace)
            if any(t.is_alive() for t in self._readers):  # pragma: no cover - orphan surviving SIGKILL
                self._log.warning(
                    "output readers still blocked after kill; output may be truncated"
                )

        if self._callback_exc is not None:
            raise self._callback_exc  # consumer-callback bug: propagate, don't mask

        duration = time.monotonic() - self._start
        stdout = "".join(self._stdout_parts)
        stderr = "".join(self._stderr_parts)
        if timed_out:
            stderr += f"\n[timeout after {self._timeout}s]"
            self._log.warning("timeout: %s (%.1fs)", shlex.join(self.argv), duration)
            return RunResult(self.argv, TIMEOUT_RETURNCODE, stdout, stderr, duration)
        self._log.info("done: rc=%d (%.1fs)", self._proc.returncode, duration)
        return RunResult(self.argv, self._proc.returncode, stdout, stderr, duration)


def run_streaming(
    argv: Sequence[str],
    *,
    sudo: bool = False,
    timeout: "float | None" = DEFAULT_TIMEOUT,
    extra_env: "Mapping[str, str] | None" = None,
    logger: "logging.Logger | None" = None,
    on_line: "Callable[[str, str], None] | None" = None,
    on_start: "Callable[[StreamingRun], None] | None" = None,
    grace: float = TERMINATE_GRACE,
    kill_run: "Callable[..., RunResult] | None" = None,
) -> RunResult:
    """Run ``argv`` with live per-line output; return the aggregated result.

    Same decision contract as :func:`run` (branch on ``returncode``; a timeout
    yields ``TIMEOUT_RETURNCODE`` without raising). ``on_line(line, stream)``
    fires as each output line arrives; ``on_start(handle)`` publishes the
    :class:`StreamingRun` before blocking, so another thread can
    ``handle.terminate()`` the command mid-flight (the cancel seam).
    """
    handle = StreamingRun(
        argv, sudo=sudo, timeout=timeout, extra_env=extra_env, logger=logger,
        on_line=on_line, grace=grace, kill_run=kill_run,
    )
    try:
        if on_start is not None:
            on_start(handle)
    except BaseException:
        # a broken on_start is a consumer bug: propagate it, but never leak an
        # unreaped child behind it
        handle.terminate()
        handle.wait()
        raise
    return handle.wait()


class InFlightCommand:
    """Thread-safe slot publishing the terminate handle of the command
    currently running inside a step — the seam ``ApplyHandle.cancel()``
    reaches through (from the consumer's thread) into the bridge worker's
    in-flight :class:`StreamingRun`.

    Once :meth:`terminate` has been requested, any command published *later*
    in the same scope is killed on arrival — a cancel that lands between two
    commands of one step (or just before the step's first command starts)
    still kills the step instead of racing past it.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._handle: "StreamingRun | None" = None
        self._kill_requested = False

    def publish(self, handle: "StreamingRun") -> None:
        with self._lock:
            self._handle = handle
            kill = self._kill_requested
        if kill:
            handle.terminate()

    def clear(self) -> None:
        with self._lock:
            self._handle = None

    def terminate(self) -> TerminateOutcome:
        with self._lock:
            self._kill_requested = True
            handle = self._handle
        if handle is None:
            return TerminateOutcome.IDLE
        return handle.terminate()
