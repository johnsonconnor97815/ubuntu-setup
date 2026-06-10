"""Runner tests — use real, harmless commands (no sudo) plus pure argv building."""

from __future__ import annotations

import unittest

from ubuntu_setup.core import runner
from ubuntu_setup.core.runner import build_argv


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


if __name__ == "__main__":
    unittest.main()
