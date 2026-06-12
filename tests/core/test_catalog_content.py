"""Directory-level validation of the SHIPPED catalog content.

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

Pure-apt total: 62 + 4 + 4 = 70 list items = 71 catalog entries (venv+pip split).

The deb batch covers all 21 ``provider_type == "deb"`` final-list entries:

- the pilot (06-11-provider-deb) landed the docker + vscode chains — the
  final-list keys docker, docker-compose AND vscode (3 of 21): two ``deb``
  repo entries (docker-repo, vscode-repo) and four third-party-repo ``apt``
  package entries (docker, docker-buildx, docker-compose, vscode);
- entries-deb (06-11) lands the remaining 18 products: 12 repo-mode chains
  (firefox incl. the official pin-1000, brave, edge, signal, spotify, mongodb
  with the mid-path {codename} suite, redis, vscodium, sublime-text flat,
  kubectl flat `/`, terraform, gh) = 12 ``deb`` repo + 12 ``apt`` package
  entries, plus 6 direct-mode ``deb`` entries (chrome, vivaldi, discord, zoom,
  obsidian, steam). final-list's mariadb/mysql/nginx are provider_type=apt
  (already in the apt batch — re-checked, not duplicated here).

The script batch (06-11-provider-script) covers the 14 ``provider_type ==
"script"`` final-list entries plus yarn (the parent prd's corepack decision):
rust, uv, bun, deno, pnpm, starship, zoxide, lazygit, ollama, gradle, rclone,
jupyterlab, typescript, zed, yarn = 15 ``script`` entries, plus 3
dependency-citation apt entries their official installers hard-require:
``npm`` (typescript/yarn; Ubuntu's nodejs ships without npm), ``zstd``
(ollama's .tar.zst bundles), ``libatomic1`` (pnpm v11's standalone binary).

The ppa batch (06-11-provider-ppa) covers all 4 ``provider_type == "ppa"``
final-list entries — inkscape, obs-studio, yt-dlp, fastfetch — as repo+package
chains: 4 ``ppa`` repo entries (+ 4 ``apt`` package entries that depend on
them). Every chain depends on curl+gnupg (the provider downloads the key from
the Launchpad API and dearmors it — Launchpad keys are always armored).

Totals: 71 + 4 + 12 + 3 + 4 = 94 apt, 14 repo-deb + 6 direct-deb = 20 deb,
4 ppa, 15 script, 133 entries.

id renames vs final-list keys (kept minimal, mapping recorded here):
``gcc``+``make`` -> ``build-essential``, ``p7zip`` -> ``7zip``,
``python`` -> ``python3``.
"""

from __future__ import annotations

import unittest

from ubuntu_setup.core.catalog import load_catalog

#: catalog id -> Ubuntu package (the final-list `ubuntu_apt_package` column,
#: verified per-entry against packages.ubuntu.com during the research task;
#: third-party-repo packages follow the vendor's official package name).
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
    # dependency citations of the script batch (06-11-provider-script)
    "zstd": "zstd",
    "libatomic1": "libatomic1",
    "npm": "npm",
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
    # third-party-repo apt packages: deb pilot (docker + vscode chains)
    "docker": "docker-ce",
    "docker-buildx": "docker-buildx-plugin",
    "docker-compose": "docker-compose-plugin",
    "vscode": "code",
    # third-party-repo apt packages: entries-deb batch (repo-mode chains)
    "firefox": "firefox",
    "brave": "brave-browser",
    "edge": "microsoft-edge-stable",
    "signal": "signal-desktop",
    "spotify": "spotify-client",
    "mongodb": "mongodb-org",
    "redis": "redis",
    "vscodium": "codium",
    "sublime-text": "sublime-text",
    "kubectl": "kubectl",
    "terraform": "terraform",
    "gh": "gh",
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
    # PPA-backed apt packages (provider-ppa batch)
    "inkscape": "inkscape",
    "obs-studio": "obs-studio",
    "yt-dlp": "yt-dlp",
    "fastfetch": "fastfetch",
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

#: the final-list `requires: [desktop]` annotations (gui == true entries);
#: repo entries a GUI package depends on carry no requires of their own —
#: the dependent does; a DIRECT-mode deb entry IS the package, so it carries
#: requires itself (authoring-guidelines)
EXPECTED_DESKTOP_IDS = frozenset({
    # apt batch
    "audacity", "gimp", "keepassxc", "krita", "libreoffice",
    "qbittorrent", "vlc",
    # deb pilot
    "vscode",
    # entries-deb: repo-mode GUI packages
    "firefox", "brave", "edge", "signal", "spotify", "vscodium",
    "sublime-text",
    # entries-deb: direct-mode GUI entries
    "chrome", "vivaldi", "discord", "zoom", "obsidian", "steam",
    # script batch (final-list gui == true)
    "zed",
    # ppa batch: PPA-backed GUI packages (the repo entries carry no requires)
    "inkscape", "obs-studio",
})

#: the shipped deb REPO-mode entries (third-party APT repositories)
EXPECTED_DEB_REPO_IDS = frozenset({
    # pilot
    "docker-repo", "vscode-repo",
    # entries-deb batch
    "firefox-repo", "brave-repo", "edge-repo", "signal-repo", "spotify-repo",
    "mongodb-repo", "redis-repo", "vscodium-repo", "sublime-text-repo",
    "kubectl-repo", "terraform-repo", "gh-repo",
})

#: the shipped ppa entries: id -> the Launchpad <owner>/<name> coordinate
#: (the official PPA each upstream install doc cites — see the sourcing
#: comments in the catalog files)
EXPECTED_PPA_COORDINATES = {
    "inkscape-repo": "inkscape.dev/stable",
    "obs-studio-repo": "obsproject/obs-studio",
    "yt-dlp-repo": "tomtomtom/yt-dlp",
    "fastfetch-repo": "zhangsongcui3371/fastfetch",
}

#: the shipped deb DIRECT-mode entries: id -> the binary package the vendor
#: .deb provides (the dpkg idempotency probe)
EXPECTED_DEB_DIRECT_PACKAGES = {
    "chrome": "google-chrome-stable",
    "vivaldi": "vivaldi-stable",
    "discord": "discord",
    "zoom": "zoom",
    "obsidian": "obsidian",
    "steam": "steam-launcher",
}

#: the shipped script entries: id -> the locked privilege declaration.
#: sudo: True == the official installer writes root-owned paths (/usr/local,
#: /opt, /usr/bin, npm -g's /usr/local prefix); everything else is a
#: user-level install into $HOME and must NEVER escalate (prd
#: 06-11-provider-script: default is the plain user).
EXPECTED_SCRIPT_SUDO = {
    "rust": False,        # ~/.rustup + ~/.cargo
    "uv": False,          # ~/.local/bin
    "bun": False,         # ~/.bun
    "deno": False,        # ~/.deno
    "pnpm": False,        # ~/.local/share/pnpm
    "starship": False,    # ~/.local/bin (installer --bin-dir)
    "zoxide": False,      # ~/.local/bin
    "jupyterlab": False,  # pipx -> ~/.local
    "zed": False,         # ~/.local/zed.app + ~/.local/bin
    "lazygit": True,      # /usr/local/bin
    "gradle": True,       # /opt/gradle + /usr/local/bin
    "rclone": True,       # /usr/bin
    "typescript": True,   # npm -g -> /usr/local
    "yarn": True,         # corepack shims -> /usr/local/bin
    "ollama": True,       # /usr/local/{bin,lib} (+ systemd unit where present)
}

#: the full cross-entry ordering graph: every shipped depends_on edge. apt
#: resolves real package dependencies itself — depends_on exists only for the
#: repo->package chains and the bootstrap-tool prerequisites (curl downloads
#: every key/.deb; gnupg dearmors armored keys — binary-keyring repos
#: (brave, gh) need no gnupg).
EXPECTED_DEPENDS_ON = {
    # pilot chains
    "docker-repo": ("ca-certificates", "curl", "gnupg"),
    # docker's official install is five packages; cli+containerd.io arrive via
    # dpkg-level Depends of docker-ce, the two plugins via depends_on so that
    # `--install docker` converges the official set (decision 06-11-provider-deb)
    "docker": ("docker-repo", "docker-buildx", "docker-compose"),
    "docker-buildx": ("docker-repo",),
    "docker-compose": ("docker-repo",),
    "vscode-repo": ("curl", "gnupg"),
    "vscode": ("vscode-repo",),
    # entries-deb: repo-mode chains
    "firefox-repo": ("curl", "gnupg"),
    "firefox": ("firefox-repo",),
    "brave-repo": ("curl",),  # binary keyring — no dearmor
    "brave": ("brave-repo",),
    "edge-repo": ("curl", "gnupg"),
    "edge": ("edge-repo",),
    "signal-repo": ("curl", "gnupg"),
    "signal": ("signal-repo",),
    "spotify-repo": ("curl", "gnupg"),
    "spotify": ("spotify-repo",),
    "mongodb-repo": ("curl", "gnupg"),
    "mongodb": ("mongodb-repo",),
    "redis-repo": ("curl", "gnupg"),
    "redis": ("redis-repo",),
    "vscodium-repo": ("curl", "gnupg"),
    "vscodium": ("vscodium-repo",),
    "sublime-text-repo": ("curl", "gnupg"),
    "sublime-text": ("sublime-text-repo",),
    "kubectl-repo": ("ca-certificates", "curl", "gnupg"),  # official doc's list
    "kubectl": ("kubectl-repo",),
    "terraform-repo": ("curl", "gnupg"),
    "terraform": ("terraform-repo",),
    "gh-repo": ("curl",),  # binary keyring — no dearmor
    "gh": ("gh-repo",),
    # entries-deb: direct-mode entries (curl downloads the .deb)
    "chrome": ("curl",),
    "vivaldi": ("curl",),
    "discord": ("curl",),
    "zoom": ("curl",),
    "obsidian": ("curl",),
    "steam": ("curl",),
    # script batch: bootstrap-tool edges the official installers hard-require
    # (curl downloads; unzip/zstd/libatomic1 per installer; npm/nodejs for the
    # npm-route entries; openjdk is gradle's documented JDK 17+ prerequisite;
    # pipx is jupyterlab's PEP 668 application path)
    "rust": ("curl",),
    "uv": ("curl",),
    "bun": ("curl", "unzip"),
    "deno": ("curl", "unzip"),
    "pnpm": ("curl", "libatomic1"),
    "starship": ("curl",),
    "zoxide": ("curl",),
    "lazygit": ("curl",),
    "gradle": ("curl", "unzip", "openjdk"),
    "rclone": ("curl", "unzip"),
    "jupyterlab": ("pipx",),
    "typescript": ("nodejs", "npm"),
    "yarn": ("nodejs", "npm"),
    "zed": ("curl",),
    "ollama": ("curl", "zstd"),
    # ppa batch: repo->package chains; every PPA key is downloaded (curl) from
    # the Launchpad API and dearmored (gnupg — Launchpad keys are armored)
    "inkscape-repo": ("curl", "gnupg"),
    "inkscape": ("inkscape-repo",),
    "obs-studio-repo": ("curl", "gnupg"),
    "obs-studio": ("obs-studio-repo",),
    "yt-dlp-repo": ("curl", "gnupg"),
    "yt-dlp": ("yt-dlp-repo",),
    "fastfetch-repo": ("curl", "gnupg"),
    "fastfetch": ("fastfetch-repo",),
}


class TestShippedCatalogContent(unittest.TestCase):
    """Lock the shipped catalog to the research final list + prd decisions."""

    @classmethod
    def setUpClass(cls) -> None:
        # load_catalog() raising would itself fail the suite: schema validity,
        # unique ids, registered types and depends_on closure are loader-enforced.
        cls.catalog = load_catalog()

    def test_entry_counts_match_final_list_arithmetic(self):
        apt = [e for e in self.catalog.values() if e.type == "apt"]
        # 63 apt-typed final-list entries - 1 (gcc+make merge) + 5 bedrock
        # (build-essential already counted) - 1 + 4 dependency citations,
        # +1 for the python3-venv/pip split = 71 pure-apt entries; the deb
        # batches add 16 third-party-repo apt packages (4 pilot + 12
        # entries-deb) = 87; the script batch adds 3 dependency citations
        # (npm, zstd, libatomic1) = 90; the ppa batch adds 4 PPA-backed apt
        # packages (inkscape, obs-studio, yt-dlp, fastfetch) = 94; plus 14
        # deb repo + 6 deb direct entries, 4 ppa repo entries and 15 script
        # entries = 133 total — all 21 final-list deb products (18
        # entries-deb + docker/docker-compose/vscode pilot), all 14
        # final-list script products + yarn, and all 4 final-list ppa
        # products covered.
        self.assertEqual(len(apt), 94)
        deb = {e.id for e in self.catalog.values() if e.type == "deb"}
        self.assertEqual(
            deb, EXPECTED_DEB_REPO_IDS | set(EXPECTED_DEB_DIRECT_PACKAGES))
        ppa = {e.id for e in self.catalog.values() if e.type == "ppa"}
        self.assertEqual(ppa, set(EXPECTED_PPA_COORDINATES))
        script = {e.id for e in self.catalog.values() if e.type == "script"}
        self.assertEqual(script, set(EXPECTED_SCRIPT_SUDO))
        self.assertEqual(len(self.catalog), 133)

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

    def test_depends_on_edges_match_the_recorded_graph(self):
        # apt resolves real package dependencies itself; catalog depends_on is
        # ONLY the cross-entry ordering of the repo->package chains (plus the
        # bootstrap-tool prerequisites) — locked edge-for-edge
        for entry in self.catalog.values():
            self.assertEqual(
                entry.depends_on, EXPECTED_DEPENDS_ON.get(entry.id, ()),
                f"{entry.id}: depends_on must match the recorded graph",
            )

    def test_deb_repo_entries_follow_the_field_contract(self):
        # repo mode: key from https, deb822 source fields present, a clean
        # file basename, and never a `package` (that belongs to the dependent)
        for entry_id in EXPECTED_DEB_REPO_IDS:
            fields = self.catalog[entry_id].fields
            self.assertTrue(fields["key_url"].startswith("https://"), entry_id)
            self.assertIn("repo_url", fields, entry_id)
            self.assertIn("suite", fields, entry_id)
            self.assertIn("name", fields, entry_id)
            self.assertNotIn("package", fields, entry_id)
            self.assertNotIn("deb_url", fields, entry_id)

    def test_deb_repo_entries_never_carry_requires(self):
        # the GUI dependent carries requires; the repo entry stays applicable
        # everywhere (authoring-guidelines)
        for entry_id in EXPECTED_DEB_REPO_IDS:
            self.assertEqual(self.catalog[entry_id].requires, (), entry_id)

    def test_deb_direct_entries_follow_the_field_contract(self):
        # direct mode: https deb_url + the dpkg probe package, and never any
        # repo-mode field (schema-enforced too; locked here content-wise)
        for entry_id, package in EXPECTED_DEB_DIRECT_PACKAGES.items():
            fields = self.catalog[entry_id].fields
            self.assertTrue(fields["deb_url"].startswith("https://"), entry_id)
            self.assertEqual(fields.get("package"), package, entry_id)
            for repo_field in ("repo_url", "key_url", "suite", "components",
                               "architectures", "pin"):
                self.assertNotIn(repo_field, fields, entry_id)

    def test_flat_repos_omit_components(self):
        # the two flat repos of the batch (kubectl `Suites: /`, sublime
        # `Suites: apt/stable/`) must not declare Components — the provider
        # omits the deb822 line entirely for flat layouts
        for entry_id in ("kubectl-repo", "sublime-text-repo"):
            self.assertNotIn("components", self.catalog[entry_id].fields,
                             entry_id)
        self.assertEqual(self.catalog["kubectl-repo"].fields["suite"], "/")
        self.assertTrue(
            self.catalog["sublime-text-repo"].fields["suite"].endswith("/"))

    # -- ppa batch ---------------------------------------------------------------
    def test_ppa_entries_follow_the_field_contract(self):
        # a ppa entry is ONLY its <owner>/<name> coordinate: every repo field
        # (URL, key, suite, basename) is derived by the provider — locked here
        # so nobody hand-writes a divergent copy of the derivation
        for entry_id, coordinate in EXPECTED_PPA_COORDINATES.items():
            fields = self.catalog[entry_id].fields
            self.assertEqual(fields, {"ppa": coordinate}, entry_id)

    def test_ppa_repo_entries_never_carry_requires(self):
        # same rule as deb repos: the GUI dependent (inkscape, obs-studio)
        # carries requires; the repo entry stays applicable everywhere
        for entry_id in EXPECTED_PPA_COORDINATES:
            self.assertEqual(self.catalog[entry_id].requires, (), entry_id)

    def test_firefox_repo_carries_the_official_pin(self):
        # the Firefox official-doc pin: priority 1000 on origin
        # packages.mozilla.org, or Ubuntu's snap-transition stub wins
        pin = self.catalog["firefox-repo"].fields["pin"]
        self.assertEqual(pin["priority"], 1000)
        self.assertEqual(pin["pin"], "origin packages.mozilla.org")
        self.assertEqual(pin["package"], "*")

    # -- script batch ----------------------------------------------------------
    def test_script_privilege_declarations_match_the_locked_table(self):
        # the review-locked sudo split: user-level entries must NEVER carry
        # sudo (prd: default is the plain user), root-level ones must declare it
        for entry_id, expected_sudo in EXPECTED_SCRIPT_SUDO.items():
            fields = self.catalog[entry_id].fields
            self.assertIs(bool(fields.get("sudo", False)), expected_sudo,
                          f"{entry_id}: sudo declaration must match the "
                          f"reviewed privilege table")

    def test_script_checks_are_real_probes(self):
        # authoring-guidelines rule 2: a vacuous probe defeats idempotency.
        # Every shipped probe is an absolute-path existence test (never
        # login-shell PATH); lock the shape so a `check: "true"` can't sneak in.
        for entry_id in EXPECTED_SCRIPT_SUDO:
            check = self.catalog[entry_id].fields["check"]
            self.assertNotIn(check.strip(), {"true", ":", "test 1"}, entry_id)
            self.assertTrue(check.startswith("test -x "),
                            f"{entry_id}: shipped script probes are absolute-"
                            f"path executable tests, got {check!r}")
            probed = check.split()[-1].strip('"')
            self.assertTrue(
                probed.startswith(("/", "$HOME/")),
                f"{entry_id}: probe path must be absolute (or $HOME-anchored "
                f"— the provider pins HOME from the passwd DB), got {probed!r}",
            )

    def test_user_level_script_probes_stay_in_home(self):
        # a user-level entry probing a root path (or vice versa) means the
        # identity declaration and the artifact location disagree
        for entry_id, is_sudo in EXPECTED_SCRIPT_SUDO.items():
            check = self.catalog[entry_id].fields["check"]
            if is_sudo:
                self.assertNotIn("$HOME", check,
                                 f"{entry_id}: root-level probes must not use "
                                 f"$HOME (privilege Rule 3)")
            else:
                self.assertIn("$HOME", check,
                              f"{entry_id}: user-level installs land in $HOME")

    def test_script_installs_carry_no_inline_sudo(self):
        # escalation is the entry-level `sudo: true` declaration, executed
        # per-command by the engine — never an inline sudo inside the command
        for entry_id in EXPECTED_SCRIPT_SUDO:
            install = self.catalog[entry_id].fields["install"]
            self.assertNotIn("sudo", install, entry_id)

    def test_script_remove_upgrade_fields_are_not_shipped(self):
        # reserved fields; the ops are deferred (prd out-of-scope) — shipping
        # a command nothing can execute would be dead, unreviewable data
        for entry_id in EXPECTED_SCRIPT_SUDO:
            fields = self.catalog[entry_id].fields
            self.assertNotIn("remove", fields, entry_id)
            self.assertNotIn("upgrade", fields, entry_id)


if __name__ == "__main__":
    unittest.main()
