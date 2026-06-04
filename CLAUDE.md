# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

为**全新安装的 Ubuntu 机器**自动化安装与配置软件的工具,使用 Python + bash 实现。

## 当前状态

仓库处于初始阶段,**尚无任何源代码**——目前仅有 `README.md`、`LICENSE`(MIT)和一份标准的 Python `.gitignore`。git 历史只有一个 "Initial commit"。

因此本文档暂无法描述实际架构与命令。**实现代码落地后,请在此补充**:
- 入口与运行方式:如何对一台目标机器执行安装(单条命令 / 引导脚本)。
- 软件清单的组织方式:声明式列表(YAML/TOML/JSON)还是逐条 bash 脚本;Python 与 bash 各自的职责边界(例如 Python 做编排、bash 做具体安装步骤)。
- 构建 / lint / 测试命令,含**运行单个测试**的方式。

## 领域约束

本项目特有、实现时需贯彻的关键点(非通用最佳实践):

- **目标是刚装好的 Ubuntu**:不能假设系统已预装基础系统以外的工具;软件安装通常走 `apt` 并需要 `sudo`,实现需考虑提权与免交互(`DEBIAN_FRONTEND=noninteractive`)。
- **幂等性**:安装流程应可在同一台机器上重复执行而不报错、不重复安装,便于增量补装与失败重试。
