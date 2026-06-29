# 执行计划 — worktree 强制隔离 hook

## 前置:本任务自身在哪改?
本任务**新增的 hook 一旦生效会拦截对 `scripts/`/`lib/` 等的写**,但本任务改的是
`.claude/hooks/`、`.claude/settings.json`、`CLAUDE.md`——**全在放行白名单内**,不会自我锁死。
故本任务可在主 checkout(dev)直接实施。先写脚本与文档,最后再启用 settings.json 的拦截。

## 步骤(有序)

1. **写 hook 脚本** `.claude/hooks/worktree-guard.py`
   - shebang `#!/usr/bin/env python3`,`chmod +x`(与现有 hook 一致,虽 settings 用 `python3 ...` 调)。
   - 纯标准库(`json`/`os`/`sys`),实现 design 的判定顺序,全程 fail-open。
   - 代码集/白名单集以模块级常量列出,便于日后增减。
   - deny 文案多行、含分支名、含逃生阀。
   - 验证:`python3 -m py_compile .claude/hooks/worktree-guard.py`。

2. **构造验证矩阵实跑**(脚本喂样例 stdin,确认逻辑——见下"验证矩阵",这是 review gate 1)
   - 必须全绿后才动 settings.json。

3. **改 settings.json**:`hooks.PreToolUse` 追加 `Edit|Write|MultiEdit|NotebookEdit` matcher 项。
   - 用 Edit 精确插入,保留现有 Task/Agent/SessionStart/UserPromptSubmit。
   - 验证:`python3 -c "import json; json.load(open('.claude/settings.json'))"` 合法;
     `python3 -c "..."` 断言 PreToolUse 有 3 个 matcher、含原 Task/Agent。

4. **改 CLAUDE.md**:新增"## 代码改动的 worktree 工作流"章节(design 要点)。
   - 措辞与全文风格一致(中文+英文术语、简洁)。

5. **最终全量校验**(review gate 2)
   - `python3 -m py_compile .claude/hooks/worktree-guard.py`
   - settings.json JSON 合法 + 结构断言
   - 重跑验证矩阵全绿
   - (真机)如在交互会话:主树 Edit 一个 `scripts/*.sh` 应被挡;`WORKTREE_GUARD=off` 应放行
   - 现有 Trellis 校验仍可用:`for f in bootstrap.sh lib/*.sh swkit scripts/*.sh; do bash -n "$f"; done`
     (确认未误伤仓库其它文件)

## 验证矩阵(喂 worktree-guard.py 的 stdin → 期望)

| # | tool_name | file_path | 环境 | 期望 |
|---|---|---|---|---|
| 1 | Edit | `/repo/scripts/git.sh` | — | **deny** |
| 2 | Write | `/repo/lib/common.sh` | — | **deny** |
| 3 | Edit | `/repo/bootstrap.sh` | — | **deny** |
| 4 | Edit | `/repo/swkit` | — | **deny** |
| 5 | Write | `/repo/scripts/newtool.sh` | — | **deny**(新代码也挡) |
| 6 | Edit | `/repo/scripts/git.sh` | `WORKTREE_GUARD=off` | 放行 |
| 7 | Edit | `/repo/scripts/git.sh` | `WORKTREE_GUARD=0` | 放行 |
| 8 | Edit | `/repo/.claude/worktrees/foo/scripts/git.sh` | — | 放行(在 worktree) |
| 9 | Edit | `/repo/CLAUDE.md` | — | 放行(白名单 *.md) |
| 10 | Edit | `/repo/README.md` | — | 放行 |
| 11 | Edit | `/repo/.trellis/tasks/x/prd.md` | — | 放行 |
| 12 | Edit | `/repo/docs/foo.md` | — | 放行 |
| 13 | Edit | `/repo/.claude/settings.json` | — | 放行(.claude/ 白名单) |
| 14 | Edit | `/home/conn/other/x.sh` | — | 放行(仓库外) |
| 15 | (坏 JSON / 缺 file_path) | — | — | 放行(fail-open)+ stderr 告警 |
| 16 | NotebookEdit | `/repo/x.ipynb`(notebook_path) | — | 放行(非代码集) |

> `/repo` 用真实仓库根 `/home/conn/workspace/ubuntu-setup` 代入;cwd 给仓库根。
> 期望"deny"= stdout 含 `"permissionDecision":"deny"`;"放行"= 无 deny 输出、exit 0。

## Review Gates
- **Gate 1**(步骤 2 后):判定逻辑验证矩阵全绿,再启用 settings.json。
- **Gate 2**(步骤 5):全量校验 + 真机/样例确认拦截与逃生阀,再交付。

## 回滚点
- settings.json:删新增 matcher 项即停用拦截(其余不受影响)。
- hook 脚本:`git rm .claude/hooks/worktree-guard.py`。
- CLAUDE.md:还原章节。
- 整体:本任务三处改动均可独立 `git checkout --` 还原。

## 交付后(Phase 3)
- 3.3 视情况把"worktree 工作流"沉淀进 spec(或就以 CLAUDE.md 章节为准)。
- 3.4 提交:中文 Conventional Commits,如
  `feat(hooks): worktree 强制隔离 — 主树改代码经 PreToolUse 拦截` —— **仅在用户明确要求时 commit**。
- 记录 `trellis init` 覆盖 settings.json 后的恢复方法(从 git/backup 取回 matcher 项)。
