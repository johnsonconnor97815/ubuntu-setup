#!/usr/bin/env python3
"""PreToolUse guard: force code edits into an isolated git worktree.

Repository convention (see CLAUDE.md "代码改动的 worktree 工作流"): changes to
the kit's *code* must happen inside a git worktree under
``.claude/worktrees/``, never directly on the main checkout (currently the
``dev`` branch). This hook enforces that for the file-writing tools
(Edit / Write / MultiEdit / NotebookEdit): when Claude tries to write a code
file on the main checkout, the hook returns ``permissionDecision: deny`` with a
reason that tells Claude to EnterWorktree first. Inside a worktree, or for
non-code files (docs / config / .trellis / .claude), it is a silent allow.

Code files (precise interception — everything else is allowed):
  - scripts/*.sh   (any .sh under scripts/, incl. TEMPLATE.sh)
  - lib/*.sh       (any .sh under lib/)
  - bootstrap.sh   (repo root)
  - swkit          (repo root launcher)

Decision order (short-circuit allow wins; the guard is fail-open):
  1. Parse stdin JSON; on any error / missing field -> allow (never lock the
     user out of editing, including editing this hook itself).
  2. Escape hatch: WORKTREE_GUARD in {0, off, false} -> allow.
  3. Resolve the target file to an absolute real path.
  4. Path lies under ``.claude/worktrees/`` -> allow (already isolated). This is
     checked on the *physical* path, so it holds whether CLAUDE_PROJECT_DIR
     points at the main checkout or at the worktree.
  5. Path is a code file under the repo root (and on the main checkout) -> deny.
  6. Anything else (docs, config, files outside the repo) -> allow.

This is a best-effort guard, not a sandbox. It only governs the file-writing
tools; writing code through Bash (sed / tee / cat >) is not intercepted. That
is an accepted boundary documented in CLAUDE.md.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

# Files this repo treats as "code" — the only things the guard intercepts.
CODE_DIRS = ("scripts", "lib")          # any *.sh below these dirs
CODE_EXT = ".sh"
CODE_EXACT = ("bootstrap.sh", "swkit")  # repo-root entrypoints

WORKTREE_SEGMENT = os.sep + os.path.join(".claude", "worktrees") + os.sep
ESCAPE_VALUES = {"0", "off", "false", "no"}


def _allow() -> int:
    """Silent allow: emit nothing, let the normal permission flow proceed."""
    return 0


def _deny(rel: str, repo_root: Path) -> int:
    branch = _current_branch(repo_root)
    where = f"分支 {branch} 的主 checkout 上" if branch else "主 checkout 上"
    reason = (
        "⛔ 代码改动需在 git worktree 内进行(本仓 worktree 隔离约定)。\n\n"
        f"你正试图在{where}直接修改代码文件:\n"
        f"  {rel}\n\n"
        "请改为:\n"
        "  1. 调用 EnterWorktree 工具新建并切入隔离 worktree"
        "(落点 .claude/worktrees/<名>/,从当前分支起);\n"
        "  2. 在 worktree 内完成本次代码改动;\n"
        "  3. 验证:bash -n + shellcheck -x --source-path=SCRIPTDIR"
        " + 相关脚本的 meta/status/help/ui 契约自测;\n"
        "  4. 验证通过后回主树 git merge,再 ExitWorktree。\n\n"
        "文档/配置(.md、.trellis/、.claude/、docs/…)不受此限,可在主树直接改。\n"
        "紧急直改或修 hook 本身:设环境变量 WORKTREE_GUARD=off 临时绕过。"
    )
    out = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


def _current_branch(repo_root: Path) -> str:
    """Best-effort current branch name; empty string if unavailable."""
    try:
        res = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return ""


def _repo_root(start: Path) -> Path:
    """Locate the repo root. Prefer CLAUDE_PROJECT_DIR; fall back to this
    script's location (.claude/hooks/ -> repo root is two parents up)."""
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return Path(env).resolve()
    # .claude/hooks/worktree-guard.py -> parents[2] == repo root
    try:
        return start.resolve().parents[2]
    except IndexError:
        return start.resolve().parent


def _is_code(rel: str) -> bool:
    """True iff the repo-relative path is a kit code file."""
    rel = rel.replace(os.sep, "/")
    if rel in CODE_EXACT:
        return True
    parts = rel.split("/")
    return len(parts) >= 2 and parts[0] in CODE_DIRS and rel.endswith(CODE_EXT)


def main() -> int:
    # Escape hatch first — cheap and unconditional.
    if os.environ.get("WORKTREE_GUARD", "").strip().lower() in ESCAPE_VALUES:
        return _allow()

    try:
        data = json.load(sys.stdin)
    except Exception as exc:  # malformed / empty payload -> fail-open
        print(f"[worktree-guard] could not parse hook input: {exc}", file=sys.stderr)
        return _allow()

    tool_input = data.get("tool_input") or {}
    # Write/Edit/MultiEdit use file_path; NotebookEdit uses notebook_path.
    file_path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not file_path:
        # No concrete target (e.g. unexpected schema) -> don't block.
        return _allow()

    cwd = data.get("cwd") or os.getcwd()
    try:
        if not os.path.isabs(file_path):
            file_path = os.path.join(cwd, file_path)
        abs_path = os.path.realpath(file_path)
    except Exception as exc:
        print(f"[worktree-guard] could not resolve path: {exc}", file=sys.stderr)
        return _allow()

    # Already isolated: any path physically under .claude/worktrees/ -> allow.
    if WORKTREE_SEGMENT in (abs_path + os.sep):
        return _allow()

    repo_root = _repo_root(Path(__file__))
    try:
        rel = os.path.relpath(abs_path, repo_root)
    except Exception:
        return _allow()
    if rel.startswith(".."):  # outside the repo -> not our concern
        return _allow()

    if _is_code(rel):
        return _deny(rel.replace(os.sep, "/"), repo_root)

    return _allow()


if __name__ == "__main__":
    sys.exit(main())
