# Errors, the Runner & Logging

> The single subprocess boundary, the exception taxonomy, and the audit log. Owns `core/runner.py`, `core/errors.py`, and the logging setup.

---

## Status: runner & taxonomy code-backed (`core/runner.py`, `core/errors.py`)

The runner contract below is implemented by `core/runner.py` — `run` (capturing), `run_streaming`/`StreamingRun` (live per-line + programmatic termination), the pure `build_argv`/`build_privileged_kill_argv`, and the `InFlightCommand` cancel slot — covered by `tests/core/test_runner.py`; the exception taxonomy by `core/errors.py`. The verified non-interactive idioms (apt prompts, locale, sudo env-stripping) are baked into the runner so individual providers cannot get them wrong.

---

## The runner is the only subprocess boundary

Every external command — in providers, the privilege helper, state queries — goes through one wrapper in `core/runner.py`. No bare `subprocess.run` / `os.system` / `shell=True` strings elsewhere.

The runner guarantees:

- **argv list, `shell=False`.** Never build a shell string from entry fields (injection + quoting bugs). The `script` escape hatch is the one place a shell line is intended, and even it is run as `["bash", "-c", cmd]` through the runner, logged verbatim.
- **Non-interactive, parseable environment** by default: `DEBIAN_FRONTEND=noninteractive`, `DEBIAN_PRIORITY=critical`, and forced `LC_ALL=C`/`LANG=C` so apt/dpkg output is stable to parse (Ansible's apt module does exactly this). Callers pass extra env (e.g. `HOME` for a dropped-privilege child) but cannot drop these.
- **Privileged variant** that prefixes `sudo` and re-asserts `DEBIAN_FRONTEND` *inside* the sudo invocation (sudo's `env_reset` strips the parent's). See [privilege-and-safety.md](./privilege-and-safety.md).
- **Captured output + timeout**, returning a small result object (`returncode`, `stdout`, `stderr`, `duration`). Decisions branch on `returncode`; when output *must* be read, read a **machine-format field** (`dpkg-query -W -f='${Status}'`, `flatpak list --columns=…`, `systemctl is-enabled`) under forced `LC_ALL=C`, never localized human prose. The `${Status}`/`${Version}` checks in [catalog-and-providers.md](./catalog-and-providers.md) are exactly this sanctioned pattern — stable, field-formatted, locale-pinned — not an exception to the rule. The timeout is **total duration** and yields `returncode == 124` without raising (both variants), so a provider surfaces it as a normal command failure.
- **A streaming variant** (`run_streaming` / `StreamingRun`) with the *same* contract — argv list + `shell=False`, forced env, `shlex.join` audit log, total-duration timeout → 124 — but stdout/stderr are forwarded line-by-line to an `on_line(line, stream)` callback *while the command runs*, and the call still returns the same aggregated result object at the end (provider rc/stderr-tail decisions don't change). The executor binds provider `ctx.run` to this variant for mutating ops, turning every line into a live `OutputLine` event; `check()` keeps the plain capturing `run`. Backpressure is the callback's: a slow consumer blocks the pipe (and eventually the child) — never an unbounded buffer in the runner.
- **Child-process-group handling + programmatic termination.** A streaming child starts in its own session (`start_new_session=True`, so the group is killable as a unit without touching us), and the handle (published to the caller via `on_start`) exposes `terminate()`: SIGTERM to the group → a grace period → SIGKILL escalation. A `sudo=True` command's child (`sudo -n env … apt-get`) is root for its whole life, so a normal user's `killpg` is always `EPERM` (the terminal's Ctrl-C only reaches it via kernel foreground-process-group delivery, which programmatic signals don't get); terminating an escalated command therefore goes **through the runner boundary itself** — `sudo -n kill [-9] -- -<pgid>`, built by the pure `build_privileged_kill_argv` (unit-testable without sudo, like `build_argv`) and audit-logged like any other command. If the privileged kill fails (lapsed `sudo -n` credential), the result is an explicit **degraded** outcome (`TerminateOutcome.DEGRADED`, surfaced to the consumer through `ApplyHandle.cancel()`): "cannot kill — the in-flight step is waited out", never silently swallowed. This is also how `SIGINT`/`SIGTERM` abort a run cleanly: the consumer (CLI today, TUI later) reacts by calling `cancel()`, which kills the in-flight command through the `InFlightCommand` slot (see signals in [idempotency-and-execution.md](./idempotency-and-execution.md)).
- **Logs the exact argv** of every command (the audit trail) before running it. Render it with `shlex.join(argv)`, not `" ".join(argv)` — a plain space-join is ambiguous the moment an argument contains spaces (you can't tell `["a b"]` from `["a", "b"]` in the log), defeating the "exact argv" audit guarantee. `shlex.join` quotes such arguments (`dpkg-query -W '-f=${Status}' tree`) and round-trips via `shlex.split`.

---

## Exception taxonomy

`core/errors.py` defines a small, typed hierarchy so the executor and TUI can react precisely instead of catching bare `Exception`:

| Exception | Raised when | Executor/TUI reaction |
|-----------|-------------|-----------------------|
| `CatalogError` | A catalog file is invalid against `schema.json`, or `depends_on` is unknown/cyclic | Abort load; exit code `2`; point at the file/entry |
| `ProviderError` | A provider's command failed (non-zero exit on an apply step) | Fail-fast: stop the run, report entry + stderr tail; exit `1` |
| `PrivilegeError` | `sudo -v` failed / user is not a sudoer / credential probe failed | Stop before mutating; tell the user what privilege is needed; exit `4` |
| `PreconditionError` | A required tool/host capability is absent for an entry | **Skip** that entry (detect-and-skip), record `skipped` |
| `UserAbort` | `SIGINT` / user cancelled at the plan confirmation | Clean stop; exit `3` |

Rules:

- Providers raise `ProviderError` (or `PreconditionError`) with the failing entry id and the captured stderr tail — never swallow a non-zero exit.
- Distinguish "not installed" (a normal `check()` result, `State.ABSENT`) from "the check command errored" (`dpkg-query` exit 2, a real DB error). Don't treat every non-zero as "absent" — see the dpkg-query pitfall in [catalog-and-providers.md](./catalog-and-providers.md).
- The brain raises typed errors; only the TUI/CLI boundary converts them to user-facing messages and exit codes.

---

## Logging & the audit trail

- **Log every command** the runner executes (exact argv, returncode, duration) and every state transition the executor records. For an open-source `sudo`-running tool, this audit log is a trust feature, not a debug afterthought — the user can review exactly what happened.
- Use the stdlib `logging` module with a file handler under the real user's home (e.g. `~/.local/state/ubuntu-setup/`, resolved via `real_home()` — never `/root` under sudo) plus a level-filtered stream the TUI can subscribe to for its live log panel.
- **Never log secrets or full file contents.** Diffs/contents that could leak sensitive data are suppressible/truncated (mirrors Ansible `no_log` / `max_diff_size`).
- Log levels: `INFO` for actions taken and skipped, `WARNING` for recoverable oddities (stale cache forced-refresh, masked unit), `ERROR` for the failing step. Keep `INFO` readable as a human transcript of the run.

---

## Anti-patterns (forbidden)

- `subprocess.run(..., shell=True)` with an interpolated entry field; any `os.system`.
- Catching bare `Exception` in a provider and continuing as if it succeeded.
- Treating any non-zero exit as "not installed" without distinguishing real command errors.
- Logging to a path that resolves to `/root` when running under sudo.
- Parsing localized apt output (always force `LC_ALL=C` instead).
