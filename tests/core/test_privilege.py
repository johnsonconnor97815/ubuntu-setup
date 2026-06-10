"""Privilege tests — real user/home resolution and the up-front ``sudo -v`` gate."""

from __future__ import annotations

import os
import pwd
import unittest

from ubuntu_setup.core.errors import PrivilegeError
from ubuntu_setup.core.privilege import Privilege
from tests._fakes import FakeRun


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


if __name__ == "__main__":
    unittest.main()
