"""File configuration for codex-response.sh; no model calls or account migration."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

RULES = Path(__file__).resolve().parents[1] / "skills/codex-response-setup/assets/response-rules.md"
TITLE = "## 回复与信息展示"
LIMITATION = "配置和加载检查不证明长期回复效果，也不保证所有工具结果可折叠。"


class SetupError(Exception):
    """A bounded failure that is safe to show without printing configuration."""


def safe_path(path: Path) -> None:
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise SetupError(f"需要明确的绝对路径：{path}")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise SetupError(f"目标路径含软链，请先核对实际位置：{part}")


def read_file(path: Path) -> bytes | None:
    safe_path(path)
    if not path.exists():
        return None
    if not path.is_file() or path.stat().st_uid != os.getuid():
        raise SetupError(f"目标不是当前用户拥有的普通文件：{path}")
    return path.read_bytes()


def parse_config(raw: bytes) -> dict:
    try:
        return tomllib.loads(raw.decode("utf-8"))
    except (UnicodeError, tomllib.TOMLDecodeError) as exc:
        raise SetupError("config.toml 无法解析；请在本机核对，未输出配置或凭据。") from exc


def config_candidate(raw: bytes) -> bytes:
    current = parse_config(raw)
    value = current.get("hide_agent_reasoning")
    if value is True:
        return raw
    if "hide_agent_reasoning" in current and not isinstance(value, bool):
        raise SetupError("hide_agent_reasoning 已存在但不是布尔值，未覆盖。")
    expected = dict(current, hide_agent_reasoning=True)
    newline = "\r\n" if b"\r\n" in raw else "\n"
    text = raw.decode("utf-8")
    if "hide_agent_reasoning" not in current:
        candidate = ("hide_agent_reasoning = true" + newline + text).encode()
        if parse_config(candidate) == expected:
            return candidate
    else:
        # Try one textual edit at a time. Parsing and whole-document comparison
        # prevent edits to matching text inside tables, comments or multiline strings.
        pattern = r'''(?m)^(\s*(?:hide_agent_reasoning|"hide_agent_reasoning"|'hide_agent_reasoning')\s*=\s*)false(?=\s*(?:#.*)?$)'''
        for match in re.finditer(pattern, text):
            candidate = (text[:match.start()] + match[1] + "true" + text[match.end():]).encode()
            if parse_config(candidate) == expected:
                return candidate
    raise SetupError("无法仅修改目标设置并保留其余 TOML 内容，请先人工核对。")


def rules_candidate(raw: bytes, standard: bytes) -> bytes:
    text = raw.decode("utf-8")
    matches = list(re.finditer(r"(?m)^## 回复与信息展示[ \t]*\r?$", text))
    if matches:
        if len(matches) == 1:
            start = matches[0].start()
            next_heading = re.search(r"(?m)^#{1,2} ", text[matches[0].end():])
            end = matches[0].end() + next_heading.start() if next_heading else len(text)
            if text[start:end].replace("\r\n", "\n").strip() == standard.decode().strip():
                return raw
        raise SetupError("已有“回复与信息展示”规则与仓库不同；请比较并保留定制，不自动覆盖。")
    separator = b"" if not raw else (b"\n" if raw.endswith(b"\n") else b"\n\n")
    return raw + separator + standard


def plan(home: Path) -> dict:
    safe_path(home)
    if home.exists() and (not home.is_dir() or home.stat().st_uid != os.getuid()):
        raise SetupError("Codex home 必须是当前用户拥有的目录。")
    paths = [home / "AGENTS.override.md", home / "AGENTS.md", home / "config.toml"]
    observed = {p: read_file(p) for p in paths}
    agents = paths[0] if (observed[paths[0]] or b"").strip() else paths[1]
    standard = RULES.read_bytes()
    config = config_candidate(observed[paths[2]] or b"")
    instructions = rules_candidate(observed[agents] or b"", standard)
    limit = parse_config(config).get("project_doc_max_bytes", 32768)
    if not isinstance(limit, int) or len(instructions) > limit:
        raise SetupError("全局规则超过指令大小限制；请先精简或核对加载范围。")
    candidates = {agents: instructions, paths[2]: config}
    changes = {p: content for p, content in candidates.items() if content != observed[p]}
    return {"home": home, "agents": agents, "observed": observed, "changes": changes,
            "config": config, "instruction_bytes": len(instructions)}


def find_cli() -> str:
    cli = shutil.which("codex")
    fallback = Path.home() / ".local/bin/codex"
    if not cli and fallback.is_file() and os.access(fallback, os.X_OK):
        cli = str(fallback)
    if not cli:
        raise SetupError("缺少 Codex CLI；先安装，或使用 install --with-requires。")
    return cli


def check_cli(config: bytes) -> str:
    cli = find_cli()
    with tempfile.TemporaryDirectory(prefix="codex-response-check-") as tmp:
        root = Path(tmp)
        env = dict(os.environ, CODEX_HOME=tmp)
        def invoke(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run([cli, *args], cwd=root, env=env, capture_output=True,
                                  text=True, timeout=30)
        version = invoke("--version")
        if version.returncode:
            raise SetupError("无法读取 Codex 版本，未写入目标配置。")
        # A positive parse alone would miss clients that silently ignore unknown keys.
        (root / "config.toml").write_text('hide_agent_reasoning = "type-check"\n')
        invalid = invoke("features", "list")
        if invalid.returncode == 0 or "hide_agent_reasoning" not in invalid.stderr or "boolean" not in invalid.stderr:
            raise SetupError("未确认当前 CLI 支持 hide_agent_reasoning；请核对该版本官方文档。")
        (root / "config.toml").write_bytes(config)
        if invoke("features", "list").returncode:
            raise SetupError("Codex 无法读取候选配置；请在本机检查，未输出含凭据的原始诊断。")
        return version.stdout.strip()


def write_atomic(path: Path, data: bytes, metadata: os.stat_result | None) -> None:
    descriptor, name = tempfile.mkstemp(prefix=".codex-response-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(name, stat.S_IMODE(metadata.st_mode) if metadata else 0o600)
        if metadata:
            os.chown(name, metadata.st_uid, metadata.st_gid)
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def apply_plan(data: dict, run: Path, record: dict) -> None:
    # Watch even unmodified instruction files: a new override could change selection.
    for path, before in data["observed"].items():
        if read_file(path) != before:
            raise SetupError("预览后文件发生变化，请重新运行 plan；未覆盖新修改。")
    for path, candidate in data["changes"].items():
        before = data["observed"][path]
        metadata = path.stat() if before is not None else None
        backup = run / "before" / path.name
        after = run / "after" / path.name
        if before is not None:
            shutil.copy2(path, backup)
        after.write_bytes(candidate)
        after.chmod(0o600)
        entry = {"path": str(path), "existed": before is not None,
                 "backup": str(backup) if before is not None else None, "after_file": str(after),
                 "before_sha256": hashlib.sha256(before).hexdigest() if before is not None else None,
                 "after_sha256": hashlib.sha256(candidate).hexdigest(),
                 "mode": oct(stat.S_IMODE(metadata.st_mode)) if metadata else None,
                 "uid": metadata.st_uid if metadata else None, "gid": metadata.st_gid if metadata else None,
                 "state": "prepared"}
        record["files"].append(entry)
        save_json(run / "manifest.json", record)
        if read_file(path) != before:
            raise SetupError("执行期间文件变化，停止后续写入；请查看已完成项。")
        write_atomic(path, candidate, metadata)
        entry["state"] = "written"
        save_json(run / "manifest.json", record)
        if path.read_bytes() != candidate:
            raise SetupError("写入后内容不匹配，停止后续操作。")
        entry["state"] = "verified"
        save_json(run / "manifest.json", record)


def save_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_report(run: Path, record: dict) -> None:
    save_json(run / "report.json", record)
    esc = html.escape
    rows = "".join(f'<tr><td>{esc(item["path"])}</td><td>{esc(item["state"])}</td></tr>' for item in record["files"])
    if not rows:
        state = "未写入，检查失败" if record["error"] else "已匹配，无需改写"
        rows = f'<tr><td>规则与显示设置</td><td>{state}</td></tr>'
    summary = "配置已保存，等待新会话验证加载与回复效果。" if not record["error"] else record["error"]
    rules = esc(RULES.read_text())
    document = f'''<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Codex 回复配置报告</title>
<style>body{{max-width:960px;margin:32px auto;padding:0 20px;font-family:system-ui;line-height:1.7}}td,th{{border:1px solid #ccc;padding:8px;text-align:left}}table{{border-collapse:collapse;width:100%}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}.notice{{padding:12px;background:#eff4fc}}</style>
<h1>Codex 回复配置报告</h1><p>{esc(record["time"])}</p>
<h2>结论与重点问题</h2><p class="notice">{esc(summary)}</p><p>{LIMITATION}</p>
<h2>用户待办与 Agent 后续建议</h2><p>重新启动 Codex 后，由 Agent 核对规则加载；按 Skill 的验收场景检查实际回复。失败时先查看下表，保留已完成项，再根据当前文件重跑。</p>
<h2>完整结果总表</h2><table><tr><th>文件</th><th>结果</th></tr>{rows}</table>
<p>写入前的候选配置已通过本机 CLI 解析与设置类型检查；各文件实际完成状态以上表为准。尚未验证项目覆盖、当前会话热更新或长期模型行为。</p>
<h2>检查范围与电脑信息</h2><p>{esc(record["cli_version"])} · {esc(sys.platform)} · 仅当前用户的 Codex 配置；不迁移账号、凭据或模型供应商。</p>
<h2>前后变化</h2><p>补充回复标准，将 hide_agent_reasoning 设为 true。既有匹配内容不重写，不修改模型、推理强度、字数、终端模式或快捷键。</p>
<p>恢复前比较当前文件与 after/，保留后续修改。根据 manifest.json，仅撤销本次新增的规则节和显示设置；不要直接用 before/ 覆盖已被其他任务修改的文件。</p>
<h2>依据附录</h2><details><summary>完整回复标准</summary><pre>{rules}</pre></details>
<p><a href="report.json">JSON 记录</a> · <a href="manifest.json">备份与变更清单</a></p></html>'''
    (run / "report.html").write_text(document, encoding="utf-8")


def configure(data: dict, no_open: bool) -> tuple[Path, bool]:
    version = check_cli(data["config"])
    home = data["home"]
    state = home / ".ubuntu-setup-response-runs"
    safe_path(state)
    if state.exists() and (not state.is_dir() or state.stat().st_uid != os.getuid() or stat.S_IMODE(state.stat().st_mode) & 0o077):
        raise SetupError("运行记录目录必须由当前用户拥有，且仅本人可访问。")
    home.mkdir(parents=True, exist_ok=True, mode=0o700)
    state.mkdir(exist_ok=True, mode=0o700)
    run = Path(tempfile.mkdtemp(prefix=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S-"), dir=state))
    (run / "before").mkdir(mode=0o700)
    (run / "after").mkdir(mode=0o700)
    record = {"time": dt.datetime.now().astimezone().isoformat(), "cli_version": version,
              "files": [], "error": None, "browser_open": "not_requested", "behavior_verified": False}
    try:
        apply_plan(data, run, record)
    except (SetupError, OSError) as exc:
        record["error"] = str(exc)
    save_json(run / "manifest.json", record)
    write_report(run, record)
    if no_open:
        record["browser_open"] = "disabled"
    elif not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) or not shutil.which("xdg-open"):
        record["browser_open"] = "unavailable"
    else:
        try:
            opened = subprocess.run(["xdg-open", str(run / "report.html")], capture_output=True, timeout=5)
            record["browser_open"] = "requested" if opened.returncode == 0 else "failed"
        except subprocess.TimeoutExpired:
            record["browser_open"] = "timeout"
        except OSError:
            record["browser_open"] = "failed"
    write_report(run, record)
    return run, record["error"] is None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("plan", "configure", "status"))
    parser.add_argument("--codex-home", type=Path)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    try:
        if os.environ.get("SUDO_USER"):
            raise SetupError("请以目标普通用户运行，不要用 sudo 包裹配置命令。")
        home = args.codex_home or Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex")
        data = plan(home)
        print(f'Codex home: {home}\n全局规则: {data["agents"]}')
        for path in data["changes"]:
            print(f"拟修改: {path}")
        if args.operation == "configure":
            run, success = configure(data, args.no_open)
            report = json.loads((run / "report.json").read_text())
            if report["error"]:
                print(f'未完成: {report["error"]}', file=sys.stderr)
            else:
                print("配置已保存；请在新会话验证加载与回复效果。")
            print(f'HTML: {run / "report.html"}\nJSON: {run / "report.json"}\n{LIMITATION}')
            print("浏览器打开状态: " + report["browser_open"])
            return 0 if success else 1
        print("配置待更新。" if data["changes"] else "配置已匹配；实际行为尚需验证。")
        print("预览和状态检查未调用模型或原生配置检查，未创建文件。")
        return int(args.operation == "status" and bool(data["changes"]))
    except (SetupError, OSError, UnicodeError, subprocess.TimeoutExpired) as exc:
        print(f"未完成: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
