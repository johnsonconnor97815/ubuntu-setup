"""SnapProvider tests — every branch through FakeRun (no real snap/sudo).

What is locked here:

- check: ``snap list <store-name>`` rc 0 -> PRESENT, any non-zero -> ABSENT
  (no machine-readable rc band — a daemon error reads ABSENT too, erring
  toward a loud install attempt); a snapd-less host reads ABSENT without
  running any command.
- the store-name default: the ``snap`` field when declared, else the entry id.
- install: ``snap install <name> [--classic] [--channel=…]``, per-command
  sudo, the widened install timeout; rc != 0 -> ProviderError.
- the snapd precondition: install on a snapd-less host raises
  ``PreconditionError`` — BEFORE the check_mode guard (a dry run shows the
  visible skip) and without running any command; through ``execute()`` that
  lands as a visible SKIPPED step and the run continues (detect-and-skip,
  never install snapd ourselves).
- remove/upgrade are deferred (NotImplementedError).
"""

from __future__ import annotations

import logging
import unittest

from ubuntu_setup.core.errors import PreconditionError, ProviderError
from ubuntu_setup.core.executor import execute
from ubuntu_setup.core.models import Action, CatalogEntry, Op, Outcome, Plan
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers import get_provider, known_types
from ubuntu_setup.core.providers.apt import _INSTALL_TIMEOUT
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.providers.snap import SnapProvider
from tests._fakes import FakeRun, make_ctx, register_provider


def snap_entry(entry_id: str = "chromium", **fields) -> CatalogEntry:
    return CatalogEntry(
        id=entry_id, description="a snap", type="snap", fields=fields,
    )


def snap_list(argv: "list[str]") -> bool:
    return argv[:2] == ["snap", "list"]


def snap_install(argv: "list[str]") -> bool:
    return argv[:2] == ["snap", "install"]


def which_present(_name: str) -> "str | None":
    return "/usr/bin/snap"


def which_missing(_name: str) -> "str | None":
    return None


def provider(run: FakeRun, *, snapd: bool = True) -> SnapProvider:
    return SnapProvider(run=run, which=which_present if snapd else which_missing)


class TestCheck(unittest.TestCase):
    def test_listed_snap_is_present(self):
        run = FakeRun().when(snap_list, returncode=0, stdout="chromium 149 ...\n")
        self.assertIs(provider(run).check(snap_entry()), State.PRESENT)
        self.assertEqual(run.calls[0].argv, ["snap", "list", "chromium"])
        self.assertFalse(run.calls[0].sudo)  # check never escalates

    def test_unlisted_snap_is_absent(self):
        run = FakeRun().when(
            snap_list, returncode=1, stderr="error: no matching snaps installed\n"
        )
        self.assertIs(provider(run).check(snap_entry()), State.ABSENT)

    def test_daemon_error_reads_absent_not_raised(self):
        # snap has no rc band separating "not installed" from "daemon down":
        # every non-zero reads "not converged" — the install attempt is loud
        run = FakeRun().when(
            snap_list, returncode=1,
            stderr="error: cannot communicate with server\n",
        )
        self.assertIs(provider(run).check(snap_entry()), State.ABSENT)

    def test_store_name_field_overrides_the_entry_id(self):
        run = FakeRun().when(snap_list, returncode=0)
        provider(run).check(snap_entry("telegram", snap="telegram-desktop"))
        self.assertEqual(run.calls[0].argv, ["snap", "list", "telegram-desktop"])

    def test_snapd_missing_reads_absent_without_running_anything(self):
        run = FakeRun()
        self.assertIs(provider(run, snapd=False).check(snap_entry()), State.ABSENT)
        self.assertEqual(run.calls, [])


class TestInstall(unittest.TestCase):
    def test_plain_install_argv_sudo_and_timeout(self):
        run = FakeRun()
        provider(run).install(snap_entry("yq"), make_ctx(run))
        (call,) = run.calls
        self.assertEqual(call.argv, ["snap", "install", "yq"])
        self.assertTrue(call.sudo)  # snap needs root; per-command escalation
        self.assertEqual(call.kw.get("timeout"), _INSTALL_TIMEOUT)

    def test_classic_flag_is_appended(self):
        run = FakeRun()
        provider(run).install(snap_entry("kotlin", classic=True), make_ctx(run))
        self.assertEqual(run.calls[0].argv, ["snap", "install", "kotlin", "--classic"])

    def test_channel_flag_is_appended(self):
        run = FakeRun()
        provider(run).install(snap_entry("foo", channel="4/stable"), make_ctx(run))
        self.assertEqual(
            run.calls[0].argv, ["snap", "install", "foo", "--channel=4/stable"]
        )

    def test_classic_and_channel_combine_with_the_store_name(self):
        run = FakeRun()
        provider(run).install(
            snap_entry("jetbrains-idea", snap="intellij-idea", classic=True,
                       channel="latest/stable"),
            make_ctx(run),
        )
        self.assertEqual(
            run.calls[0].argv,
            ["snap", "install", "intellij-idea", "--classic",
             "--channel=latest/stable"],
        )

    def test_failed_install_raises_provider_error_with_stderr_tail(self):
        run = FakeRun().when(
            snap_install, returncode=1, stderr="error: cannot install\n"
        )
        with self.assertRaises(ProviderError) as caught:
            provider(run).install(snap_entry("yq"), make_ctx(run))
        self.assertIn("yq", str(caught.exception))
        self.assertIn("cannot install", str(caught.exception))
        self.assertEqual(caught.exception.entry_id, "yq")

    def test_check_mode_makes_zero_changes(self):
        run = FakeRun()
        provider(run).install(snap_entry(), make_ctx(run, check_mode=True))
        self.assertEqual(run.calls, [])

    def test_snapd_missing_raises_precondition_error(self):
        run = FakeRun()
        with self.assertRaises(PreconditionError) as caught:
            provider(run, snapd=False).install(snap_entry(), make_ctx(run))
        self.assertEqual(caught.exception.entry_id, "chromium")
        self.assertIn("snapd", str(caught.exception))
        self.assertEqual(run.calls, [])  # never attempted, never installed snapd

    def test_snapd_missing_skips_even_in_check_mode(self):
        # the probe fires BEFORE the dry-run guard: a dry run on a snapd-less
        # host must show the visible skip, never a confident "would change"
        run = FakeRun()
        with self.assertRaises(PreconditionError):
            provider(run, snapd=False).install(
                snap_entry(), make_ctx(run, check_mode=True)
            )
        self.assertEqual(run.calls, [])


class TestDeferredOps(unittest.TestCase):
    def test_remove_and_upgrade_are_deferred(self):
        run = FakeRun()
        ctx = make_ctx(run)
        with self.assertRaises(NotImplementedError):
            provider(run).remove(snap_entry(), ctx)
        with self.assertRaises(NotImplementedError):
            provider(run).upgrade(snap_entry(), ctx)


class TestRegistry(unittest.TestCase):
    def test_snap_is_a_registered_type(self):
        self.assertIn("snap", known_types())
        self.assertIsInstance(get_provider("snap"), SnapProvider)


class TestExecutorSkip(unittest.TestCase):
    def test_snapd_missing_is_a_visible_skip_and_the_run_continues(self):
        """Through execute(): the snap step lands SKIPPED (detect-and-skip,
        not fail-fast) and the next step still runs — exit code 0."""
        run = FakeRun()  # default rc 0: sudo probe ok, apt install ok
        snapless = SnapProvider(run=run, which=which_missing)
        apt_after = CatalogEntry(
            id="ripgrep", description="x", type="apt",
            fields={"package": "ripgrep"},
        )
        plan = Plan(actions=(
            Action(snap_entry(), Op.INSTALL),
            Action(apt_after, Op.INSTALL),
        ))
        with register_provider(snapless):
            events = list(execute(
                plan,
                priv=Privilege(run=run),
                logger=logging.getLogger("test"),
                run=run,
            ))
        finished = events[-1]
        self.assertEqual(finished.exit_code, 0)
        outcomes = {r.entry_id: r.outcome for r in finished.results}
        self.assertIs(outcomes["chromium"], Outcome.SKIPPED)
        self.assertIs(outcomes["ripgrep"], Outcome.CHANGED)
        self.assertFalse(run.ran("snap install"))  # the skip never ran snap

    def test_dry_run_on_a_snapd_less_host_shows_the_visible_skip(self):
        """The provider raises BEFORE its check_mode guard, so even a dry run
        (executor check_mode=True) lands the snap step SKIPPED — never a
        confident "would install" — while the run continues and mutates
        nothing (no snap, no apt-get, no sudo probe)."""
        run = FakeRun()  # default rc 0; dpkg ${Status} "" -> ripgrep ABSENT
        snapless = SnapProvider(run=run, which=which_missing)
        apt_after = CatalogEntry(
            id="ripgrep", description="x", type="apt",
            fields={"package": "ripgrep"},
        )
        plan = Plan(actions=(
            Action(snap_entry(), Op.INSTALL),
            Action(apt_after, Op.INSTALL),
        ))
        with register_provider(snapless):
            events = list(execute(
                plan,
                priv=Privilege(run=run),
                logger=logging.getLogger("test"),
                run=run,
                check_mode=True,
            ))
        finished = events[-1]
        self.assertEqual(finished.exit_code, 0)
        results = {r.entry_id: r for r in finished.results}
        self.assertIs(results["chromium"].outcome, Outcome.SKIPPED)
        self.assertIn("snapd", results["chromium"].detail)
        self.assertIs(results["ripgrep"].outcome, Outcome.CHANGED)
        self.assertIn("would install", results["ripgrep"].detail)
        self.assertFalse(run.ran("snap"))     # ZERO snap commands in dry-run
        self.assertFalse(run.ran("apt-get"))  # ZERO mutations in dry-run
        self.assertFalse(run.ran("sudo"))     # a dry run never touches sudo


if __name__ == "__main__":
    unittest.main()
