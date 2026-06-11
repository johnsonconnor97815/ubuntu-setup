"""Command-line entry: arg parsing, event rendering, exit codes.

This is the brain/UI boundary: it is the one place that converts the brain's
typed exceptions into user-facing messages and process exit codes. All
orchestration (load -> plan -> apply -> record) lives in ``core/service.py``
(the facade the TUI shares); this module only parses arguments, consumes the
apply event stream, and renders.

    python -m ubuntu_setup                               # bare: launch the TUI
    python -m ubuntu_setup --install <id> [--dry-run]    # headless
    python -m ubuntu_setup --apply <manifest.json> [--dry-run]

The ``textual`` import lives *inside* the bare-command branch
(:func:`_run_tui`) only: the headless ``--install``/``--apply`` paths never
load it (works on machines without the TUI extra's terminal, and keeps
import-time cost zero for scripted runs)."""

from __future__ import annotations

import argparse
import logging
import os
import signal
import sys
import threading
from typing import Iterable, Sequence

from .core import environment, runner, service
from .core import state as state_mod
from .core.catalog import DEFAULT_CATALOG_DIR, load_catalog
from .core.errors import UbuntuSetupError, UserAbort
from .core.events import Event, OutputLine, RunFinished, RunStarted, StepFinished, StepStarted
from .core.models import Outcome
from .core.privilege import CredentialStatus, Privilege

_LOG = logging.getLogger("ubuntu_setup")


# --------------------------------------------------------------------------- #
# argument parsing
# --------------------------------------------------------------------------- #
def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="ubuntu-setup",
        description="Idempotent software manager/provisioner for fresh Ubuntu (headless MVP).",
    )
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--install", metavar="ID", help="install a single catalog entry by id")
    target.add_argument("--apply", metavar="MANIFEST", help="plan & apply the desired state from a manifest JSON")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="plan only: show what would change, make ZERO changes",
    )
    parser.add_argument(
        "--catalog",
        metavar="DIR",
        default=None,
        help=f"catalog directory (default: shipped {DEFAULT_CATALOG_DIR})",
    )
    return parser


# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
def _setup_logging(priv: Privilege, *, stream: bool = True) -> None:
    """Stream INFO to stderr and append an audit log under the real user's home.

    ``stream=False`` for the TUI branch: the TUI owns the terminal, so a
    stderr handler would corrupt the screen — the audit file still gets
    everything.
    """
    if _LOG.handlers:  # idempotent across repeated main() calls (tests)
        return
    _LOG.setLevel(logging.INFO)
    if stream:
        stream_handler = logging.StreamHandler(sys.stderr)
        stream_handler.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
        _LOG.addHandler(stream_handler)
    try:
        log_dir = state_mod.state_dir(priv)
        log_dir.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(log_dir / "ubuntu-setup.log")
        file_handler.setFormatter(
            logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s")
        )
        _LOG.addHandler(file_handler)
    except OSError:
        # never fail the run just because the audit file can't be opened
        _LOG.debug("could not open audit log file", exc_info=True)


# --------------------------------------------------------------------------- #
# event rendering
# --------------------------------------------------------------------------- #
_OUTCOME_GLYPH = {
    Outcome.CHANGED: "+",
    Outcome.OK: "=",
    Outcome.SKIPPED: "~",
    Outcome.FAILED: "x",
}


def _render_events(events: Iterable[Event], *, dry_run: bool) -> int:
    """Consume the apply event stream, printing step-by-step progress, and
    return the run's exit code (from the final ``RunFinished``)."""
    exit_code = 0
    counts: dict[str, int] = {}
    for event in events:
        if isinstance(event, RunStarted):
            header = "Plan (dry-run — no changes made):" if dry_run else "Result:"
            print(header, flush=True)
            if event.total == 0:
                print("  (nothing to do)", flush=True)
        elif isinstance(event, StepStarted):
            print(f"  [{event.index}/{event.total}] {event.op.value} {event.entry_id} ...", flush=True)
        elif isinstance(event, OutputLine):
            glyph = "!" if event.stream == "stderr" else "|"
            print(f"      {glyph} {event.line}", flush=True)
        elif isinstance(event, StepFinished):
            r = event.result
            counts[r.outcome.value] = counts.get(r.outcome.value, 0) + 1
            glyph = _OUTCOME_GLYPH.get(r.outcome, "?")
            print(f"  [{glyph}] {r.entry_id} {r.op.value}: {r.outcome.value} — {r.detail}", flush=True)
        elif isinstance(event, RunFinished):
            exit_code = event.exit_code
            tally = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "none"
            suffix = "; cancelled" if event.cancelled else ""
            print(f"  ({tally}; exit {exit_code}{suffix})", flush=True)
    return exit_code


def _consume_with_signals(handle: "service.ApplyHandle", *, dry_run: bool) -> int:
    """Consume the apply stream with SIGINT/SIGTERM converted to ``cancel()``.

    The streaming child runs in its own session, so the terminal's Ctrl-C
    never reaches it — and letting ``KeyboardInterrupt`` unwind the generator
    would not kill it either: the engine's abandon semantics *wait out* the
    in-flight step (blocking, with no feedback) and only ``cancel()`` kills
    it. So the first signal cancels cooperatively — the in-flight command is
    killed, the stream still ends with ``RunFinished(cancelled, exit 3)`` and
    the partial transaction is recorded. A second signal stops waiting (e.g. a
    degraded, unkillable sudo step) by raising ``KeyboardInterrupt`` into the
    normal abandon path.
    """
    seen: "list[int]" = []

    def on_signal(signum: int, frame: object) -> None:
        seen.append(signum)
        if len(seen) > 1:
            raise KeyboardInterrupt  # second signal: abandon instead of waiting
        print("\ninterrupt: cancelling — killing the in-flight command ...",
              file=sys.stderr)
        outcome = handle.cancel()
        if outcome is runner.TerminateOutcome.DEGRADED:
            print(
                "cannot kill the escalated command (sudo credential "
                "unavailable); waiting for the current step to finish "
                "(interrupt again to stop waiting) ...",
                file=sys.stderr,
            )

    installed: "list[tuple[int, object]]" = []
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGINT, signal.SIGTERM):
            installed.append((sig, signal.signal(sig, on_signal)))
    try:
        return _render_events(handle, dry_run=dry_run)
    finally:
        for sig, old in installed:
            # getsignal-style None (a handler not installed from Python) cannot
            # be passed back to signal.signal — fall back to the default
            signal.signal(sig, signal.SIG_DFL if old is None else old)


# --------------------------------------------------------------------------- #
# the TUI branch (bare command)
# --------------------------------------------------------------------------- #
def _run_tui() -> int:
    """Launch the Textual face. Only this branch imports the ``tui`` package
    (and therefore ``textual``) — headless runs never load it."""
    priv = Privilege()
    _setup_logging(priv, stream=False)  # the TUI owns the terminal
    if os.geteuid() == 0:
        _LOG.warning(
            "running as root: ubuntu-setup is designed to run as the normal user "
            "and escalate per command. Prefer running without sudo."
        )
    try:
        catalog = load_catalog(None)
    except UbuntuSetupError as exc:
        _LOG.error("%s", exc)
        print(f"error: {exc}", file=sys.stderr)
        return exc.exit_code

    # host applicability, detected once at startup: the TUI only ever sees the
    # filtered catalog (browse invisibility is decided in the brain — the face
    # consumes the result and never re-judges, non-negotiable #1)
    capabilities = environment.detect_capabilities()
    catalog = service.filter_catalog(catalog, capabilities)

    from .tui.app import ManagerApp  # deliberate local import (see module doc)

    ManagerApp(catalog, priv=priv, logger=_LOG).run()
    return 0


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main(argv: Sequence[str] | None = None) -> int:
    raw_args = list(sys.argv[1:]) if argv is None else list(argv)
    if not raw_args:
        return _run_tui()  # bare command -> the TUI (prd: the default surface)

    args = _build_parser().parse_args(raw_args)
    priv = Privilege()
    _setup_logging(priv)

    if os.geteuid() == 0:
        _LOG.warning(
            "running as root: ubuntu-setup is designed to run as the normal user "
            "and escalate per command. Prefer running without sudo."
        )

    dry_run: bool = args.dry_run
    try:
        catalog = load_catalog(args.catalog)
        if args.install is not None:
            prepared = service.prepare_install(args.install, catalog, priv=priv)
        else:
            prepared = service.prepare_apply(args.apply, catalog)

        # acquire sudo up front (unless this is a pure preview); kept at this
        # boundary so each surface owns when to prompt (the TUI suspends
        # later). Probe-adaptive (spec privilege Rule 2): a silently-cached
        # credential (or NOPASSWD) skips the interactive prompt; otherwise
        # validate interactively (`sudo -v` on the tty) — with no tty and no
        # credential that fails cleanly to exit 4.
        if not dry_run and len(prepared.plan) > 0:
            if priv.probe_credentials() is not CredentialStatus.CACHED:
                priv.ensure_sudo()

        handle = service.apply(
            prepared, priv=priv, logger=_LOG,
            run=runner.run, stream_run=runner.run_streaming, check_mode=dry_run,
        )
        try:
            return _consume_with_signals(handle, dry_run=dry_run)
        except KeyboardInterrupt:
            # Second signal (or one landing outside the handler's window): the
            # exception already unwound the generator — the engine drained the
            # bridge and recorded the partial transaction on its way out.
            # cancel()/close() are idempotent backstops for the narrow case
            # where the interrupt fired in *this* frame instead.
            handle.cancel()
            handle.close()
            print("aborted: interrupted (signal)", file=sys.stderr)
            return UserAbort.exit_code

    except UserAbort as exc:
        _LOG.error("%s", exc)
        print(f"aborted: {exc}", file=sys.stderr)
        return exc.exit_code
    except UbuntuSetupError as exc:
        _LOG.error("%s", exc)
        print(f"error: {exc}", file=sys.stderr)
        return exc.exit_code
    except KeyboardInterrupt:
        print("aborted: interrupted (SIGINT)", file=sys.stderr)
        return UserAbort.exit_code


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
