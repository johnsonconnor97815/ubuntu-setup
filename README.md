# ubuntu-setup

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成由 LLM 驱动的软件管理机器:一个 bash 脚本装好 **Claude Code CLI** 与 **Codex CLI**,并部署 `ubuntu-install` skill——此后装什么软件,直接对 LLM 说就行("装个 docker"),由 skill 里的安装守则保证幂等、apt 优先、逐命令 sudo、先计划后执行。

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

## 装完之后

1. **登录**:分别运行 `claude` 和 `codex`,按提示完成登录。
2. **让 LLM 装软件**(任意目录下):
   - Claude Code:`claude` 后直接说 "用 ubuntu-install skill 装 docker"
   - Codex:输入 `/ubuntu-install`,然后说 "install docker"

LLM 会先查活系统判断是否已装、给出要执行的命令清单等你确认、逐命令 sudo 执行、失败即停并报告卡点、装完验证版本——守则见 [`skills/ubuntu-install/SKILL.md`](skills/ubuntu-install/SKILL.md)。

skill 部署位置:`~/.claude/skills/ubuntu-install/`(Claude Code 用户级 skill)与 `~/.codex/prompts/ubuntu-install.md`(Codex 自定义 prompt)。重跑 `./bootstrap.sh` 会覆盖更新到最新版本。

## 开发者

### 校验脚本

```bash
bash -n bootstrap.sh        # 语法检查
shellcheck bootstrap.sh     # 如已安装 shellcheck
./bootstrap.sh --help
```
