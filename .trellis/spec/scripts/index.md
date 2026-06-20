# scripts/ —— 脚本编写契约

> 本层文档对应 `scripts/*.sh`:每软件一个脚本,是项目里**所有安装/配置/管理功能的唯一权威实现**。

---

## 这一层是什么

每个软件一个 `scripts/<key>.sh`,统一接口、全部 `source` 共享库 `lib/common.sh`。三个入口(`bootstrap.sh` 的 TUI、薄启动器 `swkit`、LLM 经 skill)**地位等同**,都只是**调用**这些脚本。

新增软件:`cp scripts/TEMPLATE.sh scripts/<key>.sh`,填四个必需函数。**这不是数据驱动 catalog**——每个脚本只硬编码自己的元数据;TUI 通过读各脚本 `meta` 子命令动态发现并归类。

## 文件索引

| 文件 | 内容 |
|------|------|
| [unified-interface.md](./unified-interface.md) | 统一接口:`meta`/`status`/`do_install`/`do_remove`/`do_configure`/自定义 op;`kit_dispatch` 路由;渠道优先级 |
| [idempotency.md](./idempotency.md) | 幂等纪律:`status` 闸门、查活系统、收敛、重跑安全、改前备份 |
| [ui-conventions.md](./ui-conventions.md) | `ui()` 交互界面:入口模式(非 op)、三档终端降级、`ui_run` 跑状态变更、`lib/ui.sh` 原语 |
| [quality-guidelines.md](./quality-guidelines.md) | 校验:`bash -n`、`shellcheck -x`、脚本自测、伪终端冒烟;贡献者工作流 |

## 必看 lib 安全契约

脚本侧的每个提权/包/文件操作都走 `lib/` helper。先读 [../lib/safety-contract.md](../lib/safety-contract.md)(5 条不可妥协项),那是写任何脚本前的前提。

## 真实样板

- **`scripts/TEMPLATE.sh`** —— 新脚本起点,含 `ui()` 注释样例。
- **`scripts/git.sh`** —— 最简单的完整脚本(install/remove/configure + 手写 `ui()`),适合照着学结构。
- **`scripts/zsh.sh`** —— 旗舰组件管理器(框架/提示符/插件独立增删,带参 op,完整 bespoke `ui()`)。
- 其他组件管理器范式:`tmux.sh`/`ghostty.sh`/`rime.sh`/`go.sh`/`python.sh`/`claude.sh`。

## 分类(meta 的 category)

`essentials` | `common` | `ai` | `runtime`,其余归 `other`。TUI 按此分组列脚本。

## 唯一来源

「怎么做」的唯一来源是脚本(`do_configure` 等);skill 散文只讲「如何用脚本/帮用户选」,**不**平行实现配置逻辑、**不**在用户机器运行时写/改脚本。改脚本走正常 git 流程提交到本仓库。
