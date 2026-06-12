"""Catalog loader tests — schema validation + loader-enforced invariants."""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from ubuntu_setup.core.catalog import DEFAULT_CATALOG_DIR, load_catalog
from ubuntu_setup.core.errors import CatalogError


class TestShippedCatalog(unittest.TestCase):
    def test_loads_shipped_entries(self):
        entries = load_catalog()  # default shipped catalog
        self.assertIn("ripgrep", entries)
        rg = entries["ripgrep"]
        self.assertEqual(rg.type, "apt")
        self.assertEqual(rg.fields["package"], "ripgrep")


class TestCatalogValidation(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        # the loader reads schema.json from the catalog dir
        shutil.copy(DEFAULT_CATALOG_DIR / "schema.json", self.dir / "schema.json")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def _write(self, text: str) -> None:
        (self.dir / "entries.yaml").write_text(text, encoding="utf-8")

    def test_apt_without_package_fails_schema(self):
        self._write("- {id: foo, description: x, type: apt}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_unregistered_type_is_rejected(self):
        self._write("- {id: foo, description: x, type: brew, name: foo}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_duplicate_id_is_rejected(self):
        self._write(
            "- {id: dup, description: a, type: apt, package: a}\n"
            "- {id: dup, description: b, type: apt, package: b}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_unknown_depends_on_is_rejected(self):
        self._write("- {id: foo, description: x, type: apt, package: foo, depends_on: [nope]}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_bad_id_pattern_fails_schema(self):
        self._write("- {id: 'Bad Id', description: x, type: apt, package: foo}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_valid_entry_parses_type_specific_fields(self):
        self._write("- {id: foo, description: x, type: apt, package: foo-pkg, version: '1.2'}\n")
        entries = load_catalog(self.dir)
        self.assertEqual(entries["foo"].fields["package"], "foo-pkg")
        self.assertEqual(entries["foo"].fields["version"], "1.2")

    def test_requires_parses_and_defaults_empty(self):
        self._write(
            "- {id: gui, description: x, type: apt, package: gui, requires: [desktop]}\n"
            "- {id: cli, description: x, type: apt, package: cli}\n"
        )
        entries = load_catalog(self.dir)
        self.assertEqual(entries["gui"].requires, ("desktop",))
        self.assertNotIn("requires", entries["gui"].fields)  # common field, not type-specific
        self.assertEqual(entries["cli"].requires, ())  # old entries: unaffected

    def test_unknown_requires_value_fails_schema(self):
        self._write("- {id: foo, description: x, type: apt, package: foo, requires: [warp-drive]}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_requires_must_be_a_list(self):
        self._write("- {id: foo, description: x, type: apt, package: foo, requires: desktop}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    # -- deb: two mutually exclusive modes (schema kept in sync with deb.py) --
    _DEB_REPO = (
        "- {id: r, description: x, type: deb, "
        "key_url: 'https://example.com/k.gpg', "
        "repo_url: 'https://example.com/apt', suite: stable, components: [main]%s}\n"
    )

    def test_deb_repo_mode_parses(self):
        self._write(self._DEB_REPO % "")
        entries = load_catalog(self.dir)
        self.assertEqual(entries["r"].fields["suite"], "stable")

    def test_deb_direct_mode_parses(self):
        self._write(
            "- {id: d, description: x, type: deb, "
            "deb_url: 'https://example.com/a.deb', package: a}\n"
        )
        entries = load_catalog(self.dir)
        self.assertEqual(entries["d"].fields["package"], "a")

    def test_deb_without_either_mode_fails_schema(self):
        self._write("- {id: d, description: x, type: deb}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_deb_repo_mode_missing_suite_fails_schema(self):
        self._write(
            "- {id: r, description: x, type: deb, "
            "key_url: 'https://example.com/k.gpg', repo_url: 'https://example.com/apt'}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_deb_mixed_modes_fail_schema(self):
        self._write(self._DEB_REPO % ", deb_url: 'https://example.com/a.deb', package: a")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_deb_direct_mode_without_package_fails_schema(self):
        # direct mode needs `package`: the idempotency check is the dpkg gate
        self._write("- {id: d, description: x, type: deb, deb_url: 'https://example.com/a.deb'}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_deb_http_key_url_fails_schema(self):
        # the signing key is the trust root: https only
        self._write(
            "- {id: r, description: x, type: deb, "
            "key_url: 'http://example.com/k.gpg', "
            "repo_url: 'https://example.com/apt', suite: stable}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_deb_pin_requires_all_three_fields(self):
        self._write(self._DEB_REPO % ", pin: {package: '*', priority: 1000}")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    # -- ppa: a single <owner>/<name> coordinate, everything else derived -----
    def test_ppa_entry_parses(self):
        self._write("- {id: p, description: x, type: ppa, ppa: inkscape.dev/stable}\n")
        entries = load_catalog(self.dir)
        self.assertEqual(entries["p"].fields["ppa"], "inkscape.dev/stable")

    def test_ppa_without_coordinate_fails_schema(self):
        self._write("- {id: p, description: x, type: ppa}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_ppa_prefix_or_missing_slash_fails_schema(self):
        # the field is the bare <owner>/<name> coordinate — never the ppa: form
        for bad in ("ppa:owner/name", "owner", "owner/name/extra"):
            with self.subTest(ppa=bad):
                self._write(
                    f"- {{id: p, description: x, type: ppa, ppa: '{bad}'}}\n")
                with self.assertRaises(CatalogError):
                    load_catalog(self.dir)

    def test_ppa_with_derived_repo_fields_fails_schema(self):
        # repo_url/key_url/suite/... are derived by the provider; declaring
        # them on a ppa entry is a contradiction the schema rejects
        self._write(
            "- {id: p, description: x, type: ppa, ppa: o/n, "
            "repo_url: 'https://example.com'}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_ppa_with_package_fails_schema(self):
        # one responsibility per entry: the package is a separate apt entry
        self._write("- {id: p, description: x, type: ppa, ppa: o/n, package: x}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    # -- script: the escape hatch needs an explicit probe + install -----------
    def test_script_entry_parses(self):
        self._write(
            "- {id: s, description: x, type: script, "
            "check: 'test -x /usr/local/bin/s', install: 'curl x | sh'}\n"
        )
        entries = load_catalog(self.dir)
        self.assertEqual(entries["s"].fields["check"], "test -x /usr/local/bin/s")
        self.assertNotIn("sudo", entries["s"].fields)  # default: plain user

    def test_script_sudo_declaration_parses(self):
        self._write(
            "- {id: s, description: x, type: script, sudo: true, "
            "check: 'test -x /usr/local/bin/s', install: 'curl x | sh'}\n"
        )
        self.assertIs(load_catalog(self.dir)["s"].fields["sudo"], True)

    def test_script_without_check_fails_schema(self):
        # the idempotency probe is mandatory — no probe, no entry
        self._write("- {id: s, description: x, type: script, install: 'curl x | sh'}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_script_without_install_fails_schema(self):
        self._write("- {id: s, description: x, type: script, check: 'test -x /x'}\n")
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_script_boolean_check_fails_schema(self):
        # YAML `check: true` is a boolean, not a command string — rejected
        # (the string "true" is syntactically valid; review rejects vacuous
        # probes — authoring-guidelines rule 2)
        self._write(
            "- {id: s, description: x, type: script, "
            "check: true, install: 'curl x | sh'}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_script_empty_check_fails_schema(self):
        self._write(
            "- {id: s, description: x, type: script, "
            "check: '', install: 'curl x | sh'}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)

    def test_script_non_boolean_sudo_fails_schema(self):
        self._write(
            "- {id: s, description: x, type: script, sudo: 'yes', "
            "check: 'test -x /x', install: 'curl x | sh'}\n"
        )
        with self.assertRaises(CatalogError):
            load_catalog(self.dir)


if __name__ == "__main__":
    unittest.main()
