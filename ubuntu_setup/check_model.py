"""Validate extended observations before they can become durable evidence."""

from .model import DataError, _require, _strings


def validate_check_observation(scope, value):
    fields = {
        "checks.packages": {"backend": str, "installed_count": int, "broken": list, "held": list,
                            "held_changed": list, "simulation_resolved": bool, "simulation_broken_count": int,
                            "actions": list, "metadata_mode": str, "metadata_complete": bool},
        "checks.updates": {"mode": str, "refresh_status": str, "refresh_error": str, "sources": list,
                           "unsafe_options": list, "candidates": list, "metadata_complete": bool},
        "checks.drivers": {"kernel": str, "modules": dict, "device_aliases": dict,
                           "unreadable_aliases": list, "nvidia_api": dict},
        "checks.hardware": {"graphics": dict, "confirmations": dict, "expired_confirmations": list,
                            "unbound_confirmations": list},
        "checks.configs": {"sysctl": list, "syntax_errors": list, "units": list, "read_errors": list,
                           "unverified_files": list, "sources": list},
    }[scope]
    _require(value, fields, scope)

    def require(entry, types):
        if not isinstance(entry, dict):
            raise DataError(f"{scope}: 条目须为对象")
        _require(entry, types, scope)

    def choices(item, allowed):
        if not isinstance(item, str) or item not in allowed:
            raise DataError(f"{scope}: 状态无法识别")

    for field in ("broken", "held", "held_changed", "unreadable_aliases", "expired_confirmations", "unbound_confirmations",
                  "syntax_errors", "read_errors", "unverified_files", "kept_back"):
        if field in value and not _strings(value[field]):
            raise DataError(f"{scope}: {field} 须为字符串数组")
    if scope == "checks.packages":
        choices(value["metadata_mode"], {"cache", "online"})
        if value["installed_count"] < 0 or value["simulation_broken_count"] < 0:
            raise DataError(f"{scope}: 包数量不能为负数")
        for row in value["actions"]:
            require(row, {"package": str, "action": str, "from": (str, type(None)), "to": (str, type(None))})
            choices(row["action"], {"install", "upgrade", "downgrade", "remove"})
    elif scope == "checks.updates":
        choices(value["mode"], {"cache", "online"})
        choices(value["refresh_status"], {"not_requested", "verified", "failed", "blocked"})
        for row in value["sources"]:
            require(row, {"id": str, "suite": str, "apt_trusted": bool, "package_indexes": int, "missing_indexes": int})
            if row["package_indexes"] < 0 or not 0 <= row["missing_indexes"] <= row["package_indexes"]:
                raise DataError(f"{scope}: 索引数量无效")
        for row in value["unsafe_options"]:
            require(row, {"file": str, "option": str})
        for row in value["candidates"]:
            require(row, {"package": str, "installed": str, "candidate": str, "origins": list, "apt_trusted": bool, "held": bool})
            if not _strings(row["origins"]):
                raise DataError(f"{scope}: 更新来源格式错误")
    elif scope == "checks.drivers":
        for module, row in value["modules"].items():
            require(row, {"readable": bool})
            if row["readable"]:
                require(row, {"filename": str, "version": str, "srcversion": str, "vermagic": str, "signer": str,
                              "firmware": list, "alias": list, "firmware_files": list})
                if not _strings(row["alias"]) or not _strings(row["firmware"]):
                    raise DataError(f"{scope}: 模块元数据格式错误")
                for file in row["firmware_files"]:
                    require(file, {"name": str, "present": (bool, type(None))})
            elif not isinstance(row.get("error"), str):
                raise DataError(f"{scope}: 缺少模块读取失败原因")
        if not all(isinstance(k, str) and isinstance(v, str) for k, v in value["device_aliases"].items()):
            raise DataError(f"{scope}: 设备匹配标识格式错误")
        choices(value["nvidia_api"].get("status"), {"passed", "failed", "unavailable", "not_applicable"})
        if value["nvidia_api"]["status"] == "passed" and not _strings(value["nvidia_api"].get("versions")):
            raise DataError(f"{scope}: 驱动接口版本无效")
    elif scope == "checks.hardware":
        choices(value["graphics"].get("status"), {"passed", "failed", "unavailable"})
        if value["graphics"]["status"] in {"passed", "failed"}:
            require(value["graphics"], {"software": bool, "renderer": str, "pixel": list, "gl_error": int})
        fingerprint = value.get("confirmation_fingerprint")
        if fingerprint is not None and (not isinstance(fingerprint, str) or len(fingerprint) != 64):
            raise DataError(f"{scope}: 功能确认的环境标识无效")
        for device, row in value["confirmations"].items():
            choices(device, {"display", "audio", "input"})
            require(row, {"result": str, "source": str, "recorded_at": str, "fingerprint": str})
            choices(row["result"], {"passed", "failed", "not_applicable"})
            if row["source"] != "user" or not fingerprint or row["fingerprint"] != fingerprint:
                raise DataError(f"{scope}: 人工确认缺少匹配的环境依据")
    elif scope == "checks.configs":
        if not _strings(value["sources"]):
            raise DataError(f"{scope}: 配置来源格式错误")
        for row in value["sysctl"]:
            require(row, {"key": str, "configured": (str, type(None)), "effective": (str, type(None)), "numeric": bool,
                          "excluded": bool, "optional": bool, "source": str, "location": str, "read_status": str})
            choices(row["read_status"], {"read", "no_match", "missing", "unreadable", "unsupported"})
        for row in value["units"]:
            require(row, {"unit": str, "load_state": str, "needs_reload": bool})
