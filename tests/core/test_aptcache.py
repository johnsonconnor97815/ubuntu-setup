"""AptCache freshness-guard tests — mark/consume semantics, and the run-level
lock the prd demands: multiple repo entries converging in ONE run cost exactly
one ``apt-get update`` (consumed by the first package install that follows)."""

from __future__ import annotations

import logging
import unittest

from ubuntu_setup.core.errors import ProviderError
from ubuntu_setup.core.events import RunFinished
from ubuntu_setup.core.executor import execute
from ubuntu_setup.core.models import Action, CatalogEntry, Op, Outcome, Plan
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.aptcache import AptCache
from tests._fakes import FakeRun, apt_install

_LOG = logging.getLogger("test.aptcache")


def apt_update(argv: "list[str]") -> bool:
    return argv[:2] == ["apt-get", "update"]


def dpkg_arch(argv: "list[str]") -> bool:
    return argv[:2] == ["dpkg", "--print-architecture"]


class TestAptCacheUnit(unittest.TestCase):
    def test_fresh_guard_never_updates(self):
        run = FakeRun()
        AptCache().ensure_fresh(run)
        self.assertEqual(run.calls, [])

    def test_pending_change_updates_once_then_clears(self):
        run = FakeRun()
        cache = AptCache()
        cache.mark_repo_changed()
        cache.ensure_fresh(run, entry_id="pkg")
        cache.ensure_fresh(run, entry_id="pkg2")  # consumed -> no second update
        updates = [c for c in run.calls if apt_update(c.argv)]
        self.assertEqual(len(updates), 1)
        self.assertTrue(updates[0].sudo)  # escalated per command
        self.assertFalse(cache.pending)

    def test_failed_update_raises_and_stays_pending(self):
        run = FakeRun().when(apt_update, returncode=100, stderr="E: 403 mirror")
        cache = AptCache()
        cache.mark_repo_changed()
        with self.assertRaises(ProviderError):
            cache.ensure_fresh(run, entry_id="pkg")
        self.assertTrue(cache.pending)  # a retry must update again

    def test_remark_after_consume_updates_again(self):
        run = FakeRun()
        cache = AptCache()
        cache.mark_repo_changed()
        cache.ensure_fresh(run)
        cache.mark_repo_changed()  # a NEW repo later in the run
        cache.ensure_fresh(run)
        self.assertEqual(run.count(apt_update), 2)


class TestRunLevelDedupe(unittest.TestCase):
    """The prd's acceptance lock: one run, several repo entries, ONE update."""

    @staticmethod
    def _repo(eid: str) -> CatalogEntry:
        # fictitious repo names so check() (which reads the live filesystem
        # under the default root) can never find them converged on a dev box
        return CatalogEntry(
            id=eid, description="x", type="deb",
            fields={
                "name": f"usetup-test-{eid}",
                "key_url": f"https://example.invalid/{eid}.gpg",
                "repo_url": f"https://example.invalid/{eid}/apt",
                "suite": "stable",
                "components": ["main"],
            },
        )

    @staticmethod
    def _pkg(eid: str, deps: "tuple[str, ...]") -> CatalogEntry:
        return CatalogEntry(id=eid, description="x", type="apt",
                            depends_on=deps, fields={"package": eid})

    def test_two_repos_one_package_one_update(self):
        plan = Plan(actions=(
            Action(entry=self._repo("repo-a"), op=Op.INSTALL),
            Action(entry=self._repo("repo-b"), op=Op.INSTALL),
            Action(entry=self._pkg("pkg-a", ("repo-a", "repo-b")), op=Op.INSTALL),
        ))
        run = FakeRun().when(dpkg_arch, returncode=0, stdout="amd64\n")
        events = list(execute(plan, priv=Privilege(run=run), logger=_LOG, run=run))
        fin = events[-1]
        assert isinstance(fin, RunFinished)
        self.assertEqual(fin.exit_code, 0)
        self.assertEqual([r.outcome for r in fin.results], [Outcome.CHANGED] * 3)
        # the lock: both repos converged, exactly ONE apt-get update — and it
        # ran before the package's apt-get install
        update_calls = [i for i, c in enumerate(run.calls) if apt_update(c.argv)]
        install_calls = [i for i, c in enumerate(run.calls) if apt_install(c.argv)]
        self.assertEqual(len(update_calls), 1)
        self.assertEqual(len(install_calls), 1)
        self.assertLess(update_calls[0], install_calls[0])

    def test_repo_added_after_a_consume_updates_again_before_its_consumer(self):
        # interleaved chains (repo-a, pkg-a, repo-b, pkg-b): each batch of repo
        # changes is consumed exactly once -> two updates, each before its
        # consumer's install (the guard batches, it never starves a new repo)
        plan = Plan(actions=(
            Action(entry=self._repo("repo-a"), op=Op.INSTALL),
            Action(entry=self._pkg("pkg-a", ("repo-a",)), op=Op.INSTALL),
            Action(entry=self._repo("repo-b"), op=Op.INSTALL),
            Action(entry=self._pkg("pkg-b", ("repo-b",)), op=Op.INSTALL),
        ))
        run = FakeRun().when(dpkg_arch, returncode=0, stdout="amd64\n")
        events = list(execute(plan, priv=Privilege(run=run), logger=_LOG, run=run))
        fin = events[-1]
        assert isinstance(fin, RunFinished)
        self.assertEqual(fin.exit_code, 0)
        self.assertEqual(run.count(apt_update), 2)

    def test_a_plain_apt_run_never_updates(self):
        plan = Plan(actions=(Action(entry=self._pkg("pkg-a", ()), op=Op.INSTALL),))
        run = FakeRun()
        list(execute(plan, priv=Privilege(run=run), logger=_LOG, run=run))
        self.assertEqual(run.count(apt_update), 0)


if __name__ == "__main__":
    unittest.main()
