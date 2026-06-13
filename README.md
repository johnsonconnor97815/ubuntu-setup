# ubuntu-setup

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成由 LLM 驱动的软件管理机器:一个 bash 脚本装好 **Claude Code CLI** 与 **Codex CLI**,并部署 skill——此后管理机器,直接对 LLM 说就行("装个 docker"、"配置一下 zsh"),由 skill 里的守则保证幂等、apt 优先、逐命令 sudo、先计划后执行。当前内置两个 skill:`ubuntu-install`(装/卸/升/查软件)与 `zsh-setup`(安装并配置 zsh)。

## 快速开始

```bash
git clone <repo-url>
cd ubuntu-setup
./bootstrap.sh
```

脚本幂等,可随时安全重跑:已装好的组件会被检测并跳过;失败后修因重跑即可续装。全程不需要整体 root——只有补齐 `curl`/`ca-certificates` 这类 apt 操作会逐命令 `sudo`。

## 参数

| 参数 | 说明 |
| --- | --- |
| `--only claude` / `--only codex` | 只装其中一个 CLI(默认两个都装) |
| `--method native` / `--method npm` | 安装方式。默认 `native`(官方安装器,无 Node 依赖);`npm` 要求已有 Node.js ≥ 18 与 npm,且绝不 `sudo npm install -g` |
| `--skip-skills` | 跳过 skill 部署(不写 `~/.claude` / `~/.codex`) |
| `-h` / `--help` | 用法说明 |

运行过程中会弹出一个 **TUI 开关**(whiptail 对话框,缺失时回退为文本 `[Y/n]` 提示)让你**开/关**免密 sudo——无对应命令行开关,选择只在 UI 里做;开关会显示当前状态、可来回切换;非交互运行(无终端)保持现状不动。

## 装完之后

1. **登录**:分别运行 `claude` 和 `codex`,按提示完成登录。
2. **让 LLM 管理机器**(任意目录下):
   - Claude Code:`claude` 后直接说 "用 ubuntu-install skill 装 docker" 或 "用 zsh-setup skill 配置 zsh"
   - Codex:输入 `/ubuntu-install` 再说 "install docker",或输入 `/zsh-setup` 再说 "把 zsh 装好配好"

LLM 会先查活系统判断是否已装、给出要执行的命令清单等你确认、逐命令 sudo 执行、失败即停并报告卡点、装完验证版本——守则见 [`skills/ubuntu-install/SKILL.md`](skills/ubuntu-install/SKILL.md) 与 [`skills/zsh-setup/SKILL.md`](skills/zsh-setup/SKILL.md)。

> **关于 sudo 密码**:LLM 通过自己的 shell 执行 sudo,该环境**没有交互终端,无法输入密码**。所以 `bootstrap.sh` 装机时(此刻你有终端)会弹出一个 **TUI 开关**让你开启免密 sudo;开启就让你输一次密码、写入 `/etc/sudoers.d/ubuntu-setup-llm`,使 LLM 之后免密装软件、全自动;同一开关也能随时关闭(删除该文件)。LLM 会先 `sudo -n true` 探测,通过就直接装,否则把特权命令交还你——绝不经手你的密码。这是你在 UI 里显式授予、可见可撤的边界。

skill 部署位置:`~/.claude/skills/<name>/`(Claude Code 用户级 skill)与 `~/.codex/prompts/<name>.md`(Codex 自定义 prompt),`<name>` 为 `ubuntu-install`、`zsh-setup`。重跑 `./bootstrap.sh` 会覆盖更新到最新版本。

## 开发者

### 校验脚本

```bash
bash -n bootstrap.sh        # 语法检查
shellcheck bootstrap.sh     # 如已安装 shellcheck
./bootstrap.sh --help
```
