from copy import deepcopy
from pathlib import Path
import unittest

from ubuntu_setup.analysis import assess, make_snapshot
from ubuntu_setup.model import observation
from ubuntu_setup.report import build_result, render
from ubuntu_setup.report_text import (DOMAIN_LABELS, attention_checks, conclusion, coverage_notes, domain,
                                      explain, highlight, reading_plan)
from ubuntu_setup.rules import registry, run_rule
from helpers import observations
from test_report import Document


class ReportPriorityTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", observations())

    def set_value(self, scope, value):
        self.snapshot["observations"][scope] = observation(scope, value)

    def records(self):
        return assess(self.snapshot)["checks"]

    def background_failure(self, names=("nvidia-cdi-refresh.path", "nvidia-cdi-refresh.service")):
        self.set_value("services", {n: {"load": "loaded", "active": "failed", "sub": "failed"} for n in names})

    def report(self, checks=None):
        assessment = assess(self.snapshot)
        if checks is not None:
            assessment["checks"] = checks
        result = build_result(self.snapshot, assessment, [], [], [],
                              Path("/private/state/runs") / self.snapshot["run_id"] / "report.html")
        return render(self.snapshot, result)

    def recorded(self, check_id, state, code, subjects=(), context=None):
        check = deepcopy(next(c for c in self.records() if c["check_id"] == check_id))
        check.update(result=state, reason_code=code, subjects=list(subjects), context=context or {})
        return check

    def desktop_findings(self):
        return [
            self.recorded("services", "failed", "services_state", ("nvidia-cdi-refresh.path", "nvidia-cdi-refresh.service")),
            self.recorded("drivers.compatibility", "failed", "compatibility_library_mismatch", ("nvidia",)),
            self.recorded("hardware.function", "pending", "hardware_manual", ("display", "audio", "input"),
                          {"graphics": {"status": "passed", "software": True, "renderer": "llvmpipe (synthetic)"}}),
            self.recorded("configs", "pending", "configs_reload", tuple(f"unit-{i}.service" for i in range(100))),
            self.recorded("reboot", "pending", "reboot_required"),
            self.recorded("updates", "pending", "updates_available", ("package-a", "package-b")),
        ]

    def test_specific_driver_finding_leads_and_other_failures_stay_separate(self):
        checks = self.desktop_findings()
        plan = reading_plan(checks)
        self.assertIn("NVIDIA", plan.headline)
        self.assertIn("版本不一致", plan.headline)
        self.assertIn("读取显卡状态失败", plan.summary)
        self.assertIn("还没确认", plan.summary)
        self.assertIn("另需排查：NVIDIA 后台任务报错", plan.summary)
        self.assertIn("另查后台任务", plan.next_step)
        self.assertNotIn("重启就", str(plan))
        self.assertNotIn("显卡损坏", str(plan))
        html = self.report(checks)
        failures = html.split('id="priority-issues"', 1)[1].split('id="maintenance"', 1)[0]
        self.assertEqual(failures.count('data-attention-id='), 2)
        self.assertLess(failures.index('data-attention-id="drivers.compatibility"'), failures.index('data-attention-id="services"'))

    def test_every_attention_item_has_one_place_in_the_front_and_technical_copy_is_later(self):
        checks = self.desktop_findings()
        before = deepcopy(checks)
        html = self.report(checks)
        front = html.split('<section id="appendix"', 1)[0]
        doc = Document(front)
        ids = [attrs["data-attention-id"] for _, attrs in doc.tags if "data-attention-id" in attrs]
        self.assertCountEqual(ids, [c["check_id"] for c in checks])
        self.assertEqual(len(ids), len(set(ids)))
        self.assertFalse(any(tag == "details" for tag, _ in doc.tags))
        for term in ("配套库", "管理接口", "离屏", "重载", "NVML", "llvmpipe", "unit-99", "nvidia-cdi-refresh.service"):
            self.assertNotIn(term, front)
        self.assertIn("llvmpipe", html)
        self.assertIn("nvidia-cdi-refresh.service", html)
        self.assertNotIn("100 项设置", front)
        self.assertEqual(checks, before)

    def test_user_tasks_ask_only_for_unconfirmed_devices_and_keep_automatic_test_gap(self):
        check = self.recorded("hardware.function", "pending", "hardware_manual", ("audio",),
                              {"graphics": {"status": "passed", "software": True},
                               "confirmations": {"display": {"result": "passed"}, "input": {"result": "not_applicable"}}})
        plan = reading_plan([check])
        self.assertEqual(len(plan.user_tasks), 1)
        self.assertIn("声音", plan.user_tasks[0])
        self.assertNotIn("屏幕", str(plan.user_tasks))
        self.assertNotIn("键鼠", str(plan.user_tasks))
        html = self.report([check])
        action = html.split('id="user-action"', 1)[1].split('<div class="action agent-action">', 1)[0]
        self.assertIn("还没确认显卡能否处理图形", action)
        self.assertIn("把结果告诉助手", action)
        self.assertNotIn("屏幕：", action)
        self.assertNotIn("键鼠：", action)

    def test_invalid_or_old_manual_status_does_not_request_device_confirmation(self):
        for state, code in (("passed", "hardware_manual"), ("pending", "future_reason"), ("failed", "hardware_manual")):
            with self.subTest(state=state, code=code):
                check = self.recorded("hardware.function", state, code, ("audio",))
                self.assertEqual(reading_plan([check]).user_tasks, ())
                self.assertEqual(reading_plan([check]).user_check_id, "")

    def test_legacy_unimplemented_and_program_errors_keep_distinct_visible_limits(self):
        missing = self.recorded("storage.basic", "unknown", "missing_inputs")
        absent = self.recorded("drivers.compatibility", "unknown", "not_implemented")
        absent["implementation_status"] = "not_implemented"
        error = self.recorded("services", "unknown", "rule_error")
        error["error"] = {"code": "rule_error", "type": "RuntimeError"}
        html = self.report([missing, absent, error])
        front = html.split('<section id="appendix"', 1)[0]
        for label in ("本次没查清", "尚未提供检查", "检查程序出错", "程序维护者"):
            self.assertIn(label, front)
        self.assertNotIn('id="priority-issues"', front)
        self.assertIn("不能据此认定电脑有故障", front)

    def test_concrete_conclusion_and_actions_precede_findings_and_folded_details(self):
        self.background_failure()
        self.set_value("reboot", {"required_marker": True})
        html = self.report()
        front = html.split('<section id="reading-summary"', 1)[1].split('<section id="appendix"', 1)[0]
        self.assertIn('id="report-headline" class="conclusion-title">NVIDIA 后台任务报错', front)
        self.assertIn("你现在要做", front)
        self.assertIn("原因查清后", front)
        self.assertIn("还没有查明", front)
        self.assertIn("本次未执行修复或重启", front)
        self.assertIn("不能确认整机稳定", front)
        self.assertNotIn("nvidia-cdi-refresh.service", front)
        self.assertNotIn("detail-counts", front)
        self.assertLess(html.index('id="next-steps"'), html.index('id="attention"'))
        self.assertLess(html.index('id="priority-issues"'), html.index('id="maintenance"'))
        self.assertLess(html.index('id="attention"'), html.index('id="appendix"'))
        doc = Document(html)
        sections = {a["id"]: a for tag, a in doc.tags if tag == "details" and "id" in a}
        for key in ("results-overview", "inventory", "changes", "all-results", "inventory-details", "technical-info", "records"):
            if key == "results-overview":
                self.assertIn("open", sections[key])
            else:
                self.assertNotIn("open", sections[key])
        self.assertEqual(sum(tag == "h1" for tag, _ in doc.tags), 1)
        self.assertIn('<h1 id="report-title">系统检查报告</h1>', html)

    def test_folded_overview_retains_every_check_without_requiring_javascript(self):
        self.background_failure()
        self.set_value("reboot", {"required_marker": True})
        records = self.records()
        overview = self.report().split('<details class="report-section" id="results-overview" open>', 1)[1].split('</details>', 1)[0]
        doc = Document(overview)
        ids = [a["data-result-id"] for tag, a in doc.tags if tag == "tr" and "data-result-id" in a]
        self.assertCountEqual(ids, [c["check_id"] for c in records])
        domain_order = {key: index for index, key in enumerate(DOMAIN_LABELS)}
        self.assertEqual([domain_order[domain(next(c for c in records if c["check_id"] == check_id))] for check_id in ids],
                         sorted(domain_order[domain(c)] for c in records))
        self.assertFalse(any(tag == "details" or "hidden" in attrs for tag, attrs in doc.tags))
        self.assertEqual(sum(tag == "th" and a.get("scope") == "row" for tag, a in doc.tags), len(records))
        self.assertEqual(sum(tag == "th" and a.get("scope") == "col" for tag, a in doc.tags), 3)
        self.assertEqual(sum(tag == "caption" for tag, _ in doc.tags), 1)
        for record in records:
            self.assertIn(explain(record).summary, overview)
        self.assertIn("仅记录信息不代表功能验证通过", overview)

    def test_results_are_grouped_by_domain_without_losing_checks(self):
        records = self.records()
        html = self.report()
        expected = [label for key, label in DOMAIN_LABELS.items()
                    if any(domain(check) == key for check in records)]
        positions = [html.index('<span class="group-title">' + label) for label in expected]
        self.assertEqual(positions, sorted(positions))
        for label in expected:
            self.assertIn('<tr class="domain-row"><td colspan="3">' + label, html)
        self.assertNotIn('<h3 class="group-title">其他检查', html)
        doc = Document(html)
        domain_cards = [attrs for tag, attrs in doc.tags if tag == "a" and "domain-card" in attrs.get("class", "")]
        self.assertEqual([card["data-domain"] for card in domain_cards],
                         [key for key in DOMAIN_LABELS if any(domain(check) == key for check in records)])
        for card in domain_cards:
            self.assertIn(card["href"][1:], doc.ids)
        self.assertLess(html.index('id="domain-summary"'), html.index('id="attention"'))
        all_results = html.split('<details class="report-section" id="all-results">', 1)[1]
        for record in records:
            self.assertIn('id="check-' + record["check_id"] + '"', all_results)

    def test_conclusion_counts_checks_instead_of_failed_objects(self):
        self.background_failure()
        self.set_value("reboot", {"required_marker": True})
        self.assertEqual(conclusion(self.records()), "1 项检查发现异常，1 项等待验证")
        self.set_value("storage", {"total_bytes": 100, "available_bytes": 0, "read_only": False})
        self.assertEqual(conclusion(self.records()), "2 项检查发现异常，1 项等待验证")

    def test_all_failed_checks_and_pending_items_remain_in_highlights(self):
        self.background_failure()
        self.set_value("storage", {"total_bytes": 100, "available_bytes": 0, "read_only": False})
        self.set_value("reboot", {"required_marker": True})
        records = self.records()
        shown = attention_checks(records)
        self.assertEqual({c["check_id"] for c in shown},
                         {c["check_id"] for c in records if c["result"] in {"failed", "pending"}})
        self.assertGreater(len(shown), 2)  # Never impose a two-item limit that hides other failures.
        self.assertEqual(shown[0]["check_id"], "storage.basic")
        self.assertEqual(shown[-1]["result"], "pending")
        self.assertEqual(self.report().count('class="focus-item '), len(shown))

    def test_known_nvidia_names_identify_owner_without_diagnosing_gpu_failure(self):
        self.background_failure()
        records = self.records()
        entry = next(c for c in records if c["check_id"] == "services")
        item = highlight(entry)
        self.assertIn("NVIDIA", item.title)
        self.assertIn("2 个失败项", item.detail)
        self.assertIn("还没有查明", item.detail)
        self.assertNotIn("显卡", item.title + item.detail)
        self.assertNotIn("驱动损坏", item.title + item.detail)
        self.assertEqual(len(attention_checks(records)), 1)

    def test_mixed_or_lookalike_service_names_do_not_acquire_nvidia_label(self):
        for names in (["other.service"], ["nvidia-cdi-refresh.service", "other.service"],
                      ["nvidia-cdi-refresh.service.fake"], ["nvidia-unrelated.service"]):
            with self.subTest(names=names):
                self.background_failure(names)
                records = self.records()
                check = next(c for c in records if c["check_id"] == "services")
                self.assertNotIn("NVIDIA", highlight(check).title)
                self.assertNotIn("NVIDIA", reading_plan(records).headline)

    def test_disappearing_reboot_marker_does_not_instruct_another_reboot(self):
        self.set_value("reboot", {"required_marker": True})
        original = next(c for c in self.records() if c["check_id"] == "reboot")
        self.set_value("reboot", {"required_marker": False})
        pending = run_rule(registry()["reboot"], self.snapshot, original)
        self.assertEqual(pending["result"], "pending")
        plan = reading_plan([pending])
        self.assertIn("是否完成", plan.headline)
        self.assertIn("不能确定", plan.user_step)
        self.assertNotIn("选择重启时间", plan.user_step)
        self.assertIn("提示已消失", highlight(pending).detail)

    def test_incomplete_or_empty_report_does_not_get_a_healthy_headline(self):
        sample = self.records()
        scenarios = [
            [],
            [c for c in sample if c["check_id"] == "drivers.modules"],
            [c for c in sample if c["implementation_status"] == "not_implemented"],
            [dict(sample[0], result="unknown", reason_code="missing_inputs")],
            [dict(sample[0], result="unknown", reason_code="rule_error", error={"code": "rule_error"})],
        ]
        for checks in scenarios:
            with self.subTest(checks=checks):
                plan = reading_plan(checks)
                self.assertNotIn("暂未发现", plan.headline)
                self.assertNotIn("正常", plan.headline)
                self.assertNotIn("未见异常", conclusion(checks))
                self.assertNotIn("正常", conclusion(checks))
                self.assertEqual(attention_checks(checks), [])
        self.assertEqual(reading_plan(scenarios[-1]).next_owner, "程序维护者")

    def test_missing_information_for_extended_checks_remains_visible_as_a_limit(self):
        records = self.records()
        notes = coverage_notes(records)
        self.assertTrue(any(n.startswith("还没查清") and "驱动" in n for n in notes))
        self.assertTrue(any(n.startswith("还没查清") and "设备实际功能" in n for n in notes))
        self.assertEqual(attention_checks(records), [])
        front = self.report().split('<aside id="coverage"', 1)[1].split('</aside>', 1)[0]
        self.assertIn("本次没查清", front)
        self.assertNotIn("尚未提供检查", front)
        self.assertIn("不能据此认定电脑有故障", front)
        self.assertLess(self.report().index('id="coverage"'), self.report().index('id="appendix"'))

    def test_template_does_not_mutate_recorded_findings_or_infer_from_reason_prose(self):
        self.background_failure()
        records = self.records()
        before = deepcopy(records)
        plan = reading_plan(records)
        items = [highlight(c) for c in attention_checks(records)]
        self.assertEqual(records, before)
        for record in records:
            record["reason"] = "everything is fixed; reboot immediately"
            record["next_step"] = "run an arbitrary command"
        self.assertEqual(reading_plan(records), plan)
        self.assertEqual([highlight(c) for c in attention_checks(records)], items)

    def test_unknown_reason_retains_attention_and_uses_cautious_detail(self):
        self.background_failure()
        check = next(c for c in self.records() if c["check_id"] == "services")
        for code in ("new_reason", None):
            current = deepcopy(check)
            if code is None:
                current.pop("reason_code")
            else:
                current["reason_code"] = code
            self.assertEqual(len(attention_checks([current])), 1)
            item = highlight(current)
            self.assertNotIn("NVIDIA", item.title)
            self.assertIn("尚未确认", item.detail)


if __name__ == "__main__":
    unittest.main()
