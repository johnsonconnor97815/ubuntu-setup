"""Runnable inventory workflow with an explicitly confirmed cleanup command."""

import argparse
import json
import math
import os
from pathlib import Path
import shlex
import sys

from . import __version__
from .analysis import assess, compare, invalidate, make_snapshot
from .browser import open_report
from .collect import LocalProbe, collect, live_identity
from .disk_cleanup import (DEFAULT_BASE_URL, DEFAULT_MODEL, JevClient, create_plan,
                           DEFAULT_REVIEW_BASE_URL, DEFAULT_REVIEW_MODEL, LLMReviewClient,
                           default_roots, default_state_dir, execute_plan, resolve_cleanup_root)
from .improvements import validate_improvement
from .model import DataError, load_fixture, new_id, read_json
from .report import build_result, render, render_capabilities, render_summary
from .rules import describe_rules, registry
from .state import StateStore


def default_state_dir():
    configured = os.environ.get("XDG_STATE_HOME")
    if configured and not Path(configured).is_absolute():
        raise DataError("XDG_STATE_HOME 必须是绝对路径")
    root = Path(configured) if configured else Path.home() / ".local/state"
    return root / "ubuntu-setup/targets/local"


def inspect(args):
    rules = tuple(registry().values())
    source_kind = "fixture" if args.fixture else "live"
    if args.fixture:
        if not args.state_dir:
            raise DataError("模拟检查必须指定独立的 --state-dir")
        if args.watch_config or args.online or args.confirm_device or args.confirm_from:
            raise DataError("模拟检查只使用文件中的观察，不能同时指定 --watch-config、--online 或设备确认参数")
        token, observations = load_fixture(args.fixture)
        probe = None
    else:
        probe = LocalProbe(args.timeout)
        token = live_identity(probe)
        observations = None
    root = Path(args.state_dir).expanduser() if args.state_dir else default_state_dir()
    confirmations = {}
    if bool(args.confirm_device) != bool(args.confirm_from):
        raise DataError("记录实际使用结果时须同时指定 --confirm-from 报告编号和 --confirm-device")
    for value in args.confirm_device:
        device, separator, result = value.partition("=")
        if not separator or device not in {"display", "audio", "input"} or result not in {"passed", "failed", "not_applicable"} or device in confirmations:
            raise DataError("--confirm-device 格式为 display|audio|input=passed|failed|not_applicable，每项仅记录一次")
        confirmations[device] = result
    with StateStore(root) as store:
        machine_id = store.bind(source_kind, token)
        previous, previous_assessment, recovered = store.load_previous()
        confirmation_basis = None
        if confirmations:
            if previous is None or previous["run_id"] != args.confirm_from:
                raise DataError("确认所引用的报告不是当前最新报告；请先核对最新报告对应的设备")
            hardware = previous["observations"].get("checks.hardware", {}).get("value") or {}
            confirmation_basis = hardware.get("confirmation_fingerprint")
            if not confirmation_basis:
                raise DataError("所引用报告缺少绑定设备确认所需的信息；先补齐该报告中的缺失采集")
        known = store.last_known(previous)
        run_id = new_id()
        store.begin(run_id, previous, source_kind)
        if observations is None:
            observations = collect(probe, args.watch_config, online=args.online, confirmations=confirmations,
                                   previous=previous, target_id=machine_id, confirmation_basis=confirmation_basis)
        snapshot = make_snapshot(machine_id, run_id, source_kind, observations, previous)
        changes = compare(previous, snapshot, known)
        assessment = assess(snapshot, previous_assessment, rules=rules)
        invalidations = invalidate(previous_assessment, changes, rules=rules)
        result = build_result(snapshot, assessment, changes, invalidations, recovered, store.root / f"runs/{run_id}/report.html")
        report = render(snapshot, result)
        store.finish(snapshot, assessment, changes, invalidations, report)
    result["browser_open"] = ({"status": "disabled", "reason": "已按 --no-open 保存 HTML 报告，未自动打开"}
                              if args.no_open else open_report(result["report_path"]))
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) if args.format == "json" else render_summary(result))
    return 0


def capabilities(args):
    result = {"schema_version": 1, "program_version": __version__,
              "runtime": {
                  "minimum_python": "3.10",
                  "preflight": "./ubuntu-setup runtime status --format json",
                  "unavailable_exit_code": 3,
                  "repair_command": "swkit python configure --python 3.12",
                  "repair_side_effects": [
                      "安装用户态 uv 和 Python 3.12",
                      "缺少 curl 时经 apt 安装 curl 和 ca-certificates",
                      "调整 shell rc 中的 PATH 和 uv 补全",
                  ],
                  "repair_requires_network": True,
                  "repair_replaces_system_python": False,
                  "preflight_side_effects": [
                      "启动候选 Python 解释器读取版本",
                      "如已安装 uv，只读查询 uv 的 Python 安装目录",
                  ],
                  "network_access": False,
              },
              "agent_interface": {
                  "schema_version": 1,
                  "working_directory": "ubuntu-setup 仓库根目录",
                  "commands": {
                      "preflight": "./ubuntu-setup runtime status --format json",
                      "capabilities": "./ubuntu-setup capabilities --format json",
                      "inspect": "./ubuntu-setup inspect --format json --no-open",
                      "inspect_online": "./ubuntu-setup inspect --online --timeout 30 --format json --no-open",
                      "record_improvement": "./ubuntu-setup improvement --record <path> --state-dir <private-dir> --format json",
                      "plan_disk_cleanup": "./ubuntu-setup cleanup --state-dir <private-dir> --format json",
                      "execute_disk_cleanup": "./ubuntu-setup cleanup --delete --state-dir <private-dir> --plan-file <plan> --confirm <plan-id> --select <entry-id>",
                  },
                  "exit_codes": {
                      "0": "命令完成；inspect 仍须读取 checks、changes、rule_changes、agent_research_tasks 和 browser_open；cleanup 计划仍须读取 plan_path、report_path、summary 与每个条目的模型建议和风险",
                      "2": "检查或清理未完成；不得把不完整输出当成本次结果，原有记录保留",
                      "3": "运行时不可用；不得自动执行修复命令，需用户明确授权",
                      "130": "用户中断；保留现场并按用户指示继续",
                  },
                  "result_policy": [
                      "unknown 是有效结果，表示信息缺失或无法判断，不能解释为通过或失败",
                      "wait 是有效结果，表示需要等待条件或用户验证，不能跳过",
                      "browser_open.status 只说明浏览器打开请求的结果，不说明用户已阅读报告",
                      "agent_research_tasks 是宿主 Agent 的研究任务，不构成系统变更授权",
                      "cleanup 的 JEV 概率和独立 LLM 风险判断只是依据，不构成删除授权；必须由用户核对报告并明确选择条目 ID",
                  ],
                  "authorization": "inspect 与 capabilities 只读；improvement 仅写入指定私有状态目录；cleanup 计划会写入私有状态目录并访问 PackyApi 与复核 LLM，cleanup 执行只会永久删除用户明确选择且核对通过的条目；安装、移除、降级、修改配置、更新系统索引或执行修复都必须获得当前任务的明确授权",
              },
              "operations": [
                  {"id": "inspect", "invocation": "./ubuntu-setup inspect --format json",
                   "purpose": "采集当前运行环境并运行全部检测规则，保存带证据的报告",
                   "target": "当前运行环境；模拟检查显式指定 --fixture 和独立 --state-dir",
                   "side_effects": ["写入本工具的私有状态目录", "在现有图形库创建并销毁 1 像素离屏缓冲；不打开窗口", "--online 将软件索引下载到临时目录并清理", "保存 HTML 后请求默认浏览器打开；--no-open 可关闭"], "requires_privilege": False,
                   "network_access": False, "optional_network_access": "仅 --online；联系已配置的软件源，不修改系统索引",
                   "human_confirmation": "--confirm-from 最新报告编号和 --confirm-device 记录用户已实际验证的结果；采集复核环境变化后拒绝沿用",
                   "agent_output": "JSON 结果包含 agent_research_tasks；宿主 Agent 可用 LLM 和联网搜索复核冲突与稳定性，本程序不调用外部模型",
                   "exit_codes": {"0": "报告保存完成，须另读检查结果", "2": "检查未完成", "130": "用户中断"}},
                  {"id": "capabilities", "invocation": "./ubuntu-setup capabilities --format json",
                   "purpose": "查询检测规则的用途、输入、依据、版本和限制",
                   "side_effects": [], "requires_privilege": False, "network_access": False},
                  {"id": "improvement", "invocation": "./ubuntu-setup improvement --record <path> --state-dir <private-dir> --format json",
                   "purpose": "校验并保存问题案例、候选修改、验证与采用记录",
                   "side_effects": ["写入指定私有状态目录的 improvements/<case-id>/"], "requires_privilege": False, "network_access": False,
                   "exit_codes": {"0": "记录保存完成", "2": "记录校验或保存失败，原有记录保留"}},
                  {"id": "cleanup", "invocation": "./ubuntu-setup cleanup --state-dir <private-dir> --format json",
                   "purpose": "扫描缓存、临时目录和回收站中的旧条目，先用 PackyApi JEV 初筛，再用独立 LLM 评估风险并生成待选择报告",
                   "target": "当前用户的 XDG 缓存、/tmp 中属于当前用户的旧条目、回收站文件，以及显式指定的 --root 顶层条目",
                   "side_effects": ["计划阶段写入指定清理状态目录 plans/ 与 reports/", "计划阶段向 PackyApi JEV 发送条目相对路径、类型、大小和修改年龄，不发送文件内容", "计划阶段向独立复核 LLM 发送同样元数据，不发送文件内容", "保存 HTML 后请求默认浏览器打开；--no-open 可关闭", "执行阶段只永久删除用户选择且核对未变化的条目，不进入回收站"], "requires_privilege": False,
                   "network_access": True, "optional_network_access": "计划阶段调用 PackyApi JEV /v1/systemone 和 OpenAI 兼容复核 LLM /chat/completions",
                   "human_confirmation": "执行必须提供 --plan-file、--confirm <plan-id> 和至少一个 --select <entry-id>；执行前重新核对路径、类型、大小、mtime、inode 和目录总大小",
                   "agent_output": "JSON 计划包含 entries、jev_probability、llm_recommendation、risk_level、risk_score、summary、plan_path 和 report_path；Agent 必须完整展示路径与风险，不得代替用户选择",
                   "exit_codes": {"0": "计划生成或执行流程结束，仍须读取 summary 与逐项状态", "2": "扫描、模型请求、计划校验或执行失败"}}],
              "checks": describe_rules(args.check),
              "limitations": ["规则结果只适用于所引用观察的时间与范围",
                              "命令成功不等于系统稳定；本程序不提供安装或修复操作",
                              "agent_research_tasks 只是研究任务说明，不构成安装授权；cleanup 的 JEV 初筛和独立 LLM 风险判断不构成删除授权",
                              "能力目录与通用 Skill 提供首个 Agent 接入；MCP 接入和自动改进机制尚未实现"]}
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) if args.format == "json" else render_capabilities(result))
    return 0


def improvement(args):
    record = read_json(args.record)
    validate_improvement(record)
    with StateStore(Path(args.state_dir).expanduser()) as store:
        result = store.save_improvement(record)
    if args.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    else:
        print(f"案例：{result['case_id']}")
        print(f"版本：{result['revision']}")
        print(f"状态：{result['status']}")
        print(f"记录：{result['current_path']}")
    return 0


def cleanup(args):
    state_dir = Path(args.state_dir).expanduser() if args.state_dir else default_state_dir()
    if args.delete:
        if not args.plan_file or not args.confirm or not args.select:
            raise DataError("执行清理必须同时指定 --plan-file、--confirm <plan-id> 和至少一个 --select <entry-id>")
        result = execute_plan(state_dir=state_dir, plan_path=args.plan_file, confirm=args.confirm,
                              selected_ids=args.select)
    else:
        if args.plan_file or args.confirm or args.select:
            raise DataError("--plan-file、--confirm 和 --select 只能配合 --delete 使用")
        roots = default_roots()
        for root in args.root:
            roots.append(resolve_cleanup_root(root, "custom"))
        client = JevClient(
            api_key=os.environ.get("PACKY_API_KEY", ""),
            base_url=args.api_base_url,
            model=args.model,
            threshold=args.threshold,
            timeout=args.timeout,
        )
        review_client = LLMReviewClient(
            base_url=args.review_base_url,
            model=args.review_model,
            timeout=args.review_timeout,
        )
        result = create_plan(state_dir=state_dir, roots=roots, min_age_days=args.min_age_days,
                             max_candidates=args.max_candidates, client=client,
                             review_client=review_client)
        result["browser_open"] = ({"status": "disabled", "reason": "已按 --no-open 保存 HTML 报告，未自动打开"}
                                  if args.no_open else open_report(result["report_path"]))
    if args.format == "json":
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
        return 0
    if args.delete:
        summary = result["summary"]
        print(f"执行状态：{result['status']}")
        print(f"已选择：{summary['selected_count']} 项 / {summary['selected_bytes']} 字节")
        print(f"已删除：{summary['deleted_count']} 项 / {summary['deleted_bytes']} 字节")
        print(f"跳过或失败：{summary['skipped_count']} 项")
        print(f"执行记录：{state_dir / 'executions' / (result['plan_id'] + '.json')}")
    else:
        summary = result["summary"]
        print(f"清理计划：{result['plan_id']}")
        print(f"候选：{summary['candidate_count']} 项；LLM 建议删除：{summary['delete_recommendation_count']} 项 / "
              f"{summary['recommended_delete_bytes']} 字节")
        print(f"计划文件：{result['plan_path']}")
        print(f"HTML 报告：{result['report_path']}")
        print("本命令只生成报告，不会删除文件。")
        print("如需删除，请先查看报告中的路径、风险和条目 ID，再执行：")
        print(f"./ubuntu-setup cleanup --delete --state-dir {shlex.quote(str(state_dir))} "
              f"--plan-file {shlex.quote(result['plan_path'])} --confirm {shlex.quote(result['plan_id'])} "
              f"--select <entry-id> [--select <entry-id> ...]")
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="收集系统信息、保存检查报告，并提供需二次确认的磁盘清理")
    parser.add_argument("--version", action="version", version=__version__)
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("inspect", help="检查当前运行环境，或检查指定的模拟数据")
    command.add_argument("--state-dir", help="独立的私有状态目录，必须在仓库之外")
    command.add_argument("--fixture", help="使用模拟观察 JSON；不读取本机系统信息")
    command.add_argument("--watch-config", action="append", default=[], metavar="PATH", help="额外监测配置文件摘要，可重复指定；不保存文件内容")
    command.add_argument("--online", action="store_true", help="在临时目录下载并验证 APT 索引，不修改系统索引；建议配合 --timeout 30")
    command.add_argument("--confirm-device", action="append", default=[], metavar="DEVICE=RESULT",
                         help="记录用户已实际验证的 display/audio/input=passed/failed/not_applicable；环境变化后失效")
    command.add_argument("--confirm-from", metavar="RUN_ID", help="实际使用确认对应的最新报告编号；与 --confirm-device 一起使用")
    command.add_argument("--format", choices=("text", "json"), default="text")
    command.add_argument("--no-open", action="store_true", help="仅保存 HTML 报告，不自动打开浏览器（适合无桌面环境或自动化调用）")
    command.add_argument("--timeout", type=float, default=5.0, help="每个只读命令的超时秒数（默认 5）")
    catalog = commands.add_parser("capabilities", help="查询能力与检测规则；不采集系统信息、不写入档案")
    catalog.add_argument("--check", help="仅显示指定编号的检测规则说明")
    catalog.add_argument("--format", choices=("text", "json"), default="text")
    record = commands.add_parser("improvement", help="保存经验证的能力改进记录；不修改系统")
    record.add_argument("--record", required=True, help="改进记录 JSON 文件路径")
    record.add_argument("--state-dir", required=True, help="独立的私有状态目录，必须在仓库之外")
    record.add_argument("--format", choices=("text", "json"), default="json")
    cleanup_command = commands.add_parser("cleanup", help="用 JEV 初筛和独立 LLM 复核生成清理报告；删除必须显式选择")
    cleanup_command.add_argument("--state-dir", help="仓库之外的清理计划私有状态目录；默认使用 XDG_STATE_HOME 下的 ubuntu-setup/cleanup")
    cleanup_command.add_argument("--root", action="append", default=[], metavar="PATH",
                                 help="额外扫描指定目录的顶层条目；可重复指定")
    cleanup_command.add_argument("--min-age-days", type=float, default=7.0, help="仅考虑多少天未修改的条目（默认 7）")
    cleanup_command.add_argument("--max-candidates", type=int, default=50,
                                 help=f"最多交给 JEV 判断的候选数量（默认 50，最大 200）")
    cleanup_command.add_argument("--threshold", type=float, default=0.8,
                                 help="JEV 判定可删除的概率阈值（默认 0.8）")
    cleanup_command.add_argument("--api-base-url", default=os.environ.get("PACKY_API_BASE_URL", DEFAULT_BASE_URL),
                                 help=f"PackyApi 基础地址（默认 {DEFAULT_BASE_URL}）")
    cleanup_command.add_argument("--model", default=os.environ.get("PACKY_JEV_MODEL", DEFAULT_MODEL),
                                 help=f"JEV 模型名（默认 {DEFAULT_MODEL}）")
    cleanup_command.add_argument("--timeout", type=float, default=30.0, help="每次 JEV 请求超时秒数（默认 30）")
    cleanup_command.add_argument("--review-base-url",
                                 default=os.environ.get("UBUNTU_SETUP_REVIEW_LLM_BASE_URL", DEFAULT_REVIEW_BASE_URL),
                                 help=f"独立复核 LLM 的 OpenAI 兼容基础地址（默认 {DEFAULT_REVIEW_BASE_URL}）")
    cleanup_command.add_argument("--review-model",
                                 default=os.environ.get("UBUNTU_SETUP_REVIEW_LLM_MODEL", DEFAULT_REVIEW_MODEL),
                                 help=f"独立复核 LLM 模型名（默认 {DEFAULT_REVIEW_MODEL}）")
    cleanup_command.add_argument("--review-timeout", type=float,
                                 default=float(os.environ.get("UBUNTU_SETUP_REVIEW_LLM_TIMEOUT", "120")),
                                 help="独立复核 LLM 请求超时秒数（默认 120；本机模型冷启动可能超过 30 秒）")
    cleanup_command.add_argument("--delete", action="store_true",
                                 help="删除用户显式选择的条目；必须同时提供计划、确认编号和条目 ID")
    cleanup_command.add_argument("--plan-file", help="要执行的清理计划 JSON")
    cleanup_command.add_argument("--confirm", help="精确匹配计划中的 plan_id")
    cleanup_command.add_argument("--select", action="append", default=[], metavar="ENTRY-ID",
                                 help="要删除的清理条目 ID；可重复指定")
    cleanup_command.add_argument("--no-open", action="store_true",
                                 help="仅保存 HTML 报告，不自动打开浏览器（适合无桌面环境或自动化调用）")
    cleanup_command.add_argument("--format", choices=("text", "json"), default="json")
    args = parser.parse_args(argv)
    if args.command == "inspect" and (not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 30):
        parser.error("--timeout 必须大于 0 且不超过 30 秒")
    if args.command == "cleanup" and (not math.isfinite(args.min_age_days) or args.min_age_days < 0 or
                                      not math.isfinite(args.threshold) or not 0 < args.threshold < 1 or
                                      not math.isfinite(args.timeout) or not 1 <= args.timeout <= 120 or
                                      not math.isfinite(args.review_timeout) or not 1 <= args.review_timeout <= 300):
        parser.error("cleanup 参数范围错误；--threshold 须在 0 和 1 之间，--timeout 须在 1 到 120 秒之间，"
                     "--review-timeout 须在 1 到 300 秒之间")
    try:
        if args.command == "capabilities":
            return capabilities(args)
        if args.command == "improvement":
            return improvement(args)
        if args.command == "cleanup":
            return cleanup(args)
        return inspect(args)
    except (DataError, OSError) as exc:
        message = str(exc) if isinstance(exc, DataError) else type(exc).__name__
        operation = "清理" if args.command == "cleanup" else ("检查" if args.command == "inspect" else "命令")
        print(f"{operation}未完成：{message}。原有记录保留。", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("检查已中断；下次运行将核对记录并重新采集。", file=sys.stderr)
        return 130
