# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

把一台**全新安装的 Ubuntu 机器**(含 Server / SSH / 无桌面)变成由 **LLM 驱动**的软件管理机器。核心模型是**脚本集合**:

1. **脚本是所有安装 / 配置 / 管理功能的唯一权威实现。** 每个软件一个 `scripts/<key>.sh`,统一接口(`meta` / `status` / `install` / `remove` / 可选 `configure` / `help`),全部 `source` 共享库 `lib/common.sh`——后者把项目的安全契约写成**可复用、被强制的代码**(幂等探测、逐命令 sudo、非交互 apt、改前备份、保守的 vendor apt 渠道)。写一个合规脚本基本上就是调这些 helper;不安全写法(`sudo npm`、整体 root、`apt-key`)**故意没有原语**。

2. **三个入口调用同一批脚本**:① `bootstrap.sh` 的 whiptail TUI(缺失则回退纯文本);② 人直接跑脚本 / 薄启动器 `swkit <软件> <操作> [args]`;③ LLM 经 skill。LLM 在诸入口中**独特**:除**调用**脚本外,它还**组织、推荐、并演进**脚本——为未覆盖的软件**写新脚本**(借鉴官方文档与开源做法),**修过时脚本**(软件打包 / URL / 步骤变化导致失效时)。「脚本=稳定确定可测的执行」+「LLM 让脚本与时俱进」是整个设计的要点;因此**覆盖随时间增长**,仓库只交付**种子脚本集 + 机制**,不是预装大库。

3. 这**取代**了旧模型(LLM 凭 skill 散文规则即兴拼装原始安装命令),也**消除了旧的双写问题**(同一软件的配置逻辑既写在 bootstrap 的 bash 里、又活在 skill 散文里)。现在「怎么做」的唯一来源是脚本;skill 散文降级为「脚本必须满足的契约 + 如何用 / 如何演进脚本」。

**没有 Python 包、没有数据驱动 catalog 引擎**——那个 Python/YAML 被引擎解释的声明式安装清单是被放弃的旧方向(它要求先有 `python3-yaml`/`uv` 等前置依赖,违背"全新 Ubuntu 即用"的初衷)。脚本是**纯 bash、每软件一个、自硬编码自己的元数据**;TUI 通过读各脚本的 `meta` 子命令**动态发现**并归类——这是「只读脚本自报的有界元数据」,不是被放弃的 YAML 引擎。

**部署与演进**:kit(`lib/` + `scripts/` + `swkit`)部署到 `$KIT_HOME = ~/.local/share/ubuntu-setup/`,**该目录本身是一个 git 仓**。bootstrap 用 **vendor 分支 + `git merge`** 更新(绝不盲覆盖):出厂脚本落在 `vendor` 分支,用户 / LLM 的改动落在 `main`(工作树即 `main`),所以 LLM 新写的脚本不丢、出厂与本地的冲突被**显式暴露**(打印冲突文件,不自动解决)而非吞掉。LLM 的每次改动都被 git 跟踪(可回滚、可 PR 回上游)。`swkit` 软链到 `~/.local/bin/swkit`;skills 部署到 `~/.claude/skills/<name>/`(Claude Code)与 `~/.codex/prompts/<name>.md`(Codex)。

定位为**开源产品**:脚本与 LLM 都会在作者从未见过的陌生人机器上跑 `sudo`,所以信任与安全是一等约束,不是装饰。

## 当前状态

新架构已落地。真实交付物:

- `bootstrap.sh`——唯一入口:补 kit 依赖 → vendor-merge 部署 kit 到 `$KIT_HOME` → 部署 skills → 有终端时进 TUI(`run_tui` → `tui_catalog`/`tui_category`/`tui_software` → `run_op`,读各脚本 `meta` 动态归类**并列出其 `ops`**),否则走 headless(`run_headless`,flag:`--only`/`--method`/`--with-node`/`--skip-skills`/`--headless`/`--tui`,只覆盖两个 CLI / Node / skills 的安装)。**额外动作机制**:脚本可在 `meta` 的 `ops=` 里声明 install/remove/configure 之外的动作(如 zsh 的 `install-omz`/`uninstall-omz`/`default-shell`);`kit_dispatch` 把未知 op `<x>` 路由到 `do_<x>`(连字符转下划线),TUI/`swkit` 自动列出——通用、其他脚本也可用。**带参动作**(如 zsh 的 `add-plugin <名|url>`/`remove-plugin`/`prompt <名>`)可不列进 `meta.ops`(故不进 TUI)但仍经 `kit_dispatch` 由 `swkit`/LLM 调用。
- `lib/common.sh`——共享库,安全契约即代码(探测、`sudo_run`、apt、文件、vendor apt 渠道、`npm_global_writable`、`kit_dispatch`)。
- `scripts/*.sh`——脚本集合,种子集:`git` `curl` `zsh` `docker` `node` `claude` `codex`(`docker`、`zsh` 另有 `configure`);外加 `scripts/TEMPLATE.sh`(LLM 演进时 `cp` 起步)。
- `swkit`——薄启动器:`swkit <软件> <操作>` / `list`(按类别分组、标 `[installed]`)/ `search <term>` / `help`。
- `skills/ubuntu-install/SKILL.md`、`skills/zsh-setup/SKILL.md`——「用 + 演进脚本」守则。
- `README.md` + 本文件。

设计蓝图(本节「领域约束」即其全部锁定项)见 `docs/superpowers/specs/2026-06-12-script-collection-llm-evolution-design.md`。前一份 TUI-catalog spec(`2026-06-12-bootstrap-software-manager-tui-design.md`)**部分被取代**:其「类别 → 软件 → 操作」三级导航思想保留,但「装 / 配逻辑以 `sw_<key>_*` 内联函数写死在 bootstrap.sh 内」的实现已迁移到 `scripts/`。放弃数据驱动 catalog 引擎、及把内联函数迁成脚本集合的 pivot 来龙去脉保留在 git 历史中。

## 构建 / 校验命令

无编译工具链。校验:

```bash
# 语法检查(必过)——bootstrap、库、每个脚本、launcher
bash -n bootstrap.sh
bash -n lib/common.sh
bash -n swkit
for f in scripts/*.sh; do bash -n "$f"; done

# shellcheck(保持零告警)。scripts/ 与 swkit 会 source lib/common.sh,
# 必须带 -x 跟随 source 指令;用 SCRIPTDIR 让 source-path 相对每个文件解析:
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh
shellcheck lib/common.sh bootstrap.sh      # 二者在 -x 下也全绿

./bootstrap.sh --help                      # 用法说明
```

`bootstrap.sh` 设计为可 `source`(末尾 `[[ "${BASH_SOURCE[0]}" == "$0" ]]` 守卫只在被执行时跑 `main`),便于对 `have_tty`、依赖检查等函数做函数级单测。`scripts/*.sh` 自身 `source` lib,所以脚本侧的静态检查走上面的 `shellcheck -x --source-path=SCRIPTDIR` 形式;脚本契约则用其自带子命令测(`<script> meta` 字段齐全且 `ops` 与实现一致、`<script> status` 可独立运行、`<script> help` 不炸)。

## 领域约束

本项目特有、实现 `bootstrap.sh` / `lib/common.sh` / `scripts/*.sh` / 两个 `SKILL.md` 时需贯彻的关键点;本节即唯一来源。

- **目标是刚装好的 Ubuntu**:不能假设系统已预装基础系统以外的工具(最小 Server 镜像可能连 `curl`/`git` 都没有);apt 操作需提权与免交互(`DEBIAN_FRONTEND=noninteractive`)。但**不能假设机器是纯净的**——用户可能在既有环境上跑,改任何东西前先查、先备份、失败安全。
- **仅 Ubuntu/Debian**:不做多发行版支持。

以下为**不可妥协项**。它们现在**同时**作为 `lib/common.sh` 的代码强制、与 skill 散文的**编写契约**存在(skill 教 LLM 「当脚本作者」时怎么守这些底线)。**漂移警告(新形态)**:改 lib 的安全语义,必须同步 skill 的契约散文;反之亦然——两处描述的是同一份底线,会各自漂移。注意:**旧的「每软件 configure 逻辑双写在 bootstrap bash 与 skill 散文、改一处必查另一处」已被消除**——configure 的唯一来源是脚本(`do_configure`),skill 只讲「如何用 / 如何演进」,不再平行实现。

- **①幂等查活系统**:每个操作以观察真实系统为前提(`have_cmd` / `pkg_installed` 查 dpkg 恰为 `install ok installed` / 版本输出),绝不依赖记录的标志位。落地:lib 的探测原语 + 每脚本的 `status` 闸门(`do_install`/`do_remove` 先跑 `status`,已装则报版本跳过、未装则提示跳过)。`status` 退出码 0 当且仅当已装 / 已生效。重跑 `bootstrap.sh` 或任一脚本第二次都是安全 no-op。

- **②绝不整体 root,逐命令 sudo**:脚本以普通用户身份跑,只对确需 root 的单条命令逐命令提权。落地:lib 的 `sudo_run CMD...` 是**唯一**提权途径——`EUID==0` 直接执行;sudo 免密则 `sudo CMD`;有可写 `/dev/tty` 则 `sudo CMD`(正常弹密码);否则(LLM 的无 TTY shell)打印「请你自己执行:sudo CMD」并返回 `RC_NEED_SUDO=97`,脚本因 `set -e` 而停。`apt_install`/`apt_remove` 等都经它提权。官方 native installer 与 `npm install -g` 一律以当前用户身份跑;**`sudo npm install -g` 严禁**——`npm_global_writable` 在 prefix 不可写时停下并提示 `npm config set prefix ~/.local`,而非伸手 sudo。`sudo_run` **绝不** echo/pipe/here-string 密码进 `sudo -S`、**绝不**存密码、**绝不**自写 NOPASSWD 规则。被 sudo 整体包裹时用 `SUDO_USER` 解析真实用户 home/身份(见 `zsh.sh`/`docker.sh` 里的 `user="${SUDO_USER:-$(id -un)}"`),绝不信任 `~`/`$HOME`。
  - **sudo 密码(两阶段)**:阶段 A 的 `bootstrap.sh` 由用户在自己终端直接运行,有真实 TTY,sudo 正常弹提示;TUI 的「设置」页有**开关**(whiptail 对话框;缺失则回退 `/dev/tty` 文本 `[Y/n]`;headless 时为一次性提示)开 / 关 `/etc/sudoers.d/ubuntu-setup-llm`(`<user> ALL=(ALL) NOPASSWD:ALL`)——因为阶段 B 由 LLM 经自己的 Bash 工具跑 sudo,**该环境无交互 TTY、无法输密**,不预先免密则 LLM 装不了软件。开关只走 UI、**不设命令行 flag**(见用户记忆:toggle 用交互提示而非 flag),显示当前状态且可双向切换。`have_tty` 须**真正 open `/dev/tty`** 探测(`true </dev/tty` 且 `true >/dev/tty`):设备节点存在不等于可打开,无控制终端时 open 会 ENXIO,只看 `-r`/`-w` 权限位会误判为交互、把 headless 误导进 TUI。`sudo_passwordless` 用 `sudo -n true` 的**退出码**判断,**不看文案**(classic sudo 与 sudo-rs 文案不同且会被本地化)。此规则在 `bootstrap.sh`(开关 UI)、`lib/common.sh`(`sudo_run`/`kit_have_tty`/`sudo_passwordless`)、与两个 `SKILL.md` 的契约散文里各自落地——改一处必查其余。

- **③非交互 apt**:每条 apt 命令都免交互。落地:lib 的 `apt_install`(`env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends`)/ `apt_remove`(`remove` 而非 `purge`,保留用户配置)/ `apt_update_once`(进程内首次才真跑,用哨兵);脚本不自己写裸 `apt-get`。绝不在无桌面 server 上卡 debconf 提示。

- **④fail-fast、可续跑、无回滚**:脚本各自 `set -Eeuo pipefail`,首错即停;补救方式是重跑(幂等保证安全)。改配置文件前先 `backup_file`(时间戳副本是唯一的"撤销");`append_once`(`grep -qxF`)保证重跑不累积。**例外**:headless 路径保持严格 fail-fast;但 TUI 里每个操作在 `run_op` 中单独跑脚本,**操作失败(脚本非 0,含 `RC_NEED_SUDO`)不杀会话**——记 `FAIL`、结果框点名失败项与 `~/.cache/ubuntu-setup/` 日志路径、回操作菜单,靠幂等重跑补救。喂 `whiptail --gauge` 的子 shell 须 `trap '' PIPE`,gauge 若提前退出也要把操作跑完、状态照记,不被 SIGPIPE 杀掉。

- **⑤kit 与 skill 都是面向用户机器的产品资产**:`scripts/` + `lib/` + `swkit` 与 `skills/` 都部署到最终用户机器(陌生人机器),同一底线:渠道保守(渠道优先级 `apt` → vendor apt repo(`add_apt_keyring`/`add_apt_source`,keyring 进 `/etc/apt/keyrings` + `signed-by=`,**绝不** `apt-key`)→ snap → 官方 vendor 脚本(显示 URL)→ 手动二进制(最后手段))、先计划后执行、显式验证。它们必须在作者看不见的机器上站得住。

- **编写契约(LLM 写 / 修脚本时)**:`cp scripts/TEMPLATE.sh scripts/<key>.sh`,保留结构(`#!/usr/bin/env bash`、`set -Eeuo pipefail`、定位并 `source` lib、定义 `meta`/`status`/`do_install`/`do_remove`[/`do_configure`]/`usage`、末尾 `kit_dispatch "$@"`);**一切提权 / 包 / 文件操作走 lib helper**,绝不裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`;`meta` 的 `ops` 必须**恰好**列实现了的操作,`category ∈ essentials|common|ai|runtime`(其余归 `other`);幂等(`do_install`/`do_remove` 闸在 `status` 上);改配置文件前备份、追加前 grep;先计划后执行、fail-fast、不回滚(重跑即补救,故须幂等);测试 `bash -n scripts/<key>.sh` → 脚本自身 `status`(装前 / 装后)→ 确认后真跑;改动在 `$KIT_HOME` 被 git 跟踪,`git commit` 留清晰信息,考虑 PR 回上游。`configure` **默认**(无参 / TUI 的「配置」动作)是**保守 headless 安全基线**;但脚本**可以把该软件的常用方案作为显式 opt-in 覆盖进来**(作者裁量)。例:`zsh.sh` 是一个**组件管理器**——框架(Oh My Zsh)/提示符/各插件可**独立装/卸/增/删**,状态记在 `~/.config/zsh/ubuntu-setup.conf`,每次改动整体重生成受管 drop-in `~/.config/zsh/ubuntu-setup.zsh`(收敛、不覆盖用户 `~/.zshrc`)。动作:`install-omz`/`uninstall-omz`、`add-plugin <名|git-url>`/`remove-plugin <名>`(已知插件集 + 任意 git)、`prompt <名>`、锁定安全的 `default-shell`、`configure` 一次性全量;无参动作进 `meta.ops`(TUI 可见),带参的 `add-plugin`/`remove-plugin`/`prompt` 由 swkit/LLM 调用。`docker.sh` 的加 `docker` 组 + 起服务。**唯一来源仍是脚本**;skill(`zsh-setup`)负责**帮用户选**(品味、Nerd Font/SSH 取舍、锁定安全纪律)与真正 bespoke 的定制 / 演进脚本。(此前「configure 只放最小安全子集、Starship/框架归 skill 对话」的边界已按作者要求**有意扩宽**:常用方案进脚本,skill 转为「帮选 + 兜底」。)

- **安全考量(新攻击面)**:LLM 现在会**编写带 sudo 的特权脚本**——开源产品、陌生人机器,这是真实攻击面。缓解:① lib 原语让安全写法成为默认、不安全写法无原语支持;② skill 强制「先计划后执行 + 用户确认」;③ 所有改动经 git,`git diff` 可见可审、可回滚;④ 绝不自动写 NOPASSWD;⑤ 鼓励用户 / 上游 review 后才信任 LLM 新脚本。
