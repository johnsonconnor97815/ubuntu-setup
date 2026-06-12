"""Catalog-wide container tier for the script batch: really run EVERY shipped
``script`` entry's official installer end-to-end in disposable Docker
``ubuntu:24.04`` guests.

One guest per entry, the full chain protocol each (the script entries carry
``depends_on`` bootstrap edges — curl/unzip/npm/... — so the single-entry
``verify_entry`` protocol does not fit; this mirrors the deb chain suite):

- a ``requires: [desktop]`` entry (zed) first proves the VISIBLE skip on the
  desktop-less guest, then the desktop marker is planted and the real install
  must behave like on a desktop machine;
- fresh guest: the landing probe fails; ``--dry-run`` predicts the change and
  mutates nothing (no manifest, nothing on disk);
- the real install converges the whole chain in topological order (asserted on
  the rendered step order) and reports ``changed`` for the script entry;
- the landing probe really runs (binary executes; existence probe for GUI/
  network-shim cases, reason inline in PROBES);
- **identity proof**: a user-level entry (``sudo`` undeclared) must leave NO
  root-owned files under the user's home — the per-command privilege design
  asserted end-to-end (prd: 用户级条目以非 root 身份安装验证);
- the idempotent re-run is the pure ``check()`` no-op: all ``ok``, a second
  all-ok transaction, ``desired`` never duplicated.

Entries whose *official path* cannot complete in a plain container are listed
in ``VM_TIER`` with the qualitative reason (prd: 定性记录归 VM 档, never a
weakened check) and excluded from this suite's coverage sync.

Gated like the rest of the tier:

    UBUNTU_SETUP_INTEGRATION=1 python -m unittest \\
        tests.integration.test_container_script_catalog -v

Knobs: ``UBUNTU_SETUP_INTEGRATION_PARALLEL`` (default 4),
``UBUNTU_SETUP_INTEGRATION_ENTRIES`` (comma-separated id filter),
``UBUNTU_SETUP_INTEGRATION_TIMEOUT`` (per-exec seconds; the rust toolchain
and the ollama bundle are the heaviest downloads in the catalog). A per-run
report lands under the artifacts dir (``catalog-script-<UTC stamp>.log``).
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

#: one exec holds an entire official installer run (the rust toolchain is
#: hundreds of MB; the ollama bundle is multi-GB)
EXEC_TIMEOUT = float(os.environ.get("UBUNTU_SETUP_INTEGRATION_TIMEOUT", "3600"))

#: guests in flight at once (bottleneck: vendor CDN bandwidth, not CPU)
PARALLEL = int(os.environ.get("UBUNTU_SETUP_INTEGRATION_PARALLEL", "4"))

#: script entries whose official path cannot complete in a plain container —
#: id -> the qualitative reason (kept in sync with the catalog by the
#: coverage check below; these belong to the LXD/VM tier).
VM_TIER: "dict[str, str]" = {}

#: marker that makes the guest count as a desktop host (environment.py probe 3)
DESKTOP_MARKER_CMD = (
    "mkdir -p /usr/share/xsessions"
    " && touch /usr/share/xsessions/usetup-verify.desktop"
)

#: the verify user's home (GuestProfile default) — literal paths in probes so
#: nothing depends on the exec environment's $HOME
HOME = "/home/ubuntu"


@dataclass(frozen=True)
class ScriptSpec:
    """One script entry: its expected planner order and landing proof."""

    chain_order: "tuple[str, ...]"
    probe: "tuple[str, ...]"


#: entry id -> spec. Hand-written (like the apt suite's PROBES / the deb
#: suite's CHAINS) so the expected planner order and every landing proof are
#: reviewable in one place. Existence probes only where running the binary is
#: not meaningful headless (zed: GUI; yarn: the corepack shim downloads a
#: Yarn release on first run — network, not an install property).
SPECS: "dict[str, ScriptSpec]" = {
    # -- user-level (no sudo declaration; lands in $HOME) ------------------------
    "rust": ScriptSpec(
        chain_order=("curl", "rust"),
        probe=(f"{HOME}/.cargo/bin/rustc", "--version"),
    ),
    "uv": ScriptSpec(
        chain_order=("curl", "uv"),
        probe=(f"{HOME}/.local/bin/uv", "--version"),
    ),
    "bun": ScriptSpec(
        chain_order=("curl", "unzip", "bun"),
        probe=(f"{HOME}/.bun/bin/bun", "--version"),
    ),
    "deno": ScriptSpec(
        chain_order=("curl", "unzip", "deno"),
        probe=(f"{HOME}/.deno/bin/deno", "--version"),
    ),
    "pnpm": ScriptSpec(
        chain_order=("curl", "libatomic1", "pnpm"),
        probe=(f"{HOME}/.local/share/pnpm/bin/pnpm", "--version"),
    ),
    "starship": ScriptSpec(
        chain_order=("curl", "starship"),
        probe=(f"{HOME}/.local/bin/starship", "--version"),
    ),
    "zoxide": ScriptSpec(
        chain_order=("curl", "zoxide"),
        probe=(f"{HOME}/.local/bin/zoxide", "--version"),
    ),
    "jupyterlab": ScriptSpec(
        chain_order=("pipx", "jupyterlab"),
        probe=(f"{HOME}/.local/bin/jupyter-lab", "--version"),
    ),
    "zed": ScriptSpec(  # GUI: existence probe (no display in a container)
        chain_order=("curl", "zed"),
        probe=("test", "-x", f"{HOME}/.local/bin/zed"),
    ),
    # -- root-level (sudo: true; lands in /usr/local | /opt | /usr/bin) ----------
    "lazygit": ScriptSpec(
        chain_order=("curl", "lazygit"),
        probe=("/usr/local/bin/lazygit", "--version"),
    ),
    "gradle": ScriptSpec(
        chain_order=("curl", "unzip", "openjdk", "gradle"),
        probe=("/usr/local/bin/gradle", "--version"),
    ),
    "rclone": ScriptSpec(
        chain_order=("curl", "unzip", "rclone"),
        probe=("/usr/bin/rclone", "--version"),
    ),
    "typescript": ScriptSpec(
        chain_order=("nodejs", "npm", "typescript"),
        probe=("/usr/local/bin/tsc", "--version"),
    ),
    "yarn": ScriptSpec(  # the shim downloads Yarn on first run: existence probe
        chain_order=("nodejs", "npm", "yarn"),
        probe=("test", "-x", "/usr/local/bin/yarn"),
    ),
    "ollama": ScriptSpec(
        chain_order=("curl", "zstd", "ollama"),
        probe=("/usr/local/bin/ollama", "--version"),
    ),
}


def _patient_run(argv: Sequence[str], *, timeout: float = EXEC_TIMEOUT):
    return host_run(argv, timeout=max(timeout, EXEC_TIMEOUT))


def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _selected_entries() -> "list[str]":
    entries = sorted(SPECS)
    raw = os.environ.get("UBUNTU_SETUP_INTEGRATION_ENTRIES", "").strip()
    if not raw:
        return entries
    wanted = [item.strip() for item in raw.split(",") if item.strip()]
    unknown = sorted(set(wanted) - set(entries))
    if unknown:
        raise AssertionError(
            f"UBUNTU_SETUP_INTEGRATION_ENTRIES names unknown script entries: "
            f"{unknown}"
        )
    return wanted


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestCatalogScriptEntries(unittest.TestCase):
    """The whole script batch, end-to-end: one fresh guest per entry,
    ``PARALLEL`` guests in flight, the full chain protocol each."""

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
        catalog = load_catalog()
        # coverage sync: every script-typed entry is covered here or carries a
        # recorded VM-tier reason — adding a script entry without deciding its
        # verification fails loudly, and so does a stale spec
        script_ids = {e.id for e in catalog.values() if e.type == "script"}
        covered = set(SPECS) | set(VM_TIER)
        missing = sorted(script_ids - covered)
        stale = sorted(covered - script_ids)
        overlap = sorted(set(SPECS) & set(VM_TIER))
        if missing or stale or overlap:
            raise AssertionError(
                f"SPECS/VM_TIER out of sync with the catalog script batch: "
                f"missing={missing} stale={stale} vm-overlap={overlap}"
            )
        cls.entries = _selected_entries()
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))
        cls.image = harness.build_verify_image()

    # -- shared assertions --------------------------------------------------------
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

    def _assert_no_root_residue_in_home(self, session: harness.GuestSession,
                                        entry_id: str) -> None:
        """A user-level (no-sudo) script entry must never leave root-owned
        files in the user's home — the per-command privilege model proven on
        the real artifact tree (privilege Rule 1's failure mode)."""
        res = session.exec(["find", HOME, "-user", "root"],
                           desc=f"{entry_id}: no root-owned files in $HOME")
        _ensure(res.ok and res.stdout.strip() == "",
                f"{entry_id}: user-level install left root-owned paths in "
                f"{HOME}:\n{res.stdout}")

    def _verify_chain(self, session: harness.GuestSession, entry_id: str,
                      spec: ScriptSpec, *, user_level: bool) -> None:
        """fresh dry-run -> real install (order + outcomes + identity) ->
        idempotent re-run (all ok)."""
        user = session.profile.user
        py = session.profile.python

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
        _ensure(f"{entry_id} install: changed — would install "
                f"(absent -> present)" in dry.stdout,
                f"dry-run must predict the {entry_id} change; "
                f"stdout:\n{dry.stdout}")
        no_manifest = session.exec(
            ["test", "-e", session.profile.manifest_path],
            user=user, desc="dry-run wrote no manifest?")
        _ensure(not no_manifest.ok, "a dry run must record nothing")
        still_absent = session.exec(list(spec.probe), user=user,
                                    desc="dry-run installed nothing?")
        _ensure(not still_absent.ok, "a dry run must not install anything")

        # -- 2. real install: chain order, outcome, landing, identity ------------
        inst = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"real install {entry_id}",
        )
        _ensure(inst.returncode == 0,
                f"install must exit 0, got {inst.returncode}: "
                f"{inst.stderr[-800:]}")
        self._step_order(inst.stdout, spec.chain_order)
        _ensure(f"{entry_id} install: changed" in inst.stdout,
                f"{entry_id} must report changed; stdout:\n{inst.stdout}")
        ran = session.exec(list(spec.probe), user=user,
                           desc=f"post-install {entry_id}")
        _ensure(ran.ok,
                f"{spec.probe!r} must succeed after install "
                f"(exit {ran.returncode})")
        if user_level:
            self._assert_no_root_residue_in_home(session, entry_id)
        data = self._read_manifest(session)
        _ensure(data["desired"] == [{"id": entry_id, "op": "install"}],
                f"desired must hold the one requested id, got {data['desired']}")
        tx = data["history"][-1]
        _ensure(tx["exit_code"] == 0, f"transaction exit_code must be 0: {tx}")
        recorded = {a["id"]: a["outcome"] for a in tx["actions"]}
        _ensure(recorded.get(entry_id) == "changed",
                f"transaction must record {entry_id} as changed: "
                f"{tx['actions']}")

        # -- 3. idempotent re-run: pure check() no-ops ----------------------------
        rerun = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"idempotent re-run {entry_id}",
        )
        _ensure(rerun.returncode == 0,
                f"re-run must exit 0: {rerun.stderr[-500:]}")
        _ensure(f"{entry_id} install: ok" in rerun.stdout
                and "already present" in rerun.stdout,
                f"re-run must be the check() no-op for {entry_id}; "
                f"stdout:\n{rerun.stdout}")
        data2 = self._read_manifest(session)
        _ensure(len(data2["history"]) == len(data["history"]) + 1,
                "re-run must append exactly one transaction")
        _ensure(all(a["outcome"] == "ok"
                    for a in data2["history"][-1]["actions"]),
                f"re-run transaction must be all ok: {data2['history'][-1]}")
        _ensure(data2["desired"] == [{"id": entry_id, "op": "install"}],
                "desired must be upserted, never duplicated")

    # -- per-entry worker -----------------------------------------------------------
    def _verify_one(self, entry_id: str, *, needs_desktop: bool,
                    user_level: bool) -> float:
        spec = SPECS[entry_id]
        started = time.monotonic()
        driver = DockerDriver(
            self.image,
            name=unique_name(f"usetup-scriptcat-{entry_id}"),
            run=_patient_run,
        )
        profile = harness.GuestProfile(needs_provision=False)  # baked image
        with harness.GuestSession(driver, profile=profile) as session:
            harness.inject_wheel(session, self.wheel)
            if needs_desktop:
                self._assert_desktop_skip(session, entry_id)
                session.exec(["bash", "-c", DESKTOP_MARKER_CMD], check=True,
                             desc="make the guest count as a desktop host")
            self._verify_chain(session, entry_id, spec, user_level=user_level)
        return time.monotonic() - started

    @staticmethod
    def _write_report(lines: "list[str]") -> Path:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        target = harness.artifacts_dir()
        target.mkdir(parents=True, exist_ok=True)
        report = target / f"catalog-script-{stamp}.log"
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return report

    # -- the acceptance test ----------------------------------------------------------
    def test_install_every_script_entry(self):
        """Every shipped script entry really converges on a clean 24.04 guest
        and re-runs idempotently; failures are aggregated (the run never stops
        at the first bad entry) and a duration report is kept under artifacts."""
        run_started = time.monotonic()
        outcomes: "dict[str, tuple[str, float]]" = {}
        catalog = load_catalog()
        desktop_ids = {
            e.id for e in catalog.values() if "desktop" in e.requires
        }
        user_level_ids = {
            e.id for e in catalog.values()
            if e.type == "script" and not e.fields.get("sudo", False)
        }

        def work(entry_id: str) -> None:
            t0 = time.monotonic()
            try:
                duration = self._verify_one(
                    entry_id,
                    needs_desktop=entry_id in desktop_ids,
                    user_level=entry_id in user_level_ids,
                )
            except Exception as exc:  # noqa: BLE001 — aggregate per entry
                outcomes[entry_id] = (
                    f"FAIL {type(exc).__name__}: {exc}", time.monotonic() - t0,
                )
                print(f"[script-verify] FAIL {entry_id} "
                      f"({time.monotonic() - t0:.0f}s): {exc}", flush=True)
            else:
                outcomes[entry_id] = ("ok", duration)
                print(f"[script-verify] ok   {entry_id} ({duration:.0f}s)",
                      flush=True)

        with ThreadPoolExecutor(max_workers=max(1, PARALLEL)) as pool:
            for future in [pool.submit(work, e) for e in self.entries]:
                future.result()  # work() never raises; .result() surfaces bugs

        total = time.monotonic() - run_started
        lines = [
            f"catalog script batch verification — {len(self.entries)} entries, "
            f"parallel={PARALLEL}, total {total:.0f}s",
        ]
        for entry_id in self.entries:
            status, duration = outcomes[entry_id]
            head = "ok" if status == "ok" else "FAIL"
            detail = "" if status == "ok" else f"  {status}"
            lines.append(f"{head:<5} {entry_id:<28} {duration:7.1f}s{detail}")
        report = self._write_report(lines)
        print(f"[script-verify] report: {report}", flush=True)

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
