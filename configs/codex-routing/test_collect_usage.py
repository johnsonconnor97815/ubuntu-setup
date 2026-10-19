import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from collect_usage import collect


def usage(total):
    return dict(input_tokens=total - 2, cached_input_tokens=3,
                cache_write_input_tokens=0, output_tokens=2,
                reasoning_output_tokens=1, total_tokens=total)


class CollectorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.db = self.base / "state.sqlite"
        with sqlite3.connect(self.db) as c:
            c.execute("CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, model TEXT, reasoning_effort TEXT)")
            c.execute("CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT, status TEXT)")

    def add_thread(self, name, records, parent=None):
        path = self.base / (name + ".jsonl")
        path.write_text("\n".join(json.dumps(x) for x in records), encoding="utf-8")
        with sqlite3.connect(self.db) as c:
            c.execute("INSERT INTO threads VALUES (?, ?, 'stale-model', 'high')", (name, str(path)))
            if parent:
                c.execute("INSERT INTO thread_spawn_edges VALUES (?, ?, 'running')", (parent, name))

    def test_tree_latest_totals_actual_model_and_completion(self):
        self.add_thread("root", [
            {"type": "turn_context", "payload": {"model": "astra", "effort": "medium"}},
            {"type": "token_usage_record", "payload": {"thread_token_usage": usage(10)}},
            {"type": "token_usage_record", "payload": {"thread_token_usage": usage(20)}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": usage(20)}}},
            {"type": "event_msg", "timestamp": "done", "payload": {"type": "task_complete"}}])
        self.add_thread("child", [
            {"type": "turn_context", "payload": {"model": "luna", "effort": "low"}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": usage(8)}}}], "root")
        result = collect("root", self.db)
        self.assertEqual(result["totals"]["total_tokens"], 28)
        self.assertEqual(result["threads"][0]["model"], "astra")
        self.assertEqual(result["threads"][0]["completion_timestamp"], "done")
        self.assertEqual(result["by_model"]["luna"]["totals"]["total_tokens"], 8)
        self.assertFalse(result["all_threads_completed"])

    def test_missing_usage_unknown_and_no_descendants(self):
        self.add_thread("root", [{"type": "turn_context", "payload": {"model": "sol"}}])
        result = collect("root", self.db)
        self.assertEqual(result["thread_count"], 1)
        self.assertIsNone(result["totals"])
        self.assertFalse(result["telemetry_complete"])
        self.assertIsNone(result["threads"][0]["usage"])

    def test_model_switch_not_allocated_to_last_model(self):
        self.add_thread("root", [
            {"type": "turn_context", "payload": {"model": "astra"}},
            {"type": "turn_context", "payload": {"model": "sol"}},
            {"type": "token_usage_record", "payload": {"thread_token_usage": usage(10)}}])
        result = collect("root", self.db)
        self.assertTrue(result["telemetry_complete"])
        self.assertFalse(result["model_allocation_complete"])
        self.assertIn("unknown", result["by_model"])

    def test_older_fallback_preserves_richer_same_total(self):
        fallback = usage(10)
        del fallback["cache_write_input_tokens"]
        self.add_thread("root", [
            {"type": "turn_context", "payload": {"model": "sol"}},
            {"type": "token_usage_record", "payload": {"thread_token_usage": usage(10)}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"total_token_usage": fallback}}}])
        self.assertTrue(collect("root", self.db)["telemetry_complete"])

    def test_malformed_records_and_missing_fields_unknown(self):
        self.add_thread("root", [[],
            {"type": "event_msg", "payload": {"type": "token_count", "info": "bad"}},
            {"type": "token_usage_record", "payload": {"thread_token_usage": {"total_tokens": 10}}}])
        result = collect("root", self.db)
        self.assertFalse(result["telemetry_complete"])
        self.assertIsNone(result["totals"])
        self.assertEqual(len(result["threads"][0]["errors"]), 2)


if __name__ == "__main__":
    unittest.main()
