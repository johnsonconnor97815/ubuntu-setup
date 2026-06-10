"""CLI tests.

- A real ``--dry-run`` test that exercises the whole wiring (load catalog ->
  plan -> execute with check_mode) using real, read-only ``dpkg-query`` — no
  sudo, no mutation.
- A ``smoke`` test that really installs a package; skipped unless
  ``UBUNTU_SETUP_SMOKE=1`` (needs sudo + apt).
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.cli import main


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
