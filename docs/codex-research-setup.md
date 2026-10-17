# 重装或换机器后恢复 Codex 查证配置

配置能力保存在本仓库。克隆仓库后，在仓库根目录运行：

```bash
./swkit codex-research install --with-requires
```

这条命令按需安装 Codex CLI、`jq`，部署查证 Skill，为缺失的 Exa 和 Context7 添加远程 MCP 配置，并补充目标用户的全局触发规则。系统依赖沿用仓库的逐命令提权流程；请以普通用户运行。Codex 账号登录、付费服务额度和可选 API key 需要在目标机准备，仓库不包含这些凭证。

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

`status` 成功和配置报告都不能替代这些运行验证。项目配置、组织策略、禁用的 Skill 或启动参数可能影响会话中的实际行为。

## 保存哪些内容

| 仓库内容 | 安装后的作用 |
| --- | --- |
| `skills/codex-research-setup/` | 项目内的恢复流程入口，调用脚本 |
| `scripts/codex-research.sh` | 唯一配置实现，由 `swkit` 或 Skill 调用 |
| `skills/exa-context7-research/` | 复制到目标 `CODEX_HOME/skills/`，维护完整查证规则 |
| 脚本生成的全局触发块 | 写入目标 `CODEX_HOME` 下实际优先的指令文件，引用该机 Skill 路径 |

未设置 `CODEX_HOME` 时使用 `~/.codex`。完整规则只维护在查证 Skill；全局指令只负责触发。源文件不含开发者的用户名、绝对 home 路径或密钥。

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

依据核对日期为 2026-10-17；实际检查过的本机 CLI 为 `codex-cli 0.163.0`，不把它推断成最低支持版本。其他版本需通过其配置读取与参数检查。

- [Codex MCP](https://developers.openai.com/codex/mcp)：远程 URL、环境变量认证、MCP 管理和 OAuth。
- [Codex 配置优先级](https://developers.openai.com/codex/config-basic)：用户配置仍可能被受信任项目等更高优先级配置覆盖。
- [Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md) 与 [Skills](https://developers.openai.com/codex/skills)：全局指令选择、项目 Skill 发现及软链支持。
- [Exa MCP](https://exa.ai/docs/get-started/exa-mcp)：公开端点支持无 key 限流访问，可选 API key/OAuth。
- [Context7 Codex](https://context7.com/docs/clients/codex) 与 [API Guide](https://context7.com/docs/api-guide)：端点、推荐认证和无 key 额度。当前公开端点匿名文档查询已实测成功；这不保证之后或其他部署继续接受匿名调用。

## 重跑与恢复

完全一致的配置和 Skill 文件不重复写入。已有 Skill 内容不同时停止覆盖，便于先核对用户定制与仓库版本；本命令不自动合并 Skill 升级。失败后先看报告中的已完成项，修正条件再重跑。

修改已有配置前，在 `CODEX_HOME/.ubuntu-setup-research-runs/` 下创建本次运行专用的私有目录，保存保留原权限和属主的配置备份。报告列出准确的备份路径及变更前状态；备份可能包含目标机自己的凭证，应仅留在目标机。恢复时先比较当前配置与备份，保留后来新增的配置。只撤销本次添加的 MCP、全局受管块和 Skill 文件；已有的同名 MCP 不属于本次新增项。不要为撤销本配置而卸载 CLI，也不要直接用旧备份覆盖后来有改动的配置。

## 开发验证

```bash
bash -n scripts/codex-research.sh
shellcheck -x --source-path=SCRIPTDIR scripts/codex-research.sh test/codex_research_test.sh
bash test/codex_research_test.sh
bash test/meta_test.sh
```

隔离测试使用临时文件和模拟 Codex CLI，覆盖预览不改配置、幂等、冲突保护、失败续跑和报告。它不证明新机器的网络、账号、原生 CLI 写入或模型工具选择已正常；目标机仍需执行上面的运行验证。

2026-10-17 另用真实 `codex-cli 0.163.0` 在隔离的临时用户目录验证过：缺目录预览保持目标不变；`install --with-requires --no-open` 完成配置；`status` 成功；重复配置没有改写配置或规则。该验证关闭了网络，且复用了已有 CLI 和 `jq`，不覆盖下载 CLI、安装系统依赖或 MCP 连通性。新 Codex 会话也已成功发现并读取仓库内的配置 Skill。
