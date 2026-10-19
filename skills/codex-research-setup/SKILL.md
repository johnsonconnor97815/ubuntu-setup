---
name: codex-research-setup
description: Set up or restore this repository's proactive Exa and Context7 research configuration for Codex CLI after reinstalling a machine, moving to another machine, or explicitly requesting this profile. Runs the ubuntu-setup configuration script; does not perform ordinary research tasks.
---

# 重建 Codex 的 Exa 与 Context7 查证配置

在目标机器上恢复本仓库维护的 MCP 连接和全局查证规则。完整规则只维护在 [规则模板](assets/research-rules.md)，由配置脚本写入目标用户的有效全局 `AGENTS` 文件，供新会话加载。

属于本仓库的 Codex 配置系列。终端滚动、Agent Views 与 tmux vi 复制模式的配置和排查见同系列的 [codex-terminal-setup](../codex-terminal-setup/SKILL.md)。

## 执行

1. 定位包含 `swkit` 和 `scripts/codex-research.sh` 的本仓库根目录。仓库内入口 `.agents/skills/codex-research-setup` 是指向本文件所在目录的软链；需要解析资源路径时先解析软链。确认当前机器就是用户要配置的目标；不要把开发机当作另一台机器执行。
2. 在仓库根目录运行 `./swkit codex-research plan`。它检查依赖、已有 MCP、全局指令和已有部署，列出拟改动及冲突，不改配置或安装依赖；原生 CLI 可能生成自身的运行临时目录。缺少依赖或尚无 Codex home 时报告检查限制，安装阶段补足条件后重新检查。仅当预览报告需要迁移已有部署时，读取[迁移与恢复说明](../../docs/codex-research-migration.md)。
3. 沿用用户已给出的配置授权，执行 `./swkit codex-research install --with-requires`。它按需安装 Codex CLI 和 `jq`，然后部署配置；已有依赖时可运行 `./swkit codex-research configure`。若用户要求保留已有 MCP、只部署查证规则，改用 `./swkit codex-research rules plan`、`./swkit codex-research rules configure` 和 `./swkit codex-research rules status`。该独立范围不读取或修改 MCP、不安装依赖，也不证明完整连接方案符合模板；原有完整配置检查不变。先核对现有工具能支持规则中的查证任务，保留未验证项。不另写安装命令或修改安装脚本来绕过冲突。自动化测试、SSH 或不需要打开报告时传 `--no-open`。
4. 完整配置执行 `./swkit codex-research status`；仅规则部署执行 `./swkit codex-research rules status`。查看 HTML/JSON 报告并按所选范围核对，不能把仅规则成功写成 MCP 配置通过。配置完整只证明静态配置与仓库规则匹配，不能证明规则已加载、MCP 连通或模型已遵循规则。
5. 在目标机器的新 Codex 会话中检查 `/mcp`，分别进行一次公开的 Exa 检索和 Context7 文档查询，再用两个场景检查触发：缺少第三方依据时主动查证；已有充分本地证据的纯文本修改不强制查证。使用环境当前暴露的工具和参数。未实际执行的检查保留“待验证”；配置失败后可补足条件重跑。

## 边界

- 安装后的行为面向目标用户的 Codex 会话；配置能力和规则的源文件归本仓库维护，不依赖原机器的用户目录。`CODEX_HOME` 已设置时沿用它。
- 不复制原机器的 `config.toml`、API key、OAuth token、模型供应商或登录信息。新建 MCP 使用官方公开端点；目标机已有兼容配置和凭证保持原样。缺少目标账号或额度时由用户在目标机完成认证，不向聊天或仓库索取密钥。
- 同名 MCP 冲突、禁用、限制工具列表，或已有规则存在定制，先报告差异和影响，保留用户选择。仅规则模式保留所有 MCP 设置，规则定制、路径和旧部署迁移检查仍生效；不能把仅规则成功写成完整配置通过。项目级配置、组织策略和命令行参数仍可能改变最终生效结果。
- 全局指令按 Codex 的 `AGENTS.override.md` / `AGENTS.md` 优先级选择文件，保留已有内容。脚本生成目标机路径，不能复制开发机的绝对路径。
- 现有配置修改前备份；恢复前比较当前内容，保留安装后用户自己的修改。没有自动全量回滚，不运行卸载 Codex 来撤销这个配置。

需要核对认证方式、配置依据、恢复步骤或维护检查命令时，按需读取[配置说明](../../docs/codex-research-setup.md)。
