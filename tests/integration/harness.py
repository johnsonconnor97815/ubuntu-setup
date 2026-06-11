"""The verification harness: wheel injection + the per-entry protocol.

Pieces (all driver-agnostic — they only speak :class:`drivers.GuestDriver`):

- :func:`build_wheel` — build the project wheel on the host into a caller-owned
  temp dir (zero host residue). Prefers ``uv build`` (dev machines), falls
  back to ``pip wheel`` (CI).
- :func:`build_verify_image` — the container tier's baked base image
  (``docker/verify-base.Dockerfile``); layer-cached, apt lists refreshed at
  most daily via a date build-arg.
- :class:`GuestSession` — one disposable guest: records every exec into a
  transcript; on failure writes diagnostics (transcript + the tool's in-guest
  audit log + manifest snapshot) under the artifacts dir, then destroys the
  guest (``UBUNTU_SETUP_INTEGRATION_KEEP=1`` keeps a failed guest alive).
- :func:`provision` — bring a *stock* guest (LXD tier) up to what the Docker
  tier bakes into its image. Root inside the guest only — never the host.
- :func:`inject_wheel` — push the wheel, create a venv (PEP 668), install it.
- :func:`verify_entry` — the protocol: fresh check (absent, dry-run mutates
  nothing) -> real install (changed, binary runs, transaction recorded) ->
  idempotent re-run (ok, no second install) — asserting exit codes, stdout and
  manifest semantics against the spec
  (``.trellis/spec/core/idempotency-and-execution.md``).
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Sequence

from tests.integration.drivers import ExecResult, GuestDriver, GuestError, host_run

REPO_ROOT = Path(__file__).resolve().parents[2]
DOCKERFILE = Path(__file__).resolve().parent / "docker" / "verify-base.Dockerfile"
VERIFY_IMAGE = "ubuntu-setup-verify-base:noble"

#: what `provision` installs inside a stock guest (= the Dockerfile's list)
PROVISION_PACKAGES = (
    "sudo", "ca-certificates", "python3-venv", "python3-yaml", "python3-jsonschema",
)


@dataclass(frozen=True)
class GuestProfile:
    """How to use a guest: which user runs the tool, and whether the guest
    still needs in-guest provisioning (stock LXD image) or comes baked
    (the Docker verify-base image)."""

    user: str = "ubuntu"
    home: str = "/home/ubuntu"
    needs_provision: bool = False

    @property
    def venv(self) -> str:
        return f"{self.home}/usetup-venv"

    @property
    def python(self) -> str:
        return f"{self.venv}/bin/python"

    @property
    def manifest_path(self) -> str:
        return f"{self.home}/.local/state/ubuntu-setup/manifest.json"

    @property
    def audit_log_path(self) -> str:
        return f"{self.home}/.local/state/ubuntu-setup/ubuntu-setup.log"


def artifacts_dir() -> Path:
    override = os.environ.get("UBUNTU_SETUP_INTEGRATION_ARTIFACTS")
    if override:
        return Path(override)
    return Path(__file__).resolve().parent / "_artifacts"


# --------------------------------------------------------------------------- #
# host-side build steps
# --------------------------------------------------------------------------- #
def build_wheel(dest_dir: Path, *, repo_root: Path = REPO_ROOT) -> Path:
    """Build the project wheel into ``dest_dir`` and return its path.

    ``dest_dir`` is a caller-owned temp dir (the test's ``TemporaryDirectory``)
    — the wheel never lands outside it. (The setuptools backend does refresh
    the repo's gitignored ``build/`` + ``*.egg-info`` byproducts in place —
    the standard packaging side effect, not test residue.) Builder preference:
    ``uv build`` where available (the dev-machine toolchain; the repo venv has
    no pip), else ``pip wheel`` (GHA runners).
    """
    if shutil.which("uv") is not None:
        argv = ["uv", "build", "--wheel", "--out-dir", str(dest_dir), str(repo_root)]
    else:
        try:
            import pip  # noqa: F401 — availability probe only
        except ImportError as exc:
            raise GuestError(
                "cannot build the wheel: neither `uv` nor `pip` is available "
                "on this host"
            ) from exc
        argv = [
            sys.executable, "-m", "pip", "wheel", "--no-deps",
            "--wheel-dir", str(dest_dir), str(repo_root),
        ]
    res = host_run(argv, timeout=600.0)
    if not res.ok:
        raise GuestError(
            f"wheel build failed (exit {res.returncode}): {res.stderr.strip()[-2000:]}"
        )
    wheels = sorted(dest_dir.glob("ubuntu_setup-*.whl"))
    if not wheels:
        raise GuestError(f"wheel build produced no ubuntu_setup-*.whl in {dest_dir}")
    return wheels[-1]


def build_verify_image(*, run=host_run) -> str:
    """Build (or reuse from layer cache) the container tier's base image.

    ``UBUNTU_SETUP_VERIFY_BASE_IMAGE`` overrides the ``ubuntu:24.04`` base
    reference for hosts where docker.io is proxied/mirrored (must stay a
    byte-identical official image, e.g. ``mirror.gcr.io/library/ubuntu:24.04``).
    """
    refresh = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    base = os.environ.get("UBUNTU_SETUP_VERIFY_BASE_IMAGE", "ubuntu:24.04")
    res = run(
        [
            "docker", "build",
            "-t", VERIFY_IMAGE,
            "--build-arg", f"APT_REFRESH={refresh}",
            "--build-arg", f"BASE_IMAGE={base}",
            "-f", str(DOCKERFILE), str(DOCKERFILE.parent),
        ],
        timeout=900.0,
    )
    if not res.ok:
        raise GuestError(
            f"verify-base image build failed (exit {res.returncode}): "
            f"{res.stderr.strip()[-2000:]}"
        )
    return VERIFY_IMAGE


# --------------------------------------------------------------------------- #
# guest session: transcript + diagnostics + teardown
# --------------------------------------------------------------------------- #
class GuestSession:
    """One disposable guest with a recorded transcript.

    Use as a context manager: ``launch()`` on enter; on an exception inside the
    block, diagnostics are collected to the artifacts dir before the guest is
    destroyed (or kept, with ``UBUNTU_SETUP_INTEGRATION_KEEP=1``).
    """

    def __init__(self, driver: GuestDriver, *, profile: GuestProfile) -> None:
        self.driver = driver
        self.profile = profile
        self.transcript: "list[str]" = []

    # -- lifecycle -------------------------------------------------------------
    def __enter__(self) -> "GuestSession":
        self.driver.launch()
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        try:
            if exc is not None:
                where = self.collect_diagnostics()
                if where is not None:
                    print(
                        f"[verify-infra] guest {self.driver.name!r} failed; "
                        f"diagnostics: {where}",
                        file=sys.stderr,
                    )
        finally:
            keep = (
                exc is not None
                and os.environ.get("UBUNTU_SETUP_INTEGRATION_KEEP") == "1"
            )
            if keep:
                print(
                    f"[verify-infra] UBUNTU_SETUP_INTEGRATION_KEEP=1: keeping "
                    f"failed guest {self.driver.name!r} for inspection",
                    file=sys.stderr,
                )
            else:
                self.driver.destroy()
        return False  # never swallow the test failure

    # -- recorded exec -----------------------------------------------------------
    def exec(
        self,
        argv: Sequence[str],
        *,
        user: "str | None" = None,
        check: bool = False,
        desc: str = "",
    ) -> ExecResult:
        """Run a command in the guest, recording it into the transcript.

        ``check=True`` turns a non-zero exit into a :class:`GuestError` — for
        harness plumbing steps (provision/venv), not protocol assertions.
        """
        res = self.driver.exec(argv, user=user)
        self.transcript.append(
            "$ {argv}{user}  # {desc}\nexit {rc}\n--- stdout ---\n{out}\n"
            "--- stderr ---\n{err}\n".format(
                argv=" ".join(argv),
                user=f"  [user={user}]" if user else "",
                desc=desc or "-",
                rc=res.returncode,
                out=res.stdout,
                err=res.stderr,
            )
        )
        if check and not res.ok:
            raise GuestError(
                f"guest step failed ({desc or argv[0]}): exit {res.returncode}\n"
                f"stderr tail: {res.stderr[-2000:]}"
            )
        return res

    # -- diagnostics -------------------------------------------------------------
    def collect_diagnostics(self) -> "Path | None":
        """Write the transcript + in-guest audit log + manifest snapshot under
        the artifacts dir; never raises (diagnostics must not mask the failure)."""
        try:
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            target = artifacts_dir() / f"{stamp}-{self.driver.name}"
            target.mkdir(parents=True, exist_ok=True)
            (target / "transcript.log").write_text(
                "\n".join(self.transcript), encoding="utf-8"
            )
            for guest_path, fname in (
                (self.profile.audit_log_path, "guest-audit.log"),
                (self.profile.manifest_path, "manifest.json"),
            ):
                res = self.driver.exec(["cat", guest_path])
                if res.ok:
                    (target / fname).write_text(res.stdout, encoding="utf-8")
            return target
        except Exception as exc:  # noqa: BLE001 — diagnostics are best-effort
            print(f"[verify-infra] diagnostics collection failed: {exc}",
                  file=sys.stderr)
            return None


# --------------------------------------------------------------------------- #
# in-guest preparation
# --------------------------------------------------------------------------- #
def provision(session: GuestSession) -> None:
    """Bring a stock guest to the baked verify-base level (no-op when the
    profile says the image is already baked). Runs as root *inside the guest*
    — the host is never touched."""
    if not session.profile.needs_provision:
        return
    session.exec(["apt-get", "update"], check=True, desc="provision: apt-get update")
    session.exec(
        ["apt-get", "install", "-y", "--no-install-recommends",
         *PROVISION_PACKAGES],
        check=True,
        desc="provision: install harness prerequisites",
    )
    user = session.profile.user
    session.exec(
        ["bash", "-c",
         f'echo "{user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-usetup-verify'
         " && chmod 0440 /etc/sudoers.d/90-usetup-verify"],
        check=True,
        desc="provision: NOPASSWD sudoers for the verify user",
    )


def inject_wheel(session: GuestSession, wheel: Path) -> None:
    """Push the host-built wheel and install it into a fresh in-guest venv.

    24.04 is PEP 668 externally-managed: never the system python. The venv is
    ``--system-site-packages`` + ``pip install --no-deps`` so runtime deps come
    from the guest's apt packages (no PyPI traffic; the headless paths never
    import textual)."""
    dest = f"/tmp/{wheel.name}"
    session.driver.push(wheel, dest)
    user = session.profile.user
    session.exec(
        ["python3", "-m", "venv", "--system-site-packages", session.profile.venv],
        user=user, check=True, desc="create venv",
    )
    session.exec(
        [f"{session.profile.venv}/bin/pip", "install", "--no-deps",
         "--no-cache-dir", dest],
        user=user, check=True, desc="install wheel into venv",
    )


# --------------------------------------------------------------------------- #
# the per-entry verification protocol
# --------------------------------------------------------------------------- #
def _ensure(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def _read_manifest(session: GuestSession) -> dict:
    res = session.exec(
        ["cat", session.profile.manifest_path],
        user=session.profile.user, check=True, desc="read manifest",
    )
    return json.loads(res.stdout)


def verify_entry(
    session: GuestSession,
    entry_id: str,
    binary: str,
    *,
    probe: "Sequence[str] | None" = None,
    expect_preinstalled: bool = False,
    include_usage_probe: bool = False,
) -> None:
    """Run the full per-entry protocol on a fresh, already-injected guest.

    1. fresh state: the binary is absent; ``--install --dry-run`` exits 0,
       predicts ``absent -> present (would change)`` and records **nothing**;
    2. real install: exit 0, outcome ``changed``, the binary actually runs,
       and the manifest gains a transaction (exit_code 0, outcome changed)
       plus the upserted desired entry;
    3. idempotent re-run: exit 0, outcome ``ok`` (already present — the
       ``check()`` skip, not a reinstall), a second transaction records ``ok``,
       and ``desired`` is not duplicated.

    ``probe`` overrides the default ``[binary, "--version"]`` landing proof for
    tools without ``--version`` (e.g. ``["go", "version"]``, ``["test", "-x",
    "/usr/sbin/sshd"]`` for daemons/GUI apps that can't run headless).

    ``expect_preinstalled`` flips the protocol for entries the base image (or
    any fresh 24.04) already ships (e.g. ca-certificates, python3): the probe
    must succeed *before* install, dry-run predicts "already present (no
    change)", and the install run is the ``check()`` no-op (outcome ``ok``,
    never ``changed``) — still proving id/package validity and idempotency.

    ``include_usage_probe`` adds the exit-code-table probe (unknown id ->
    ``CatalogError`` -> exit 2) — once per tier is enough, so it is opt-in.
    """
    user = session.profile.user
    py = session.profile.python
    probe_argv = list(probe) if probe is not None else [binary, "--version"]

    # -- 0. fresh guest (or: the preinstalled premise holds) --------------------
    probe_res = session.exec(probe_argv, user=user,
                             desc=f"pre-probe: {entry_id} "
                                  f"({'pre' if expect_preinstalled else 'not '}installed)")
    if expect_preinstalled:
        _ensure(probe_res.ok,
                f"{entry_id}: expected preinstalled in the base image, but the "
                f"probe failed (exit {probe_res.returncode})")
    else:
        _ensure(not probe_res.ok,
                f"guest is not fresh: {probe_argv!r} already succeeds before install")

    if include_usage_probe:
        bogus = session.exec(
            [py, "-m", "ubuntu_setup", "--install", "no-such-entry-xyz",
             "--dry-run"],
            user=user, desc="unknown id -> CatalogError -> exit 2",
        )
        _ensure(bogus.returncode == 2,
                f"unknown id must exit 2 (CatalogError), got {bogus.returncode}")

    # -- 1. plan-only: predicts the (no-)change, mutates nothing ----------------
    dry = session.exec(
        [py, "-m", "ubuntu_setup", "--install", entry_id, "--dry-run"],
        user=user, desc=f"dry-run on fresh guest: {entry_id}",
    )
    _ensure(dry.returncode == 0,
            f"--dry-run must exit 0, got {dry.returncode}: {dry.stderr[-500:]}")
    if expect_preinstalled:
        _ensure(f"{entry_id} install: ok" in dry.stdout
                and "already present" in dry.stdout,
                f"dry-run must report the no-change; stdout was:\n{dry.stdout}")
    else:
        _ensure("would install (absent -> present)" in dry.stdout,
                f"dry-run must predict the change; stdout was:\n{dry.stdout}")
    manifest_exists = session.exec(["test", "-e", session.profile.manifest_path],
                                   user=user, desc="dry-run wrote no manifest?")
    _ensure(not manifest_exists.ok, "a dry run must record nothing")

    # -- 2. real install (the check() no-op for a preinstalled entry) ------------
    expected_outcome = "ok" if expect_preinstalled else "changed"
    inst = session.exec(
        [py, "-m", "ubuntu_setup", "--install", entry_id],
        user=user, desc=f"real install: {entry_id}",
    )
    _ensure(inst.returncode == 0,
            f"install must exit 0, got {inst.returncode}: {inst.stderr[-500:]}")
    _ensure(f"{entry_id} install: {expected_outcome}" in inst.stdout,
            f"install must report outcome {expected_outcome}; stdout was:\n"
            f"{inst.stdout}")
    ran = session.exec(probe_argv, user=user,
                       desc=f"post-install: {entry_id} probe runs")
    _ensure(ran.ok, f"{probe_argv!r} must succeed after install "
                    f"(exit {ran.returncode})")
    data = _read_manifest(session)
    _ensure(data["desired"] == [{"id": entry_id, "op": "install"}],
            f"desired must hold the upserted entry, got {data['desired']}")
    tx = data["history"][-1]
    _ensure(tx["exit_code"] == 0, f"transaction exit_code must be 0, got {tx}")
    _ensure(tx["actions"] == [{"id": entry_id, "op": "install",
                               "outcome": expected_outcome}],
            f"transaction must record outcome {expected_outcome}, "
            f"got {tx['actions']}")

    # -- 3. idempotent re-run ----------------------------------------------------
    rerun = session.exec(
        [py, "-m", "ubuntu_setup", "--install", entry_id],
        user=user, desc=f"idempotent re-run: {entry_id}",
    )
    _ensure(rerun.returncode == 0,
            f"re-run must exit 0, got {rerun.returncode}: {rerun.stderr[-500:]}")
    _ensure(f"{entry_id} install: ok" in rerun.stdout
            and "already present" in rerun.stdout,
            f"re-run must be the check() no-op; stdout was:\n{rerun.stdout}")
    _ensure("Unpacking" not in rerun.stdout,
            "re-run must not reinstall (apt output detected)")
    data2 = _read_manifest(session)
    _ensure(len(data2["history"]) == len(data["history"]) + 1,
            "re-run must append exactly one transaction")
    _ensure(data2["history"][-1]["actions"] == [
                {"id": entry_id, "op": "install", "outcome": "ok"}],
            f"re-run transaction must record ok, got {data2['history'][-1]}")
    _ensure(data2["desired"] == [{"id": entry_id, "op": "install"}],
            "desired must be upserted, never duplicated")
