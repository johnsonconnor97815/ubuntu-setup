"""AptProvider tests — check() state mapping, install idiom, dry-run guard."""

from __future__ import annotations

import unittest

from ubuntu_setup.core.errors import ProviderError
from ubuntu_setup.core.models import CatalogEntry
from ubuntu_setup.core.providers.apt import AptProvider
from ubuntu_setup.core.providers.aptcache import AptCache
from ubuntu_setup.core.providers.base import State
from tests._fakes import FakeRun, apt_install, make_ctx, status_query, version_query


def apt_update(argv: list) -> bool:
    return argv[:2] == ["apt-get", "update"]


def _entry(**fields) -> CatalogEntry:
    return CatalogEntry(
        id="ripgrep", description="Fast grep", type="apt",
        fields={"package": "ripgrep", **fields},
    )


class TestAptCheck(unittest.TestCase):
    def test_installed_status_is_present(self):
        run = FakeRun().when(status_query, returncode=0, stdout="install ok installed")
        self.assertIs(AptProvider(run=run).check(_entry()), State.PRESENT)

    def test_no_match_rc1_is_absent(self):
        run = FakeRun().when(status_query, returncode=1, stdout="")
        self.assertIs(AptProvider(run=run).check(_entry()), State.ABSENT)

    def test_removed_not_purged_is_absent(self):
        # dpkg reports a config-files state with rc 0 — must NOT be "present"
        run = FakeRun().when(status_query, returncode=0, stdout="deinstall ok config-files")
        self.assertIs(AptProvider(run=run).check(_entry()), State.ABSENT)

    def test_real_dpkg_error_rc2_raises(self):
        run = FakeRun().when(status_query, returncode=2, stderr="dpkg DB error")
        with self.assertRaises(ProviderError):
            AptProvider(run=run).check(_entry())

    def test_version_mismatch_is_outdated(self):
        run = (
            FakeRun()
            .when(status_query, returncode=0, stdout="install ok installed")
            .when(version_query, returncode=0, stdout="1.0")
        )
        self.assertIs(AptProvider(run=run).check(_entry(version="2.0")), State.OUTDATED)

    def test_version_match_is_present(self):
        run = (
            FakeRun()
            .when(status_query, returncode=0, stdout="install ok installed")
            .when(version_query, returncode=0, stdout="2.0")
        )
        self.assertIs(AptProvider(run=run).check(_entry(version="2.0")), State.PRESENT)


class TestAptInstall(unittest.TestCase):
    def test_install_runs_apt_get_with_sudo(self):
        run = FakeRun()  # default rc 0
        AptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertTrue(run.ran("apt-get install"))
        apt_calls = [c for c in run.calls if apt_install(c.argv)]
        self.assertEqual(len(apt_calls), 1)
        self.assertTrue(apt_calls[0].sudo)  # escalated per-command
        self.assertIn("--no-install-recommends", apt_calls[0].argv)
        self.assertIn("ripgrep", apt_calls[0].argv)

    def test_install_widens_the_command_timeout(self):
        # the runner's blanket 600s default dies mid-download on heavy
        # meta-packages (libreoffice/qemu class — seen in the catalog
        # real-install verification); install carries its own wider cap
        run = FakeRun()
        AptProvider(run=run).install(_entry(), make_ctx(run))
        apt_calls = [c for c in run.calls if apt_install(c.argv)]
        self.assertGreater(apt_calls[0].kw.get("timeout", 0), 600.0)

    def test_install_pinned_version_targets_pkg_equals_version(self):
        run = FakeRun()
        AptProvider(run=run).install(_entry(version="13.0.0"), make_ctx(run))
        apt_calls = [c for c in run.calls if apt_install(c.argv)]
        self.assertIn("ripgrep=13.0.0", apt_calls[0].argv)

    def test_check_mode_makes_zero_changes(self):
        run = FakeRun()
        AptProvider(run=run).install(_entry(), make_ctx(run, check_mode=True))
        self.assertFalse(run.ran("apt-get"))  # mutation guard honored

    def test_install_failure_raises_provider_error(self):
        run = FakeRun().when(apt_install, returncode=100, stderr="E: Unable to locate package")
        with self.assertRaises(ProviderError):
            AptProvider(run=run).install(_entry(), make_ctx(run))

    def test_install_consumes_a_pending_repo_change_before_installing(self):
        # the freshness guard's consumption side: a repo entry converged
        # earlier this run marked the cache -> update once, BEFORE install
        run = FakeRun()
        cache = AptCache()
        cache.mark_repo_changed()
        AptProvider(run=run).install(_entry(), make_ctx(run, aptcache=cache))
        update_idx = [i for i, c in enumerate(run.calls) if apt_update(c.argv)]
        install_idx = [i for i, c in enumerate(run.calls) if apt_install(c.argv)]
        self.assertEqual(len(update_idx), 1)
        self.assertLess(update_idx[0], install_idx[0])
        self.assertFalse(cache.pending)

    def test_install_with_a_fresh_cache_never_updates(self):
        run = FakeRun()
        AptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertEqual(run.count(apt_update), 0)


if __name__ == "__main__":
    unittest.main()
