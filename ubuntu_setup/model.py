"""Versioned observations shared by live collection, fixtures and saved runs."""

from datetime import datetime, timezone
import json
from pathlib import Path
import uuid

# Version of observation semantics, independent of program and rule versions.
COLLECTOR_VERSION = "0.1.0"
CHECK_COLLECTOR_VERSION = "0.2.0"

BASE_SCOPES = (
    "os", "environment", "resources", "storage", "kernel", "kernel.next_boot",
    "boot", "packages.dpkg", "packages.snap", "packages.flatpak.system",
    "packages.flatpak.user", "sources.apt", "metadata.apt", "hardware.pci",
    "hardware.usb", "drivers.bindings", "drivers.modules", "drivers.secure_boot",
    "drivers.dkms", "reboot", "services", "configs",
)
CHECK_SCOPES = ("checks.packages", "checks.drivers", "checks.hardware", "checks.updates", "checks.configs")
SCOPES = BASE_SCOPES + CHECK_SCOPES
MAP_SCOPES = frozenset(s for s in SCOPES if s.startswith(("packages.", "hardware."))) | {
    "sources.apt", "drivers.bindings", "drivers.modules", "configs", "services",
}
STATUSES = {"observed", "unknown", "not_applicable"}


class DataError(ValueError):
    """Malformed, unsupported or inconsistent input; never an empty inventory."""


def now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def new_id():
    return uuid.uuid4().hex


def observation(scope, value=None, *, status="observed", reason="", coverage=None):
    return {
        "observation_id": new_id(), "scope": scope, "observed_at": now(),
        "collector_version": CHECK_COLLECTOR_VERSION if scope in CHECK_SCOPES else COLLECTOR_VERSION,
        "status": status, "value": value,
        "reason": reason, "coverage": coverage or [scope], "evidence_refs": [],
    }


def _strings(value):
    return isinstance(value, list) and all(isinstance(x, str) for x in value)


def _require(value, fields, scope):
    for field, expected in fields.items():
        item = value.get(field)
        if not isinstance(item, expected) or (expected is int and isinstance(item, bool)):
            raise DataError(f"{scope}: 字段 {field} 类型错误")


def validate_observations(observations, *, legacy=False):
    allowed = (set(BASE_SCOPES), set(SCOPES)) if legacy else (set(SCOPES),)
    if not isinstance(observations, dict) or set(observations) not in allowed:
        raise DataError("采集范围不完整或包含未知范围")
    for scope, obs in observations.items():
        if not isinstance(obs, dict) or obs.get("scope") != scope:
            raise DataError(f"{scope}: 观察记录格式错误")
        if not isinstance(obs.get("status"), str) or obs["status"] not in STATUSES or not isinstance(obs.get("reason"), str):
            raise DataError(f"{scope}: 观察状态或原因错误")
        if not _strings(obs.get("coverage")) or not isinstance(obs.get("observed_at"), str):
            raise DataError(f"{scope}: 缺少采集时间或覆盖范围")
        if not isinstance(obs.get("observation_id"), str) or not obs["observation_id"] or not isinstance(obs.get("collector_version"), str) or not _strings(obs.get("evidence_refs")):
            raise DataError(f"{scope}: 观察编号、版本或证据引用格式错误")
        try:
            timestamp = datetime.fromisoformat(obs["observed_at"])
            if timestamp.tzinfo is None:
                raise ValueError("missing timezone")
        except ValueError as exc:
            raise DataError(f"{scope}: 采集时间缺少时区或格式错误") from exc
        if obs["status"] != "observed":
            if obs.get("value") is not None or not obs["reason"]:
                raise DataError(f"{scope}: 未知或不适用记录须有原因且 value 为 null")
            continue
        value = obs.get("value")
        if not isinstance(value, dict):
            raise DataError(f"{scope}: value 必须是对象")
        fields = {
            "os": {"id": str, "version_id": str, "architecture": str},
            "environment": {"kind": str, "technology": str},
            "resources": {"cpu_model": str, "logical_cpus": int, "memory_bytes": int},
            "storage": {"total_bytes": int, "available_bytes": int, "read_only": bool},
            "kernel": {"release": str}, "boot": {"id": str},
            "reboot": {"required_marker": bool},
            "drivers.secure_boot": {"enabled": bool},
            "metadata.apt": {"index_file_count": int},
        }.get(scope, {})
        _require(value, fields, scope)
        if scope in CHECK_SCOPES:
            from .check_model import validate_check_observation
            validate_check_observation(scope, value)
        for field in ("total_bytes", "available_bytes", "logical_cpus", "memory_bytes", "index_file_count"):
            if field in fields and value[field] < 0:
                raise DataError(f"{scope}: {field} 不能为负数")
        for field in ("id", "version_id", "architecture", "release"):
            if field in fields and not value[field]:
                raise DataError(f"{scope}: {field} 不能为空")
        if scope == "environment" and value["kind"] not in {"physical", "vm", "container", "wsl"}:
            raise DataError("environment: 未知环境类型")
        if scope == "drivers.dkms" and not _strings(value.get("entries")):
            raise DataError("drivers.dkms: entries 必须是字符串数组")
        if scope in MAP_SCOPES:
            for name, entry in value.items():
                if not name or not isinstance(entry, dict):
                    raise DataError(f"{scope}: 清单条目格式错误")
                if scope.startswith("packages."):
                    _require(entry, {"version": str}, scope)
                if scope == "packages.dpkg":
                    _require(entry, {"architecture": str, "status": str, "error_flag": str}, scope)


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DataError("JSON 包含重复字段")
        result[key] = value
    return result


def _reject_constant(value):
    raise DataError("JSON 包含非有限数字")


def read_json(path):
    try:
        with Path(path).open(encoding="utf-8") as stream:
            return json.load(stream, object_pairs_hook=_unique_fields, parse_constant=_reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        # Do not include file contents or parser excerpts in error messages.
        raise DataError(f"无法读取有效 JSON：{Path(path).name}（{type(exc).__name__}）") from exc


def load_fixture(path):
    raw = read_json(path)
    if not isinstance(raw, dict) or raw.get("schema_version") != 1:
        raise DataError("模拟数据的 schema_version 必须为 1")
    if not isinstance(raw.get("fixture_id"), str) or not raw["fixture_id"]:
        raise DataError("模拟数据缺少 fixture_id")
    values = raw.get("observations")
    if not isinstance(values, dict) or set(values) - set(SCOPES):
        raise DataError("模拟数据的 observations 格式或范围错误")
    observations = {}
    for scope in SCOPES:
        entry = values.get(scope)
        if entry is None:
            observations[scope] = observation(scope, status="unknown", reason="模拟数据未提供此范围")
        elif not isinstance(entry, dict):
            raise DataError(f"{scope}: 模拟观察须为对象")
        else:
            observations[scope] = observation(
                scope, entry.get("value"), status=entry.get("status", "observed"),
                reason=entry.get("reason", ""), coverage=entry.get("coverage", [scope]),
            )
    validate_observations(observations)
    return raw["fixture_id"], observations


def validate_snapshot(snapshot):
    if not isinstance(snapshot, dict) or snapshot.get("schema_version") != 1:
        raise DataError("不认识的快照格式")
    for key in ("snapshot_id", "machine_id", "run_id", "captured_at", "source_kind"):
        if not isinstance(snapshot.get(key), str) or not snapshot[key]:
            raise DataError(f"快照缺少 {key}")
    if snapshot["source_kind"] not in {"live", "fixture"}:
        raise DataError("快照来源错误")
    # Old snapshots are immutable. Accept the complete original scope set,
    # without fabricating observations or changing their evidence references.
    validate_observations(snapshot.get("observations"), legacy=True)
