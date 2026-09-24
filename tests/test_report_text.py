from copy import deepcopy
from dataclasses import replace
from html.parser import HTMLParser
from pathlib import Path
import unittest

from ubuntu_setup.analysis import assess, make_snapshot
from ubuntu_setup.model import observation
from ubuntu_setup.report import build_result, render
from ubuntu_setup.report_text import CATEGORY_LABELS, CONTENT_VERSION, counts, domain_summary, explain
from ubuntu_setup.rules import registry, run_rule
from helpers import observations


class CardText(HTMLParser):
    """Separate a card's main explanation from its folded technical evidence."""

    def __init__(self, html):
        super().__init__()
        self.cards = {}
        self.card = None
        self.depth = 0
        self.start_depth = 0
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "details":
            self.depth += 1
        if tag == "article" and "data-check-id" in attrs:
            self.card = {"main": "", "details": ""}
            self.cards[attrs["data-check-id"]] = self.card
            self.start_depth = self.depth

    def handle_endtag(self, tag):
        if tag == "article":
            self.card = None
        if tag == "details":
            self.depth -= 1

    def handle_data(self, data):
        if self.card is not None:
            self.card["details" if self.depth > self.start_depth else "main"] += data


class UserWordingTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", observations())

    def set_value(self, scope, value):
        self.snapshot["observations"][scope] = observation(scope, value)

    def check(self, check_id):
        return next(c for c in assess(self.snapshot)["checks"] if c["check_id"] == check_id)

    def test_reading_information_is_not_displayed_as_system_health(self):
        for check_id in ("platform", "environment", "drivers.modules"):
            with self.subTest(check=check_id):
                record = self.check(check_id)
                self.assertEqual(record["result"], "passed")
                self.assertEqual(explain(record).category, "info")
                self.assertTrue(explain(record).impact)
        self.assertEqual(explain(self.check("packages.state")).category, "passed")
        self.assertIn("只核对安装记录", explain(self.check("packages.state")).impact)

    def test_missing_information_unimplemented_and_program_error_are_distinct(self):
        self.snapshot["observations"]["storage"] = observation("storage", status="unknown", reason="synthetic access failure")
        missing = self.check("storage.basic")
        absent = dict(self.check("drivers.compatibility"), implementation_status="not_implemented", rule_version="1")
        def broken(*args):
            raise RuntimeError("private")
        failure = run_rule(replace(registry()["services"], evaluate=broken), self.snapshot)
        self.assertEqual([c["result"] for c in (missing, absent, failure)], ["unknown"] * 3)
        self.assertEqual([explain(c).category for c in (missing, absent, failure)],
                         ["unknown", "not_implemented", "check_error"])
        self.assertEqual(explain(failure).action_owner, "程序维护者")
        self.assertNotIn("private", str(failure))

    def test_copy_does_not_parse_chinese_reason_or_change_the_record(self):
        record = self.check("storage.basic")
        before = deepcopy(record)
        expected = explain(record)
        self.assertEqual(record, before)
        record["reason"] = "系统已经损坏，立即强制重装"
        record["next_step"] = "execute arbitrary command"
        self.assertEqual(explain(record), expected)

    def test_two_failed_objects_are_not_two_diagnosed_causes(self):
        self.set_value("services", {
            "synthetic.path": {"load": "loaded", "active": "failed", "sub": "failed"},
            "synthetic.service": {"load": "loaded", "active": "failed", "sub": "failed"},
        })
        record = self.check("services")
        message = explain(record)
        self.assertIn("2 个后台项目", message.summary)
        self.assertIn("还没有查明", message.impact)
        self.assertIn("同一个原因", message.impact)
        self.assertEqual(message.action_owner, "系统助手")
        self.assertEqual(counts([record]), {"failed": 1})

    def test_reboot_marker_and_disappeared_marker_keep_different_explanations(self):
        self.set_value("reboot", {"required_marker": True})
        first = self.check("reboot")
        self.set_value("reboot", {"required_marker": False})
        later = run_rule(registry()["reboot"], self.snapshot, first)
        self.assertEqual((first["result"], later["result"]), ("pending", "pending"))
        self.assertIn("系统提示需要重启", explain(first).summary)
        self.assertIn("提示已消失", explain(later).summary)
        self.assertIn("还没有确认", explain(later).summary)
        self.assertNotEqual(first["reason_code"], later["reason_code"])
        self.assertEqual(explain(first).action_owner, "系统助手")
        self.assertIn("用户", explain(first).next_step)
        self.snapshot["observations"]["reboot"] = observation("reboot", status="unknown", reason="unreadable")
        unavailable = run_rule(registry()["reboot"], self.snapshot, later)
        self.assertEqual(unavailable["context"], first["context"])
        self.assertEqual(explain(unavailable).category, "unknown")
        self.assertIn("仍保留", explain(unavailable).impact)

    def test_disk_metadata_is_not_claimed_as_write_test_or_install_capacity(self):
        message = explain(self.check("storage.basic"))
        self.assertIn("尚未测试实际写入", message.impact)
        self.assertIn("需要多少空间", message.impact)
        for available, read_only in ((0, False), (1, True), (0, True)):
            with self.subTest(available=available, read_only=read_only):
                self.set_value("storage", {"total_bytes": 100, "available_bytes": available, "read_only": read_only})
                self.assertEqual(explain(self.check("storage.basic")).category, "failed")

    def test_guest_environment_does_not_claim_host_drivers_verified(self):
        for kind in ("container", "wsl"):
            with self.subTest(kind=kind):
                self.set_value("environment", {"kind": kind, "technology": "synthetic"})
                message = explain(self.check("drivers.compatibility"))
                self.assertEqual(message.category, "not_applicable")
                self.assertIn("目标电脑", message.impact)
                self.assertIn("尚未验证", explain(self.check("platform")).summary)

    def test_legacy_unknown_reason_and_wrong_result_use_cautious_fallback(self):
        for code in (None, "future_reason", "services_state"):
            record = self.check("storage.basic")
            if code is None:
                record.pop("reason_code")
            else:
                record["reason_code"] = code
            self.assertEqual(explain(record).category, "passed")
            self.assertIn("不能据此扩大判断范围", explain(record).impact)
        record = self.check("storage.basic")
        record["result"] = "pending"
        self.assertEqual(explain(record).category, "pending")
        self.assertIn("等待验证", explain(record).summary)

    def test_all_current_checks_have_reviewed_copy_and_counts_remain_complete(self):
        records = assess(self.snapshot)["checks"]
        self.assertEqual(sum(counts(records).values()), len(records))
        self.assertEqual(counts(records)["not_implemented"], 0)
        self.assertEqual(counts(records)["info"], 3)
        for record in records:
            with self.subTest(check=record["check_id"]):
                self.assertTrue(record["reason_code"])
                message = explain(record)
                self.assertIn(message.category, CATEGORY_LABELS)
                self.assertNotIn("当前没有对应的详细说明", message.impact)

    def test_domain_summary_keeps_pending_and_unknown_visible(self):
        records = [
            {"check_id": "hardware.function", "result": "pending"},
            {"check_id": "drivers.compatibility", "result": "unknown"},
        ]
        self.assertEqual(domain_summary(records), ("pending", "1 项待确认 · 1 项没查清"))

    def test_main_cards_keep_uncertainty_and_hide_technical_identifiers(self):
        self.set_value("services", {"synthetic.service": {"load": "loaded", "active": "failed", "sub": "failed"}})
        assessment = assess(self.snapshot)
        result = build_result(self.snapshot, assessment, [], [], [],
                              Path("/private/state/runs") / self.snapshot["run_id"] / "report.html")
        page = render(self.snapshot, result)
        cards = CardText(page).cards
        self.assertIn("还没有查明", cards["services"]["main"])
        self.assertNotIn("synthetic.service", cards["services"]["main"])
        self.assertIn("synthetic.service", cards["services"]["details"])
        self.assertIn("尚未确定原因", cards["services"]["details"])
        self.assertEqual(result["report_content_version"], CONTENT_VERSION)
        self.assertEqual(result["checks"], assessment["checks"])
        self.assertIn('name="report-content-version" content="' + CONTENT_VERSION + '"', page)


if __name__ == "__main__":
    unittest.main()
