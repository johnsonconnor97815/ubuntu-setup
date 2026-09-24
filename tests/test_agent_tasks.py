import unittest

from ubuntu_setup.agent_tasks import build


def check(check_id, result, context=None, reason_code=""):
    return {"check_id": check_id, "result": result, "reason_code": reason_code,
            "context": context or {}}


class AgentTaskTests(unittest.TestCase):
    def test_offline_updates_request_online_refresh_before_research(self):
        tasks = build([
            check("updates", "unknown", {"candidate_count": 2}, "updates_cached"),
            check("packages.dependencies", "unknown", {}, "dependencies_unknown"),
        ])
        self.assertEqual(tasks[0]["task_id"], "refresh-apt-metadata")
        self.assertIn("--online", tasks[0]["command"])
        self.assertIn("network", tasks[0]["requires"])

    def test_update_research_covers_conflicts_and_stability(self):
        tasks = build([
            check("updates", "pending", {
                "candidate_count": 3,
                "security_candidate_count": 1,
                "candidates": [{"package": "sudo"}, {"package": "netplan.io"}],
            }, "updates_available"),
            check("packages.dependencies", "passed", {
                "actions": [
                    {"package": "sudo", "action": "upgrade"},
                    {"package": "helper", "action": "install"},
                ],
                "kept_back": ["dnsmasq-base"],
            }, "dependencies_ok"),
        ])
        by_id = {task["task_id"]: task for task in tasks}
        self.assertEqual(set(by_id), {"review-update-conflicts", "research-update-stability"})

        conflict = by_id["review-update-conflicts"]
        self.assertEqual(conflict["inputs"]["simulated_action_counts"], {"upgrade": 1, "install": 1})
        self.assertEqual(conflict["inputs"]["kept_back"], ["dnsmasq-base"])
        self.assertIn("移除", " ".join(conflict["questions"]))
        self.assertIn("conflict_found", conflict["output"]["conflict_status"])

        stability = by_id["research-update-stability"]
        self.assertIn("llm", stability["requires"])
        self.assertIn("web_search", stability["requires"])
        self.assertIn("已知问题", " ".join(stability["questions"]))
        self.assertIn("official vendor issue trackers and status pages",
                      stability["source_policy"]["preferred_sources"])
        self.assertIn("候选版本", stability["source_policy"]["exact_version_required"])
        self.assertTrue(any("候选版本、发行版和架构" in item for item in stability["constraints"]))
        self.assertIn("concerns_found", stability["output"]["stability_status"])
        self.assertTrue(any("执行授权" in item for item in stability["constraints"]))

    def test_current_updates_do_not_request_research(self):
        tasks = build([
            check("updates", "passed", {}, "updates_current"),
            check("packages.dependencies", "passed", {}, "dependencies_ok"),
        ])
        self.assertEqual(tasks, [])


if __name__ == "__main__":
    unittest.main()
