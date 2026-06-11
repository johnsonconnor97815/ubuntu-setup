# PRD: TUI 三屏闭环 — tui-three-screen-loop

> 来源：2026-06-09 grillme 访谈路线图 + 任务① engine-seams（已交付：`429c5c6`/`6881a82`/`ae9ed19`）+ 2026-06-10 布局拍板（双栏）与 Textual 前置查证（[research/textual-verification.md](research/textual-verification.md)）。

## 目标

首个可用 TUI：裸命令进入 → browse 双栏浏览 catalog（实时状态）→ `i` 安装 → plan 模态确认 → progress 行级日志 → 回 browse 刷新。**脑脸分离是一等约束**（不可妥协项①）：`tui/` 只消费 `core/service` facade，零安装逻辑、零 subprocess。

## 引擎接缝（任务①已交付，直接消费）

- `core.service`：`scan(catalog, run=)` → `Iterator[ScanResult(entry, state|None, error|None)]`；`prepare_install(entry_id, catalog, priv=)` → `PreparedRun`；`apply(prepared, priv=, logger=, run=, stream_run=, check_mode=, keepalive=)` → `ApplyHandle`（可迭代事件 + `cancel()→TerminateOutcome` + `close()`）。
- `core.events`：`RunStarted(total)` / `StepStarted(index,total,entry_id,op)` / `OutputLine(entry_id,line,stream)` / `StepFinished(index,total,result)` / `RunFinished(results,exit_code,cancelled)`。
- `core.privilege`：`probe_credentials()→CredentialStatus(CACHED/NONE/UNAVAILABLE)`；`ensure_sudo()` 交互；keep-alive 由 `service.apply` 托管。
- 取消杀当前步（含提权 kill 与 DEGRADED 降级可感知）已全部在引擎层。

## 已拍板决策

1. **布局**：browse 双栏（左列表右详情联动：id/type/tags/状态/依赖/描述）；plan-confirm 为 `ModalScreen[bool]` 覆盖；progress 推新屏。
2. **browse**：进屏即起 thread worker 跑 `service.scan` 流式逐行刷新；状态徽章 ✓已装 / ·未装 / ↑可升级 / ⟳检查中 / !错误；**只绑 install 键**（remove/upgrade 不露出，状态照显）。
3. **progress**：`Log`（**显式设 `max_lines`**）+ step 进度头（N/M + 当前条目）。**批量 drain 是强制要求**（实测 25× 差距：逐行 marshal 2,403 行/s vs 批 50 行 60,132 行/s，见 research）——消费 worker 每批取尽当下可得事件，OutputLine 聚合一次 `write_lines`，每批一次 `call_from_thread`；禁止每事件一次 marshal。
4. **取消**：`c` → `handle.cancel()`；返回 DEGRADED → 显示「无法终止，等待当前步完成」；杀步后结束摘要明示「系统可能处于半装状态，建议运行 `dpkg --configure -a`」。
5. **sudo（探测自适应 TUI 侧）**：确认 plan 后、apply 前：`probe_credentials()` 非 CACHED → 在 worker 里 `call_from_thread` 包住 `with app.suspend(): priv.ensure_sudo()`（research §2 的用法约束）；失败显示错误回 browse，不退出 app。
6. **入口**：裸 `python -m ubuntu_setup` → TUI；`--install`/`--apply` headless 路径零回归（textual 的 import 只发生在 TUI 分支内）；`pyproject.toml` 正式加依赖 `textual>=8,<9`。
7. **键位**：`j/k`+方向 移动、`i` 安装、`/` 过滤（esc 清除）、`q` 退出；progress 屏 `c` 取消、结束后 enter 返回。
8. **测试**：`tests/tui/` Pilot + 注入 fake facade（不 shell out）；节流有客观断言。

## 范围（模块）

- `pyproject.toml`：`textual>=8,<9` 依赖。
- `cli.py`：无参数分支 → 启动 TUI（textual import 局部化在该分支，headless 不加载）。
- `tui/app.py`：ManagerApp（service/privilege 依赖注入）+ BINDINGS + 样式。
- `tui/screens/browse.py`：双栏联动；scan worker（`exclusive=True` 成组）；过滤；`i` → 安装流程 worker（prepare → 确认 → sudo → 推 progress）。
- `tui/screens/confirm.py`：`ModalScreen[bool]` 渲染 plan（条目/op/predicted_state_change；区分「would change」与「cannot fully simulate」——spec idempotency 的 plan 语义）；worker 内 `push_screen_wait`。
- `tui/screens/progress.py`：Log + 进度头；批量 drain 消费 worker；取消键；结束摘要（成功/失败/取消 + dpkg 提示）；返回 browse 并触发受影响条目重新 check 刷新。
- `tui/widgets/`：状态徽章等（确有复用才建）。
- `tests/tui/`：Pilot 套件 + **core 不 import textual 守护测试**（import `ubuntu_setup.core` 全模块后断言 `sys.modules` 无 `textual`）。

## 非目标

remove/upgrade 键位、installed 屏（任务③，先定义再做）、多选/批量安装、tag 分组视图、主题定制、LLM。

## 验收

- Pilot 测试全绿；既有 121 个 headless 测试零回归；core-无-textual 守护测试。
- **节流验收**：fake ≥5000 行日志洪水，断言 marshal 调用次数 ≪ 行数，进度屏测试不超时。
- **真机手测记 journal**（硬验收，衔接任务①遗留的真机冒烟）：裸命令进 TUI → 浏览+过滤 → 安装 `tree` 全流程（plan 确认 → sudo suspend 提示 → 行级日志 → 回 browse 状态变 ✓）；SSH 80 列窄端可用；取消路径（含提权 kill 成功 / 凭证失效 DEGRADED）。
- 脑脸分离审查：`tui/` 内无 subprocess/sudo/安装逻辑。

## 风险

- **suspend × worker × sudo 的真实终端交接**（headless 测不了 tty）→ 真机冒烟列为硬验收。
- 窄终端双栏拥挤 → Textual CSS `fr` 自适应；<90 列时详情栏可隐藏（实现时定）。
- 快速滚动时详情联动刷新风暴 → 详情更新保持纯渲染轻量，必要时 debounce（实现时定）。
- 列表部件几百行性能 → 文档称数千行无虞，低风险。

## spec 同步（与代码一并交付，不许默默偏离）

- `tui/ui-guidelines.md`：status 头 reconcile 为 code-backed；示例与真实 App/Screen/worker 代码对齐。
- `core/directory-structure.md`：`tui/` 模块清单从规划变实际；入口描述（裸命令 → TUI）落地。
