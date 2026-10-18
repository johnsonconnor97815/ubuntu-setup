---
name: codex-terminal-setup
description: Configure or troubleshoot Codex CLI scrollback and tmux vi copy mode. Use for terminal history, keyboard browsing, and Agent Views screen-mode activation; not MCP or research-tool setup.
---

# Codex 终端滚动与 tmux 复制模式

属于本仓库的 Codex 配置系列。Exa、Context7 与主动查证配置交给同系列的 [codex-research-setup](../codex-research-setup/SKILL.md)；本 Skill 处理终端显示、滚动历史及其生效排查。

源文件保存在 `skills/codex-terminal-setup/`；项目发现入口 `.agents/skills/codex-terminal-setup` 使用相对软链。先解析软链并定位仓库，流程与实现均随仓库维护。本 Skill 提供配置与排查流程，没有专用的自动配置或客户端重启命令。

## 收集当前状态

1. 明确是在维护仓库流程，还是配置用户指定的目标机器。仅编写 Skill 时不改主机配置。使用前阅读 [版本依据与排查分支](references/scrollback.md)，核对目标版本和适用范围；配置是否生效以目标机验证为准。
2. 区分终端里的 Codex CLI、CLI 内的 Agent Views、后端 Session 和 tmux 窗格。Agent Views 是 CLI 内部的会话管理界面；核对用户实际使用的入口，已有上下文明确时直接沿用。
3. 只读检查版本与窗格，不读取对话正文或完整环境变量：

   ```bash
   codex --version
   tmux -V
   tmux list-panes -a -F '#{pane_id} pid=#{pane_pid} command=#{pane_current_command} alternate_on=#{alternate_on} history_size=#{history_size} history_limit=#{history_limit}'
   tmux show-options -g history-limit
   ```

   将问题对应到用户的实际窗格；有多个候选时不要默认 `%0`。`pane_pid` 可能是 Shell，当前命令也可能是 Node 启动器；沿进程父子关系核实原生 Codex 客户端及其版本，不能仅凭当前 PATH 的 `codex --version` 代替。
4. 检查该客户端使用的 `CODEX_HOME`、用户和项目配置、profile 与屏幕模式启动覆盖，只提取有关字段。记录客户端启动时间、配置变更时间和当前 `alternate_on`；比较时间时统一时区。另查该窗格实际继承的 `mode-keys` 和 `history_limit`，区分默认选项与已经分配的历史容量。

## 制定与执行配置计划

- 用户希望继续用 tmux vi 复制模式时，候选设置是用户配置中的 `tui.alternate_screen = "never"`；需要 Codex 自管全屏交互时保留相应模式。说明作用范围和取舍，不把一种个人习惯改成所有机器的默认值。
- tmux 历史行数是独立选项，按用途、内存和窗格数量选择；提高上限不保证保存完整会话，也不能找回已丢弃的输出。
- 计划列明目标文件、原值、单项差异、配置优先级、生效所需的新客户端或新窗格、验证与恢复步骤。沿用已有授权；仅请求排查不构成结束工作会话的授权。
- Codex 用户配置按 [参考中的合并方式](references/scrollback.md#配置与恢复) 修改：改前备份原内容、属主和权限，验证候选 TOML，仅修改目标键。已有 `[tui]` 时合并，不能复制本机整份配置到另一台机器。
- tmux 已有 `scripts/tmux.sh` 管理器；先检查 `./swkit tmux help` 和相关实现。`configure --history <lines>` 会走完整配置流程，可能调用插件或字体处理，执行前确认附带操作仍在授权内。不能为了改历史上限重置插件或主题。若需要扩展窄变更入口，在仓库组件中实现并验证；不要复制另一套管理器。已有受管配置和状态文件需保持一致，单改生成文件会被后续配置覆盖。
- 后续自动化能力归仓库脚本维护；当前 `scripts/codex.sh` 没有本设置的专用配置动作，不能编造 `swkit codex` 参数。新增执行能力时配套预览、备份、幂等、恢复和隔离验证。

## 验证与交付

1. 分开记录配置解析、运行模式和实际浏览结果。Codex CLI `0.163.0` 可用 `codex features list` 检查配置加载，但不证明滚动正常；其他版本先核对命令支持，完整校验边界见参考。tmux 候选配置可用该版本支持的 `source-file -n` 只解析，避免执行插件或 Shell 命令。
2. 配置为 `never` 而主界面仍 `alternate_on=1` 时，结合配置覆盖、客户端生命周期和是否打开了独立记录查看器判断，不能仅凭这一个字段认定根因。
3. 在 Agent Views 新建 Session 不等于启动新的 CLI 客户端。需要重新初始化屏幕模式时，安排在任务允许的时机重新打开外层 CLI。tmux `3.6` 提高历史容量后需新建窗口或分屏，其他版本按对应规则判断。不要自动关闭工作窗格或重启后台服务。
4. 新客户端回到主界面后再读运行状态，然后检查：超过一屏的回答能否连续上翻；vi 按键、搜索与复制是否符合用户选择；进入 Agent Views、切换 Session 和调整分屏后是否仍满足需求。按实际场景验证，不能为了测试额外调用模型或伪造完成确认。
5. 用户当前无法验证时，保存已确认依据、剩余检查和由谁处理，将交互结果保留为“待验证”。配置写入成功、客户端重开或某个状态字段正确，都不能单独写成问题已解决。
6. 按 [仓库报告约定](../../docs/html-reports.md) 保存 HTML 与 JSON，记录版本、配置范围、运行状态、备份和恢复限制。私有配置与机器记录留在目标机，不提交仓库。恢复前比较当前内容，只撤销本次键值变化，保留后续修改。
