"""Guest drivers for the integration tier: launch / exec / push / destroy.

:class:`GuestDriver` is the minimal lifecycle protocol the verification
harness drives; the two implementations map it onto the ``docker`` and
``lxc``/``incus`` host CLIs:

- :class:`DockerDriver` — plain Docker containers (the 95-entry container
  tier: apt/dpkg/file entries; no systemd, no snapd).
- :class:`LxdDriver` — LXD/Incus *system* containers (the 15-entry system
  tier: full systemd as init, snapd officially supported in first-level
  containers). The escape hatch to a real VM is just ``vm=True`` — same CLI,
  same exec/push/delete API (research: isolation-tech.md §1.3/§1.4). ``lxc``
  and ``incus`` are near-identical CLIs, so the binary name is a parameter.

This is *test-layer* code, deliberately outside the product's
``core/runner.py`` boundary (which governs product code): it drives host CLIs
via ``subprocess`` per the verify-infra prd, through one injectable
``host_run`` seam so every driver is unit-testable without docker/lxd
(``tests/integration/test_drivers.py``).

Hard rule: drivers only *probe* for their host tool (:func:`detect_docker` /
:func:`detect_lxd`) — they never install anything on the host.
"""

from __future__ import annotations

import shutil
import subprocess
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Protocol, Sequence

#: generous total-duration cap per host command (a real apt/snap install in the
#: guest happens *inside* one exec); TimeoutExpired propagating = a test bug.
DEFAULT_TIMEOUT = 900.0


@dataclass(frozen=True)
class ExecResult:
    """One host/guest command's outcome. Decisions branch on ``returncode``."""

    argv: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str

    @property
    def ok(self) -> bool:
        return self.returncode == 0


class GuestError(Exception):
    """A guest lifecycle command failed (launch/push plumbing, never an
    in-guest assertion — those are the harness's ``AssertionError``s)."""


HostRun = Callable[..., ExecResult]


def host_run(argv: Sequence[str], *, timeout: float = DEFAULT_TIMEOUT) -> ExecResult:
    """The one real subprocess seam of the integration tier (injectable)."""
    proc = subprocess.run(  # noqa: PLW1510 — returncode is branched on by callers
        list(argv), capture_output=True, text=True, timeout=timeout
    )
    return ExecResult(tuple(argv), proc.returncode, proc.stdout, proc.stderr)


def unique_name(prefix: str) -> str:
    """A collision-free guest name — what makes parallel per-entry guests safe."""
    return f"{prefix}-{uuid.uuid4().hex[:8]}"


class GuestDriver(Protocol):
    """The minimal guest lifecycle the harness drives (prd: launch / push /
    exec / destroy)."""

    name: str

    def launch(self) -> None: ...

    def exec(self, argv: Sequence[str], *, user: "str | None" = None) -> ExecResult: ...

    def push(self, src: "Path | str", dest: str) -> None: ...

    def destroy(self) -> None: ...


# --------------------------------------------------------------------------- #
# Docker (container tier)
# --------------------------------------------------------------------------- #
class DockerDriver:
    """A disposable Docker container guest (one per entry, never reused)."""

    def __init__(
        self,
        image: str,
        *,
        name: "str | None" = None,
        run: HostRun = host_run,
    ) -> None:
        self.image = image
        self.name = name or unique_name("usetup-verify")
        self._run = run

    def launch(self) -> None:
        res = self._run(
            ["docker", "run", "-d", "--name", self.name, self.image,
             "sleep", "infinity"]
        )
        if not res.ok:
            raise GuestError(
                f"docker run failed for {self.name!r} "
                f"(exit {res.returncode}): {res.stderr.strip()[-2000:]}"
            )

    def exec(self, argv: Sequence[str], *, user: "str | None" = None) -> ExecResult:
        cmd = ["docker", "exec"]
        if user is not None:
            cmd += ["-u", user]
        cmd += [self.name, *argv]
        return self._run(cmd)

    def push(self, src: "Path | str", dest: str) -> None:
        if not dest.startswith("/"):
            raise GuestError(f"push dest must be an absolute guest path: {dest!r}")
        res = self._run(["docker", "cp", str(src), f"{self.name}:{dest}"])
        if not res.ok:
            raise GuestError(
                f"docker cp -> {self.name}:{dest} failed "
                f"(exit {res.returncode}): {res.stderr.strip()[-2000:]}"
            )

    def destroy(self) -> None:
        # best-effort and idempotent: a guest that never launched / is already
        # gone must not turn teardown into a second failure
        self._run(["docker", "rm", "-f", self.name])


# --------------------------------------------------------------------------- #
# LXD / Incus (system tier; --vm is the real-VM escape hatch)
# --------------------------------------------------------------------------- #
class LxdDriver:
    """An LXD/Incus system-container (or ``--vm``) guest.

    ``config`` maps to ``-c key=value`` launch options — e.g.
    ``{"security.nesting": "true"}`` for the docker catalog entry. ``binary``
    is ``"lxc"`` (LXD) or ``"incus"``; the CLIs are interchangeable for
    everything this driver does.
    """

    #: accepted ``cloud-init status --wait`` exits: 0 done, 2 done with
    #: recoverable errors (newer cloud-init), 127 no cloud-init in the image.
    _CLOUD_INIT_OK = (0, 2, 127)

    def __init__(
        self,
        image: str,
        *,
        name: "str | None" = None,
        binary: str = "lxc",
        vm: bool = False,
        config: "Mapping[str, str] | None" = None,
        run: HostRun = host_run,
        ready_timeout: float = 180.0,
        poll_interval: float = 2.0,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self.image = image
        self.name = name or unique_name("usetup-verify")
        self.binary = binary
        self.vm = vm
        self.config = dict(config or {})
        self._run = run
        self._ready_timeout = ready_timeout
        self._poll_interval = poll_interval
        self._sleep = sleep
        #: getent cache: user -> (uid, gid, home); resolved once per guest
        self._users: "dict[str, tuple[str, str, str]]" = {}

    def launch(self) -> None:
        cmd = [self.binary, "launch", self.image, self.name]
        if self.vm:
            cmd.append("--vm")
        for key, value in self.config.items():
            cmd += ["-c", f"{key}={value}"]
        res = self._run(cmd)
        if not res.ok:
            raise GuestError(
                f"{self.binary} launch failed for {self.name!r} "
                f"(exit {res.returncode}): {res.stderr.strip()[-2000:]}"
            )
        self._wait_ready()

    def _wait_ready(self) -> None:
        """Exec is not instantly available (container init / VM agent boot):
        poll a trivial command, then let cloud-init finish (user creation)."""
        attempts = max(1, int(self._ready_timeout / self._poll_interval))
        for _ in range(attempts):
            if self._run([self.binary, "exec", self.name, "--", "true"]).ok:
                break
            self._sleep(self._poll_interval)
        else:
            raise GuestError(
                f"guest {self.name!r} never became exec-ready within "
                f"{self._ready_timeout:.0f}s"
            )
        res = self._run(
            [self.binary, "exec", self.name, "--", "cloud-init", "status", "--wait"]
        )
        if res.returncode not in self._CLOUD_INIT_OK:
            raise GuestError(
                f"cloud-init failed in {self.name!r} (exit {res.returncode}): "
                f"{res.stderr.strip()[-2000:]}"
            )

    def _resolve_user(self, user: str) -> "tuple[str, str, str]":
        if user not in self._users:
            res = self._run(
                [self.binary, "exec", self.name, "--", "getent", "passwd", user]
            )
            if not res.ok:
                raise GuestError(
                    f"unknown guest user {user!r} in {self.name!r} "
                    f"(getent exit {res.returncode})"
                )
            # name:x:uid:gid:gecos:home:shell
            fields = res.stdout.strip().split(":")
            self._users[user] = (fields[2], fields[3], fields[5])
        return self._users[user]

    def exec(self, argv: Sequence[str], *, user: "str | None" = None) -> ExecResult:
        cmd = [self.binary, "exec", self.name]
        if user is not None:
            uid, gid, home = self._resolve_user(user)
            cmd += [
                "--user", uid, "--group", gid,
                "--env", f"HOME={home}", "--env", f"USER={user}",
            ]
        cmd += ["--", *argv]
        return self._run(cmd)

    def push(self, src: "Path | str", dest: str) -> None:
        if not dest.startswith("/"):
            raise GuestError(f"push dest must be an absolute guest path: {dest!r}")
        # `<name>/<path>` target form: the slash after the guest name is the root
        res = self._run([self.binary, "file", "push", str(src), f"{self.name}{dest}"])
        if not res.ok:
            raise GuestError(
                f"{self.binary} file push -> {self.name}{dest} failed "
                f"(exit {res.returncode}): {res.stderr.strip()[-2000:]}"
            )

    def destroy(self) -> None:
        self._run([self.binary, "delete", "--force", self.name])  # best-effort


# --------------------------------------------------------------------------- #
# host-tool probes (skip, never install)
# --------------------------------------------------------------------------- #
def detect_docker(
    *,
    run: HostRun = host_run,
    which: Callable[[str], "str | None"] = shutil.which,
) -> "str | None":
    """``"docker"`` when the CLI exists *and* the daemon responds, else None."""
    if which("docker") is None:
        return None
    try:
        res = run(["docker", "info"], timeout=30.0)
    except (OSError, subprocess.SubprocessError):
        return None
    return "docker" if res.ok else None


def detect_lxd(
    *,
    run: HostRun = host_run,
    which: Callable[[str], "str | None"] = shutil.which,
) -> "str | None":
    """The first responsive CLI among LXD's ``lxc`` and ``incus``, else None."""
    for binary in ("lxc", "incus"):
        if which(binary) is None:
            continue
        try:
            res = run([binary, "info"], timeout=30.0)
        except (OSError, subprocess.SubprocessError):
            continue
        if res.ok:
            return binary
    return None
