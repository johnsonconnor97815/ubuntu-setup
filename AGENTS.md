# AGENTS.md

面向在本仓库工作的 AI 助手（Claude Code / Codex / 其他）的简短指引。

本仓库交付的是**一套脚本集合 + 部署器 + 守则**:

- `lib/common.sh` —— 共享库,把项目的**安全**契约写成可复用、被强制的代码(幂等探测、逐命令 `sudo_run`、非交互 apt、改前备份、保守 vendor 渠道)。末尾 `source lib/ui.sh`。
- `lib/ui.sh` —— 共享库,把**现代 TUI 渲染**写成可复用代码(安全契约的视觉孪生):alt-screen 生命周期 + trap 还原、`ui_pick`/`ui_confirm`/`ui_input`/`ui_notify`/`ui_run`、`ui_catalog`、`ui_badge`/`ui_header`/`ui_footer`/`ui_row`/`ui_read_key`、i18n `ui_t`。纯 bash + ANSI,**无 whiptail 依赖**,非富终端回退纯文本编号菜单,无 TTY 静默降级。
- `scripts/<软件>.sh` —— 每软件一个、统一接口(`meta`/`status`/`install`/`remove`/可选 `configure`/`help`)的脚本,**装/配/管理功能的唯一实现**;另有 **`ui` 入口模式**(由 `kit_dispatch` 路由,**不进 `meta` 的 `ops`**)打开该软件**自己的交互管理界面**——脚本定义 `ui()` 则用它,否则由 `ui_default_menu` 按 `ops` 合成。`scripts/TEMPLATE.sh` 是新脚本起步模板(含 `ui()` 注释样例)。
- `swkit` —— 薄启动器:`swkit <软件> <操作>` / `swkit <软件>`(开该软件界面)/ `swkit ui`(开总目录)/ `list` / `search`。
- `bootstrap.sh` —— **启动器**:补依赖、把 kit 部署到 git 跟踪的 `~/.local/share/ubuntu-setup`(vendor 分支 + merge,不盲覆盖)、部署 skills,然后开现代全屏 TUI——「安装软件」交给共享目录浏览器 `ui_catalog`(按类别列脚本、标已装、`→` 钻进各脚本**自己的** `ui()`),「设置」页切语言 + 免密 sudo 开关;无终端走 headless。
- `skills/*/SKILL.md` —— 部署到用户机器的守则:`ubuntu-install`(如何**用**脚本 + 如何**演进**脚本)、`zsh-setup`(zsh 品味对话 + 演进 `scripts/zsh.sh`)。新增 skill 时把目录名加进 `bootstrap.sh` 的 `SKILLS` 数组。

三个入口(TUI / `swkit` / LLM 经 skill)调用同一批脚本;**LLM 还独特地负责为未覆盖的软件写新脚本、修过时脚本**——脚本提供稳定执行,LLM 让脚本与时俱进。没有编译工具链,没有 Python 包,没有数据驱动 catalog 引擎。

开工前先读 `CLAUDE.md`(项目目标、不可妥协项、校验命令)。校验:

```bash
for f in bootstrap.sh lib/common.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done   # 语法
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/ui.sh bootstrap.sh  # 全部带 -x(都 source lib)
./bootstrap.sh --help
```

**漂移注意**:安全不可妥协项现**同时**作为 `lib/common.sh` 的代码强制、与两个 `SKILL.md` 的「编写契约」散文存在——改 lib 的安全语义必须同步 skill 的契约散文,反之亦然。同理 **UI 契约**(`ui()` 约定、`ui` 是入口模式而非 op、三档终端降级)同时落在 `lib/ui.sh`、`scripts/TEMPLATE.sh` 与 skill 散文。(旧的「每软件配置逻辑双写在 bootstrap bash 与 skill 散文」已被消除:唯一来源是脚本。)
