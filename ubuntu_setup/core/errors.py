"""Typed exception taxonomy.

The brain raises typed errors; only the CLI/TUI boundary converts them to
user-facing messages and process exit codes. Each terminating error carries
its headless ``exit_code`` (single source of truth for the mapping in
``cli.py``), matching the table in
``.trellis/spec/core/idempotency-and-execution.md`` /
``.trellis/spec/core/error-and-logging.md``:

    0  all actions ok/changed          (no exception)
    1  stopped on a failed action      (ProviderError, fail-fast)
    2  usage / invalid catalog/manifest(CatalogError)
    3  interrupted (SIGINT)            (UserAbort)
    4  required privilege unavailable  (PrivilegeError)

``PreconditionError`` is NOT a termination code: it skips one entry and the
run continues (detect-and-skip).
"""

from __future__ import annotations


class UbuntuSetupError(Exception):
    """Base class for all typed errors raised by the brain."""

    #: process exit code when this error reaches the CLI boundary uncaught
    exit_code: int = 1


class CatalogError(UbuntuSetupError):
    """A catalog/manifest file is invalid, or a reference is unknown/cyclic."""

    exit_code = 2


class ProviderError(UbuntuSetupError):
    """A provider command failed (non-zero exit on an apply step). Fail-fast."""

    exit_code = 1

    def __init__(self, message: str, *, entry_id: str | None = None,
                 stderr_tail: str = "") -> None:
        self.entry_id = entry_id
        self.stderr_tail = stderr_tail
        prefix = f"[{entry_id}] " if entry_id else ""
        tail = f"\n--- stderr (tail) ---\n{stderr_tail}" if stderr_tail else ""
        super().__init__(f"{prefix}{message}{tail}")


class PrivilegeError(UbuntuSetupError):
    """``sudo -v`` failed / the user is not a sudoer / credential probe failed."""

    exit_code = 4


class PreconditionError(UbuntuSetupError):
    """A required tool/host capability is absent for an entry -> skip the entry.

    Not a termination code: the executor records the entry as ``skipped`` and
    continues with the rest of the plan.
    """

    exit_code = 0  # never used as a process exit code; the entry is skipped

    def __init__(self, message: str, *, entry_id: str | None = None) -> None:
        self.entry_id = entry_id
        prefix = f"[{entry_id}] " if entry_id else ""
        super().__init__(f"{prefix}{message}")


class UserAbort(UbuntuSetupError):
    """SIGINT / user cancelled at the plan confirmation."""

    exit_code = 3
