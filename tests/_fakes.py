"""Shared test doubles.

``FakeRun`` stands in for ``core.runner.run`` — the single subprocess boundary.
Injecting it lets us exercise providers / executor / cli without touching real
apt or sudo (the prd's "fake runner" test strategy).
"""

from __future__ import annotations

import logging
from types import SimpleNamespace
from typing import Callable, Sequence

from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.base import Ctx
from ubuntu_setup.core.runner import RunResult


def status_query(argv: list[str]) -> bool:
    return "-f=${Status}" in argv


def version_query(argv: list[str]) -> bool:
    return "-f=${Version}" in argv


def apt_install(argv: list[str]) -> bool:
    return argv[:2] == ["apt-get", "install"]


class FakeRun:
    """Records calls and returns scripted :class:`RunResult`s.

    Rules added via :meth:`when` are matched in order; unmatched commands return
    ``default_rc`` with empty output.
    """

    def __init__(self, default_rc: int = 0) -> None:
        self.calls: list[SimpleNamespace] = []
        self._rules: list[tuple[Callable[[list[str]], bool], tuple[int, str, str]]] = []
        self._default_rc = default_rc

    def when(self, match: Callable[[list[str]], bool], *, returncode: int = 0,
             stdout: str = "", stderr: str = "") -> "FakeRun":
        self._rules.append((match, (returncode, stdout, stderr)))
        return self

    def __call__(self, argv: Sequence[str], *, sudo: bool = False, **kw) -> RunResult:
        a = list(argv)
        self.calls.append(SimpleNamespace(argv=a, sudo=sudo, kw=kw))
        for match, (rc, out, err) in self._rules:
            if match(a):
                return RunResult(a, rc, out, err, 0.0)
        return RunResult(a, self._default_rc, "", "", 0.0)

    # -- introspection helpers ------------------------------------------------
    def ran(self, needle: str) -> bool:
        return any(needle in " ".join(c.argv) for c in self.calls)

    def count(self, match: Callable[[list[str]], bool]) -> int:
        return sum(1 for c in self.calls if match(c.argv))


def make_ctx(run: FakeRun, *, check_mode: bool = False) -> Ctx:
    return Ctx(
        run=run,
        priv=Privilege(run=run),
        log=logging.getLogger("test"),
        check_mode=check_mode,
    )
