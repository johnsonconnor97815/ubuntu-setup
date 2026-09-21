from copy import deepcopy
import unittest

from ubuntu_setup.analysis import assess, compare, invalidate, make_snapshot
from ubuntu_setup.model import observation
from helpers import observations


def snapshot(data, run="a" * 32, previous=None):
    return make_snapshot("b" * 32, run, "fixture", data, previous)


def check(assessment, check_id):
    return next(c for c in assessment["checks"] if c["check_id"] == check_id)


class AnalysisTests(unittest.TestCase):
    def setUp(self):
        self.before = snapshot(observations())
        self.after = deepcopy(self.before)
        self.previous_assessment = assess(self.before)

    def test_first_run_and_unchanged_run_have_no_invented_changes(self):
        self.assertEqual(compare(None, self.before), [])
        self.assertEqual(compare(self.before, snapshot(observations(), "c" * 32)), [])

    def test_normal_software_upgrade_rechecks_software_not_all_drivers(self):
        self.after["observations"]["packages.dpkg"]["value"]["nano"]["version"] = "2.0-example"
        changes = compare(self.before, self.after)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0]["before"]["version"], "1.0-example")
        invalid = {c["check_id"] for c in invalidate(self.previous_assessment, changes)}
        self.assertIn("packages.dependencies", invalid)
        self.assertNotIn("drivers.compatibility", invalid)

    def test_driver_package_upgrade_rechecks_drivers(self):
        self.after["observations"]["packages.dpkg"]["value"]["linux-image-example"]["version"] = "new-example"
        invalid = {c["check_id"] for c in invalidate(self.previous_assessment, compare(self.before, self.after))}
        self.assertIn("drivers.compatibility", invalid)

    def test_software_removal_is_limited_to_the_enumerated_source(self):
        del self.after["observations"]["packages.dpkg"]["value"]["nano"]
        self.assertEqual(compare(self.before, self.after)[0]["kind"], "removed_from_inventory")

    def test_device_disappearance_is_not_asserted_as_removal(self):
        self.after["observations"]["hardware.usb"]["value"] = {}
        self.assertEqual(compare(self.before, self.after)[0]["kind"], "not_observed")

    def test_device_replacement_at_same_address_is_detected(self):
        self.after["observations"]["hardware.pci"]["value"]["0000:01:00.0"]["device"] = "0x0003"
        changes = compare(self.before, self.after)
        self.assertEqual(changes[0]["kind"], "changed")
        self.assertIn("hardware.function", {c["check_id"] for c in invalidate(self.previous_assessment, changes)})

    def test_unknown_is_never_filled_with_old_value_or_reported_removed(self):
        data = observations()
        data["hardware.pci"] = observation("hardware.pci", status="unknown", reason="PermissionError")
        current = snapshot(data, "c" * 32, self.before)
        self.assertIsNone(current["observations"]["hardware.pci"]["value"])
        self.assertIn("last_known_ref", current["observations"]["hardware.pci"])
        self.assertEqual(compare(self.before, current)[0]["kind"], "observation_unavailable")

    def test_restored_collection_can_compare_to_dated_last_known_value(self):
        unknown = deepcopy(self.before)
        unknown["observations"]["packages.dpkg"] = observation("packages.dpkg", status="unknown", reason="timeout")
        self.after["observations"]["packages.dpkg"]["value"]["nano"]["version"] = "2.0-example"
        changes = compare(unknown, self.after, {"packages.dpkg": self.before["observations"]["packages.dpkg"]})
        self.assertEqual([c["kind"] for c in changes], ["observation_restored", "changed"])
        self.assertEqual(changes[1]["comparison_basis"], "last_known_observation")

    def test_config_changes_invalidate_but_do_not_restore_content(self):
        self.after["observations"]["configs"]["value"]["/etc/example.conf"]["sha256"] = "user-edited"
        changes = compare(self.before, self.after)
        self.assertEqual(changes[0]["after"]["sha256"], "user-edited")
        self.assertIn("configs", {c["check_id"] for c in invalidate(self.previous_assessment, changes)})

    def test_stopping_config_monitoring_is_not_file_deletion(self):
        self.after["observations"]["configs"]["value"] = {}
        self.after["observations"]["configs"]["coverage"] = ["未监测配置"]
        self.assertEqual([c["kind"] for c in compare(self.before, self.after)], ["coverage_changed"])

    def test_kernel_change_invalidates_device_results(self):
        self.after["observations"]["kernel"]["value"]["release"] = "6.9.0-example"
        invalid = {c["check_id"] for c in invalidate(self.previous_assessment, compare(self.before, self.after))}
        self.assertIn("drivers.compatibility", invalid)
        self.assertIn("hardware.function", invalid)

    def test_loaded_modules_do_not_pass_function_or_compatibility_checks(self):
        self.assertEqual(check(self.previous_assessment, "drivers.modules")["result"], "passed")
        self.assertEqual(check(self.previous_assessment, "drivers.compatibility")["result"], "unknown")
        self.assertEqual(check(self.previous_assessment, "hardware.function")["result"], "unknown")

    def test_unfinished_package_registration_is_reported(self):
        self.after["observations"]["packages.dpkg"]["value"]["nano"]["status"] = "half-configured"
        self.assertEqual(check(assess(self.after), "packages.state")["result"], "failed")

    def test_residual_package_config_is_not_an_incomplete_install(self):
        self.after["observations"]["packages.dpkg"]["value"]["nano"]["status"] = "config-files"
        self.assertEqual(check(assess(self.after), "packages.state")["result"], "passed")

    def test_reboot_wait_survives_disappearing_marker_until_boot_changes(self):
        self.before["observations"]["reboot"]["value"]["required_marker"] = True
        pending = assess(self.before)
        still_pending = assess(self.after, pending)
        self.assertEqual(check(still_pending, "reboot")["result"], "pending")
        self.assertEqual(check(assess(self.after, still_pending), "reboot")["result"], "pending")
        self.after["observations"]["boot"]["value"]["id"] = "synthetic-boot-b"
        after_boot = assess(self.after, still_pending)
        self.assertEqual(check(after_boot, "reboot")["result"], "passed")
        self.assertEqual(check(after_boot, "hardware.function")["result"], "unknown")

    def test_space_fluctuations_do_not_create_changes_but_exhaustion_does(self):
        self.after["observations"]["storage"]["value"]["available_bytes"] -= 4096
        self.assertEqual(compare(self.before, self.after), [])
        self.after["observations"]["storage"]["value"]["available_bytes"] = 0
        self.assertEqual(check(assess(self.after), "storage.basic")["result"], "failed")
        self.assertEqual(compare(self.before, self.after)[0]["scope"], "storage")

    def test_reboot_wait_survives_a_failed_probe_between_runs(self):
        self.before["observations"]["reboot"]["value"]["required_marker"] = True
        pending = assess(self.before)
        failed_probe = deepcopy(self.after)
        failed_probe["observations"]["reboot"] = observation("reboot", status="unknown", reason="PermissionError")
        unknown = assess(failed_probe, pending)
        self.assertEqual(check(unknown, "reboot")["result"], "unknown")
        self.assertEqual(check(assess(self.after, unknown), "reboot")["result"], "pending")

    def test_rule_change_invalidates_unchanged_observations(self):
        self.previous_assessment["checks"][0]["rule_version"] = "old-rule"
        invalid = invalidate(self.previous_assessment, [])
        self.assertEqual(invalid[0]["invalidated_by"], ["rule_version"])

    def test_module_version_change_is_not_hidden_by_unchanged_name(self):
        self.after["observations"]["drivers.modules"]["value"]["example"]["version"] = "2.0-example"
        changes = compare(self.before, self.after)
        self.assertEqual(changes[0]["kind"], "changed")
        self.assertIn("drivers.compatibility", {c["check_id"] for c in invalidate(self.previous_assessment, changes)})

    def test_collector_change_does_not_invent_device_removal(self):
        self.after["observations"]["hardware.pci"]["value"] = {}
        self.after["observations"]["hardware.pci"]["collector_version"] = "next-collector"
        self.assertEqual(compare(self.before, self.after)[0]["kind"], "coverage_changed")

    def test_outside_validation_scope_does_not_claim_support(self):
        for field, value in (("id", "fedora"), ("version_id", "22.04"), ("architecture", "aarch64")):
            with self.subTest(field=field):
                data = deepcopy(self.before)
                data["observations"]["os"]["value"][field] = value
                self.assertEqual(check(assess(data), "platform")["result"], "unknown")

    def test_container_results_are_not_host_hardware_verification(self):
        self.after["observations"]["environment"]["value"] = {"kind": "container", "technology": "docker"}
        result = check(assess(self.after), "hardware.function")
        self.assertEqual(result["result"], "not_applicable")
        self.assertIn("宿主机", result["reason"])


if __name__ == "__main__":
    unittest.main()
