"""CLI tests.

- A real ``--dry-run`` test that exercises the whole wiring (load catalog ->
  plan -> execute with check_mode) using real, read-only ``dpkg-query`` — no
  sudo, no mutation.
- Probe-adaptive sudo wiring tests with a faked ``Privilege`` + faked runner
  (sudo never really runs): a cached credential skips the interactive prompt;
  headless with no tty and no credential still fails cleanly to exit 4.
- A ``smoke`` test that really installs a package; skipped unless
  ``UBUNTU_SETUP_SMOKE=1`` (needs sudo + apt).
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from ubuntu_setup.cli import main
from ubuntu_setup.core.errors import PrivilegeError
from ubuntu_setup.core.privilege import CredentialStatus, Privilege
from tests._fakes import FakeRun, status_query


class TestCliDryRun(unittest.TestCase):
    def test_dry_run_install_is_safe_and_zero(self):
        # read-only: dpkg-query only; --dry-run writes nothing and mutates nothing
        rc = main(["--install", "tree", "--dry-run"])
        self.assertEqual(rc, 0)

    def test_unknown_id_is_usage_error(self):
        rc = main(["--install", "no-such-entry-xyz", "--dry-run"])
        self.assertEqual(rc, 2)  # CatalogError -> exit 2

    def test_apply_missing_manifest_is_usage_error(self):
        rc = main(["--apply", "/no/such/manifest.json", "--dry-run"])
        self.assertEqual(rc, 2)  # CatalogError -> exit 2 (and no file created)
        self.assertFalse(Path("/no/such/manifest.json").exists())

    def test_apply_dry_run_plans_from_manifest_desired(self):
        with tempfile.TemporaryDirectory() as tmp:
            manifest = Path(tmp) / "manifest.json"
            manifest.write_text(json.dumps({
                "version": 1,
                "desired": [{"id": "tree", "op": "install"}],
                "history": [],
            }), encoding="utf-8")
            before = manifest.read_text(encoding="utf-8")
            rc = main(["--apply", str(manifest), "--dry-run"])
            self.assertEqual(rc, 0)
            # dry-run records no transaction and rewrites nothing
            self.assertEqual(manifest.read_text(encoding="utf-8"), before)


class TestCliProbeAdaptiveSudo(unittest.TestCase):
    """The apply-time sudo gate: probe first, prompt only when needed."""

    @staticmethod
    def _manifest(tmp: str) -> Path:
        # one desired entry -> a non-empty plan, so the sudo gate is reached
        path = Path(tmp) / "manifest.json"
        path.write_text(json.dumps({
            "version": 1,
            "desired": [{"id": "tree", "op": "install"}],
            "history": [],
        }), encoding="utf-8")
        return path

    def test_headless_no_tty_no_credential_exits_4(self):
        """No cached credential and the interactive validation fails (the
        no-tty case): exit 4, cleanly, before service.apply ever runs."""

        class NoCred(Privilege):
            def __init__(self):
                super().__init__(run=FakeRun())

            def probe_credentials(self):
                return CredentialStatus.NONE

            def ensure_sudo(self):  # what `sudo -v` does with no tty
                raise PrivilegeError(
                    "sudo is required but unavailable: `sudo -v` failed (exit 1)."
                )

        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest(tmp)
            before = manifest.read_text(encoding="utf-8")
            with mock.patch("ubuntu_setup.cli.Privilege", NoCred):
                rc = main(["--apply", str(manifest)])
            self.assertEqual(rc, 4)
            # failed before applying: no transaction page was written
            self.assertEqual(manifest.read_text(encoding="utf-8"), before)

    def test_cached_credential_skips_interactive_prompt(self):
        """Probe says CACHED -> the interactive `sudo -v` is never issued and
        the apply proceeds (here: an already-present no-op via a fake runner)."""
        fake_run = FakeRun().when(status_query, returncode=0,
                                  stdout="install ok installed")
        prompted: "list[bool]" = []

        class Cached(Privilege):
            def __init__(self):
                super().__init__(run=fake_run)

            def probe_credentials(self):
                return CredentialStatus.CACHED

            def ensure_sudo(self):
                prompted.append(True)

        with tempfile.TemporaryDirectory() as tmp:
            manifest = self._manifest(tmp)
            with mock.patch("ubuntu_setup.cli.Privilege", Cached), \
                 mock.patch("ubuntu_setup.core.runner.run", fake_run):
                rc = main(["--apply", str(manifest)])
            self.assertEqual(rc, 0)
            self.assertEqual(prompted, [])  # never prompted interactively
            self.assertFalse(fake_run.ran("apt-get"))  # already present: no-op
            data = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual(
                data["history"][0]["actions"],
                [{"id": "tree", "op": "install", "outcome": "ok"}],
            )


@unittest.skipUnless(
    os.environ.get("UBUNTU_SETUP_SMOKE") == "1",
    "smoke test needs sudo + apt; set UBUNTU_SETUP_SMOKE=1 to run",
)
class TestCliSmoke(unittest.TestCase):
    def test_install_is_idempotent(self):
        self.assertEqual(main(["--install", "tree"]), 0)
        self.assertEqual(main(["--install", "tree"]), 0)  # second run: ok no-op


if __name__ == "__main__":
    unittest.main()
