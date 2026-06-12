"""ScriptProvider tests — check state mapping, the controlled bash execution
form, sudo routing, HOME pinning, the dry-run guard, and the deferred ops."""

from __future__ import annotations

import unittest

from ubuntu_setup.core.errors import CatalogError, ProviderError
from ubuntu_setup.core.models import CatalogEntry
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.base import State
from ubuntu_setup.core.providers.script import ScriptProvider, shell_argv
from tests._fakes import FakeRun, make_ctx

CHECK_CMD = 'test -x "$HOME/.cargo/bin/rustc"'
INSTALL_CMD = "curl -sSf https://sh.rustup.rs | sh -s -- -y"


def _entry(*, sudo: "bool | None" = None, **overrides) -> CatalogEntry:
    fields = {"check": CHECK_CMD, "install": INSTALL_CMD}
    if sudo is not None:
        fields["sudo"] = sudo
    fields.update(overrides)
    return CatalogEntry(
        id="rust", description="Rust toolchain", type="script", fields=fields,
    )


def is_check(argv: list) -> bool:
    return argv[-1] == CHECK_CMD


def is_install(argv: list) -> bool:
    return argv[-1] == INSTALL_CMD


class TestShellArgv(unittest.TestCase):
    def test_controlled_bash_form_with_pipefail(self):
        # the spec's sanctioned `bash -c` form for script, plus pipefail so a
        # failed curl in `curl … | sh` fails the step (sh alone would exit 0)
        self.assertEqual(
            shell_argv("curl x | sh"),
            ["bash", "-o", "pipefail", "-c", "curl x | sh"],
        )

    def test_never_a_login_shell(self):
        # -l would source the user's profile: probes must not depend on
        # login-shell PATH (prd: absolute paths / explicit env instead)
        self.assertNotIn("-l", shell_argv("true"))
        self.assertNotIn("-lc", shell_argv("true"))


class TestScriptCheck(unittest.TestCase):
    def test_exit_zero_is_present(self):
        run = FakeRun().when(is_check, returncode=0)
        self.assertIs(ScriptProvider(run=run).check(_entry()), State.PRESENT)

    def test_exit_one_is_absent(self):
        run = FakeRun().when(is_check, returncode=1)
        self.assertIs(ScriptProvider(run=run).check(_entry()), State.ABSENT)

    def test_command_not_found_127_is_absent_not_an_error(self):
        # a probe like `some-tool --version` exits 127 when the tool is absent
        # — unlike dpkg there is no machine-readable "real error" band, so any
        # non-zero reads "not converged" (errs toward a loud install attempt)
        run = FakeRun().when(is_check, returncode=127)
        self.assertIs(ScriptProvider(run=run).check(_entry()), State.ABSENT)

    def test_check_runs_the_verbatim_command_via_bash(self):
        run = FakeRun().when(is_check, returncode=0)
        ScriptProvider(run=run).check(_entry())
        self.assertEqual(run.calls[0].argv, shell_argv(CHECK_CMD))

    def test_check_is_unprivileged_by_default(self):
        run = FakeRun().when(is_check, returncode=0)
        ScriptProvider(run=run).check(_entry())
        self.assertFalse(run.calls[0].sudo)

    def test_check_runs_under_the_declared_identity(self):
        # prd: check and the mutating ops run under the SAME identity
        run = FakeRun().when(is_check, returncode=0)
        ScriptProvider(run=run).check(_entry(sudo=True))
        self.assertTrue(run.calls[0].sudo)

    def test_unprivileged_check_pins_home_to_the_real_users_home(self):
        # `$HOME` in author commands must stay authoritative even if the app
        # was (against Rule 1) launched under sudo — pinned from the passwd DB
        run = FakeRun().when(is_check, returncode=0)
        ScriptProvider(run=run).check(_entry())
        self.assertEqual(
            run.calls[0].kw.get("extra_env"), {"HOME": Privilege().real_home()}
        )

    def test_sudo_check_passes_no_extra_env(self):
        # sudo's env_reset strips the parent env anyway; root-level commands
        # must not use $HOME at all (authoring rule)
        run = FakeRun().when(is_check, returncode=0)
        ScriptProvider(run=run).check(_entry(sudo=True))
        self.assertIsNone(run.calls[0].kw.get("extra_env"))

    def test_missing_check_field_raises_catalog_error(self):
        entry = CatalogEntry(id="bad", description="x", type="script",
                             fields={"install": "x"})
        with self.assertRaises(CatalogError):
            ScriptProvider(run=FakeRun()).check(entry)


class TestScriptInstall(unittest.TestCase):
    def test_install_runs_the_verbatim_command_via_bash(self):
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(), make_ctx(run))
        install_calls = [c for c in run.calls if is_install(c.argv)]
        self.assertEqual(len(install_calls), 1)
        self.assertEqual(install_calls[0].argv, shell_argv(INSTALL_CMD))

    def test_install_is_unprivileged_by_default(self):
        # most script entries are user-level installs into $HOME (prd):
        # never escalate without the explicit declaration
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertFalse(run.calls[0].sudo)

    def test_install_escalates_when_declared(self):
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(sudo=True), make_ctx(run))
        self.assertTrue(run.calls[0].sudo)

    def test_unprivileged_install_pins_home(self):
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertEqual(
            run.calls[0].kw.get("extra_env"), {"HOME": Privilege().real_home()}
        )

    def test_install_widens_the_command_timeout(self):
        # official installers download hundreds of MB (rust toolchain /
        # ollama bundle class) — same widened cap as apt install
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertGreater(run.calls[0].kw.get("timeout", 0), 600.0)

    def test_check_mode_makes_zero_changes(self):
        run = FakeRun()
        ScriptProvider(run=run).install(_entry(), make_ctx(run, check_mode=True))
        self.assertEqual(run.calls, [])  # mutation guard honored

    def test_install_failure_raises_provider_error_with_stderr_tail(self):
        run = FakeRun().when(is_install, returncode=1, stderr="curl: (22) 404")
        with self.assertRaises(ProviderError) as caught:
            ScriptProvider(run=run).install(_entry(), make_ctx(run))
        self.assertIn("curl: (22) 404", str(caught.exception))

    def test_missing_install_field_raises_catalog_error(self):
        entry = CatalogEntry(id="bad", description="x", type="script",
                             fields={"check": "x"})
        with self.assertRaises(CatalogError):
            ScriptProvider(run=FakeRun()).install(entry, make_ctx(FakeRun()))


class TestScriptDeferredOps(unittest.TestCase):
    def test_remove_is_deferred_even_when_the_field_is_present(self):
        # the schema reserves the field; the op stays unimplemented (prd)
        run = FakeRun()
        entry = _entry(remove="rustup self uninstall -y")
        with self.assertRaises(NotImplementedError):
            ScriptProvider(run=run).remove(entry, make_ctx(run))
        self.assertEqual(run.calls, [])

    def test_upgrade_is_deferred_even_when_the_field_is_present(self):
        run = FakeRun()
        entry = _entry(upgrade="rustup update")
        with self.assertRaises(NotImplementedError):
            ScriptProvider(run=run).upgrade(entry, make_ctx(run))
        self.assertEqual(run.calls, [])


if __name__ == "__main__":
    unittest.main()
