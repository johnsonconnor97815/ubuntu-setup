# Aider 本机代码任务

目标：安装 Aider，注册 Codex MCP 入口，并通过 MCP 让本机 DeepSeek 修改隔离项目中的
文件，再独立运行代码检查结果。安装、注册、工具发现和实际修改分别验收。

```bash
swkit aider install
swkit aider configure --root /absolute/workspace
swkit aider status
```

Aider 固定为 `aider-chat 0.86.2`，由 uv 使用 Python 3.12 安装到独立工具环境；
MCP 固定为 `mcp-aider-executor 1.1.0`，放在用户数据目录的
`ubuntu-setup/aider-mcp/`。不需要 sudo，不更改系统 Python 或 npm 全局前缀。
同时固定其 `@modelcontextprotocol/server 2.0.0-alpha.2` 依赖：上游的宽版本范围会
选到 `2.4.0`，实际启动报错 `does not provide an export named 'StdioServerTransport'`。
本入口使用上游声明的 alpha 版本，不修改安装包源码。

模型地址为 `http://127.0.0.1:18080/v1`，名称为
`openai/deepseek-v4.1-flash-1017`。`local-only` 是本机无认证接口所需的占位值。
模型配置只作用于这个 MCP 进程；实际运行上下文为 8192 tokens，按 6144 输入、2048
输出登记，不以模型训练时的理论上限登记。本入口不修改模型服务。

配置写入当前 `CODEX_HOME/config.toml`（默认 `~/.codex/config.toml`），只增加
`aider-deepseek`。已有同名不同配置时停止；相同配置重复执行不写入。原配置先备份，
随后核对其他配置内容不变，并调用 Codex 的严格解析检查。源仓库路径会写入本机配置，
移动仓库后需要先核对并更新这个入口。注册后重连 MCP 或开启新会话。

调用流程：

1. 在任务指定的项目目录调用 `aider_check_progress`，确认没有上一次运行仍在执行。
2. 调用 `aider_message_prompt`，提供明确的任务、允许修改的现有文件和相关项目规则。
   新文件在任务文字中说明。按实际上下文分配任务，不一次塞入整个仓库。
3. 等待并检查进程、日志、实际文件差异和任务对应的测试。工具返回后台已启动不代表完成。
   上游进度工具会对已结束的进程返回 `isError: true`，必须结合状态和实际结果判断。
4. 主会话检查并接收结果。Aider 不自动提交，不修改 `.gitignore`，不共享本机会话历史；
   调用方必须提供所需上下文。MCP 的目录白名单是路径检查，不是操作系统沙箱。

默认只登记工作区根目录内的路径；关闭额外 Git 工具和通用文件工具。
这些设置不代替用户授权和项目规则。Android 设备与共享环境操作仍遵循 Workbench 队列。

安装恢复：保留 Codex 配置备份和 npm lockfile。卸载 Aider 可执行
`uv tool uninstall aider-chat`；MCP 配置、日志和私有 npm 目录不会自动删除。

检查：`bash -n scripts/aider.sh`、`shellcheck -x --source-path=SCRIPTDIR scripts/aider.sh`、
`python3 -m unittest discover -s tests -p test_aider_config.py -v`。
需运行着本机模型的实际验收：
`python3 -u tests/manual/aider_mcp_smoke.py --workspace /absolute/workspace`。
它会创建独立测试仓库并通过 MCP 请求 Aider 修改文件，再运行 5 项测试，核对测试文件与
提交记录没有被改写。测试文件和结果保留用于检查，不自动清理。

依据（2026-10-30 查阅）：

- [Aider 官方安装](https://aider.chat/docs/install.html)
- [本机兼容接口](https://aider.chat/docs/llms/openai-compat.html)
- [脚本调用](https://aider.chat/docs/scripting.html)
- [MCP Executor 上游](https://github.com/RailKill/mcp-aider-executor)
- [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)

2026-10-30 本机验收：MCP 初始化与工具发现通过；经 `aider_message_prompt` 请求模型
修改独立测试仓库中的 `clamp.py`，运行前失败、修改后 5 项测试全部通过，测试文件和 Git
提交记录保持不变。端到端耗时 165.1 秒。安装重复执行无额外安装；253 项仓库单元测试、
38 个 Bash 文件的语法检查及全仓 ShellCheck 通过。这些结果不代表大项目、多文件任务或
并行吞吐已经验证。私有运行目录保存在本机用户状态目录，不提交到仓库。
