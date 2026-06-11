"""Driver unit tests — mock host-run, no docker/lxd needed.

These are NOT gated: they run in the default unit suite and keep the
LxdDriver "code ready" while the dev host has no lxd/incus (prd: the system
tier itself skips; its driver logic is still verified here)."""

from __future__ import annotations

import unittest
from typing import Callable, Sequence

from tests.integration.drivers import (
    DockerDriver,
    ExecResult,
    GuestError,
    LxdDriver,
    detect_docker,
    detect_lxd,
)


class FakeHostRun:
    """Scripted stand-in for ``drivers.host_run`` (the tests/_fakes.FakeRun
    pattern: ordered rules, first match wins, default otherwise)."""

    def __init__(self, default_rc: int = 0) -> None:
        self.calls: "list[list[str]]" = []
        self._rules: "list[tuple[Callable[[list[str]], bool], tuple[int, str, str]]]" = []
        self._default_rc = default_rc

    def when(self, match: Callable[["list[str]"], bool], *, returncode: int = 0,
             stdout: str = "", stderr: str = "") -> "FakeHostRun":
        self._rules.append((match, (returncode, stdout, stderr)))
        return self

    def __call__(self, argv: Sequence[str], *, timeout: float = 0.0) -> ExecResult:
        a = list(argv)
        self.calls.append(a)
        for match, (rc, out, err) in self._rules:
            if match(a):
                return ExecResult(tuple(a), rc, out, err)
        return ExecResult(tuple(a), self._default_rc, "", "")


class TestDockerDriver(unittest.TestCase):
    def test_lifecycle_argv_shapes(self):
        fake = FakeHostRun()
        d = DockerDriver("img:tag", name="g1", run=fake)
        d.launch()
        d.push("/host/x.whl", "/tmp/x.whl")
        res = d.exec(["echo", "hi"])
        d.exec(["id"], user="ubuntu")
        d.destroy()

        self.assertEqual(fake.calls, [
            ["docker", "run", "-d", "--init", "--name", "g1", "img:tag",
             "sleep", "infinity"],
            ["docker", "cp", "/host/x.whl", "g1:/tmp/x.whl"],
            ["docker", "exec", "g1", "echo", "hi"],
            ["docker", "exec", "-u", "ubuntu", "g1", "id"],
            ["docker", "rm", "-f", "g1"],
        ])
        self.assertEqual(res.returncode, 0)

    def test_launch_failure_raises_with_stderr(self):
        fake = FakeHostRun().when(lambda a: a[:2] == ["docker", "run"],
                                  returncode=125, stderr="no such image")
        d = DockerDriver("img", name="g1", run=fake)
        with self.assertRaises(GuestError) as cm:
            d.launch()
        self.assertIn("no such image", str(cm.exception))

    def test_push_failure_raises_and_relative_dest_rejected(self):
        fake = FakeHostRun().when(lambda a: a[:2] == ["docker", "cp"],
                                  returncode=1, stderr="denied")
        d = DockerDriver("img", name="g1", run=fake)
        with self.assertRaises(GuestError):
            d.push("/x", "/tmp/x")
        with self.assertRaises(GuestError):
            d.push("/x", "tmp/x")  # must be an absolute guest path

    def test_destroy_is_best_effort(self):
        fake = FakeHostRun(default_rc=1)  # `docker rm -f` of a gone guest fails
        DockerDriver("img", name="g1", run=fake).destroy()  # must not raise
        self.assertEqual(fake.calls, [["docker", "rm", "-f", "g1"]])


def _is_exec_true(argv: "list[str]") -> bool:
    return argv[:3] == ["lxc", "exec", "g1"] and argv[-1] == "true"


class TestLxdDriver(unittest.TestCase):
    def test_launch_waits_for_exec_ready_then_cloud_init(self):
        attempts = {"n": 0}

        def exec_true_still_booting(argv: "list[str]") -> bool:
            if _is_exec_true(argv):
                attempts["n"] += 1
                return attempts["n"] <= 2  # first two polls: not ready yet
            return False

        sleeps: "list[float]" = []
        fake = FakeHostRun().when(exec_true_still_booting, returncode=1)
        d = LxdDriver("ubuntu:24.04", name="g1", run=fake,
                      poll_interval=2.0, ready_timeout=10.0, sleep=sleeps.append)
        d.launch()

        self.assertEqual(fake.calls[0], ["lxc", "launch", "ubuntu:24.04", "g1"])
        self.assertEqual(sleeps, [2.0, 2.0])  # slept exactly between failed polls
        self.assertEqual(fake.calls[-1],
                         ["lxc", "exec", "g1", "--", "cloud-init", "status", "--wait"])

    def test_launch_vm_and_config_flags(self):
        fake = FakeHostRun()
        d = LxdDriver("ubuntu:24.04", name="g1", vm=True,
                      config={"security.nesting": "true"}, run=fake,
                      sleep=lambda _s: None)
        d.launch()
        self.assertEqual(fake.calls[0], [
            "lxc", "launch", "ubuntu:24.04", "g1", "--vm",
            "-c", "security.nesting=true",
        ])

    def test_ready_timeout_raises(self):
        fake = FakeHostRun().when(_is_exec_true, returncode=1)
        d = LxdDriver("ubuntu:24.04", name="g1", run=fake,
                      poll_interval=1.0, ready_timeout=3.0, sleep=lambda _s: None)
        with self.assertRaises(GuestError) as cm:
            d.launch()
        self.assertIn("never became exec-ready", str(cm.exception))

    def test_cloud_init_missing_is_tolerated_but_error_raises(self):
        def cloud_init(argv: "list[str]") -> bool:
            return argv[-3:] == ["cloud-init", "status", "--wait"]

        ok = FakeHostRun().when(cloud_init, returncode=127)  # no cloud-init binary
        LxdDriver("img", name="g1", run=ok, sleep=lambda _s: None).launch()

        bad = FakeHostRun().when(cloud_init, returncode=1, stderr="boom")
        with self.assertRaises(GuestError) as cm:
            LxdDriver("img", name="g1", run=bad, sleep=lambda _s: None).launch()
        self.assertIn("cloud-init", str(cm.exception))

    def test_exec_as_user_resolves_getent_once_and_sets_env(self):
        def getent(argv: "list[str]") -> bool:
            return argv[-3:] == ["getent", "passwd", "ubuntu"]

        fake = FakeHostRun().when(
            getent, stdout="ubuntu:x:1000:1000:Ubuntu:/home/ubuntu:/bin/bash\n"
        )
        d = LxdDriver("img", name="g1", run=fake)
        d.exec(["id"], user="ubuntu")
        d.exec(["pwd"], user="ubuntu")

        getent_calls = [c for c in fake.calls if c[-3:-1] == ["getent", "passwd"]]
        self.assertEqual(len(getent_calls), 1)  # cached after the first exec
        self.assertEqual(fake.calls[1], [
            "lxc", "exec", "g1",
            "--user", "1000", "--group", "1000",
            "--env", "HOME=/home/ubuntu", "--env", "USER=ubuntu",
            "--", "id",
        ])

    def test_exec_unknown_user_raises(self):
        fake = FakeHostRun().when(lambda a: a[-3:-1] == ["getent", "passwd"],
                                  returncode=2)
        with self.assertRaises(GuestError):
            LxdDriver("img", name="g1", run=fake).exec(["id"], user="ghost")

    def test_push_target_form_and_destroy(self):
        fake = FakeHostRun()
        d = LxdDriver("img", name="g1", binary="incus", run=fake)
        d.push("/host/x.whl", "/tmp/x.whl")
        d.destroy()
        self.assertEqual(fake.calls, [
            ["incus", "file", "push", "/host/x.whl", "g1/tmp/x.whl"],
            ["incus", "delete", "--force", "g1"],
        ])
        with self.assertRaises(GuestError):
            d.push("/host/x.whl", "tmp/x.whl")  # relative guest path


class TestDetectProbes(unittest.TestCase):
    def test_detect_docker_requires_cli_and_daemon(self):
        self.assertIsNone(detect_docker(run=FakeHostRun(), which=lambda _b: None))
        down = FakeHostRun().when(lambda a: a == ["docker", "info"], returncode=1)
        self.assertIsNone(detect_docker(run=down, which=lambda _b: "/usr/bin/docker"))
        up = FakeHostRun()
        self.assertEqual(detect_docker(run=up, which=lambda _b: "/usr/bin/docker"),
                         "docker")

    def test_detect_lxd_prefers_lxc_then_incus(self):
        self.assertIsNone(detect_lxd(run=FakeHostRun(), which=lambda _b: None))

        # lxc present but daemon broken -> falls through to a working incus
        run = FakeHostRun().when(lambda a: a == ["lxc", "info"], returncode=1)
        which = lambda b: f"/usr/bin/{b}"  # noqa: E731 — tiny probe stub
        self.assertEqual(detect_lxd(run=run, which=which), "incus")

        # both fine -> lxc wins
        self.assertEqual(detect_lxd(run=FakeHostRun(), which=which), "lxc")


if __name__ == "__main__":
    unittest.main()
