import importlib.util
from pathlib import Path
import os
import stat
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("agent_evidence", Path(__file__).resolve().parents[1] / "skills/agent-evidence-setup/scripts/setup.py")
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.codex, self.claude, self.skills = [self.root / s for s in ("codex", "claude", "skills")]

    def plan(self):
        return setup.build_plan(self.codex, self.claude, self.skills)

    def test_preview_does_not_create_targets(self):
        data = self.plan()
        self.assertTrue(data["changes"])
        self.assertEqual(list(self.root.iterdir()), [])

    def test_preserves_bytes_metadata_and_repeat_has_no_changes(self):
        self.codex.mkdir()
        p = self.codex / "AGENTS.md"
        before = "# Existing\r\n保留原规则。".encode()
        p.write_bytes(before)
        p.chmod(0o640)
        run, result = setup.configure(self.plan(), self.root / "state", True)
        self.assertIsNone(result["error"])
        self.assertTrue(p.read_bytes().startswith(before))
        self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o640)
        self.assertEqual(p.stat().st_uid, os.getuid())
        item = next(x for x in result["files"] if x["path"] == str(p))
        self.assertEqual(Path(item["backup"]).read_bytes(), before)
        self.assertTrue((run / "report.html").exists())
        old_time = p.stat().st_mtime_ns
        self.assertFalse(self.plan()["changes"])
        setup.configure(self.plan(), self.root / "state", True)
        self.assertEqual(p.stat().st_mtime_ns, old_time)

    def test_override_preserves_base(self):
        self.codex.mkdir()
        (self.codex / "AGENTS.md").write_text("base")
        p = self.codex / "AGENTS.override.md"
        p.write_text("override")
        data = self.plan()
        self.assertIn(p, data["changes"])
        self.assertNotIn(self.codex / "AGENTS.md", data["changes"])

    def test_empty_override_does_not_hide_base(self):
        self.codex.mkdir()
        (self.codex / "AGENTS.md").write_text("base")
        (self.codex / "AGENTS.override.md").write_bytes(b"")
        with self.assertRaises(setup.SetupError):
            self.plan()

    def test_custom_rules_and_incomplete_markers_are_preserved(self):
        for raw in [setup.START + b"\ncustom\n" + setup.END, setup.START, setup.TITLE.encode()]:
            with self.subTest(raw=raw), self.assertRaises(setup.SetupError):
                setup.merge(raw, b"standard")

    def test_different_skill_prevents_all_instruction_writes(self):
        dest = self.skills / setup.NAME
        dest.mkdir(parents=True)
        (dest / "SKILL.md").write_text("custom")
        with self.assertRaises(setup.SetupError):
            self.plan()
        self.assertFalse(self.codex.exists())
        self.assertFalse(self.claude.exists())

    def test_environment_drift_prevents_apply(self):
        data = self.plan()
        self.codex.mkdir()
        p = self.codex / "AGENTS.override.md"
        p.write_text("new override")
        with self.assertRaises(setup.SetupError):
            setup.configure(data, self.root / "state", True)
        self.assertFalse((self.root / "state").exists())

    def test_interrupted_skill_copy_can_resume_without_overwriting_completed_files(self):
        original_write = setup.atomic_write
        failed = self.skills / setup.NAME / "assets/evidence-rules.md"
        def write(path, raw, metadata=None):
            if path == failed:
                raise OSError("simulated interrupted copy")
            return original_write(path, raw, metadata)
        with patch.object(setup, "atomic_write", side_effect=write):
            _, result = setup.configure(self.plan(), self.root / "state", True)
        self.assertEqual(result["error"], "simulated interrupted copy")
        completed = self.codex / "AGENTS.md"
        before = completed.read_bytes()
        modified = completed.stat().st_mtime_ns
        _, result = setup.configure(self.plan(), self.root / "state", True)
        self.assertIsNone(result["error"])
        self.assertEqual(completed.read_bytes(), before)
        self.assertEqual(completed.stat().st_mtime_ns, modified)
        self.assertFalse(self.plan()["changes"])

    def test_additional_user_file_is_not_silently_removed(self):
        setup.configure(self.plan(), self.root / "state", True)
        extra = self.skills / setup.NAME / "personal.md"
        extra.write_text("user notes")
        with self.assertRaises(setup.SetupError):
            self.plan()
        self.assertEqual(extra.read_text(), "user notes")

    def test_symlink_and_size_limit_block_writes(self):
        self.codex.mkdir()
        (self.codex / "AGENTS.md").symlink_to(self.root / "elsewhere")
        with self.assertRaises(setup.SetupError):
            self.plan()
        (self.codex / "AGENTS.md").unlink()
        (self.codex / "config.toml").write_text("project_doc_max_bytes = 1\n")
        with self.assertRaises(setup.SetupError):
            self.plan()


if __name__ == "__main__":
    unittest.main()
