# AGENTS.md

面向在本仓库工作的 AI 助手（Claude Code / Codex / 其他）的简短指引。

本仓库只交付两样东西：

- `bootstrap.sh` —— 唯一入口的 bash 脚本，在全新 Ubuntu 上装好 Claude Code CLI 与 Codex CLI，并部署 `skills/`。
- `skills/*/SKILL.md` —— 部署到用户机器的守则（LLM 据此管理机器）。当前：`ubuntu-install`（装/卸/升/查软件）、`zsh-setup`（安装并配置 zsh）。新增 skill 时记得把目录名加进 `bootstrap.sh` 的 `SKILLS` 数组。

没有编译工具链，没有 Python 包。

开工前先读 `CLAUDE.md`：项目目标、不可妥协项，以及校验命令——
`bash -n bootstrap.sh`（语法，必过）、`shellcheck bootstrap.sh`（如已安装）、`./bootstrap.sh --help`（用法）。

`bootstrap.sh` 用代码强制、`skills/ubuntu-install/SKILL.md` 用散文教给 LLM，两者承载同一套不可妥协项，会各自漂移。改其中任一处，必查另一处是否需要同步。
