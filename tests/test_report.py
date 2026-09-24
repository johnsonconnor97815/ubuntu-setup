import base64
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
import unittest

from ubuntu_setup.analysis import assess, make_snapshot
from ubuntu_setup.model import observation
from ubuntu_setup.report import build_result, render
from helpers import observations


class Document(HTMLParser):
    def __init__(self, content):
        super().__init__()
        self.tags = []
        self.ids = []
        self.links = []
        self.csp = ""
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        self.tags.append((tag, attributes))
        if "id" in attributes:
            self.ids.append(attributes["id"])
        if "href" in attributes:
            self.links.append(attributes["href"])
        if tag == "meta" and attributes.get("http-equiv") == "Content-Security-Policy":
            self.csp = attributes["content"]


class HtmlReportTests(unittest.TestCase):
    def setUp(self):
        self.observations = observations()

    def report(self, changes=None):
        snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", self.observations)
        assessment = assess(snapshot)
        result = build_result(snapshot, assessment, changes or [], [], [],
                              Path("/private/state/runs") / snapshot["run_id"] / "report.html")
        return render(snapshot, result)

    def test_report_is_standalone_and_evidence_links_resolve(self):
        content = self.report()
        doc = Document(content)
        self.assertTrue(content.startswith("<!doctype html>"))
        self.assertIn("模拟数据 · 不是本机检测", content)
        self.assertEqual(len(doc.ids), len(set(doc.ids)))
        for link in doc.links:
            if link.startswith("#"):
                self.assertIn(link[1:], doc.ids)
            else:
                self.assertTrue(link.endswith(".json"))
                self.assertNotIn("://", link)
        self.assertFalse(any("src" in attrs or tag == "link" for tag, attrs in doc.tags))
        self.assertIn("observation-packages-dpkg", doc.ids)
        self.assertIn("未完成安装", content)
        self.assertIn("nano", content)

    def test_machine_data_and_check_text_cannot_insert_executable_html(self):
        attack = '</script><img src="https://example.invalid/steal" onerror="alert(1)"> & <svg/onload=alert(2)>'
        self.observations["resources"]["value"]["cpu_model"] = attack
        self.observations["services"] = observation("services", {attack: {"load": "loaded", "active": "failed", "sub": "failed"}})
        content = self.report([{"scope": "configs", "subject": attack, "kind": "changed", "before": attack, "after": attack}])
        doc = Document(content)
        self.assertFalse(any(tag in {"img", "svg", "iframe"} for tag, _ in doc.tags))
        self.assertFalse(any(key.startswith("on") for _, attrs in doc.tags for key in attrs))
        self.assertEqual(sum(tag == "script" for tag, _ in doc.tags), 1)
        self.assertIn("&lt;img", content)
        self.assertNotIn(attack, content)

    def test_only_bundled_script_is_allowed_by_the_document_policy(self):
        content = self.report()
        script = re.search(r"<script>(.*?)</script>", content, re.S).group(1)
        digest = base64.b64encode(hashlib.sha256(script.encode()).digest()).decode()
        policy = Document(content).csp
        self.assertIn("script-src 'sha256-" + digest + "'", policy)
        self.assertIn("default-src 'none'", policy)
        self.assertNotIn("script-src 'unsafe-inline'", policy)

    def test_failed_and_pending_checks_appear_before_passed_results(self):
        self.observations["services"] = observation("services", {"synthetic.service": {"load": "loaded", "active": "failed", "sub": "failed"}})
        self.observations["reboot"]["value"]["required_marker"] = True
        doc = Document(self.report())
        states_by_domain = {}
        current_domain = None
        for tag, attrs in doc.tags:
            if tag == "details" and "data-domain" in attrs:
                current_domain = attrs["data-domain"]
            elif tag == "article" and "data-status" in attrs:
                states_by_domain.setdefault(current_domain, []).append(attrs["data-status"])
        self.assertEqual(states_by_domain["system"][0], "pending")
        self.assertEqual(states_by_domain["services"][0], "failed")
        priority = {"failed": 0, "pending": 1, "check_error": 2, "unknown": 3,
                    "not_implemented": 4, "passed": 5, "info": 6, "not_applicable": 7}
        for states in states_by_domain.values():
            priorities = [priority[state] for state in states]
            self.assertEqual(priorities, sorted(priorities))

    def test_all_changes_are_available_even_when_summary_is_long(self):
        changes = [{"scope": "packages.dpkg", "subject": f"synthetic-package-{index}", "kind": "added", "before": None, "after": {"version": "1"}} for index in range(43)]
        content = self.report(changes)
        self.assertIn("展开其余 3 项变化", content)
        self.assertIn("synthetic-package-42", content)

    def test_update_research_tasks_are_visible_but_not_executed(self):
        snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", self.observations)
        assessment = assess(snapshot)
        for record in assessment["checks"]:
            if record["check_id"] == "updates":
                record["result"] = "pending"
                record["reason_code"] = "updates_available"
                record["context"] = {"candidate_count": 1, "security_candidate_count": 0}
        result = build_result(snapshot, assessment, [], [], [],
                              Path("/private/state/runs") / snapshot["run_id"] / "report.html")
        content = render(snapshot, result)
        self.assertTrue(result["agent_research_tasks"])
        self.assertIn("复核更新是否会造成冲突", content)
        self.assertIn("调查更新是否稳定", content)
        self.assertIn("模拟方案是否要求新增安装、移除或降级", content)
        self.assertIn("更新后哪些服务可能需要重载或重启", content)
        self.assertIn("不构成执行授权", content)


if __name__ == "__main__":
    unittest.main()
