"""Bounded evidence collection for the five extended checks.

Collection reads facts and native probe results. The independent rules decide
what those facts mean. Missing evidence never becomes a successful empty check.
"""

import hashlib
import json
from pathlib import Path
import re
import shlex

from .collect import ProbeError
from .model import now


def observed(observations, scope):
    item = observations.get(scope, {})
    return item.get("value") if item.get("status") == "observed" else None


def parse_modinfo(text):
    values = {}
    for line in text.splitlines():
        if ":" not in line:
            raise ProbeError("modinfo 输出无法完整解析")
        name, value = line.split(":", 1)
        if name in {"filename", "version", "srcversion", "vermagic", "signer", "firmware", "alias"}:
            values.setdefault(name, []).append(value.strip())
    if len(values.get("filename", [])) != 1:
        raise ProbeError("modinfo 缺少模块文件信息")
    for name in ("version", "srcversion", "vermagic", "signer"):
        if len(values.get(name, [])) > 1:
            raise ProbeError("modinfo 包含相互矛盾的字段")
    return {name: values.get(name, []) if name in {"firmware", "alias"} else next(iter(values.get(name, [])), "")
            for name in ("filename", "version", "srcversion", "vermagic", "signer", "firmware", "alias")}


def firmware_files(probe, release, names):
    results = []
    if len(names) > 1024:
        raise ProbeError("固件声明超出采集上限")
    for name in sorted(set(names)):
        if not name or name.startswith("/") or ".." in Path(name).parts or not re.fullmatch(r"[A-Za-z0-9_./*?\[\]+-]+", name):
            results.append({"name": "unrecognized", "present": None})
            continue
        found = False
        for base in (f"/lib/firmware/updates/{release}", "/lib/firmware/updates", f"/lib/firmware/{release}", "/lib/firmware"):
            for suffix in ("", ".xz", ".zst"):
                if probe.glob(f"{base}/{name}{suffix}"):
                    found = True
                    break
            if found:
                break
        results.append({"name": name, "present": found})
    return results


def collect_drivers(probe, observations):
    kernel = observed(observations, "kernel")
    bindings = observed(observations, "drivers.bindings")
    if kernel is None or bindings is None:
        raise ProbeError("缺少当前内核或设备与驱动关系")
    release = kernel["release"]
    modules = {}
    for module in sorted({v["module"] for v in bindings.values() if v.get("module")}):
        try:
            result = probe.module_info(release, module)
            if result.code != 0:
                modules[module] = {"readable": False, "error": "modinfo_failed"}
                continue
            info = parse_modinfo(result.output)
            modules[module] = {"readable": True, **info,
                               "firmware_files": firmware_files(probe, release, info["firmware"])}
        except (OSError, UnicodeError, ProbeError) as exc:
            modules[module] = {"readable": False, "error": type(exc).__name__}
    aliases, unreadable_aliases = {}, []
    for device, binding in sorted(bindings.items()):
        if not binding.get("module"):
            continue
        bus, address = device.split(":", 1)
        try:
            alias = probe.read(f"/sys/bus/{bus}/devices/{address}/modalias").strip()
            if not alias or len(alias) > 4096:
                raise ProbeError("设备匹配标识无效")
            aliases[device] = alias
        except (OSError, UnicodeError, ProbeError):
            unreadable_aliases.append(device)
    nvidia = {"status": "not_applicable"}
    if "nvidia" in modules:
        try:
            result = probe.nvidia_status()
            versions = result.output.splitlines()
            if result.code == 0 and versions and all(re.fullmatch(r"\d+(?:\.\d+)+", v) for v in versions):
                nvidia = {"status": "passed", "versions": versions}
            else:
                nvidia = {"status": "failed", "return_code": result.code,
                          "error": "driver_library_mismatch" if "Driver/library version mismatch" in result.output else "management_api_failed"}
        except (OSError, UnicodeError, ProbeError):
            nvidia = {"status": "unavailable"}
    return {"kernel": release, "modules": modules, "device_aliases": aliases,
            "unreadable_aliases": unreadable_aliases, "nvidia_api": nvidia}


def normalize_sysctl(key):
    # sysctl.d(5): the first separator selects dot notation or slash notation;
    # in dot notation the meaning of all subsequent dots/slashes is exchanged.
    separator = re.search(r"[./]", key)
    if separator and separator[0] == ".":
        key = key.translate(str.maketrans({".": "/", "/": "."}))
    if (not key or key.startswith("/") or any(part in {"", ".", ".."} for part in key.split("/"))
            or not re.fullmatch(r"[A-Za-z0-9_./*?\[\]!:+-]+", key)):
        raise ValueError("sysctl key")
    return key


def parse_sysctl(text):
    entries, errors, sources = {}, [], set()
    source, line_number = "sysctl.d", 0
    for line in text.splitlines():
        if line.startswith("# /"):
            source, line_number = line[2:].strip(), 0
            sources.add(source)
            continue
        line_number += 1
        value = line.strip()
        if not value or value.startswith(("#", ";")):
            continue
        optional = value.startswith("-")
        if optional:
            value = value[1:]
        key, sep, raw = value.partition("=")
        location = f"{source}:{line_number}"
        try:
            key = normalize_sysctl(key.strip())
        except ValueError:
            errors.append(location)
            continue
        if not sep and not optional:
            errors.append(location)
            continue
        # Only numeric settings are persisted. Unknown formats remain explicitly
        # unverified; arbitrary configuration values can contain private data.
        normalized = " ".join(raw.split()) if sep else None
        numeric = normalized is None or bool(re.fullmatch(r"[-+]?\d+(?:\s+[-+]?\d+)*", normalized))
        entries[key] = {"key": key, "configured": normalized if numeric else None,
                        "numeric": numeric, "excluded": not bool(sep), "optional": optional,
                        "source": source, "location": location}
    return list(entries.values()), errors, sorted(sources)


def resolve_sysctl(probe, entries):
    explicit = {e["key"] for e in entries if not any(c in e["key"] for c in "*?[")}
    resolved = {}
    for entry in entries:
        key = entry["key"]
        if entry["excluded"]:
            continue
        is_glob = any(c in key for c in "*?[")
        keys = [p.removeprefix("/proc/sys/") for p in probe.glob("/proc/sys/" + key)] if is_glob else [key]
        if len(keys) > 4096:
            raise ProbeError("sysctl 匹配结果超出上限")
        if not keys:
            resolved[key] = {**entry, "read_status": "no_match", "effective": None}
        for actual_key in keys:
            if is_glob and actual_key in explicit:
                continue
            if entry["numeric"]:
                try:
                    value = " ".join(probe.read("/proc/sys/" + actual_key).split())
                    valid = bool(re.fullmatch(r"[-+]?\d+(?:\s+[-+]?\d+)*", value))
                    status, effective = ("read", value) if valid else ("unsupported", None)
                except FileNotFoundError:
                    status, effective = "missing", None
                except (OSError, UnicodeError, ProbeError):
                    status, effective = "unreadable", None
            else:
                status, effective = "unsupported", None
            resolved[actual_key] = {**entry, "key": actual_key, "read_status": status, "effective": effective}
    return sorted(resolved.values(), key=lambda e: e["key"])


def parse_units(text):
    units = []
    if not text.strip():
        raise ProbeError("没有读到系统单元配置状态")
    for block in re.split(r"\n\s*\n", text.strip()):
        values = {}
        for line in block.splitlines():
            key, sep, value = line.partition("=")
            if not sep or key in values or key not in {"Id", "LoadState", "NeedDaemonReload", "FragmentPath", "DropInPaths"}:
                raise ProbeError("系统单元配置输出无法解析")
            values[key] = value
        if set(values) != {"Id", "LoadState", "NeedDaemonReload", "FragmentPath", "DropInPaths"} or not values["Id"] or values["NeedDaemonReload"] not in {"yes", "no"}:
            raise ProbeError("系统单元配置状态不完整")
        try:
            paths = ([values["FragmentPath"]] if values["FragmentPath"] else []) + [p[1:-1] if len(p) >= 2 and p[0] == p[-1] and p[0] in "\"'" else p
                                                                                   for p in shlex.split(values["DropInPaths"], posix=False)]
        except ValueError as exc:
            raise ProbeError("系统单元配置路径无法解析") from exc
        # Backslashes are literal characters in systemd-escaped unit filenames
        # (for example snap-foo\x2dbar.mount). Never shell-unescape these paths.
        if any(not p.startswith("/") or "\x00" in p for p in paths):
            raise ProbeError("系统单元配置路径无法安全读取")
        units.append({"unit": values["Id"], "load_state": values["LoadState"], "needs_reload": values["NeedDaemonReload"] == "yes",
                      "files": paths})
    if len({u["unit"] for u in units}) != len(units):
        raise ProbeError("系统单元配置状态重复")
    return sorted(units, key=lambda u: u["unit"])


def collect_configs(probe, watch_configs):
    result = {"sysctl": [], "syntax_errors": [], "units": [], "read_errors": [], "unverified_files": [], "sources": [],
              "sysctl_digest": None, "unit_files": {}}
    try:
        output = probe.run("sysctl_config")
        if output.code:
            raise ProbeError("无法读取 sysctl 配置")
        entries, errors, sources = parse_sysctl(output.output)
        result.update(sysctl=resolve_sysctl(probe, entries), syntax_errors=errors, sources=sources,
                      sysctl_digest=hashlib.sha256(output.output.encode()).hexdigest())
    except (OSError, UnicodeError, ProbeError):
        result["read_errors"].append("sysctl")
    try:
        output = probe.run("unit_config")
        if output.code:
            raise ProbeError("无法读取系统单元配置")
        result["units"] = parse_units(output.output)
        masked = {p for row in result["units"] if row["load_state"] == "masked" for p in row["files"]}
        for path in sorted({p for row in result["units"] for p in row["files"]}):
            if path in masked:
                result["unit_files"][path] = {"exists": True, "masked": True}
                continue
            try:
                result["unit_files"][path] = probe.file_info(path)
                if not result["unit_files"][path]["exists"]:
                    result["read_errors"].append(path)
            except (OSError, UnicodeError, ProbeError):
                result["read_errors"].append(path)
    except (OSError, UnicodeError, ProbeError):
        result["read_errors"].append("systemd_units")
    result["unverified_files"] = sorted(str(Path(p).absolute()) for p in watch_configs if str(Path(p).absolute()) not in result["sources"])
    return result


CONFIRMATION_SCOPES = ("os", "environment", "boot", "kernel", "hardware.pci", "hardware.usb", "drivers.bindings",
                       "drivers.modules", "packages.dpkg", "configs", "checks.configs")


def confirmation_fingerprint(observations, target_id):
    facts = {}
    for scope in CONFIRMATION_SCOPES:
        record = observations.get(scope, {})
        if record.get("status") != "observed":
            return None
        if scope == "checks.configs" and (record["value"]["read_errors"] or record["value"]["syntax_errors"]):
            return None
        facts[scope] = {k: record[k] for k in ("value", "coverage", "collector_version")}
    facts["target_id"] = target_id
    return hashlib.sha256(json.dumps(facts, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def collect_hardware(probe, observations, confirmations, previous, target_id, confirmation_basis=None):
    try:
        result = probe.run("graphics")
        graphics = json.loads(result.output) if result.code == 0 else {"status": "unavailable", "stage": "process"}
        if not isinstance(graphics, dict) or graphics.get("status") not in {"passed", "failed", "unavailable"}:
            raise ProbeError("绘制测试返回格式无法识别")
    except (OSError, UnicodeError, ProbeError, ValueError):
        graphics = {"status": "unavailable", "stage": "probe"}
    fingerprint = confirmation_fingerprint(observations, target_id)
    old = observed((previous or {}).get("observations", {}), "checks.hardware") or {}
    prior = old.get("confirmations", {})
    accepted, expired, unbound = {}, [], []
    for device in ("display", "audio", "input"):
        if device in confirmations:
            if fingerprint and confirmation_basis == fingerprint:
                accepted[device] = {"result": confirmations[device], "source": "user", "recorded_at": now(), "fingerprint": fingerprint}
            else:
                unbound.append(device)
        elif device in prior:
            if fingerprint and prior[device]["fingerprint"] == fingerprint:
                accepted[device] = prior[device]
            else:
                expired.append(device)
    return {"graphics": graphics, "confirmation_fingerprint": fingerprint, "confirmations": accepted,
            "expired_confirmations": expired, "unbound_confirmations": unbound}
