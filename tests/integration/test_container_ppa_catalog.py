"""Catalog-wide container tier for the ppa batch: really converge EVERY
PPA chain end-to-end in disposable Docker ``ubuntu:24.04`` guests.

One guest per product (the 4 final-list ``provider_type == "ppa"`` products:
inkscape, obs-studio, yt-dlp, fastfetch — each a ``ppa`` repo entry + an
``apt`` package entry). Per chain the protocol mirrors the deb chain suite
(the ppa provider IS the deb repo machinery behind a translation):

- a ``requires: [desktop]`` product (inkscape, obs-studio) first proves the
  VISIBLE skip on the desktop-less guest, then the desktop marker is planted
  and the real install must behave like on a desktop machine;
- fresh dry-run predicts both changes (repo + package) and mutates nothing
  (no manifest, no sources file);
- the real install converges the whole chain in topological order (asserted
  on the rendered step order), reports ``changed`` for the product and its
  repo entry, and costs EXACTLY one ``apt-get update`` (the freshness guard
  end-to-end — counted from the in-guest audit log; the Launchpad key fetch +
  JSON unwrap + dearmor must all have worked for the update to succeed);
- the landing probe really runs;
- the idempotent re-run is the pure ``check()`` no-op — including the repo
  entry (byte-identical derived ``.sources`` + the fetched-lists probe), with
  NO further ``apt-get update`` and a second all-``ok`` transaction.

Gated like the rest of the tier:

    UBUNTU_SETUP_INTEGRATION=1 python -m unittest \\
        tests.integration.test_container_ppa_catalog -v

Knobs: ``UBUNTU_SETUP_INTEGRATION_PARALLEL`` (default 4),
``UBUNTU_SETUP_INTEGRATION_ENTRIES`` (comma-separated product filter),
``UBUNTU_SETUP_INTEGRATION_TIMEOUT`` (per-exec seconds; inkscape/obs pull
sizable GUI dependency trees). A per-run report lands under the artifacts dir
(``catalog-ppa-<UTC stamp>.log``).
"""

from __future__ import annotations

import json
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
from tests.integration.drivers import DockerDriver, detect_docker, host_run, unique_name
from ubuntu_setup.core.catalog import load_catalog

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

#: inkscape/obs-studio pull sizable GUI dependency trees through one exec
EXEC_TIMEOUT = float(os.environ.get("UBUNTU_SETUP_INTEGRATION_TIMEOUT", "1800"))

#: guests in flight at once (bottleneck: Launchpad/archive bandwidth, not CPU)
PARALLEL = int(os.environ.get("UBUNTU_SETUP_INTEGRATION_PARALLEL", "4"))

#: marker that makes the guest count as a desktop host (environment.py probe 3)
DESKTOP_MARKER_CMD = (
    "mkdir -p /usr/share/xsessions"
    " && touch /usr/share/xsessions/usetup-verify.desktop"
)


@dataclass(frozen=True)
class ChainSpec:
    """One product of the ppa batch: its expected planner order and landing
    proof. Every chain has a repo entry, so every chain costs exactly one
    ``apt-get update``."""

    chain_order: "tuple[str, ...]"
    probe: "tuple[str, ...]"
    repo_id: str


#: product id -> chain spec. Hand-written (like the deb suite's CHAINS) so the
#: expected planner order and every landing proof are reviewable in one place.
#: GUI apps probe file existence (no display in a container).
CHAINS: "dict[str, ChainSpec]" = {
    "inkscape": ChainSpec(
        chain_order=("curl", "gnupg", "inkscape-repo", "inkscape"),
        probe=("test", "-x", "/usr/bin/inkscape"),
        repo_id="inkscape-repo",
    ),
    "obs-studio": ChainSpec(
        chain_order=("curl", "gnupg", "obs-studio-repo", "obs-studio"),
        probe=("test", "-x", "/usr/bin/obs"),
        repo_id="obs-studio-repo",
    ),
    "yt-dlp": ChainSpec(
        chain_order=("curl", "gnupg", "yt-dlp-repo", "yt-dlp"),
        probe=("yt-dlp", "--version"),
        repo_id="yt-dlp-repo",
    ),
    "fastfetch": ChainSpec(
        chain_order=("curl", "gnupg", "fastfetch-repo", "fastfetch"),
        probe=("fastfetch", "--version"),
        repo_id="fastfetch-repo",
    ),
}


def _patient_run(argv: Sequence[str], *, timeout: float = EXEC_TIMEOUT):
    return host_run(argv, timeout=max(timeout, EXEC_TIMEOUT))


def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _selected_products() -> "list[str]":
    products = sorted(CHAINS)
    raw = os.environ.get("UBUNTU_SETUP_INTEGRATION_ENTRIES", "").strip()
    if not raw:
        return products
    wanted = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = sorted(set(wanted) - set(products))
    if unknown:
        raise AssertionError(
            f"UBUNTU_SETUP_INTEGRATION_ENTRIES names unknown ppa products: "
            f"{unknown}"
        )
    return wanted


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestCatalogPpaEntries(unittest.TestCase):
    """The whole provider-ppa batch, end-to-end: one fresh guest per product,
    ``PARALLEL`` guests in flight, the full chain protocol each."""

    image: str
    wheel: Path
    products: "list[str]"

    @classmethod
    def setUpClass(cls) -> None:
        if detect_docker() is None:
            raise unittest.SkipTest(
                "container tier skipped: no responsive Docker daemon on this "
                "host (`docker info` failed) — this suite never installs host "
                "software itself"
            )
        catalog = load_catalog()
        # coverage sync: every ppa-typed entry and every PPA-backed apt
        # package must be covered by exactly one chain here — adding a ppa
        # entry without deciding its chain fails loudly
        ppa_world = {e.id for e in catalog.values() if e.type == "ppa"} | {
            e.id for e in catalog.values()
            if e.type == "apt"
            and any(catalog[dep].type == "ppa" for dep in e.depends_on)
        }
        chain_ids = set()
        for product, spec in CHAINS.items():
            chain_ids.add(product)
            chain_ids.add(spec.repo_id)
        missing = sorted(ppa_world - chain_ids)
        stale = sorted(chain_ids - ppa_world)
        if missing or stale:
            raise AssertionError(
                f"CHAINS out of sync with the catalog ppa batch: "
                f"missing={missing} stale={stale}"
            )
        cls.products = _selected_products()
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))
        cls.image = harness.build_verify_image()

    # -- shared chain assertions -------------------------------------------------
    @staticmethod
    def _step_order(stdout: str, entry_ids: Sequence[str]) -> None:
        positions = []
        for entry_id in entry_ids:
            needle = f"] install {entry_id} ..."
            idx = stdout.find(needle)
            _ensure(idx >= 0, f"step for {entry_id!r} missing from:\n{stdout}")
            positions.append(idx)
        _ensure(positions == sorted(positions),
                f"chain order {entry_ids} violated in:\n{stdout}")

    @staticmethod
    def _count_audit_updates(session: harness.GuestSession) -> int:
        """How many `apt-get update` commands the TOOL has run so far, from the
        in-guest audit log (the runner logs every exact argv) — the freshness
        guard's batch dedupe asserted end-to-end."""
        res = session.exec(["cat", session.profile.audit_log_path],
                           user=session.profile.user, check=True,
                           desc="read audit log")
        return sum(
            1 for line in res.stdout.splitlines()
            if "run: " in line and line.rstrip().endswith("apt-get update")
        )

    def _read_manifest(self, session: harness.GuestSession) -> dict:
        res = session.exec(["cat", session.profile.manifest_path],
                           user=session.profile.user, check=True,
                           desc="read manifest")
        return json.loads(res.stdout)

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

    def _verify_chain(self, session: harness.GuestSession, entry_id: str,
                      spec: ChainSpec, sources_path: str) -> None:
        """fresh dry-run -> real install (order + exactly one update) ->
        idempotent re-run (all ok, no further update)."""
        user = session.profile.user
        py = session.profile.python
        changed_ids = (spec.repo_id, entry_id)

        # -- 1. fresh guest: dry-run predicts, mutates nothing -------------------
        pre = session.exec(list(spec.probe), user=user,
                           desc=f"pre-probe {entry_id}")
        _ensure(not pre.ok,
                f"guest is not fresh: {spec.probe!r} already succeeds")
        dry = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id, "--dry-run"],
            user=user, desc=f"dry-run {entry_id}",
        )
        _ensure(dry.returncode == 0,
                f"dry-run must exit 0: {dry.stderr[-500:]}")
        for predicted in changed_ids:
            _ensure(
                f"{predicted} install: changed — would install "
                f"(absent -> present)" in dry.stdout,
                f"dry-run must predict the {predicted} change; "
                f"stdout:\n{dry.stdout}")
        no_manifest = session.exec(
            ["test", "-e", session.profile.manifest_path],
            user=user, desc="dry-run wrote no manifest?")
        _ensure(not no_manifest.ok, "a dry run must record nothing")
        still_absent = session.exec(["test", "-e", sources_path],
                                    user=user,
                                    desc="dry-run wrote no sources file?")
        _ensure(not still_absent.ok, "a dry run must not configure the repo")

        # -- 2. real install: chain order, outcomes, exactly one update ----------
        inst = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"real install {entry_id}",
        )
        _ensure(inst.returncode == 0,
                f"install must exit 0, got {inst.returncode}: "
                f"{inst.stderr[-800:]}")
        self._step_order(inst.stdout, spec.chain_order)
        for changed in changed_ids:
            _ensure(f"{changed} install: changed" in inst.stdout,
                    f"{changed} must report changed; stdout:\n{inst.stdout}")
        updates = self._count_audit_updates(session)
        _ensure(updates == 1,
                f"the chain must cost exactly 1 apt-get update "
                f"(freshness guard), saw {updates}")
        ran = session.exec(list(spec.probe), user=user,
                           desc=f"post-install {entry_id}")
        _ensure(ran.ok,
                f"{spec.probe!r} must succeed after install "
                f"(exit {ran.returncode})")
        data = self._read_manifest(session)
        _ensure(data["desired"] == [{"id": entry_id, "op": "install"}],
                f"desired must hold the one requested id, got {data['desired']}")
        tx = data["history"][-1]
        _ensure(tx["exit_code"] == 0, f"transaction exit_code must be 0: {tx}")
        recorded = {a["id"]: a["outcome"] for a in tx["actions"]}
        for changed in changed_ids:
            _ensure(recorded.get(changed) == "changed",
                    f"transaction must record {changed} as changed: "
                    f"{tx['actions']}")

        # -- 3. idempotent re-run: pure check() no-ops, no further update ---------
        rerun = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"idempotent re-run {entry_id}",
        )
        _ensure(rerun.returncode == 0,
                f"re-run must exit 0: {rerun.stderr[-500:]}")
        for eid in changed_ids:
            _ensure(f"{eid} install: ok" in rerun.stdout,
                    f"re-run must be the check() no-op for {eid}; "
                    f"stdout:\n{rerun.stdout}")
        _ensure("Unpacking" not in rerun.stdout,
                "re-run must not reinstall (apt output detected)")
        _ensure(self._count_audit_updates(session) == 1,
                "the re-run must not update again (nothing marked the cache)")
        data2 = self._read_manifest(session)
        _ensure(len(data2["history"]) == len(data["history"]) + 1,
                "re-run must append exactly one transaction")
        _ensure(all(a["outcome"] == "ok"
                    for a in data2["history"][-1]["actions"]),
                f"re-run transaction must be all ok: {data2['history'][-1]}")

    # -- per-product worker --------------------------------------------------------
    def _verify_one(self, entry_id: str, *, needs_desktop: bool,
                    sources_path: str) -> float:
        spec = CHAINS[entry_id]
        started = time.monotonic()
        driver = DockerDriver(
            self.image,
            name=unique_name(f"usetup-ppacat-{entry_id}"),
            run=_patient_run,
        )
        profile = harness.GuestProfile(needs_provision=False)  # baked image
        with harness.GuestSession(driver, profile=profile) as session:
            harness.inject_wheel(session, self.wheel)
            if needs_desktop:
                self._assert_desktop_skip(session, entry_id)
                session.exec(["bash", "-c", DESKTOP_MARKER_CMD], check=True,
                             desc="make the guest count as a desktop host")
            self._verify_chain(session, entry_id, spec, sources_path)
        return time.monotonic() - started

    @staticmethod
    def _write_report(lines: "list[str]") -> Path:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = harness.artifacts_dir()
        target.mkdir(parents=True, exist_ok=True)
        report = target / f"catalog-ppa-{stamp}.log"
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return report

    # -- the acceptance test --------------------------------------------------------
    def test_install_every_ppa_chain(self):
        """Every ppa product really converges on a clean 24.04 guest and
        re-runs idempotently; failures are aggregated (the run never stops at
        the first bad chain) and a duration report is kept under artifacts."""
        run_started = time.monotonic()
        outcomes: "dict[str, tuple[str, float]]" = {}
        catalog = load_catalog()
        desktop_ids = {
            e.id for e in catalog.values() if "desktop" in e.requires
        }

        def sources_path_for(spec: ChainSpec) -> str:
            # the ppa provider's file basename is the repo entry id
            return f"/etc/apt/sources.list.d/{spec.repo_id}.sources"

        def work(entry_id: str) -> None:
            t0 = time.monotonic()
            try:
                duration = self._verify_one(
                    entry_id,
                    needs_desktop=entry_id in desktop_ids,
                    sources_path=sources_path_for(CHAINS[entry_id]),
                )
            except Exception as exc:  # noqa: BLE001 — aggregate per chain
                outcomes[entry_id] = (
                    f"FAIL {type(exc).__name__}: {exc}", time.monotonic() - t0,
                )
                print(f"[ppa-verify] FAIL {entry_id} "
                      f"({time.monotonic() - t0:.0f}s): {exc}", flush=True)
            else:
                outcomes[entry_id] = ("ok", duration)
                print(f"[ppa-verify] ok   {entry_id} ({duration:.0f}s)",
                      flush=True)

        with ThreadPoolExecutor(max_workers=max(1, PARALLEL)) as pool:
            for future in [pool.submit(work, p) for p in self.products]:
                future.result()  # work() never raises; .result() surfaces bugs

        total = time.monotonic() - run_started
        lines = [
            f"catalog ppa batch verification — {len(self.products)} chains, "
            f"parallel={PARALLEL}, total {total:.0f}s",
        ]
        for entry_id in self.products:
            status, duration = outcomes[entry_id]
            head = "ok" if status == "ok" else "FAIL"
            detail = "" if status == "ok" else f"  {status}"
            lines.append(f"{head:<5} {entry_id:<28} {duration:7.1f}s{detail}")
        report = self._write_report(lines)
        print(f"[ppa-verify] report: {report}", flush=True)

        failures = [f"{p}: {s}" for p, (s, _) in sorted(outcomes.items())
                    if s != "ok"]
        if failures:
            self.fail(
                f"{len(failures)}/{len(self.products)} chains failed "
                f"(diagnostics under {harness.artifacts_dir()}):\n"
                + "\n".join(failures)
            )


if __name__ == "__main__":
    unittest.main()
