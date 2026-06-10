"""Command-line entry: arg parsing, event rendering, exit codes.

This is the brain/UI boundary: it is the one place that converts the brain's
typed exceptions into user-facing messages and process exit codes. All
orchestration (load -> plan -> apply -> record) lives in ``core/service.py``
(the facade the future TUI shares); this module only parses arguments, consumes
the apply event stream, and renders. It imports ``core`` only — never
``textual`` (the TUI is a separate, later surface).

    python -m ubuntu_setup --install <id> [--dry-run]
    python -m ubuntu_setup --apply <manifest.json> [--dry-run]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from typing import Iterable, Sequence

from .core import runner, service
from .core import state as state_mod
from .core.catalog import DEFAULT_CATALOG_DIR, load_catalog
from .core.errors import UbuntuSetupError, UserAbort
from .core.events import Event, OutputLine, RunFinished, RunStarted, StepFinished, StepStarted
from .core.models import Outcome
from .core.privilege import Privilege

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
def _setup_logging(priv: Privilege) -> None:
    """Stream INFO to stderr and append an audit log under the real user's home."""
    if _LOG.handlers:  # idempotent across repeated main() calls (tests)
        return
    _LOG.setLevel(logging.INFO)
    stream = logging.StreamHandler(sys.stderr)
    stream.setFormatter(logging.Formatter("%(levelname)s %(message)s"))
    _LOG.addHandler(stream)
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
            print(f"      | {event.line}", flush=True)
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


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main(argv: Sequence[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
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
        # boundary so each surface owns when to prompt (the TUI suspends later)
        if not dry_run and len(prepared.plan) > 0:
            priv.ensure_sudo()

        handle = service.apply(
            prepared, priv=priv, logger=_LOG, run=runner.run, check_mode=dry_run
        )
        return _render_events(handle, dry_run=dry_run)

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
