# worktree 强制隔离工作流(PreToolUse hook)

## Goal

让"修改代码的需求"自动落在隔离的 git worktree 里完成,验证通过后再合并回主分支,
避免直接在主 checkout(当前 `dev`)上改代码。核心强度由用户拍板为**强制拦截**:
用 Claude Code 的 `PreToolUse` hook 硬挡住"在主 checkout 里对代码文件的 Edit/Write",
而非仅靠 CLAUDE.md 软约定。

落地范围:**本项目仓库**(`.claude/settings.json` + `.claude/hooks/` + 仓库根 `CLAUDE.md`),
纳入 git 版本管理。

## 背景事实(已联网+本仓查证)

- Claude Code v2.1.50+ 原生支持 worktree:`claude --worktree`、会话内 `EnterWorktree`/`ExitWorktree`
  工具、`isolation: worktree` 子 agent、`WorktreeCreate`/`WorktreeRemove` hook、`.worktreeinclude`。
  默认 worktree 落点 `.claude/worktrees/<名>/`,新分支 `worktree-<名>`。
- `PreToolUse` hook 可拦截工具调用:从 stdin 读 JSON(含 `tool_name`、`tool_input.file_path`、`cwd`),
  通过退出码 2 + stderr,或输出 `{"hookSpecificOutput":{"hookEventName":"PreToolUse",
  "permissionDecision":"deny","permissionDecisionReason":"..."}}` 来拒绝并把理由回传给 Claude。
- `.claude/settings.json` 由 Trellis 在 `trellis init` 时一次性写入,**日常 Trellis 脚本不改写它**
  (`.trellis/scripts/` 全仓无写 settings.json 的代码),且重装会先备份到 `.trellis/.backup-*`。
  现有 hooks:SessionStart、PreToolUse[Task,Agent]、UserPromptSubmit——新增项需保留它们。
- `.gitignore` 已含 `.claude/worktrees/`;`settings.local.json` 已设 `"worktree":{"baseRef":"head"}`
  (worktree 从当前 HEAD=dev 分支,而非 origin/HEAD=main)——基分支已正确,本任务不改。
- 已有 worktree 在用(`.claude/worktrees/codex-default-editor/`),方案需与之兼容。

## Requirements

### 必须(MVP)
1. **拦截**:在主 checkout 里对**代码文件**发起 Edit/Write/MultiEdit/NotebookEdit 时,
   hook 返回 `deny`,理由文本指引 Claude"先进 worktree 再改",并提示逃生阀。
2. **放行 worktree**:目标文件路径落在 `.claude/worktrees/<...>/` 下时一律放行。
3. **放行非代码**:文档/任务/配置类路径(见下"拦截范围")在主 checkout 也放行,避免锁死自己。
4. **逃生阀**:环境变量 `WORKTREE_GUARD` ∈ {`0`,`off`,`false`} 时整体放行(紧急直改/改 hook 本身)。
5. **配合指令**:仓库根 `CLAUDE.md` 增补一节"代码改动的 worktree 隔离工作流",
   告诉 Claude 被拒后调 `EnterWorktree`、在 worktree 内验证(`bash -n`+`shellcheck -x`+脚本契约自测)、
   验证通过后合并回 `dev`(`git merge`)、收尾 `ExitWorktree`,并写明逃生阀。
6. **不破坏现有 Trellis hooks**:settings.json 新增 PreToolUse 项,保留 SessionStart/Task/Agent/UserPromptSubmit。

### 不做(非目标)
- 不强制"合并前必须验证":hook 无法在 `git merge` 时刻介入(merge 走 Bash 工具),
  这一步靠 CLAUDE.md 工作流约定,不是 hook 硬保证。可作未来增强(拦截 Bash 的 merge/commit)。
- 不堵 Bash 旁路:用 `sed`/`tee`/`cat >` 经 Bash 改代码文件能绕过本 hook(已知边界,见风险)。
- 不改 worktree 创建逻辑(`WorktreeCreate` hook)、不改基分支(已是 head)。
- 不做自动 merge:Claude Code 有意不自动 merge,保持人/会话手动控制。

### 拦截范围(关键决策——待 review 确认)
**推荐"精确拦截代码、白名单放行其余",最小误伤**:
- **拦截**(主 checkout 内视为"代码"):`scripts/*.sh`(含 `TEMPLATE.sh`)、`lib/*.sh`、
  `bootstrap.sh`、`swkit`。
- **放行**(非代码,主 checkout 直接改):`.trellis/`、`.claude/`、`docs/`、`memory/`、
  仓库根及任意 `*.md`、`.git/`、`README*`、`.gitignore`、`*.json`/`*.conf` 等配置、scratchpad/tmp。
- 仓库外的绝对路径(如 `$HOME` 下文件)放行(本 hook 只治本仓代码)。

## Acceptance Criteria

- [ ] 主 checkout 内 Edit `scripts/git.sh` → 被 `deny`,reason 含 worktree 工作流指引与逃生阀说明。
- [ ] 主 checkout 内 Edit `lib/common.sh`、`bootstrap.sh`、`swkit` → 被 `deny`。
- [ ] `WORKTREE_GUARD=off`(或 `0`/`false`)时,上述 Edit → 放行(exit 0,无 deny)。
- [ ] 主 checkout 内 Edit `CLAUDE.md`、`README.md`、`.trellis/x.md`、`docs/y.md` → 放行。
- [ ] 路径在 `.claude/worktrees/foo/scripts/git.sh` 的 Edit → 放行。
- [ ] 现有 Trellis hooks(SessionStart/UserPromptSubmit/Task/Agent)注册仍在、行为不变。
- [ ] `.claude/settings.json` 是合法 JSON;hook 脚本 `python3 -m py_compile` 通过(或 bash 则 `bash -n`+`shellcheck`)。
- [ ] hook 在缺字段/坏 JSON/相对路径等边界输入下不崩(fail-open:异常时放行并打印告警,不挡正常工作)。
- [ ] `CLAUDE.md` 新增章节描述完整工作流(建→改→验证→合并→收尾)与逃生阀。

## 风险与边界(诚实记录)
- **Bash 旁路**:Edit/Write 系工具被拦,但 Bash 内重定向写文件不被拦。Claude 常规走 Edit/Write,
  故可接受;若要堵需加 PreToolUse[Bash] 检测(列为未来增强)。
- **fail-open vs fail-closed**:hook 自身异常时选择**放行**(fail-open),宁可漏挡不可锁死工作流。
- **trellis init 覆盖**:重装平台适配器可能重写 settings.json(有 backup)。在 design 记录恢复步骤。
- **新建代码文件也被拦**:Write 新 `scripts/foo.sh` 同样要求在 worktree——符合预期。

## Notes
- 用户选择:落地范围=本项目仓库;自动程度=强制拦截;走 Trellis 规划。
- baseRef 已在 `settings.local.json` 配为 head;若希望该设定也纳入 git,可在 design 评估
  是否迁入提交版 `settings.json`(待确认,默认不动)。
