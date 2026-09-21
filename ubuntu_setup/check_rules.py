"""Pure interpretation of extended evidence. No I/O or repair operations."""

import fnmatch

from .rules import Outcome


def dependencies(inputs, previous):
    data = inputs.value("checks.packages")
    context = {"installed_count": data["installed_count"], "actions": data["actions"], "metadata_mode": data["metadata_mode"],
               "kept_back": data.get("kept_back", [])}
    if data["broken"]:
        return Outcome("failed", "已安装软件存在未满足的依赖或版本冲突", "核对冲突包和依赖关系，先形成修复计划",
                       subjects=tuple(data["broken"]), context=context, reason_code="dependencies_broken")
    if not data["installed_count"]:
        return Outcome("unknown", "没有可核对的已安装软件记录", "核实包管理数据库与目标环境", context=context, reason_code="dependencies_empty")
    if data["held_changed"]:
        return Outcome("unknown", "更新模拟涉及被锁定版本的软件；此模拟不能直接用于执行", "保留锁定要求并重新解析计划",
                       subjects=tuple(data["held_changed"]), context=context, reason_code="dependencies_held")
    if not data["simulation_resolved"] or data["simulation_broken_count"]:
        return Outcome("failed", "当前更新候选无法组成依赖完整的方案", "查清版本冲突后重新解析；未执行任何更新",
                       context=context, reason_code="dependencies_conflict")
    if not data["metadata_complete"]:
        return Outcome("unknown", "当前已安装软件依赖未见冲突，但部分软件源缺少缓存，更新模拟不完整",
                       "使用隔离联网检查补齐索引后重新解析", context=context, reason_code="dependencies_incomplete")
    consequential = tuple(a["package"] for a in data["actions"] if a["action"] in {"remove", "downgrade"})
    if consequential:
        return Outcome("pending", "模拟更新需要移除或降级已有软件，影响须先确认", "审查完整变更清单与用户用途，再制定维护计划",
                       subjects=consequential, wait_reason="plan_review", context=context, reason_code="dependencies_changes")
    return Outcome("passed", "当前已安装软件依赖未见冲突，所用索引中的更新候选可完成依赖解析；不证明软件功能或未来安装计划兼容",
                   context=context, reason_code="dependencies_ok")


def compatibility(inputs, previous):
    env = inputs.value("environment")
    if env and env["kind"] in {"container", "wsl"}:
        return Outcome("not_applicable", "此处驱动信息不能验证宿主机；当前规则只检查真实主机或虚拟机中的设备",
                       reason_code="compatibility_guest")
    data = inputs.value("checks.drivers")
    bindings, loaded = inputs.value("drivers.bindings"), inputs.value("drivers.modules")
    kernel, secure = inputs.value("kernel"), inputs.value("drivers.secure_boot")
    if not env or data is None or bindings is None or loaded is None or kernel is None:
        return Outcome("unknown", "缺少驱动匹配所需信息", "补充设备、模块和当前内核信息后重查", reason_code="compatibility_missing")
    problems, pending, gaps, verified, details = [], [], [], [], []
    if data["kernel"] != kernel["release"]:
        gaps.append("kernel:changed_during_collection")
    for name, info in data["modules"].items():
        if not info["readable"]:
            gaps.append(name + ":module_file_unreadable")
            continue
        builtin = info["filename"] == "(builtin)"
        running = loaded.get(name)
        if not builtin and not running:
            gaps.append(name + ":loaded_state_unknown")
        if not builtin:
            vermagic = info["vermagic"].split()
            if not vermagic:
                gaps.append(name + ":kernel_metadata_missing")
            elif vermagic[0] != kernel["release"]:
                problems.append(name + ":kernel_mismatch")
            else:
                verified.append(name)
        else:
            verified.append(name)
        if running:
            for field in ("version", "srcversion"):
                if info[field] and running.get(field) and info[field] != running[field]:
                    pending.append(name)
                    break
            if running.get("state") != "Live":
                gaps.append(name + ":module_not_live")
        if not builtin and secure and secure["enabled"] and not info["signer"]:
            gaps.append(name + ":signature_missing")
        missing_firmware = [f["name"] for f in info["firmware_files"] if f["present"] is not True]
        if missing_firmware:
            # Declared firmware can be for another device revision or an optional
            # alternative. Absence alone is never called a hardware fault.
            gaps.append(name + ":firmware_selection_unverified")
        details.append({"module": name, "signer_present": bool(info["signer"]),
                        "signature_trust_verified": False, "firmware_unconfirmed": missing_firmware})
    for device, binding in bindings.items():
        module = binding.get("module")
        if not module:
            continue
        info = data["modules"].get(module, {})
        alias = data["device_aliases"].get(device)
        if info.get("readable") and (not alias or not any(fnmatch.fnmatchcase(alias, pattern) for pattern in info["alias"])):
            gaps.append(device + ":device_support_unverified")
    pci = inputs.value("hardware.pci")
    if pci is None or inputs.value("hardware.usb") is None:
        gaps.append("device_inventory_incomplete")
    for device, info in (pci or {}).items():
        if int(info["class"], 16) >> 16 in {2, 3, 4} and not bindings.get("pci:" + device, {}).get("driver"):
            gaps.append("pci:" + device + ":no_bound_driver")
    if data["nvidia_api"]["status"] == "failed":
        problems.append("nvidia:management_api")
    elif data["nvidia_api"]["status"] == "unavailable":
        gaps.append("nvidia:management_api_unavailable")
    if secure is None:
        gaps.append("secure_boot_unknown")
    next_kernel = inputs.value("kernel.next_boot")
    context = {"verified_modules": verified, "problems": problems, "pending_modules": sorted(set(pending)),
               "unverified": gaps, "module_details": details, "next_boot_verified": False,
               "next_boot_kernel": next_kernel, "nvidia_api": data["nvidia_api"]}
    if problems:
        if problems == ["nvidia:management_api"] and data["nvidia_api"].get("error") == "driver_library_mismatch":
            return Outcome("failed", "NVIDIA 管理接口明确报告驱动与配套库版本不一致",
                           "核对正在运行的驱动与磁盘上的组件版本，再安排适用的生效和复查步骤",
                           subjects=("nvidia",), context=context, reason_code="compatibility_library_mismatch")
        return Outcome("failed", "磁盘上的驱动与当前内核不匹配，或 NVIDIA 管理接口测试失败；具体失败见逐项证据",
                       "先核对失败路径、驱动版本和安装来源，再制定维护计划", subjects=tuple(problems), context=context, reason_code="compatibility_failed")
    if pending:
        return Outcome("pending", "部分正在运行的驱动与磁盘上的版本不同，尚未验证切换后的效果",
                       "核对下次启动内核和签名条件，安排重启后复查", subjects=tuple(sorted(set(pending))),
                       wait_reason="driver_activation", context=context, reason_code="compatibility_pending")
    if gaps or not verified:
        return Outcome("unknown", "已核对可读的设备匹配标识、当前内核和驱动文件；仍有支持关系或固件选择未确认",
                       "按未确认项补充设备用途、固件和支持证据", subjects=tuple(gaps), context=context, reason_code="compatibility_partial")
    return Outcome("passed", "本次已绑定模块的设备标识与当前内核版本检查通过；不证明全部固件、签名信任、下次启动或软件用途兼容",
                   context=context, reason_code="compatibility_ok")


def hardware(inputs, previous):
    env = inputs.value("environment")
    if not env:
        return Outcome("unknown", "缺少运行环境信息，无法确定设备测试的适用范围", reason_code="hardware_missing")
    if env["kind"] in {"container", "wsl"}:
        return Outcome("not_applicable", "来宾环境的图形测试不能验证宿主机屏幕、声音和输入设备", reason_code="hardware_guest")
    data = inputs.value("checks.hardware")
    if data is None:
        return Outcome("unknown", "本次没有取得设备测试结果", "补充设备功能测试", reason_code="hardware_missing")
    confirmations = data["confirmations"]
    failed = [name for name, row in confirmations.items() if row["result"] == "failed"]
    if data["graphics"]["status"] == "failed":
        failed.append("graphics_render")
    context = {**data, "manual_required": [name for name in ("display", "audio", "input") if name not in confirmations]}
    if failed:
        return Outcome("failed", "绘制测试失败或用户确认设备使用有异常", "根据失败项目检查对应设备和驱动路径",
                       subjects=tuple(failed), context=context, reason_code="hardware_failed")
    if context["manual_required"] or data["unbound_confirmations"]:
        return Outcome("pending", "自动绘制测试已有结果；屏幕显示、声音和输入仍需实际使用确认",
                       "请实际检查屏幕显示、播放声音、键盘与鼠标，并分别记录结果",
                       subjects=tuple(context["manual_required"]), wait_reason="user_verification", context=context, reason_code="hardware_manual")
    graphics = data["graphics"]
    display_used = confirmations["display"]["result"] != "not_applicable"
    if display_used and (graphics["status"] != "passed" or graphics.get("software", True)):
        return Outcome("unknown", "人工使用结果已记录，但自动测试未验证硬件图形绘制路径",
                       "核对图形库、运行环境和实际使用的显卡后复查", context=context, reason_code="hardware_partial")
    return Outcome("passed", "列出的自动测试和人工使用确认已完成；仅适用于记录的环境与设备范围",
                   context=context, reason_code="hardware_ok")


def updates(inputs, previous):
    data = inputs.value("checks.updates")
    context = {"candidates": data["candidates"], "candidate_count": len(data["candidates"]),
               "refresh_status": data["refresh_status"], "refresh_error": data["refresh_error"],
               "security_candidate_count": sum(any(s.endswith("-security") for s in c["origins"]) for c in data["candidates"])}
    if data["unsafe_options"]:
        return Outcome("failed", "部分软件源允许跳过来源或有效期检查，不能据此确认更新可信",
                       "核对并修正这些软件源的信任设置，再重新验证", subjects=tuple(sorted({x["file"] for x in data["unsafe_options"]})),
                       context=context, reason_code="updates_unsafe")
    if data["refresh_status"] == "failed":
        is_failure = data["refresh_error"] in {"signature", "date", "source_unavailable"}
        return Outcome("failed" if is_failure else "unknown", "联网核实软件源未成功；失败原因已分类保留，缓存不能代替本次核实",
                       "按来源签名、日期或网络问题补充检查后重试", context=context,
                       reason_code="updates_source_failed" if is_failure else "updates_network")
    if data["refresh_status"] != "verified":
        return Outcome("unknown", "已分析本地缓存中的更新候选，但未联网确认来源签名、索引有效期与最新内容",
                       "运行 inspect --online，在临时目录核实软件源和更新", context=context, reason_code="updates_cached")
    if (not data["sources"] or not data["metadata_complete"] or any(not s["apt_trusted"] for s in data["sources"])
            or any(not c["apt_trusted"] for c in data["candidates"])):
        return Outcome("unknown", "软件源索引不完整或信任状态未确认，不能给出完整更新结论",
                       "核对启用的软件源及本机架构对应索引", context=context, reason_code="updates_incomplete")
    if data["candidates"]:
        return Outcome("pending", "通过来源核实的索引中有可用更新，尚未安装；是否更新仍需结合变更清单和用户用途",
                       "审查更新清单、依赖变更和支持范围后形成维护计划",
                       subjects=tuple(c["package"] for c in data["candidates"]), wait_reason="update_plan", context=context, reason_code="updates_available")
    return Outcome("passed", "本次已核实的软件源索引中，没有比已安装版本更新的候选；不代表无漏洞或所有软件仍受支持",
                   context=context, reason_code="updates_current")


def configs(inputs, previous):
    data = inputs.value("checks.configs")
    failures = list(data["syntax_errors"])
    failures += [row["unit"] for row in data["units"] if row["load_state"] in {"error", "bad-setting"}]
    reload_units = [row["unit"] for row in data["units"] if row["needs_reload"]]
    # systemd can flag every unit after its unit-file search path changes. This
    # is one reload requirement, not evidence of hundreds of edited/broken files.
    pending = ["systemd:daemon_reload"] if reload_units else []
    unknown = list(data["read_errors"]) + list(data["unverified_files"])
    verified = 0
    for row in data["sysctl"]:
        if row["read_status"] == "read":
            # Whitespace, leading signs and leading zeroes are not differences.
            configured = [int(v) for v in row["configured"].split()]
            effective = [int(v) for v in row["effective"].split()]
            if configured != effective:
                pending.append(row["key"])
            else:
                verified += 1
        elif row["read_status"] in {"missing", "no_match"} and row["optional"]:
            continue
        else:
            unknown.append(row["key"])
    for row in data["units"]:
        if row["load_state"] not in {"loaded", "masked", "not-found", "error", "bad-setting", "merged"}:
            unknown.append(row["unit"])
        elif row["load_state"] == "loaded" and not row["needs_reload"]:
            verified += 1
    context = {"verified_count": verified, "invalid": failures, "not_effective": pending,
               "reload_units": reload_units, "unverified": unknown}
    if failures:
        return Outcome("failed", "部分配置语法无法解析，或系统单元报告配置加载错误", "核对具体文件与目标版本支持的写法，再制定修改计划",
                       subjects=tuple(failures), context=context, reason_code="configs_invalid")
    if pending:
        if pending == ["systemd:daemon_reload"]:
            return Outcome("pending", "系统服务管理器报告需要重新加载配置；不据此推断每个单元都被修改或损坏",
                           "核对系统单元配置变化及重新加载的影响，再决定是否执行", subjects=tuple(pending),
                           wait_reason="configuration_activation", context=context, reason_code="configs_reload")
        return Outcome("pending", "部分设置文件与当前生效状态不同，或系统仍在使用旧的单元配置",
                       "核实差异是否有意保留及重新加载的影响，再决定如何生效",
                       subjects=tuple(pending), wait_reason="configuration_activation", context=context, reason_code="configs_pending")
    if unknown or not verified:
        return Outcome("unknown", "已核对支持的配置；部分文件格式、读取结果或生效状态尚不能验证",
                       "为未覆盖的配置补充对应程序与版本的检查方法", subjects=tuple(unknown), context=context, reason_code="configs_partial")
    return Outcome("passed", "支持的数字类 sysctl 设置与当前值一致，已读取的系统单元没有报告配置加载错误或等待重新加载",
                   context=context, reason_code="configs_ok")
