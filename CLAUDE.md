# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

把一台**全新安装的 Ubuntu 机器**(含 Server / SSH / 无桌面)变成由 **LLM 驱动**的软件管理机器。核心模型是**脚本集合**:

1. **脚本是所有安装 / 配置 / 管理功能的唯一权威实现。** 每个软件一个 `scripts/<key>.sh`,统一接口(`meta` / `status` / `install` / `remove` / 可选 `configure` / `help`),全部 `source` 共享库 `lib/common.sh`——后者把项目的安全契约写成**可复用、被强制的代码**(幂等探测、逐命令 sudo、非交互 apt、改前备份、保守的 vendor apt 渠道)。写一个合规脚本基本上就是调这些 helper;不安全写法(`sudo npm`、整体 root、`apt-key`)**故意没有原语**。

2. **三个入口调用同一批脚本**:① `bootstrap.sh` 的现代全屏 TUI(`lib/ui.sh` 自绘,**无 whiptail**,非富终端回退纯文本)——它钻进**每个脚本自己的 `ui()` 管理界面**;② 人直接跑脚本 / 薄启动器 `swkit <软件> <操作> [args]`(或 `swkit <软件>` 开该软件界面、`swkit ui` 开总目录);③ LLM 经 skill。LLM 在诸入口中**独特**:除**调用**脚本外,它还**组织、推荐、并演进**脚本——为未覆盖的软件**写新脚本**(借鉴官方文档与开源做法),**修过时脚本**(软件打包 / URL / 步骤变化导致失效时)。「脚本=稳定确定可测的执行」+「LLM 让脚本与时俱进」是整个设计的要点;因此**覆盖随时间增长**,仓库只交付**种子脚本集 + 机制**,不是预装大库。

3. 这**取代**了旧模型(LLM 凭 skill 散文规则即兴拼装原始安装命令),也**消除了旧的双写问题**(同一软件的配置逻辑既写在 bootstrap 的 bash 里、又活在 skill 散文里)。现在「怎么做」的唯一来源是脚本;skill 散文降级为「脚本必须满足的契约 + 如何用 / 如何演进脚本」。

**没有 Python 包、没有数据驱动 catalog 引擎**——那个 Python/YAML 被引擎解释的声明式安装清单是被放弃的旧方向(它要求先有 `python3-yaml`/`uv` 等前置依赖,违背"全新 Ubuntu 即用"的初衷)。脚本是**纯 bash、每软件一个、自硬编码自己的元数据**;TUI 通过读各脚本的 `meta` 子命令**动态发现**并归类——这是「只读脚本自报的有界元数据」,不是被放弃的 YAML 引擎。

**部署与演进**:kit(`lib/` + `scripts/` + `swkit`)部署到 `$KIT_HOME = ~/.local/share/ubuntu-setup/`,**该目录本身是一个 git 仓**。bootstrap 用 **vendor 分支 + `git merge`** 更新(绝不盲覆盖):出厂脚本落在 `vendor` 分支,用户 / LLM 的改动落在 `main`(工作树即 `main`),所以 LLM 新写的脚本不丢、出厂与本地的冲突被**显式暴露**(打印冲突文件,不自动解决)而非吞掉。LLM 的每次改动都被 git 跟踪(可回滚、可 PR 回上游)。`swkit` 软链到 `~/.local/bin/swkit`;skills 部署到 `~/.claude/skills/<name>/`(Claude Code)与 `~/.codex/prompts/<name>.md`(Codex)。

定位为**开源产品**:脚本与 LLM 都会在作者从未见过的陌生人机器上跑 `sudo`,所以信任与安全是一等约束,不是装饰。

## 当前状态

新架构已落地。真实交付物:

- `bootstrap.sh`——**启动器**:补 kit 依赖 → vendor-merge 部署 kit 到 `$KIT_HOME` → 部署 skills → 有终端时进 TUI(`run_tui` 用 `ui_pick` 开顶层菜单「安装软件/设置」,`esc/q` 退出;「安装软件」= `ui_catalog "$(kit_scripts_dir)"`,按类别列脚本、标已装、`→`/回车钻进各脚本**自己的 `ui()`**,`esc` 返回、`q` 退出;「设置」= 语言切换 + 免密 sudo 开关,`esc/q` 返回),否则走 headless(`run_headless`,flag:`--only`/`--method`/`--with-node`/`--skip-skills`/`--headless`/`--tui`,只覆盖两个 CLI / Node / skills 的安装)。**额外动作机制**:脚本可在 `meta` 的 `ops=` 里声明 install/remove/configure 之外的动作(如 zsh 的 `install-omz`/`uninstall-omz`/`default-shell`);`kit_dispatch` 把未知 op `<x>` 路由到 `do_<x>`(连字符转下划线)。**`ui` 是入口模式**(类同 `meta`/`status`/`help`,**不进 `meta.ops`**):`kit_dispatch ui` 在有 TTY 时调脚本的 `ui()`(无则 `ui_default_menu` 合成)、无 TTY 时打印「用 swkit <key> <op>」指引退 0。**带参动作**(zsh 的 `add-plugin <名|url>`/`remove-plugin`/`prompt <名>`)经 `kit_dispatch` 由 `swkit`/LLM 调用,**也**在 zsh 的 `ui()` 界面里交互可达(空格勾选、`a` 加 git 插件、提示符子菜单)。
- `lib/common.sh`——共享库,**安全**契约即代码(探测、`sudo_run`、apt、文件、vendor apt 渠道、`npm_global_writable`、`kit_dispatch`);末尾 `source lib/ui.sh`。
- `lib/ui.sh`——共享库,**现代 TUI 渲染即代码**(安全契约的视觉孪生):alt-screen 生命周期 + `trap` 还原 + `SIGWINCH`、`ui_pick`/`ui_confirm`/`ui_input`/`ui_notify`/`ui_run`/`ui_catalog`/`ui_default_menu`、`ui_badge`/`ui_header`/`ui_footer`/`ui_row`/`ui_read_key`、i18n `ui_t`。纯 bash+ANSI,无 whiptail;三档终端:富 TTY 全屏渲染、受限 TTY 纯文本编号菜单、无 TTY 静默降级。
- `scripts/*.sh`——脚本集合,种子集:`git` `curl` `zsh` `fonts` `docker` `ghostty` `node` `claude` `codex`(`docker`、`git`、`zsh`、`ghostty` 另有 `configure`,`ghostty` 还有 `default-terminal`;**每个脚本都手写了自己的 `ui()`**);外加 `scripts/TEMPLATE.sh`(LLM 演进时 `cp` 起步,含 `ui()` 注释样例)。`fonts.sh` 是**用户态 Nerd Font 管理器**(curated:`meslolgs` 旗舰 / `jetbrains-mono` / `firacode` / `hack`;装入 `~/.local/share/fonts` + `fc-cache`,**不用 sudo**;`install [name]`/`remove [name]`/`apply [name] [size] [target]`/`configure --font --size --target`;可把偏好保存到 `~/.config/ubuntu-setup/fonts.conf`,并用用户级 gsettings 应用到检测到的 Ptyxis / GNOME Terminal / GNOME 桌面 monospace;SSH 时给客户端终端指引——字形由本地客户端终端渲染,服务器侧应用只对本地显示生效)。`zsh.sh` 选 starship/p10k 时经 `KIT_SCRIPTS_DIR/fonts.sh` **真正安装** MesloLGS NF(取代旧的仅 `log_warn`)。`ghostty.sh` 是 **Ghostty 终端的安装+配置管理器**(渠道:apt〔26.04+〕→ 社区 `.deb`〔mkasberg/ghostty-ubuntu,按 `${arch}_${VERSION_ID}` 命中 GitHub release,适配 24.04/25.10〕→ snap `--classic`,**择高而用并打印所用渠道**;`configure` 管**主题**〔`theme`,数百内置,支持 `dark:…,light:…` 自动明暗,按 `ghostty +list-themes` 宽松校验〕/ **字体**〔`font-family`+`font-size`,curated Nerd Font 经 `KIT_SCRIPTS_DIR/fonts.sh` 自动装〕/ **常用项**〔`background-opacity`、`cursor-style`/blink、`window-padding`、`copy-on-select`、`mouse-hide-while-typing`、`confirm-close-surface`、`shell-integration`〕;偏好存 `~/.config/ubuntu-setup/ghostty.conf`,整体重生成受管 drop-in `~/.config/ghostty/ubuntu-setup`,并经**绝对路径 `config-file=`** 一次性 include 进用户 `~/.config/ghostty/config`——**不覆盖用户内容**、改前 `backup_file`、`config-file` 用绝对路径绕开相对解析与「cycle detected」。**`default-terminal`〔`off` 反转〕**把 Ghostty 设为默认终端:主力是用户态写 freedesktop **`xdg-terminal-exec`** 选择器(Ghostty 的 `.desktop` id 作 `~/.config/<desktop>-xdg-terminals.list` 首行、保留并去重其他终端,GNOME 25.04+ 的 Ctrl+Alt+T/「Open Terminal」走此),best-effort 再经 `sudo update-alternatives` 注册系统 **`x-terminal-emulator`**(Ghostty 不自注册故先 `--install` 再 `--set`;**仅 .deb/apt**,snap 跳过——存不了 `--gtk-single-instance`;失败/`RC_NEED_SUDO` 仅 `log_warn` 不中断);**故意不碰** legacy gsettings(25.04+ 会倒退现代链)/`$TERMINAL`。Ghostty 是桌面 GUI 终端:SSH/headless 下这些设置作用于**有显示器的机器**,install/configure/default-terminal 会据 `SSH_*` 如实提示)。`claude.sh` 不再只是安装器,而是 **Claude Code 扩展管理器**(组件管理器,同 `zsh.sh` 范式):`install`/`remove`/`status` 管 CLI 本体;装好后**外壳调用官方 `claude` CLI**(MCP、插件)+ 文件式(skills)管理三条扩展轴——curated 速选(MCP:`sequential-thinking`/`filesystem`/`memory`/`playwright`〔均 npx/Node〕、`context7`〔http〕;marketplace:`anthropics/claude-plugins-official`/`anthropics/skills`;skill:`pdf`/`docx`/`pptx`/`frontend-design`/`mcp-builder`,取自 `anthropics/skills` 子目录)+ 任意添加;带参 op `mcp-add`/`mcp-remove`/`mcp-search`/`marketplace-add`/`marketplace-remove`/`plugin-install`/`plugin-remove`/`plugin-enable`/`plugin-disable`/`skill-install`/`skill-remove`(默认 `--scope user`;**`meta.ops` 仍只 `install,remove`**,带参 op 由 `kit_dispatch` 路由、在 `ui()` 里交互可达——三段勾选界面 MCP/Plugins/Skills);全程用户态、**拒绝 sudo 包裹**、幂等(`claude mcp get`/`plugin list`/目录探测)、skill 删除前 tar 备份且 kit 自有 skill〔`ubuntu-install`/`zsh-setup`/`claude-extensions`〕受保护;`jq` 仅 `mcp-search` 用且缺失则降级;**绝不自动装 Node**〔指向 `swkit node install`〕、绝不 `sudo npm`)。
- `swkit`——薄启动器:`swkit <软件> <操作>` / `swkit <软件>`(无操作=开该软件 `ui` 界面)/ `swkit ui`(`ui_catalog` 总目录)/ `list`(按类别分组、标 `[installed]`)/ `search <term>` / `help`。
- `skills/ubuntu-install/SKILL.md`、`skills/zsh-setup/SKILL.md`、`skills/claude-extensions/SKILL.md`——「用 + 演进脚本」守则。
- `README.md` + 本文件。

设计蓝图(本节「领域约束」即其全部锁定项)见 `docs/superpowers/specs/2026-06-12-script-collection-llm-evolution-design.md`。**现代化 TUI + 脚本自有 UI 重构**(`lib/ui.sh`、`ui()` 约定、丢弃 whiptail、bootstrap 退化为启动器)见 `docs/superpowers/specs/2026-06-13-script-owned-tui-ui-refactor-design.md`。前一份 TUI-catalog spec(`2026-06-12-bootstrap-software-manager-tui-design.md`)**部分被取代**:其「类别 → 软件 → 操作」三级导航思想保留(现为「类别 → 软件 → 该软件自己的 `ui()`」),「装 / 配逻辑以 `sw_<key>_*` 内联函数写死在 bootstrap.sh 内」迁到 `scripts/`,而其 whiptail 渲染被 `lib/ui.sh` 取代。放弃数据驱动 catalog 引擎、内联函数迁成脚本集合、whiptail 迁成自绘 TUI 的 pivot 来龙去脉保留在 git 历史中。

## 构建 / 校验命令

无编译工具链。校验:

```bash
# 语法检查(必过)——bootstrap、两个库、每个脚本、launcher
for f in bootstrap.sh lib/common.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done

# shellcheck(保持零告警)。所有文件都 source lib(common.sh 再 source ui.sh),
# 统一带 -x 跟随 source 指令、用 SCRIPTDIR 让 source-path 相对每个文件解析:
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/ui.sh bootstrap.sh

./bootstrap.sh --help                      # 用法说明
```

`bootstrap.sh` 设计为可 `source`(末尾 `[[ "${BASH_SOURCE[0]}" == "$0" ]]` 守卫只在被执行时跑 `main`),便于对 `have_tty`、依赖检查等函数做函数级单测。`scripts/*.sh` 自身 `source` lib,所以脚本侧的静态检查走上面的 `shellcheck -x --source-path=SCRIPTDIR` 形式;脚本契约则用其自带子命令测(`<script> meta` 字段齐全且 `ops` 与实现一致、**`ops` 不含 `ui`**、`<script> status` 可独立运行、`<script> help` 不炸、**`<script> ui` 在无 TTY 下打印指引退 0**)。富屏渲染无法 headless 自动测,可用伪终端冒烟(`printf 'q' | TERM=xterm-256color script -qec '<script> ui' /dev/null`,确认渲染不崩、`q` 干净退出、终端复原)。

## 领域约束

本项目特有、实现 `bootstrap.sh` / `lib/common.sh` / `lib/ui.sh` / `scripts/*.sh` / 两个 `SKILL.md` 时需贯彻的关键点;本节即唯一来源。

- **目标是刚装好的 Ubuntu**:不能假设系统已预装基础系统以外的工具(最小 Server 镜像可能连 `curl`/`git` 都没有);apt 操作需提权与免交互(`DEBIAN_FRONTEND=noninteractive`)。但**不能假设机器是纯净的**——用户可能在既有环境上跑,改任何东西前先查、先备份、失败安全。
- **仅 Ubuntu/Debian**:不做多发行版支持。

以下为**不可妥协项**。它们现在**同时**作为 `lib/common.sh` 的代码强制、与 skill 散文的**编写契约**存在(skill 教 LLM 「当脚本作者」时怎么守这些底线)。**漂移警告(新形态)**:改 lib 的安全语义,必须同步 skill 的契约散文;反之亦然——两处描述的是同一份底线,会各自漂移。注意:**旧的「每软件 configure 逻辑双写在 bootstrap bash 与 skill 散文、改一处必查另一处」已被消除**——configure 的唯一来源是脚本(`do_configure`),skill 只讲「如何用 / 如何演进」,不再平行实现。

- **①幂等查活系统**:每个操作以观察真实系统为前提(`have_cmd` / `pkg_installed` 查 dpkg 恰为 `install ok installed` / 版本输出),绝不依赖记录的标志位。落地:lib 的探测原语 + 每脚本的 `status` 闸门(`do_install`/`do_remove` 先跑 `status`,已装则报版本跳过、未装则提示跳过)。`status` 退出码 0 当且仅当已装 / 已生效。重跑 `bootstrap.sh` 或任一脚本第二次都是安全 no-op。

- **②绝不整体 root,逐命令 sudo**:脚本以普通用户身份跑,只对确需 root 的单条命令逐命令提权。落地:lib 的 `sudo_run CMD...` 是**唯一**提权途径——`EUID==0` 直接执行;sudo 免密则 `sudo CMD`;有可写 `/dev/tty` 则 `sudo CMD`(正常弹密码);否则(LLM 的无 TTY shell)打印「请你自己执行:sudo CMD」并返回 `RC_NEED_SUDO=97`,脚本因 `set -e` 而停。`apt_install`/`apt_remove` 等都经它提权。官方 native installer 与 `npm install -g` 一律以当前用户身份跑;**`sudo npm install -g` 严禁**——`npm_global_writable` 在 prefix 不可写时停下并提示 `npm config set prefix ~/.local`,而非伸手 sudo。`sudo_run` **绝不** echo/pipe/here-string 密码进 `sudo -S`、**绝不**存密码、**绝不**自写 NOPASSWD 规则。被 sudo 整体包裹时用 `SUDO_USER` 解析真实用户 home/身份(见 `zsh.sh`/`docker.sh` 里的 `user="${SUDO_USER:-$(id -un)}"`),绝不信任 `~`/`$HOME`。
  - **sudo 密码(两阶段)**:阶段 A 的 `bootstrap.sh` 由用户在自己终端直接运行,有真实 TTY,sudo 正常弹提示;TUI 的「设置」页有**开关**(`ui_confirm` 模态;非富终端回退 `/dev/tty` 文本 `[Y/n]`;headless 时为一次性提示)开 / 关 `/etc/sudoers.d/ubuntu-setup-llm`(`<user> ALL=(ALL) NOPASSWD:ALL`)——因为阶段 B 由 LLM 经自己的 Bash 工具跑 sudo,**该环境无交互 TTY、无法输密**,不预先免密则 LLM 装不了软件。**特权写入经 `ui_run`**(它退出备用屏,sudo 密码提示走真实终端——比旧的进度条管道更正,旧方案靠 preauth 绕开 pipe 无法输密)。开关只走 UI、**不设命令行 flag**(见用户记忆:toggle 用交互提示而非 flag),显示当前状态且可双向切换。`have_tty` 须**真正 open `/dev/tty`** 探测(`true </dev/tty` 且 `true >/dev/tty`):设备节点存在不等于可打开,无控制终端时 open 会 ENXIO,只看 `-r`/`-w` 权限位会误判为交互、把 headless 误导进 TUI。`sudo_passwordless` 用 `sudo -n true` 的**退出码**判断,**不看文案**(classic sudo 与 sudo-rs 文案不同且会被本地化)。此规则在 `bootstrap.sh`(开关 UI)、`lib/common.sh`(`sudo_run`/`kit_have_tty`/`sudo_passwordless`)、`lib/ui.sh`(`ui_confirm`/`ui_run` 的渲染与退屏)、与两个 `SKILL.md` 的契约散文里各自落地——改一处必查其余。

- **③非交互 apt**:每条 apt 命令都免交互。落地:lib 的 `apt_install`(`env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends`)/ `apt_remove`(`remove` 而非 `purge`,保留用户配置)/ `apt_update_once`(进程内首次才真跑,用哨兵);脚本不自己写裸 `apt-get`。绝不在无桌面 server 上卡 debconf 提示。

- **④fail-fast、可续跑、无回滚**:脚本各自 `set -Eeuo pipefail`,首错即停;补救方式是重跑(幂等保证安全)。改配置文件前先 `backup_file`(时间戳副本是唯一的"撤销");`append_once`(`grep -qxF`)保证重跑不累积。**例外**:headless 路径保持严格 fail-fast;但交互界面里每个状态变更经 `ui_run "<标题>" -- <script> <op>` 单独跑(子进程),`ui_run` **退出备用屏**直接展示真实输出(apt/sudo 提示正常)、`tee` 到 `~/.cache/ubuntu-setup/` 日志、显示 `✓/✗`、回车再回屏。**操作失败(脚本非 0,含 `RC_NEED_SUDO`)不杀界面循环**——`ui_run` 返回退出码供调用方记录、点名日志路径、回菜单,靠幂等重跑补救;`ui_begin`/`ui_end` 的 `trap … EXIT INT TERM` 保证任何崩溃都复原终端(备用屏/光标/`stty`)。(旧的 `whiptail --gauge` 子 shell 与 `trap '' PIPE` 已随 whiptail 一并移除。)

- **⑤kit 与 skill 都是面向用户机器的产品资产**:`scripts/` + `lib/` + `swkit` 与 `skills/` 都部署到最终用户机器(陌生人机器),同一底线:渠道保守(渠道优先级 `apt` → vendor apt repo(`add_apt_keyring`/`add_apt_source`,keyring 进 `/etc/apt/keyrings` + `signed-by=`,**绝不** `apt-key`)→ snap → 官方 vendor 脚本(显示 URL)→ 手动二进制(最后手段))、先计划后执行、显式验证。它们必须在作者看不见的机器上站得住。

- **编写契约(LLM 写 / 修脚本时)**:`cp scripts/TEMPLATE.sh scripts/<key>.sh`,保留结构(`#!/usr/bin/env bash`、`set -Eeuo pipefail`、定位并 `source` lib、定义 `meta`/`status`/`do_install`/`do_remove`[/`do_configure`][/`ui`]/`usage`、末尾 `kit_dispatch "$@"`);**一切提权 / 包 / 文件操作走 lib helper**,绝不裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`;`meta` 的 `ops` 必须**恰好**列实现了的操作(**`ui` 是入口模式、不进 `ops`**),`category ∈ essentials|common|ai|runtime`(其余归 `other`);幂等(`do_install`/`do_remove` 闸在 `status` 上);改配置文件前备份、追加前 grep;先计划后执行、fail-fast、不回滚(重跑即补救,故须幂等);测试 `bash -n` → `shellcheck -x` → 脚本自身 `status`(装前 / 装后)→ `ui` 在无 TTY 退 0 →(伪终端冒烟富屏)→ 确认后真跑;改动在 `$KIT_HOME` 被 git 跟踪,`git commit` 留清晰信息,考虑 PR 回上游。
  - **`ui()`(交互界面,可选但鼓励)**:省略则 `kit_dispatch ui` 用 `ui_default_menu`(由 `meta.ops` 合成)兜底;手写则用 `lib/ui.sh` 原语——`if ! ui_supported; then ui_default_menu; return 0; fi` 起手、`ui_begin`/`ui_end` 包住循环、**每个状态变更经 `ui_run "<标题>" -- "$0" <op> [args]`**(退屏跑、可见输出+日志、回屏后重载状态),配合 `ui_pick`/`ui_confirm`/`ui_input`/`ui_notify`/`ui_badge`/`ui_header`/`ui_footer`/`ui_row`/`ui_read_key`。样板:`scripts/zsh.sh`(旗舰)、`scripts/TEMPLATE.sh`(注释样例)。**UI 契约漂移**:`ui()` 约定 / `ui` 非 op / 三档终端降级 同时落在 `lib/ui.sh`、`TEMPLATE.sh` 与两个 `SKILL.md`——改一处必查其余。
  - `configure` **默认**(无参)是**保守 headless 安全基线**;但脚本**可以把该软件的常用方案作为显式 opt-in 覆盖进来**(作者裁量)。例:`zsh.sh` 是一个**组件管理器**——框架(Oh My Zsh)/提示符/各插件可**独立装/卸/增/删**,状态记在 `~/.config/zsh/ubuntu-setup.conf`,每次改动整体重生成受管 drop-in `~/.config/zsh/ubuntu-setup.zsh`(收敛、不覆盖用户 `~/.zshrc`)。动作:`install-omz`/`uninstall-omz`、`add-plugin <名|git-url>`/`remove-plugin <名>`(kit 自管插件:已知集 + 任意 git)、`prompt <名>`、锁定安全的 `default-shell`、`configure` 一次性全量;**OMZ 原生插件**(独立于 kit 插件的另一维度,经 OMZ 的 `plugins=($OMZ_PLUGINS)` 启用)用 `add-omz-plugin <名>`/`remove-omz-plugin <名>`(curated:`git sudo extract colored-man-pages command-not-found docker docker-compose kubectl z`,加任意已存在于 `~/.oh-my-zsh/plugins` 的;**故意不含** autosuggestions/syntax-highlighting——那是 kit 自管插件,避免双重加载);**OMZ 设置逐项可配**用 `omz-setting <key> <value>`(`update`/`magic`/`untracked-dirty`/`correction`/`wait-dots`/`hist-stamps`,默认是保守的性能/非交互安全最佳实践,如 `update=disabled` 因 kit 用 git 管更新)。无参动作进 `meta.ops`,带参的 `add-plugin`/`remove-plugin`/`prompt`/`add-omz-plugin`/`remove-omz-plugin`/`omz-setting` 由 swkit/LLM 调用,**且在 zsh 的 `ui()` 里交互可达**(空格勾插件、`a` 加 git 插件、提示符子菜单、OMZ 开启时多出「Oh My Zsh plugins」勾选区 +「＋ add」行 +「Oh My Zsh settings」可调区——旧的「带参动作进不了 TUI」限制已不复存在)。`docker.sh` 的 `configure` 加 `docker` 组 + 起服务,`git.sh` 的 `configure` 设全局 user.name/email。`claude.sh` 同为**组件管理器**:`install`/`remove`/`status` 管 CLI 本体,装好后**外壳调用 `claude` CLI**(MCP、插件)+ 文件式(skills)管三轴,带参 op(`mcp-add`/`marketplace-add`/`plugin-install`/`skill-install` 等,默认 `--scope user`)由 swkit/LLM 调用且在 `ui()` 三段勾选界面里可达,用户态、拒绝 sudo 包裹、curated+任意添加、幂等。**唯一来源仍是脚本**;skill(`zsh-setup`、`claude-extensions`)负责**帮用户选**(品味、Nerd Font/SSH 取舍、MCP/插件的 token 成本与运行时/密钥/作用域、锁定安全纪律)与真正 bespoke 的定制 / 演进脚本。

- **安全考量(新攻击面)**:LLM 现在会**编写带 sudo 的特权脚本**——开源产品、陌生人机器,这是真实攻击面。缓解:① lib 原语让安全写法成为默认、不安全写法无原语支持;② skill 强制「先计划后执行 + 用户确认」;③ 所有改动经 git,`git diff` 可见可审、可回滚;④ 绝不自动写 NOPASSWD;⑤ 鼓励用户 / 上游 review 后才信任 LLM 新脚本。
