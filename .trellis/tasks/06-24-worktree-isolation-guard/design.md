# 技术设计 — worktree 强制隔离 hook

## 组件总览

三个改动,全部纳入 git:

1. `.claude/hooks/worktree-guard.py` — 新增。PreToolUse 判定脚本(纯 python3 标准库,
   沿用现有 `inject-*.py`/`session-start.py` 的 .py 风格,无 jq/外部依赖)。
2. `.claude/settings.json` — 编辑。在 `hooks.PreToolUse` 数组**追加**一个 matcher 项,
   保留全部现有项。
3. `CLAUDE.md`(仓库根) — 编辑。新增"代码改动的 worktree 隔离工作流"章节(配合指令)。

## 数据流

```
Claude 拟调用 Edit/Write(file_path=X)
  → Claude Code 触发 PreToolUse, matcher 命中 "Edit|Write|MultiEdit|NotebookEdit"
  → 运行 `python3 .claude/hooks/worktree-guard.py`,stdin 喂 JSON
  → 脚本判定:逃生阀? 在 worktree? 非代码白名单? 仓库外?
       任一为真 → 放行(exit 0, 无输出)
       否则(主 checkout 内的代码文件) → 输出 deny JSON, exit 0
  → Claude 收到 deny + reason → (按 CLAUDE.md)调 EnterWorktree → 在 worktree 内重试 Edit → 放行
```

## hook 判定逻辑(worktree-guard.py)

输入(stdin JSON,字段已查证):
- `tool_name` — "Edit"/"Write"/"MultiEdit"/"NotebookEdit"
- `tool_input.file_path` — 目标文件(Write/Edit/MultiEdit);NotebookEdit 用 `notebook_path`
- `cwd` — 事件触发时工作目录(进入 worktree 后为 worktree 路径)

判定顺序(短路放行优先,fail-open):
1. **解析输入**:`json.load(sys.stdin)`;取 tool_name、file_path(回退 notebook_path)、cwd。
   任何异常/缺字段 → 打印告警到 stderr、`sys.exit(0)`(放行,绝不锁死)。
2. **逃生阀**:`os.environ.get("WORKTREE_GUARD","").lower() in {"0","off","false"}` → exit 0。
3. **绝对化路径**:`abs_path = os.path.realpath(file_path if os.path.isabs(file_path)
   else os.path.join(cwd, file_path))`。
4. **在 worktree?**:`os.sep + ".claude" + os.sep + "worktrees" + os.sep` 是 `abs_path` 子串 → exit 0。
   (worktree 默认落点;与 `EnterWorktree`/`--worktree` 一致。)
5. **定位仓库根**:hook 经 `$CLAUDE_PROJECT_DIR` 环境变量拿项目根(Claude Code 注入);
   回退:脚本自身路径上溯两级(`.claude/hooks/` → repo)。算 `rel = os.path.relpath(abs_path, repo_root)`。
6. **仓库外?**:`rel` 以 `..` 开头 → 仓库外 → exit 0。
7. **非代码白名单?**:`rel` 命中放行集 → exit 0。放行集(前缀/glob):
   `.trellis/`、`.claude/`、`docs/`、`memory/`、`.git/`、任意 `*.md`、`*.json`、`*.conf`、
   `.gitignore`、`LICENSE*`、`README*`、`.worktreeinclude`。
8. **是代码?**:`rel` 命中代码集 → **deny**。代码集:
   `scripts/*.sh`(含 `scripts/TEMPLATE.sh`)、`lib/*.sh`、`bootstrap.sh`、`swkit`。
9. **兜底**:既非白名单也非已知代码(如未来新目录) → MVP 选择**放行**(exit 0),
   只挡明确的代码,避免误伤;若日后要收紧改成"仓库内非白名单一律拦"再议(design 记此选择)。

deny 输出(stdout,exit 0):
```json
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
"permissionDecisionReason":"<多行指引>"}}
```
reason 文案(要点):当前在主 checkout(分支 X),本仓约定代码改动须在 worktree 内进行;
请调用 EnterWorktree 新建并切入,改完在其中跑 `bash -n`+`shellcheck -x`+脚本自测,
验证通过后回主树 `git merge`、`ExitWorktree`;紧急直改可设 `WORKTREE_GUARD=off`。

### 为什么用 file_path 而非 hook 执行 cwd 判 worktree
hook 命令的执行目录不保证等于 Claude 会话 cwd;最可靠的是看**目标文件绝对路径**
是否在 `.claude/worktrees/` 下。这对"在 worktree 里改"和"在主树里改"都成立,不依赖 hook 进程 cwd。

### 为什么 fail-open
hook 异常若 fail-closed 会把所有 Edit 锁死(包括修 hook 本身),灾难性;fail-open 最坏只是漏挡一次,
由 CLAUDE.md 约定与人工兜底。安全契约这里让位于"不可把用户锁死"。

## settings.json 改法

`hooks.PreToolUse` 现有 `[{matcher:"Task",...},{matcher:"Agent",...}]`,**追加**第三项:
```json
{
  "matcher": "Edit|Write|MultiEdit|NotebookEdit",
  "hooks": [
    { "type": "command", "command": "python3 .claude/hooks/worktree-guard.py", "timeout": 10 }
  ]
}
```
其余 hooks(SessionStart/UserPromptSubmit)与 env/enabledPlugins 原样不动。
命令用相对路径 `python3 .claude/hooks/...`(与现有 hook 写法一致)。

## CLAUDE.md 配合章节(要点)

新增小节(放在"领域约束"附近或单独一节"## 代码改动的 worktree 工作流"):
- 触发:涉及 `scripts/`/`lib/`/`bootstrap.sh`/`swkit` 的改动。
- 步骤:① `EnterWorktree`(建 `.claude/worktrees/<名>` 并切入)→ ② 在 worktree 内改 →
  ③ 验证(`for f in ...; do bash -n "$f"; done` + `shellcheck -x --source-path=SCRIPTDIR ...` +
  涉及脚本的 `meta`/`status`/`help`/`ui` 契约自测)→ ④ 通过后回主树 `git merge worktree-<名>` →
  ⑤ `ExitWorktree` / 清理。
- 逃生阀:`WORKTREE_GUARD=off`(改 hook 自身、紧急小修、文档不受 hook 限制时无需)。
- 诚实声明:hook 只挡 Edit/Write 系工具对代码文件的写,Bash 旁路不挡;合并前验证靠本约定。

## 兼容性 / 回滚
- 兼容现有 `.claude/worktrees/codex-default-editor/` 等既有 worktree(它们路径即在放行段)。
- 回滚:从 settings.json 删掉新增 matcher 项即停用;删 `worktree-guard.py`;还原 CLAUDE.md 章节。
- `trellis init` 重装覆盖 settings.json 时:从 `.trellis/.backup-*` 或 git 恢复本 matcher 项
  (本任务在 implement 记一行"恢复指引")。

## 测试策略(无运行时无法静态覆盖,须喂样例 stdin 实跑)
- 用构造的 JSON 喂 `worktree-guard.py`,断言放行/deny(见 implement 的验证矩阵)。
- `python3 -m py_compile .claude/hooks/worktree-guard.py`。
- `python3 -c "import json,sys; json.load(open('.claude/settings.json'))"` 验 JSON 合法。
- 真机端到端:在主树试 Edit 一个 `scripts/*.sh` 看是否被挡(需在交互会话验证,或用样例 stdin 模拟)。
