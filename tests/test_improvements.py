import io
import json
import subprocess
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from ubuntu_setup.cli import main
from ubuntu_setup.improvements import validate_improvement
from ubuntu_setup.model import DataError
from ubuntu_setup.state import StateStore


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/fixtures/improvement-codex-skill-loading.json"


class ImprovementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "private-improvements"
        self.record = json.loads(FIXTURE.read_text())

    def adopted(self):
        record = json.loads(json.dumps(self.record))
        record.update(
            revision=2,
            status="adopted",
            updated_at="2026-09-24T01:00:00+00:00",
            adoption={
                "decision": "adopted",
                "version": "0.10.0",
                "scope": "Codex CLI 0.156.0 user-level skills",
                "rollback": "Revert the deployment change and remove the copied ~/.agents/skills entry.",
                "decided_at": "2026-09-24T01:00:00+00:00",
            },
        )
        return record

    def test_first_revision_cannot_skip_to_adoption(self):
        record = self.adopted()
        record["revision"] = 1
        with self.assertRaisesRegex(DataError, "两个记录版本"):
            validate_improvement(record)

    def test_validation_and_adoption_are_separate_immutable_revisions(self):
        with StateStore(self.state) as store:
            first = store.save_improvement(self.record)
            second = store.save_improvement(self.adopted())

        self.assertEqual(first["revision"], 1)
        self.assertEqual(second["revision"], 2)
        current = json.loads((self.state / "improvements/codex-156-skill-loading/current.json").read_text())
        self.assertEqual((current["revision"], current["status"]), (2, "adopted"))
        revision_1 = self.state / "improvements/codex-156-skill-loading/revisions/0001.json"
        revision_2 = self.state / "improvements/codex-156-skill-loading/revisions/0002.json"
        self.assertEqual(json.loads(revision_1.read_text())["status"], "validated")
        self.assertEqual(json.loads(revision_2.read_text())["status"], "adopted")

    def test_history_rewrite_is_rejected(self):
        with StateStore(self.state) as store:
            store.save_improvement(self.record)
            changed = self.adopted()
            changed["problem"]["summary"] = "changed after the fact"
            with self.assertRaisesRegex(DataError, "不能改写 problem"):
                store.save_improvement(changed)

        current = json.loads((self.state / "improvements/codex-156-skill-loading/current.json").read_text())
        self.assertEqual((current["revision"], current["status"]), (1, "validated"))
        self.assertEqual(current["problem"]["summary"], self.record["problem"]["summary"])

    def test_cli_saves_record_without_probing_host(self):
        record_path = self.root / "record.json"
        record_path.write_text(json.dumps(self.record, ensure_ascii=False))
        out = io.StringIO()
        with patch("ubuntu_setup.cli.LocalProbe", side_effect=AssertionError("host probe forbidden")), redirect_stdout(out):
            code = main(["improvement", "--record", str(record_path), "--state-dir", str(self.state)])

        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        self.assertEqual(result["case_id"], "codex-156-skill-loading")
        self.assertTrue(Path(result["current_path"]).is_file())

    def test_launcher_accepts_improvement(self):
        record_path = self.root / "record.json"
        record_path.write_text(json.dumps(self.record, ensure_ascii=False))
        completed = subprocess.run(
            [str(ROOT / "ubuntu-setup"), "improvement", "--record", str(record_path),
             "--state-dir", str(self.state), "--format", "json"],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        result = json.loads(completed.stdout)
        self.assertEqual(result["status"], "validated")

    def test_capabilities_advertise_the_improvement_operation(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["capabilities", "--format", "json"])

        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        operation = next(item for item in result["operations"] if item["id"] == "improvement")
        self.assertIn("improvements/<case-id>/", " ".join(operation["side_effects"]))
        self.assertIn("record_improvement", result["agent_interface"]["commands"])


if __name__ == "__main__":
    unittest.main()
