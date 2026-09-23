"""Runnable read-only workflow for any terminal-based Agent."""

import argparse
import json
import math
import os
from pathlib import Path
import sys

from . import __version__
from .analysis import assess, compare, invalidate, make_snapshot
from .browser import open_report
from .collect import LocalProbe, collect, live_identity
from .model import DataError, load_fixture, new_id
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
              "operations": [
                  {"id": "inspect", "invocation": "./ubuntu-setup inspect --format json",
                   "purpose": "采集当前运行环境并运行全部检测规则，保存带证据的报告",
                   "target": "当前运行环境；模拟检查显式指定 --fixture 和独立 --state-dir",
                   "side_effects": ["写入本工具的私有状态目录", "在现有图形库创建并销毁 1 像素离屏缓冲；不打开窗口", "--online 将软件索引下载到临时目录并清理", "保存 HTML 后请求默认浏览器打开；--no-open 可关闭"], "requires_privilege": False,
                   "network_access": False, "optional_network_access": "仅 --online；联系已配置的软件源，不修改系统索引",
                   "human_confirmation": "--confirm-from 最新报告编号和 --confirm-device 记录用户已实际验证的结果；采集复核环境变化后拒绝沿用",
                   "exit_codes": {"0": "报告保存完成，须另读检查结果", "2": "检查未完成", "130": "用户中断"}},
                  {"id": "capabilities", "invocation": "./ubuntu-setup capabilities --format json",
                   "purpose": "查询检测规则的用途、输入、依据、版本和限制",
                   "side_effects": [], "requires_privilege": False, "network_access": False}],
              "checks": describe_rules(args.check),
              "limitations": ["规则结果只适用于所引用观察的时间与范围",
                              "命令成功不等于系统稳定；本程序不提供安装或修复操作",
                              "规则目录是接入基础，尚非专用 Agent 适配或自动改进机制"]}
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) if args.format == "json" else render_capabilities(result))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="只读收集系统信息、比较变化并保存检查报告；不安装或修复系统")
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
    args = parser.parse_args(argv)
    if args.command == "inspect" and (not math.isfinite(args.timeout) or args.timeout <= 0 or args.timeout > 30):
        parser.error("--timeout 必须大于 0 且不超过 30 秒")
    try:
        return capabilities(args) if args.command == "capabilities" else inspect(args)
    except (DataError, OSError) as exc:
        message = str(exc) if isinstance(exc, DataError) else type(exc).__name__
        print(f"检查未完成：{message}。原有记录保留。", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("检查已中断；下次运行将核对记录并重新采集。", file=sys.stderr)
        return 130
