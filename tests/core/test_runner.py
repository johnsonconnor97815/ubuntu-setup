"""Runner tests — use real, harmless commands (no sudo) plus pure argv building.

Streaming/termination tests run real ``python3 -c`` children, driven by
synchronization primitives (a flag file the consumer creates, line events)
rather than sleeps, so they cannot flake; the privileged-kill path is covered
via the pure argv builder and a fake ``kill_run`` (sudo never really runs).
"""

from __future__ import annotations

import os
import signal
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

from ubuntu_setup.core import runner
from ubuntu_setup.core.runner import (
    InFlightCommand,
    StreamingRun,
    TerminateOutcome,
    build_argv,
    build_privileged_kill_argv,
    run_streaming,
)
from tests._fakes import FakeRun


class TestRunner(unittest.TestCase):
    def test_success_captures_stdout(self):
        res = runner.run(["printf", "%s", "hello"])
        self.assertTrue(res.ok)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout, "hello")

    def test_nonzero_does_not_raise(self):
        res = runner.run(["false"])
        self.assertFalse(res.ok)
        self.assertNotEqual(res.returncode, 0)

    def test_forced_env_is_applied(self):
        res = runner.run(["sh", "-c", 'printf %s "$LC_ALL"'])
        self.assertEqual(res.stdout, "C")

    def test_extra_env_cannot_drop_forced(self):
        res = runner.run(
            ["sh", "-c", 'printf %s "$LC_ALL"'],
            extra_env={"LC_ALL": "en_US.UTF-8"},
        )
        self.assertEqual(res.stdout, "C")  # forced env wins last

    def test_timeout_yields_timeout_returncode(self):
        res = runner.run(["sleep", "5"], timeout=0.2)
        self.assertEqual(res.returncode, runner.TIMEOUT_RETURNCODE)

    def test_build_argv_no_sudo_is_identity(self):
        self.assertEqual(build_argv(["echo", "hi"], sudo=False), ["echo", "hi"])

    def test_build_argv_sudo_wraps_with_env_and_reasserts(self):
        argv = build_argv(["apt-get", "install", "-y", "rg"], sudo=True)
        # wrap with `env` (robust across sudoers configs; not bare `sudo VAR=val`)
        self.assertEqual(argv[:3], ["sudo", "-n", "env"])
        self.assertIn("DEBIAN_FRONTEND=noninteractive", argv)
        self.assertIn("DEBIAN_PRIORITY=critical", argv)
        self.assertIn("LC_ALL=C", argv)
        # the original command is preserved, in order, at the end
        self.assertEqual(argv[-4:], ["apt-get", "install", "-y", "rg"])


PY = sys.executable or "python3"


class TestRunStreaming(unittest.TestCase):
    """The streaming variant: live lines, aggregate equivalence, timeout."""

    def test_lines_arrive_while_the_command_runs(self):
        """Liveness proof by causality: the child exits 0 ONLY if the flag
        file appears while it runs — and only the on_line callback creates it.
        A buffered-replay implementation (lines after exit) must exit 7."""
        code = (
            "import os, sys, time\n"
            "print('one', flush=True)\n"
            "for _ in range(1000):\n"
            "    if os.path.exists(sys.argv[1]):\n"
            "        print('two', flush=True)\n"
            "        sys.exit(0)\n"
            "    time.sleep(0.01)\n"
            "sys.exit(7)\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            flag = Path(tmp) / "consumer-saw-one"
            seen: "list[tuple[str, str]]" = []

            def on_line(line: str, stream: str) -> None:
                seen.append((line, stream))
                if line == "one":
                    flag.touch()

            res = run_streaming([PY, "-c", code, str(flag)], on_line=on_line)

        self.assertEqual(res.returncode, 0)  # 7 would mean: lines were not live
        self.assertEqual(seen, [("one", "stdout"), ("two", "stdout")])
        self.assertEqual(res.stdout, "one\ntwo\n")  # aggregate still complete

    def test_aggregate_result_matches_run_contract(self):
        """rc / stdout / stderr / duration keep the RunResult decision contract
        (providers branch on rc and read the stderr tail)."""
        code = "import sys; print('out'); print('err', file=sys.stderr); sys.exit(3)"
        seen: "list[tuple[str, str]]" = []
        res = run_streaming([PY, "-c", code], on_line=lambda l, s: seen.append((l, s)))
        self.assertEqual(res.returncode, 3)
        self.assertFalse(res.ok)
        self.assertEqual(res.stdout, "out\n")
        self.assertEqual(res.stderr, "err\n")
        self.assertGreaterEqual(res.duration, 0.0)
        self.assertIn(("out", "stdout"), seen)
        self.assertIn(("err", "stderr"), seen)

    def test_forced_env_is_applied(self):
        res = run_streaming(["sh", "-c", 'printf "%s\\n" "$LC_ALL"'])
        self.assertEqual(res.stdout, "C\n")

    def test_timeout_returns_124_and_reaps_the_child(self):
        handles: "list[StreamingRun]" = []
        code = "import time; print('x', flush=True); time.sleep(30)"
        res = run_streaming(
            [PY, "-c", code], timeout=0.5, grace=0.2, on_start=handles.append,
        )
        self.assertEqual(res.returncode, runner.TIMEOUT_RETURNCODE)
        self.assertIn("[timeout after", res.stderr)
        self.assertIn("x\n", res.stdout)        # output up to the kill is kept
        self.assertLess(res.duration, 25.0)     # did not wait out the sleep
        (handle,) = handles
        with self.assertRaises(ProcessLookupError):
            os.kill(handle.pid, 0)              # the child is gone (reaped group)

    def test_terminate_escalates_term_grace_kill(self):
        """A child ignoring SIGTERM is SIGKILLed after the grace period."""
        code = (
            "import signal, sys, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('ready', flush=True)\n"
            "time.sleep(30)\n"
        )
        ready = threading.Event()

        def on_line(line: str, stream: str) -> None:
            if line == "ready":
                ready.set()  # the SIGTERM handler is installed by now

        handle = StreamingRun([PY, "-c", code], on_line=on_line, grace=0.3)
        self.assertTrue(ready.wait(timeout=10.0))
        self.assertIs(handle.terminate(), TerminateOutcome.TERMINATED)
        res = handle.wait()
        self.assertEqual(res.returncode, -signal.SIGKILL)  # escalation happened
        self.assertLess(res.duration, 25.0)

    def test_terminate_compliant_child_stops_at_sigterm(self):
        ready = threading.Event()
        handle = StreamingRun(
            [PY, "-c", "import time; print('go', flush=True); time.sleep(30)"],
            on_line=lambda l, s: ready.set(), grace=5.0,
        )
        self.assertTrue(ready.wait(timeout=10.0))
        self.assertIs(handle.terminate(), TerminateOutcome.TERMINATED)
        res = handle.wait()
        self.assertEqual(res.returncode, -signal.SIGTERM)  # no escalation needed

    def test_on_line_exception_is_reraised_not_swallowed(self):
        """A broken consumer callback is a bug: it must surface from wait()
        (never a misleading RunResult), and the child must still be drained —
        not deadlocked on a full pipe, not SIGPIPE-killed mid-write."""
        flood = (
            "import sys\n"
            "print('one', flush=True)\n"
            "for i in range(200000):\n"          # far beyond the 64 KiB pipe buffer
            "    sys.stdout.write('x%d\\n' % i)\n"
        )

        def boom(line: str, stream: str) -> None:
            raise RuntimeError("consumer bug")

        t0 = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, "consumer bug"):
            run_streaming([PY, "-c", flood], on_line=boom, timeout=30)
        # the child was drained and finished — no waiting out the timeout
        self.assertLess(time.monotonic() - t0, 20.0)

    def test_terminate_escalates_when_group_member_survives_leader(self):
        """The leader dying alone is not a successful SIGTERM: a group member
        that ignores SIGTERM (and holds the pipes) must still be SIGKILLed
        after the grace period — not left running until the total timeout."""
        grandchild = (
            "import signal, sys, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('g-ready', flush=True)\n"
            "time.sleep(30)\n"
        )
        code = (
            "import subprocess, sys\n"
            f"subprocess.Popen([sys.executable, '-c', {grandchild!r}])\n"
            # the leader exits at once; the grandchild inherits group + pipes
        )
        ready = threading.Event()

        def on_line(line: str, stream: str) -> None:
            if line == "g-ready":
                ready.set()  # the grandchild's SIGTERM handler is installed

        handle = StreamingRun([PY, "-c", code], grace=0.3, timeout=60,
                              on_line=on_line)
        self.assertTrue(ready.wait(timeout=10.0))
        self.assertIs(handle.terminate(), TerminateOutcome.TERMINATED)
        res = handle.wait()
        self.assertEqual(res.returncode, 0)   # the leader itself exited cleanly
        self.assertLess(res.duration, 25.0)   # the grandchild did not sleep out

    def test_terminate_degraded_when_group_cannot_be_signalled(self):
        """EPERM on killpg (the escalated-child wall, faked here) is reported
        as DEGRADED — visibly — and the command runs on until finished."""
        ready = threading.Event()
        handle = StreamingRun(
            [PY, "-c", "import time; print('go', flush=True); time.sleep(30)"],
            on_line=lambda l, s: ready.set(), grace=0.2,
        )
        self.assertTrue(ready.wait(timeout=10.0))
        with mock.patch.object(runner.os, "killpg", side_effect=PermissionError):
            self.assertIs(handle.terminate(), TerminateOutcome.DEGRADED)
        # DEGRADED is not cached: a retry (here: unpatched) attempts the kill again
        self.assertIs(handle.terminate(), TerminateOutcome.TERMINATED)
        res = handle.wait()
        self.assertNotEqual(res.returncode, 0)


class TestPrivilegedKill(unittest.TestCase):
    """The sudo kill path — pure argv construction + fake kill_run routing
    (no real sudo, mirroring the build_argv test strategy)."""

    def test_build_privileged_kill_argv_term(self):
        self.assertEqual(build_privileged_kill_argv(1234),
                         ["sudo", "-n", "kill", "--", "-1234"])

    def test_build_privileged_kill_argv_kill(self):
        self.assertEqual(build_privileged_kill_argv(1234, hard=True),
                         ["sudo", "-n", "kill", "-9", "--", "-1234"])

    def test_sudo_kill_goes_through_the_runner_boundary(self):
        """sudo=True routes the signal through kill_run (audit-logged runner
        path), never a direct killpg when the privileged kill succeeds."""
        kill_run = FakeRun()  # rc 0: privileged kill succeeds
        with mock.patch.object(runner.os, "killpg") as killpg:
            ok = runner._kill_process_group(
                99999999, signal.SIGTERM, sudo=True,
                kill_run=kill_run, logger=runner._LOG,
            )
        self.assertTrue(ok)
        killpg.assert_not_called()
        self.assertEqual(kill_run.calls[0].argv,
                         ["sudo", "-n", "kill", "--", "-99999999"])

    def test_sudo_kill_failure_degrades_when_direct_kill_is_eperm(self):
        """Lapsed `sudo -n` + EPERM on the direct fallback = the degraded
        path: the signal is NOT delivered and the caller is told so."""
        kill_run = FakeRun(default_rc=1)  # credential lapsed: sudo -n kill fails
        with mock.patch.object(runner.os, "killpg", side_effect=PermissionError):
            ok = runner._kill_process_group(
                99999999, signal.SIGKILL, sudo=True,
                kill_run=kill_run, logger=runner._LOG,
            )
        self.assertFalse(ok)
        self.assertEqual(kill_run.calls[0].argv,
                         ["sudo", "-n", "kill", "-9", "--", "-99999999"])

    def test_dead_group_counts_as_delivered(self):
        """A group that is already gone is success, not degradation."""
        kill_run = FakeRun(default_rc=1)
        with mock.patch.object(runner.os, "killpg", side_effect=ProcessLookupError):
            ok = runner._kill_process_group(
                99999999, signal.SIGTERM, sudo=True,
                kill_run=kill_run, logger=runner._LOG,
            )
        self.assertTrue(ok)

    def test_non_sudo_kill_never_calls_kill_run(self):
        kill_run = FakeRun()
        with mock.patch.object(runner.os, "killpg") as killpg:
            ok = runner._kill_process_group(
                4242, signal.SIGTERM, sudo=False,
                kill_run=kill_run, logger=runner._LOG,
            )
        self.assertTrue(ok)
        killpg.assert_called_once_with(4242, signal.SIGTERM)
        self.assertEqual(kill_run.calls, [])


class _FakeHandle:
    def __init__(self, outcome=TerminateOutcome.TERMINATED):
        self.terminated = 0
        self._outcome = outcome

    def terminate(self):
        self.terminated += 1
        return self._outcome


class TestInFlightCommand(unittest.TestCase):
    def test_terminate_with_nothing_in_flight_is_idle(self):
        self.assertIs(InFlightCommand().terminate(), TerminateOutcome.IDLE)

    def test_terminate_reaches_the_published_handle(self):
        slot = InFlightCommand()
        handle = _FakeHandle()
        slot.publish(handle)
        self.assertIs(slot.terminate(), TerminateOutcome.TERMINATED)
        self.assertEqual(handle.terminated, 1)

    def test_cleared_slot_is_idle_again(self):
        slot = InFlightCommand()
        slot.publish(_FakeHandle())
        slot.clear()
        self.assertIs(slot.terminate(), TerminateOutcome.IDLE)

    def test_kill_requested_before_publish_kills_on_arrival(self):
        """A cancel landing just before the step's command starts must not
        race past it: the next published handle is terminated immediately."""
        slot = InFlightCommand()
        self.assertIs(slot.terminate(), TerminateOutcome.IDLE)
        handle = _FakeHandle()
        slot.publish(handle)
        self.assertEqual(handle.terminated, 1)


if __name__ == "__main__":
    unittest.main()
