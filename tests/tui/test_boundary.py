"""Brain/face boundary guards (non-negotiable #1).

These run in a *fresh* subprocess because this test process itself imports
``textual`` (the Pilot suite) — ``sys.modules`` here can no longer prove
anything about what ``core``/the headless CLI pull in.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

import ubuntu_setup

_TUI_DIR = Path(ubuntu_setup.__file__).resolve().parent / "tui"


def _run_python(code: str) -> "subprocess.CompletedProcess[str]":
    return subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, timeout=120
    )


class TestCoreNeverImportsTextual(unittest.TestCase):
    def test_importing_every_core_module_loads_no_textual(self):
        code = (
            "import importlib, pkgutil, sys\n"
            "import ubuntu_setup.core as core\n"
            "names = [m.name for m in pkgutil.walk_packages(core.__path__, 'ubuntu_setup.core.')]\n"
            "assert names, 'no core modules found'\n"
            "for name in names:\n"
            "    importlib.import_module(name)\n"
            "assert 'textual' not in sys.modules, 'core/ must never import textual'\n"
        )
        proc = _run_python(code)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)


class TestHeadlessCliNeverImportsTextual(unittest.TestCase):
    def test_headless_install_path_loads_no_textual(self):
        # an unknown id exercises the full headless wiring (parse -> catalog ->
        # error path -> exit 2) without touching the system at all
        code = (
            "import sys\n"
            "from ubuntu_setup.cli import main\n"
            "rc = main(['--install', 'no-such-entry-xyz', '--dry-run'])\n"
            "assert rc == 2, rc\n"
            "assert 'textual' not in sys.modules, 'headless CLI must not load textual'\n"
        )
        proc = _run_python(code)
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)


class TestTuiContainsNoSubprocess(unittest.TestCase):
    """The face never shells out — not even through the stdlib back door."""

    def test_tui_sources_never_reference_subprocess(self):
        sources = sorted(_TUI_DIR.rglob("*.py"))
        self.assertTrue(sources)
        needles = (
            "import subprocess",
            "from subprocess",
            "os.system(",
            "os.popen(",
            "pty.spawn(",
        )
        for path in sources:
            text = path.read_text(encoding="utf-8")
            for needle in needles:
                self.assertNotIn(
                    needle, text, msg=f"{path} uses {needle!r} (face must not shell out)"
                )


if __name__ == "__main__":
    unittest.main()
