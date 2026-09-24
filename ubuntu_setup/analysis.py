"""Compare observations and produce narrowly scoped, evidence-based checks."""

from copy import deepcopy

from .model import DataError, MAP_SCOPES, SCOPES, now, validate_snapshot
from .rules import registry, run_rule

DRIVER_PACKAGES = ("linux-", "firmware-", "nvidia-", "libnvidia-", "xserver-", "mesa-",
                   "libgl", "libegl", "libdrm", "libvulkan", "libc6", "libstdc++")


def _comparison_value(scope, value):
    if scope == "storage":
        # Available space fluctuates as the machine runs. Still recheck it each run.
        return {"total_bytes": value["total_bytes"], "read_only": value["read_only"],
                "space_exhausted": value["available_bytes"] <= 0}
    return value


def compare(previous, current, last_known=None):
    if previous is None:
        return []
    last_known = last_known or {}
    changes = []
    for scope in SCOPES:
        old = previous["observations"].get(scope)
        new = current["observations"][scope]
        if old is None:
            changes.append({"scope": scope, "subject": scope, "kind": "coverage_changed",
                            "previous_observed_at": None, "observed_at": new["observed_at"],
                            "before": None, "after": {"coverage": new["coverage"], "collector_version": new["collector_version"]}})
            continue
        base = {"scope": scope, "subject": scope,
                "previous_observed_at": old["observed_at"], "observed_at": new["observed_at"]}
        if new["status"] != "observed":
            if old["status"] != new["status"] or old["reason"] != new["reason"]:
                changes.append({**base, "kind": "observation_unavailable", "before": old["status"],
                                "after": new["status"], "reason": new["reason"]})
            continue  # No synthetic removals when enumeration failed or became inapplicable.
        if old["status"] != "observed":
            changes.append({**base, "kind": "observation_restored", "before": old["status"], "after": "observed"})
            old = last_known.get(scope)
            if old is None:
                continue
            base["previous_observed_at"] = old["observed_at"]
            base["comparison_basis"] = "last_known_observation"
        if old["coverage"] != new["coverage"] or old["collector_version"] != new["collector_version"]:
            changes.append({**base, "kind": "coverage_changed",
                            "before": {"coverage": old["coverage"], "collector_version": old["collector_version"]},
                            "after": {"coverage": new["coverage"], "collector_version": new["collector_version"]}})
            # Changed installation/user/monitoring scope is not evidence of removal.
            continue
        a, b = old["value"], new["value"]
        if scope in MAP_SCOPES:
            for subject in sorted(set(a) | set(b)):
                if a.get(subject) == b.get(subject) and (subject in a) == (subject in b):
                    continue
                if subject not in a:
                    kind = "added"
                elif subject not in b:
                    kind = "not_observed" if scope.startswith(("hardware.", "drivers.")) else "removed_from_inventory"
                else:
                    kind = "changed"
                changes.append({**base, "subject": subject, "kind": kind,
                                "before": a.get(subject), "after": b.get(subject)})
        elif _comparison_value(scope, a) != _comparison_value(scope, b):
            changes.append({**base, "kind": "changed", "before": a, "after": b})
    return changes


def assess(snapshot, previous_assessment=None, *, rules=None):
    """Evaluate each rule against this snapshot; never collect or repair here."""
    validate_snapshot(snapshot)
    available = registry(rules)
    if any(s not in snapshot["observations"] for rule in available.values() for s in rule.input_scopes):
        raise DataError("旧快照缺少新增检查所需的信息；请运行 inspect 重新采集，历史记录保持不变")
    checked_at = now()
    if previous_assessment and previous_assessment["machine_id"] != snapshot["machine_id"]:
        raise DataError("不能将其他目标的检查记录用于本次检测")
    previous = {c["check_id"]: c for c in (previous_assessment or {}).get("checks", [])}
    checks = [run_rule(rule, snapshot, previous.get(rule.check_id), checked_at=checked_at)
              for rule in available.values()]
    versions = {key: rule.version for key, rule in available.items()}
    rule_changes = []
    if previous_assessment is not None:
        for key in sorted(set(previous) | set(available)):
            before = previous.get(key, {}).get("rule_version")
            after = versions.get(key)
            inputs_changed = key in previous and key in available and set(previous[key]["input_scopes"]) != set(available[key].input_scopes)
            if key not in previous or key not in available or before != after or inputs_changed:
                kind = "added" if key not in previous else "removed" if key not in available else "updated"
                change = {"check_id": key, "kind": kind, "before": before, "after": after}
                if inputs_changed:
                    change["reason"] = "rule_inputs"
                rule_changes.append(change)
    return {"schema_version": 1, "assessment_id": snapshot["snapshot_id"],
            "snapshot_id": snapshot["snapshot_id"], "machine_id": snapshot["machine_id"],
            "checked_at": checked_at, "scope": "read_only_inventory",
            "rule_versions": versions, "rule_changes": rule_changes, "checks": checks,
            "limitations": ["未执行安装、修复、修改系统索引或重启；联网检查只在临时目录下载索引",
                            "设备测试仅覆盖列出的路径；人工确认单独记录，不能证明所有软件或硬件稳定",
                            "未扫描所有手动安装软件、其他用户环境或所有配置",
                            "此报告不能作为系统全面稳定或允许系统变更的凭据"]}


def invalidate(previous_assessment, changes, *, rules=None):
    if previous_assessment is None:
        return []
    available = registry(rules)
    result = []
    changed_scopes = {c["scope"] for c in changes}
    driver_package_changed = any(c["scope"].startswith("packages.") and (
        c["kind"] in {"coverage_changed", "observation_unavailable"} or
        c["subject"].startswith(DRIVER_PACKAGES)) for c in changes)
    for check in previous_assessment["checks"]:
        rule = available.get(check["check_id"])
        reasons = changed_scopes.intersection(check["input_scopes"])
        if rule is None:
            reasons.add("rule_removed")
        elif check.get("rule_version") != rule.version:
            reasons.add("rule_version")
        if rule is not None:
            reasons |= changed_scopes.intersection(rule.invalidation_scopes)
            if set(check["input_scopes"]) != set(rule.input_scopes):
                reasons.add("rule_inputs")
        if rule is not None and rule.driver_related:
            if driver_package_changed:
                reasons.add("packages:driver_or_runtime_related")
        if reasons:
            result.append({"check_id": check["check_id"], "previous_assessment_id": previous_assessment["assessment_id"],
                           "validity": "stale", "invalidated_by": sorted(reasons)})
    return result


def make_snapshot(machine_id, run_id, source_kind, observations, previous=None):
    records = deepcopy(observations)
    for scope, obs in records.items():
        obs["machine_id"] = machine_id
        if previous and obs["status"] != "observed":
            prior = previous["observations"].get(scope)
            if prior is None:
                continue
            if prior["status"] == "observed":
                obs["last_known_ref"] = {"snapshot_id": previous["snapshot_id"], "scope": scope}
            elif prior.get("last_known_ref"):
                obs["last_known_ref"] = deepcopy(prior["last_known_ref"])
    return {"schema_version": 1, "snapshot_id": run_id, "machine_id": machine_id,
            "run_id": run_id, "source_kind": source_kind, "captured_at": now(),
            "previous_snapshot_id": previous["snapshot_id"] if previous else None, "observations": records}
