"""Privilege tests — real user/home resolution, the up-front ``sudo -v`` gate,
the silent credential probe matrix, the per-step probe, and the keep-alive.

The matrix is driven by fake run injection (sudo never really runs), explicitly
enumerating the environments from the prd: credential cached / credential
expired / no ``-N`` (stock 22.04) / NOPASSWD / probe unavailable. The
no-tty-no-credential exit-4 path is covered at the CLI boundary in
``tests/test_cli.py``.
"""

from __future__ import annotations

import os
import pwd
import threading
import unittest

from ubuntu_setup.core.errors import PrivilegeError
from ubuntu_setup.core.privilege import CredentialStatus, Privilege, SudoKeepalive
from tests._fakes import FakeRun

# realistic `sudo -h` excerpts: 24.04 (>= 1.9.12) lists -N; stock 22.04 (1.9.9)
# does not (its lowercase `-n, --non-interactive` must not false-positive)
_HELP_WITH_N = "  -N, --no-update               don't update user's cached credentials\n"
_HELP_2204 = "  -n, --non-interactive         non-interactive mode, no prompts are used\n"


def _argv(*words: str):
    expect = list(words)
    return lambda a: a == expect


class TestRealUser(unittest.TestCase):
    def test_real_user_matches_passwd_db(self):
        # not running as root in tests -> the passwd-DB identity of our uid
        name, uid, gid = Privilege().real_user()
        pw = pwd.getpwuid(os.getuid())
        self.assertEqual((name, uid, gid), (pw.pw_name, pw.pw_uid, pw.pw_gid))

    def test_real_home_comes_from_passwd_db_not_env(self):
        # $HOME must never be consulted (it may be /root under sudo)
        priv = Privilege()
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = "/definitely/not/a/home"
        try:
            home = priv.real_home()
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
        self.assertEqual(home, pwd.getpwuid(os.getuid()).pw_dir)
        self.assertNotEqual(home, "/definitely/not/a/home")


class TestEnsureSudo(unittest.TestCase):
    def test_ensure_sudo_runs_sudo_v_through_the_runner(self):
        run = FakeRun()  # default rc 0
        Privilege(run=run).ensure_sudo()
        self.assertEqual(run.calls[0].argv, ["sudo", "-v"])

    def test_ensure_sudo_failure_raises_privilege_error_exit_4(self):
        run = FakeRun(default_rc=1)  # not a sudoer / validation failed
        with self.assertRaises(PrivilegeError) as cm:
            Privilege(run=run).ensure_sudo()
        self.assertEqual(cm.exception.exit_code, 4)

    def test_ensure_sudo_maps_unrunnable_sudo_to_privilege_error(self):
        def broken_run(argv, **kw):
            raise FileNotFoundError("sudo: command not found")

        with self.assertRaises(PrivilegeError) as cm:
            Privilege(run=broken_run).ensure_sudo()
        self.assertEqual(cm.exception.exit_code, 4)


class TestProbeCredentials(unittest.TestCase):
    """The silent probe: never prompts, explicit enum result, -N adaptive."""

    def test_cached_credential_uses_silent_Nnv_and_is_cached(self):
        # 24.04: -N supported; cached timestamp -> rc 0 -> CACHED
        run = (
            FakeRun()
            .when(_argv("sudo", "-h"), stdout=_HELP_WITH_N)
            .when(_argv("sudo", "-Nnv"), returncode=0)
        )
        self.assertIs(Privilege(run=run).probe_credentials(), CredentialStatus.CACHED)
        # the probe argv is the read-only -Nnv form (no TTL reset), never -nv
        self.assertEqual(run.calls[-1].argv, ["sudo", "-Nnv"])

    def test_expired_credential_is_none(self):
        run = (
            FakeRun()
            .when(_argv("sudo", "-h"), stdout=_HELP_WITH_N)
            .when(_argv("sudo", "-Nnv"), returncode=1)
        )
        self.assertIs(Privilege(run=run).probe_credentials(), CredentialStatus.NONE)

    def test_2204_without_N_falls_back_to_sudo_n_true(self):
        # stock 22.04 (sudo 1.9.9): no -N in the help -> the plain probe
        run = (
            FakeRun()
            .when(_argv("sudo", "-h"), stdout=_HELP_2204)
            .when(_argv("sudo", "-n", "true"), returncode=1)
        )
        self.assertIs(Privilege(run=run).probe_credentials(), CredentialStatus.NONE)
        self.assertFalse(any(c.argv == ["sudo", "-Nnv"] for c in run.calls))
        self.assertEqual(run.calls[-1].argv, ["sudo", "-n", "true"])

    def test_nopasswd_probes_as_cached_even_on_fallback(self):
        # NOPASSWD: validation succeeds without a password -> rc 0 -> CACHED
        run = (
            FakeRun()
            .when(_argv("sudo", "-h"), stdout=_HELP_2204)
            .when(_argv("sudo", "-n", "true"), returncode=0)
        )
        self.assertIs(Privilege(run=run).probe_credentials(), CredentialStatus.CACHED)

    def test_N_support_detection_runs_once_and_is_cached(self):
        run = (
            FakeRun()
            .when(_argv("sudo", "-h"), stdout=_HELP_WITH_N)
            .when(_argv("sudo", "-Nnv"), returncode=1)
        )
        priv = Privilege(run=run)
        priv.probe_credentials()
        priv.probe_credentials()
        self.assertEqual(run.count(lambda a: a == ["sudo", "-h"]), 1)
        self.assertEqual(run.count(lambda a: a == ["sudo", "-Nnv"]), 2)

    def test_unrunnable_sudo_is_unavailable_not_a_crash(self):
        def broken_run(argv, **kw):
            raise FileNotFoundError("sudo: command not found")

        self.assertIs(
            Privilege(run=broken_run).probe_credentials(), CredentialStatus.UNAVAILABLE
        )


class TestEnsureSudoNoninteractive(unittest.TestCase):
    """The per-step probe: silent escalation guaranteed, or a clean exit-4."""

    def test_cached_credential_passes_via_sudo_n_true(self):
        run = FakeRun()  # rc 0: the next escalation will run silently
        Privilege(run=run).ensure_sudo_noninteractive()
        self.assertEqual(run.calls[0].argv, ["sudo", "-n", "true"])

    def test_lapsed_credential_raises_exit_4_with_interactive_signal(self):
        run = FakeRun(default_rc=1)  # credential expired mid-run
        with self.assertRaises(PrivilegeError) as cm:
            Privilege(run=run).ensure_sudo_noninteractive()
        self.assertEqual(cm.exception.exit_code, 4)
        # the "interactive escalation required" signal for the consumer
        self.assertIn("interactive escalation required", str(cm.exception))


class TestSudoKeepalive(unittest.TestCase):
    """Controlled-clock tests: short injected intervals + events, no real 50s
    sleeps, no flake."""

    def test_refreshes_periodically_through_the_runner_seam(self):
        refreshed_twice = threading.Event()
        inner = FakeRun()

        def run(argv, **kw):
            res = inner(argv, **kw)
            if len(inner.calls) >= 2:
                refreshed_twice.set()
            return res

        ka = Privilege(run=run).keepalive(interval=0.005)
        ka.start()
        try:
            self.assertTrue(refreshed_twice.wait(timeout=5.0))
        finally:
            ka.stop()
        # every refresh is the spec's command, via the runner seam
        self.assertGreaterEqual(len(inner.calls), 2)
        self.assertTrue(all(c.argv == ["sudo", "-n", "true"] for c in inner.calls))

    def test_stop_unblocks_the_interval_wait_and_joins(self):
        # a long interval proves stop() does not wait it out: Event.wait
        # returns the moment the stop event is set, then the thread is joined
        threads_before = set(threading.enumerate())
        ka = SudoKeepalive(FakeRun(), interval=60.0)
        ka.start()
        ka.stop()
        self.assertEqual(set(threading.enumerate()), threads_before)  # joined

    def test_stop_is_idempotent_and_safe_if_never_started(self):
        ka = SudoKeepalive(FakeRun(), interval=60.0)
        ka.stop()  # never started: a no-op, not an error
        ka.start()
        ka.stop()
        ka.stop()  # second stop: still a no-op

    def test_start_is_idempotent_while_running(self):
        threads_before = set(threading.enumerate())
        ka = SudoKeepalive(FakeRun(), interval=60.0)
        ka.start()
        ka.start()  # no second thread
        self.assertEqual(len(set(threading.enumerate()) - threads_before), 1)
        ka.stop()
        self.assertEqual(set(threading.enumerate()), threads_before)


if __name__ == "__main__":
    unittest.main()
