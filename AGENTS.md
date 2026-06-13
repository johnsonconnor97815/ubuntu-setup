# AGENTS.md

面向在本仓库工作的 AI 助手（Claude Code / Codex / 其他）的简短指引。

本仓库交付的是**一套脚本集合 + 部署器 + 守则**:

- `lib/common.sh` —— 共享库,把项目的安全契约写成可复用、被强制的代码(幂等探测、逐命令 `sudo_run`、非交互 apt、改前备份、保守 vendor 渠道)。
- `scripts/<软件>.sh` —— 每软件一个、统一接口(`meta`/`status`/`install`/`remove`/可选 `configure`/`help`)的脚本,**装/配/管理功能的唯一实现**;`scripts/TEMPLATE.sh` 是新脚本起步模板。
- `swkit` —— 薄启动器:`swkit <软件> <操作>` / `list` / `search`。
- `bootstrap.sh` —— 唯一入口:补依赖、把 kit 部署到 git 跟踪的 `~/.local/share/ubuntu-setup`(vendor 分支 + merge,不盲覆盖)、部署 skills、提供动态目录 TUI(读各脚本 `meta`)/ headless。
- `skills/*/SKILL.md` —— 部署到用户机器的守则:`ubuntu-install`(如何**用**脚本 + 如何**演进**脚本)、`zsh-setup`(zsh 品味对话 + 演进 `scripts/zsh.sh`)。新增 skill 时把目录名加进 `bootstrap.sh` 的 `SKILLS` 数组。

三个入口(TUI / `swkit` / LLM 经 skill)调用同一批脚本;**LLM 还独特地负责为未覆盖的软件写新脚本、修过时脚本**——脚本提供稳定执行,LLM 让脚本与时俱进。没有编译工具链,没有 Python 包,没有数据驱动 catalog 引擎。

开工前先读 `CLAUDE.md`(项目目标、不可妥协项、校验命令)。校验:

```bash
bash -n bootstrap.sh lib/common.sh swkit          # 语法(对每个 scripts/*.sh 同样跑)
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh   # 脚本 source lib,需 -x
shellcheck lib/common.sh bootstrap.sh
./bootstrap.sh --help
```

**漂移注意**:不可妥协项现**同时**作为 `lib/common.sh` 的代码强制、与两个 `SKILL.md` 的「编写契约」散文存在——改 lib 的安全语义必须同步 skill 的契约散文,反之亦然。(旧的「每软件配置逻辑双写在 bootstrap bash 与 skill 散文」已被消除:唯一来源是脚本。)
