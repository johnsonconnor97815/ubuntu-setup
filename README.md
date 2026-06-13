# ubuntu-setup

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成由 LLM 驱动的软件管理机器:一个 bash 脚本在 **TUI** 里让你**自选**安装 **Claude Code CLI**、**Codex CLI**、**Node.js + npm** 与 skill——此后管理机器,直接对 LLM 说就行("装个 docker"、"配置一下 zsh"),由 skill 里的守则保证幂等、apt 优先、逐命令 sudo、先计划后执行。当前内置两个 skill:`ubuntu-install`(装/卸/升/查软件)与 `zsh-setup`(安装并配置 zsh)。

## 快速开始

```bash
git clone <repo-url>
cd ubuntu-setup
./bootstrap.sh
```

有终端时,`./bootstrap.sh` 默认进入 **TUI**(whiptail,缺失则回退纯文本菜单):

- **软件列表**(多选):**Claude Code CLI**、**Codex CLI**、**Node.js + npm**(apt)、内置 **skills**。勾选哪个装哪个,默认勾选两个 CLI 与 skills、Node 默认不勾;已装的会标注 `[已安装]` 并幂等跳过。安装在**进度条**后台进行,完整日志写到 `~/.cache/ubuntu-setup/`,装完弹出结果摘要并回到主菜单。
- **设置**:切换界面**语言**(中文 / English / 日本語,记到 `~/.config/ubuntu-setup/config`);**开/关 LLM 免密 sudo**(见文末)。

脚本幂等,可随时安全重跑:已装好的组件会被检测并跳过;失败后修因重跑即可续装。全程不需要整体 root——只有 Node、以及补齐 `curl`/`ca-certificates` 这类 apt 操作会逐命令 `sudo`。

## 参数(headless)

带任一安装参数、或在无终端环境(如 CI)运行时,脚本不进 TUI,改走 headless 流程并遵循这些参数:

| 参数 | 说明 |
| --- | --- |
| `--only claude` / `--only codex` | 只装其中一个 CLI(默认两个都装) |
| `--method native` / `--method npm` | 安装方式。默认 `native`(官方安装器,无 Node 依赖);`npm` 要求已有 Node.js ≥ 18 与 npm,且绝不 `sudo npm install -g`(也绝不为满足 npm 而自动装 Node) |
| `--with-node` | 额外用 apt 装 Node.js + npm |
| `--skip-skills` | 跳过 skill 部署(不写 `~/.claude` / `~/.codex`) |
| `--headless` | 即便有终端也强制走非交互流程 |
| `--tui` | 即便带了上面的参数也强制进 TUI(仍需有终端) |
| `-h` / `--help` | 用法说明 |

**免密 sudo** 只在 UI 里开关——无命令行开关:TUI 里在「设置」页,headless 里为一次性提示。开关显示当前状态、可来回切换;非交互运行(无终端)保持现状不动。

## 装完之后

1. **登录**:分别运行 `claude` 和 `codex`,按提示完成登录。
2. **让 LLM 管理机器**(任意目录下):
   - Claude Code:`claude` 后直接说 "用 ubuntu-install skill 装 docker" 或 "用 zsh-setup skill 配置 zsh"
   - Codex:输入 `/ubuntu-install` 再说 "install docker",或输入 `/zsh-setup` 再说 "把 zsh 装好配好"

LLM 会先查活系统判断是否已装、给出要执行的命令清单等你确认、逐命令 sudo 执行、失败即停并报告卡点、装完验证版本——守则见 [`skills/ubuntu-install/SKILL.md`](skills/ubuntu-install/SKILL.md) 与 [`skills/zsh-setup/SKILL.md`](skills/zsh-setup/SKILL.md)。

> **关于 sudo 密码**:LLM 通过自己的 shell 执行 sudo,该环境**没有交互终端,无法输入密码**。所以 `bootstrap.sh`(此刻你有终端)在 TUI 的「设置」页提供一个**开关**让你开启免密 sudo;开启就让你输一次密码、写入 `/etc/sudoers.d/ubuntu-setup-llm`,使 LLM 之后免密装软件、全自动;同一开关也能随时关闭(删除该文件)。LLM 会先 `sudo -n true` 探测,通过就直接装,否则把特权命令交还你——绝不经手你的密码。这是你在 UI 里显式授予、可见可撤的边界。

skill 部署位置:`~/.claude/skills/<name>/`(Claude Code 用户级 skill)与 `~/.codex/prompts/<name>.md`(Codex 自定义 prompt),`<name>` 为 `ubuntu-install`、`zsh-setup`。重跑 `./bootstrap.sh` 会覆盖更新到最新版本。

## 开发者

### 校验脚本

```bash
bash -n bootstrap.sh        # 语法检查
shellcheck bootstrap.sh     # 如已安装 shellcheck
./bootstrap.sh --help
```
