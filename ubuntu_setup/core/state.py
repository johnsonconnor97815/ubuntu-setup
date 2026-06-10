"""The manifest: desired state + append-only transaction history.

This is the manager<->provisioner bridge. Ad-hoc ``--install`` updates the
``desired`` list; ``--apply <manifest>`` replays it on a fresh machine. The
manifest is JSON at ``~/.local/state/ubuntu-setup/manifest.json`` (resolved via
``real_home()`` — never ``/root`` under sudo). It references catalog ids only and
is **never** consulted to decide whether something is currently installed —
current state is always re-derived via ``check()``.
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

from .errors import CatalogError
from .models import Manifest, StepResult
from .privilege import Privilege

MANIFEST_VERSION = 1
_STATE_SUBDIR = (".local", "state", "ubuntu-setup")
_MANIFEST_NAME = "manifest.json"


def state_dir(priv: Privilege) -> Path:
    """The XDG state dir under the *real* user's home (never ``/root``)."""
    name = priv.real_user()[0]
    return Path(priv.real_home(name), *_STATE_SUBDIR)


def manifest_path(priv: Privilege) -> Path:
    """The persistent state manifest path (used by ``--install``)."""
    return state_dir(priv) / _MANIFEST_NAME


def now_iso() -> str:
    """UTC timestamp, e.g. ``2026-06-04T12:30:05Z``."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_run_id() -> str:
    """A unique, sortable-ish run id: ``<iso>-<short hex>``."""
    return f"{now_iso()}-{uuid.uuid4().hex[:4]}"


def load_manifest(path: Path | str) -> Manifest:
    """Load a manifest, or return an empty one if the file does not exist.

    Raises :class:`CatalogError` (exit 2) if the file exists but is invalid.
    """
    path = Path(path)
    if not path.exists():
        return Manifest(version=MANIFEST_VERSION)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise CatalogError(f"manifest is invalid JSON: {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise CatalogError(f"manifest must be a JSON object: {path}")
    version = data.get("version", MANIFEST_VERSION)
    if not isinstance(version, int) or isinstance(version, bool):
        raise CatalogError(f"manifest 'version' must be an integer: {path}")
    if version > MANIFEST_VERSION:
        # version gates forward-compatible schema migrations: refuse to interpret
        # a manifest written by a newer tool rather than misread it.
        raise CatalogError(
            f"manifest version {version} is newer than supported ({MANIFEST_VERSION}): {path}"
        )
    desired = data.get("desired", [])
    history = data.get("history", [])
    if not isinstance(desired, list) or not isinstance(history, list):
        raise CatalogError(f"manifest 'desired'/'history' must be lists: {path}")
    return Manifest(
        version=version,
        desired=desired,
        history=history,
    )


def save_manifest(path: Path | str, manifest: Manifest) -> None:
    """Write ``manifest`` as pretty JSON, creating the state dir if needed."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "version": manifest.version,
        "desired": manifest.desired,
        "history": manifest.history,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def update_desired(manifest: Manifest, entry_id: str, op: str) -> None:
    """Upsert ``{id, op}`` into ``desired`` (the user's intended end-state)."""
    for item in manifest.desired:
        if item.get("id") == entry_id:
            item["op"] = op
            return
    manifest.desired.append({"id": entry_id, "op": op})


def record_transaction(
    manifest: Manifest,
    *,
    run_id: str,
    started_at: str,
    exit_code: int,
    results: Iterable[StepResult],
) -> None:
    """Append one apply transaction to ``history`` (nala's ``history.json`` model)."""
    manifest.history.append(
        {
            "run_id": run_id,
            "started_at": started_at,
            "exit_code": exit_code,
            "actions": [
                {"id": r.entry_id, "op": r.op.value, "outcome": r.outcome.value}
                for r in results
            ],
        }
    )
