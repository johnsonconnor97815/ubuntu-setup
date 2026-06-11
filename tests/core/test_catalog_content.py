"""Directory-level validation of the SHIPPED catalog content (the apt batch).

The loader already enforces schema validity, unique ids, registered types and
closed ``depends_on`` references — ``load_catalog()`` succeeding IS that test.
This module locks the *content* against the intersection-research final list
(.trellis/tasks/06-10-intersection-research/research/final-list.json) plus the
parent prd's approved additions (06-10-catalog-launch-essentials, 2026-06-10):

- the 63 ``provider_type == "apt"`` entries, with the gcc+make ->
  build-essential merge (net 62);
- the bedrock whitelist (5 approved items; build-essential is one of them,
  python3-venv+pip lands as TWO entries — the apt provider takes one package
  per entry): zip, xz-utils, openssh-server, python3-venv, python3-pip;
- the dependency citations (4): ca-certificates, software-properties-common,
  lsb-release, unzip.

Total: 62 + 4 + 4 = 70 list items = 71 catalog entries (venv+pip split).

id renames vs final-list keys (kept minimal, mapping recorded here):
``gcc``+``make`` -> ``build-essential``, ``p7zip`` -> ``7zip``,
``python`` -> ``python3``.
"""

from __future__ import annotations

import unittest

from ubuntu_setup.core.catalog import load_catalog

#: catalog id -> Ubuntu package (the final-list `ubuntu_apt_package` column,
#: verified per-entry against packages.ubuntu.com during the research task).
EXPECTED_APT_PACKAGES = {
    # bedrock (final-list `curl` + prd-approved additions)
    "curl": "curl",
    "ca-certificates": "ca-certificates",
    "gnupg": "gnupg",
    "lsb-release": "lsb-release",
    "software-properties-common": "software-properties-common",
    "zip": "zip",
    "unzip": "unzip",
    "xz-utils": "xz-utils",
    "openssh-server": "openssh-server",
    # build toolchain
    "build-essential": "build-essential",  # merged gcc+make
    "ninja": "ninja-build",
    "cmake": "cmake",
    "just": "just",
    "maven": "maven",
    # cli utilities
    "bat": "bat",
    "eza": "eza",
    "fd": "fd-find",
    "fzf": "fzf",
    "jq": "jq",
    "7zip": "7zip",  # final-list key: p7zip
    "pandoc": "pandoc",
    "ripgrep": "ripgrep",
    "rsync": "rsync",
    "tree": "tree",
    # containers / virtualization / devops
    "podman": "podman",
    "qemu": "qemu-system",
    "ansible": "ansible",
    # databases
    "postgresql": "postgresql",
    "sqlite": "sqlite3",
    "mariadb": "mariadb-server",
    "mysql": "mysql-server",
    # editors
    "neovim": "neovim",
    "vim": "vim",
    "nano": "nano",
    # gui apps
    "audacity": "audacity",
    "gimp": "gimp",
    "keepassxc": "keepassxc",
    "krita": "krita",
    "libreoffice": "libreoffice",
    "qbittorrent": "qbittorrent",
    "vlc": "vlc",
    # languages / runtimes
    "go": "golang-go",
    "nodejs": "nodejs",
    "openjdk": "default-jdk",
    "php": "php",
    "python3": "python3",  # final-list key: python
    "python3-venv": "python3-venv",
    "python3-pip": "python3-pip",
    "ruby": "ruby-full",
    "dotnet": "dotnet-sdk-8.0",
    "lua": "lua5.4",
    # media / graphics (cli)
    "ffmpeg": "ffmpeg",
    "graphviz": "graphviz",
    "imagemagick": "imagemagick",
    # network tools
    "aria2": "aria2",
    "httpie": "httpie",
    "iperf3": "iperf3",
    "nginx": "nginx",
    "nmap": "nmap",
    "wget": "wget",
    # package managers
    "flatpak": "flatpak",
    "pipx": "pipx",
    "poetry": "python3-poetry",
    # shell / monitoring
    "btop": "btop",
    "htop": "htop",
    "fish": "fish",
    "tmux": "tmux",
    "zsh": "zsh",
    # vcs
    "git": "git",
    "git-lfs": "git-lfs",
    "glab": "glab",
}

#: the final-list `requires: [desktop]` annotations (gui == true entries)
EXPECTED_DESKTOP_IDS = frozenset({
    "audacity", "gimp", "keepassxc", "krita", "libreoffice",
    "qbittorrent", "vlc",
})


class TestShippedCatalogContent(unittest.TestCase):
    """Lock the shipped apt batch to the research final list + prd decisions."""

    @classmethod
    def setUpClass(cls) -> None:
        # load_catalog() raising would itself fail the suite: schema validity,
        # unique ids, registered types and depends_on closure are loader-enforced.
        cls.catalog = load_catalog()

    def test_apt_entry_count_matches_final_list_arithmetic(self):
        apt = [e for e in self.catalog.values() if e.type == "apt"]
        # 63 apt-typed final-list entries - 1 (gcc+make merge) + 5 bedrock
        # (build-essential already counted) - 1 + 4 dependency citations,
        # +1 for the python3-venv/pip split = 71
        self.assertEqual(len(apt), 71)
        self.assertEqual(len(self.catalog), 71)  # this batch ships apt only

    def test_apt_ids_and_packages_match_annotations(self):
        apt = {e.id: e for e in self.catalog.values() if e.type == "apt"}
        self.assertEqual(set(apt), set(EXPECTED_APT_PACKAGES))
        for entry_id, package in EXPECTED_APT_PACKAGES.items():
            self.assertEqual(
                apt[entry_id].fields.get("package"), package,
                f"{entry_id}: package must follow the final-list "
                f"ubuntu_apt_package annotation",
            )

    def test_gui_entries_require_desktop_exactly_as_annotated(self):
        for entry in self.catalog.values():
            expected = ("desktop",) if entry.id in EXPECTED_DESKTOP_IDS else ()
            self.assertEqual(
                entry.requires, expected,
                f"{entry.id}: requires must match the final-list annotation",
            )

    def test_every_entry_is_maintainer_reviewed_official(self):
        # first-release entries are maintainer-authored and reviewed -> official
        # (catalog/authoring-guidelines.md rule 5)
        for entry in self.catalog.values():
            self.assertEqual(entry.source, "official", entry.id)

    def test_every_entry_has_tags_and_description(self):
        for entry in self.catalog.values():
            self.assertTrue(entry.tags, f"{entry.id}: tags must not be empty")
            self.assertTrue(entry.description.strip(), entry.id)

    def test_legacy_entries_survived_the_reorganization(self):
        # the pre-batch cli-tools.yaml shipped ripgrep + tree; they must remain
        # (merged into the new structure, never duplicated — unique ids are
        # loader-enforced, so presence is the only thing left to assert)
        self.assertIn("ripgrep", self.catalog)
        self.assertIn("tree", self.catalog)
        self.assertEqual(self.catalog["ripgrep"].fields["package"], "ripgrep")

    def test_no_depends_on_in_the_pure_apt_batch(self):
        # apt resolves real package dependencies itself; catalog depends_on is
        # for cross-entry ordering (repo -> package), which this batch has none of
        for entry in self.catalog.values():
            self.assertEqual(entry.depends_on, (), entry.id)


if __name__ == "__main__":
    unittest.main()
