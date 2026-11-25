"""Merge the shared evidence rules and install a self-contained user Skill."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

SOURCE = Path(__file__).resolve().parents[1]
NAME = "agent-evidence-setup"
START = b"<!-- ubuntu-setup:agent-evidence:start -->"
END = b"<!-- ubuntu-setup:agent-evidence:end -->"
TITLE = "## 证据、任务理解与长期记录"
LIMIT = "静态匹配不证明实际加载；有限样例不证明长期效果或所有后台摘要均受约束。"


class SetupError(Exception):
    pass


def digest(raw):
    return hashlib.sha256(raw).hexdigest() if raw is not None else None


def check_path(path):
    if not path.is_absolute() or ".." in path.parts or path == Path("/"):
        raise SetupError(f"需要明确的绝对路径：{path}")
    for node in (path, *path.parents):
        if node.is_symlink():
            raise SetupError(f"路径含软链，请先核对实际位置：{node}")
    if path.exists() and path.stat().st_uid != os.getuid():
        raise SetupError(f"路径不属于当前用户：{path}")


def read_file(path):
    check_path(path)
    if not path.exists():
        return None
    if not path.is_file():
        raise SetupError(f"目标不是普通文件：{path}")
    return path.read_bytes()


def merge(raw, rules):
    block = START + b"\n" + rules.rstrip() + b"\n" + END + b"\n"
    raw.decode("utf-8")
    if START in raw or END in raw:
        if raw.count(START) != 1 or raw.count(END) != 1:
            raise SetupError("受管规则标记缺失或重复，未覆盖。")
        begin, finish = raw.index(START), raw.index(END) + len(END)
        if finish <= begin or raw[begin:finish].replace(b"\r\n", b"\n") != block.rstrip():
            raise SetupError("已有受管规则与源文件不同；保留定制，先比较差异。")
        return raw
    if TITLE in raw.decode("utf-8"):
        raise SetupError("已有同名但未受管的规则；先核对，未重复追加。")
    sep = b"" if not raw else (b"\n" if raw.endswith(b"\n") else b"\n\n")
    return raw + sep + block


def source_files():
    files = {}
    for path in sorted(SOURCE.rglob("*")):
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise SetupError("Skill 源文件含软链，无法生成独立副本。")
        if path.is_file():
            files[path.relative_to(SOURCE)] = path.read_bytes()
    return files


def build_plan(codex_home, claude_home, codex_skills, target="both"):
    rules = (SOURCE / "assets/evidence-rules.md").read_bytes()
    observed, candidates, targets, trees = {}, {}, [], {}
    source_snapshot = source_files()

    def observe(path):
        if path not in observed:
            observed[path] = read_file(path)
        return observed[path]

    for client in (["codex", "claude"] if target == "both" else [target]):
        home = codex_home if client == "codex" else claude_home
        check_path(home)
        if home.exists() and not home.is_dir():
            raise SetupError(f"配置目录不是目录：{home}")
        if client == "codex":
            override, base = home / "AGENTS.override.md", home / "AGENTS.md"
            over_raw, base_raw = observe(override), observe(base)
            if over_raw is not None and not over_raw.strip() and (base_raw or b"").strip():
                raise SetupError("存在空 AGENTS.override.md 和非空 AGENTS.md；先确认加载选择，避免遮蔽既有规则。")
            path = override if over_raw is not None else base
            config = observe(home / "config.toml") or b""
            try:
                cap = tomllib.loads(config.decode()).get("project_doc_max_bytes", 32768)
            except (ValueError, UnicodeError) as exc:
                raise SetupError("Codex 配置无法解析；未输出配置内容。") from exc
        else:
            path, cap = home / "CLAUDE.md", 4 * 1024 * 1024
        candidate = merge(observe(path) or b"", rules)
        if not isinstance(cap, int) or isinstance(cap, bool) or len(candidate) > cap:
            raise SetupError(f"全局规则超过已检查的大小限制：{path}")
        candidates[path] = candidate
        dest = (codex_skills if client == "codex" else home / "skills") / NAME
        check_path(dest)
        expected = source_snapshot
        existing = set()
        if dest.exists():
            if not dest.is_dir():
                raise SetupError(f"同名 Skill 不是目录：{dest}")
            for item in dest.rglob("*"):
                if "__pycache__" in item.parts or item.suffix == ".pyc":
                    continue
                check_path(item)
                if item.is_file():
                    existing.add(item.relative_to(dest))
            if not existing <= set(expected):
                raise SetupError(f"已有同名 Skill 包含额外文件，未覆盖：{dest}")
        trees[dest] = existing if dest.exists() else None
        for relative, content in expected.items():
            item = dest / relative
            before = observe(item)
            if before is not None and before != content:
                raise SetupError(f"已有 Skill 文件与源文件不同，未覆盖：{item}")
            candidates[item] = content
        targets.append({"client": client, "instructions": str(path), "skill": str(dest),
                        "instruction_bytes": len(candidate), "instruction_lines": len(candidate.splitlines())})
    changes = {p: b for p, b in candidates.items() if b != observed[p]}
    return {"observed": observed, "changes": changes, "trees": trees,
            "targets": targets, "rules_sha256": digest(rules), "source_snapshot": source_snapshot}


def recheck(plan):
    if source_files() != plan["source_snapshot"]:
        raise SetupError("预览后 Skill 源文件发生变化，请重新预览。")
    for path, before in plan["observed"].items():
        if read_file(path) != before:
            raise SetupError(f"预览后文件发生变化，停止写入：{path}")
    for root, before in plan["trees"].items():
        check_path(root)
        now = None if not root.exists() else {
            p.relative_to(root) for p in root.rglob("*")
            if p.is_file() and "__pycache__" not in p.parts and p.suffix != ".pyc"}
        if now != before:
            raise SetupError(f"预览后 Skill 文件集合发生变化：{root}")


def atomic_write(path, raw, metadata=None):
    check_path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix=".agent-evidence-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp, stat.S_IMODE(metadata.st_mode) if metadata else 0o600)
        if metadata:
            os.chown(temp, metadata.st_uid, metadata.st_gid)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def save_json(path, record):
    atomic_write(path, (json.dumps(record, ensure_ascii=False, indent=2) + "\n").encode())


def write_report(run, record):
    save_json(run / "report.json", record)
    esc = html.escape
    rows = "".join(f'<tr><td>{esc(x["path"])}</td><td>{esc(x["state"])}</td></tr>' for x in record["files"])
    result = record["error"] or ("配置已保存，等待新会话检查加载。" if rows else "内容已匹配，无需改写。")
    text = f"""<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>证据与长期记录规则配置报告</title>
<style>body{{max-width:1100px;margin:32px auto;padding:0 20px;font-family:system-ui;line-height:1.7}}table{{border-collapse:collapse;width:100%}}td,th{{border:1px solid #ccc;padding:8px;text-align:left}}pre{{white-space:pre-wrap;overflow-wrap:anywhere}}</style>
<h1>证据与长期记录规则配置报告</h1><p>{esc(record['time'])}</p>
<h2>结论与重点问题</h2><p>{esc(result)}</p><p>{LIMIT}</p>
<h2>用户待办与 Agent 后续建议</h2><p>由 Agent 在新会话核对规则和 Skill 加载，检查项目覆盖及有限行为样例。脚本不判断其他章节的语义冲突。失败时保留已完成项，根据当前内容补查，不直接覆盖备份。</p>
<h2>完整结果总表</h2><table><tr><th>路径</th><th>状态</th></tr>{rows or '<tr><td>全部目标</td><td>匹配，无改写</td></tr>'}</table>
<h2>检查范围与电脑信息</h2><p>{esc(sys.platform)} · 当前用户指令与本 Skill 副本。客户端加载、长期行为、后台摘要均未由本脚本验证。</p><pre>{esc(json.dumps(record['targets'], ensure_ascii=False, indent=2))}</pre>
<h2>前后变化</h2><p>保留既有指令，仅追加受管规则及缺少的 Skill 文件。配置、账号、模型、权限及 MCP 保持原状。写前备份、写后按内容核对；匹配文件不改写。</p>
<h2>依据附录</h2><details><summary>公共规则</summary><pre>{esc((SOURCE / 'assets/evidence-rules.md').read_text())}</pre></details>
<p>恢复：先比较 manifest.json 中 after_sha256 与当前文件。存在后续修改时，人工合并撤回本次区段；不得整份覆盖。没有后续修改时可按 before/ 恢复原文件、原权限与属主，仅移除清单明确记录的新增文件。</p>
<p><a href="report.json">JSON 报告</a> · <a href="manifest.json">备份和变更清单</a></p></html>"""
    atomic_write(run / "report.html", text.encode())


def configure(plan, state, no_open=False):
    recheck(plan)
    check_path(state)
    if state.exists() and (not state.is_dir() or stat.S_IMODE(state.stat().st_mode) & 0o077):
        raise SetupError("记录目录必须是当前用户的私有目录（权限 0700）。")
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    run = Path(tempfile.mkdtemp(prefix=dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S-"), dir=state))
    (run / "before").mkdir(mode=0o700)
    (run / "after").mkdir(mode=0o700)
    record = {"time": dt.datetime.now(dt.timezone.utc).isoformat(), "targets": plan["targets"],
              "rules_sha256": plan["rules_sha256"], "files": [], "error": None,
              "semantic_conflicts": "requires_agent_review", "loading": "not_checked",
              "behavior": "not_checked", "browser_open": "not_requested"}
    try:
        for index, (path, after) in enumerate(plan["changes"].items()):
            before = plan["observed"][path]
            if read_file(path) != before:
                raise SetupError(f"执行期间文件变化，停止后续操作：{path}")
            metadata = path.stat() if before is not None else None
            backup = run / "before" / str(index)
            if before is not None:
                shutil.copy2(path, backup)
            atomic_write(run / "after" / str(index), after)
            entry = {"path": str(path), "backup": str(backup) if before is not None else None,
                     "before_sha256": digest(before), "after_sha256": digest(after),
                     "mode": stat.S_IMODE(metadata.st_mode) if metadata else None,
                     "uid": metadata.st_uid if metadata else None, "gid": metadata.st_gid if metadata else None,
                     "state": "prepared"}
            record["files"].append(entry)
            save_json(run / "manifest.json", record)
            if read_file(path) != before:
                raise SetupError(f"备份后文件变化，停止写入：{path}")
            atomic_write(path, after, metadata)
            entry["state"] = "written"
            save_json(run / "manifest.json", record)
            if read_file(path) != after:
                raise SetupError(f"写入核对失败：{path}")
            entry["state"] = "verified"
            save_json(run / "manifest.json", record)
    except (OSError, SetupError) as exc:
        record["error"] = str(exc)
    save_json(run / "manifest.json", record)
    write_report(run, record)
    if no_open:
        record["browser_open"] = "disabled"
    elif shutil.which("xdg-open"):
        try:
            result = subprocess.run(["xdg-open", str(run / "report.html")], capture_output=True, timeout=5)
            record["browser_open"] = "requested" if result.returncode == 0 else "failed"
        except (OSError, subprocess.TimeoutExpired):
            record["browser_open"] = "failed_or_timeout"
    else:
        record["browser_open"] = "unavailable"
    write_report(run, record)
    return run, record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["plan", "configure", "status"])
    parser.add_argument("--target", choices=["codex", "claude", "both"], default="both")
    parser.add_argument("--codex-home", type=Path, default=Path(os.environ.get("CODEX_HOME") or Path.home() / ".codex"))
    parser.add_argument("--claude-home", type=Path, default=Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude"))
    parser.add_argument("--codex-skills-dir", type=Path, default=Path.home() / ".agents/skills")
    parser.add_argument("--state-dir", type=Path, default=Path(os.environ.get("XDG_STATE_HOME") or Path.home() / ".local/state") / "ubuntu-setup/agent-evidence")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    try:
        if os.environ.get("SUDO_USER") or os.getuid() == 0:
            raise SetupError("请以目标普通用户运行，不要用 sudo 包裹。")
        plan = build_plan(args.codex_home, args.claude_home, args.codex_skills_dir, args.target)
        print(json.dumps({"targets": plan["targets"], "rules_sha256": plan["rules_sha256"],
                          "changes": [str(p) for p in plan["changes"]],
                          "semantic_conflicts": "requires_agent_review", "loading": "not_checked"}, ensure_ascii=False, indent=2))
        if args.operation == "configure":
            run, record = configure(plan, args.state_dir, args.no_open)
            print(f"HTML: {run / 'report.html'}\nJSON: {run / 'report.json'}")
            print("浏览器：" + record["browser_open"])
            if record["error"]:
                raise SetupError(record["error"])
        print(LIMIT)
        return int(args.operation == "status" and bool(plan["changes"]))
    except (SetupError, OSError, UnicodeError) as exc:
        print(f"未完成：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
