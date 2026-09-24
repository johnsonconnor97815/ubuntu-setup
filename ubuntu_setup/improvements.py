"""Validated local records for capability improvement cases."""

from datetime import datetime
import re

from .model import DataError


STATUSES = {"open", "candidate", "validated", "adopted", "rejected", "withdrawn"}
TRANSITIONS = {
    "open": {"candidate", "rejected", "withdrawn"},
    "candidate": {"validated", "rejected", "withdrawn"},
    "validated": {"adopted", "rejected", "withdrawn"},
    "adopted": {"withdrawn"},
    "rejected": set(),
    "withdrawn": set(),
}
STABLE_FIELDS = ("capability", "problem", "case", "candidate", "validation")


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _strings(value, *, allow_empty=False):
    return isinstance(value, list) and (allow_empty or bool(value)) and all(_text(item) for item in value)


def _timestamp(value, field):
    if not _text(value):
        raise DataError(f"改进记录缺少 {field}")
    try:
        timestamp = datetime.fromisoformat(value)
    except ValueError as exc:
        raise DataError(f"改进记录的 {field} 时间格式错误") from exc
    if timestamp.tzinfo is None:
        raise DataError(f"改进记录的 {field} 缺少时区")


def _object(value, fields, label):
    if not isinstance(value, dict):
        raise DataError(f"改进记录缺少 {label}")
    for field in fields:
        if not _text(value.get(field)):
            raise DataError(f"改进记录的 {label}.{field} 不能为空")


def validate_improvement(record):
    if not isinstance(record, dict) or record.get("schema_version") != 1:
        raise DataError("不认识的改进记录格式")
    case_id = record.get("case_id")
    if not isinstance(case_id, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]{2,63}", case_id):
        raise DataError("改进案例编号格式错误")
    revision = record.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 1:
        raise DataError("改进记录版本必须从 1 开始")
    status = record.get("status")
    if status not in STATUSES:
        raise DataError("改进记录状态错误")
    if revision == 1 and status == "adopted":
        raise DataError("验证通过与采用必须分成两个记录版本")
    _timestamp(record.get("created_at"), "created_at")
    _timestamp(record.get("updated_at"), "updated_at")

    _object(record.get("capability"), ("name", "version"), "capability")
    problem = record.get("problem")
    _object(problem, ("summary", "observed_at", "expected", "actual"), "problem")
    _timestamp(problem["observed_at"], "problem.observed_at")
    if not _strings(problem.get("evidence")):
        raise DataError("改进记录缺少问题证据")

    case = record.get("case")
    _object(case, ("kind", "input", "expected"), "case")
    if case["kind"] not in {"synthetic", "deidentified"}:
        raise DataError("改进案例类型错误")

    _object(record.get("candidate"), ("summary", "change", "rollback"), "candidate")
    validation = record.get("validation")
    _object(validation, ("old_result", "new_result"), "validation")
    if not isinstance(validation.get("passed"), bool):
        raise DataError("改进记录的验证结果必须是布尔值")
    if not _strings(validation.get("tests")):
        raise DataError("改进记录缺少验证命令或测试")
    if not _strings(validation.get("limitations"), allow_empty=True):
        raise DataError("改进记录的限制说明格式错误")
    if status in {"validated", "adopted"} and not validation["passed"]:
        raise DataError("验证未通过时不能记为 validated 或 adopted")

    if status == "adopted":
        adoption = record.get("adoption")
        _object(adoption, ("decision", "version", "scope", "rollback", "decided_at"), "adoption")
        if adoption["decision"] != "adopted":
            raise DataError("采用记录的 decision 必须为 adopted")
        _timestamp(adoption["decided_at"], "adoption.decided_at")


def validate_transition(previous, current):
    validate_improvement(previous)
    validate_improvement(current)
    if previous["case_id"] != current["case_id"]:
        raise DataError("改进记录版本不能更换案例编号")
    if current["revision"] != previous["revision"] + 1:
        raise DataError("改进记录版本必须连续递增")
    if current["status"] not in TRANSITIONS[previous["status"]]:
        raise DataError("改进记录状态不能这样跳转")
    for field in STABLE_FIELDS:
        if previous[field] != current[field]:
            raise DataError(f"改进记录版本不能改写 {field}")
