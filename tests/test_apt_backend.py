"""Exercise the real APT resolver against a disposable, local file repository.

No network or installed-package changes. Every APT path and hook is isolated.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HAS_APT = bool(importlib.util.find_spec("apt_pkg") and shutil.which("apt-get"))
HELPER = Path(__file__).resolve().parents[1] / "ubuntu_setup/apt_probe.py"


@unittest.skipUnless(HAS_APT, "requires the optional system python3-apt backend")
class AptBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ubuntu-setup-test-apt-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ("repo/dists/synthetic/main/binary-amd64", "lists/partial", "cache/archives/partial", "empty", "log"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        packages = ("Package: libdemo\nVersion: 2.0\nArchitecture: amd64\nFilename: pool/libdemo.deb\nSize: 1\nDescription: fixture\n\n"
                    "Package: demo\nVersion: 2.0\nArchitecture: amd64\nDepends: libdemo (>= 2.0)\nConflicts: oldhelper\n"
                    "Filename: pool/demo.deb\nSize: 1\nDescription: fixture\n\n")
        relative = "main/binary-amd64/Packages"
        (self.root / "repo/dists/synthetic" / relative).write_text(packages)
        digest = hashlib.sha256(packages.encode()).hexdigest()
        (self.root / "repo/dists/synthetic/Release").write_text(
            "Origin: Synthetic\nLabel: Synthetic\nSuite: synthetic\nCodename: synthetic\nArchitectures: amd64\nComponents: main\n"
            f"SHA256:\n {digest} {len(packages)} {relative}\n")
        self.status = self.root / "status"
        self.set_installed()
        (self.root / "sources.list").write_text(f"deb [trusted=yes] file:{self.root}/repo synthetic main\n")
        (self.root / "preferences").write_text("")
        self.config = self.root / "apt.conf"
        values = {"Dir::Etc::parts": "-", "Dir::Etc::main": "-", "Dir::Etc::sourcelist": str(self.root / "sources.list"),
                  "Dir::Etc::sourceparts": str(self.root / "empty"), "Dir::Etc::preferences": str(self.root / "preferences"),
                  "Dir::Etc::preferencesparts": str(self.root / "empty"), "Dir::State": str(self.root),
                  "Dir::State::status": str(self.status), "Dir::State::lists": str(self.root / "lists"),
                  "Dir::Cache": str(self.root / "cache"), "Dir::Cache::pkgcache": "", "Dir::Cache::srcpkgcache": "",
                  "Dir::Log": str(self.root / "log"), "APT::Architecture": "amd64", "APT::Sandbox::User": "",
                  "Acquire::Languages": "none"}
        self.config.write_text("\n".join(f'{key} "{value}";' for key, value in values.items()) + '\nAPT::Architectures { "amd64"; };\n')
        self.env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "APT_CONFIG": str(self.config)}
        result = subprocess.run(("/usr/bin/apt-get", "update", "--error-on=any"), env=self.env,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def set_installed(self, *, dependency="1.0", hold=False):
        self.status.write_text(
            "Package: libdemo\nStatus: install ok installed\nVersion: 1.0\nArchitecture: amd64\nDescription: fixture\n\n"
            f"Package: demo\nStatus: {'hold' if hold else 'install'} ok installed\nVersion: 1.0\nArchitecture: amd64\nDepends: libdemo (>= {dependency})\nDescription: fixture\n\n"
            "Package: oldhelper\nStatus: install ok installed\nVersion: 1.0\nArchitecture: amd64\nDescription: fixture\n\n")

    def analyze(self, online=False):
        before = self.status.read_bytes()
        args = ["/usr/bin/python3", str(HELPER)]
        if online:
            root = self.root / "online"
            root.mkdir(mode=0o700)
            args.append(str(root))
        result = subprocess.run(args, env=self.env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0)
        value = json.loads(result.stdout)
        self.assertNotIn("error", value, value)
        self.assertEqual(self.status.read_bytes(), before, "the resolver must never modify package state")
        return value

    def test_real_solver_records_install_upgrade_and_removal(self):
        result = self.analyze()["packages"]
        self.assertTrue(result["simulation_resolved"])
        self.assertTrue(result["metadata_complete"], "APT's absent optional binary-all index is not a cache defect")
        self.assertEqual({(a["package"], a["action"]) for a in result["actions"]},
                         {("demo", "upgrade"), ("libdemo", "upgrade"), ("oldhelper", "remove")})

    def test_real_installed_version_dependency_conflict(self):
        self.set_installed(dependency="3.0")
        self.assertEqual(self.analyze()["packages"]["broken"], ["demo"])

    def test_real_resolver_preserves_held_package(self):
        self.set_installed(hold=True)
        result = self.analyze()["packages"]
        self.assertEqual(result["held"], ["demo"])
        self.assertEqual(result["held_changed"], [])
        self.assertFalse(any(a["package"] == "demo" for a in result["actions"]))

    def test_real_pin_prevents_forbidden_library_upgrade(self):
        (self.root / "preferences").write_text("Package: libdemo\nPin: version 2.0\nPin-Priority: -1\n")
        result = self.analyze()["packages"]
        self.assertFalse(any(a["package"] in {"libdemo", "demo"} for a in result["actions"]))

    def test_online_refuses_explicit_trust_bypass(self):
        result = self.analyze(online=True)
        self.assertEqual(result["updates"]["refresh_status"], "blocked")
        self.assertEqual(result["updates"]["unsafe_options"][0]["option"], "trusted")

    def test_online_rejects_unsigned_release_and_never_runs_host_hooks(self):
        (self.root / "sources.list").write_text(f"deb file:{self.root}/repo synthetic main\n")
        marker = self.root / "hook-ran"
        with self.config.open("a") as file:
            file.write(f'APT::Update::Post-Invoke {{ "touch {marker}"; }};\n')
        result = self.analyze(online=True)
        self.assertEqual(result["updates"]["refresh_status"], "failed")
        self.assertEqual(result["updates"]["refresh_error"], "signature")
        self.assertFalse(marker.exists())
        self.assertEqual(result["packages"]["metadata_mode"], "cache")

    def signed_repository(self, *, expired=False):
        if not shutil.which("gpg") or not shutil.which("gpgconf"):
            self.skipTest("optional gpg required for signed fixture repository")
        key_dir = self.root / "test-key"
        key_dir.mkdir(mode=0o700)
        command = ["gpg", "--homedir", str(key_dir), "--batch", "--pinentry-mode", "loopback", "--passphrase", ""]
        self.addCleanup(lambda: subprocess.run(["gpgconf", "--homedir", str(key_dir), "--kill", "gpg-agent"],
                                              capture_output=True, timeout=5))
        subprocess.run([*command, "--quick-generate-key", "Ubuntu Setup Synthetic Test", "ed25519", "sign", "0"],
                       check=True, capture_output=True, timeout=10)
        key = self.root / "fixture-key.gpg"
        key.write_bytes(subprocess.run([*command, "--export"], check=True, capture_output=True, timeout=5).stdout)
        release = self.root / "repo/dists/synthetic/Release"
        if expired:
            with release.open("a") as stream:
                stream.write("Date: Sat, 01 Jan 2000 00:00:00 +0000\nValid-Until: Sun, 02 Jan 2000 00:00:00 +0000\n")
        subprocess.run([*command, "--output", str(release.with_name("InRelease")), "--clearsign", str(release)],
                       check=True, capture_output=True, timeout=5)
        (self.root / "sources.list").write_text(f"deb [signed-by={key}] file:{self.root}/repo synthetic main\n")

    def test_signed_source_is_verified_and_candidates_use_fresh_isolated_indexes(self):
        self.signed_repository()
        result = self.analyze(online=True)
        self.assertEqual(result["updates"]["refresh_status"], "verified")
        self.assertTrue(all(s["apt_trusted"] for s in result["updates"]["sources"]))
        self.assertEqual(result["packages"]["metadata_mode"], "online")
        self.assertTrue(result["packages"]["metadata_complete"])

    def test_expired_signed_source_is_rejected(self):
        self.signed_repository(expired=True)
        result = self.analyze(online=True)
        self.assertEqual(result["updates"]["refresh_status"], "failed")
        self.assertEqual(result["updates"]["refresh_error"], "date")


if __name__ == "__main__":
    unittest.main()
