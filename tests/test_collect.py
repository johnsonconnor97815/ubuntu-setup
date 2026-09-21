import json
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from ubuntu_setup.collect import COMMANDS, CommandResult, LocalProbe, ProbeError, collect, parse_dpkg, parse_flatpak, parse_os_release, parse_snap
from helpers import FakeProbe


class CollectorTests(unittest.TestCase):
    def test_all_scopes_are_read_without_mutation_tools(self):
        probe = FakeProbe()
        data = collect(probe)
        self.assertEqual(data["hardware.pci"]["status"], "observed")
        self.assertEqual(len(data["hardware.usb"]["value"]), 1)
        self.assertIn("usb:1-1:1.0", data["drivers.bindings"]["value"])
        self.assertEqual(data["kernel.next_boot"]["status"], "unknown")
        self.assertNotIn("serial", json.dumps(data))
        self.assertEqual(set(probe.calls), set(COMMANDS))

    def test_one_permission_failure_does_not_become_empty_hardware(self):
        probe = FakeProbe()
        probe.files["/sys/bus/pci/devices/0000:01:00.0/vendor"] = PermissionError("PRIVATE_CONTENT")
        data = collect(probe)
        self.assertEqual(data["hardware.pci"]["status"], "unknown")
        self.assertIsNone(data["hardware.pci"]["value"])
        self.assertEqual(data["packages.dpkg"]["status"], "observed")
        self.assertNotIn("PRIVATE_CONTENT", json.dumps(data))

    def test_device_disappearing_during_scan_makes_scope_unknown(self):
        probe = FakeProbe()
        del probe.files["/sys/bus/usb/devices/1-1/idProduct"]
        self.assertEqual(collect(probe)["hardware.usb"]["status"], "unknown")

    def test_failed_environment_probe_does_not_claim_physical_machine(self):
        probe = FakeProbe()
        probe.commands["container"] = CommandResult(1, "")
        self.assertEqual(collect(probe)["environment"]["status"], "unknown")

    def test_container_and_wsl_are_distinguished(self):
        for technology, kind in (("docker", "container"), ("wsl", "wsl")):
            with self.subTest(technology=technology):
                probe = FakeProbe()
                probe.commands["container"] = CommandResult(0, technology + "\n")
                self.assertEqual(collect(probe)["environment"]["value"]["kind"], kind)

    def test_vm_is_not_physical(self):
        probe = FakeProbe()
        probe.commands["vm"] = CommandResult(0, "kvm\n")
        self.assertEqual(collect(probe)["environment"]["value"]["kind"], "vm")

    def test_missing_command_is_unknown_not_uninstalled(self):
        probe = FakeProbe()
        probe.commands["snap"] = ProbeError("工具缺失")
        data = collect(probe)
        self.assertEqual(data["packages.snap"]["status"], "unknown")
        self.assertEqual(data["os"]["status"], "observed")

    def test_secure_boot_failure_does_not_mean_disabled(self):
        probe = FakeProbe()
        probe.commands["secure_boot"] = CommandResult(1, "")
        self.assertIsNone(collect(probe)["drivers.secure_boot"]["value"])

    def test_dpkg_retains_architecture_and_incomplete_status(self):
        entries = parse_dpkg("libexample:amd64\t2\tamd64\thalf-configured\treinstreq\n")
        self.assertEqual(entries["libexample:amd64"]["status"], "half-configured")
        self.assertEqual(entries["libexample:amd64"]["architecture"], "amd64")

    def test_partial_package_output_is_not_accepted(self):
        for text in ("", "nano\t1\tamd64\tinstalled\tok\ntruncated", "nano\t1\tamd64\tinvalid\tok\n"):
            with self.subTest(text=text), self.assertRaises(ProbeError):
                parse_dpkg(text)

    def test_unknown_snap_output_is_not_empty_success(self):
        with self.assertRaises(ProbeError):
            parse_snap("")
        with self.assertRaises(ProbeError):
            parse_snap("Unexpected localized header\n")

    def test_flatpak_keeps_commit_even_if_version_empty(self):
        result = parse_flatpak("runtime/org.example/x86_64/1\t\tcommit-a\n")
        self.assertEqual(result["runtime/org.example/x86_64/1"]["commit"], "commit-a")

    def test_os_release_is_parsed_without_evaluating_shell(self):
        result = parse_os_release('ID=ubuntu\nVERSION_ID="24.04"\nIGNORED="$(touch NEVER_RUN)"\n', "x86_64")
        self.assertEqual(result["id"], "ubuntu")
        self.assertNotIn("IGNORED", result)

    def test_config_digest_does_not_store_credentials(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "example.sources"
            path.write_text("URIs: https://username:PRIVATE_PASSWORD@example.invalid\n")
            data = LocalProbe().file_info(path)
            self.assertNotIn("PRIVATE_PASSWORD", json.dumps(data))
            self.assertEqual(len(data["sha256"]), 64)

    def test_timeout_kills_read_only_probe_and_returns_unknown(self):
        command = (sys.executable, "-c", "import time; time.sleep(10)")
        with patch.dict(COMMANDS, {"test_probe": command}), patch("ubuntu_setup.collect.shutil.which", return_value=sys.executable):
            with self.assertRaisesRegex(ProbeError, "超时"):
                LocalProbe(timeout=0.03).run("test_probe")

    def test_proc_style_file_is_read_in_small_chunks(self):
        class SmallReadsOnly(io.BytesIO):
            def read(self, size=-1):
                if size < 0 or size > 4096:
                    raise OSError(12, "Cannot allocate memory")
                return super().read(size)

        with patch.object(Path, "open", return_value=SmallReadsOnly(b"6.8.0-example\n")):
            self.assertEqual(LocalProbe().read("synthetic-proc-file"), "6.8.0-example\n")

    def test_small_reads_still_enforce_total_size_limit(self):
        with patch.object(Path, "open", return_value=io.BytesIO(b"x" * (4 * 1024 * 1024 + 1))):
            with self.assertRaisesRegex(ProbeError, "大小限制"):
                LocalProbe().read("synthetic-oversized-file")

    def test_loaded_module_version_is_recorded(self):
        result = collect(FakeProbe())["drivers.modules"]["value"]["example"]
        self.assertEqual(result["version"], "1.0-example")
        self.assertEqual(result["srcversion"], "synthetic-source-a")

    def test_module_without_version_metadata_is_not_reported_absent(self):
        probe = FakeProbe()
        del probe.files["/sys/module/example/version"]
        result = collect(probe)["drivers.modules"]
        self.assertEqual(result["status"], "observed")
        self.assertIsNone(result["value"]["example"]["version"])


if __name__ == "__main__":
    unittest.main()
