"""Shared test doubles.

``FakeRun`` stands in for ``core.runner.run`` — the single subprocess boundary.
Injecting it lets us exercise providers / executor / cli without touching real
apt or sudo (the prd's "fake runner" test strategy).

``register_provider`` temporarily registers a scripted provider *instance* in
the registry, so executor/facade tests can drive arbitrary install behavior
(emit timing, PreconditionError, slow steps) without a real provider type.
"""

from __future__ import annotations

import logging
import threading
from types import SimpleNamespace
from typing import Callable, Sequence
from unittest import mock

from ubuntu_setup.core import providers as providers_mod
from ubuntu_setup.core.privilege import Privilege
from ubuntu_setup.core.providers.base import Ctx
from ubuntu_setup.core.runner import RunResult, TerminateOutcome


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

    The contract mirrors the real seam's *streaming* extension too: a caller
    may pass ``on_line``/``on_start`` (as the executor's per-step ``ctx.run``
    binding does). A rule's ``lines`` are forwarded to ``on_line`` before the
    result returns; ``on_start`` is accepted and ignored (no real process —
    cancel tests publish a :class:`FakeKillableCommand` instead).
    """

    def __init__(self, default_rc: int = 0) -> None:
        self.calls: list[SimpleNamespace] = []
        self._rules: list[tuple[Callable[[list[str]], bool],
                                tuple[int, str, str, tuple]]] = []
        self._default_rc = default_rc

    def when(self, match: Callable[[list[str]], bool], *, returncode: int = 0,
             stdout: str = "", stderr: str = "",
             lines: "Sequence[object]" = ()) -> "FakeRun":
        """``lines``: scripted live output — each item a ``str`` (stdout) or a
        ``(line, stream)`` tuple — forwarded to ``on_line`` when the caller
        streams."""
        norm = tuple((l, "stdout") if isinstance(l, str) else (l[0], l[1])
                     for l in lines)
        self._rules.append((match, (returncode, stdout, stderr, norm)))
        return self

    def __call__(self, argv: Sequence[str], *, sudo: bool = False,
                 on_line=None, on_start=None, **kw) -> RunResult:
        a = list(argv)
        self.calls.append(SimpleNamespace(argv=a, sudo=sudo, kw=kw))
        for match, (rc, out, err, lines) in self._rules:
            if match(a):
                if on_line is not None:
                    for line, stream in lines:
                        on_line(line, stream)
                return RunResult(a, rc, out, err, 0.0)
        return RunResult(a, self._default_rc, "", "", 0.0)

    # -- introspection helpers ------------------------------------------------
    def ran(self, needle: str) -> bool:
        return any(needle in " ".join(c.argv) for c in self.calls)

    def count(self, match: Callable[[list[str]], bool]) -> int:
        return sum(1 for c in self.calls if match(c.argv))


class FakeKillableCommand:
    """A scripted slow in-flight command for cancel tests (no real process).

    :meth:`stream_run` plays the executor's ``stream_run`` seam: it publishes
    *itself* as the terminate handle via ``on_start`` (the real seam publishes
    a ``StreamingRun``), sets ``started``, then blocks on ``done`` — the
    synchronization primitive that makes cancel tests deterministic.
    ``terminate()`` plays the streaming runner's kill: it unblocks the command
    with a killed-by-signal rc — or, with ``degraded=True``, returns
    :attr:`TerminateOutcome.DEGRADED` and leaves the command running (the test
    later calls :meth:`finish` to simulate natural completion).
    """

    def __init__(self, *, degraded: bool = False) -> None:
        self.started = threading.Event()
        self.done = threading.Event()
        self.was_killed = False
        self.terminate_calls = 0
        self._degraded = degraded

    def terminate(self) -> TerminateOutcome:
        self.terminate_calls += 1
        if self._degraded:
            return TerminateOutcome.DEGRADED
        self.was_killed = True
        self.done.set()
        return TerminateOutcome.TERMINATED

    def finish(self) -> None:
        """Natural completion (the degraded path's only way out)."""
        self.done.set()

    def stream_run(self, argv: Sequence[str], *, sudo: bool = False,
                   on_line=None, on_start=None, **kw) -> RunResult:
        if on_start is not None:
            on_start(self)
        self.started.set()
        assert self.done.wait(timeout=10.0), "fake command was never killed/finished"
        rc = -15 if self.was_killed else 0
        return RunResult(list(argv), rc, "", "terminated" if self.was_killed else "", 0.0)


def make_ctx(run: FakeRun, *, check_mode: bool = False) -> Ctx:
    return Ctx(
        run=run,
        priv=Privilege(run=run),
        log=logging.getLogger("test"),
        check_mode=check_mode,
    )


def register_provider(provider) -> "mock._patch_dict":
    """Patch the registry so ``get_provider(provider.type)`` returns *this*
    instance (the registry normally constructs a fresh ``cls(run=run)`` per
    step; a shared instance lets tests observe state across the run).

    Use as a context manager::

        with register_provider(MyFakeProvider()):
            ...
    """
    return mock.patch.dict(
        providers_mod._REGISTRY,
        {provider.type: lambda run=None, _p=provider: _p},
    )
