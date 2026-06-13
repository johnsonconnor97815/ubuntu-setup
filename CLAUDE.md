# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

把一台**全新安装的 Ubuntu 机器**(含 Server / SSH / 无桌面)变成由 **LLM 驱动**的软件管理机器:

1. 仓库提供**一个 bash 脚本** `bootstrap.sh`——在全新 Ubuntu 上检查/补齐最小依赖,安装 **Claude Code CLI** 与 **Codex CLI**(默认官方 native installer,无 Node 依赖;npm 为可选回退),处理 `PATH`,并把 `skills/` 部署到用户机器。
2. 此后的一切软件安装/卸载/升级/查询,通过 **Skill / Agent 方式交给 LLM**(Claude Code 或 Codex)完成。本仓库提供 `skills/ubuntu-install/SKILL.md` 作为"安装知识"的载体——用户对 LLM 说"装个 docker",LLM 在 skill 守则下完成。

**没有 Python 包、没有 TUI、没有 catalog 引擎**——那是被放弃的旧方向(因为它要求先有 `python3-yaml`/`uv` 等前置依赖,违背"全新 Ubuntu 即用"的初衷)。仓库只交付一个 bash 脚本 + markdown 知识;运行时的"大脑"就是 LLM 本身。(放弃 catalog 引擎的 pivot 来龙去脉保留在 git 历史中。)

定位为**开源产品**:脚本与 LLM 都会在作者从未见过的陌生人机器上跑 `sudo`,所以信任与安全是一等约束,不是装饰。

## 当前状态

新架构已落地:`bootstrap.sh`(唯一入口)+ `skills/ubuntu-install/SKILL.md`(LLM 安装守则)+ `README.md` + 本文件。下面的"领域约束"即设计蓝图的全部锁定项;放弃 catalog 引擎的 pivot 来龙去脉保留在 git 历史中。

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
- **③非交互 apt**:每条 apt 命令都带 `DEBIAN_FRONTEND=noninteractive` 与 `-y --no-install-recommends`,绝不在无桌面 server 上卡 debconf 提示。
- **④fail-fast、可续跑、无回滚**:`set -euo pipefail`,首错即停并指明卡在哪一步;补救方式是重跑(幂等保证安全)。改配置文件前先备份——那份备份是唯一的"撤销"。
- **⑤skill 是面向用户机器的产品资产**:`skills/` 是部署到最终用户机器的产品,而非本仓库自用的开发工具。其内容必须在作者看不见的机器上站得住:渠道保守(apt 优先)、先计划后执行、显式验证。
