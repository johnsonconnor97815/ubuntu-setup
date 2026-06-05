# 跨机环境初始化 skill(Trellis + Codegraph,兼容 Claude Code 与 Codex CLI)

## Goal

让任意用户在新机器上 `git clone` 本仓库后,能通过一个**项目内 skill** 一键(或引导式)把本地开发环境拉到与原机一致:初始化 Trellis(开发者身份等本地态)+ 安装并索引 Codegraph,并把 codegraph MCP 注册进当前所用的 CLI。skill 本身随仓库提交,且**同时支持 Claude Code CLI 与 Codex CLI** 两种入口。

前置决定:整个 `.trellis/` 改为**全量提交**(full-share 模型),scaffolding 与本 skill 一并入库。

## What I already know(已查证)

### 环境一致需要补的缺口
- `.trellis/` 提交后,真正机器本地、不随仓库走的只有:`.developer`、`.current-task`、`.runtime/`、`.session-id`、`__pycache__`(见 `.trellis/.gitignore`)。→ Trellis 侧的「初始化」≈ 设定开发者身份。
- **Codegraph 完全未进仓库**:它是 npm 全局包,MCP 注册在**用户级**(Claude `~/.claude.json` 有 `codegraph: codegraph serve --mcp`;Codex `~/.codex/config.toml` 只有 context7/exa,**无 codegraph**)。→ 跨机一致的主要工作量在 codegraph。

### Codegraph(已验证,v0.9.9,包名 `@colbymchenry/codegraph`,`~/.local/bin/codegraph` 软链 npm 全局)
- `codegraph init [path]` — 初始化并建初始索引,生成 `.codegraph/` 目录(机器本地,需 gitignore)。
- `codegraph install -t <ids> -l <global|local> -y` — 把 MCP server 装进 agent,**原生支持 Claude Code、Codex CLI**(及 Cursor/opencode/Hermes)。`-t auto|all|none`、`-l global|local`、`-y` 非交互(默认 global+auto+auto-allow)、`--print-config <id>` 仅打印配置不写文件。
- `codegraph sync` 增量更新;`codegraph status` 看索引状态。
- 前置:Node/npm + `npm install -g @colbymchenry/codegraph`。

### Trellis 初始化
- `python3 .trellis/scripts/init_developer.py <name>` → 写 `.trellis/.developer` + 建 `.trellis/workspace/<name>/`。幂等:已存在则提示不覆盖。
- Claude Code:hooks 在 `.claude/hooks/` + `.claude/settings.json`(已提交,clone 即生效)。
- Codex:hooks 在 `.codex/hooks.json`,但**需用户级** `~/.codex/config.toml` 设 `[features].hooks = true` 并经 `/hooks` 一次性审批(项目级 config 不能开 feature flag)→ 这步无法被项目 skill 自动化,只能引导。

### Skill / 命令的投放位置(仓库现状)
- Claude Code skill:`.claude/skills/<name>/SKILL.md`(frontmatter:`name` + `description`)。
- Claude Code slash 命令:`.claude/commands/trellis/<name>.md`(纯 markdown,文件名 → `/trellis:<name>`)。
- 跨工具/Codex 可移植 skill:`.agents/skills/<name>/SKILL.md`(AGENTS.md 明确指引 Codex 等工具到这里找 skill)。
- Codex 原生 skill/命令发现机制 = **待查证**(见 Open Questions / Research)。

## Decision(ADR-lite,已与用户确认)
**Context**:要让新机 clone 后环境与原机一致,且 skill 跨 Claude Code / Codex 两端可用。
**Decision**:
1. **形态 = 纯 skill,无 wrapper 脚本**。codegraph 的 `init` / `install` 与 Trellis 的 `init_developer.py` 已是幂等命令,SKILL.md 直接编排这些命令 + 引导手动步骤,不另写 bootstrap 脚本。
2. **codegraph 位置 = 尽量 local**。Claude:`codegraph install -t claude -l local` → 写**项目级 `.mcp.json`**(提交进仓库,别人 clone 后 Claude 自动获得 codegraph,本地只需装 binary + 建索引)。Codex:`codegraph install -t codex`(只能用户级,SKILL 中说明并执行)。
3. **入口 = 双端 skill + Claude slash 命令**。`.claude/skills/trellis-setup/SKILL.md`(Claude)+ `.agents/skills/trellis-setup/SKILL.md`(Codex 原生扫描)+ `.claude/commands/trellis/setup.md`(给 Claude `/trellis:setup`)。三份内容尽量同源。
**Consequences**:`.mcp.json` 入库让 Claude 端近乎零配置;Codex 端因 codegraph/hooks 都是用户级,仍需用户跑一次 setup + 手动开 hooks。三处 skill 文本需保持同步(后续 `trellis update` 或手动维护)。

## Requirements
- [ ] 随仓库提交的 `trellis-setup` skill,三处投放:`.claude/skills/trellis-setup/SKILL.md`、`.agents/skills/trellis-setup/SKILL.md`、`.claude/commands/trellis/setup.md`。
- [ ] skill 覆盖并按序编排:
  1. **前置检测**:Node/npm 是否就绪;`codegraph` 是否在 PATH(否则 `npm install -g @colbymchenry/codegraph`)。
  2. **Codegraph 索引**:`codegraph init`(或已存在则 `codegraph sync`),生成/更新 `.codegraph/`。
  3. **Codegraph MCP 注册**:Claude → `codegraph install -t claude -l local`(写项目级 `.mcp.json`);Codex → `codegraph install -t codex`(用户级)。
  4. **Trellis 身份**:`python3 .trellis/scripts/init_developer.py <name>`(幂等)。
  5. **CLI 专属引导**:Codex 用户须 `~/.codex/config.toml` 开 `[features].hooks=true` + `/hooks` 审批(skill 只说明,不自动改)。
- [ ] skill 内按「当前是 Claude 还是 Codex」分支(同源内容,两段说明)。
- [ ] 幂等:重复运行不报错、不重复装(依赖各命令自身幂等性 + 存在性检测)。
- [ ] 项目级 `.mcp.json` 提交入库;`.codegraph/` 加入根 `.gitignore` 不入库。

## Acceptance Criteria
- [ ] 三个 skill/命令文件存在且内容同源、可被各自 CLI 发现。
- [ ] `.mcp.json` 含 codegraph 条目并已提交;根 `.gitignore` 含 `.codegraph/`。
- [ ] 按 skill 步骤在本机走一遍:`codegraph status` 显示有索引;`get_developer` 返回身份;重复跑一遍无副作用、无报错。
- [ ] SKILL.md frontmatter(`name`/`description`)合法,Claude/Codex 均能识别。

## Out of Scope(explicit)
- 安装 Node/npm 本身(只检测+给提示,不代装)。
- 非 Claude Code / Codex 的其他 agent 工具。
- 修改用户级 Codex feature flag(只能引导用户自己开)。

## Research References
- [`research/codex-cli-skills-and-mcp.md`](research/codex-cli-skills-and-mcp.md) — Codex 原生扫描 `.agents/skills/<name>/SKILL.md`(非 AGENTS.md 驱动);codegraph 的 Codex MCP 装在用户级;Codex hooks 需用户级开 + `/hooks` 审批。

## Research Notes(已收敛事实)
- **双端投放**:Claude Code 读 `.claude/skills/<name>/SKILL.md`;Codex 原生读 `.agents/skills/<name>/SKILL.md`。同一 skill 在两处各放一份(Trellis 现有惯例)。`.claude/commands/trellis/<name>.md` 可另给 Claude 一个 `/trellis:setup` slash 入口。
- **codegraph MCP 位置**:Codex 目标只写用户级 `~/.codex/config.toml`;Claude 的 `-l local` 才写项目级 `.mcp.json`。即「项目级随仓库」对 Codex 不成立 → 跨端一致更适合统一走 `global`。
- **不可自动化项**:Codex 用户须自行 `~/.codex/config.toml` 开 `[features].hooks=true` + `/hooks` 审批;Node/npm 需预装。skill 只检测+引导。

## Technical Notes
- 已读:`.trellis/scripts/init_developer.py`、`.codex/config.toml`、`.codex/hooks.json`、`AGENTS.md`、`.claude/skills/*/SKILL.md` 格式、`.claude/commands/trellis/*.md` 格式。
- codegraph help 输出已记录(init/install/sync/status/serve)。
