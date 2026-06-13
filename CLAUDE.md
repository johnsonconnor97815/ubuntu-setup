# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

把一台**全新安装的 Ubuntu 机器**(含 Server / SSH / 无桌面)变成由 **LLM 驱动**的软件管理机器:

1. 仓库提供**一个 bash 脚本** `bootstrap.sh`——有终端时默认进入 **whiptail TUI**(缺失则回退纯文本菜单):主菜单含「安装软件」与「设置」。「安装软件」是一个**精选目录**,按**类别 → 软件 → 操作(安装 / 卸载 / 配置)**三级浏览——类别有装机必备(git / curl / zsh)、常用软件(docker)、AI 编码 CLI(**Claude Code CLI**、**Codex CLI**,官方 native installer,无 Node 依赖)、运行时(**Node.js + npm**,apt)、LLM 资产(内置 skills);没有任何项被默认强制,每个软件只显示它真正支持的操作(无意义的「配置」不出现)。设置页可切界面语言(中文 / English / 日本語,持久化到 `~/.config/ubuntu-setup/config`)并开关 LLM 免密 sudo。每个操作在进度条后台进行、全量日志写 `~/.cache/ubuntu-setup/`,完成回菜单。带任一安装 flag 或无终端(如 CI)则走 headless(只装两个 CLI / Node / skills,目录里 git/docker/zsh 等仅 TUI 可管)。脚本仍负责检查/补齐最小依赖、处理 `PATH`、把 `skills/` 部署到用户机器。
2. 此后的一切软件安装/卸载/升级/查询,通过 **Skill / Agent 方式交给 LLM**(Claude Code 或 Codex)完成。本仓库提供 `skills/ubuntu-install/SKILL.md` 作为"安装知识"的载体——用户对 LLM 说"装个 docker",LLM 在 skill 守则下完成。

**没有 Python 包、没有数据驱动 catalog 引擎**——那个 Python/YAML 数据驱动的安装引擎是被放弃的旧方向(它要求先有 `python3-yaml`/`uv` 等前置依赖,违背"全新 Ubuntu 即用"的初衷)。仓库只交付一个 bash 脚本 + markdown 知识;运行时的"大脑"就是 LLM 本身。bootstrap 的 **whiptail TUI 是允许的**:它是纯 shell、零前置依赖(whiptail 缺失即回退文本菜单)。TUI 的「安装软件」提供一个**精选、写死的软件目录**(类别 → 软件 → 装/卸/配),仍是**纯 bash、有界、零数据驱动**——目录(`CATALOG`/`CAT_ITEMS`)与每个软件的装/卸/配都是手写 shell 函数(`sw_<key>_install` 等约定),**不是**那个被放弃的 Python/YAML 数据驱动 catalog 引擎。目录内是作者精选的少量常用软件(含 docker);**长尾/任意软件,以及 configure 的深度定制(如 zsh 的 Starship/插件),仍交给 LLM 的 skill,不进 TUI**。边界:TUI = 精选起步集的开箱即用(装/卸 + 最小安全配置);skill = 任意软件 + 深度配置。(放弃数据驱动 catalog 引擎、以及把 TUI 从"固定几项"扩成"精选目录"的 pivot 来龙去脉保留在 git 历史中。)

定位为**开源产品**:脚本与 LLM 都会在作者从未见过的陌生人机器上跑 `sudo`,所以信任与安全是一等约束,不是装饰。

## 当前状态

新架构已落地:`bootstrap.sh`(唯一入口)+ `skills/ubuntu-install/SKILL.md`(LLM 安装守则)+ `README.md` + 本文件。`bootstrap.sh` 现以 whiptail TUI 为默认交互入口:「安装软件」是三级精选目录(类别 → 软件 → 装/卸/配,`tui_catalog`/`tui_category`/`tui_software` → `run_op`),外加设置页(多语言 + 免密 sudo 开关);无终端或带任一安装 flag 时走 headless(保留 `--only`/`--method`/`--with-node`/`--skip-skills` 等 flag,只覆盖两个 CLI / Node / skills)。下面的"领域约束"即设计蓝图的全部锁定项;放弃数据驱动 catalog 引擎、及把 TUI 扩成精选目录的 pivot 来龙去脉保留在 git 历史中。

## 构建 / 校验命令

无编译工具链。校验脚本:

```bash
bash -n bootstrap.sh        # 语法检查(必过)
shellcheck bootstrap.sh     # 如已安装 shellcheck
./bootstrap.sh --help       # 用法说明
```

`bootstrap.sh` 设计为可 `source`(末尾 `BASH_SOURCE` 守卫),便于对依赖检查等函数做函数级单测。

## 领域约束

本项目特有、实现 `bootstrap.sh` 与 `skills/ubuntu-install/SKILL.md` 时需贯彻的关键点;本节即唯一来源。

- **目标是刚装好的 Ubuntu**:不能假设系统已预装基础系统以外的工具(最小 Server 镜像可能连 `curl` 都没有);apt 操作需提权与免交互(`DEBIAN_FRONTEND=noninteractive`)。但**不能假设机器是纯净的**——用户可能在既有环境上跑,改任何东西前先查、先备份、失败安全。
- **仅 Ubuntu/Debian**:不做多发行版支持。

以下为**不可妥协项**,`bootstrap.sh` 用代码强制,`SKILL.md` 用散文教给 LLM——两者会各自漂移,改一处必查另一处:

- **①幂等查活系统**:每个安装步骤都以观察真实系统为前提(`command -v`、`dpkg-query` 查 `install ok installed`、版本输出),绝不依赖记录的标志位;已装则报版本并跳过。重跑 `bootstrap.sh` 第二次是安全 no-op。
- **②绝不整体 root,逐命令 sudo**:脚本以普通用户身份跑,只对确需 root 的单条命令(apt)逐命令 `sudo`;官方 installer 与 `npm install -g` 一律以当前用户身份跑;**`sudo npm install -g` 严禁**(EACCES 的解法是 `npm config set prefix ~/.local`)。被 sudo 整体包裹时用 `SUDO_USER` 解析真实用户 home,绝不信任 `~`/`$HOME`。
  - **sudo 密码(两阶段)**:阶段 A 的 `bootstrap.sh` 由用户在自己终端直接运行,有真实 TTY,sudo 正常弹提示输密码;并在 TUI 的「设置」页通过 **开关(whiptail 对话框;缺失则回退 `/dev/tty` 文本 `[Y/n]`;headless 时为一次性提示)** 让用户**开/关** `/etc/sudoers.d/ubuntu-setup-llm`(`<user> ALL=(ALL) NOPASSWD:ALL`)——因为阶段 B 由 LLM 通过自己的 Bash 工具执行 sudo,**该环境无交互 TTY,无法输入密码**,不预先免密则 LLM 根本装不了软件。开关只走 UI、**不设命令行 flag**,显示当前状态且可双向切换(ON 写文件、OFF 删文件);文本回退从 `/dev/tty` 读(`curl|bash` 也能交互),非交互(无 TTY)保持现状——`have_tty` 须**真正 open `/dev/tty`** 探测(设备节点存在不等于可打开:无控制终端时 open 会 ENXIO,只看 `-r`/`-w` 权限位会误判为交互、把 headless 误导进 TUI);失败不致命(warn 并继续)、`sudo rm` 可撤销。阶段 B 的 LLM 仍必须先 `sudo -n true` 探测(**按退出码判断,不看文案**:classic sudo 与 sudo-rs 文案不同且会被本地化),通过则装(用户已接受提示时即通过),否则把特权命令交还用户(让其重跑 `bootstrap.sh` 接受提示,或自己执行),**严禁 echo/pipe/`sudo -S`/存密码,严禁自行写 NOPASSWD**。bootstrap.sh 用代码、两个 `SKILL.md`(ubuntu-install §3、zsh-setup §2/§8)用散文各自落地此规则,改一处必查其余。
- **③非交互 apt**:每条 apt 命令都带 `DEBIAN_FRONTEND=noninteractive` 与 `-y --no-install-recommends`,绝不在无桌面 server 上卡 debconf 提示。
- **④fail-fast、可续跑、无回滚**:`set -euo pipefail`,首错即停并指明卡在哪一步;补救方式是重跑(幂等保证安全)。改配置文件前先备份——那份备份是唯一的"撤销"。**例外**:headless 路径保持严格 fail-fast;但 TUI 里每个操作(装/卸/配)在 `run_op` 中单独执行,**操作失败不杀脚本**——记 `FAIL`、结果框点名失败项与 `~/.cache/ubuntu-setup/` 日志路径、回到操作菜单,靠幂等重跑补救(否则一次失败会把整个菜单会话带崩)。喂 `whiptail --gauge` 的子 shell 须 `trap '' PIPE`,gauge 若提前退出也要把操作跑完、状态照记,不被 SIGPIPE 杀掉。
- **⑤skill 是面向用户机器的产品资产**:`skills/` 是部署到最终用户机器的产品,而非本仓库自用的开发工具。其内容必须在作者看不见的机器上站得住:渠道保守(apt 优先)、先计划后执行、显式验证。
- **⑥configure 逻辑也是双处落地**:TUI 的「配置」操作(`sw_zsh_configure`、`sw_docker_configure`)只做**最小安全子集**(zsh 设默认登录 shell;docker 加 `docker` 组 + 起服务),且都先查活、改前幂等;深度定制归 LLM skill(zsh 的 Starship/插件/`.zshrc` 归 `zsh-setup`,其余软件归 `ubuntu-install`)。同一软件的配置知识因此同时活在 `bootstrap.sh` 的 bash 与 skill 的散文里——与 ② 的 sudo 规则一样,改一处必查另一处。新增/扩展某软件的 TUI 配置时,务必只放安全子集,别把 skill 的深度定制搬进 bash。
