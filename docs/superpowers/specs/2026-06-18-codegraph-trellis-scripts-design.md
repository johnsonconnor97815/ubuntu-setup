# CodeGraph 与 Trellis 脚本 — 设计

日期:2026-06-18
状态:已批准方向(两个独立脚本),进入实现

## 目标

为 ubuntu-setup 脚本集合新增两个 `category=ai` 的脚本,安装并配置两款面向 AI 编码代理(Claude Code / Codex 等)的工具:

- **CodeGraph**(`@colbymchenry/codegraph`,colbymchenry/codegraph)——本地代码知识图谱:tree-sitter 解析本地代码为 SQLite 图,跑成 100% 本地 MCP server 供 agent 查询,显著减少 token/工具调用。
- **Trellis**(`@mindfoldhq/trellis`,mindfold-ai/Trellis)——AI 编码工程框架 / agent harness:把 specs / tasks / memory 持久化进 repo 的 `.trellis/`,让各 agent 按统一工程标准工作。

两者都是全局 npm 包、纯 CLI(非 GUI)、headless/SSH 完美适用,与现有 `scripts/codex.sh`、`scripts/claude.sh` 范式同类。

## 结构决定

**两个独立脚本**(`scripts/codegraph.sh` + `scripts/trellis.sh`),不合并。理由:codegraph 与 trellis 是两款独立工具,各有独立的安装命令与配置语义,符合本项目「每软件一个 `scripts/<key>.sh`、各自硬编码自己的 `meta`」铁律;TUI 通过读各脚本 `meta` 动态发现并各自归入 `ai` 类。

## 不可妥协项(两脚本共同遵守)

- **绝不自动装 Node、绝不 `sudo npm`**:`install` 前用 `have_cmd node`/`have_cmd npm` 校验,缺失则 `log_err` 指向 `swkit node install` 并返回非 0;`npm install -g` 前过 `npm_ensure_user_prefix`:prefix 为系统默认(`/usr`、`/usr/local`)时以用户态把前缀设到 `~/.local`(写 `~/.npmrc`,无 sudo、可 `npm config delete prefix` 还原)再装,自定义且不可写的前缀则退回报错;`npm_global_writable` 仍是底层判定,绝不伸手 sudo。
- **幂等查活系统**:`do_install`/`do_remove`/`do_configure` 先跑 `status`(探测真实系统:`have_cmd <cmd>`),已装跳过、未装提示。
- **fail-fast、不回滚**:`set -Eeuo pipefail`,重跑即补救。
- **i18n**:UI 描述性文案经本地 `*_I18N` 表(en/zh/ja,结构同 `ui_t`),专有名词(CodeGraph/Trellis/包名/`node`/`npm` 等)不译。
- **入口模式 `ui`**:不进 `meta.ops`;无 TTY 时 `kit_dispatch` 打印指引退 0。
- 安装后经 `ensure_local_bin_on_path` 提示 PATH。

## scripts/codegraph.sh

`meta`:`key=codegraph` `name=CodeGraph` `category=ai` `ops=install,remove,configure`
`desc=Local code knowledge graph (MCP server) for AI coding agents`

- **`status`**:`have_cmd codegraph` 为准(返回 0 当且仅当已装);版本 best-effort(`codegraph --version` 取首行,失败回退 `codegraph (installed)`)。
- **`do_install`**:校验 `node`+`npm`(缺则指向 `swkit node install`)→ `npm_ensure_user_prefix`(无 sudo 建用户态 `~/.local` 前缀)→ `npm install -g @colbymchenry/codegraph` → `ensure_local_bin_on_path`。
- **`do_configure`**(codegraph 真正的"配置"):`codegraph install --yes`(自动探测并把 MCP server 接入 Claude Code/Codex 等 agent)。可选 `--target=claude,codex,...` 透传指定 agent。先 `status` 闸门(未装则提示先 install)。stdin 喂 `</dev/null` 防挂起。
- **`do_remove`**:best-effort `codegraph uninstall`(反注册 agent 配置;`--yes` + `</dev/null` 防挂起、失败仅 warn)→ `npm uninstall -g @colbymchenry/codegraph` → `rm -f ~/.local/bin/codegraph`;仍在 PATH 则 warn。提示项目内 `.codegraph/` 用户数据保留。
- **per-repo `codegraph init -i` 不做成 op**:它是用户在各自 repo 内建索引的用法动作,装/配后经 `ui_notify` 与 `help` 告知,脚本本身聚焦机器级安装 + agent 接入(YAGNI)。
- **`ui`**:bespoke 全屏(仿 `codex.sh`):未装=[install];已装=[configure(接入 agent)]+[remove(确认)]。

## scripts/trellis.sh

`meta`:`key=trellis` `name=Trellis` `category=ai` `ops=install,remove,configure`
`desc=AI coding engineering framework (specs/tasks/memory in your repo)`

- **`status`**:`have_cmd trellis` 为准;版本 best-effort(同上回退 `trellis (installed)`)。
- **`do_install`**:校验 `node`+`npm` 且 Node 主版本 ≥ 18(硬性,文档要求);**软**校验 `python3` ≥ 3.9(缺/旧仅 `log_warn`——npm 装包不需 Python,Python 是运行时部分功能所需,不阻断安装)→ `npm_ensure_user_prefix`(无 sudo 建用户态 `~/.local` 前缀)→ `npm install -g @mindfoldhq/trellis@latest` → `ensure_local_bin_on_path`。
- **`do_configure`**(trellis 唯一有意义的配置 = 每仓库 init):在**当前 git 仓库**跑 `trellis init -u <name>`。
  - 守门:`git rev-parse --is-inside-work-tree` 失败则 `log_err` 指引「先 `cd` 进你的项目 repo」并返回非 0(避免在任意目录写出 `.trellis/`)。
  - 默认 `<name>`:`git config user.name` → 回退 `id -un`;为空则报错。
  - flag:`--user <name>`/`-u <name>` 设用户名;其余参数(如 `--claude --codex --cursor --opencode`)原样透传给 `trellis init`。无参=保守基线(默认用户名、不指定平台)。
  - stdin 喂 `</dev/null` 防挂起。
- **`do_remove`**:`npm uninstall -g @mindfoldhq/trellis` → `rm -f ~/.local/bin/trellis`;仍在 PATH 则 warn。提示各 repo 内 `.trellis/` 保留。
- **`ui`**:bespoke 全屏:未装=[install];已装=[configure(在当前 repo init)]+[remove(确认)]。

## SSH / headless

两者皆 CLI,无「仅桌面」提示。codegraph 接入 agent 配置、trellis 写 repo 文件,均在 headless 正常工作。

## 校验

每脚本:`bash -n` → `shellcheck -x --source-path=SCRIPTDIR` 零告警 → `meta` 字段齐全且 `ops` 与实现一致且不含 `ui` → `status` 可独立运行 → `help` 不炸 → `ui` 无 TTY 退 0 →(可选)伪终端冒烟。整集合回归运行 CLAUDE.md 的两条校验命令。

## 不实现(YAGNI)

- 不做数据驱动 catalog;不动 bootstrap/lib/其他脚本(TUI 自动发现新脚本)。
- codegraph 的 per-repo `init`、trellis 的多平台精细编排留给用户在 repo 内手动跑。
