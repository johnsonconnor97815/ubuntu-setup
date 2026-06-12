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


if __name__ == "__main__":
    unittest.main()
