"""Catalog-wide SYSTEM tier for the snap batch: really install EVERY shipped
snap entry in disposable LXD/Incus ``ubuntu:24.04`` system containers.

snapd needs a running systemd, so this batch cannot use the Docker tier
(research: isolation-tech.md — snap inside plain containers is explicitly
unsupported; first-level LXD containers are the officially supported path).
One guest per entry, the per-entry protocol on top of ``harness.verify_entry``:

- guest provisioning brings the stock cloud image to verify-base level, makes
  sure snapd is present *in the guest* (the LXD ``ubuntu:`` images preinstall
  it; the Incus ``images:`` ones may not — in-guest provisioning is the test
  harness simulating a fresh Ubuntu machine, NOT the product installing snapd:
  the product's snapd-missing path stays PreconditionError and is locked by
  unit tests), and waits for the seed (``snap wait system seed.loaded``, the
  LXD-tier readiness idiom);
- a ``requires: [desktop]`` entry (chromium, telegram, thunderbird, the two
  JetBrains IDEs) first proves the VISIBLE skip on the desktop-less guest,
  then the desktop marker is planted and the install must proceed;
- then the standard protocol: fresh dry-run predicts and mutates nothing ->
  real install (outcome ``changed``, the /snap/bin command landed, transaction
  recorded) -> idempotent re-run (outcome ``ok`` — the ``snap list`` check()
  no-op, never a second install).

Gated like the rest of the tier; additionally skips — explicitly, with the
unlock steps — when neither ``lxc`` nor ``incus`` responds on this host
(**this suite never installs host software itself**):

    UBUNTU_SETUP_INTEGRATION=1 python -m unittest \\
        tests.integration.test_system_snap -v

Knobs: ``UBUNTU_SETUP_INTEGRATION_PARALLEL`` (default 3 — IDE snaps are
1.3-1.7 GB, store bandwidth is the bottleneck),
``UBUNTU_SETUP_INTEGRATION_ENTRIES`` (comma-separated entry filter),
``UBUNTU_SETUP_INTEGRATION_TIMEOUT`` (per-exec seconds, default 3600). A
per-run report lands under the artifacts dir (``catalog-snap-<UTC stamp>.log``).
"""

from __future__ import annotations

import os
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from tests.integration import harness
from tests.integration.drivers import LxdDriver, detect_lxd, host_run, unique_name
from ubuntu_setup.core.catalog import load_catalog

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

UNLOCK_HINT = (
    "system tier skipped: neither LXD (`lxc info`) nor Incus (`incus info`) "
    "responds on this host — this suite never installs host software itself. "
    "Unlock with:\n"
    "  sudo apt install incus\n"
    "  sudo incus admin init --minimal\n"
    "  sudo usermod -aG incus-admin \"$USER\"   # then re-login (or `newgrp incus-admin`)\n"
    "then run:\n"
    "  UBUNTU_SETUP_INTEGRATION=1 python -m unittest "
    "tests.integration.test_system_snap -v"
)

#: image per CLI: lxd ships the `ubuntu:` remote (snapd preinstalled); incus
#: uses `images:` (the /cloud variant has cloud-init -> the `ubuntu` user)
IMAGES = {"lxc": "ubuntu:24.04", "incus": "images:ubuntu/24.04/cloud"}

#: IDE-class snaps are 1.3-1.7 GB through one exec
EXEC_TIMEOUT = float(os.environ.get("UBUNTU_SETUP_INTEGRATION_TIMEOUT", "3600"))

#: guests in flight at once (bottleneck: Snap Store bandwidth, not CPU)
PARALLEL = int(os.environ.get("UBUNTU_SETUP_INTEGRATION_PARALLEL", "3"))

#: marker that makes the guest count as a desktop host (environment.py probe 3)
DESKTOP_MARKER_CMD = (
    "mkdir -p /usr/share/xsessions"
    " && touch /usr/share/xsessions/usetup-verify.desktop"
)


@dataclass(frozen=True)
class SnapSpec:
    """One snap entry: its store name (-> the /snap/bin command set) and the
    landing proof. GUI apps and JVM tools probe the command symlink existence
    (no display / no JDK in the guest); yq really runs."""

    store: str
    probe: "tuple[str, ...]"


#: entry id -> spec. Hand-written (like the deb/ppa suites' CHAINS) so every
#: store name and landing proof are reviewable in one place; the app/command
#: names were verified against the Snap Store 2026-06-11.
SNAPS: "dict[str, SnapSpec]" = {
    "chromium": SnapSpec(
        store="chromium", probe=("test", "-x", "/snap/bin/chromium")),
    "yq": SnapSpec(
        store="yq", probe=("/snap/bin/yq", "--version")),
    "telegram": SnapSpec(
        store="telegram-desktop",
        probe=("test", "-x", "/snap/bin/telegram-desktop")),
    "jetbrains-idea": SnapSpec(
        store="intellij-idea", probe=("test", "-x", "/snap/bin/intellij-idea")),
    "jetbrains-pycharm": SnapSpec(
        store="pycharm", probe=("test", "-x", "/snap/bin/pycharm")),
    "kotlin": SnapSpec(
        store="kotlin", probe=("test", "-x", "/snap/bin/kotlinc")),
    "thunderbird": SnapSpec(
        store="thunderbird", probe=("test", "-x", "/snap/bin/thunderbird")),
}


def _patient_run(argv: Sequence[str], *, timeout: float = EXEC_TIMEOUT):
    return host_run(argv, timeout=max(timeout, EXEC_TIMEOUT))


def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _selected_entries() -> "list[str]":
    entries = sorted(SNAPS)
    raw = os.environ.get("UBUNTU_SETUP_INTEGRATION_ENTRIES", "").strip()
    if not raw:
        return entries
    wanted = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = sorted(set(wanted) - set(entries))
    if unknown:
        raise AssertionError(
            f"UBUNTU_SETUP_INTEGRATION_ENTRIES names unknown snap entries: "
            f"{unknown}"
        )
    return wanted


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestCatalogSnapEntries(unittest.TestCase):
    """The whole provider-snap batch, end-to-end: one fresh system-container
    guest per entry, ``PARALLEL`` guests in flight, the full protocol each."""

    binary: str
    image: str
    wheel: Path
    entries: "list[str]"
    desktop_ids: "frozenset[str]"

    @classmethod
    def setUpClass(cls) -> None:
        binary = detect_lxd()
        if binary is None:
            raise unittest.SkipTest(UNLOCK_HINT)
        cls.binary = binary
        cls.image = IMAGES[binary]
        catalog = load_catalog()
        # coverage sync: every snap-typed entry must be covered here with the
        # store name the catalog/provider will actually install — adding a
        # snap entry without deciding its verification fails loudly
        snap_world = {
            e.id: str(e.fields.get("snap") or e.id)
            for e in catalog.values() if e.type == "snap"
        }
        table = {entry_id: spec.store for entry_id, spec in SNAPS.items()}
        if snap_world != table:
            raise AssertionError(
                f"SNAPS out of sync with the catalog snap batch: "
                f"catalog={snap_world} suite={table}"
            )
        cls.desktop_ids = frozenset(
            e.id for e in catalog.values()
            if e.type == "snap" and "desktop" in e.requires
        )
        cls.entries = _selected_entries()
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))

    # -- in-guest snapd readiness -------------------------------------------------
    @staticmethod
    def _ensure_snapd_seeded(session: harness.GuestSession) -> None:
        """Make the guest a faithful fresh-Ubuntu host for snaps: snapd
        present (preinstalled on the `ubuntu:` images; the `images:` ones may
        lack it) and the seed loaded — the documented readiness gate before
        the first `snap install` in a young system container."""
        session.exec(
            ["apt-get", "install", "-y", "--no-install-recommends", "snapd"],
            check=True, desc="provision: ensure snapd (in-guest only)",
        )
        session.exec(
            ["snap", "wait", "system", "seed.loaded"],
            check=True, desc="provision: wait for the snapd seed",
        )

    def _assert_desktop_skip(self, session: harness.GuestSession,
                             entry_id: str) -> None:
        profile = session.profile
        res = session.exec(
            [profile.python, "-m", "ubuntu_setup", "--install", entry_id,
             "--dry-run"],
            user=profile.user, desc=f"requires gate: {entry_id} skips headless",
        )
        _ensure(res.returncode == 0,
                f"{entry_id}: desktop-less dry-run must exit 0 (visible skip), "
                f"got {res.returncode}: {res.stderr[-500:]}")
        _ensure(f"{entry_id} install: skipped" in res.stdout
                and "requires desktop" in res.stdout,
                f"{entry_id}: desktop-less dry-run must report the requires "
                f"skip; stdout:\n{res.stdout}")

    # -- per-entry worker -----------------------------------------------------------
    def _verify_one(self, entry_id: str) -> float:
        spec = SNAPS[entry_id]
        started = time.monotonic()
        driver = LxdDriver(
            self.image,
            binary=self.binary,
            name=unique_name(f"usetup-snapcat-{entry_id}"),
            run=_patient_run,
        )
        # stock cloud image: harness provisions it in-guest (apt prerequisites
        # + NOPASSWD sudoers), unlike the baked Docker verify-base image
        profile = harness.GuestProfile(needs_provision=True)
        with harness.GuestSession(driver, profile=profile) as session:
            harness.provision(session)
            self._ensure_snapd_seeded(session)
            harness.inject_wheel(session, self.wheel)
            if entry_id in self.desktop_ids:
                self._assert_desktop_skip(session, entry_id)
                session.exec(["bash", "-c", DESKTOP_MARKER_CMD], check=True,
                             desc="make the guest count as a desktop host")
            harness.verify_entry(session, entry_id, spec.store,
                                 probe=spec.probe)
        return time.monotonic() - started

    @staticmethod
    def _write_report(lines: "list[str]") -> Path:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = harness.artifacts_dir()
        target.mkdir(parents=True, exist_ok=True)
        report = target / f"catalog-snap-{stamp}.log"
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return report

    # -- the acceptance test ----------------------------------------------------------
    def test_install_every_snap_entry(self):
        """Every snap entry really converges in a clean 24.04 system container
        and re-runs idempotently; failures are aggregated (the run never stops
        at the first bad entry) and a duration report lands under artifacts."""
        run_started = time.monotonic()
        outcomes: "dict[str, tuple[str, float]]" = {}

        def work(entry_id: str) -> None:
            t0 = time.monotonic()
            try:
                duration = self._verify_one(entry_id)
            except Exception as exc:  # noqa: BLE001 — aggregate per entry
                outcomes[entry_id] = (
                    f"FAIL {type(exc).__name__}: {exc}", time.monotonic() - t0,
                )
                print(f"[snap-verify] FAIL {entry_id} "
                      f"({time.monotonic() - t0:.0f}s): {exc}", flush=True)
            else:
                outcomes[entry_id] = ("ok", duration)
                print(f"[snap-verify] ok   {entry_id} ({duration:.0f}s)",
                      flush=True)

        with ThreadPoolExecutor(max_workers=max(1, PARALLEL)) as pool:
            for future in [pool.submit(work, e) for e in self.entries]:
                future.result()  # work() never raises; .result() surfaces bugs

        total = time.monotonic() - run_started
        lines = [
            f"catalog snap batch verification — {len(self.entries)} entries, "
            f"parallel={PARALLEL}, driver={self.binary}, total {total:.0f}s",
        ]
        for entry_id in self.entries:
            status, duration = outcomes[entry_id]
            head = "ok" if status == "ok" else "FAIL"
            detail = "" if status == "ok" else f"  {status}"
            lines.append(f"{head:<5} {entry_id:<22} {duration:7.1f}s{detail}")
        report = self._write_report(lines)
        print(f"[snap-verify] report: {report}", flush=True)

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
