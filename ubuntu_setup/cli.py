"""Command-line entry: arg parsing, bootstrap, headless ``--apply`` / ``--install``.

This is the brain/UI boundary: it is the one place that converts the brain's
typed exceptions into user-facing messages and process exit codes. It imports
``core`` only — never ``textual`` (the TUI is a separate, later surface).

    python -m ubuntu_setup --install <id> [--dry-run]
    python -m ubuntu_setup --apply <manifest.json> [--dry-run]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path
from typing import Sequence

from .core import runner
from .core.catalog import DEFAULT_CATALOG_DIR, load_catalog
from .core.errors import CatalogError, UbuntuSetupError, UserAbort
from .core.executor import execute
from .core.models import Manifest, Op, Outcome
from .core.planner import build_plan
from .core.privilege import Privilege
from .core import state as state_mod

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
# summary
# --------------------------------------------------------------------------- #
_OUTCOME_GLYPH = {
    Outcome.CHANGED: "+",
    Outcome.OK: "=",
    Outcome.SKIPPED: "~",
    Outcome.FAILED: "x",
}


def _print_summary(results, *, dry_run: bool, exit_code: int) -> None:
    header = "Plan (dry-run — no changes made):" if dry_run else "Result:"
    print(header)
    if not results:
        print("  (nothing to do)")
    for r in results:
        print(f"  [{_OUTCOME_GLYPH.get(r.outcome, '?')}] {r.entry_id} {r.op.value}: {r.outcome.value} — {r.detail}")
    counts: dict[str, int] = {}
    for r in results:
        counts[r.outcome.value] = counts.get(r.outcome.value, 0) + 1
    tally = ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) or "none"
    print(f"  ({tally}; exit {exit_code})")


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

        # resolve the desired state + which manifest file to record into
        if args.install is not None:
            manifest_file: Path = state_mod.manifest_path(priv)
            manifest: Manifest = state_mod.load_manifest(manifest_file)
            desired = [{"id": args.install, "op": Op.INSTALL.value}]
        else:
            manifest_file = Path(args.apply)
            if not manifest_file.exists():
                # --install's own state manifest may start empty, but a manifest
                # the user explicitly asked to --apply must exist (exit 2).
                raise CatalogError(f"manifest not found: {manifest_file}")
            manifest = state_mod.load_manifest(manifest_file)
            desired = manifest.desired

        plan = build_plan(desired, catalog)

        # acquire sudo up front (unless this is a pure preview)
        if not dry_run and len(plan) > 0:
            priv.ensure_sudo()

        started_at = state_mod.now_iso()
        results, exit_code = execute(
            plan, priv=priv, logger=_LOG, run=runner.run, check_mode=dry_run
        )

        # record the transaction (never for a dry-run preview)
        if not dry_run:
            if args.install is not None:
                state_mod.update_desired(manifest, args.install, Op.INSTALL.value)
            state_mod.record_transaction(
                manifest,
                run_id=state_mod.new_run_id(),
                started_at=started_at,
                exit_code=exit_code,
                results=results,
            )
            state_mod.save_manifest(manifest_file, manifest)

        _print_summary(results, dry_run=dry_run, exit_code=exit_code)
        return exit_code

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
