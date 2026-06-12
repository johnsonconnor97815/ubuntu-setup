"""DebProvider tests — repo-mode check/install (deb822 + keyring + pin +
fetched-lists probe), direct-mode check/install, dry-run guard, freshness
marking. All through FakeRun + a tmpdir root: no real apt, sudo or network."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.core.errors import ProviderError
from ubuntu_setup.core.models import CatalogEntry
from ubuntu_setup.core.providers.aptcache import AptCache
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.providers.deb import DebProvider
from tests._fakes import FakeRun, apt_install, make_ctx, status_query

ARMORED_KEY = b"-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----\n"
BINARY_KEY = b"\x99\x02\x0d\x04binary-keyring-bytes"


def repo_entry(**fields) -> CatalogEntry:
    base = {
        "name": "docker",
        "key_url": "https://download.docker.com/linux/ubuntu/gpg",
        "repo_url": "https://download.docker.com/linux/ubuntu",
        "suite": "{codename}",
        "components": ["stable"],
    }
    base.update(fields)
    return CatalogEntry(id="docker-repo", description="Docker repo", type="deb",
                        fields=base)


def direct_entry(**fields) -> CatalogEntry:
    base = {
        "deb_url": "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb",
        "package": "google-chrome-stable",
    }
    base.update(fields)
    return CatalogEntry(id="chrome", description="Chrome", type="deb", fields=base)


def dpkg_arch(argv: "list[str]") -> bool:
    return argv[:2] == ["dpkg", "--print-architecture"]


def curl_download(argv: "list[str]") -> bool:
    return argv[:1] == ["curl"]


def gpg_dearmor(argv: "list[str]") -> bool:
    return argv[:1] == ["gpg"] and "--dearmor" in argv


def apt_update(argv: "list[str]") -> bool:
    return argv[:2] == ["apt-get", "update"]


def install_to(target_prefix: str):
    def match(argv: "list[str]") -> bool:
        return argv[:1] == ["install"] and argv[-1].startswith(target_prefix)
    return match


def fake_run() -> FakeRun:
    """A FakeRun with the host probes scripted (arch query)."""
    return FakeRun().when(dpkg_arch, returncode=0, stdout="amd64\n")


class WritingRun:
    """Wraps a FakeRun so the curl rule actually *writes* the downloaded file
    (the provider sniffs it to decide on dearmoring)."""

    def __init__(self, inner: FakeRun, key_bytes: bytes) -> None:
        self.inner = inner
        self.key_bytes = key_bytes

    def __call__(self, argv, **kw):
        if curl_download(list(argv)):
            Path(argv[argv.index("-o") + 1]).write_bytes(self.key_bytes)
        return self.inner(argv, **kw)


class RepoRoot:
    """A tmpdir standing in for `/`: helpers plant the artifacts check() reads."""

    def __init__(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="usetup-deb-test-")
        self.path = Path(self._tmp.name)
        (self.path / "etc/os-release").parent.mkdir(parents=True)
        (self.path / "etc/os-release").write_text(
            'PRETTY_NAME="Ubuntu 24.04.2 LTS"\nVERSION_CODENAME=noble\n'
            "UBUNTU_CODENAME=noble\n"
        )

    def cleanup(self) -> None:
        self._tmp.cleanup()

    def write(self, canonical: str, content: "str | bytes") -> None:
        path = self.path / canonical.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content)

    def plant_converged_repo(self, provider: DebProvider, entry: CatalogEntry) -> None:
        """All four PRESENT conditions: sources + key + (pin) + fetched lists."""
        self.write(provider.sources_path(entry), provider.sources_content(entry))
        self.write(provider.keyring_path(entry), BINARY_KEY)
        pin = provider.pin_content(entry)
        if pin is not None:
            self.write(provider.preferences_path(entry), pin)
        self.write(provider.lists_release_paths(entry)[0], "x")


class DebTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.root = RepoRoot()
        self.addCleanup(self.root.cleanup)

    def provider(self, run) -> DebProvider:
        return DebProvider(run=run, root=self.root.path)


class TestRepoSourcesContent(DebTestCase):
    def test_deb822_body_with_codename_and_host_arch(self):
        provider = self.provider(fake_run())
        self.assertEqual(
            provider.sources_content(repo_entry()),
            "Types: deb\n"
            "URIs: https://download.docker.com/linux/ubuntu\n"
            "Suites: noble\n"            # {codename} resolved from os-release
            "Components: stable\n"
            "Architectures: amd64\n"     # host arch via dpkg --print-architecture
            "Signed-By: /etc/apt/keyrings/docker.gpg\n",
        )

    def test_explicit_architectures_skip_the_host_probe(self):
        run = FakeRun()  # NO arch rule: a probe would yield empty stdout -> error
        entry = repo_entry(suite="stable", architectures=["amd64", "arm64", "armhf"])
        content = self.provider(run).sources_content(entry)
        self.assertIn("Architectures: amd64 arm64 armhf\n", content)
        self.assertEqual(run.count(dpkg_arch), 0)

    def test_flat_repo_omits_components_line(self):
        entry = repo_entry(suite="/", components=None)
        entry.fields.pop("components")
        content = self.provider(fake_run()).sources_content(entry)
        self.assertIn("Suites: /\n", content)
        self.assertNotIn("Components:", content)

    def test_arch_probe_failure_raises(self):
        run = FakeRun().when(dpkg_arch, returncode=1, stderr="boom")
        with self.assertRaises(ProviderError):
            self.provider(run).sources_content(repo_entry(suite="stable"))

    def test_missing_codename_raises(self):
        self.root.write("/etc/os-release", 'PRETTY_NAME="Debian-ish"\n')
        with self.assertRaises(ProviderError):
            self.provider(fake_run()).sources_content(repo_entry())

    def test_name_defaults_to_entry_id(self):
        entry = repo_entry(suite="stable")
        entry.fields.pop("name")
        provider = self.provider(fake_run())
        self.assertEqual(provider.keyring_path(entry), "/etc/apt/keyrings/docker-repo.gpg")
        self.assertEqual(provider.sources_path(entry),
                         "/etc/apt/sources.list.d/docker-repo.sources")


class TestRepoCheck(DebTestCase):
    def test_nothing_on_disk_is_absent(self):
        self.assertIs(self.provider(fake_run()).check(repo_entry()), State.ABSENT)

    def test_fully_converged_is_present(self):
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        self.assertIs(provider.check(entry), State.PRESENT)

    def test_sources_content_drift_is_absent(self):
        # drift -> ABSENT so install() is the convergence op that rewrites it
        # (OUTDATED would *satisfy* an install and never converge)
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        self.root.write(provider.sources_path(entry),
                        "Types: deb\nURIs: https://evil.example.com\n")
        self.assertIs(provider.check(entry), State.ABSENT)

    def test_missing_or_empty_key_is_absent(self):
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        self.root.write(provider.keyring_path(entry), b"")
        self.assertIs(provider.check(entry), State.ABSENT)

    def test_unfetched_lists_is_absent(self):
        # configured but `apt-get update` never ran for it: not converged —
        # the self-healing half of the freshness guard (a repo-only run is
        # re-converged and consumed on the next run)
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        lists = self.root.path / "var/lib/apt/lists"
        for item in lists.iterdir():
            item.unlink()
        self.assertIs(provider.check(entry), State.ABSENT)

    def test_release_paths_lock_apts_exact_mangled_names(self):
        # the real-world filename apt writes for the docker pilot, byte-exact
        self.assertEqual(
            self.provider(fake_run()).lists_release_paths(repo_entry()),
            ("/var/lib/apt/lists/"
             "download.docker.com_linux_ubuntu_dists_noble_InRelease",
             "/var/lib/apt/lists/"
             "download.docker.com_linux_ubuntu_dists_noble_Release"),
        )

    def test_flat_repo_release_paths(self):
        # flat at the root (kubectl `Suites: /`) and flat at a path (Sublime
        # `Suites: apt/stable/`): the release file sits at <uri>/<suite>/
        provider = self.provider(fake_run())
        root_flat = repo_entry(
            repo_url="https://pkgs.k8s.io/core:/stable:/v1.30/deb/", suite="/")
        root_flat.fields.pop("components")
        self.assertEqual(
            provider.lists_release_paths(root_flat)[0],
            "/var/lib/apt/lists/pkgs.k8s.io_core:_stable:_v1.30_deb_InRelease",
        )
        path_flat = repo_entry(
            repo_url="https://download.sublimetext.com/", suite="apt/stable/")
        path_flat.fields.pop("components")
        self.assertEqual(
            provider.lists_release_paths(path_flat)[0],
            "/var/lib/apt/lists/download.sublimetext.com_apt_stable_InRelease",
        )

    def test_underscore_in_repo_url_is_percent_quoted_like_apt(self):
        # apt's URItoFileName quotes `_` itself as %5f; a literal-underscore
        # probe would NEVER find the file -> the repo would re-converge forever
        entry = repo_entry(repo_url="https://example.com/my_repo", suite="stable")
        provider = self.provider(fake_run())
        self.assertEqual(
            provider.lists_release_paths(entry)[0],
            "/var/lib/apt/lists/example.com_my%5frepo_dists_stable_InRelease",
        )
        self.root.plant_converged_repo(provider, entry)
        self.assertIs(provider.check(entry), State.PRESENT)

    def test_sibling_path_repo_lists_do_not_count(self):
        # exact-name matching: a fetched sibling repo whose URI extends ours
        # (…/ubuntu vs …/ubuntu/sub) must NOT satisfy the fetched-lists probe —
        # a prefix glob would read a never-fetched repo as PRESENT and stick
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        for canonical in provider.lists_release_paths(entry):
            path = self.root.path / canonical.lstrip("/")
            if path.exists():
                path.unlink()
        self.root.write(
            "/var/lib/apt/lists/"
            "download.docker.com_linux_ubuntu_sub_dists_noble_InRelease",
            "x",
        )
        self.assertIs(provider.check(entry), State.ABSENT)

    def test_plain_release_file_also_proves_the_fetch(self):
        # servers without an inline-signed InRelease ship Release(+.gpg)
        provider = self.provider(fake_run())
        entry = repo_entry()
        self.root.plant_converged_repo(provider, entry)
        in_release, release = provider.lists_release_paths(entry)
        (self.root.path / in_release.lstrip("/")).unlink()
        self.root.write(release, "x")
        self.assertIs(provider.check(entry), State.PRESENT)

    def test_pin_drift_is_absent_and_pin_match_is_present(self):
        provider = self.provider(fake_run())
        entry = repo_entry(pin={"package": "*",
                                "pin": "origin download.docker.com",
                                "priority": 1000})
        self.root.plant_converged_repo(provider, entry)
        self.assertIs(provider.check(entry), State.PRESENT)
        self.root.write(provider.preferences_path(entry), "Pin-Priority: 1\n")
        self.assertIs(provider.check(entry), State.ABSENT)


class TestRepoInstall(DebTestCase):
    def test_install_places_key_and_sources_via_sudo_install(self):
        run = fake_run()
        cache = AptCache()
        provider = self.provider(run)
        provider.install(repo_entry(), make_ctx(run, aptcache=cache))

        # keyrings dir ensured (idempotent), escalated
        dir_calls = [c for c in run.calls
                     if c.argv[:4] == ["install", "-m", "0755", "-d"]]
        self.assertEqual(len(dir_calls), 1)
        self.assertTrue(dir_calls[0].sudo)
        # key downloaded UNprivileged via curl
        curls = [c for c in run.calls if curl_download(c.argv)]
        self.assertEqual(len(curls), 1)
        self.assertFalse(curls[0].sudo)
        self.assertIn("https://download.docker.com/linux/ubuntu/gpg", curls[0].argv)
        # key + sources land world-readable via per-command sudo install
        key_calls = [c for c in run.calls
                     if install_to("/etc/apt/keyrings/docker.gpg")(c.argv)]
        src_calls = [c for c in run.calls
                     if install_to("/etc/apt/sources.list.d/docker.sources")(c.argv)]
        self.assertEqual((len(key_calls), len(src_calls)), (1, 1))
        self.assertTrue(key_calls[0].sudo and src_calls[0].sudo)
        self.assertIn("0644", key_calls[0].argv)
        # repo install marks the per-run guard but NEVER updates itself
        self.assertEqual(run.count(apt_update), 0)
        self.assertTrue(cache.pending)

    def test_armored_key_is_dearmored_binary_key_is_not(self):
        for key_bytes, expect_dearmor in ((ARMORED_KEY, 1), (BINARY_KEY, 0)):
            with self.subTest(dearmor=expect_dearmor):
                inner = fake_run()
                run = WritingRun(inner, key_bytes)
                self.provider(inner).install(repo_entry(), make_ctx(run))
                self.assertEqual(inner.count(gpg_dearmor), expect_dearmor)

    def test_pin_is_written_when_declared(self):
        run = fake_run()
        entry = repo_entry(pin={"package": "*", "pin": "origin packages.mozilla.org",
                                "priority": 1000})
        self.provider(run).install(entry, make_ctx(run))
        pin_calls = [c for c in run.calls
                     if install_to("/etc/apt/preferences.d/docker")(c.argv)]
        self.assertEqual(len(pin_calls), 1)
        self.assertTrue(pin_calls[0].sudo)

    def test_check_mode_makes_zero_changes(self):
        run = fake_run()
        cache = AptCache()
        self.provider(run).install(repo_entry(),
                                   make_ctx(run, check_mode=True, aptcache=cache))
        self.assertEqual(run.calls, [])  # mutation guard: not even a download
        self.assertFalse(cache.pending)

    def test_key_download_failure_raises(self):
        run = fake_run().when(curl_download, returncode=22, stderr="curl: (22) 404")
        with self.assertRaises(ProviderError):
            self.provider(run).install(repo_entry(), make_ctx(run))

    def test_dearmor_failure_raises(self):
        inner = fake_run().when(gpg_dearmor, returncode=2, stderr="gpg: no data")
        run = WritingRun(inner, ARMORED_KEY)
        with self.assertRaises(ProviderError):
            self.provider(inner).install(repo_entry(), make_ctx(run))

    def test_sources_placement_failure_raises(self):
        run = fake_run().when(install_to("/etc/apt/sources.list.d/"),
                              returncode=1, stderr="read-only fs")
        cache = AptCache()
        with self.assertRaises(ProviderError):
            self.provider(run).install(repo_entry(), make_ctx(run, aptcache=cache))
        self.assertFalse(cache.pending)  # a failed converge never marks


class TestDirectMode(DebTestCase):
    def test_check_uses_the_dpkg_status_gate(self):
        run = FakeRun().when(status_query, returncode=0, stdout="install ok installed")
        self.assertIs(self.provider(run).check(direct_entry()), State.PRESENT)
        run = FakeRun().when(status_query, returncode=1)
        self.assertIs(self.provider(run).check(direct_entry()), State.ABSENT)

    def test_check_real_dpkg_error_raises(self):
        run = FakeRun().when(status_query, returncode=2, stderr="dpkg DB error")
        with self.assertRaises(ProviderError):
            self.provider(run).check(direct_entry())

    def test_install_downloads_then_apt_installs_the_local_file(self):
        run = FakeRun()
        self.provider(run).install(direct_entry(), make_ctx(run))
        curls = [c for c in run.calls if curl_download(c.argv)]
        self.assertEqual(len(curls), 1)
        self.assertFalse(curls[0].sudo)
        apt_calls = [c for c in run.calls if apt_install(c.argv)]
        self.assertEqual(len(apt_calls), 1)
        self.assertTrue(apt_calls[0].sudo)
        # the target is the downloaded file by ABSOLUTE path (apt treats it as
        # a local .deb and resolves dependencies), not a repo package name
        self.assertTrue(apt_calls[0].argv[-1].startswith("/"))
        self.assertTrue(apt_calls[0].argv[-1].endswith("chrome.deb"))
        self.assertGreater(apt_calls[0].kw.get("timeout", 0), 600.0)

    def test_install_consumes_a_pending_repo_change_first(self):
        run = FakeRun()
        cache = AptCache()
        cache.mark_repo_changed()
        self.provider(run).install(direct_entry(), make_ctx(run, aptcache=cache))
        update_idx = next(i for i, c in enumerate(run.calls) if apt_update(c.argv))
        install_idx = next(i for i, c in enumerate(run.calls) if apt_install(c.argv))
        self.assertLess(update_idx, install_idx)
        self.assertFalse(cache.pending)

    def test_install_failure_raises(self):
        run = FakeRun().when(apt_install, returncode=100, stderr="E: broken deps")
        with self.assertRaises(ProviderError):
            self.provider(run).install(direct_entry(), make_ctx(run))

    def test_check_mode_makes_zero_changes(self):
        run = FakeRun()
        self.provider(run).install(direct_entry(), make_ctx(run, check_mode=True))
        self.assertEqual(run.calls, [])


if __name__ == "__main__":
    unittest.main()
