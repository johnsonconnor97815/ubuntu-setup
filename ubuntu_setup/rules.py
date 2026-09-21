"""Versioned, side-effect-free checks over explicitly declared observations."""

from copy import deepcopy
from dataclasses import dataclass, field
import json
import re
from typing import Callable

from .model import DataError, SCOPES, now

RESULTS = {"passed", "failed", "unknown", "pending", "not_applicable"}


@dataclass(frozen=True)
class Outcome:
    result: str
    reason: str
    next_step: str = ""
    subjects: tuple = ()
    wait_reason: str = ""
    context: dict = field(default_factory=dict)
    reason_code: str = ""


@dataclass(frozen=True)
class Rule:
    check_id: str
    label: str
    version: str
    input_scopes: tuple
    required_scopes: tuple
    applicability: str
    pass_condition: str
    limits: str
    basis_refs: tuple
    evaluate: Callable
    driver_related: bool = False
    implemented: bool = True

    def __post_init__(self):
        if not isinstance(self.check_id, str) or not self.check_id or not isinstance(self.version, str) or not self.version or not callable(self.evaluate):
            raise ValueError("检查规则缺少编号、版本或实现")
        if (not set(self.input_scopes) <= set(SCOPES)
                or len(set(self.input_scopes)) != len(self.input_scopes)
                or not set(self.required_scopes) <= set(self.input_scopes)):
            raise ValueError("检查规则声明了无效输入范围")

    @property
    def invalidation_scopes(self):
        # Unknown config impact is conservatively rechecked. Driver-package
        # heuristics are only invalidation hints, never compatibility evidence.
        extra = ("boot",) if self.driver_related else ()
        return tuple(sorted(set(self.input_scopes) | {"os", "environment", "configs"} | set(extra)))

    def describe(self):
        return {"check_id": self.check_id, "label": self.label, "rule_version": self.version,
                "kind": "check", "input_schema_version": 1, "output_schema_version": 1,
                "implementation_status": "implemented" if self.implemented else "not_implemented",
                "input_scopes": list(self.input_scopes), "required_scopes": list(self.required_scopes),
                "applicability": self.applicability, "pass_condition": self.pass_condition,
                "limitations": self.limits, "basis_refs": list(self.basis_refs),
                "invalidation_scopes": list(self.invalidation_scopes),
                "recheck_on_driver_packages": self.driver_related,
                "side_effects": [], "requires_privilege": False, "network_access": False,
                "failure_behavior": "缺少必要观察或规则执行出错时记未知；继续独立检查，不自动修复",
                "retry_condition": "补齐缺失观察、修复规则或相关条件改变后重新检查"}


class Inputs:
    """A rule cannot silently read undeclared observations or alter its snapshot."""

    def __init__(self, rule, observations):
        self._observations = {s: deepcopy(observations[s]) for s in rule.input_scopes}

    def value(self, scope):
        item = self._observations[scope]
        return item["value"] if item["status"] == "observed" else None


def run_rule(rule, snapshot, previous=None, *, checked_at=None):
    observations = snapshot["observations"]
    unavailable = [{"scope": s, "status": observations[s]["status"], "reason": observations[s]["reason"]}
                   for s in rule.input_scopes if observations[s]["status"] != "observed"]
    missing = [item for item in unavailable if item["scope"] in rule.required_scopes]
    prior = deepcopy(previous or {})
    error = None
    if missing:
        outcome = Outcome("unknown", "缺少必要观察：" + "、".join(item["scope"] for item in missing),
                          "根据缺失原因补充相应只读采集，再重新检查",
                          context=prior.get("context", {}), reason_code="missing_inputs")
    else:
        try:
            outcome = rule.evaluate(Inputs(rule, observations), prior)
            if (not isinstance(outcome, Outcome) or outcome.result not in RESULTS
                    or not isinstance(outcome.reason, str) or not outcome.reason
                    or not isinstance(outcome.next_step, str) or not isinstance(outcome.context, dict)
                    or not isinstance(outcome.wait_reason, str)
                    or not isinstance(outcome.reason_code, str)
                    or not isinstance(outcome.subjects, tuple)
                    or not all(isinstance(s, str) for s in outcome.subjects)):
                raise ValueError("检查规则返回无效结果")
            if not rule.implemented and outcome.result != "unknown":
                raise ValueError("尚未实现的检查不能产生确定结论")
            json.dumps(outcome.context, allow_nan=False)
        except Exception as exc:
            # Isolate failed rules, including programming errors. Never serialize
            # exception text, which could include private command/file contents.
            error = {"code": "rule_error", "type": type(exc).__name__}
            outcome = Outcome("unknown", "检查规则执行失败，不能判断目标状态",
                              "修复并验证该规则后重新检查；其他独立检查可继续",
                              context=prior.get("context", {}), reason_code="rule_error")
    record = {"check_id": rule.check_id, "label": rule.label, "rule_version": rule.version,
              "implementation_status": "implemented" if rule.implemented else "not_implemented",
              "result": outcome.result, "reason": outcome.reason, "next_step": outcome.next_step,
              "reason_code": outcome.reason_code,
              "input_scopes": list(rule.input_scopes), "checked_at": checked_at or now(),
              "validity": "current", "subjects": list(outcome.subjects),
              "wait_reason": outcome.wait_reason, "context": deepcopy(outcome.context),
              "observation_refs": [observations[s]["observation_id"] for s in rule.input_scopes],
              "evidence_refs": [{"snapshot_id": snapshot["snapshot_id"], "scope": s,
                                 "observation_id": observations[s]["observation_id"],
                                 "observed_at": observations[s]["observed_at"],
                                 "collector_version": observations[s]["collector_version"],
                                 "status": observations[s]["status"],
                                 "coverage": deepcopy(observations[s]["coverage"])} for s in rule.input_scopes],
              "unavailable_inputs": unavailable, "basis_refs": list(rule.basis_refs)}
    if error:
        record["error"] = error
    return record


def _platform(inputs, previous):
    info, env = inputs.value("os"), inputs.value("environment")
    if (info["id"], info["version_id"], info["architecture"], env["kind"]) == ("ubuntu", "24.04", "x86_64", "physical"):
        return Outcome("passed", "符合 Ubuntu 24.04 / x86_64 真实主机的首批采集验证范围；不表示全部功能兼容", reason_code='platform_supported')
    return Outcome("unknown", "超出首批实测的系统、架构或运行环境组合", "核对该环境的采集方法与适用范围", reason_code='platform_unverified')


def _environment(inputs, previous):
    env = inputs.value("environment")
    label = {"physical": "真实主机", "vm": "虚拟机", "container": "容器", "wsl": "WSL（Windows 中的 Linux 环境）"}[env["kind"]]
    return Outcome("passed", f"本次环境：{label}；结论仅适用于当前可见环境", reason_code='environment_identified')


def _packages(inputs, previous):
    packages = inputs.value("packages.dpkg")
    broken = tuple(sorted(name for name, entry in packages.items()
                          if entry["status"] not in {"installed", "config-files", "not-installed"} or entry["error_flag"] != "ok"))
    return Outcome("failed" if broken else "passed",
                   f"发现 {len(broken)} 项未完成或异常包状态" if broken else "所读取的包状态未显示未完成安装；尚未验证依赖与软件功能",
                   "为异常包制定修复计划" if broken else "", subjects=broken, reason_code='packages_state')


def _dependencies(inputs, previous):
    from .check_rules import dependencies
    return dependencies(inputs, previous)


def _storage(inputs, previous):
    storage = inputs.value("storage")
    failed = storage["read_only"] or storage["available_bytes"] <= 0
    return Outcome("failed" if failed else "passed",
                   "根文件系统只读或可用空间耗尽" if failed else "根文件系统未报告只读且有可用空间；未判定任何安装计划的空间需求",
                   "实际写入前按具体计划检查目标路径、权限和空间", subjects=("/",) if failed else (), reason_code='storage_state')


def _reboot(inputs, previous):
    reboot, boot = inputs.value("reboot"), inputs.value("boot")
    context = previous.get("context", {})
    pending_boot = context.get("pending_boot_id")
    if reboot is None:
        return Outcome("unknown", "无法读取重启提示", "补充重启提示采集；保留此前的等待记录", context=context, reason_code='reboot_unreadable')
    if reboot["required_marker"]:
        return Outcome("pending", "检测到 reboot-required 标志，相关生效情况待重启验证",
                       "重启后检查实际内核、模块及设备功能", wait_reason="reboot",
                       context={"pending_boot_id": boot["id"] if boot else None}, reason_code='reboot_required')
    if "pending_boot_id" in context and (not boot or not pending_boot or boot["id"] == pending_boot):
        return Outcome("pending", "提示文件已消失，但未确认经历了所等待的重启，继续保留待验证",
                       "核实是否经历了所等待的重启，再检查相关功能", wait_reason="reboot", context=context, reason_code='reboot_unconfirmed')
    return Outcome("passed", "当前未检测到 reboot-required 标志；不据此宣称驱动或所有变更已生效", reason_code='no_reboot_marker')


def _modules(inputs, previous):
    modules = inputs.value("drivers.modules")
    return Outcome("passed", f"读取到 {len(modules)} 个动态模块；未验证签名、版本匹配或设备功能", reason_code='modules_read')


def _compatibility(inputs, previous):
    from .check_rules import compatibility
    return compatibility(inputs, previous)


def _hardware(inputs, previous):
    from .check_rules import hardware
    return hardware(inputs, previous)


def _services(inputs, previous):
    services = inputs.value("services")
    if any(entry.get("active") != "failed" for entry in services.values()):
        return Outcome("unknown", "失败服务观察中包含无法确认的状态", "重新读取失败服务状态，核对采集格式", reason_code='services_unrecognized')
    subjects = tuple(sorted(services))
    return Outcome("failed" if subjects else "passed",
                   f"发现 {len(subjects)} 个失败系统单元；尚未确定原因及对用户用途的影响" if subjects else "本次没有列出失败系统单元；未验证所有服务功能",
                   "按单元核对状态、必要日志和用户用途，再判断影响与修复方式" if subjects else "", subjects=subjects, reason_code='services_state')


def _updates(inputs, previous):
    from .check_rules import updates
    return updates(inputs, previous)


def _configs(inputs, previous):
    from .check_rules import configs
    return configs(inputs, previous)


def _dkms(inputs, previous):
    env = inputs.value("environment")
    if env is None:
        return Outcome("unknown", "无法确认 DKMS 记录与运行内核是否属于同一环境", "先补充运行环境识别", reason_code='dkms_environment_unknown')
    if env["kind"] in {"container", "wsl"}:
        return Outcome("not_applicable", "当前规则不适用于容器或 WSL 的宿主内核；其 DKMS 记录不能作为宿主验证", reason_code='dkms_guest')
    dkms = inputs.value("drivers.dkms")
    if dkms is None:
        return Outcome("unknown", "无法读取 DKMS 登记记录；工具缺失不代表没有外部驱动", "核实缺失原因及实际驱动安装方式", reason_code='dkms_unreadable')
    entries = dkms["entries"]
    if not entries:
        return Outcome("not_applicable", "成功读取的 DKMS 清单为空，没有可供此规则核对的登记模块；其他驱动仍需单独检查", reason_code='dkms_empty')
    kernel, os_info = inputs.value("kernel"), inputs.value("os")
    if not kernel or not os_info:
        return Outcome("unknown", "当前内核或架构信息不足，不能匹配 DKMS 记录", "补充运行内核和架构信息", reason_code='dkms_system_unknown')
    parsed, seen = [], set()
    for line in entries:
        # Recognize only the supported unannotated output form. Warnings,
        # unfamiliar states and duplicate/conflicting rows remain unknown.
        match = re.fullmatch(r"([^/,\s]+)/([^/,\s]+)(?:, ([^,\s]+), ([^,:\s]+))?: (added|built|installed)", line)
        if not match:
            return Outcome("unknown", "DKMS 记录包含警告、未知状态或无法完整解析的行", "核对 DKMS 版本及原始记录，再补充解析规则", reason_code='dkms_unrecognized')
        name, version, release, arch, status = match.groups()
        if (status in {"built", "installed"}) != (release is not None):
            return Outcome("unknown", "DKMS 状态缺少匹配的内核字段或字段组合无法识别", "核对 DKMS 版本及原始记录", reason_code='dkms_fields_unknown')
        key = (name, version, release, arch)
        if key in seen:
            return Outcome("unknown", "DKMS 清单包含重复或相互矛盾的登记记录", "重新采集并核对重复记录", reason_code='dkms_duplicate')
        seen.add(key)
        parsed.append((name, version, release, arch, status))
    current = [row for row in parsed if row[2:4] == (kernel["release"], os_info["architecture"])]
    incomplete = tuple(sorted(f"{name}/{version}" for name, version, _, _, state in current if state != "installed"))
    if incomplete:
        return Outcome("failed", "当前内核和架构有 DKMS 模块仅完成构建，未登记为已安装；是否需要安装须结合设备用途判断",
                       "核对这些模块是否为当前设备所需，再制定有依据的维护计划", subjects=incomplete, reason_code='dkms_uninstalled')
    # All registered module/version pairs need a current-kernel record for this
    # narrow check to pass. Absence may be intentional, so it is not a failure.
    unmatched = {(row[0], row[1]) for row in parsed} - {(row[0], row[1]) for row in current}
    if unmatched:
        return Outcome("unknown", "部分 DKMS 模块没有当前内核和架构的安装记录；不能推断缺失是否构成故障",
                       "核对设备所需模块及目标内核，区分旧内核留存与实际缺口",
                       subjects=tuple(sorted(f"{name}/{version}" for name, version in unmatched)), reason_code='dkms_unmatched')
    return Outcome("passed", f"{len(current)} 个已登记 DKMS 模块有当前内核和架构的 installed 记录；未验证签名、加载、下次启动内核或设备功能", reason_code='dkms_installed')


PROTOTYPE = "docs/prototype.md"
DESIGN = "docs/inventory-and-health.md"
DKMS_MANUAL = "https://manpages.ubuntu.com/manpages/noble/en/man8/dkms.8.html"

# Versions change when semantics, required evidence or support scope changes.
# Reorganizing code alone does not change collector versions or machine facts.
RULES = (
    Rule("platform", "采集器首批验证范围", "2", ("os", "environment"), ("os", "environment"),
         "所有运行环境；仅已实测组合可以通过", "Ubuntu 24.04、x86_64、真实主机",
         "只说明采集方法的首批验证范围，不证明系统或驱动兼容", (PROTOTYPE,), _platform),
    Rule("environment", "运行环境识别", "1", ("environment",), ("environment",),
         "所有运行环境", "取得明确的运行环境类型", "来宾环境结果不能证明宿主状态", (PROTOTYPE,), _environment),
    Rule("packages.state", "已登记的软件包状态", "1", ("packages.dpkg",), ("packages.dpkg",),
         "能够读取 dpkg 登记状态的系统", "无未完成安装状态及异常错误标志",
         "残留配置不是未完成安装；未验证依赖与软件功能", (PROTOTYPE, "man:dpkg-query(1)"), _packages),
    Rule("packages.dependencies", "软件依赖与版本兼容性", "2", ("packages.dpkg", "sources.apt", "os", "checks.packages"), ("checks.packages",),
         "可读取 python3-apt、dpkg 数据库与 APT 索引的系统", "已安装依赖完整；候选更新可解析且不改动锁定包、不要求移除或降级",
         "只解析 APT/dpkg；缓存候选不保证新鲜；不验证应用功能、Snap、Flatpak 或任意新软件计划",
         ("https://apt-team.pages.debian.net/python-apt/library/apt_pkg.html",), _dependencies),
    Rule("storage.basic", "根文件系统基本条件", "1", ("storage",), ("storage",),
         "当前可见根文件系统", "未报告只读且可用空间大于零",
         "不证明具体安装计划空间充足，也不检查其他路径权限", (PROTOTYPE, "man:statvfs(3)"), _storage),
    Rule("reboot", "系统重启提示", "1", ("reboot", "boot"), (),
         "当前环境及此前等待记录", "没有当前提示，也没有尚未确认经历的重启等待",
         "提示消失或启动标识变化不能证明设备功能通过", (PROTOTYPE,), _reboot),
    Rule("drivers.modules", "模块清单读取", "1", ("drivers.modules", "kernel"), ("drivers.modules",),
         "能够读取动态模块清单的环境", "取得完整的本次模块清单",
         "不含内建模块，不证明签名、版本匹配或设备功能", (PROTOTYPE, "man:proc_modules(5)"), _modules, True),
    Rule("drivers.dkms.current", "当前内核的 DKMS 安装记录", "1", ("drivers.dkms", "kernel", "os", "environment"), (),
         "真实主机或虚拟机内可读取的 DKMS 登记模块；容器和 WSL 不适用此规则",
         "所有已登记模块版本都有当前内核和架构的 installed 记录，且清单完整可解析",
         "未安装工具记未知；无登记模块记不适用；缺少匹配记录记未知；仅 built 记该安装记录检查未通过；不验证设备功能",
         (DKMS_MANUAL, PROTOTYPE), _dkms, True),
    Rule("drivers.compatibility", "驱动与硬件兼容性", "2",
         ("hardware.pci", "hardware.usb", "drivers.bindings", "drivers.modules", "drivers.secure_boot", "drivers.dkms", "kernel", "kernel.next_boot", "environment", "checks.drivers"), (),
         "真实主机或虚拟机中已经绑定的 PCI/USB 模块", "当前内核与模块元数据匹配；设备标识匹配；无换版等待及必要证据缺口",
         "固件声明可有可选项；签名存在不等于可信；不核实引导选择、所有用户态库或厂商完整支持矩阵",
         ("man:modinfo(8)", DESIGN), _compatibility, True),
    Rule("hardware.function", "设备实际功能", "2",
         ("hardware.pci", "hardware.usb", "drivers.bindings", "drivers.modules", "kernel", "environment", "checks.hardware", "checks.configs", "packages.dpkg"), (),
         "真实主机或虚拟机中的图形与人工确认的显示、声音、输入", "所列绘制回读与实际使用确认通过，且确认仍匹配当前环境",
         "单像素绘制不覆盖所有显卡或性能；软件绘制不证明 GPU 可用；声音与输入不自动录制；确认失效后须重验",
         ("https://registry.khronos.org/EGL/sdk/docs/man/html/eglIntro.xhtml", DESIGN), _hardware, True),
    Rule("services", "失败系统服务清单", "2", ("services",), ("services",),
         "能够读取当前 systemd 系统单元失败清单的环境", "完整清单中没有失败单元",
         "失败仅说明单元状态；原因、用途影响及全部服务功能仍待核对", (PROTOTYPE, "man:systemctl(1)"), _services),
    Rule("updates", "必要更新与来源有效性", "2", ("metadata.apt", "sources.apt", "os", "checks.updates"), ("checks.updates",),
         "APT 配置中的软件源及已安装包；inspect --online 可在临时目录核实来源", "来源验证成功、索引完整且无可用较新候选",
         "离线缓存结果未知；不检查全部漏洞、发行版支持期限、手动安装软件或未启用的源",
         ("https://manpages.ubuntu.com/manpages/noble/en/man8/apt-get.8.html", "man:apt-secure(8)"), _updates),
    Rule("configs", "所监测配置的生效情况", "2", ("configs", "sources.apt", "checks.configs"), ("checks.configs",),
         "systemd 选择的 sysctl.d 数字设置和已加载系统单元", "支持的设置与当前数字值一致，且系统单元无加载错误或等待重载",
         "不支持的格式和任意额外配置文件为未知；不自动应用设置，不证明服务功能",
         ("https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html", "man:systemctl(1)"), _configs),
)


def registry(rules=None):
    selected = tuple(RULES if rules is None else rules)
    if any(not isinstance(rule, Rule) for rule in selected) or len({r.check_id for r in selected}) != len(selected):
        raise DataError("检测规则必须有效且编号唯一")
    return {r.check_id: r for r in selected}


def describe_rules(check_id=None):
    available = registry()
    if check_id is not None:
        if check_id not in available:
            raise DataError(f"不存在的检测规则：{check_id}")
        return [available[check_id].describe()]
    return [rule.describe() for rule in available.values()]
