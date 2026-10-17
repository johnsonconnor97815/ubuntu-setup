"""Configuration protection tests; all writes and CLI probes stay in fixtures."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("codex_response", ROOT / "lib/codex_response.py")
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)


class ResponseSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="response-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "target"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        cli = self.bin / "codex"
        cli.write_text(f"#!{sys.executable}\n" + '''
import os, sys, tomllib
from pathlib import Path
with open(os.environ["RESPONSE_TEST_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
if sys.argv[1:] == ["--version"]:
    print("codex-cli fixture")
    sys.exit(0)
if sys.argv[1:] != ["features", "list"]:
    sys.exit(2)
config = tomllib.loads((Path(os.environ["CODEX_HOME"]) / "config.toml").read_text())
mode = os.environ.get("RESPONSE_TEST_MODE")
if mode == "ignore-unknown":
    sys.exit(0)
if not isinstance(config.get("hide_agent_reasoning"), bool):
    print("hide_agent_reasoning: expected a boolean", file=sys.stderr)
    sys.exit(1)
if mode == "reject-config":
    print("fixture-secret-diagnostic", file=sys.stderr)
    sys.exit(1)
print("fixture_feature stable true")
''')
        cli.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ.get("PATH", ""),
                        RESPONSE_TEST_LOG=str(self.root / "cli.log"))
        self.env.pop("SUDO_USER", None)
        self.standard = setup.RULES.read_bytes()

    def invoke(self, operation="configure", mode=None):
        env = dict(self.env)
        if mode:
            env["RESPONSE_TEST_MODE"] = mode
        return subprocess.run([sys.executable, str(ROOT / "lib/codex_response.py"), operation,
                               "--codex-home", str(self.home), "--no-open"],
                              env=env, cwd=self.root, capture_output=True, text=True, timeout=20)

    def seed(self, config=None, agents=None):
        self.home.mkdir(exist_ok=True)
        if config is not None:
            (self.home / "config.toml").write_bytes(config)
        if agents is not None:
            (self.home / "AGENTS.md").write_bytes(agents)

    def reports(self):
        return list(self.home.glob(".ubuntu-setup-response-runs/*/report.json"))

    def test_plan_and_status_do_not_create_home_or_invoke_cli(self):
        self.assertEqual(self.invoke("plan").returncode, 0)
        self.assertEqual(self.invoke("status").returncode, 1)
        self.assertFalse(self.home.exists())
        self.assertFalse((self.root / "cli.log").exists())

    def test_fresh_configuration_and_private_report(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), self.standard)
        self.assertEqual(tomllib.loads((self.home / "config.toml").read_text()), {"hide_agent_reasoning": True})
        report_file = self.reports()[0]
        report = json.loads(report_file.read_text())
        self.assertEqual(report["browser_open"], "disabled")
        self.assertFalse(report["behavior_verified"])
        self.assertIsNone(report["error"])
        self.assertTrue(all(f["state"] == "verified" and not f["existed"] for f in report["files"]))
        self.assertEqual(report_file.parent.stat().st_mode & 0o777, 0o700)
        self.assertTrue(report_file.with_suffix(".html").exists())
        self.assertEqual(self.invoke("status").returncode, 0)

    def test_repeat_does_not_rewrite_matching_files(self):
        self.assertEqual(self.invoke().returncode, 0)
        paths = [self.home / "AGENTS.md", self.home / "config.toml"]
        before = [(p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino) for p in paths]
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual(before, [(p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_ino) for p in paths])
        self.assertEqual(len(self.reports()), 2)
        self.assertTrue(any(not json.loads(p.read_text())["files"] for p in self.reports()))

    def test_preserves_credentials_comments_and_file_metadata(self):
        original = b'# existing comment\n"hide_agent_reasoning" = false # display\n[provider]\ntoken="fixture-secret-value"\nhide_agent_reasoning=false\n'
        self.seed(config=original, agents=b"# Existing research\n\nKeep sources.\n")
        path = self.home / "config.toml"
        path.chmod(0o640)
        before = path.stat()
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = original.replace(b'"hide_agent_reasoning" = false', b'"hide_agent_reasoning" = true', 1)
        self.assertEqual(path.read_bytes(), expected)
        after = path.stat()
        self.assertEqual((before.st_mode, before.st_uid, before.st_gid), (after.st_mode, after.st_uid, after.st_gid))
        report_file = self.reports()[0]
        report = json.loads(report_file.read_text())
        item = next(f for f in report["files"] if f["path"] == str(path))
        self.assertEqual(Path(item["backup"]).read_bytes(), original)
        self.assertEqual(Path(item["backup"]).stat().st_mode & 0o777, 0o640)
        for output in (result.stdout, result.stderr, report_file.read_text(), report_file.with_suffix(".html").read_text()):
            self.assertNotIn("fixture-secret-value", output)

    def test_only_edits_top_level_setting_not_multiline_string_or_table(self):
        raw = b'note="""\nhide_agent_reasoning = false\n"""\nhide_agent_reasoning = false\n[tui]\nhide_agent_reasoning = false\n'
        changed = setup.config_candidate(raw)
        old = tomllib.loads(raw.decode())
        new = tomllib.loads(changed.decode())
        self.assertEqual(new, dict(old, hide_agent_reasoning=True))
        self.assertEqual(new["note"], old["note"])

    def test_existing_identical_unmarked_section_with_following_section_is_skipped(self):
        original = b"# Other rules\n\n" + self.standard + b"\n## More rules\nKeep this.\n"
        self.seed(agents=original)
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), original)

    def test_matching_crlf_rules_keep_original_line_endings(self):
        original = self.standard.replace(b"\n", b"\r\n")
        self.seed(agents=original)
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), original)

    def test_rule_conflict_blocks_both_writes(self):
        original = "## 回复与信息展示\n\n我的定制规则\n".encode()
        self.seed(agents=original, config=b"hide_agent_reasoning=false\n")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), original)
        self.assertEqual((self.home / "config.toml").read_bytes(), b"hide_agent_reasoning=false\n")
        self.assertEqual(self.reports(), [])

    def test_nonempty_override_is_updated_instead_of_base(self):
        base = b"# Base must stay unchanged\n"
        self.seed(agents=base)
        override = self.home / "AGENTS.override.md"
        override.write_bytes(b"# Effective rules\n")
        self.assertEqual(self.invoke().returncode, 0)
        self.assertTrue(override.read_bytes().endswith(self.standard))
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), base)

    def test_empty_override_falls_back_to_base(self):
        self.seed()
        override = self.home / "AGENTS.override.md"
        override.write_text("\n  \n")
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual((self.home / "AGENTS.md").read_bytes(), self.standard)
        self.assertEqual(override.read_text(), "\n  \n")

    def test_symbolic_link_target_is_not_followed(self):
        self.seed()
        target = self.root / "outside.toml"
        target.write_text("hide_agent_reasoning=false\n")
        (self.home / "config.toml").symlink_to(target)
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertEqual(target.read_text(), "hide_agent_reasoning=false\n")
        self.assertFalse((self.home / "AGENTS.md").exists())

    def test_invalid_toml_and_invalid_type_are_preserved(self):
        for raw in (b"invalid TOML !", b'hide_agent_reasoning="false"\n'):
            with self.subTest(raw=raw):
                self.seed(config=raw)
                self.assertNotEqual(self.invoke().returncode, 0)
                self.assertEqual((self.home / "config.toml").read_bytes(), raw)
                self.assertFalse((self.home / "AGENTS.md").exists())

    def test_incompatible_cli_blocks_writes_without_leaking_diagnostics(self):
        for mode in ("ignore-unknown", "reject-config"):
            with self.subTest(mode=mode):
                result = self.invoke(mode=mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.home.exists())
                self.assertNotIn("fixture-secret-diagnostic", result.stdout + result.stderr)

    def test_small_instruction_budget_blocks_writes(self):
        self.seed(config=b"project_doc_max_bytes=50\n")
        self.assertNotEqual(self.invoke().returncode, 0)
        self.assertFalse((self.home / "AGENTS.md").exists())

    def test_concurrent_new_override_stops_stale_plan(self):
        self.seed()
        data = setup.plan(self.home)
        (self.home / "AGENTS.override.md").write_text("# New owner instruction\n")
        run = self.root / "run"
        with self.assertRaises(setup.SetupError):
            setup.apply_plan(data, run, {"files": []})
        self.assertFalse((self.home / "config.toml").exists())

    def test_partial_failure_recorded_and_resume_preserves_finished_file(self):
        data = setup.plan(self.home)
        original_write = setup.write_atomic
        def failing_write(path, content, metadata):
            if path.name == "config.toml":
                raise OSError("fixture write failure")
            original_write(path, content, metadata)
        with mock.patch.object(setup, "check_cli", return_value="fixture"), mock.patch.object(setup, "write_atomic", side_effect=failing_write):
            run, success = setup.configure(data, True)
        self.assertFalse(success)
        report = json.loads((run / "report.json").read_text())
        self.assertEqual([f["state"] for f in report["files"]], ["verified", "prepared"])
        agent_stat = (self.home / "AGENTS.md").stat()
        self.assertEqual(self.invoke().returncode, 0)
        self.assertEqual((self.home / "AGENTS.md").stat().st_ino, agent_stat.st_ino)

    def test_report_escapes_paths(self):
        self.home = self.root / "<custom-home>"
        self.assertEqual(self.invoke().returncode, 0)
        output = self.reports()[0].with_suffix(".html").read_text()
        self.assertNotIn("<custom-home>", output)
        self.assertIn("&lt;custom-home&gt;", output)


if __name__ == "__main__":
    unittest.main()
