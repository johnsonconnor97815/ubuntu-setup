from copy import deepcopy
from contextlib import redirect_stderr, redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from helpers import FakeProbe
from ubuntu_setup.analysis import assess, compare, invalidate, make_snapshot
from ubuntu_setup.apt_probe import isolated_config, refresh_failure, source_overrides
from ubuntu_setup.check_collect import (collect_configs, collect_hardware, confirmation_fingerprint,
                                       normalize_sysctl, parse_modinfo, parse_sysctl, parse_units, resolve_sysctl)
from ubuntu_setup.collect import CommandResult, LocalProbe, ProbeError, collect
from ubuntu_setup.cli import main
from ubuntu_setup.model import BASE_SCOPES, CHECK_SCOPES, DataError, observation, validate_observations, validate_snapshot
from ubuntu_setup.report_text import MESSAGES, explain
from ubuntu_setup.report import build_result, render


def healthy_probe():
    probe = FakeProbe()
    for address, alias in (("pci/devices/0000:01:00.0", "pci:v0000FFFFd00000001"),
                           ("usb/devices/1-1", "usb:vFFFFp0002"), ("usb/devices/1-1:1.0", "usb:vFFFFp0002ic03")):
        probe.files["/sys/bus/" + address + "/modalias"] = alias
    probe.commands["graphics"] = CommandResult(0, json.dumps({"status": "passed", "renderer": "Synthetic GPU",
                                                            "software": False, "pixel": [255, 0, 0, 255], "gl_error": 0}))
    return probe


def confirmed_collection(probe, **kwargs):
    target_id = kwargs.get("target_id", "")
    before = collect(probe, target_id=target_id)
    basis = before["checks.hardware"]["value"]["confirmation_fingerprint"]
    return collect(probe, confirmation_basis=basis, **kwargs)


class ExtendedRuleTests(unittest.TestCase):
    def setUp(self):
        self.probe = healthy_probe()
        self.obs = collect(self.probe, online=True)

    def result(self, check_id):
        snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", self.obs)
        result = next(c for c in assess(snapshot)["checks"] if c["check_id"] == check_id)
        self.assertNotIn("error", result)
        self.assertEqual(result["implementation_status"], "implemented")
        self.assertTrue((check_id, result["reason_code"], result["result"]) in MESSAGES or result["reason_code"] == "missing_inputs")
        self.assertNotIn("具体范围请查看技术详情", explain(result).summary)
        return result

    def test_dependencies_resolved_without_claiming_application_function(self):
        self.assertEqual(self.result("packages.dependencies")["result"], "passed")

    def test_current_dependency_conflict_fails_with_package_names(self):
        self.obs["checks.packages"]["value"]["broken"] = ["editor:amd64"]
        result = self.result("packages.dependencies")
        self.assertEqual(result["result"], "failed")
        self.assertEqual(result["subjects"], ["editor:amd64"])

    def test_candidate_conflict_is_separate_from_current_package_state(self):
        self.obs["checks.packages"]["value"]["simulation_resolved"] = False
        self.assertEqual(self.result("packages.dependencies")["reason_code"], "dependencies_conflict")
        self.assertEqual(self.result("packages.state")["result"], "passed")

    def test_solver_removal_or_downgrade_requires_plan_review(self):
        for action in ("remove", "downgrade"):
            self.obs["checks.packages"]["value"]["actions"] = [{"package": "editor", "action": action, "from": "2", "to": None if action == "remove" else "1"}]
            result = self.result("packages.dependencies")
            self.assertEqual(result["result"], "pending")
            self.assertEqual(result["context"]["actions"][0]["action"], action)

    def test_locked_package_change_is_not_silently_accepted(self):
        self.obs["checks.packages"]["value"]["held_changed"] = ["editor"]
        self.assertEqual(self.result("packages.dependencies")["reason_code"], "dependencies_held")

    def test_incomplete_cache_cannot_be_a_complete_update_plan(self):
        self.obs["checks.packages"]["value"]["metadata_complete"] = False
        self.assertEqual(self.result("packages.dependencies")["result"], "unknown")

    def test_empty_database_does_not_pass_dependencies(self):
        self.obs["checks.packages"]["value"]["installed_count"] = 0
        self.assertEqual(self.result("packages.dependencies")["result"], "unknown")

    def test_online_source_checks_distinguish_updates_and_no_candidates(self):
        self.assertEqual(self.result("updates")["result"], "passed")
        self.obs["checks.updates"]["value"]["candidates"] = [{"package": "editor", "installed": "1", "candidate": "2",
                                                           "origins": ["noble-security"], "apt_trusted": True, "held": False}]
        result = self.result("updates")
        self.assertEqual(result["result"], "pending")
        self.assertEqual(result["context"]["security_candidate_count"], 1)

    def test_cache_no_candidates_does_not_mean_up_to_date(self):
        self.obs["checks.updates"]["value"].update(mode="cache", refresh_status="not_requested")
        self.assertEqual(self.result("updates")["result"], "unknown")

    def test_source_signature_failure_and_network_failure_are_different(self):
        for error, expected in (("signature", "failed"), ("date", "failed"), ("source_unavailable", "failed"),
                                ("network", "unknown"), ("process_incomplete", "unknown")):
            self.obs["checks.updates"]["value"].update(refresh_status="failed", refresh_error=error)
            self.assertEqual(self.result("updates")["result"], expected)

    def test_unsafe_trust_configuration_fails_even_without_network(self):
        self.obs["checks.updates"]["value"].update(mode="cache", refresh_status="not_requested",
                                                  unsafe_options=[{"file": "/etc/apt/sources.list", "option": "trusted"}])
        self.assertEqual(self.result("updates")["reason_code"], "updates_unsafe")

    def test_incomplete_verified_refresh_is_not_passed(self):
        self.obs["checks.updates"]["value"]["metadata_complete"] = False
        self.assertEqual(self.result("updates")["reason_code"], "updates_incomplete")

    def test_untrusted_candidate_is_not_accepted_by_source_level_success(self):
        self.obs["checks.updates"]["value"]["candidates"] = [{"package": "editor", "installed": "1", "candidate": "2",
                                                           "origins": ["synthetic"], "apt_trusted": False, "held": False}]
        self.assertEqual(self.result("updates")["reason_code"], "updates_incomplete")

    def test_driver_device_and_running_kernel_match_is_narrow_pass(self):
        result = self.result("drivers.compatibility")
        self.assertEqual(result["result"], "passed")
        self.assertFalse(result["context"]["next_boot_verified"])
        self.assertFalse(result["context"]["module_details"][0]["signature_trust_verified"])

    def test_driver_file_for_different_kernel_fails(self):
        self.obs["checks.drivers"]["value"]["modules"]["example"]["vermagic"] = "other-kernel SMP"
        self.assertEqual(self.result("drivers.compatibility")["result"], "failed")

    def test_changed_driver_file_is_activation_wait(self):
        self.obs["checks.drivers"]["value"]["modules"]["example"]["version"] = "2.0"
        self.assertEqual(self.result("drivers.compatibility")["reason_code"], "compatibility_pending")

    def test_optional_firmware_absence_is_unconfirmed_not_fault(self):
        self.obs["checks.drivers"]["value"]["modules"]["example"]["firmware_files"] = [{"name": "optional-revision.bin", "present": False}]
        self.assertEqual(self.result("drivers.compatibility")["result"], "unknown")

    def test_unmatched_device_alias_requires_evidence_not_forced_driver(self):
        self.obs["checks.drivers"]["value"]["modules"]["example"]["alias"] = ["other:*"]
        self.assertEqual(self.result("drivers.compatibility")["result"], "unknown")

    def test_nvidia_driver_library_mismatch_is_recorded_as_specific_failure(self):
        self.obs["checks.drivers"]["value"]["nvidia_api"] = {"status": "failed", "return_code": 18, "error": "driver_library_mismatch"}
        result = self.result("drivers.compatibility")
        self.assertEqual(result["reason_code"], "compatibility_library_mismatch")
        self.assertIn("版本不一致", explain(result).summary)

    def test_guest_cannot_claim_host_hardware_or_driver_compatibility(self):
        self.obs["environment"]["value"] = {"kind": "container", "technology": "docker"}
        for check in ("drivers.compatibility", "hardware.function"):
            self.assertEqual(self.result(check)["result"], "not_applicable")

    def test_actual_render_does_not_silently_confirm_screen_audio_and_input(self):
        result = self.result("hardware.function")
        self.assertEqual(result["result"], "pending")
        self.assertEqual(set(result["subjects"]), {"display", "audio", "input"})
        self.assertIn("自动测试已生成并读取测试画面", explain(result).summary)
        self.assertIn("等待你确认", explain(result).summary)

    def test_actual_render_failure_is_not_masked_by_user_passes(self):
        self.obs["checks.hardware"]["value"]["graphics"]["status"] = "failed"
        self.assertEqual(self.result("hardware.function")["result"], "failed")

    def test_user_confirmation_can_complete_the_declared_device_scope(self):
        self.obs = confirmed_collection(self.probe, confirmations={k: "passed" for k in ("display", "audio", "input")})
        self.assertEqual(self.result("hardware.function")["result"], "passed")

    def test_software_rendering_cannot_pass_hardware_acceleration(self):
        self.obs = confirmed_collection(self.probe, confirmations={k: "passed" for k in ("display", "audio", "input")})
        self.obs["checks.hardware"]["value"]["graphics"]["software"] = True
        self.assertEqual(self.result("hardware.function")["reason_code"], "hardware_partial")

    def test_user_reported_device_failure_is_preserved(self):
        self.obs = confirmed_collection(self.probe, confirmations={"audio": "failed"})
        self.assertEqual(self.result("hardware.function")["subjects"], ["audio"])

    def test_sysctl_and_loaded_unit_configuration_can_pass(self):
        self.assertEqual(self.result("configs")["result"], "passed")

    def test_changed_effective_setting_is_pending_not_automatic_repair(self):
        self.obs["checks.configs"]["value"]["sysctl"][0]["effective"] = "10"
        self.assertEqual(self.result("configs")["reason_code"], "configs_pending")

    def test_systemd_reload_is_one_requirement_not_hundreds_of_faults(self):
        self.obs["checks.configs"]["value"]["units"] = [{"unit": f"test-{i}.service", "load_state": "loaded", "needs_reload": True} for i in range(200)]
        result = self.result("configs")
        self.assertEqual(result["subjects"], ["systemd:daemon_reload"])
        self.assertEqual(result["reason_code"], "configs_reload")
        self.assertEqual(len(result["context"]["reload_units"]), 200)

    def test_syntax_errors_and_bad_settings_fail(self):
        self.obs["checks.configs"]["value"]["units"][0]["load_state"] = "bad-setting"
        self.assertEqual(self.result("configs")["reason_code"], "configs_invalid")

    def test_unknown_configuration_format_is_not_a_pass(self):
        self.obs["checks.configs"]["value"]["unverified_files"] = ["/etc/application.conf"]
        self.assertEqual(self.result("configs")["result"], "unknown")


class EvidenceCollectionTests(unittest.TestCase):
    def test_unit_paths_keep_literal_systemd_escapes(self):
        text = ('Id=snap-foo\\x2dbar.mount\nLoadState=loaded\nNeedDaemonReload=no\n'
                'FragmentPath=/etc/systemd/system/snap-foo\\x2dbar.mount\n'
                'DropInPaths=/etc/systemd/system/snap-foo\\x2dbar.mount.d/custom.conf\n')
        unit = parse_units(text)[0]
        self.assertEqual(unit["files"], ['/etc/systemd/system/snap-foo\\x2dbar.mount',
                                         '/etc/systemd/system/snap-foo\\x2dbar.mount.d/custom.conf'])

    def test_malformed_probe_payload_does_not_abort_independent_checks(self):
        probe = healthy_probe()
        probe.commands["graphics"] = CommandResult(0, '{"status":"passed"}')
        data = collect(probe)
        self.assertEqual(data["checks.hardware"]["status"], "unknown")
        self.assertEqual(data["checks.packages"]["status"], "observed")

    def test_feedback_for_previous_report_is_not_bound_to_changed_environment(self):
        probe = healthy_probe()
        old = collect(probe)
        basis = old["checks.hardware"]["value"]["confirmation_fingerprint"]
        probe.files["/proc/sys/kernel/random/boot_id"] = "new-boot"
        current = collect(probe, confirmation_basis=basis, confirmations={"audio": "passed"})
        record = current["checks.hardware"]["value"]
        self.assertEqual(record["confirmations"], {})
        self.assertEqual(record["unbound_confirmations"], ["audio"])

    def test_sysctl_precedence_globs_exclusions_and_effective_arrays(self):
        probe = FakeProbe()
        probe.files.update({"/proc/sys/net/ipv4/conf/eth0/rp_filter": "1", "/proc/sys/net/ipv4/conf/eth1/rp_filter": "0",
                            "/proc/sys/net/ipv4/conf/lo/rp_filter": "0", "/proc/sys/kernel/printk": "4\t4\t1\t7"})
        text = ("# /usr/lib/sysctl.d/10-default.conf\nnet.ipv4.conf.*.rp_filter=2\n"
                "# /etc/sysctl.d/99-custom.conf\nnet.ipv4.conf.*.rp_filter=1\n"
                "net.ipv4.conf.eth1.rp_filter=0\n-net.ipv4.conf.lo.rp_filter\nkernel.printk=4 4 1 7\n")
        entries, errors, sources = parse_sysctl(text)
        result = {e["key"]: e for e in resolve_sysctl(probe, entries)}
        self.assertEqual(errors, [])
        self.assertEqual(result["net/ipv4/conf/eth0/rp_filter"]["configured"], "1")
        self.assertEqual(result["net/ipv4/conf/eth1/rp_filter"]["configured"], "0")
        self.assertNotIn("net/ipv4/conf/lo/rp_filter", result)
        self.assertEqual(result["kernel/printk"]["effective"], "4 4 1 7")

    def test_sysctl_normalization_handles_interface_dots(self):
        self.assertEqual(normalize_sysctl("net.ipv4.conf.enp3s0/200.forwarding"), "net/ipv4/conf/enp3s0.200/forwarding")
        self.assertEqual(normalize_sysctl("net/ipv4/conf/enp3s0.200/forwarding"), "net/ipv4/conf/enp3s0.200/forwarding")
        for bad in ("/etc/passwd", "../../secret", "net//x"):
            with self.assertRaises(ValueError):
                normalize_sysctl(bad)

    def test_non_numeric_values_are_not_leaked_and_are_unverified(self):
        entries, _, _ = parse_sysctl("kernel.core_pattern=PRIVATE_VALUE\n")
        result = resolve_sysctl(FakeProbe(), entries)
        self.assertEqual(result[0]["read_status"], "unsupported")
        self.assertNotIn("PRIVATE_VALUE", json.dumps(result))

    def test_partial_config_read_preserves_other_evidence(self):
        probe = FakeProbe()
        probe.commands["sysctl_config"] = ProbeError("PRIVATE_CONTENT")
        result = collect_configs(probe, ())
        self.assertEqual(result["read_errors"], ["sysctl"])
        self.assertTrue(result["units"])
        self.assertNotIn("PRIVATE_CONTENT", json.dumps(result))

    def test_modinfo_missing_or_conflicting_metadata_does_not_pass(self):
        for text in ("version: 1", "filename: a\nvermagic: a\nvermagic: b"):
            with self.assertRaises(ProbeError):
                parse_modinfo(text)

    def test_confirmation_reused_only_for_same_environment(self):
        probe = healthy_probe()
        data = confirmed_collection(probe, confirmations={"display": "passed", "audio": "passed", "input": "passed"}, target_id="A")
        previous = make_snapshot("b" * 32, "a" * 32, "fixture", data)
        new = collect(probe, previous=previous, target_id="A")
        self.assertEqual(new["checks.hardware"]["value"]["confirmations"], data["checks.hardware"]["value"]["confirmations"])
        for scope, change in (("boot", {"id": "another-boot"}), ("kernel", {"release": "next-kernel"}),
                              ("hardware.usb", {}), ("configs", {"/etc/example": {"exists": True, "sha256": "other"}})):
            altered = deepcopy(new)
            altered[scope]["value"] = change
            result = collect_hardware(probe, altered, {}, previous, "A")
            self.assertEqual(result["confirmations"], {})
            self.assertEqual(set(result["expired_confirmations"]), {"display", "audio", "input"})
        self.assertNotEqual(confirmation_fingerprint(new, "A"), confirmation_fingerprint(new, "B"))

    def test_configuration_file_or_software_version_change_invalidates_confirmation(self):
        probe = healthy_probe()
        data = confirmed_collection(probe, confirmations={"audio": "passed"})
        previous = make_snapshot("b" * 32, "a" * 32, "fixture", data)
        for scope, key in (("packages.dpkg", "nano"), ("drivers.modules", "example")):
            changed = deepcopy(data)
            changed[scope]["value"][key]["version"] = "changed"
            self.assertFalse(collect_hardware(probe, changed, {}, previous, "")["confirmations"])
        changed = deepcopy(data)
        changed["checks.configs"]["value"]["sysctl_digest"] = "different"
        self.assertFalse(collect_hardware(probe, changed, {}, previous, "")["confirmations"])

    def test_missing_fingerprint_evidence_never_accepts_a_confirmation(self):
        data = collect(healthy_probe())
        data["drivers.modules"] = observation("drivers.modules", status="unknown", reason="unreadable")
        result = collect_hardware(healthy_probe(), data, {"audio": "passed"}, None, "")
        self.assertEqual(result["confirmations"], {})
        self.assertEqual(result["unbound_confirmations"], ["audio"])

    def test_legacy_snapshot_scopes_are_accepted_without_fabricated_ids(self):
        data = collect(healthy_probe())
        previous = make_snapshot("b" * 32, "a" * 32, "fixture", {k: data[k] for k in BASE_SCOPES})
        original = deepcopy(previous)
        validate_snapshot(previous)
        current = make_snapshot("b" * 32, "c" * 32, "fixture", data, previous)
        changes = compare(previous, current)
        self.assertEqual({c["scope"] for c in changes}, set(CHECK_SCOPES))
        self.assertTrue(all(c["kind"] == "coverage_changed" for c in changes))
        self.assertEqual(previous, original)

    def test_partial_new_scope_set_is_rejected(self):
        data = collect(healthy_probe())
        del data["checks.hardware"]
        with self.assertRaises(DataError):
            validate_snapshot(make_snapshot("b" * 32, "a" * 32, "fixture", data))

    def test_malformed_extended_evidence_is_rejected(self):
        data = collect(healthy_probe())
        data["checks.packages"]["value"]["simulation_resolved"] = "yes"
        with self.assertRaises(DataError):
            validate_observations(data)


class AptIsolationTests(unittest.TestCase):
    def test_active_source_trust_bypasses_detected_without_credentials_in_output(self):
        with tempfile.TemporaryDirectory() as temp:
            one, deb822 = Path(temp) / "test.list", Path(temp) / "test.sources"
            one.write_text("# deb [trusted=yes] http://unused invalid main\n"
                           "deb [arch=amd64 trusted=true] https://PRIVATE_USER:PRIVATE_PASSWORD@example.invalid noble main\n")
            deb822.write_text("Types: deb\nURIs: https://example.invalid\nCheck-Valid-Until: no\n\n"
                              "Enabled: no\nTrusted: yes\nURIs: https://disabled.invalid\n")
            issues = source_overrides([one, deb822])
            self.assertEqual({e["option"] for e in issues}, {"trusted", "check-valid-until"})
            self.assertEqual(len(issues), 2)
            self.assertNotIn("PRIVATE", json.dumps(issues))

    def test_network_config_allowlist_excludes_hooks_and_keeps_source_pins(self):
        class Config:
            def find_file(self, key):
                return "/synthetic/" + key.split("::")[-1]
            def find(self, key):
                return {"APT::Architecture": "amd64", "APT::Default-Release": "noble",
                        "Acquire::http::Proxy": "http://proxy.invalid", "APT::Update::Post-Invoke": "touch /PRIVATE_HOOK"}.get(key, "")
            def keys(self):
                return ["APT::Update::Post-Invoke", "Acquire::http::Proxy", "Acquire::http::Proxy-Auto-Detect"]
            def value_list(self, key):
                return ["amd64", "i386"]
        text = isolated_config(Config(), Path("/tmp/isolated-example"))
        self.assertNotIn("PRIVATE_HOOK", text)
        self.assertNotIn("Post-Invoke", text)
        self.assertNotIn("Proxy-Auto-Detect", text)
        self.assertIn('Dir::Etc::parts "-"', text)
        self.assertIn('Dir::Etc::preferences "/synthetic/preferences"', text)
        self.assertIn('APT::Architectures { "amd64"; "i386";', text)
        self.assertIn('Acquire::AllowInsecureRepositories "false"', text)
        self.assertIn('Dir::State::lists "/tmp/isolated-example/lists"', text)

    def test_source_error_classification_never_copies_stderr_or_credentials(self):
        for stderr, expected in (("NO_PUBKEY secret", "signature"), ("Release expired secret", "date"),
                                 ("Could not connect to PRIVATE_URL", "network"), ("404 secret", "source_unavailable")):
            self.assertEqual(refresh_failure(stderr), expected)

    def test_network_timeout_preserves_current_dependency_result_and_cleans_temp(self):
        probe = LocalProbe()
        roots = []
        def command(args):
            if len(args) == 3:
                roots.append(Path(args[-1]))
                (roots[-1] / "secret").write_text("PRIVATE")
                raise ProbeError("timeout")
            return CommandResult(0, json.dumps(FakeProbe().apt_checks()))
        with patch.object(probe, "_command", side_effect=command):
            result = probe.apt_checks(online=True)
        self.assertEqual(result["packages"]["broken"], [])
        self.assertEqual(result["updates"]["refresh_status"], "failed")
        self.assertTrue(roots)
        self.assertTrue(all(not p.exists() for p in roots))


class ConfirmationWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "state"
        self.probe = healthy_probe()

    def run_cli(self, *options):
        out, err = io.StringIO(), io.StringIO()
        with patch("ubuntu_setup.cli.LocalProbe", return_value=self.probe), \
                patch("ubuntu_setup.cli.live_identity", return_value="synthetic-machine"), \
                redirect_stdout(out), redirect_stderr(err):
            code = main(["inspect", "--state-dir", str(self.root), "--no-open", "--format", "json", *options])
        return code, json.loads(out.getvalue()) if out.getvalue() else None, err.getvalue()

    def test_cli_records_only_feedback_for_the_current_report(self):
        code, before, _ = self.run_cli()
        self.assertEqual(code, 0)
        code, after, err = self.run_cli("--confirm-from", before["run_id"], "--confirm-device", "display=passed",
                                        "--confirm-device", "audio=passed", "--confirm-device", "input=passed")
        self.assertEqual(code, 0, err)
        check = next(c for c in after["checks"] if c["check_id"] == "hardware.function")
        self.assertEqual(check["result"], "passed")
        self.assertTrue(all(c["source"] == "user" for c in check["context"]["confirmations"].values()))
        code, _, err = self.run_cli("--confirm-from", before["run_id"], "--confirm-device", "audio=passed")
        self.assertEqual(code, 2)
        self.assertIn("不是当前最新报告", err)

    def test_cli_recollects_and_rejects_feedback_after_a_hardware_change(self):
        _, before, _ = self.run_cli()
        self.probe.files["/sys/bus/usb/devices/1-1/idProduct"] = "0042"
        code, after, err = self.run_cli("--confirm-from", before["run_id"], "--confirm-device", "audio=passed")
        self.assertEqual(code, 0, err)
        check = next(c for c in after["checks"] if c["check_id"] == "hardware.function")
        self.assertEqual(check["result"], "pending")
        self.assertEqual(check["context"]["confirmations"], {})
        self.assertEqual(check["context"]["unbound_confirmations"], ["audio"])

    def test_cli_requires_a_report_reference_for_confirmation(self):
        code, _, err = self.run_cli("--confirm-device", "audio=passed")
        self.assertEqual(code, 2)
        self.assertIn("--confirm-from", err)

    def test_new_report_evidence_escapes_untrusted_renderer_text(self):
        data = collect(self.probe)
        data["checks.hardware"]["value"]["graphics"]["renderer"] = '<script>alert("unsafe")</script>'
        snapshot = make_snapshot("b" * 32, "a" * 32, "fixture", data)
        assessment = assess(snapshot)
        result = build_result(snapshot, assessment, [], [], [], self.root / "runs" / ("a" * 32) / "report.html")
        document = render(snapshot, result)
        self.assertNotIn('<script>alert("unsafe")</script>', document)
        self.assertIn('&lt;script&gt;', document)
        self.assertIn("屏幕显示", document)
        self.assertIn("等待实际使用确认", document)


if __name__ == "__main__":
    unittest.main()
