from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from ubuntu_setup.browser import open_report


class BrowserTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "报告 with spaces & symbols.html"
        self.path.write_text("<!doctype html><title>synthetic report</title>")

    def test_desktop_open_uses_argument_list_and_encoded_file_uri(self):
        with patch.dict("os.environ", {"DISPLAY": ":1"}, clear=True), \
                patch("ubuntu_setup.browser.shutil.which", return_value="/usr/bin/xdg-open"), \
                patch("ubuntu_setup.browser.subprocess.run", return_value=subprocess.CompletedProcess([], 0)) as run:
            result = open_report(self.path)
        self.assertEqual(result["status"], "requested")
        args, kwargs = run.call_args
        self.assertEqual(args[0], ["/usr/bin/xdg-open", self.path.as_uri()])
        self.assertNotIn("shell", kwargs)
        self.assertLessEqual(kwargs["timeout"], 5)
        self.assertEqual(kwargs["stdout"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)

    def test_no_desktop_session_never_starts_opener(self):
        with patch.dict("os.environ", {}, clear=True), patch("ubuntu_setup.browser.subprocess.run") as run:
            result = open_report(self.path)
        self.assertEqual(result["status"], "unavailable")
        run.assert_not_called()
        self.assertTrue(self.path.is_file())

    def test_missing_opener_keeps_report_available(self):
        with patch.dict("os.environ", {"WAYLAND_DISPLAY": "wayland-0"}, clear=True), \
                patch("ubuntu_setup.browser.shutil.which", return_value=None), \
                patch("ubuntu_setup.browser.subprocess.run") as run:
            result = open_report(self.path)
        self.assertEqual(result["status"], "unavailable")
        run.assert_not_called()

    def test_opener_failures_are_separate_from_report_generation(self):
        for error, expected in ((OSError("PRIVATE_ERROR"), "failed"),
                                (subprocess.TimeoutExpired("synthetic", 5), "timeout")):
            with self.subTest(error=error), patch.dict("os.environ", {"DISPLAY": ":1"}, clear=True), \
                    patch("ubuntu_setup.browser.shutil.which", return_value="/usr/bin/xdg-open"), \
                    patch("ubuntu_setup.browser.subprocess.run", side_effect=error) as run:
                result = open_report(self.path)
                self.assertEqual(result["status"], expected)
                self.assertNotIn("PRIVATE_ERROR", result["reason"])
                run.assert_called_once()
                self.assertTrue(self.path.is_file())

    def test_unsuccessful_opener_exit_is_reported(self):
        with patch.dict("os.environ", {"DISPLAY": ":1"}, clear=True), \
                patch("ubuntu_setup.browser.shutil.which", return_value="/usr/bin/xdg-open"), \
                patch("ubuntu_setup.browser.subprocess.run", return_value=subprocess.CompletedProcess([], 4)):
            self.assertEqual(open_report(self.path)["status"], "failed")

    def test_missing_report_never_starts_opener(self):
        self.path.unlink()
        with patch("ubuntu_setup.browser.subprocess.run") as run:
            self.assertEqual(open_report(self.path)["status"], "failed")
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
