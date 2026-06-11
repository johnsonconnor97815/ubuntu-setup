"""Catalog-wide container tier: really install EVERY shipped apt entry.

One disposable Docker ``ubuntu:24.04`` guest per catalog entry, the full
``verify_entry`` protocol each (fresh check -> install -> idempotent re-run;
preinstalled entries run the present-state variant). Gated behind
``UBUNTU_SETUP_INTEGRATION=1`` like the rest of the tier:

    UBUNTU_SETUP_INTEGRATION=1 python -m unittest \\
        tests.integration.test_container_catalog -v

Knobs (in addition to the package-level ones in ``tests/integration``):

- ``UBUNTU_SETUP_INTEGRATION_PARALLEL`` — guests in flight (default 4; the
  bottleneck is archive bandwidth, not CPU).
- ``UBUNTU_SETUP_INTEGRATION_ENTRIES`` — comma-separated id filter, e.g.
  ``libreoffice,qemu`` (re-run failures without the other ~70 guests).
- ``UBUNTU_SETUP_INTEGRATION_TIMEOUT`` — per-exec timeout in seconds
  (default 1800: heavy meta-packages like libreoffice/qemu-system download
  hundreds of MB inside a single ``apt-get install`` exec).

A per-run report (entry, status, duration) is written under the artifacts dir
(``catalog-apt-<UTC stamp>.log``) — the kept record of the full real run.
"""

from __future__ import annotations

import os
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from tests.integration import harness
from tests.integration.drivers import DockerDriver, detect_docker, host_run, unique_name
from ubuntu_setup.core.catalog import load_catalog

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

#: per-exec timeout: one apt-get install of a heavy meta-package must fit
EXEC_TIMEOUT = float(os.environ.get("UBUNTU_SETUP_INTEGRATION_TIMEOUT", "1800"))

#: guests in flight at once
PARALLEL = int(os.environ.get("UBUNTU_SETUP_INTEGRATION_PARALLEL", "4"))

#: entry id -> probe argv proving the install really landed. Explicit for every
#: entry (instead of a default) so each probe is reviewable in one place:
#: - plain `--version` style where the tool supports it;
#: - tool-specific forms where it does not (go/lua/tmux/nginx/...);
#: - `test -x <path>` for GUI apps (no display in a container) and daemons.
PROBES: "dict[str, tuple[str, ...]]" = {
    # bedrock
    "curl": ("curl", "--version"),
    "ca-certificates": ("test", "-x", "/usr/sbin/update-ca-certificates"),
    "gnupg": ("gpg", "--version"),
    "lsb-release": ("lsb_release", "-i"),
    "software-properties-common": ("test", "-x", "/usr/bin/add-apt-repository"),
    "zip": ("zip", "-h"),
    "unzip": ("unzip", "-h"),
    "xz-utils": ("xz", "--version"),
    "openssh-server": ("test", "-x", "/usr/sbin/sshd"),
    # build toolchain
    "build-essential": ("gcc", "--version"),
    "ninja": ("ninja", "--version"),
    "cmake": ("cmake", "--version"),
    "just": ("just", "--version"),
    "maven": ("mvn", "--version"),
    # cli utilities
    "bat": ("batcat", "--version"),
    "eza": ("eza", "--version"),
    "fd": ("fdfind", "--version"),
    "fzf": ("fzf", "--version"),
    "jq": ("jq", "--version"),
    "7zip": ("7z", "i"),  # noble's 7zip package names the binary 7z, not 7zz
    "pandoc": ("pandoc", "--version"),
    "ripgrep": ("rg", "--version"),
    "rsync": ("rsync", "--version"),
    "tree": ("tree", "--version"),
    # containers / virtualization / devops
    "podman": ("podman", "--version"),
    "qemu": ("qemu-system-x86_64", "--version"),
    "ansible": ("ansible", "--version"),
    # databases
    "postgresql": ("psql", "--version"),
    "sqlite": ("sqlite3", "--version"),
    "mariadb": ("mariadb", "--version"),
    "mysql": ("mysql", "--version"),
    # editors
    "neovim": ("nvim", "--version"),
    "vim": ("vim", "--version"),
    "nano": ("nano", "--version"),
    # gui apps (no display in a container -> existence probes)
    "audacity": ("test", "-x", "/usr/bin/audacity"),
    "gimp": ("test", "-x", "/usr/bin/gimp"),
    "keepassxc": ("test", "-x", "/usr/bin/keepassxc"),
    "krita": ("test", "-x", "/usr/bin/krita"),
    "libreoffice": ("test", "-x", "/usr/bin/libreoffice"),
    "qbittorrent": ("test", "-x", "/usr/bin/qbittorrent"),
    "vlc": ("test", "-x", "/usr/bin/vlc"),
    # languages / runtimes
    "go": ("go", "version"),
    "nodejs": ("node", "--version"),
    "openjdk": ("java", "--version"),
    "php": ("php", "--version"),
    "python3": ("python3", "--version"),
    "python3-venv": ("python3", "-m", "venv", "--help"),
    "python3-pip": ("pip3", "--version"),
    "ruby": ("ruby", "--version"),
    "dotnet": ("dotnet", "--version"),
    "lua": ("lua5.4", "-v"),
    # media / graphics (cli)
    "ffmpeg": ("ffmpeg", "-version"),
    "graphviz": ("dot", "-V"),
    "imagemagick": ("convert", "-version"),
    # network tools
    "aria2": ("aria2c", "--version"),
    "httpie": ("http", "--version"),
    "iperf3": ("iperf3", "--version"),
    "nginx": ("nginx", "-v"),
    "nmap": ("nmap", "--version"),
    "wget": ("wget", "--version"),
    # package managers
    "flatpak": ("flatpak", "--version"),
    "pipx": ("pipx", "--version"),
    "poetry": ("poetry", "--version"),
    # shell / monitoring
    "btop": ("btop", "--version"),
    "htop": ("htop", "--version"),
    "fish": ("fish", "--version"),
    "tmux": ("tmux", "-V"),
    "zsh": ("zsh", "--version"),
    # vcs
    "git": ("git", "--version"),
    "git-lfs": ("git-lfs", "--version"),
    "glab": ("glab", "--version"),
}

#: packages baked into the verify-base image (ubuntu:24.04 + the harness
#: scaffolding from docker/verify-base.Dockerfile) — these entries run the
#: present-state protocol: the install IS the check() no-op (outcome `ok`).
PREINSTALLED = frozenset({"ca-certificates", "python3", "python3-venv"})

#: how a guest is made to count as a desktop host (environment.py probe 3:
#: a non-empty /usr/share/xsessions) — for `requires: [desktop]` entries the
#: protocol FIRST asserts the visible skip on the desktop-less guest, then
#: plants this marker and runs the normal install protocol.
DESKTOP_MARKER_CMD = (
    "mkdir -p /usr/share/xsessions"
    " && touch /usr/share/xsessions/usetup-verify.desktop"
)


def _patient_run(argv: Sequence[str], *, timeout: float = EXEC_TIMEOUT):
    """drivers.host_run with a heavy-package-sized timeout (one apt-get install
    of e.g. libreoffice/qemu-system happens inside a single guest exec)."""
    return host_run(argv, timeout=max(timeout, EXEC_TIMEOUT))


def _selected_entries() -> "list[str]":
    """All shipped apt entry ids, optionally filtered by the ENTRIES knob."""
    apt_ids = sorted(e.id for e in load_catalog().values() if e.type == "apt")
    raw = os.environ.get("UBUNTU_SETUP_INTEGRATION_ENTRIES", "").strip()
    if not raw:
        return apt_ids
    wanted = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = sorted(set(wanted) - set(apt_ids))
    if unknown:
        raise AssertionError(
            f"UBUNTU_SETUP_INTEGRATION_ENTRIES names non-apt/unknown ids: {unknown}"
        )
    return wanted


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestCatalogAptEntries(unittest.TestCase):
    """The whole shipped apt batch, end-to-end: one fresh guest per entry,
    ``PARALLEL`` guests in flight, the full verify_entry protocol each."""

    image: str
    wheel: Path
    entries: "list[str]"

    @classmethod
    def setUpClass(cls) -> None:
        if detect_docker() is None:
            raise unittest.SkipTest(
                "container tier skipped: no responsive Docker daemon on this "
                "host (`docker info` failed) — this suite never installs host "
                "software itself"
            )
        cls.entries = _selected_entries()
        # the probe map must cover the apt batch exactly — adding a catalog
        # entry without deciding its landing proof fails loudly here
        all_apt = {e.id for e in load_catalog().values() if e.type == "apt"}
        missing = sorted(all_apt - PROBES.keys())
        stale = sorted(PROBES.keys() - all_apt)
        if missing or stale:
            raise AssertionError(
                f"PROBES out of sync with the catalog: missing={missing} stale={stale}"
            )
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))
        cls.image = harness.build_verify_image()

    # -- helpers ----------------------------------------------------------------
    def _assert_desktop_skip(self, session: "harness.GuestSession",
                             entry_id: str) -> None:
        """On the desktop-less guest a `requires: [desktop]` entry must be a
        VISIBLE skip (exit 0, outcome skipped, reason named) — the requires
        gate asserted end-to-end before we make the guest desktop-capable."""
        profile = session.profile
        res = session.exec(
            [profile.python, "-m", "ubuntu_setup", "--install", entry_id,
             "--dry-run"],
            user=profile.user, desc=f"requires gate: {entry_id} skips headless",
        )
        if res.returncode != 0:
            raise AssertionError(
                f"{entry_id}: desktop-less dry-run must exit 0 (visible skip), "
                f"got {res.returncode}: {res.stderr[-500:]}"
            )
        if (f"{entry_id} install: skipped" not in res.stdout
                or "requires desktop" not in res.stdout):
            raise AssertionError(
                f"{entry_id}: desktop-less dry-run must report the requires "
                f"skip; stdout was:\n{res.stdout}"
            )

    def _verify_one(self, entry_id: str, *, needs_desktop: bool) -> float:
        """Run the protocol for one entry in its own guest; return duration."""
        probe = PROBES[entry_id]
        started = time.monotonic()
        driver = DockerDriver(
            self.image,
            name=unique_name(f"usetup-cat-{entry_id}"),
            run=_patient_run,
        )
        profile = harness.GuestProfile(needs_provision=False)  # baked image
        with harness.GuestSession(driver, profile=profile) as session:
            harness.inject_wheel(session, self.wheel)
            if needs_desktop:
                self._assert_desktop_skip(session, entry_id)
                # plant the desktop signal (probe 3: non-empty xsessions dir)
                # as root, then the entry must install like on a real desktop
                session.exec(["bash", "-c", DESKTOP_MARKER_CMD], check=True,
                             desc="make the guest count as a desktop host")
            harness.verify_entry(
                session, entry_id, probe[0],
                probe=probe,
                expect_preinstalled=entry_id in PREINSTALLED,
            )
        return time.monotonic() - started

    @staticmethod
    def _write_report(lines: "list[str]") -> Path:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = harness.artifacts_dir()
        target.mkdir(parents=True, exist_ok=True)
        report = target / f"catalog-apt-{stamp}.log"
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return report

    # -- the acceptance test ------------------------------------------------------
    def test_install_every_apt_entry(self):
        """Every shipped apt entry really installs on a clean 24.04 guest and
        re-runs idempotently; failures are aggregated (the run never stops at
        the first bad entry) and a duration report is kept under artifacts."""
        run_started = time.monotonic()
        outcomes: "dict[str, tuple[str, float]]" = {}
        desktop_ids = {
            e.id for e in load_catalog().values() if "desktop" in e.requires
        }

        def work(entry_id: str) -> None:
            t0 = time.monotonic()
            try:
                duration = self._verify_one(
                    entry_id, needs_desktop=entry_id in desktop_ids
                )
            except Exception as exc:  # noqa: BLE001 — aggregate per entry
                outcomes[entry_id] = (
                    f"FAIL {type(exc).__name__}: {exc}", time.monotonic() - t0,
                )
                print(f"[catalog-verify] FAIL {entry_id} "
                      f"({time.monotonic() - t0:.0f}s): {exc}", flush=True)
            else:
                outcomes[entry_id] = ("ok", duration)
                print(f"[catalog-verify] ok   {entry_id} ({duration:.0f}s)",
                      flush=True)

        with ThreadPoolExecutor(max_workers=max(1, PARALLEL)) as pool:
            for future in [pool.submit(work, e) for e in self.entries]:
                future.result()  # work() never raises; .result() surfaces bugs

        total = time.monotonic() - run_started
        lines = [
            f"catalog apt batch verification — {len(self.entries)} entries, "
            f"parallel={PARALLEL}, total {total:.0f}s",
        ]
        for entry_id in self.entries:
            status, duration = outcomes[entry_id]
            head = "ok" if status == "ok" else "FAIL"
            detail = "" if status == "ok" else f"  {status}"
            lines.append(f"{head:<5} {entry_id:<28} {duration:7.1f}s{detail}")
        report = self._write_report(lines)
        print(f"[catalog-verify] report: {report}", flush=True)

        failures = [f"{e}: {s}" for e, (s, _) in sorted(outcomes.items())
                    if s != "ok"]
        if failures:
            self.fail(
                f"{len(failures)}/{len(self.entries)} entries failed "
                f"(diagnostics under {harness.artifacts_dir()}):\n"
                + "\n".join(failures)
            )


if __name__ == "__main__":
    unittest.main()
