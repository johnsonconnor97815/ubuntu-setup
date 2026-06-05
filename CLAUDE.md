# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目目标

面向**全新安装的 Ubuntu 机器**(含 Server / SSH / 无桌面)的**持续软件管理器**:随时装 / 卸 / 升级 / 查看,而非一次性安装脚本。带终端 TUI(Textual),使用 Python 大脑 + bash/subprocess 手实现。

每个即时操作都自动记录进一份**可导出清单**;把清单在新机上重放即可复现整套配置——因此它既是**管理器**(交互式生命周期),又是**provisioner**(可复现的初始化),清单是二者的桥梁。

定位为**开源产品**:工具会在作者从未见过的陌生人机器上跑 `sudo`,所以信任与安全是一等约束,不是装饰。

## 当前状态

产品源码**尚未开始**——仓库目前仅有 `README.md`、`LICENSE`(MIT)、Python `.gitignore` 与 `.trellis/` 脚手架。

但设计蓝图已锁定于 `.trellis/spec/`,本文档不再重复其细节,请按需查阅:
- 锁定决策与 why:[`.trellis/spec/design-direction.md`](.trellis/spec/design-direction.md)。
- 项目定位 + 7 条不可妥协项:[`.trellis/spec/index.md`](.trellis/spec/index.md)。
- 入口 / 运行方式、模块布局与脑·手·脸边界:[`core/directory-structure.md`](.trellis/spec/core/directory-structure.md)。
- 声明式清单的组织、provider 协议与命令惯用法:[`core/catalog-and-providers.md`](.trellis/spec/core/catalog-and-providers.md)、[`catalog/authoring-guidelines.md`](.trellis/spec/catalog/authoring-guidelines.md)。
- 幂等 / 计划 / 执行 / 可导出清单:[`core/idempotency-and-execution.md`](.trellis/spec/core/idempotency-and-execution.md)。
- TUI 边界与结构:[`tui/ui-guidelines.md`](.trellis/spec/tui/ui-guidelines.md)。

> 构建 / lint / 测试命令在源码落地后于此补充;现阶段无可运行的工具链。

## 领域约束

本项目特有、实现时需贯彻的关键点(非通用最佳实践);细节以 `.trellis/spec/` 为准,本节仅为摘要:

- **目标是刚装好的 Ubuntu**:不能假设系统已预装基础系统以外的工具;软件安装通常走 `apt` 并需要 `sudo`,实现需考虑提权与免交互(`DEBIAN_FRONTEND=noninteractive`)。但**不能假设机器是纯净的**(开源用户可能在既有环境上跑)。
- **幂等性**:同一台机器可重复执行而不报错、不重复安装,便于增量补装与失败重试。

以下 7 条为 spec 锁定的**不可妥协项**(详见 [`spec/index.md`](.trellis/spec/index.md)),每条一行,细节指向对应文档:

- **①脑/脸分离**:一个模块要么 `import textual`,要么含安装逻辑,二者不可兼有;`core/` 绝不 import `textual`。详见 [`core/directory-structure.md`](.trellis/spec/core/directory-structure.md)、[`tui/ui-guidelines.md`](.trellis/spec/tui/ui-guidelines.md)。
- **②`check()` 为幂等引擎**:每个条目查**活系统**判断是否已就位,不依赖任何状态账本(账本一旦用户手动改动就漂移)。详见 [`core/idempotency-and-execution.md`](.trellis/spec/core/idempotency-and-execution.md)。
- **③绝不整体 root,逐命令 sudo**:不把整个 app 以 root 跑;按需逐命令提权,用 `SUDO_USER` 解析用户路径,sudo 下不用 `~`/`$HOME`。详见 [`core/privilege-and-safety.md`](.trellis/spec/core/privilege-and-safety.md)。
- **④plan-before-apply + fail-fast**:先预览将发生什么再执行,首错即停,改因后重跑续装,**无回滚**(唯一可逆的是先备份过的 config)。详见 [`core/idempotency-and-execution.md`](.trellis/spec/core/idempotency-and-execution.md)。
- **⑤单一 subprocess 边界**:所有外部命令都走 `core/runner.py`(argv 列表、非交互环境、`LC_ALL=C`、记日志)。详见 [`core/error-and-logging.md`](.trellis/spec/core/error-and-logging.md)。
- **⑥类型分发只在 provider 注册表**:除注册表外任何代码都不按 `entry.type` 分支;新增软件类型是局部改动。详见 [`core/catalog-and-providers.md`](.trellis/spec/core/catalog-and-providers.md)。
- **⑦catalog 是数据非代码**:声明式 + `script` 逃生口;LLM 阶段(MVP 后置)只生成**声明式、合 schema** 的条目,绝不生成 `script`。详见 [`catalog/authoring-guidelines.md`](.trellis/spec/catalog/authoring-guidelines.md)。
