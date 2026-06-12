"""PpaProvider tests — the deb-repo reuse seam.

What is ppa-specific (and therefore tested here): the <owner>/<name> ->
repo-fields translation (ppa.launchpadcontent.net URL, {codename} suite,
main component, entry-id basename, Launchpad key-API URL) and the JSON key
unwrap. The shared mechanics (byte-for-byte check, fetched-lists probe,
per-command sudo placement, freshness marking) are exercised end-to-end
through the translated entry so a drift in the reuse seam fails loudly —
the exhaustive deb matrix itself lives in ``test_deb.py``.

All through FakeRun + a tmpdir root: no real apt, sudo or network.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.core.errors import CatalogError, ProviderError
from ubuntu_setup.core.models import CatalogEntry
from ubuntu_setup.core.providers import get_provider, known_types
from ubuntu_setup.core.providers.aptcache import AptCache
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.providers.ppa import PpaProvider
from tests._fakes import FakeRun, make_ctx

ARMORED_KEY = (
    "-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmQINBF...\n"
    "-----END PGP PUBLIC KEY BLOCK-----\n"
)

EXPECTED_KEY_URL = (
    "https://api.launchpad.net/devel/~inkscape.dev/+archive/ubuntu/stable"
    "?ws.op=getSigningKeyData"
)


def ppa_entry(coordinate: str = "inkscape.dev/stable", **fields) -> CatalogEntry:
    return CatalogEntry(
        id="inkscape-repo", description="Inkscape PPA", type="ppa",
        fields={"ppa": coordinate, **fields},
    )


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
    return FakeRun().when(dpkg_arch, returncode=0, stdout="amd64\n")


class KeyWritingRun:
    """Wraps a FakeRun so the curl rule actually *writes* the downloaded body
    (the provider JSON-decodes and armor-sniffs it). Records what the staged
    key file contained when gpg saw it, proving the unwrap happened first."""

    def __init__(self, inner: FakeRun, body: str) -> None:
        self.inner = inner
        self.body = body
        self.key_seen_by_gpg: "str | None" = None

    def __call__(self, argv, **kw):
        a = list(argv)
        if curl_download(a):
            Path(a[a.index("-o") + 1]).write_text(self.body, encoding="utf-8")
        if gpg_dearmor(a):
            self.key_seen_by_gpg = Path(a[-1]).read_text(encoding="utf-8")
        return self.inner(a, **kw)


class PpaTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="usetup-ppa-test-")
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        (self.root / "etc/os-release").parent.mkdir(parents=True)
        (self.root / "etc/os-release").write_text(
            'PRETTY_NAME="Ubuntu 24.04.2 LTS"\nUBUNTU_CODENAME=noble\n'
        )

    def provider(self, run) -> PpaProvider:
        return PpaProvider(run=run, root=self.root)

    def write(self, canonical: str, content: str) -> None:
        path = self.root / canonical.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def plant_converged(self, provider: PpaProvider, entry: CatalogEntry) -> None:
        """All PRESENT conditions of the shared repo check: sources + key +
        fetched lists (a ppa entry never declares a pin)."""
        self.write(provider.sources_path(entry), provider.sources_content(entry))
        self.write(provider.keyring_path(entry), "binary-keyring-bytes")
        self.write(provider.lists_release_paths(entry)[0], "x")


class TestTranslation(PpaTestCase):
    def test_sources_content_is_the_derived_deb822_body(self):
        self.assertEqual(
            self.provider(fake_run()).sources_content(ppa_entry()),
            "Types: deb\n"
            "URIs: https://ppa.launchpadcontent.net/inkscape.dev/stable/ubuntu\n"
            "Suites: noble\n"            # {codename} resolved from os-release
            "Components: main\n"         # every PPA publishes the main component
            "Architectures: amd64\n"     # host arch via dpkg --print-architecture
            "Signed-By: /etc/apt/keyrings/inkscape-repo.gpg\n",
        )

    def test_file_basename_is_the_entry_id(self):
        # never add-apt-repository's <owner>-ubuntu-<name> (no collision with a
        # manually added copy; deterministic check target)
        provider = self.provider(fake_run())
        entry = ppa_entry()
        self.assertEqual(provider.sources_path(entry),
                         "/etc/apt/sources.list.d/inkscape-repo.sources")
        self.assertEqual(provider.keyring_path(entry),
                         "/etc/apt/keyrings/inkscape-repo.gpg")

    def test_lists_release_paths_lock_apts_exact_mangled_names(self):
        self.assertEqual(
            self.provider(fake_run()).lists_release_paths(ppa_entry()),
            ("/var/lib/apt/lists/ppa.launchpadcontent.net_inkscape.dev_stable_"
             "ubuntu_dists_noble_InRelease",
             "/var/lib/apt/lists/ppa.launchpadcontent.net_inkscape.dev_stable_"
             "ubuntu_dists_noble_Release"),
        )

    def test_malformed_coordinate_raises_catalog_error(self):
        provider = self.provider(fake_run())
        for bad in ("no-slash", "/name", "owner/", "", "owner/name/extra"):
            with self.subTest(ppa=bad):
                with self.assertRaises(CatalogError):
                    provider.check(ppa_entry(bad))

    def test_registered_in_the_registry(self):
        self.assertIn("ppa", known_types())
        self.assertIsInstance(get_provider("ppa"), PpaProvider)


class TestCheck(PpaTestCase):
    def test_nothing_on_disk_is_absent(self):
        self.assertIs(self.provider(fake_run()).check(ppa_entry()), State.ABSENT)

    def test_fully_converged_is_present(self):
        provider = self.provider(fake_run())
        entry = ppa_entry()
        self.plant_converged(provider, entry)
        self.assertIs(provider.check(entry), State.PRESENT)

    def test_sources_drift_is_absent(self):
        # the shared deb contract through the translation: drift -> ABSENT so
        # install() re-converges (never OUTDATED, which would satisfy install)
        provider = self.provider(fake_run())
        entry = ppa_entry()
        self.plant_converged(provider, entry)
        self.write(provider.sources_path(entry),
                   "Types: deb\nURIs: https://evil.example.com\n")
        self.assertIs(provider.check(entry), State.ABSENT)

    def test_unfetched_lists_is_absent(self):
        provider = self.provider(fake_run())
        entry = ppa_entry()
        self.plant_converged(provider, entry)
        for canonical in provider.lists_release_paths(entry):
            path = self.root / canonical.lstrip("/")
            if path.exists():
                path.unlink()
        self.assertIs(provider.check(entry), State.ABSENT)


class TestInstall(PpaTestCase):
    def test_install_downloads_from_the_launchpad_key_api(self):
        run = fake_run()
        self.provider(run).install(ppa_entry(), make_ctx(run))
        curls = [c for c in run.calls if curl_download(c.argv)]
        self.assertEqual(len(curls), 1)
        self.assertFalse(curls[0].sudo)  # unprivileged download
        self.assertIn(EXPECTED_KEY_URL, curls[0].argv)

    def test_install_unwraps_json_then_dearmors_then_places_files(self):
        inner = fake_run()
        run = KeyWritingRun(inner, json.dumps(ARMORED_KEY))
        cache = AptCache()
        self.provider(inner).install(ppa_entry(), make_ctx(run, aptcache=cache))
        # gpg saw the UNWRAPPED armored key, not the JSON envelope
        self.assertEqual(inner.count(gpg_dearmor), 1)
        self.assertEqual(run.key_seen_by_gpg, ARMORED_KEY)
        # key + sources land world-readable via per-command sudo install
        key_calls = [c for c in inner.calls
                     if install_to("/etc/apt/keyrings/inkscape-repo.gpg")(c.argv)]
        src_calls = [c for c in inner.calls
                     if install_to("/etc/apt/sources.list.d/"
                                   "inkscape-repo.sources")(c.argv)]
        self.assertEqual((len(key_calls), len(src_calls)), (1, 1))
        self.assertTrue(key_calls[0].sudo and src_calls[0].sudo)
        self.assertIn("0644", key_calls[0].argv)
        # repo install marks the per-run guard but NEVER updates itself
        self.assertEqual(inner.count(apt_update), 0)
        self.assertTrue(cache.pending)

    def test_invalid_json_key_response_raises(self):
        inner = fake_run()
        run = KeyWritingRun(inner, "<html>502 Bad Gateway</html>")
        with self.assertRaises(ProviderError):
            self.provider(inner).install(ppa_entry(), make_ctx(run))

    def test_json_null_key_response_raises(self):
        # a freshly created PPA generates its key asynchronously: JSON null
        inner = fake_run()
        run = KeyWritingRun(inner, "null")
        with self.assertRaises(ProviderError):
            self.provider(inner).install(ppa_entry(), make_ctx(run))

    def test_missing_download_file_is_tolerated_for_fakes(self):
        # seam parity with deb's _is_armored: a plain FakeRun never writes the
        # file; a genuine download failure already raises on curl's exit code
        run = fake_run()
        cache = AptCache()
        self.provider(run).install(ppa_entry(), make_ctx(run, aptcache=cache))
        self.assertTrue(cache.pending)

    def test_key_download_failure_raises(self):
        run = fake_run().when(curl_download, returncode=22, stderr="curl: 404")
        with self.assertRaises(ProviderError):
            self.provider(run).install(ppa_entry(), make_ctx(run))

    def test_check_mode_makes_zero_changes(self):
        run = fake_run()
        cache = AptCache()
        self.provider(run).install(ppa_entry(),
                                   make_ctx(run, check_mode=True, aptcache=cache))
        self.assertEqual(run.calls, [])  # mutation guard: not even a download
        self.assertFalse(cache.pending)

    def test_remove_and_upgrade_are_deferred(self):
        run = fake_run()
        provider = self.provider(run)
        with self.assertRaises(NotImplementedError):
            provider.remove(ppa_entry(), make_ctx(run))
        with self.assertRaises(NotImplementedError):
            provider.upgrade(ppa_entry(), make_ctx(run))


if __name__ == "__main__":
    unittest.main()
