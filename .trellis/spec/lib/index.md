# lib/ —— 安全契约即代码

> 本层文档对应 `lib/` 共享库:`lib/common.sh`(安全原语)与 `lib/ui.sh`(TUI 渲染)。
> 它们把项目的不可妥协项写成**被强制执行的可复用代码**,被 `scripts/` 下每个脚本 `source`。

---

## 开工前:先进 worktree(前置隔离)

改本层代码(`lib/*.sh`)前,若经 Trellis 开发:**先 `EnterWorktree`、再 `task.py start` / 派子 agent** —— 子 agent 继承主会话 cwd,写入才落进 `.claude/worktrees/`。`worktree-guard.py`(PreToolUse)只是 **write 层兜底**、不是主隔离机制(对子 agent、headless `-p` 都不可靠)。完整理由与步骤见仓库根 `CLAUDE.md`「代码改动的 worktree 工作流」。

## 这一层是什么

`ubuntu-setup` 是一组**纯 bash、每软件一个**的脚本(`scripts/<key>.sh`),用来在全新 Ubuntu 上安装/配置/管理软件。所有脚本共享同一个库 `lib/common.sh`(它末尾再 `source lib/ui.sh`)。

库的设计哲学(见 `lib/common.sh` 顶部注释):

> 安全写法是**默认**——写合规脚本基本就是调这些 helper;不安全写法(`sudo npm`、整体 root、`apt-key`)**故意没有原语**。

所以本层的"规范"不是建议,而是**已经落在代码里的事实**。改这一层 = 改全项目的安全语义。

## 文件索引

| 文件 | 内容 |
|------|------|
| [safety-contract.md](./safety-contract.md) | 5 条不可妥协项 + 各自由哪个 lib 原语强制 |
| [sudo-and-apt.md](./sudo-and-apt.md) | `sudo_run` 逐命令提权 / `RC_NEED_SUDO` / 非交互 apt / vendor apt 渠道(`add_apt_keyring`/`add_apt_source`)/ vendor 二进制 `.deb`(curl + `apt_install` 本地路径,curl `--max-time` 二分律) |
| [npm-and-files.md](./npm-and-files.md) | 用户态 npm 全局安装(绝不 `sudo npm`) / `backup_file` / `append_once` / `ensure_local_bin_on_path` |

## 唯一来源与"漂移"纪律(CRITICAL)

**CLAUDE.md 的「领域约束」一节是安全语义的唯一权威来源。** 本层 spec 是它的**实操摘要 + 真实代码索引**,不复制其完整论述。

CLAUDE.md 明确警告:同一份安全底线**同时**描述在三处——`lib/common.sh` 的代码、CLAUDE.md 的契约散文、`skills/*/SKILL.md` 的散文——会各自**漂移**。本层 spec 加入后是第四处。所以:

- **改安全语义时,源头永远是 `lib/common.sh` + CLAUDE.md**;本层 spec 跟随更新,不抢做权威。
- 写 spec 时**引用 CLAUDE.md 章节 + 真实函数名**,而非重抄长段论述,把漂移面降到最小。

## 渲染层 `lib/ui.sh`

`lib/ui.sh` 是现代 TUI 渲染库(纯 bash + ANSI,**无 whiptail**),是安全契约的"视觉孪生"。脚本侧怎么用它见 [../scripts/ui-conventions.md](../scripts/ui-conventions.md)。
