from copy import deepcopy
from dataclasses import replace
import json
import unittest
from unittest.mock import patch

from ubuntu_setup.analysis import assess, compare, invalidate, make_snapshot
from ubuntu_setup.model import COLLECTOR_VERSION, DataError, observation
from ubuntu_setup.rules import Outcome, RULES, describe_rules, registry, run_rule
from helpers import observations


def by_id(assessment, check_id):
    return next(c for c in assessment["checks"] if c["check_id"] == check_id)


class RuleTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", observations())

    def set_value(self, scope, value):
        self.snapshot["observations"][scope] = observation(scope, value)

    def result(self, check_id):
        return by_id(assess(self.snapshot), check_id)

    def test_individual_check_is_pure_and_does_not_construct_probes(self):
        before = deepcopy(self.snapshot)
        with patch("builtins.open", side_effect=AssertionError("IO forbidden")), \
                patch("ubuntu_setup.collect.LocalProbe", side_effect=AssertionError("probe forbidden")):
            result = run_rule(registry()["storage.basic"], self.snapshot)
        self.assertEqual(result["result"], "passed")
        self.assertEqual(self.snapshot, before)

    def test_result_evidence_identifies_actual_input_including_unknown(self):
        self.snapshot["observations"]["packages.dpkg"] = observation("packages.dpkg", status="unknown", reason="工具缺失")
        result = self.result("packages.state")
        self.assertEqual(result["result"], "unknown")
        ref = result["evidence_refs"][0]
        obs = self.snapshot["observations"]["packages.dpkg"]
        self.assertEqual((ref["snapshot_id"], ref["observation_id"], ref["observed_at"]),
                         (self.snapshot["snapshot_id"], obs["observation_id"], obs["observed_at"]))
        self.assertEqual(ref["status"], "unknown")
        self.assertEqual(result["unavailable_inputs"][0]["reason"], "工具缺失")

    def test_missing_required_input_does_not_invoke_rule_or_reuse_old_pass(self):
        prior = self.result("storage.basic")
        self.snapshot["observations"]["storage"] = observation("storage", status="unknown", reason="PermissionError")
        def forbidden(*args):
            self.fail("rule evaluated without its required input")
        rule = replace(registry()["storage.basic"], evaluate=forbidden)
        result = run_rule(rule, self.snapshot, prior)
        self.assertEqual(result["result"], "unknown")
        self.assertNotIn("error", result)

    def test_rule_failure_is_unknown_and_does_not_block_other_checks_or_leak_data(self):
        def broken(*args):
            raise RuntimeError("PRIVATE_TOKEN")
        rules = tuple(replace(r, evaluate=broken) if r.check_id == "storage.basic" else r for r in RULES)
        result = assess(self.snapshot, rules=rules)
        self.assertEqual(by_id(result, "storage.basic")["error"], {"code": "rule_error", "type": "RuntimeError"})
        self.assertEqual(by_id(result, "storage.basic")["result"], "unknown")
        self.assertEqual(by_id(result, "packages.state")["result"], "passed")
        self.assertNotIn("PRIVATE_TOKEN", json.dumps(result))

    def test_invalid_result_and_undeclared_input_remain_unknown(self):
        for evaluator in (lambda inputs, previous: Outcome("all_good", "invalid"),
                          lambda inputs, previous: Outcome("passed", "invalid code", reason_code={"bad": "object"}),
                          lambda inputs, previous: Outcome("passed", "bad context", context={"bad": object()}),
                          lambda inputs, previous: Outcome("passed", "bad context", context={"bad": float("nan")}),
                          lambda inputs, previous: inputs.value("packages.dpkg")):
            with self.subTest(evaluator=evaluator):
                result = run_rule(replace(registry()["storage.basic"], evaluate=evaluator), self.snapshot)
                self.assertEqual(result["result"], "unknown")
                self.assertEqual(result["error"]["code"], "rule_error")

    def test_rule_mutating_its_inputs_cannot_alter_snapshot_or_prior_record(self):
        prior = {"context": {"original": "value"}}
        def change(inputs, previous):
            inputs.value("storage")["available_bytes"] = 0
            previous["context"].clear()
            return Outcome("unknown", "synthetic mutation")
        run_rule(replace(registry()["storage.basic"], evaluate=change), self.snapshot, prior)
        self.assertGreater(self.snapshot["observations"]["storage"]["value"]["available_bytes"], 0)
        self.assertEqual(prior, {"context": {"original": "value"}})

    def test_interrupt_is_not_swallowed_by_rule_isolation(self):
        def interrupted(*args):
            raise KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            run_rule(replace(registry()["storage.basic"], evaluate=interrupted), self.snapshot)

    def test_only_changed_rule_invalidates_when_machine_is_unchanged(self):
        before = assess(self.snapshot)
        rules = tuple(replace(r, version="test-next") if r.check_id == "services" else r for r in RULES)
        invalid = invalidate(before, [], rules=rules)
        self.assertEqual([(c["check_id"], c["invalidated_by"]) for c in invalid], [("services", ["rule_version"])])
        after = assess(self.snapshot, before, rules=rules)
        self.assertEqual(after["rule_changes"], [{"check_id": "services", "kind": "updated", "before": "2", "after": "test-next"}])

    def test_added_and_removed_rules_are_not_machine_changes(self):
        original = tuple(r for r in RULES if r.check_id != "drivers.dkms.current")
        before = assess(self.snapshot, rules=original)
        after = assess(self.snapshot, before)
        self.assertEqual(after["rule_changes"], [{"check_id": "drivers.dkms.current", "kind": "added", "before": None, "after": "1"}])
        removed = invalidate(after, [], rules=original)
        self.assertEqual([(c["check_id"], c["invalidated_by"]) for c in removed], [("drivers.dkms.current", ["rule_removed"])])
        self.assertEqual(compare(self.snapshot, deepcopy(self.snapshot)), [])

    def test_input_contract_change_is_detected_even_if_version_was_not_bumped(self):
        before = assess(self.snapshot)
        rules = tuple(replace(r, input_scopes=("storage", "os")) if r.check_id == "storage.basic" else r for r in RULES)
        invalid = invalidate(before, [], rules=rules)
        self.assertEqual(invalid[0]["invalidated_by"], ["rule_inputs"])
        after = assess(self.snapshot, before, rules=rules)
        self.assertEqual(after["rule_changes"][0]["reason"], "rule_inputs")

    def test_rule_update_does_not_discard_reboot_wait(self):
        self.set_value("reboot", {"required_marker": True})
        before = assess(self.snapshot)
        self.set_value("reboot", {"required_marker": False})
        rules = tuple(replace(r, version="test-next") if r.check_id == "reboot" else r for r in RULES)
        self.assertEqual(by_id(assess(self.snapshot, before, rules=rules), "reboot")["result"], "pending")

    def test_previous_assessment_must_belong_to_same_machine(self):
        previous = assess(self.snapshot)
        previous["machine_id"] = "another-machine"
        with self.assertRaises(DataError):
            assess(self.snapshot, previous)

    def test_program_release_does_not_change_unchanged_collector_semantics(self):
        self.assertEqual(COLLECTOR_VERSION, "0.1.0")
        self.assertEqual(self.snapshot["observations"]["os"]["collector_version"], "0.1.0")

    def test_duplicate_rule_identifiers_are_rejected(self):
        with self.assertRaises(DataError):
            registry((RULES[0], RULES[0]))

    def test_capability_description_can_be_filtered_and_unknown_id_is_error(self):
        result = describe_rules("services")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["check_id"], "services")
        self.assertEqual(result[0]["input_scopes"], ["services"])
        self.assertEqual(result[0]["side_effects"], [])
        with self.assertRaises(DataError):
            describe_rules("unknown-rule")

    def test_failed_service_is_a_scoped_failure_and_names_are_reported(self):
        self.set_value("services", {"synthetic.service": {"load": "loaded", "active": "failed", "sub": "failed"}})
        result = self.result("services")
        self.assertEqual(result["result"], "failed")
        self.assertEqual(result["subjects"], ["synthetic.service"])
        self.assertIn("尚未确定原因", result["reason"])
        self.assertEqual(self.result("hardware.function")["result"], "unknown")

    def test_service_state_with_unknown_format_is_not_passed(self):
        self.set_value("services", {"synthetic.service": {"active": "unrecognized"}})
        self.assertEqual(self.result("services")["result"], "unknown")

    def test_vm_is_not_claimed_as_the_initial_real_machine_validation(self):
        self.set_value("environment", {"kind": "vm", "technology": "kvm"})
        self.assertEqual(self.result("platform")["result"], "unknown")

    def test_five_extended_rules_are_implemented_but_missing_evidence_stays_unknown(self):
        descriptions = {r["check_id"]: r for r in describe_rules()}
        for check_id in ("packages.dependencies", "drivers.compatibility", "hardware.function", "updates", "configs"):
            with self.subTest(check_id=check_id):
                self.assertEqual(descriptions[check_id]["implementation_status"], "implemented")
                self.assertEqual(descriptions[check_id]["rule_version"], "2")
                self.assertEqual(self.result(check_id)["result"], "unknown")

    def test_unimplemented_rule_cannot_accidentally_declare_success(self):
        rule = replace(registry()["drivers.compatibility"], implemented=False, evaluate=lambda inputs, previous: Outcome("passed", "synthetic accidental pass"))
        result = run_rule(rule, self.snapshot)
        self.assertEqual(result["result"], "unknown")
        self.assertEqual(result["error"]["code"], "rule_error")


class DkmsRuleTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", observations())

    def result(self, entries):
        self.snapshot["observations"]["drivers.dkms"] = observation("drivers.dkms", {"entries": entries})
        return by_id(assess(self.snapshot), "drivers.dkms.current")

    def test_matching_install_record_passes_only_this_narrow_check(self):
        result = self.result(["synthetic/1.0, 6.8.0-example, x86_64: installed"])
        self.assertEqual(result["result"], "passed")
        self.assertIn("未验证", result["reason"])
        self.assertEqual(by_id(assess(self.snapshot), "drivers.compatibility")["result"], "unknown")

    def test_only_built_current_module_fails_install_record_check(self):
        result = self.result(["synthetic/1.0, 6.8.0-example, x86_64: built"])
        self.assertEqual(result["result"], "failed")
        self.assertEqual(result["subjects"], ["synthetic/1.0"])
        self.assertIn("是否需要安装", result["reason"])

    def test_absent_current_kernel_or_architecture_match_is_unknown(self):
        for line in ("synthetic/1.0: added", "synthetic/1.0, 6.7.0-old, x86_64: installed",
                     "synthetic/1.0, 6.8.0-example, aarch64: installed"):
            with self.subTest(line=line):
                self.assertEqual(self.result([line])["result"], "unknown")

    def test_old_kernel_record_cannot_hide_an_unmatched_second_module(self):
        result = self.result(["synthetic/1.0, 6.8.0-example, x86_64: installed", "another/1.0, 6.7.0-old, x86_64: installed"])
        self.assertEqual(result["result"], "unknown")
        self.assertEqual(result["subjects"], ["another/1.0"])

    def test_other_kernel_for_same_module_does_not_fail_current_kernel_check(self):
        result = self.result(["synthetic/1.0, 6.8.0-example, x86_64: installed", "synthetic/1.0, 6.7.0-old, x86_64: built"])
        self.assertEqual(result["result"], "passed")

    def test_empty_list_and_missing_tool_are_different(self):
        self.assertEqual(self.result([])["result"], "not_applicable")
        self.snapshot["observations"]["drivers.dkms"] = observation("drivers.dkms", status="unknown", reason="tool missing")
        self.assertEqual(by_id(assess(self.snapshot), "drivers.dkms.current")["result"], "unknown")

    def test_warnings_partial_unknown_or_duplicate_rows_cannot_pass(self):
        installed = "synthetic/1.0, 6.8.0-example, x86_64: installed"
        for entries in ([installed + " (WARNING! Diff between built and installed module!)"],
                        [installed, "truncated"], [installed, installed], ["synthetic/1.0: broken"],
                        ["synthetic/1.0: installed"], ["synthetic/1.0, 6.8.0-example, x86_64: added"], [""]):
            with self.subTest(entries=entries):
                self.assertEqual(self.result(entries)["result"], "unknown")

    def test_container_and_wsl_records_do_not_check_host_kernel(self):
        for kind in ("container", "wsl"):
            with self.subTest(kind=kind):
                self.snapshot["observations"]["environment"] = observation("environment", {"kind": kind, "technology": "synthetic"})
                self.assertEqual(self.result(["synthetic/1.0, 6.8.0-example, x86_64: installed"])["result"], "not_applicable")

    def test_missing_kernel_or_environment_keeps_result_unknown(self):
        for scope in ("kernel", "environment", "os"):
            with self.subTest(scope=scope):
                old = self.snapshot["observations"][scope]
                self.snapshot["observations"][scope] = observation(scope, status="unknown", reason="not read")
                self.assertEqual(self.result(["synthetic/1.0, 6.8.0-example, x86_64: installed"])["result"], "unknown")
                self.snapshot["observations"][scope] = old


if __name__ == "__main__":
    unittest.main()
