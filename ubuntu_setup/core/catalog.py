"""Load and validate the declarative catalog (YAML -> ``CatalogEntry`` models).

The JSON Schema is the enforcement mechanism; this loader also enforces what the
schema cannot express cheaply: a unique ``id``, a *registered* ``type``, and
``depends_on`` references that resolve. Any violation raises ``CatalogError``
(exit code 2).
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import jsonschema
import yaml

from .errors import CatalogError
from .models import CatalogEntry
from .providers import known_types

_COMMON_FIELDS = {"id", "description", "type", "depends_on", "tags", "source"}

#: where the shipped catalog lives, relative to the package root
DEFAULT_CATALOG_DIR = Path(__file__).resolve().parent.parent / "catalog"
_SCHEMA_FILE = "schema.json"


def _load_schema(catalog_dir: Path) -> dict[str, Any]:
    schema_path = catalog_dir / _SCHEMA_FILE
    try:
        return json.loads(schema_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise CatalogError(f"catalog schema not found: {schema_path}") from exc
    except json.JSONDecodeError as exc:
        raise CatalogError(f"catalog schema is invalid JSON: {schema_path}: {exc}") from exc


def _to_entry(raw: dict[str, Any]) -> CatalogEntry:
    return CatalogEntry(
        id=raw["id"],
        description=raw["description"],
        type=raw["type"],
        depends_on=tuple(raw.get("depends_on", ())),
        tags=tuple(raw.get("tags", ())),
        source=raw.get("source", "community"),
        fields={k: v for k, v in raw.items() if k not in _COMMON_FIELDS},
    )


def load_catalog(catalog_dir: Path | str | None = None) -> dict[str, CatalogEntry]:
    """Return ``{id: CatalogEntry}`` for every ``*.yaml`` under ``catalog_dir``.

    Raises :class:`CatalogError` on schema violation, unknown/duplicate id,
    unregistered type, or an unresolved ``depends_on``.
    """
    catalog_dir = Path(catalog_dir) if catalog_dir is not None else DEFAULT_CATALOG_DIR
    schema = _load_schema(catalog_dir)
    validator = jsonschema.Draft7Validator(schema)

    entries: dict[str, CatalogEntry] = {}
    for yaml_file in sorted(catalog_dir.glob("*.yaml")):
        try:
            docs = yaml.safe_load(yaml_file.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            raise CatalogError(f"{yaml_file}: invalid YAML: {exc}") from exc
        if docs is None:
            continue
        if not isinstance(docs, list):
            raise CatalogError(f"{yaml_file}: top level must be a list of entries")

        for raw in docs:
            if not isinstance(raw, dict):
                raise CatalogError(f"{yaml_file}: each entry must be a mapping, got {type(raw).__name__}")
            errors = sorted(validator.iter_errors(raw), key=lambda e: e.path)
            if errors:
                first = errors[0]
                ident = raw.get("id", "<no id>")
                raise CatalogError(f"{yaml_file}: entry {ident!r} fails schema: {first.message}")

            entry = _to_entry(raw)
            if entry.type not in known_types():
                raise CatalogError(
                    f"{yaml_file}: entry {entry.id!r} has unregistered type {entry.type!r}; "
                    f"registered: {sorted(known_types())}"
                )
            if entry.id in entries:
                raise CatalogError(f"duplicate catalog id {entry.id!r} (in {yaml_file})")
            entries[entry.id] = entry

    # depends_on must resolve to known ids (cycles are out of scope this slice)
    for entry in entries.values():
        for dep in entry.depends_on:
            if dep not in entries:
                raise CatalogError(
                    f"entry {entry.id!r} depends_on unknown id {dep!r}"
                )

    return entries
