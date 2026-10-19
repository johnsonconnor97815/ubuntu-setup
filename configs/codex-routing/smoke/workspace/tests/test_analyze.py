import json
import subprocess
import sys
import unittest
from pathlib import Path

from analyze import summarize

ROOT = Path(__file__).resolve().parents[1]
EMPTY = dict(valid_records=0, unique_events=0, duplicate_records=0,
             invalid_lines=[], ignored_lines=0, error_ids_by_service={}, retry_ids=[])


def event(**updates):
    record = dict(event_id="x", service="api", level="INFO", attempt=1, message="ok")
    record.update(updates)
    return json.dumps(record)


class Acceptance(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(summarize([]), EMPTY)

    def test_noise_and_message_are_not_errors(self):
        self.assertEqual(summarize(["ERROR", "", "  stack ERROR", event(message="ERROR tests passed")]),
                         dict(EMPTY, valid_records=1, unique_events=1, ignored_lines=3))

    def test_first_valid_id_wins_across_services(self):
        lines = [event(level="ERROR", attempt=2), event(service="other", level="ERROR"), event()]
        self.assertEqual(summarize(lines), dict(EMPTY, valid_records=3, unique_events=1,
                         duplicate_records=2, error_ids_by_service={"api": ["x"]}, retry_ids=["x"]))

    def test_invalid_does_not_reserve_id(self):
        lines = [event(attempt=0), event(level="ERROR")]
        self.assertEqual(summarize(lines), dict(EMPTY, valid_records=1, unique_events=1,
                         invalid_lines=[1], error_ids_by_service={"api": ["x"]}))

    def test_invalid_fields(self):
        missing = json.loads(event()); del missing["message"]
        lines = ["{bad", json.dumps(missing), event(event_id=3), event(service="  "),
                 event(level="error"), event(attempt=True), event(attempt=1.5),
                 event(attempt=-1), event(message=None), event(event_id="")]
        self.assertEqual(summarize(lines), dict(EMPTY, invalid_lines=list(range(1, 11))))

    def test_sorted_and_extra_fields(self):
        lines = ["  " + event(event_id="z", level="ERROR", attempt=3, extra=True),
                 event(event_id="a", level="ERROR", attempt=2), event(event_id="b", level="WARN")]
        self.assertEqual(summarize(lines), dict(EMPTY, valid_records=3, unique_events=3,
                         error_ids_by_service={"api": ["a", "z"]}, retry_ids=["a", "z"]))

    def test_fixture(self):
        expected = dict(valid_records=30, unique_events=20, duplicate_records=10,
                        invalid_lines=list(range(34, 42)), ignored_lines=10,
                        error_ids_by_service={"api": ["e03", "e12", "e20"], "worker": ["e07", "e16"]},
                        retry_ids=["e05", "e07", "e12", "e18"])
        self.assertEqual(json.loads((ROOT / "expected-summary.json").read_text()), expected)
        self.assertEqual(summarize((ROOT / "app.log").read_text().splitlines()), expected)

    def test_cli(self):
        result = subprocess.run([sys.executable, str(ROOT / "analyze.py"), str(ROOT / "app.log")],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), json.loads((ROOT / "expected-summary.json").read_text()))


if __name__ == "__main__":
    unittest.main()
