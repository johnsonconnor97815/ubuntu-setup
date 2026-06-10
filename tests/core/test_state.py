"""Manifest (state.py) tests — round-trip, transactions, desired upsert."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.core import state as state_mod
from ubuntu_setup.core.errors import CatalogError
from ubuntu_setup.core.models import Manifest, Op, Outcome, StepResult


class TestManifest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "manifest.json"

    def tearDown(self):
        import shutil

        shutil.rmtree(self.dir, ignore_errors=True)

    def test_missing_file_loads_empty_manifest(self):
        m = state_mod.load_manifest(self.path)
        self.assertEqual(m.version, state_mod.MANIFEST_VERSION)
        self.assertEqual(m.desired, [])
        self.assertEqual(m.history, [])

    def test_save_then_load_round_trips(self):
        m = Manifest(desired=[{"id": "ripgrep", "op": "install"}])
        state_mod.save_manifest(self.path, m)
        loaded = state_mod.load_manifest(self.path)
        self.assertEqual(loaded.desired, [{"id": "ripgrep", "op": "install"}])

    def test_invalid_json_raises_catalog_error(self):
        self.path.write_text("{not json", encoding="utf-8")
        with self.assertRaises(CatalogError):
            state_mod.load_manifest(self.path)

    def test_non_integer_version_raises_catalog_error(self):
        self.path.write_text('{"version": "abc", "desired": [], "history": []}',
                             encoding="utf-8")
        with self.assertRaises(CatalogError):
            state_mod.load_manifest(self.path)

    def test_newer_version_raises_catalog_error(self):
        # forward-compat gate: refuse a manifest written by a newer tool
        self.path.write_text('{"version": 99, "desired": [], "history": []}',
                             encoding="utf-8")
        with self.assertRaises(CatalogError):
            state_mod.load_manifest(self.path)

    def test_update_desired_upserts(self):
        m = Manifest()
        state_mod.update_desired(m, "ripgrep", "install")
        state_mod.update_desired(m, "ripgrep", "remove")  # update in place
        state_mod.update_desired(m, "tree", "install")
        self.assertEqual(
            m.desired,
            [{"id": "ripgrep", "op": "remove"}, {"id": "tree", "op": "install"}],
        )

    def test_record_transaction_appends_history(self):
        m = Manifest()
        results = [
            StepResult("ripgrep", Op.INSTALL, Outcome.CHANGED, "installed"),
            StepResult("tree", Op.INSTALL, Outcome.OK, "already present"),
        ]
        state_mod.record_transaction(
            m, run_id="rid-1", started_at="2026-06-04T00:00:00Z", exit_code=0, results=results,
        )
        self.assertEqual(len(m.history), 1)
        tx = m.history[0]
        self.assertEqual(tx["run_id"], "rid-1")
        self.assertEqual(tx["exit_code"], 0)
        self.assertEqual(tx["actions"][0], {"id": "ripgrep", "op": "install", "outcome": "changed"})
        self.assertEqual(tx["actions"][1]["outcome"], "ok")

    def test_saved_manifest_is_valid_json(self):
        m = Manifest(desired=[{"id": "x", "op": "install"}])
        state_mod.record_transaction(
            m, run_id="r", started_at="t", exit_code=0,
            results=[StepResult("x", Op.INSTALL, Outcome.CHANGED, "")],
        )
        state_mod.save_manifest(self.path, m)
        data = json.loads(self.path.read_text(encoding="utf-8"))
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["history"][0]["actions"][0]["id"], "x")


if __name__ == "__main__":
    unittest.main()
