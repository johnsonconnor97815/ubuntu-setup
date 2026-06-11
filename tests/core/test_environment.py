"""Environment detection tests — each of the three desktop probes individually
triggerable via injected inputs, plus the ``requires`` judgment itself."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.core.environment import (
    DESKTOP,
    detect_capabilities,
    unmet_requires,
)
from ubuntu_setup.core.models import CatalogEntry
from tests._fakes import FakeRun


def _get_default(argv: "list[str]") -> bool:
    return argv == ["systemctl", "get-default"]


class TestDetectDesktop(unittest.TestCase):
    def setUp(self):
        # an existing-but-empty session dir: probe 3 must NOT fire on it
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.empty_dir = Path(self.tmp.name)

    # -- probe 1: display variables -------------------------------------------
    def test_display_env_alone_is_desktop(self):
        run = FakeRun(default_rc=1)  # systemctl would say "no"
        caps = detect_capabilities(run=run, env={"DISPLAY": ":0"},
                                   session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset({DESKTOP}))
        self.assertEqual(run.calls, [])  # short-circuit: no command needed

    def test_wayland_display_env_alone_is_desktop(self):
        caps = detect_capabilities(run=FakeRun(default_rc=1),
                                   env={"WAYLAND_DISPLAY": "wayland-0"},
                                   session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset({DESKTOP}))

    def test_empty_display_value_is_not_a_signal(self):
        caps = detect_capabilities(run=FakeRun(default_rc=1),
                                   env={"DISPLAY": ""},
                                   session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset())

    # -- probe 2: systemd default target --------------------------------------
    def test_graphical_target_alone_is_desktop(self):
        run = FakeRun().when(_get_default, returncode=0, stdout="graphical.target\n")
        caps = detect_capabilities(run=run, env={}, session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset({DESKTOP}))

    def test_multi_user_target_is_not_desktop(self):
        run = FakeRun().when(_get_default, returncode=0, stdout="multi-user.target\n")
        caps = detect_capabilities(run=run, env={}, session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset())

    def test_failing_systemctl_is_not_desktop(self):
        run = FakeRun().when(_get_default, returncode=1, stderr="degraded")
        caps = detect_capabilities(run=run, env={}, session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset())

    def test_missing_systemctl_does_not_crash(self):
        """A container without systemd: the probe must degrade, not raise."""

        def no_systemd(argv, **kw):
            raise FileNotFoundError("systemctl")

        caps = detect_capabilities(run=no_systemd, env={},
                                   session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset())

    # -- probe 3: installed session registries --------------------------------
    def test_nonempty_session_dir_alone_is_desktop(self):
        sessions = Path(self.tmp.name) / "xsessions"
        sessions.mkdir()
        (sessions / "ubuntu.desktop").write_text("[Desktop Entry]\n", encoding="utf-8")
        caps = detect_capabilities(run=FakeRun(default_rc=1), env={},
                                   session_dirs=(self.empty_dir, sessions))
        self.assertEqual(caps, frozenset({DESKTOP}))

    def test_missing_session_dirs_are_not_a_signal(self):
        missing = Path(self.tmp.name) / "does-not-exist"
        caps = detect_capabilities(run=FakeRun(default_rc=1), env={},
                                   session_dirs=(missing,))
        self.assertEqual(caps, frozenset())

    def test_no_signal_at_all_is_empty(self):
        caps = detect_capabilities(run=FakeRun(default_rc=1), env={},
                                   session_dirs=(self.empty_dir,))
        self.assertEqual(caps, frozenset())


class TestUnmetRequires(unittest.TestCase):
    @staticmethod
    def _entry(requires: "tuple[str, ...]" = ()) -> CatalogEntry:
        return CatalogEntry(id="x", description="x", type="apt",
                            requires=requires, fields={"package": "x"})

    def test_no_requires_is_always_applicable(self):
        self.assertEqual(unmet_requires(self._entry(), frozenset()), ())
        self.assertEqual(unmet_requires(self._entry(), frozenset({DESKTOP})), ())

    def test_unmet_capability_is_reported(self):
        entry = self._entry(requires=(DESKTOP,))
        self.assertEqual(unmet_requires(entry, frozenset()), (DESKTOP,))

    def test_met_capability_is_applicable(self):
        entry = self._entry(requires=(DESKTOP,))
        self.assertEqual(unmet_requires(entry, frozenset({DESKTOP})), ())


if __name__ == "__main__":
    unittest.main()
