from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from ubuntu_setup.cli import main
from ubuntu_setup.model import BASE_SCOPES, CHECK_SCOPES, DataError, new_id
from ubuntu_setup.state import StateStore
from helpers import fixture_data


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "private-state"
        self.fixture = self.root / "fixture.json"
        self.data = fixture_data()

    def run_cli(self, data=None, extra=(), open_browser=False):
        self.fixture.write_text(json.dumps(self.data if data is None else data))
        out, err = io.StringIO(), io.StringIO()
        args = ["inspect", "--fixture", str(self.fixture), "--state-dir", str(self.state), "--format", "json", *extra]
        if not open_browser:
            args.append("--no-open")
        with redirect_stdout(out), redirect_stderr(err):
            code = main(args)
        return code, json.loads(out.getvalue()) if out.getvalue() else None, err.getvalue()

    def current_snapshot(self):
        pointer = json.loads((self.state / "inventory/current.json").read_text())
        return json.loads((self.state / f"inventory/snapshots/{pointer['run_id']}.json").read_text())

    def test_fixture_run_never_constructs_live_probe(self):
        with patch("ubuntu_setup.cli.LocalProbe", side_effect=AssertionError("host probe forbidden")):
            code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result["source_kind"], "fixture")
        self.assertTrue(Path(result["report_path"]).is_file())

    def test_repeat_run_preserves_history_and_reports_no_change(self):
        code, first, _ = self.run_cli()
        self.assertEqual(code, 0)
        original = (self.state / f"inventory/snapshots/{first['run_id']}.json").read_bytes()
        code, second, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(first["machine_id"], second["machine_id"])
        self.assertNotEqual(first["run_id"], second["run_id"])
        self.assertEqual(second["changes"], [])
        self.assertEqual((self.state / f"inventory/snapshots/{first['run_id']}.json").read_bytes(), original)

    def test_unknown_then_restore_compares_last_known_without_filling_unknown(self):
        self.run_cli()
        original_packages = self.data["observations"]["packages.dpkg"]
        self.data["observations"]["packages.dpkg"] = {"status": "unknown", "reason": "PermissionError", "value": None}
        self.assertEqual(self.run_cli()[0], 0)
        self.assertIsNone(self.current_snapshot()["observations"]["packages.dpkg"]["value"])
        self.data["observations"]["packages.dpkg"] = original_packages
        original_packages["value"]["nano"]["version"] = "2.0-example"
        code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        upgraded = [c for c in result["changes"] if c["subject"] == "nano"]
        self.assertEqual(upgraded[0]["before"]["version"], "1.0-example")

    def test_identity_and_live_fixture_mismatch_are_rejected(self):
        self.run_cli()
        identity = (self.state / "identity.json").read_bytes()
        self.data["fixture_id"] = "another-synthetic-machine"
        self.assertEqual(self.run_cli()[0], 2)
        self.assertEqual((self.state / "identity.json").read_bytes(), identity)
        with StateStore(self.state) as store, self.assertRaises(DataError):
            store.bind("live", "some-token")

    def test_raw_identity_is_not_saved(self):
        self.run_cli()
        identity = (self.state / "identity.json").read_text()
        self.assertNotIn("synthetic-desktop-a", identity)

    def test_corrupt_current_is_preserved_not_reinitialized(self):
        self.run_cli()
        pointer = self.state / "inventory/current.json"
        pointer.write_text("{corrupt")
        code, _, _ = self.run_cli()
        self.assertEqual(code, 2)
        self.assertEqual(pointer.read_text(), "{corrupt")

    def test_unknown_snapshot_schema_is_rejected(self):
        self.run_cli()
        snap = self.current_snapshot()
        path = self.state / f"inventory/snapshots/{snap['snapshot_id']}.json"
        snap["schema_version"] = 999
        path.write_text(json.dumps(snap))
        self.assertEqual(self.run_cli()[0], 2)

    def test_missing_identity_with_existing_data_is_not_a_new_machine(self):
        self.run_cli()
        (self.state / "identity.json").unlink()
        self.assertEqual(self.run_cli()[0], 2)

    def test_incomplete_read_only_task_is_retained_and_recollected(self):
        self.run_cli()
        interrupted = new_id()
        with StateStore(self.state) as store:
            store.bind("fixture", self.data["fixture_id"])
            previous, _, _ = store.load_previous()
            store.begin(interrupted, previous, "fixture")
        events = self.state / f"runs/{interrupted}/events.jsonl"
        with events.open("a") as stream:
            stream.write('{"partial":')
        original_events = events.read_bytes()
        code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result["recovered_runs"][0]["status"], "interrupted")
        self.assertEqual(events.read_bytes(), original_events)
        self.assertEqual(result["changes"], [])

    def test_publication_interruption_recovers_only_a_complete_report(self):
        with patch.object(StateStore, "_publish", side_effect=OSError("simulated interruption")):
            self.assertEqual(self.run_cli()[0], 2)
        code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result["recovered_runs"][0]["status"], "completed")
        self.assertEqual(result["changes"], [])

    def test_missing_complete_snapshot_is_not_treated_as_first_run(self):
        self.run_cli()
        snap = self.current_snapshot()
        (self.state / f"inventory/snapshots/{snap['snapshot_id']}.json").unlink()
        self.assertEqual(self.run_cli()[0], 2)

    def test_concurrent_writer_does_not_enter_state(self):
        with StateStore(self.state):
            with self.assertRaisesRegex(DataError, "另一个"):
                with StateStore(self.state):
                    self.fail("second writer acquired lock")

    def test_managed_files_and_directories_are_private(self):
        self.assertEqual(self.run_cli()[0], 0)
        for path in [self.state, *self.state.rglob("*")]:
            with self.subTest(path=path):
                self.assertFalse(stat.S_IMODE(path.stat().st_mode) & 0o077)

    def test_symlink_cannot_redirect_snapshot_storage(self):
        self.run_cli()
        snapshots = self.state / "inventory/snapshots"
        snapshots.rename(self.state / "old-snapshots")
        external = self.root / "external"
        external.mkdir()
        snapshots.symlink_to(external, target_is_directory=True)
        self.assertEqual(self.run_cli()[0], 2)
        self.assertEqual(list(external.iterdir()), [])

    def test_path_traversal_in_pointer_is_rejected(self):
        self.run_cli()
        path = self.state / "inventory/current.json"
        value = json.loads(path.read_text())
        value["run_id"] = "../../outside"
        path.write_text(json.dumps(value))
        self.assertEqual(self.run_cli()[0], 2)

    def test_malformed_fixture_does_not_probe_host_or_create_state(self):
        self.data["observations"]["hardware.pci"] = {"status": "unknown", "value": {"old": {}}, "reason": "failed"}
        with patch("ubuntu_setup.cli.LocalProbe", side_effect=AssertionError("host probe forbidden")):
            self.assertEqual(self.run_cli()[0], 2)
        self.assertFalse(self.state.exists())

    def test_missing_fixture_scopes_stay_unknown_without_host_fallback(self):
        self.data["observations"] = {}
        with patch("ubuntu_setup.cli.LocalProbe", side_effect=AssertionError("host probe forbidden")):
            code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertTrue(all(o["status"] == "unknown" for o in result["observations"].values()))

    def test_invalid_numeric_input_is_rejected(self):
        self.data["observations"]["storage"]["value"]["available_bytes"] = -1
        self.assertEqual(self.run_cli()[0], 2)

    def test_corrupt_check_input_does_not_crash_or_reinitialize(self):
        self.run_cli()
        run_id = self.current_snapshot()["run_id"]
        path = self.state / f"assessments/{run_id}.json"
        value = json.loads(path.read_text())
        value["checks"][0]["input_scopes"] = [{"not": "a scope"}]
        path.write_text(json.dumps(value))
        self.assertEqual(self.run_cli()[0], 2)

    def test_nonfinite_fixture_number_is_not_accepted(self):
        self.data["observations"]["metadata.apt"]["value"]["newest_file_mtime"] = float("nan")
        self.assertEqual(self.run_cli()[0], 2)

    def test_duplicate_json_fields_are_not_accepted(self):
        self.run_cli()
        pointer = self.state / "inventory/current.json"
        pointer.write_text('{"schema_version": 1, "schema_version": 999}')
        self.assertEqual(self.run_cli()[0], 2)

    def test_rule_catalog_never_probes_or_writes_machine_state(self):
        out = io.StringIO()
        with patch("ubuntu_setup.cli.LocalProbe", side_effect=AssertionError("host probe forbidden")), \
                patch("ubuntu_setup.cli.StateStore", side_effect=AssertionError("state forbidden")), redirect_stdout(out):
            code = main(["capabilities", "--check", "services", "--format", "json"])
        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        self.assertEqual([c["check_id"] for c in result["checks"]], ["services"])
        self.assertEqual(result["runtime"], {
            "minimum_python": "3.10",
            "preflight": "./ubuntu-setup runtime status --format json",
            "unavailable_exit_code": 3,
            "repair_command": "swkit python configure --python 3.12",
            "repair_side_effects": [
                "安装用户态 uv 和 Python 3.12",
                "缺少 curl 时经 apt 安装 curl 和 ca-certificates",
                "调整 shell rc 中的 PATH 和 uv 补全",
            ],
            "repair_requires_network": True,
            "repair_replaces_system_python": False,
            "preflight_side_effects": [
                "启动候选 Python 解释器读取版本",
                "如已安装 uv，只读查询 uv 的 Python 安装目录",
            ],
            "network_access": False,
        })
        self.assertFalse(self.state.exists())

    def test_report_exposes_evidence_paths_and_specific_failed_services(self):
        self.data["observations"]["services"]["value"] = {"synthetic.service": {"load": "loaded", "active": "failed", "sub": "failed"}}
        code, result, _ = self.run_cli()
        self.assertEqual(code, 0)  # A completed report can contain failed checks.
        self.assertTrue(Path(result["snapshot_path"]).is_file())
        assessment = json.loads(Path(result["assessment_path"]).read_text())
        self.assertEqual(result["rule_versions"], assessment["rule_versions"])
        self.assertIn("synthetic.service", Path(result["report_path"]).read_text())
        self.assertEqual(next(c for c in result["checks"] if c["check_id"] == "services")["result"], "failed")

    def test_previous_v1_assessment_is_read_without_rewriting_history(self):
        self.run_cli()
        snapshot = self.current_snapshot()
        path = self.state / f"assessments/{snapshot['run_id']}.json"
        value = json.loads(path.read_text())
        value.pop("rule_versions")
        value.pop("rule_changes")
        value["checks"] = [c for c in value["checks"] if c["check_id"] != "drivers.dkms.current"]
        for check in value["checks"]:
            check["rule_version"] = "1"
            for key in ("evidence_refs", "basis_refs", "unavailable_inputs", "reason_code"):
                check.pop(key)
        path.write_text(json.dumps(value))
        historical = path.read_bytes()
        code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result["changes"], [])
        changes = {c["check_id"]: c["kind"] for c in result["rule_changes"]}
        self.assertEqual(changes, {"platform": "updated", "services": "updated", "drivers.dkms.current": "added",
                                   **{k: "updated" for k in ("packages.dependencies", "drivers.compatibility", "hardware.function", "updates", "configs")}})
        self.assertEqual(path.read_bytes(), historical)

    def test_previous_complete_scope_set_resumes_without_rewriting_old_evidence(self):
        self.run_cli()
        snapshot = self.current_snapshot()
        run_id = snapshot["run_id"]
        snapshot_path = self.state / f"inventory/snapshots/{run_id}.json"
        assessment_path = self.state / f"assessments/{run_id}.json"
        snapshot["observations"] = {s: o for s, o in snapshot["observations"].items() if s in BASE_SCOPES}
        assessment = json.loads(assessment_path.read_text())
        extended = {"packages.dependencies", "drivers.compatibility", "hardware.function", "updates", "configs"}
        for record in assessment["checks"]:
            if record["check_id"] in extended:
                record.update(rule_version="1", implementation_status="not_implemented", result="unknown")
                record["input_scopes"] = [s for s in record["input_scopes"] if s in BASE_SCOPES]
                record["evidence_refs"] = [r for r in record["evidence_refs"] if r["scope"] in BASE_SCOPES]
                record["observation_refs"] = [snapshot["observations"][s]["observation_id"] for s in record["input_scopes"]]
                record["unavailable_inputs"] = [r for r in record["unavailable_inputs"] if r["scope"] in BASE_SCOPES]
        assessment["rule_versions"] = {c["check_id"]: c["rule_version"] for c in assessment["checks"]}
        snapshot_path.write_text(json.dumps(snapshot))
        assessment_path.write_text(json.dumps(assessment))
        files = [snapshot_path, assessment_path, self.state / f"runs/{run_id}/report.html"]
        before = [p.read_bytes() for p in files]
        code, result, err = self.run_cli()
        self.assertEqual(code, 0, err)
        self.assertEqual({c["scope"] for c in result["changes"]}, set(CHECK_SCOPES))
        self.assertTrue(all(c["kind"] == "coverage_changed" for c in result["changes"]))
        self.assertEqual({c["check_id"] for c in result["rule_changes"]}, extended)
        self.assertEqual([p.read_bytes() for p in files], before)

    def test_corrupt_evidence_is_rejected_and_preserved(self):
        self.run_cli()
        run_id = self.current_snapshot()["run_id"]
        path = self.state / f"assessments/{run_id}.json"
        value = json.loads(path.read_text())
        value["checks"][0]["evidence_refs"][0]["snapshot_id"] = "another-snapshot"
        path.write_text(json.dumps(value))
        original = path.read_bytes()
        self.assertEqual(self.run_cli()[0], 2)
        self.assertEqual(path.read_bytes(), original)

    def test_invalid_reason_code_is_rejected_without_rewriting_history(self):
        self.run_cli()
        run_id = self.current_snapshot()["run_id"]
        path = self.state / f"assessments/{run_id}.json"
        value = json.loads(path.read_text())
        value["checks"][0]["reason_code"] = {"invalid": "object"}
        path.write_text(json.dumps(value))
        original = path.read_bytes()
        self.assertEqual(self.run_cli()[0], 2)
        self.assertEqual(path.read_bytes(), original)

    def test_corrupt_rule_manifest_is_rejected(self):
        self.run_cli()
        run_id = self.current_snapshot()["run_id"]
        path = self.state / f"assessments/{run_id}.json"
        value = json.loads(path.read_text())
        value["rule_versions"]["services"] = "different-version"
        path.write_text(json.dumps(value))
        self.assertEqual(self.run_cli()[0], 2)

    def test_object_in_check_result_is_rejected_without_crashing_or_rewriting(self):
        self.run_cli()
        run_id = self.current_snapshot()["run_id"]
        path = self.state / f"assessments/{run_id}.json"
        value = json.loads(path.read_text())
        value["checks"][0]["result"] = {"malformed": "status"}
        path.write_text(json.dumps(value))
        original = path.read_bytes()
        self.assertEqual(self.run_cli()[0], 2)
        self.assertEqual(path.read_bytes(), original)

    def test_object_in_observation_status_is_rejected_before_state_creation(self):
        self.data["observations"]["os"]["status"] = {"malformed": "status"}
        self.assertEqual(self.run_cli()[0], 2)
        self.assertFalse(self.state.exists())

    def test_html_opens_only_after_report_is_published_and_lock_released(self):
        def open_completed(path):
            report = Path(path)
            self.assertEqual(report.suffix, ".html")
            self.assertTrue(report.read_text().startswith("<!doctype html>"))
            pointer = json.loads((self.state / "inventory/current.json").read_text())
            self.assertEqual(report.parent.name, pointer["run_id"])
            with StateStore(self.state):
                pass
            return {"status": "requested", "reason": "synthetic open request"}
        with patch("ubuntu_setup.cli.open_report", side_effect=open_completed) as opener:
            code, result, _ = self.run_cli(open_browser=True)
        self.assertEqual(code, 0)
        self.assertEqual(result["report_format"], "html")
        self.assertEqual(result["browser_open"]["status"], "requested")
        opener.assert_called_once()
        self.assertFalse(Path(result["report_path"]).with_suffix(".md").exists())

    def test_no_open_flag_avoids_browser_even_for_json_reports(self):
        with patch("ubuntu_setup.cli.open_report") as opener:
            code, result, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(result["browser_open"]["status"], "disabled")
        opener.assert_not_called()

    def test_browser_failure_does_not_make_completed_inspection_fail(self):
        with patch("ubuntu_setup.cli.open_report", return_value={"status": "failed", "reason": "synthetic browser failure"}):
            code, result, _ = self.run_cli(open_browser=True)
        self.assertEqual(code, 0)
        self.assertEqual(result["browser_open"]["status"], "failed")
        self.assertTrue(Path(result["report_path"]).is_file())
        self.assertEqual(self.run_cli()[0], 0)

    def test_report_save_or_publication_failure_does_not_open_browser(self):
        with patch.object(StateStore, "_publish", side_effect=OSError("synthetic publication failure")), \
                patch("ubuntu_setup.cli.open_report") as opener:
            self.assertEqual(self.run_cli(open_browser=True)[0], 2)
        opener.assert_not_called()

    def test_legacy_markdown_run_is_read_without_rewriting_its_report(self):
        _, result, _ = self.run_cli()
        report = Path(result["report_path"])
        report.unlink()
        markdown = report.with_suffix(".md")
        markdown.write_text("# 原始历史报告\n")
        manifest_path = report.parent / "state.json"
        manifest = json.loads(manifest_path.read_text())
        manifest.pop("report_file")
        manifest_path.write_text(json.dumps(manifest))
        code, current, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertEqual(current["changes"], [])
        self.assertEqual(markdown.read_text(), "# 原始历史报告\n")
        self.assertTrue(Path(current["report_path"]).is_file())

    def test_missing_declared_html_cannot_be_hidden_by_unrelated_markdown(self):
        _, result, _ = self.run_cli()
        report = Path(result["report_path"])
        report.unlink()
        report.with_suffix(".md").write_text("# Wrong report\n")
        self.assertEqual(self.run_cli()[0], 2)

    def test_terminal_prints_summary_instead_of_raw_html(self):
        self.fixture.write_text(json.dumps(self.data))
        output = io.StringIO()
        with redirect_stdout(output):
            code = main(["inspect", "--fixture", str(self.fixture), "--state-dir", str(self.state), "--no-open"])
        self.assertEqual(code, 0)
        self.assertIn("report.html", output.getvalue())
        self.assertIn("模拟检查", output.getvalue())
        self.assertNotIn("<!doctype", output.getvalue())


if __name__ == "__main__":
    unittest.main()
