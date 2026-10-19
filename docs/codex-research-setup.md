# 重装或换机器后恢复 Codex 查证配置

配置能力保存在本仓库。克隆仓库后，在仓库根目录运行：

```bash
./swkit codex-research install --with-requires
```

这条命令按需安装 Codex CLI、`jq`，为缺失的 Exa 和 Context7 添加远程 MCP 配置，并将完整查证规则合并到目标用户的有效全局 `AGENTS` 文件。系统依赖沿用仓库的逐命令提权流程；请以普通用户运行。Codex 账号登录、付费服务额度和可选 API key 需要在目标机准备，仓库不包含这些凭证。

也可以在此仓库的 Codex 会话中调用 `$codex-research-setup`。项目入口是 `.agents/skills/codex-research-setup`，指向 `skills/codex-research-setup`；配置逻辑只有 `scripts/codex-research.sh` 一份。通用 `bootstrap.sh` 不会自动启用这个配置。

## 预览、执行与验证

```bash
./swkit codex-research plan                  # 不改配置、不装依赖、不刷新索引
./swkit codex-research install --with-requires
./swkit codex-research status                # 仅检查配置完整性
# 已有 Codex 和 jq 时，仅执行配置：
./swkit codex-research configure --no-open
```

安装和配置命令保存 HTML 与 JSON 报告，默认请求浏览器打开 HTML；无桌面或打开失败时查看输出路径。`--no-open` 适用于自动化和 SSH。`plan` 与 `status` 不写报告或目标配置，但其调用的原生 Codex CLI 可能创建自身的运行临时目录。首次使用、Codex home 尚不存在时，预览会报告原生检查尚未完成；安装阶段创建目录后重新检查，不据此跳过冲突检测。

成功安装后应新开 Codex 会话，检查 `/mcp`，分别调用一次 Exa 检索、Context7 库解析与文档查询。再检查两个行为场景：

- 询问一个尚无依据的第三方 API 或当前兼容性问题，应主动选用合适的查证工具；一个工具已给出充分证据时，不要求两个都调用。
- 对已给出完整文本的拼写修改，且不依赖外部事实，应直接完成；不能仅凭“小改动”跳过实际存在的外部证据缺口。

`status` 成功和配置报告都不能替代这些运行验证。项目指令、配置覆盖、组织策略或启动参数可能影响会话中的实际行为；全局规则加载也不证明模型始终遵守。

## 保存哪些内容

| 仓库内容 | 安装后的作用 |
| --- | --- |
| `skills/codex-research-setup/` | 项目内的恢复流程入口，调用脚本 |
| `scripts/codex-research.sh` | 唯一配置实现，由 `swkit` 或 Skill 调用 |
| `skills/codex-research-setup/assets/research-rules.md` | 完整查证规则模板，归查证配置 Skill 维护 |
| 脚本生成的全局受管块 | 将完整规则写入目标 `CODEX_HOME` 下实际优先的指令文件，供新会话直接加载 |

未设置 `CODEX_HOME` 时使用 `~/.codex`。规则模板是配置产物的来源，完整规则直接写入全局指令。源文件不含开发者的用户名、绝对 home 路径或密钥。

## 兼容性与认证

默认新增配置使用下面的公开端点，不迁移原机器的整个配置文件：

```toml
[mcp_servers.exa]
url = "https://mcp.exa.ai/mcp"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"
```

已有同名、启用且兼容的官方端点保持原样，包括认证设置。不同端点、stdio 传输、禁用或工具限制（包括 Exa URL 的 `tools` 参数）作为冲突处理。脚本从项目外调用原生 Codex MCP 命令，避免把当前仓库的覆盖配置误作用户配置；这不能消除目标会话自己的项目覆盖。

需要 API key 时，在目标机按官方说明管理凭证。Codex 支持下列环境变量引用，变量值不应提交到仓库；不要在未设置变量时盲目添加这些引用：

```toml
# 放在相应的已有 MCP 表内，不要重复声明整张表。
# Exa:
env_http_headers = { "x-api-key" = "EXA_API_KEY" }
# Context7:
bearer_token_env_var = "CONTEXT7_API_KEY"
```

原生 `codex mcp add` 可能尝试 OAuth 登录并打开浏览器。脚本限制等待时间，随后重新读取配置；如果配置已写入但认证未结束，报告仍保留连接和认证待验证，不能据此宣称可用。

执行前用目标机的原生 CLI 核对配置读取与所需参数；配置方式和认证条件以对应版本及服务文档为准。

- [Codex MCP](https://developers.openai.com/codex/mcp)：远程 URL、环境变量认证、MCP 管理和 OAuth。
- [Codex 配置优先级](https://developers.openai.com/codex/config-basic)：用户配置仍可能被受信任项目等更高优先级配置覆盖。
- [Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md) 与 [Skills](https://developers.openai.com/codex/skills)：全局指令选择与加载、项目配置 Skill 发现及软链支持。
- [Exa MCP](https://exa.ai/docs/get-started/exa-mcp)：公开端点支持无 key 限流访问，可选 API key/OAuth。
- [Context7 Codex](https://context7.com/docs/clients/codex) 与 [API Guide](https://context7.com/docs/api-guide)：端点、认证方式和额度条件，按目标机账号与服务状态核对。

## 重跑与恢复

完全一致的 MCP 配置和全局规则不重复写入。已有受管规则与仓库模板不同或含不明修改时，保留并报告冲突。失败后先看报告中的已完成项，修正条件再重跑。

仅当 `plan` 报告需要迁移已有部署时，按需读取[迁移与恢复说明](codex-research-migration.md)。

修改已有配置前，在 `CODEX_HOME/.ubuntu-setup-research-runs/` 下创建本次运行专用的私有目录，保存恢复资料。报告列出准确的备份和变更位置；备份可能包含目标机自己的凭证，应仅留在目标机。恢复时先比较当前文件与 `recovery.json` 中的候选哈希，保留后来新增的内容，再撤销本次新增配置或恢复本次修改的文件及配套内容。已有的同名 MCP 不属于本次新增项。不要为撤销本配置而卸载 CLI，也不要直接用旧备份覆盖后来有改动的配置。

## 开发验证

```bash
bash -n scripts/codex-research.sh
shellcheck -x --source-path=SCRIPTDIR scripts/codex-research.sh test/codex_research_test.sh
bash test/codex_research_test.sh
bash test/meta_test.sh
```

隔离测试使用临时文件和模拟 Codex CLI，覆盖预览不改配置、幂等、MCP 冲突保护、已有部署迁移、文件定制与软链保护、并发变化、失败续跑和恢复记录。它不证明目标机的网络、账号或模型行为已正常；目标机仍需执行上面的运行验证。
