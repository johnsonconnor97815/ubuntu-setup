"""Reviewed user-facing wording; independent of rule decisions and raw evidence.

Add wording by (check, reason_code, result), never by parsing translated prose.
A new reason without reviewed copy keeps its original result and a cautious
summary. Presentation changes do not invalidate machine observations.
"""

from collections import Counter
from dataclasses import dataclass


CONTENT_VERSION = "9"
CATEGORY_LABELS = {
    "failed": "发现问题", "pending": "尚待完成", "check_error": "检查程序出错",
    "unknown": "本次没查清", "not_implemented": "尚未提供检查",
    "passed": "此项未见异常", "info": "仅记录信息", "not_applicable": "本次不适用",
}
TITLES = {
    "platform": "系统信息能否读取",
    "environment": "本次检查的环境",
    "packages.state": "软件安装记录",
    "packages.dependencies": "软件之间是否冲突",
    "storage.basic": "系统盘的空间和写入限制",
    "reboot": "系统重启提示",
    "drivers.modules": "系统组件清单",
    "drivers.compatibility": "驱动与系统是否匹配",
    "hardware.function": "屏幕、声音和键鼠能否使用",
    "services": "后台任务是否报错",
    "updates": "可用的软件更新",
    "configs": "设置是否生效",
}
INFO_CHECKS = {"platform", "environment", "drivers.modules"}
DOMAIN_LABELS = {
    "system": "系统和基础环境",
    "software": "软件和更新",
    "hardware": "驱动和设备",
    "services": "后台任务和设置",
    "other": "其他检查",
}
DOMAIN_DESCRIPTIONS = {
    "system": "系统版本、磁盘空间和重启提示",
    "software": "已装软件、依赖关系和可用更新",
    "hardware": "驱动、屏幕、声音和键鼠",
    "services": "后台任务和系统设置",
    "other": "新增或尚未归类的检查",
}
DOMAIN_CHECK_IDS = {
    "platform": "system",
    "environment": "system",
    "storage.basic": "system",
    "reboot": "system",
    "packages.state": "software",
    "packages.dependencies": "software",
    "updates": "software",
    "drivers.modules": "hardware",
    "drivers.compatibility": "hardware",
    "hardware.function": "hardware",
    "services": "services",
    "configs": "services",
}


@dataclass(frozen=True)
class Message:
    summary: str
    impact: str = ""
    next_step: str = ""
    action_owner: str = "系统助手"


@dataclass(frozen=True)
class Explanation:
    title: str
    category: str
    summary: str
    impact: str
    next_step: str
    action_owner: str


# Counts refer to subjects from the assessment, not inferred causes.
MESSAGES = {
    ("platform", "platform_supported", "passed"): Message(
        "这类系统已经验证过信息读取方法。",
        "这项记录只说明读取方法的适用范围，软件和驱动是否兼容还需要另外检查。"),
    ("platform", "platform_unverified", "unknown"): Message(
        "这类系统上的信息读取方法尚未验证。",
        "这不能说明电脑有故障；其他机器的验证结果也不能直接套用。",
        "核实本机环境和读取方法，再继续检查。"),
    ("environment", "environment_identified", "passed"): Message(
        "已识别本次检查所在的环境，具体类型见下方电脑信息。",
        "结果只适用于本次能访问的环境；在虚拟环境中检查，不能证明外层电脑的状态。"),
    ("packages.state", "packages_state", "passed"): Message(
        "本次读取的软件安装记录中，没有发现未完成的安装或异常状态。",
        "这项只核对安装记录；软件所需组件和实际使用情况分别检查。"),
    ("packages.state", "packages_state", "failed"): Message(
        "发现 {count} 条软件安装记录未完成或状态异常。",
        "这些软件的使用可能受影响，具体影响还需要检查。",
        "核对这些软件的安装记录和相关软件，再制定修复计划。"),
    ("storage.basic", "storage_state", "passed"): Message(
        "系统盘还有剩余空间，系统没有把它标为“只能读取”。",
        "尚未测试实际写入，也没计算下一次安装需要多少空间。",
        "实际安装前，按计划核对保存位置、写入权限和所需空间。"),
    ("storage.basic", "storage_state", "failed"): Message(
        "系统盘被标为“只能读取”，或可用空间已经耗尽。",
        "这会限制写入。哪些操作受到影响，还要结合保存位置确认。",
        "查清具体原因，并按实际任务核对可用空间和写入条件。"),
    ("reboot", "reboot_unreadable", "unknown"): Message(
        "本次没能读取系统的重启提示。",
        "之前等待重启的记录仍保留，目前无法确认是否还需要重启。",
        "重新读取重启提示，并核对之前的等待记录。"),
    ("reboot", "reboot_required", "pending"): Message(
        "系统提示需要重启，哪些变更需要重启还没有查明。",
        "相关功能仍待重启后检查；不能承诺重启会解决其他异常。",
        "先查清提示来源，再与用户安排重启，之后复查相关功能。"),
    ("reboot", "reboot_unconfirmed", "pending"): Message(
        "重启提示已消失，但还没有确认完成了此前等待的重启。",
        "仍保留待验证状态，不能把提示消失当作功能已经正常。",
        "核实是否已经重启，再检查相关功能。"),
    ("reboot", "no_reboot_marker", "passed"): Message(
        "本次没有发现系统重启提示，也没有未确认的重启等待记录。",
        "这不能证明所有变更都已生效，或设备功能已经正常。"),
    ("drivers.modules", "modules_read", "passed"): Message(
        "已读取系统加载的功能组件清单，其中包含部分驱动。",
        "这项只确认清单已经读取；驱动匹配和设备使用情况见对应检查。"),
    ("services", "services_unrecognized", "unknown"): Message(
        "本次读到的后台运行状态无法确认。",
        "目前不能判断是否存在运行异常。",
        "重新读取状态，核对检查程序是否正确识别了记录。"),
    ("services", "services_state", "failed"): Message(
        "系统记录了 {count} 个后台项目的失败状态。后台项目是系统在后台运行或监视的功能。",
        "原因和使用影响还没有查明，也未确认这些记录是否来自同一个原因。",
        "查看这些项目的状态和日志，再判断原因与处理方法。"),
    ("services", "services_state", "passed"): Message(
        "本次可读取的系统后台项目中，没有列出失败记录。",
        "未检查全部用户的后台程序，也没有验证所有后台功能。"),
}
MESSAGES.update({
    ("packages.dependencies", "dependencies_broken", "failed"): Message(
        "有 {count} 个软件包缺少所需组件，或组件版本互相冲突。", "相关软件可能无法正常安装或使用。", "查清缺少或冲突的是哪些组件，再制定修复方案。"),
    ("packages.dependencies", "dependencies_empty", "unknown"): Message(
        "没有读到可核对的已安装软件。", "不能据此认定软件依赖正常。", "核实软件安装记录和本次检查环境。"),
    ("packages.dependencies", "dependencies_held", "unknown"): Message(
        "更新试算涉及已指定保持原版本的软件，方案需要重新核对。", "保持原版本的要求仍保留；未执行更新。", "保留版本要求，重新核对更新方案。"),
    ("packages.dependencies", "dependencies_conflict", "failed"): Message(
        "现有更新候选无法组成相互兼容的安装方案。", "这是更新方案的冲突，不能直接说明当前软件无法使用。", "查明冲突版本后重新制定方案。"),
    ("packages.dependencies", "dependencies_incomplete", "unknown"): Message(
        "已安装软件所需的组件未见冲突，但更新信息不完整。", "部分下载来源缺少软件清单，试算结果还不能作为完整更新方案。", "联网核对下载来源和软件清单，再重新检查。"),
    ("packages.dependencies", "dependencies_changes", "pending"): Message(
        "模拟更新需要移除或降级 {count} 个软件包。", "这些变化可能影响已有软件；目前只生成了清单。", "审查清单和用户用途，再决定维护方案。"),
    ("packages.dependencies", "dependencies_ok", "passed"): Message(
        "已安装软件所需的组件未见冲突，现有更新清单也能算出安装方案。", "仅核对系统登记的软件及其所需组件。软件能否实际使用、安装前的最新方案，仍需另外检查。"),
    ("drivers.compatibility", "compatibility_guest", "not_applicable"): Message(
        "当前环境不能用于验证外层电脑的驱动。", "需在目标电脑上运行这项检查。"),
    ("drivers.compatibility", "compatibility_missing", "unknown"): Message(
        "缺少设备或驱动信息，本次无法完成匹配检查。", "缺少信息不等于驱动损坏。", "补充设备、正在运行的系统核心版本和驱动信息。"),
    ("drivers.compatibility", "compatibility_failed", "failed"): Message(
        "驱动版本核对或读取 NVIDIA 显卡状态时发现异常。", "失败的是哪些检查、是否影响使用，需结合下方记录确认。", "查看具体错误和相关版本，再制定处理方案。"),
    ("drivers.compatibility", "compatibility_library_mismatch", "failed"): Message(
        "读取 NVIDIA 显卡状态失败：正在使用的驱动与配套软件版本不一致。", "屏幕是否正常显示、能否用显卡处理图形，还需要分别检查。", "核对正在使用和已经安装的驱动版本，再制定处理方案。"),
    ("drivers.compatibility", "compatibility_pending", "pending"): Message(
        "有 {count} 个驱动仍在运行旧版本，磁盘上的版本已经变化。", "新版本尚未完成实际使用验证。", "先核对重启后将使用的系统与驱动，再安排重启和复查。"),
    ("drivers.compatibility", "compatibility_partial", "unknown"): Message(
        "已有 {driver_count} 个驱动组件通过系统版本核对，其余适用条件仍未确认。", "部分设备运行文件尚未确认，可能只是其他型号才需要的文件；还不能判断故障。", "逐项核对设备型号及其需要的文件。"),
    ("drivers.compatibility", "compatibility_ok", "passed"): Message(
        "已检查的驱动与当前系统核心版本、设备标识相符。", "仍未证明全部固件选择、签名信任、重启后适配及所有软件用途正常。"),
    ("hardware.function", "hardware_missing", "unknown"): Message(
        "本次没能取得可用的设备测试结果。", "目前不能判断实际使用情况。", "补充目标环境和设备测试。"),
    ("hardware.function", "hardware_guest", "not_applicable"): Message(
        "当前环境的测试不能证明外层电脑的屏幕、声音和输入正常。", "需在实际使用这些设备的电脑上确认。"),
    ("hardware.function", "hardware_failed", "failed"): Message(
        "绘制测试或用户的实际使用检查发现异常。", "自动测试与用户反馈分别记录，具体设备见下方。", "按失败项目检查设备和驱动。"),
    ("hardware.function", "hardware_manual", "pending"): Message(
        "{graphics_result}；还有设备使用情况等待你确认。", "自动测试无法代替查看屏幕、听声音和实际使用键盘鼠标。",
        "按下方设备表确认尚未检查的项目，并把结果告诉助手。", "用户"),
    ("hardware.function", "hardware_partial", "unknown"): Message(
        "已记录你的使用反馈，但自动测试还没确认能否用显卡处理图形。", "电脑能生成测试画面，不代表显卡已经参与处理。", "核对测试实际使用的设备和相关软件，再重新测试。"),
    ("hardware.function", "hardware_ok", "passed"): Message(
        "列出的自动测试和用户实际使用确认已完成。", "只适用于这次记录的设备和环境；设备、驱动、配置或启动状态变化后重新确认。"),
    ("updates", "updates_unsafe", "failed"): Message(
        "部分软件下载来源允许跳过来源或有效期检查。", "这些来源中的更新还不能确认可信；未执行安装。", "核对对应下载来源的设置，再验证更新。"),
    ("updates", "updates_source_failed", "failed"): Message(
        "有软件下载来源未通过本次联网核实。", "可能是来源真实性未通过验证、清单过期或地址已不可用，具体原因见详情。", "查看失败原因，核对相应下载来源后重试。"),
    ("updates", "updates_network", "unknown"): Message(
        "本次联网检查未完成，无法确认更新清单是否完整。", "网络或读取失败不能直接认定电脑有故障。", "核对网络与软件源连接，再重新检查。"),
    ("updates", "updates_cached", "unknown"): Message(
        "本机保存的清单中有 {candidate_count} 项可能的更新，尚未联网核实。", "清单可能不完整或已过期，还不能据此决定安装。", "联网核对来源和最新软件清单，再判断适用更新。"),
    ("updates", "updates_incomplete", "unknown"): Message(
        "软件下载清单不完整，或尚未确认下载来源可信。", "目前无法给出完整更新结论。", "核对启用的下载来源及其软件清单。"),
    ("updates", "updates_available", "pending"): Message(
        "已联网核实下载来源，找到 {count} 项可用的软件更新。", "尚未安装；一项更新可能是应用，也可能是它需要的组件。是否更新还要核对对已有软件的影响。", "核对更新清单和对已有软件的影响，再制定更新方案。"),
    ("updates", "updates_current", "passed"): Message(
        "本次已核实的软件源中，没有比已安装版本更新的候选。", "这不代表没有安全漏洞，也不覆盖所有手动安装的软件或软件支持期限。"),
    ("configs", "configs_invalid", "failed"): Message(
        "有 {count} 处设置无法解析，或系统报告配置加载错误。", "涉及的设置可能没有按预期加载，具体文件见下方。", "核对设置写法与本机软件版本，再制定修改计划。"),
    ("configs", "configs_pending", "pending"): Message(
        "有 {count} 项设置与当前生效状态不同，或仍在等待重新加载。", "可能是尚未生效，也可能是临时调整，需要先查清；本次未应用设置。", "核对具体差异及重新加载的影响，再决定如何处理。"),
    ("configs", "configs_reload", "pending"): Message(
        "系统提示需要重新读取后台运行设置。", "目前只确认有这一项提示，具体哪些功能受影响还需检查。本次没有应用设置或重启后台程序。", "查清哪些设置变了，以及重新读取后会影响什么，再决定如何处理。"),
    ("configs", "configs_partial", "unknown"): Message(
        "已核对支持的设置，部分文件或设置项仍无法验证。", "额外监测文件发生变化，不等于其内容正确或已经生效。", "为未覆盖的设置补充对应程序的检查方法。"),
    ("configs", "configs_ok", "passed"): Message(
        "已核对的数字设置与当前值一致，也未读到后台运行设置的加载错误或重新读取提示。", "只覆盖已列出的设置和后台项目，仍需另外确认相关功能是否可用。"),
})
UNIMPLEMENTED = {
    "packages.dependencies": Message(
        "当前程序尚未提供软件兼容性检查。",
        "还不能判断软件版本能否配合使用，以及安装或升级会影响哪些已有软件。",
        "有具体软件需求后，核对版本、来源和相关软件的变化。"),
    "drivers.compatibility": Message(
        "当前程序尚未提供完整的驱动适配检查。",
        "读到驱动名称不代表它适合这台电脑，设备能否正常使用也还没有验证。",
        "结合设备型号与用途，检查驱动和系统是否匹配，以及重启前后的实际功能。"),
    "hardware.function": Message(
        "当前程序尚未提供设备实际功能检查。",
        "显示、音频等设备是否正常工作，还没有验证；虚拟环境中的结果也不能代表外层电脑。",
        "按用户需要使用的设备安排功能检查。"),
    "updates": Message(
        "当前程序尚未提供适用更新检查。",
        "还没有联网核实更新、来源签名和支持期限，仅凭本机保存的信息不能确认这些情况。",
        "按具体维护目标查证适用更新，再核对对现有软件的影响。"),
    "configs": Message(
        "当前程序尚未提供设置生效检查。",
        "即使记录了设置文件的变化，也不能证明设置写得正确或已经生效。",
        "针对需要调整的设置，补充相应版本的检查方法。"),
}


def category(check):
    state = check["result"]
    if state == "unknown":
        if check.get("error"):
            return "check_error"
        if check.get("implementation_status") == "not_implemented":
            return "not_implemented"
    if state == "passed" and check["check_id"] in INFO_CHECKS:
        return "info"
    return state if state in CATEGORY_LABELS else "unknown"


def domain(check):
    return DOMAIN_CHECK_IDS.get(check["check_id"], "other")


def domain_summary(checks):
    totals = counts(checks)
    statuses = []
    if totals["failed"]:
        statuses.append(f'{totals["failed"]} 项发现问题')
    if totals["pending"]:
        statuses.append(f'{totals["pending"]} 项待确认')
    if totals["check_error"]:
        statuses.append(f'{totals["check_error"]} 项检查没完成')
    unclear = totals["unknown"] + totals["not_implemented"]
    if unclear:
        statuses.append(f'{unclear} 项没查清')
    if statuses:
        tone = next((state for state in ("failed", "pending", "check_error", "unknown")
                     if totals[state]), "unknown")
        return tone, " · ".join(statuses)
    return "passed", "暂未发现问题"


def explain(check):
    """Present the recorded decision; never run a check or interpret raw prose."""
    group = category(check)
    code = check.get("reason_code", "")
    message = MESSAGES.get((check["check_id"], code, check["result"])) if isinstance(code, str) else None
    if group == "check_error":
        message = Message("检查程序运行出错，本次没能得出结论。",
                          "这是检查没有完成，不能据此认定电脑有故障。",
                          "修复检查程序后重新检查；其他独立检查可以继续。", "程序维护者")
    elif group == "not_implemented":
        message = UNIMPLEMENTED.get(check["check_id"], Message(
            "当前程序尚未提供这项检查。", "本次没有这方面的检查结论。",
            "补充检查方法后再进行验证。", "程序维护者"))
    elif code == "missing_inputs" and check["result"] == "unknown":
        message = Message("缺少本次检查需要的信息，这项没能查清。",
                          "信息没读到，不能直接判断为电脑故障。",
                          "核对缺失原因，补充读取后重新检查。")
    if message is None:
        summaries = {
            "passed": "原记录已通过所列检查条件，具体范围请查看技术详情。",
            "failed": "这项检查记录了异常，具体内容请查看技术详情。",
            "pending": "这项检查仍在等待验证，具体内容请查看技术详情。",
            "not_applicable": "原记录表明这项检查不适用，具体条件请查看技术详情。",
        }
        message = Message(summaries.get(check["result"], "这项检查尚未得出结论，具体原因请查看技术详情。"),
                          "当前没有对应的详细说明，不能据此扩大判断范围。",
                          "核对原始记录，并补充相应说明。")
    context = check.get("context", {})
    graphics = context.get("graphics", {})
    graphics_result = ("自动测试已生成并读取测试画面" if graphics.get("status") == "passed" and not graphics.get("software", True)
                       else "自动测试能生成画面，但还没确认显卡能否处理图形" if graphics.get("status") == "passed"
                       else "本次自动图形测试未完成")
    return Explanation(
        TITLES.get(check["check_id"], "其他检查"), group,
        message.summary.format(count=len(check.get("subjects", [])), candidate_count=context.get("candidate_count", 0),
                               graphics_result=graphics_result, driver_count=len(context.get("verified_modules", []))),
        message.impact, message.next_step, message.action_owner if message.next_step else "")


def counts(checks):
    return Counter(category(check) for check in checks)


def conclusion(checks):
    """Summarize recorded check outcomes, never infer overall system health."""
    totals = counts(checks)
    if totals["failed"]:
        text = f'{totals["failed"]} 项检查发现异常'
        if totals["pending"]:
            text += f'，{totals["pending"]} 项等待验证'
        return text
    if totals["pending"]:
        return f'{totals["pending"]} 项检查仍在等待验证'
    if totals["check_error"]:
        return "部分检查程序出错，结论尚不完整"
    if totals["unknown"]:
        return "部分信息未能查清，结论尚不完整"
    if totals["passed"]:
        return "已检查的项目未见异常，检查范围仍有限"
    return "现有检查不足以判断系统状态"


@dataclass(frozen=True)
class Highlight:
    check_id: str
    state: str
    title: str
    detail: str


@dataclass(frozen=True)
class ReadingPlan:
    headline: str
    summary: str
    tone: str
    next_owner: str
    next_step: str
    user_title: str
    user_step: str
    user_tasks: tuple = ()
    user_check_id: str = ""


# Friendly identification only: these names never prove driver or GPU failure.
# Verified against the corresponding NVIDIA unit descriptions, 2026-09-19.
NVIDIA_REFRESH_UNITS = {"nvidia-cdi-refresh.path", "nvidia-cdi-refresh.service"}
COVERAGE_NAMES = {
    "packages.dependencies": "软件之间是否冲突", "drivers.compatibility": "驱动与系统是否匹配",
    "hardware.function": "设备实际功能", "updates": "可用更新", "configs": "设置是否生效",
}


def _nvidia_refresh(check):
    subjects = set(check.get("subjects", []))
    return bool(subjects) and subjects <= NVIDIA_REFRESH_UNITS


def highlight(check):
    """A short finding for the front page, with uncertainty kept beside it."""
    check_id, state = check["check_id"], check["result"]
    code = check.get("reason_code")
    count = len(check.get("subjects", []))
    messages = {
        ("drivers.compatibility", "compatibility_library_mismatch", "failed"): (
            "NVIDIA 驱动与配套软件版本不一致",
            "驱动是让系统使用显卡的软件。本次读取显卡状态失败，显示和图形处理是否受影响还没确认。"),
        ("drivers.compatibility", "compatibility_failed", "failed"): (
            "驱动检查发现问题", "驱动版本核对或读取 NVIDIA 显卡状态时出错，具体使用影响还没确认。"),
        ("drivers.compatibility", "compatibility_pending", "pending"): (
            "部分驱动还在使用旧版本", f"{count} 个驱动的文件版本已变化，正在使用的仍是旧版本；新版本能否正常使用还没验证。"),
        ("configs", "configs_reload", "pending"): (
            "系统设置需要重新读取", "系统给出了重新读取后台运行设置的提示，具体使用影响还需检查。"),
        ("configs", "configs_pending", "pending"): (
            "部分设置还需要核对", f"{count} 项设置与当前状态不同，或等待重新读取；可能尚未生效，也可能是临时调整。"),
        ("configs", "configs_invalid", "failed"): (
            "部分设置无法正确读取", f"{count} 处设置无法解析，或系统报告加载错误；相关功能可能受影响。"),
        ("hardware.function", "hardware_manual", "pending"): (
            "设备使用情况等待确认", explain(check).summary),
        ("hardware.function", "hardware_failed", "failed"): (
            "设备使用或自动测试发现问题", "自动图形测试或用户的实际使用反馈有异常，具体设备和测试结果见记录。"),
        ("updates", "updates_available", "pending"): (
            f"有 {count} 项软件更新可评估", "已联网核实下载来源，尚未安装；还要核对更新对已有软件的影响。"),
        ("updates", "updates_unsafe", "failed"): (
            "部分软件下载来源需要核实", "设置允许跳过来源或有效期检查，这些来源中的更新还不能确认可信。"),
        ("updates", "updates_source_failed", "failed"): (
            "软件下载来源未通过核实", "本次联网核实失败；具体原因可能涉及来源真实性、清单日期或地址是否可用。"),
        ("packages.dependencies", "dependencies_changes", "pending"): (
            "更新方案会移除软件或改用旧版", f"试算涉及移除或降低 {count} 个软件包的版本，尚未执行；对已有软件的影响需先核对。"),
        ("packages.dependencies", "dependencies_broken", "failed"): (
            "部分软件缺少组件或版本冲突", f"涉及 {count} 个软件包，可能影响安装或使用。"),
        ("packages.dependencies", "dependencies_conflict", "failed"): (
            "现有更新无法组成兼容方案", "这是拟议更新之间的冲突，当前软件能否使用仍需另外检查。"),
        ("packages.state", "packages_state", "failed"): (
            "软件安装记录有异常", f"{count} 条记录显示安装未完成或状态异常；使用影响尚未查明。"),
        ("storage.basic", "storage_state", "failed"): (
            "系统盘的写入条件有问题", "系统盘被标为只能读取，或剩余空间已经耗尽；具体原因需继续核对。"),
        ("reboot", "reboot_required", "pending"): (
            "系统提示需要重启", "为什么需要重启还没查明；重启后仍要检查相关功能。"),
        ("reboot", "reboot_unconfirmed", "pending"): (
            "此前等待的重启还没有确认", "提示已消失，但尚未确认是否重启过；先核实，再判断下一步。"),
    }
    if (check_id, code, state) == ("services", "services_state", "failed"):
        title = "NVIDIA 后台任务报错" if _nvidia_refresh(check) else "系统后台任务报错"
        return Highlight(check_id, state, title,
                         f"记录中有 {count} 个失败项；原因和对使用的影响还没有查明。")
    title, detail = messages.get((check_id, code, state), (
        TITLES.get(check_id, "其他检查") + ("：发现问题" if state == "failed" else "：尚待完成"),
        "具体原因和影响尚未确认，请查看这项检查的原始记录。"))
    return Highlight(check_id, state, title, detail)


def attention_checks(checks):
    # Reading order, not an inferred severity score. Never truncate findings.
    priority = {"storage.basic": 0, "packages.state": 1, "packages.dependencies": 2,
                "drivers.compatibility": 3, "hardware.function": 4, "services": 5,
                "configs": 6, "reboot": 7, "updates": 8}
    return sorted((c for c in checks if c["result"] in {"failed", "pending"}),
                  key=lambda c: (c["result"] != "failed", priority.get(c["check_id"], 10), c["check_id"]))


def manual_confirmation(checks):
    return next((c for c in checks if (c["check_id"], c.get("reason_code"), c["result"]) ==
                 ("hardware.function", "hardware_manual", "pending")), None)


def reading_plan(checks):
    """Suggest who does what, without scheduling actions or changing decisions."""
    attention = attention_checks(checks)
    failed = [c for c in attention if c["result"] == "failed"]
    reboot = any((c["check_id"], c.get("reason_code")) == ("reboot", "reboot_required") for c in attention)
    unconfirmed = any((c["check_id"], c.get("reason_code")) == ("reboot", "reboot_unconfirmed") for c in attention)
    manual = manual_confirmation(checks)
    user_title = "暂时没有需要你执行的操作"
    user_step = "后续建议由助手继续核对，具体操作确定后再说明。"
    tasks, user_check_id = (), ""
    if manual:
        device_tasks = {"display": "屏幕：看看画面是否正常。", "audio": "声音：播放一段声音，确认能听到。",
                        "input": "键鼠：分别试用键盘和鼠标。"}
        tasks = tuple(text for device, text in device_tasks.items() if device in manual.get("subjects", []))
        user_title = "确认设备能否正常使用"
        user_step = "把结果告诉助手：正常、有什么问题，或本次不需要使用。"
        if not tasks:
            user_step = "本次反馈尚未对应到当前设备，请和助手核对后重新确认。"
        user_check_id = manual["check_id"]
    elif unconfirmed:
        user_title = "确认此前是否重启过"
        user_step = "告诉助手是否已经重启；目前还不能确定是否需要再次重启。"
    elif reboot:
        user_title = "原因查清后，再选择重启时间"
        user_step = "助手需要先查明哪些变更要求重启，再安排重启后的检查。"

    totals = counts(checks)
    owner = "系统助手"
    if failed:
        first = failed[0]
        item = highlight(first)
        headline, summary, tone = item.title, item.detail, "failed"
        if len(failed) == 2:
            summary += "另需排查：" + highlight(failed[1]).title + "。"
        elif len(failed) > 2:
            summary += f"另有 {len(failed) - 1} 项检查发现问题，见下方。"
        step = explain(first).next_step or "核对异常记录，查明原因后制定处理方案。"
        if any(c["check_id"] == "services" and c.get("reason_code") == "services_state" for c in failed[1:]):
            step += "另查后台任务报错的原因。"
    elif attention:
        first = attention[0]
        item = highlight(first)
        headline, summary, tone = item.title, item.detail, "pending"
        step = explain(first).next_step or "核对尚待完成的事项，再确定处理步骤。"
        if first is manual:
            summary = "还有设备的实际使用结果需要你确认，具体项目见下方。"
            if manual.get("context", {}).get("graphics", {}).get("software"):
                summary += "是否能用显卡处理图形也还没确认。"
            step = "记录你的实际使用结果，继续完成设备检查。"
        elif unconfirmed and first["check_id"] == "reboot":
            headline = "先确认此前的重启是否完成"
    elif totals["check_error"]:
        headline, summary, tone = "部分检查没能完成", "检查程序出错，相关结果目前无法判断。", "unknown"
        owner, step = "程序维护者", "修复出错的检查，再重新运行。"
    elif totals["unknown"] or totals["not_implemented"]:
        headline, summary, tone = "部分检查还没有结论", "还缺少检查信息或检查方法，目前不能判断这些项目。", "unknown"
        step = "补齐缺失信息和检查方法，再继续检查。"
    elif totals["passed"]:
        headline, summary, tone = "已检查的项目暂未发现问题", "结论只适用于本次列出的检查范围，实际使用情况仍需另行验证。", "passed"
        step = "继续验证需要使用的软件和设备。"
    else:
        headline, summary, tone = "现有检查还不足以判断系统状态", "目前没有足够的功能检查结果。", "unknown"
        step = "补充适用的功能检查。"
    return ReadingPlan(headline, summary, tone, owner, step, user_title, user_step, tasks, user_check_id)


def coverage_notes(checks):
    """Keep unresolved areas visible, without presenting them as more faults."""
    notes = []
    for group, prefix in (("check_error", "检查程序出错"),
                          ("unknown", "还没查清"), ("not_implemented", "尚未提供检查")):
        names = [COVERAGE_NAMES.get(c["check_id"], TITLES.get(c["check_id"], "其他检查"))
                 for c in checks if category(c) == group]
        if names:
            notes.append(prefix + "：" + "、".join(names) + "。")
    return notes
