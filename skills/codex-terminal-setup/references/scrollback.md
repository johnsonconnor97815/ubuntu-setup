# 版本依据与排查分支

## 已核对的边界

依据核对日期：2026-10-17。以下结论来自实际读取的 Codex CLI `0.163.0`、tmux `3.6` 对应源码、本机状态检查和 tmux 隔离验证；不是最低支持版本或其他版本的兼容性承诺。

**尚未完成：重新打开 Codex CLI 后，连续长回答、Agent Views 切换、调整分屏和 vi 复制的实际交互验证。** 后续验证须重新读取目标环境，不把这次设置或诊断直接当成功能通过。

| 项目 | 已有依据 | 不能据此认定 |
| --- | --- | --- |
| `tui.alternate_screen = "never"` | 0.163.0 配置加载接受此值，启动路径选择终端滚动模式 | 当前已经运行的客户端会立即切换 |
| Agent Views 新建 Session | 创建后端 thread，复用当前 `App` / `Tui`；部分会话配置可重新加载 | 新 Session 会重新初始化终端屏幕 |
| `alternate_on` | tmux 报告当前窗格是否处于备用屏幕 | 单独一个 `1` 就能证明配置错误或未重启 |
| tmux `history-limit` | 3.6 隔离验证中新窗格使用新上限，旧窗格保留原容量 | 修改默认值或重开窗格内的 Codex 会扩大旧窗格容量 |

## 区分界面和会话

在已核对的版本中：

- Codex CLI 的终端客户端持有屏幕模式。Agent Views 是其中的会话管理界面；新建或切换后端 Session 不能代替启动新的终端客户端。
- 屏幕缓冲模式在 CLI 启动路径中决定。发现旧进程在配置变更前启动，且主界面仍在备用屏幕时，这支持“当前客户端尚未应用新模式”；同时核对启动覆盖和实际配置路径。
- 备用屏幕不会像普通终端输出那样给 tmux 持续保留完整的已滚过文字。这能解释“只看到一屏，再往前是无关旧输出”的现象，但同类现象也需排除历史裁剪或输出重建。
- 独立记录查看器会临时进入备用屏幕。因此应先确认在主界面还是查看器中，再解读 `alternate_on`。

不要从“新建 Session 可能重读配置”推导出屏幕模式已改变；两条处理路径不同。

## 浏览方式与键位

| 0.163.0 的界面 | 已核对的操作 |
| --- | --- |
| 默认全屏主界面 | `PageUp` / `PageDown` 翻页；`Ctrl+Home` / `Ctrl+End` 到开头或最新内容 |
| 默认全屏中的 `Ctrl+T` | 在当前视图显示详细记录，未必出现明显的新窗口 |
| 终端滚动模式中的独立记录查看器 | `Ctrl+T` 打开；`j/k`、上下键逐行；`Ctrl+U/D` 半页；`PageUp/PageDown` 翻页；`Home/End` 首尾；`/` 或 `F3` 搜索；`q` 或 `Ctrl+T` 关闭 |
| tmux vi 复制模式 | 以实际 `copy-mode-vi` 键表为准；不要假定用户的前缀键或自定义选择、复制键 |

这不是完整 Vim 实现。Codex `/vim` 作用于输入框编辑，不能当作对话浏览键位的统一开关。

Codex 查看器按会话记录显示内容，能够加载仍可读取的较早记录，也可显示主界面省略的已记录摘要。tmux 只能查看窗格已输出且尚未裁剪的文字。保留终端滚动模式后仍可使用独立查看器，两者可以配合。

## 配置与恢复

Codex 配置位置使用目标客户端实际的 `CODEX_HOME/config.toml`；未设置时通常为 `~/.codex/config.toml`。用户配置仍可能被项目配置、profile 或启动覆盖改变，先检查实际来源。

候选内容：

```toml
[tui]
alternate_screen = "never"
```

已有 `[tui]` 时只合并 `alternate_screen`。遇到已有点号键、内联表或复杂布局时，先解析并生成候选文件；不能靠在末尾追加整段 TOML 合并。保存原内容、属主、权限及备份位置，核对候选数据的变化仅为目标键，然后写入并再次校验。

0.163.0 中实际运行过 `codex features list` 检查配置加载；命令行临时覆盖为 `never` 可以加载，无效枚举对照被拒绝。该结果证明此路径会检查枚举值，不证明终端功能正常。`codex --strict-config features list` 在该版本被明确拒绝，不使用这条命令作为校验方法。原生 CLI 可能生成自身缓存或临时目录，不能承诺调用完全零写入。

原值不存在时，恢复应移除本次新增的键；原来有值时恢复记录的原值。不要一律设回 `auto`，也不要用旧备份覆盖用户后来加入的 MCP、模型或其他设置。

tmux 配置还需识别主配置、XDG 配置和 `source-file` 链，检查相关文件是否实际存在及选项优先级。对 ubuntu-setup 管理的配置，持久的 `history-limit` 与管理状态中的 `HISTORY` 必须一致。仓库 `scripts/tmux.sh` 是其管理实现，`configure` 路径还会处理已有插件和主题；不要把它误当成无其他行为的单项 setter。

## 尚未生效时如何判断

| 观察 | 处理 |
| --- | --- |
| 配置是 `never`，工作客户端早于配置写入，主界面仍 `alternate_on=1` | 安排启动新的外层 CLI 客户端，再读取主界面状态；仅在 Agent Views 新建 Session 不足以证明生效 |
| 新客户端仍在备用屏幕 | 重新核对实际二进制版本、配置路径、profile、项目及启动覆盖；排除独立查看器，不反复写相同设置 |
| tmux 默认为 200000，而现有窗格仍为 50000 | 在 3.6 中符合预期；新建窗口或分屏后检查新窗格，不结束原工作窗格来强制验证 |
| 主界面已经不是备用屏幕，仍看不到所需内容 | 检查该窗格历史是否已裁剪、Codex 恢复或宽度变化是否重建了有限的显示历史，不直接扩大其他配置 |
| 用户无法重开或验证 | 保留配置、原会话和“待验证”状态，给出下一次验证步骤，不宣称已修复 |

200000 行是容量上限，不会在新窗格建立时预先分配全部历史行。实际内存随内容、行宽及窗格数量变化；提高 tmux 上限不会找回已丢弃输出，也不代表 Codex 会把所有历史重新输出到终端。

tmux 3.6 的已执行隔离对照：先以 50000 创建窗格，改默认值到 200000 后，已有窗格仍为 50000，新建窗格为 200000。隔离测试使用独立 socket 和空配置，未重启工作服务器。上游后续实现已改变这项行为；其他版本需要读取对应版本手册或隔离验证，不能套用当前开发分支。

## 来源

- [Codex TUI 配置](https://developers.openai.com/codex/config-advanced#tui-options)：`alternate_screen = "never"` 保留终端滚动历史。
- [Codex 0.163.0 屏幕模式解析](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/lib.rs#L2175) 与 [启动处理](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/startup_orchestration.rs#L294)：决定屏幕缓冲及终端显示模式。
- [Agent Views 新建 Session](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/app/agents_overview_new.rs#L95) 与 [新会话配置处理](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/app/new_session.rs#L53)：会话配置刷新与终端初始化分别处理。
- [全屏导航](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/transcript_view/input.rs#L426)、[查看器处理](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/app_backtrack.rs#L158)、[独立查看器按键](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/pager_overlay/transcript.rs#L423) 与 [默认键位](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/keymap.rs#L1879)。
- [记录分页](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/app/history_pagination.rs)、[摘要呈现](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/history_cell/messages.rs#L395) 与 [显示历史重建](https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/tui/src/app/resize_reflow.rs)：可读记录与终端缓存的边界。
- [tmux 3.6 手册](https://github.com/tmux/tmux/blob/3.6/tmux.1#L4552)、[历史网格初始化](https://github.com/tmux/tmux/blob/3.6/grid.c#L297) 与 [上游问题 #4705](https://github.com/tmux/tmux/issues/4705)：历史容量、生效范围及后续变化。
