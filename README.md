# ubuntu-setup

为全新安装的 Ubuntu 机器自动化安装与配置软件的工具(Python + bash)。

## 开发环境初始化(克隆后首次)

本仓库用 [Trellis](.trellis/) 管理开发流程,并集成 Codegraph 代码索引。新机器 `git clone` 后,用内置 setup skill 一键拉齐本地环境(安装并索引 Codegraph、注册 codegraph MCP、设置 Trellis 开发者身份):

- **Claude Code**:运行 `/trellis:setup`
- **Codex CLI**:触发 `trellis-setup` skill(位于 `.agents/skills/trellis-setup/`,Codex 原生扫描)

流程幂等,可安全重复运行。Codex 用户还需在用户级 `~/.codex/config.toml` 开 `[features].hooks = true` 并 `/hooks` 审批一次(详见 skill 说明)。
