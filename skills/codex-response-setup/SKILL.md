---
name: codex-response-setup
description: Restore this repository's Codex reply style and reasoning-display preference on a new or reinstalled machine, or when the user requests this saved profile. Configures global instructions while preserving accounts and unrelated settings; not an ordinary text-rewriting skill.
---

# 恢复 Codex 回复与显示偏好

目标是简洁但不漏事项，突出重要结果、异常和待办，重点解释难点与不确定性，避免自造术语。完整标准只有 [response-rules.md](assets/response-rules.md) 一份；配置逻辑由仓库的 `scripts/codex-response.sh` 和 `lib/codex_response.py` 维护。

## 配置过程

1. 确认目标机器和用户，沿用已有授权。定位包含 `swkit` 的仓库根目录；`.agents/skills/codex-response-setup` 是软链，先解析实际位置。读取回复标准，查看目标 `CODEX_HOME`（未设置则 `~/.codex`）下的全局指令及相关显示设置，不输出凭据。
2. 在仓库根目录执行 `./swkit codex-response plan`。预览不创建目录、不安装依赖、不调用模型。检查拟改动及现有规则的语义冲突；脚本只能识别同名规则节的内容差异，不能判断其他章节是否语义冲突。
3. 在已授权范围内执行 `./swkit codex-response configure`，随后运行 `./swkit codex-response status`。自动化测试或不需要打开报告时用 `--no-open`。需要明确目标目录时给 `plan`、`configure` 加 `--codex-home /绝对路径`；状态检查可直接运行 `python3 lib/codex_response.py status --codex-home /绝对路径`。
4. 查看生成的 HTML/JSON 报告。候选配置在临时目录通过原生 CLI 类型与解析检查后才写入；写前备份，保留权限与属主。完整匹配的规则和设置不重写。前检查阻止执行时不创建报告；开始执行后记录每个文件的状态，失败停止后续写入。
5. 新启动目标 Codex，核对生效的全局指令，并按下方场景验收实际回复。需要读取诊断时，仅过滤所需规则，不保存或打印完整上下文。没有实际执行的检查保持“待验证”。

需要 Python 3.11+（标准库 `tomllib`）和已安装的 Codex CLI。缺 Python 时先核对目标系统支持的解释器，不替换系统 Python。缺 Codex 时可沿用仓库安装器 `./swkit codex-response install --with-requires`；它不会安装 Python 或迁移登录信息。普通 `configure` 不安装依赖。

## 配置边界

- 按 `AGENTS.override.md` / `AGENTS.md` 的优先级选取有效全局文件，追加完整标准，不依赖原机器路径。已有同名标准完全相同时跳过，不额外添加标记；内容不同时保留并报告差异，不能为了让检查通过而覆盖定制。
- 仅把顶层 `hide_agent_reasoning` 设为 `true`。不修改模型、推理强度、`model_verbosity`、快捷键、终端模式、MCP、账号或密钥，不复制原机器的整个配置。
- 项目指令、配置覆盖、组织策略或启动参数仍可能改变实际效果。不要把静态匹配、CLI 解析成功或规则加载成功写成模型行为已验证。
- 工具结果折叠由 CLI 控制。不要虚构“全部自动折叠”设置，也不要从隐藏推理事件推断工具结果已隐藏。设置依据、检查边界与恢复方法见 [配置检查与恢复](references/verification-and-recovery.md)。
- 沿用授权继续，不逐条重复确认；出现不在授权内的配置取舍或用户定制冲突时，先列出具体差异。修订回复标准属于仓库维护，不能在目标机临时改安装脚本绕过检查。

## 验收标准

| 场景 | 应有表现 |
| --- | --- |
| 几项简单工作均完成 | 简述做了什么、结果怎样，合并表达但不漏项 |
| 部分完成、部分失败或未确认 | 重要异常直接显示；说明依据、验证范围和影响，不统称“完成” |
| 难点或陌生术语 | 解释与当前判断有关的原因，必要术语随文简释，不创造新名词 |
| 需要下一步处理 | 写清由谁处理，区分必须、建议和可选；无待办不凑建议 |
| 用户要求详细、正式或原样 | 按用户要求调整，不机械压缩或强套模板 |
| 工具返回大量内容 | 报告保留必要结果、错误及依据；不承诺 CLI 能折叠所有输出 |

这些是回复验收标准，不替代任务本身的调查和验证。一次样例通过也不保证长期效果；后续依据具体失败回复作窄范围修订。

恢复或中断后继续时，按 [配置检查与恢复](references/verification-and-recovery.md) 比较当前文件与运行记录，保留后续修改。
