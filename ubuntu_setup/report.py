"""Human and machine reports derived from the same observations and checks."""

from collections import Counter
from datetime import datetime
import base64
import hashlib
import html
import json
from pathlib import Path
import re
from string import Template
from urllib.parse import quote

from . import report_text


LABELS = {"passed": "通过所列检查", "failed": "异常", "unknown": "未知", "pending": "待验证", "not_applicable": "不适用"}
OBSERVATION_LABELS = {"observed": "已读取", "unknown": "未读到信息", "not_applicable": "本次不适用"}
SCOPE_LABELS = {
    "os": "系统版本与架构", "environment": "运行环境", "resources": "处理器与内存",
    "storage": "系统盘空间", "kernel": "当前运行的内核", "kernel.next_boot": "下次启动的内核",
    "boot": "本次启动标识", "packages.dpkg": "发行版登记的软件包", "packages.snap": "Snap 软件",
    "packages.flatpak.system": "Flatpak 软件（系统范围）", "packages.flatpak.user": "Flatpak 软件（当前用户）",
    "sources.apt": "软件源配置摘要", "metadata.apt": "本地软件索引", "hardware.pci": "PCI 设备（如显卡、网卡）",
    "hardware.usb": "USB 设备", "drivers.bindings": "设备与驱动的对应关系",
    "drivers.modules": "已加载的内核模块", "drivers.secure_boot": "启动签名检查状态",
    "drivers.dkms": "外部驱动构建记录", "reboot": "重启提示", "services": "失败系统服务", "configs": "额外监测的配置",
    "checks.packages": "软件依赖与更新模拟", "checks.drivers": "设备、内核和驱动文件核对",
    "checks.hardware": "自动绘制测试与人工使用确认", "checks.updates": "更新候选与软件源核实",
    "checks.configs": "设置文件与生效状态核对",
}
CHANGE_LABELS = {"added": "新增", "changed": "变化", "not_observed": "本次未检测到",
                 "removed_from_inventory": "不再出现在该清单", "observation_unavailable": "本次无法确认",
                 "observation_restored": "恢复采集", "coverage_changed": "采集范围改变"}


def escape(value):
    value = re.sub(r"[\x00-\x1f\x7f]", " ", str(value))
    value = value.replace("\\", "\\\\").replace("|", "\\|").replace("`", "\\`").replace("<", "&lt;").replace(">", "&gt;")
    return value.replace("[", "\\[").replace("]", "\\]")


def build_result(snapshot, assessment, changes, invalidations, recovered, report_path):
    root = Path(report_path).parent.parent.parent
    return {"schema_version": 1, "run_id": snapshot["run_id"], "machine_id": snapshot["machine_id"],
            "snapshot_id": snapshot["snapshot_id"], "assessment_id": assessment["assessment_id"],
            "snapshot_path": str(root / f"inventory/snapshots/{snapshot['snapshot_id']}.json"),
            "assessment_path": str(root / f"assessments/{assessment['assessment_id']}.json"),
            "rule_versions": assessment["rule_versions"], "rule_changes": assessment["rule_changes"],
            "source_kind": snapshot["source_kind"], "captured_at": snapshot["captured_at"],
            "report_path": str(report_path), "report_format": "html",
            "report_content_version": report_text.CONTENT_VERSION,
            "observation_counts": dict(Counter(o["status"] for o in snapshot["observations"].values())),
            "check_counts": dict(Counter(c["result"] for c in assessment["checks"])),
            "observations": {s: {"status": o["status"], "reason": o["reason"], "coverage": o["coverage"]}
                             for s, o in snapshot["observations"].items()},
            "checks": assessment["checks"], "changes": changes, "invalidated_checks": invalidations,
            "recovered_runs": recovered, "limitations": assessment["limitations"]}


def _h(value):
    return html.escape(str(value), quote=True)


def _anchor(scope):
    return "observation-" + re.sub(r"[^a-zA-Z0-9_-]", "-", scope)


def _display_time(value):
    try:
        return datetime.fromisoformat(value).astimezone().strftime("%Y-%m-%d %H:%M:%S（本机时间）")
    except ValueError:
        return value


def _badge(status, *, observation=False):
    labels = OBSERVATION_LABELS if observation else report_text.CATEGORY_LABELS
    state = status if status in labels else "unknown"
    return f'<span class="badge {state}">{_h(labels[state])}</span>'


def _json_detail(value):
    return '<pre>' + _h(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False)) + '</pre>'


def _small_table(headings, rows):
    return ('<div class="table-wrap"><table><thead><tr>' + ''.join('<th scope="col">' + _h(h) + '</th>' for h in headings) +
            '</tr></thead><tbody>' + ''.join('<tr>' + ''.join('<td>' + _h(cell) + '</td>' for cell in row) + '</tr>' for row in rows) + '</tbody></table></div>')


def _extended_details(check, snapshot):
    """Readable evidence for new checks; keep raw JSON in the technical appendix."""
    context = check.get("context", {})
    check_id = check["check_id"]
    if check_id == "packages.dependencies" and "installed_count" in context:
        actions = context.get("actions", [])
        parts = ['<p>已核对 ' + _h(context["installed_count"]) + ' 个已安装软件包。更新模拟使用' +
                 ('本次联网取得的索引' if context.get("metadata_mode") == "online" else '本地缓存索引') + '。</p>']
        if actions:
            names = {"install": "新增安装", "upgrade": "升级", "downgrade": "降级", "remove": "移除"}
            totals = Counter(a["action"] for a in actions)
            summary = '、'.join(names[k] + ' ' + str(totals[k]) + ' 项' for k in names if totals[k])
            parts.append('<details><summary>查看模拟变更清单：' + _h(summary) + '</summary><p>以下仅为模拟，没有执行安装。执行前仍须重新核对。</p>' +
                         _small_table(("软件包", "拟议动作", "当前版本", "候选版本"),
                                      [(a["package"], names[a["action"]], a["from"] or '—', a["to"] or '—') for a in actions]) + '</details>')
        if context.get("kept_back"):
            parts.append('<p>另有 ' + str(len(context["kept_back"])) + ' 个更新候选未纳入这次模拟方案，原因需结合版本锁定、依赖或分批更新策略确认：' +
                         _h('、'.join(context["kept_back"])) + '。</p>')
        return ''.join(parts)
    if check_id == "drivers.compatibility" and "verified_modules" in context:
        parts = ['<p>' + _h(len(context["verified_modules"])) + ' 个模块通过当前内核版本核对；重启后将使用的内核与驱动尚未完成核实。</p>']
        loaded = snapshot["observations"].get("drivers.modules", {}).get("value") or {}
        disk = (snapshot["observations"].get("checks.drivers", {}).get("value") or {}).get("modules", {})
        rows = [(name, loaded.get(name, {}).get("version") or '未提供', entry.get("version") or '未提供')
                for name, entry in disk.items() if entry.get("readable") and (entry.get("version") or loaded.get(name, {}).get("version"))]
        if rows:
            parts.append('<details><summary>查看运行中与磁盘上的驱动版本</summary>' + _small_table(("驱动", "正在运行的版本", "磁盘上的版本"), rows) + '</details>')
        return ''.join(parts)
    if check_id == "hardware.function" and "graphics" in context:
        graphics = context["graphics"]
        automatic = ('通过；使用软件绘制，尚未证明显卡加速' if graphics.get("software") else '绘制和像素回读通过') if graphics["status"] == "passed" else ('绘制测试失败' if graphics["status"] == "failed" else '未能完成测试')
        rows = [("离屏绘制（不打开窗口）", automatic)]
        labels = {"display": "屏幕显示", "audio": "播放声音", "input": "键盘与鼠标"}
        states = {"passed": "用户确认可用", "failed": "用户确认有异常", "not_applicable": "用户确认本次不需要"}
        for name, label in labels.items():
            confirmation = context.get("confirmations", {}).get(name)
            result = states[confirmation["result"]] if confirmation else '等待实际使用确认'
            if name in context.get("expired_confirmations", []):
                result = '环境已经变化，原确认失效，需重新检查'
            rows.append((label, result))
        result = _small_table(("测试内容", "本次结果"), rows)
        if graphics.get("renderer"):
            result += '<p>绘制测试使用：' + _h(graphics["renderer"]) + '。</p>'
        if context.get("unbound_confirmations"):
            result += '<p>本次提交的反馈没有绑定到当前环境：相关条件已变化或未能完整读取，请按本次报告重新确认。</p>'
        return result
    if check_id == "updates" and "refresh_status" in context:
        errors = {"signature": "来源签名未通过", "date": "索引已过期或日期不符", "source_unavailable": "软件源或发布文件不可用",
                  "network": "网络连接或证书连接检查失败", "process_incomplete": "检查进程未完成或超时", "refresh_failed": "软件源刷新失败"}
        parts = []
        if context.get("refresh_error") in errors:
            parts.append('<p>本次未完成的原因：' + _h(errors[context["refresh_error"]]) + '。本次结论没有使用旧缓存冒充联网结果。</p>')
        candidates = context.get("candidates", [])
        if candidates:
            parts.append('<details><summary>查看 ' + str(len(candidates)) + ' 个更新候选</summary>' +
                         _small_table(("软件包", "已安装", "候选版本", "备注"),
                                      [(c["package"], c["installed"], c["candidate"], '已锁定版本' if c["held"] else '尚未安装') for c in candidates]) + '</details>')
        return ''.join(parts)
    if check_id == "configs" and "verified_count" in context:
        parts = ['<p>已有 ' + _h(context["verified_count"]) + ' 个设置或单元通过本项核对。' +
                 ('另有 ' + str(len(context.get("unverified", []))) + ' 项尚未查清。' if context.get("unverified") else '') + '</p>']
        data = snapshot["observations"].get("checks.configs", {}).get("value") or {}
        pending = set(context.get("not_effective", []))
        rows = [(r["key"], r["configured"], r["effective"]) for r in data.get("sysctl", []) if r["key"] in pending]
        if rows:
            parts.append(_small_table(("设置", "文件中的值", "当前生效的值"), rows))
        if context.get("reload_units"):
            parts.append('<p>重新加载配置的提示由系统服务管理器给出，不能据此判断每个服务的配置都被修改。</p>')
        return ''.join(parts)
    return ''


def _check_card(check, snapshot):
    explanation = report_text.explain(check)
    pieces = [f'<article id="check-{_h(check["check_id"])}" class="check {explanation.category}" data-status="{_h(check["result"])}" '
              f'data-category="{explanation.category}" data-check-id="{_h(check["check_id"])}">',
              '<div class="check-head"><h3>' + _h(explanation.title) + '</h3>' + _badge(explanation.category) + '</div>',
              '<p>' + _h(explanation.summary) + '</p>']
    if explanation.impact:
        pieces.append('<p class="impact"><strong>影响与限制：</strong>' + _h(explanation.impact) + '</p>')
    pieces.append(_extended_details(check, snapshot))
    if explanation.next_step:
        pieces.append('<div class="next"><strong>建议下一步 · 由 ' + _h(explanation.action_owner) +
                      ' 处理</strong>' + _h(explanation.next_step) + '</div>')
    pieces += ['<details class="check-evidence"><summary>查看技术详情与原始记录</summary><div class="evidence">',
               '<p>原检查名称：' + _h(check["label"]) + '</p>',
               '<p>原始结论（' + _h(LABELS.get(check["result"], check["result"])) + '）：' + _h(check["reason"]) + '</p>']
    if check.get("next_step"):
        pieces.append('<p>原始后续建议：' + _h(check["next_step"]) + '</p>')
    subjects = check.get("subjects", [])
    if subjects:
        pieces.append('<p>涉及的对象：</p><ul class="subjects">' +
                      ''.join('<li><code>' + _h(s) + '</code></li>' for s in subjects) + '</ul>')
    if check["check_id"] == "drivers.dkms.current":
        pieces.append('<p>DKMS 是用于构建和管理部分驱动模块的工具；这项只检查它登记的安装记录。</p>')
    pieces += ['<p>检查编号：<code>' + _h(check["check_id"]) + '</code> · 规则版本：' + _h(check["rule_version"]) + '</p>',
               '<p>原因编号：<code>' + _h(check.get("reason_code") or "旧记录未提供") + '</code></p>',
               '<p>判断时间：' + _h(check["checked_at"]) + '</p>']
    for item in check.get("unavailable_inputs", []):
        pieces.append('<p>未取得的信息：' + _h(SCOPE_LABELS.get(item["scope"], item["scope"])) + ' — ' + _h(item["reason"]) + '</p>')
    for scope in check["input_scopes"]:
        obs = snapshot["observations"][scope]
        pieces.append('<p><a href="#' + _anchor(scope) + '">' + _h(SCOPE_LABELS[scope]) + '</a> · ' +
                      _h(OBSERVATION_LABELS[obs["status"]]) + ' · ' + _h(obs["observed_at"]) + '</p>')
    for basis in check.get("basis_refs", []):
        pieces.append('<p>规则依据：<code>' + _h(basis) + '</code></p>')
    if check.get("error"):
        pieces.append('<p>检查程序错误：' + _h(check["error"].get("code", "")) + ' / ' + _h(check["error"].get("type", "")) + '</p>')
    if check.get("context") and check["check_id"] in {"packages.dependencies", "drivers.compatibility", "hardware.function", "updates", "configs"}:
        pieces.append('<details><summary>逐项结果与待确认内容</summary>' + _json_detail(check["context"]) + '</details>')
    pieces.append('</div></details></article>')
    return ''.join(pieces)


def _ordered_checks(checks):
    order = {state: index for index, state in enumerate(report_text.CATEGORY_LABELS)}
    return sorted(checks, key=lambda c: order[report_text.category(c)])


def _results_table(checks):
    """Keep every recorded check in the optional, script-independent overview."""
    rows = []
    for check in _ordered_checks(checks):
        explanation = report_text.explain(check)
        rows.append('<tr data-result-id="' + _h(check["check_id"]) + '"><th scope="row"><a class="evidence-link" href="#' +
                    quote('check-' + check["check_id"], safe='') + '" aria-label="查看' + _h(explanation.title) + '的依据">' +
                    _h(explanation.title) + '</a></th><td>' + _badge(explanation.category) + '</td><td>' +
                    _h(explanation.summary) + '</td></tr>')
    if not rows:
        return '<p>本次没有可列出的检查结果。</p>'
    return ('<div class="table-wrap"><table class="results-table"><caption>共 ' + str(len(checks)) +
            ' 项。<span class="no-print">点击检查项目可查看依据。</span>仅记录信息不代表功能验证通过。</caption>' +
            '<thead><tr><th scope="col">检查项目</th><th scope="col">结果</th><th scope="col">本次发现</th></tr></thead>' +
            '<tbody>' + ''.join(rows) + '</tbody></table></div>')


def _check_sections(checks, snapshot):
    ordered = _ordered_checks(checks)
    groups = (
        ("attention", [c for c in ordered if report_text.category(c) in {"failed", "pending", "check_error", "unknown"}]),
        ("unimplemented", [c for c in ordered if report_text.category(c) == "not_implemented"]),
        ("completed", [c for c in ordered if report_text.category(c) in {"passed", "info", "not_applicable"}]),
    )
    pieces = []
    for name, items in groups:
        if not items:
            continue
        cards = '<div class="checks">' + ''.join(_check_card(c, snapshot) for c in items) + '</div>'
        heading = {"attention": "异常、等待验证与未完成的检查", "unimplemented": "程序尚未提供的检查",
                   "completed": "基础检查与信息记录"}[name]
        pieces.append('<div class="result-group"><h3 class="group-title">' + heading + '</h3>' + cards + '</div>')
    return ''.join(pieces)


def _highlights(checks):
    manual = report_text.manual_confirmation(checks)
    remaining = [c for c in report_text.attention_checks(checks) if c is not manual]
    sections = []
    for state, label, group_id in (("failed", "已发现的问题", "priority-issues"),
                                    ("pending", "后续检查和维护", "maintenance")):
        items = [c for c in remaining if c["result"] == state]
        if not items:
            continue
        rows = []
        for check in items:
            item, explanation = report_text.highlight(check), report_text.explain(check)
            rows.append('<li class="focus-item ' + state + '" data-attention-id="' + _h(item.check_id) +
                        '"><div class="focus-copy"><h4>' + _h(item.title) + '</h4><p>' + _h(item.detail) + '</p>' +
                        ('<p class="finding-next"><strong>建议' + _h(explanation.action_owner) + '：</strong>' +
                         _h(explanation.next_step) + '</p>' if explanation.next_step else '') +
                        '</div><a class="focus-link evidence-link" href="#' + quote('check-' + item.check_id, safe='') +
                        '" aria-label="查看' + _h(item.title) + '的记录">查看记录<span aria-hidden="true"> →</span></a></li>')
        sections.append('<section class="finding-group ' + state + '" id="' + group_id + '" aria-labelledby="' +
                        group_id + '-heading"><h3 id="' + group_id + '-heading">' + label + '<span>' + str(len(items)) +
                        ' 项检查</span></h3><ul class="focus-list">' + ''.join(rows) + '</ul></section>')
    return ''.join(sections) or '<p class="quiet">本次没有其他已记录的问题或维护安排。</p>'


def _coverage(checks):
    items = [c for c in _ordered_checks(checks) if report_text.category(c) in {"unknown", "check_error", "not_implemented"}]
    if not items:
        return ''
    rows = []
    for check in items:
        explanation = report_text.explain(check)
        rows.append('<li><span class="coverage-state">' + _h(report_text.CATEGORY_LABELS[explanation.category]) +
                    '</span><a class="evidence-link" href="#' + quote('check-' + check['check_id'], safe='') + '">' +
                    _h(explanation.title) + '</a><p>' + _h(explanation.summary) + '</p></li>')
    return ('<aside id="coverage" class="coverage-note" aria-labelledby="coverage-heading"><h3 id="coverage-heading">'
            '这些检查还没有结论</h3><ul>' + ''.join(rows) + '</ul><p class="footnote">'
            '缺少信息或检查没完成，不能据此认定电脑有故障。</p></aside>')


def _observation_details(scope, observation):
    status, value = observation["status"], observation["value"]
    if status != "observed":
        description = "原因见详情"
    elif scope == "configs" and value == {}:
        description = "本次未额外指定要关注的设置文件"
    elif scope.startswith(("packages.", "hardware.")) or scope in {"drivers.modules", "services"}:
        description = f"{len(value)} 条记录"
    else:
        description = "本次信息已保存"
    return ('<details class="observation" id="' + _anchor(scope) + '"><summary>' +
            _h(SCOPE_LABELS[scope]) + ' ' + _badge(status, observation=True) +
            '<span class="meta">' + _h(description) + '</span></summary>' +
            ('<p>' + _h(observation["reason"]) + '</p>' if observation["reason"] else '') +
            '<p class="meta">读取时间：' + _h(observation["observed_at"]) +
            ' · 采集程序版本：' + _h(observation["collector_version"]) + '</p>' +
            '<p class="meta">读取范围：' + _h('；'.join(observation["coverage"])) + '</p>' +
            '<p class="meta">记录编号：<code>' + _h(observation["observation_id"]) + '</code></p>' +
            _json_detail(value) + '</details>')


def _change_table(changes):
    rows = []
    for change in changes:
        rows.append('<tr><td>' + _h(SCOPE_LABELS.get(change["scope"], change["scope"])) +
                    '</td><td><code>' + _h(change["subject"]) + '</code></td><td>' +
                    _h(CHANGE_LABELS.get(change["kind"], change["kind"])) +
                    '</td><td><details><summary>查看变化前后</summary>' +
                    _json_detail(change) + '</details></td></tr>')
    return ('<div class="table-wrap"><table><caption>本次记录的变化</caption><thead><tr><th scope="col">范围</th><th scope="col">对象</th><th scope="col">变化</th><th scope="col">依据</th></tr></thead><tbody>' +
            ''.join(rows) + '</tbody></table></div>')


def render(snapshot, result):
    """Render one offline HTML file; all observed strings are escaped as text."""
    observations = snapshot["observations"]

    def value(scope):
        item = observations[scope]
        return item["value"] if item["status"] == "observed" else {}

    os_info, resources, storage = value("os"), value("resources"), value("storage")
    system = " ".join(str(os_info.get(k, "未读到")) for k in ("id", "version_id"))
    environment = {"physical": "本机系统", "vm": "虚拟机（软件模拟的电脑）",
                   "container": "容器（隔离的运行环境）", "wsl": "WSL（Windows 内的 Linux 环境）"}
    memory = f'{resources["memory_bytes"] / (1024 ** 3):.1f} GiB' if "memory_bytes" in resources else "未读到"
    disk = (f'可用 {storage["available_bytes"] / (1024 ** 3):.1f} GiB / 总计 {storage["total_bytes"] / (1024 ** 3):.1f} GiB'
            if "available_bytes" in storage else "未读到")
    secure_boot = value("drivers.secure_boot").get("enabled")
    package_count = len(value("packages.dpkg")) if observations["packages.dpkg"]["status"] == "observed" else None
    facts = [
        ("操作系统", system), ("本次检查的环境", environment.get(value("environment").get("kind"), "未读到")),
        ("处理器", resources.get("cpu_model", "未读到")), ("内存容量", memory), ("系统盘空间", disk),
    ]
    technical_facts = [
        ("处理器类型（架构）", os_info.get("architecture", "未读到")),
        ("内核（系统核心）版本", value("kernel").get("release", "未读到")),
        ("软件包登记数量", f"{package_count} 条，包含卸载后保留设置的记录等状态" if package_count is not None else "未读到"),
        ("安全启动（Secure Boot，启动时检查签名）", "已启用" if secure_boot is True else "未启用" if secure_boot is False else "未读到"),
        ("下次启动的内核版本", value("kernel.next_boot").get("release", "尚未确认")),
    ]
    totals = report_text.counts(result["checks"])
    stats = ''.join(f'<li>{_h(label)} <strong>{totals[state]}</strong></li>'
                    for state, label in report_text.CATEGORY_LABELS.items() if totals[state])
    changes = result["changes"]
    if not changes:
        change_html = '<p class="muted">' + ("这是首次记录，没有上次的信息可比较。" if snapshot.get("previous_snapshot_id") is None
                                           else "可比较的信息与上次一致；未读到的信息仍无法比较。") + '</p>'
    else:
        change_html = '<p>记录到 ' + str(len(changes)) + ' 项变化，相关检查已按本次信息重新判断。</p>'
        change_html += '<details><summary>查看变化记录</summary>' + _change_table(changes[:40])
        if len(changes) > 40:
            change_html += f'<details><summary>展开其余 {len(changes) - 40} 项变化</summary>' + _change_table(changes[40:]) + '</details>'
        change_html += '</details>'
    rule_html = ""
    if result.get("rule_changes"):
        kinds = {"added": "新增", "updated": "更新", "removed": "移除"}
        rule_html = '<details class="panel"><summary>检查方法的变化（技术记录）</summary><ul>' + ''.join(
            '<li><code>' + _h(c["check_id"]) + '</code>：' + _h(kinds[c["kind"]]) +
            '（' + _h(c["before"] if c["before"] is not None else "无") + ' → ' +
            _h(c["after"] if c["after"] is not None else "无") + '）</li>' for c in result["rule_changes"]) + '</ul></details>'
    invalidations = ""
    if result["invalidated_checks"]:
        names = {c["check_id"]: report_text.explain(c).title for c in result["checks"]}
        invalidations = '<details class="panel"><summary>哪些旧结论需要重新检查</summary><p>仍在使用的检查方法已重新运行，本次结果见上方。</p><ul>' + ''.join(
            '<li>' + _h(names.get(c["check_id"], c["check_id"])) + '：' +
            _h('、'.join(c["invalidated_by"])) + '</li>' for c in result["invalidated_checks"]) + '</ul></details>'
    records = ('<p>完整信息、检查结果和变化记录均保存在本机。下面的 JSON 文件供 Agent 或技术人员读取。</p><ul>' +
               '<li><a href="../../inventory/snapshots/' + quote(snapshot["snapshot_id"], safe="") + '.json">完整机器信息（JSON）</a></li>' +
               '<li><a href="../../assessments/' + quote(result["assessment_id"], safe="") + '.json">原始检查结果（JSON）</a></li>' +
               '<li><a href="changes.json">变化记录（JSON）</a></li></ul>')
    if result["recovered_runs"]:
        records += '<p>本次还核对了 ' + str(len(result["recovered_runs"])) + ' 项此前未完成的记录。</p>' + _json_detail(result["recovered_runs"])
    counts = result["observation_counts"]
    inventory_summary = ' · '.join(f'{OBSERVATION_LABELS[s]} {counts.get(s, 0)} 项' for s in ("observed", "unknown", "not_applicable"))
    template = Path(__file__).with_name("report_template.html").read_text(encoding="utf-8")
    script = re.search(r"<script>(.*?)</script>", template, re.S).group(1)
    digest = base64.b64encode(hashlib.sha256(script.encode("utf-8")).digest()).decode("ascii")

    def facts_html(items):
        return ''.join('<div><dt>' + _h(label) + '</dt><dd>' + _h(detail) + '</dd></div>' for label, detail in items)

    plan = report_text.reading_plan(result["checks"])
    manual = report_text.manual_confirmation(result["checks"])
    graphics = manual.get("context", {}).get("graphics", {}) if manual else {}
    user_note = ''
    if manual and (graphics.get("software", True) or graphics.get("status") != "passed"):
        user_note = '<p class="footnote">自动测试还没确认显卡能否处理图形，需由助手继续检查。</p>'
    return Template(template).substitute(
        script_hash=digest, content_version=report_text.CONTENT_VERSION,
        source_class="fixture" if snapshot["source_kind"] == "fixture" else "",
        source_label="模拟数据 · 不是本机检测" if snapshot["source_kind"] == "fixture" else "本机检查",
        headline=_h(plan.headline), summary=_h(plan.summary), summary_tone=plan.tone,
        agent_owner=_h(plan.next_owner), agent_step=_h(plan.next_step),
        user_title=_h(plan.user_title), user_step=_h(plan.user_step),
        user_tasks=('<ul class="user-tasks">' + ''.join('<li>' + _h(task) + '</li>' for task in plan.user_tasks) + '</ul>') if plan.user_tasks else '',
        user_attention=('data-attention-id="' + _h(plan.user_check_id) + '"') if plan.user_check_id else '',
        user_record=('<a class="evidence-link action-link" href="#' + quote('check-' + plan.user_check_id, safe='') +
                     '">查看设备测试记录 →</a>') if plan.user_check_id else '',
        user_note=user_note,
        highlights=_highlights(result["checks"]), coverage=_coverage(result["checks"]),
        total_checks=len(result["checks"]), total_changes=len(result["changes"]),
        captured_at=_h(_display_time(snapshot["captured_at"])), captured_at_raw=_h(snapshot["captured_at"]),
        system_label=_h(system), environment_label=_h(environment.get(value("environment").get("kind"), "未读到")),
        stats=stats, results_table=_results_table(result["checks"]),
        run_id=_h(snapshot["run_id"]),
        facts=facts_html(facts), technical_facts=facts_html(technical_facts),
        checks=_check_sections(result["checks"], snapshot), inventory_summary=_h(inventory_summary),
        observations=''.join(_observation_details(s, obs) for s, obs in observations.items()),
        changes=change_html, rule_changes=rule_html, invalidations=invalidations,
        limitations='<ul>' + ''.join('<li>' + _h(item) + '</li>' for item in result["limitations"]) + '</ul>',
        records=records, report_path=_h(result["report_path"]),
    )


def render_summary(result):
    plan = report_text.reading_plan(result["checks"])
    label = "模拟检查" if result["source_kind"] == "fixture" else "只读检查"
    lines = [f'{label}报告已保存：{result["report_path"]}',
             plan.headline,
             '建议下一步（尚未执行）：' + plan.next_owner + ' ' + plan.next_step,
             '你需要处理：' + plan.user_title + '。' + ' '.join(plan.user_tasks) + plan.user_step,
             result["browser_open"]["reason"]]
    return "\n".join(lines) + "\n"


def render_capabilities(result):
    lines = ["# 检测能力目录", "", f"程序版本：{result['program_version']}",
             "本命令仅说明能力，不采集目标系统，也不保存机器档案。", "",
             "| 检查编号 | 版本 | 名称 | 实现状态 |", "| --- | --- | --- | --- |"]
    for rule in result["checks"]:
        status = "已实现" if rule["implementation_status"] == "implemented" else "待实现，保留未知"
        lines.append(f"| {escape(rule['check_id'])} | {escape(rule['rule_version'])} | {escape(rule['label'])} | {status} |")
    for rule in result["checks"]:
        lines += ["", f"## {escape(rule['label'])}", "",
                  "- 适用条件：" + rule["applicability"],
                  "- 所需观察：" + "、".join(rule["input_scopes"]),
                  "- 通过条件：" + rule["pass_condition"],
                  "- 限制：" + rule["limitations"],
                  "- 依据：" + "、".join(rule["basis_refs"])]
    return "\n".join(lines) + "\n"
