"""Container tier, deb pilot: the docker + vscode repo->package chains, really
installed end-to-end in disposable Docker ``ubuntu:24.04`` guests.

What each chain proves (the provider-deb prd's acceptance):

- the planner's dependency expansion schedules the ``deb`` repo entry (and the
  bootstrap tools it depends on) BEFORE the third-party-repo ``apt`` package —
  asserted on the rendered step order;
- the freshness guard runs ``apt-get update`` exactly ONCE per run for the
  whole batch (asserted by counting runner audit-log lines in the guest);
- a dry run predicts the change and mutates nothing;
- the idempotent re-run is the pure ``check()`` no-op — including the repo
  entry itself (files match + the fetched-lists probe passes), with NO second
  ``apt-get update``;
- the transaction history records every chain step with its outcome.

The vscode chain additionally exercises the ``requires: [desktop]`` gate
end-to-end first (visible skip on the desktop-less guest), then plants the
desktop marker and installs for real. Service-start interference from
docker-ce/containerd postinst is neutralized by the verify-base image's
``/usr/sbin/policy-rc.d`` (exit 101 — see ``docker/verify-base.Dockerfile``).

Gated like the rest of the tier:

    UBUNTU_SETUP_INTEGRATION=1 python -m unittest \\
        tests.integration.test_container_deb -v
"""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Sequence

from tests.integration import harness
from tests.integration.drivers import DockerDriver, detect_docker, host_run, unique_name

INTEGRATION = os.environ.get("UBUNTU_SETUP_INTEGRATION") == "1"
GATE_REASON = "real-install integration tier; set UBUNTU_SETUP_INTEGRATION=1 to run"

#: docker-ce alone is a ~100MB download; one exec must hold the whole install
EXEC_TIMEOUT = float(os.environ.get("UBUNTU_SETUP_INTEGRATION_TIMEOUT", "1800"))

#: marker that makes the guest count as a desktop host (environment.py probe 3)
DESKTOP_MARKER_CMD = (
    "mkdir -p /usr/share/xsessions"
    " && touch /usr/share/xsessions/usetup-verify.desktop"
)


def _patient_run(argv: Sequence[str], *, timeout: float = EXEC_TIMEOUT):
    return host_run(argv, timeout=max(timeout, EXEC_TIMEOUT))


def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


@unittest.skipUnless(INTEGRATION, GATE_REASON)
class TestDebPilotChains(unittest.TestCase):
    """docker + vscode full chains, one fresh guest each, in parallel."""

    image: str
    wheel: Path

    @classmethod
    def setUpClass(cls) -> None:
        if detect_docker() is None:
            raise unittest.SkipTest(
                "container tier skipped: no responsive Docker daemon on this "
                "host (`docker info` failed) — this suite never installs host "
                "software itself"
            )
        tmp = tempfile.TemporaryDirectory(prefix="usetup-verify-wheel-")
        cls.addClassCleanup(tmp.cleanup)  # zero host residue
        cls.wheel = harness.build_wheel(Path(tmp.name))
        cls.image = harness.build_verify_image()

    # -- assertions shared by both chains ----------------------------------------
    @staticmethod
    def _step_order(stdout: str, entry_ids: Sequence[str], op: str = "install"
                    ) -> "list[int]":
        positions = []
        for entry_id in entry_ids:
            needle = f"] {op} {entry_id} ..."
            idx = stdout.find(needle)
            _ensure(idx >= 0, f"step for {entry_id!r} missing from:\n{stdout}")
            positions.append(idx)
        return positions

    @staticmethod
    def _count_audit_updates(session: harness.GuestSession) -> int:
        """How many `apt-get update` commands the tool has run so far, from the
        in-guest audit log (the runner logs every exact argv) — the freshness
        guard's dedupe asserted end-to-end."""
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

    def _verify_chain(
        self,
        session: harness.GuestSession,
        entry_id: str,
        *,
        chain_order: Sequence[str],
        changed_ids: Sequence[str],
        probe: Sequence[str],
        repo_id: str,
    ) -> None:
        """fresh dry-run -> real install (order + one update) -> idempotent
        re-run (all ok, no second update)."""
        user = session.profile.user
        py = session.profile.python

        # -- 1. fresh guest: dry-run predicts, mutates nothing -------------------
        pre = session.exec(list(probe), user=user, desc=f"pre-probe {entry_id}")
        _ensure(not pre.ok, f"guest is not fresh: {probe!r} already succeeds")
        dry = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id, "--dry-run"],
            user=user, desc=f"dry-run {entry_id}",
        )
        _ensure(dry.returncode == 0, f"dry-run must exit 0: {dry.stderr[-500:]}")
        _ensure(f"{repo_id} install: changed — would install (absent -> present)"
                in dry.stdout,
                f"dry-run must predict the repo change; stdout:\n{dry.stdout}")
        _ensure(f"{entry_id} install: changed — would install (absent -> present)"
                in dry.stdout,
                f"dry-run must predict the package change; stdout:\n{dry.stdout}")
        no_manifest = session.exec(["test", "-e", session.profile.manifest_path],
                                   user=user, desc="dry-run wrote no manifest?")
        _ensure(not no_manifest.ok, "a dry run must record nothing")
        still_absent = session.exec(
            ["test", "-e", f"/etc/apt/sources.list.d/{repo_id.split('-repo')[0]}.sources"],
            user=user, desc="dry-run wrote no sources file?")
        _ensure(not still_absent.ok, "a dry run must not configure the repo")

        # -- 2. real install: chain order, outcomes, ONE update ------------------
        inst = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"real install {entry_id}",
        )
        _ensure(inst.returncode == 0,
                f"install must exit 0, got {inst.returncode}: {inst.stderr[-800:]}")
        positions = self._step_order(inst.stdout, chain_order)
        _ensure(positions == sorted(positions),
                f"repo must converge before its packages; order {chain_order} "
                f"violated in:\n{inst.stdout}")
        for changed in changed_ids:
            _ensure(f"{changed} install: changed" in inst.stdout,
                    f"{changed} must report changed; stdout:\n{inst.stdout}")
        _ensure(self._count_audit_updates(session) == 1,
                "the whole chain must cost exactly ONE apt-get update "
                "(freshness guard dedupe)")
        ran = session.exec(list(probe), user=user, desc=f"post-install {entry_id}")
        _ensure(ran.ok, f"{probe!r} must succeed after install (exit {ran.returncode})")
        data = self._read_manifest(session)
        _ensure(data["desired"] == [{"id": entry_id, "op": "install"}],
                f"desired must hold the one requested id, got {data['desired']}")
        tx = data["history"][-1]
        _ensure(tx["exit_code"] == 0, f"transaction exit_code must be 0: {tx}")
        recorded = {a["id"]: a["outcome"] for a in tx["actions"]}
        for changed in changed_ids:
            _ensure(recorded.get(changed) == "changed",
                    f"transaction must record {changed} as changed: {tx['actions']}")

        # -- 3. idempotent re-run: pure check() no-ops, no second update ----------
        rerun = session.exec(
            [py, "-m", "ubuntu_setup", "--install", entry_id],
            user=user, desc=f"idempotent re-run {entry_id}",
        )
        _ensure(rerun.returncode == 0,
                f"re-run must exit 0: {rerun.stderr[-500:]}")
        for eid in (repo_id, entry_id):
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
        _ensure(all(a["outcome"] == "ok" for a in data2["history"][-1]["actions"]),
                f"re-run transaction must be all ok: {data2['history'][-1]}")

    # -- the two pilots -----------------------------------------------------------
    def _verify_docker(self) -> None:
        driver = DockerDriver(self.image, name=unique_name("usetup-deb-docker"),
                              run=_patient_run)
        profile = harness.GuestProfile(needs_provision=False)
        with harness.GuestSession(driver, profile=profile) as session:
            harness.inject_wheel(session, self.wheel)
            self._verify_chain(
                session, "docker",
                # planner DFS over docker's depends_on: bootstrap tools, the
                # repo, then the plugins, then the engine
                chain_order=("ca-certificates", "curl", "gnupg", "docker-repo",
                             "docker-buildx", "docker-compose", "docker"),
                changed_ids=("docker-repo", "docker-buildx", "docker-compose",
                             "docker"),
                probe=("docker", "--version"),
                repo_id="docker-repo",
            )
            # the official five-package set really landed (cli + containerd
            # arrive via dpkg-level Depends of docker-ce)
            for pkg in ("docker-ce", "docker-ce-cli", "containerd.io",
                        "docker-buildx-plugin", "docker-compose-plugin"):
                res = session.exec(["dpkg-query", "-W", "-f=${Status}", pkg],
                                   user=session.profile.user,
                                   desc=f"official set: {pkg} installed")
                _ensure(res.ok and res.stdout.strip() == "install ok installed",
                        f"{pkg} must be installed after the docker chain")

    def _verify_vscode(self) -> None:
        driver = DockerDriver(self.image, name=unique_name("usetup-deb-vscode"),
                              run=_patient_run)
        profile = harness.GuestProfile(needs_provision=False)
        with harness.GuestSession(driver, profile=profile) as session:
            harness.inject_wheel(session, self.wheel)
            # the requires gate first: on the desktop-less guest the GUI
            # package must be a VISIBLE skip (the repo entry carries no
            # requires and would converge — dry run, so nothing mutates)
            gate = session.exec(
                [session.profile.python, "-m", "ubuntu_setup",
                 "--install", "vscode", "--dry-run"],
                user=session.profile.user,
                desc="requires gate: vscode skips on a desktop-less guest",
            )
            _ensure(gate.returncode == 0,
                    f"desktop-less dry-run must exit 0, got {gate.returncode}")
            _ensure("vscode install: skipped" in gate.stdout
                    and "requires desktop" in gate.stdout,
                    f"vscode must skip visibly without a desktop; "
                    f"stdout:\n{gate.stdout}")
            session.exec(["bash", "-c", DESKTOP_MARKER_CMD], check=True,
                         desc="make the guest count as a desktop host")
            self._verify_chain(
                session, "vscode",
                chain_order=("curl", "gnupg", "vscode-repo", "vscode"),
                changed_ids=("vscode-repo", "vscode"),
                # GUI app, no display in a container -> existence probe
                probe=("test", "-x", "/usr/bin/code"),
                repo_id="vscode-repo",
            )

    # -- the acceptance test --------------------------------------------------------
    def test_docker_and_vscode_chains_in_parallel(self):
        failures: "list[str]" = []
        chains = (("docker", self._verify_docker), ("vscode", self._verify_vscode))
        with ThreadPoolExecutor(max_workers=len(chains)) as pool:
            futures = {pool.submit(fn): name for name, fn in chains}
            for future, name in futures.items():
                try:
                    future.result()
                except Exception as exc:  # noqa: BLE001 — aggregate per chain
                    failures.append(f"{name}: {type(exc).__name__}: {exc}")
        if failures:
            self.fail("deb pilot chain failed (diagnostics under "
                      f"{harness.artifacts_dir()}):\n" + "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
