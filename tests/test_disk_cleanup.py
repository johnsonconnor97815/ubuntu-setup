import io
import json
import os
from pathlib import Path
import tempfile
import time
from contextlib import redirect_stderr, redirect_stdout
import unittest
from unittest.mock import patch

from ubuntu_setup.cli import main
from ubuntu_setup.disk_cleanup import JevClient, LLMReviewClient, create_plan, execute_plan, scan_roots
from ubuntu_setup.model import DataError


class FakeJevClient:
    def __init__(self, delete_names=(), threshold=0.8):
        self.delete_names = set(delete_names)
        self.threshold = threshold
        self.model = "jev-test"

    def classify(self, entries):
        results = []
        for entry in entries:
            probability = 0.99 if entry["relative_path"] in self.delete_names else 0.1
            results.append({
                **entry,
                "jev_decision": "delete" if probability >= self.threshold else "keep",
                "jev_probability": probability,
                "jev_model": self.model,
            })
        return results


class FakeReviewClient:
    def __init__(self, recommendation="delete", risk_level="low"):
        self.recommendation = recommendation
        self.risk_level = risk_level
        self.model = "review-test"

    def review(self, entries):
        return [
            {
                **entry,
                "llm_recommendation": self.recommendation,
                "risk_level": self.risk_level,
                "risk_score": 20 if self.risk_level == "low" else 80,
                "llm_reason": "常见缓存，风险较低",
                "llm_model": self.model,
            }
            for entry in entries
        ]


class DiskCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "root"
        self.state = Path(self.temp.name) / "state"
        self.root.mkdir()

    def old(self, path):
        timestamp = time.time() - 8 * 86400
        os.utime(path, (timestamp, timestamp))

    def make_candidates(self):
        cache = self.root / "cache"
        cache.mkdir()
        pip_cache = cache / "pip"
        pip_cache.mkdir()
        wheel = pip_cache / "wheel.zip"
        wheel.write_bytes(b"x" * 100)
        keep = cache / "important.bin"
        keep.write_bytes(b"y" * 20)
        recent = cache / "recent.tmp"
        recent.write_bytes(b"z" * 10)
        for path in (wheel, pip_cache, keep):
            self.old(path)
        return pip_cache, keep, recent

    def test_scan_excludes_recent_entries_and_symlinks(self):
        pip_cache, keep, recent = self.make_candidates()
        link = self.root / "cache" / "link"
        link.symlink_to(keep)
        entries, skipped, truncated = scan_roots([(self.root / "cache", "cache")],
                                                  min_age_days=7, max_candidates=20)

        self.assertEqual([entry["relative_path"] for entry in entries], ["pip", "important.bin"])
        self.assertEqual(skipped, [])
        self.assertFalse(truncated)
        self.assertEqual({entry["kind"] for entry in entries}, {"directory", "file"})
        self.assertEqual(next(entry for entry in entries if entry["relative_path"] == "pip")["size_bytes"], 100)
        self.assertTrue(link.is_symlink())

    def test_plan_records_two_models_without_final_delete_decision(self):
        pip_cache, keep, recent = self.make_candidates()
        plan = create_plan(state_dir=self.state, roots=[(self.root / "cache", "cache")],
                           min_age_days=7, max_candidates=20,
                           client=FakeJevClient(delete_names={"pip"}),
                           review_client=FakeReviewClient())

        self.assertEqual(plan["schema_version"], 3)
        self.assertEqual(plan["summary"], {
            "candidate_count": 2,
            "reviewed_count": 1,
            "delete_recommendation_count": 1,
            "review_recommendation_count": 0,
            "keep_recommendation_count": 0,
            "recommended_delete_bytes": 100,
            "risk_counts": {"low": 1, "medium": 0, "high": 0, "not_assessed": 1},
        })
        self.assertNotIn("decision", plan["entries"][0])
        self.assertEqual(plan["entries"][0]["llm_recommendation"], "delete")
        self.assertEqual(plan["entries"][0]["risk_level"], "low")
        self.assertEqual(plan["entries"][1]["llm_recommendation"], "not_requested")
        self.assertTrue(Path(plan["report_path"]).is_file())
        report = Path(plan["report_path"]).read_text()
        self.assertIn("不会自动删除任何文件", report)
        self.assertIn(str(pip_cache), report)
        self.assertNotIn("PACKY_API_KEY", Path(plan["plan_path"]).read_text())

    def test_execute_removes_only_explicitly_selected_entry_once(self):
        pip_cache, keep, recent = self.make_candidates()
        plan = create_plan(state_dir=self.state, roots=[(self.root / "cache", "cache")],
                           min_age_days=7, max_candidates=20,
                           client=FakeJevClient(delete_names={"pip"}),
                           review_client=FakeReviewClient())
        selected_id = plan["entries"][0]["id"]
        result = execute_plan(state_dir=self.state, plan_path=plan["plan_path"],
                              confirm=plan["plan_id"], selected_ids=[selected_id])

        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["summary"], {"selected_count": 1, "selected_bytes": 100,
                                             "deleted_count": 1, "deleted_bytes": 100, "skipped_count": 0})
        self.assertFalse(pip_cache.exists())
        self.assertTrue(keep.exists())
        self.assertTrue(recent.exists())
        with self.assertRaisesRegex(DataError, "已经执行过"):
            execute_plan(state_dir=self.state, plan_path=plan["plan_path"],
                         confirm=plan["plan_id"], selected_ids=[selected_id])

    def test_execute_rejects_missing_unknown_duplicate_or_unreviewed_selection(self):
        pip_cache, keep, recent = self.make_candidates()
        plan = create_plan(state_dir=self.state, roots=[(self.root / "cache", "cache")],
                           min_age_days=7, max_candidates=20,
                           client=FakeJevClient(delete_names={"pip"}),
                           review_client=FakeReviewClient())
        selected_id = plan["entries"][0]["id"]
        rejected_id = plan["entries"][1]["id"]
        cases = [
            ([], "至少指定一个"),
            (["missing"], "条目不存在"),
            ([selected_id, selected_id], "不能重复"),
            ([rejected_id], "JEV 初筛未通过"),
        ]
        for selected_ids, message in cases:
            with self.subTest(selected_ids=selected_ids):
                with self.assertRaisesRegex(DataError, message):
                    execute_plan(state_dir=self.state, plan_path=plan["plan_path"],
                                 confirm=plan["plan_id"], selected_ids=selected_ids)
        self.assertTrue(pip_cache.exists())
        self.assertTrue(keep.exists())

    def test_execute_skips_changed_selected_entry(self):
        pip_cache, keep, recent = self.make_candidates()
        plan = create_plan(state_dir=self.state, roots=[(self.root / "cache", "cache")],
                           min_age_days=7, max_candidates=20,
                           client=FakeJevClient(delete_names={"pip"}),
                           review_client=FakeReviewClient())
        (pip_cache / "new-file").write_bytes(b"changed")
        result = execute_plan(state_dir=self.state, plan_path=plan["plan_path"],
                              confirm=plan["plan_id"], selected_ids=[plan["entries"][0]["id"]])

        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["summary"]["skipped_count"], 1)
        self.assertEqual(result["results"][0]["execution_status"], "changed")
        self.assertTrue(pip_cache.exists())

    def test_jev_client_sends_metadata_without_file_content(self):
        entry = {
            "root_kind": "cache", "relative_path": "pip", "kind": "directory",
            "size_bytes": 100, "age_days": 8,
        }
        client = JevClient(api_key="secret", base_url="https://example.test/v1/",
                           model="jev-test", threshold=0.8, timeout=3)
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            def read(self):
                return json.dumps({"model": "jev-1", "answers": {"deletable": {"type": "noul", "noul": 0.9}}}).encode()

        def fake_urlopen(request, timeout):
            requests.append((request, timeout))
            return Response()

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            result = client.request(entry)

        request, timeout = requests[0]
        self.assertEqual(request.full_url, "https://example.test/v1/systemone")
        self.assertEqual(request.get_header("Authorization"), "Bearer secret")
        self.assertEqual(timeout, 3)
        payload = json.loads(request.data.decode())
        self.assertEqual(payload["state"]["entry"], entry)
        self.assertEqual(result, {"decision": "delete", "jev_probability": 0.9, "jev_model": "jev-1"})

    def test_llm_review_client_uses_openai_compatible_endpoint_and_parses_risk(self):
        entry = {"id": "a" * 32, "root_kind": "cache", "relative_path": "pip", "kind": "directory",
                 "size_bytes": 100, "age_days": 8}
        client = LLMReviewClient(base_url="http://127.0.0.1:11434/v1", model="qwen-test", timeout=4)
        requests = []

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            def read(self):
                return json.dumps({
                    "model": "qwen-server",
                    "choices": [{"message": {"content": json.dumps({
                        "results": [{
                            "id": entry["id"], "recommendation": "delete", "risk_level": "low",
                            "risk_score": 15, "reason": "常见缓存目录",
                        }],
                    }, ensure_ascii=False)}}],
                }).encode()

        def fake_urlopen(request, timeout):
            requests.append((request, timeout))
            return Response()

        with patch("urllib.request.urlopen", side_effect=fake_urlopen):
            results = client.review([entry])

        request, timeout = requests[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:11434/v1/chat/completions")
        self.assertEqual(timeout, 4)
        payload = json.loads(request.data.decode())
        self.assertEqual(payload["model"], "qwen-test")
        self.assertIn('"results"', payload["messages"][0]["content"])
        self.assertEqual(json.loads(payload["messages"][1]["content"])["candidates"], [{
            "id": entry["id"], "root_kind": "cache", "relative_path": "pip",
            "kind": "directory", "size_bytes": 100, "age_days": 8,
        }])
        self.assertEqual(results[0]["llm_recommendation"], "delete")
        self.assertEqual(results[0]["risk_level"], "low")
        self.assertEqual(results[0]["risk_score"], 15)

    def test_llm_review_client_rejects_remote_http_and_invalid_result(self):
        with self.assertRaisesRegex(DataError, "https URL"):
            LLMReviewClient(base_url="http://example.test/v1")

        client = LLMReviewClient()

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc_value, traceback):
                return False

            def read(self):
                return json.dumps({"choices": [{"message": {"content": "{\"results\": []}"}}]}).encode()

        with patch("urllib.request.urlopen", return_value=Response()):
            with self.assertRaisesRegex(DataError, "缺少候选条目"):
                client.review([{"id": "a" * 32, "root_kind": "cache", "relative_path": "pip",
                                "kind": "directory", "size_bytes": 1, "age_days": 8}])

    def test_cli_generates_report_then_deletes_only_selected_entry(self):
        pip_cache, keep, recent = self.make_candidates()
        fake_jev = FakeJevClient(delete_names={"pip"})
        fake_review = FakeReviewClient()
        out = io.StringIO()
        with patch("ubuntu_setup.cli.default_roots", return_value=[(self.root / "cache", "cache")]), \
                patch("ubuntu_setup.cli.JevClient", return_value=fake_jev), \
                patch("ubuntu_setup.cli.LLMReviewClient", return_value=fake_review), redirect_stdout(out):
            code = main(["cleanup", "--state-dir", str(self.state), "--min-age-days", "7",
                         "--format", "json", "--no-open"])

        self.assertEqual(code, 0)
        plan = json.loads(out.getvalue())
        self.assertEqual(plan["browser_open"]["status"], "disabled")
        self.assertEqual(plan["summary"]["delete_recommendation_count"], 1)
        selected_id = plan["entries"][0]["id"]

        execution_out = io.StringIO()
        with redirect_stdout(execution_out):
            code = main(["cleanup", "--delete", "--state-dir", str(self.state),
                         "--plan-file", plan["plan_path"], "--confirm", plan["plan_id"],
                         "--select", selected_id, "--format", "json"])

        self.assertEqual(code, 0)
        execution = json.loads(execution_out.getvalue())
        self.assertEqual(execution["summary"]["deleted_count"], 1)
        self.assertFalse(pip_cache.exists())
        self.assertTrue(keep.exists())

    def test_cli_delete_requires_selection(self):
        pip_cache, keep, recent = self.make_candidates()
        out = io.StringIO()
        with patch("ubuntu_setup.cli.default_roots", return_value=[(self.root / "cache", "cache")]), \
                patch("ubuntu_setup.cli.JevClient", return_value=FakeJevClient(delete_names={"pip"})), \
                patch("ubuntu_setup.cli.LLMReviewClient", return_value=FakeReviewClient()), redirect_stdout(out):
            code = main(["cleanup", "--state-dir", str(self.state), "--format", "json", "--no-open"])
        plan = json.loads(out.getvalue())

        stderr = io.StringIO()
        with redirect_stderr(stderr):
            code = main(["cleanup", "--delete", "--state-dir", str(self.state),
                         "--plan-file", plan["plan_path"], "--confirm", plan["plan_id"], "--format", "json"])

        self.assertEqual(code, 2)
        self.assertIn("至少一个 --select", stderr.getvalue())
        self.assertTrue(pip_cache.exists())

    def test_capabilities_advertise_cleanup_boundaries(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = main(["capabilities", "--format", "json"])

        self.assertEqual(code, 0)
        result = json.loads(out.getvalue())
        operation = next(item for item in result["operations"] if item["id"] == "cleanup")
        self.assertIn("PackyApi JEV 初筛", operation["purpose"])
        self.assertIn("独立 LLM", operation["purpose"])
        self.assertTrue(operation["network_access"])
        self.assertIn("--select <entry-id>", operation["human_confirmation"])
        self.assertIn("plan_disk_cleanup", result["agent_interface"]["commands"])
        self.assertIn("明确选择条目 ID", " ".join(result["agent_interface"]["result_policy"]))


if __name__ == "__main__":
    unittest.main()
