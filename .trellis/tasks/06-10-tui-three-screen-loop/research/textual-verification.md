# Textual 8.x 前置查证（任务② 动手前必读）

> 2026-06-10 验证；环境：textual 8.2.7（uv 临时环境，Python 3 本机）；文档来源 context7 `/websites/textual_textualize_io`；吞吐为本机 headless `run_test()` 实测（真终端渲染只会更慢，SSH 下更甚——结论方向不变）。

## 1. 日志部件选型与高频 append 吞吐（实测）

- 流式进程输出选 **`Log`**（面向逐行纯文本：`write_line` / `write_lines` / `max_lines` / `auto_scroll`）；`RichLog` 面向任意 Rich renderable，逐行场景没必要。
- 实测（5000 行，headless）：
  - 每行一次 `call_from_thread(log.write_line, …)`：**2,403 行/s**（每次 marshal round-trip 事件循环）。
  - 每 50 行一次 `call_from_thread(log.write_lines, batch)`：**60,132 行/s**（25× 提升）。
  - `max_lines=1000` 两种写法都正确封顶 `line_count==1000`（内存有界 ✓）。
- **结论（设计约束）**：progress 屏的 worker 必须**批量 drain** ApplyHandle 事件——把当下可得的事件一次取尽（或小时间窗聚合），OutputLine 聚合成一次 `write_lines`、step 事件逐个更新，**每批一次 marshal**。禁止每事件一次 `call_from_thread`。
- 验收可断言：fake 高频输出（≥5k 行）下 marshal 调用次数 ≪ 行数。

## 2. `App.suspend()`（sudo 交互提示的载体）

- 文档确认：`with self.suspend(): system("vim")` 形态的上下文管理器，专为「暂停全屏、把终端交给交互式外部命令」设计——`sudo -v` 场景成立。
- 注意：suspend 是 App 方法、在事件循环线程使用。**从 thread worker 里要用 `call_from_thread` 包住整个 `with self.suspend(): priv.ensure_sudo()` 的函数**（阻塞事件循环正是 suspend 的语义——终端已交给 sudo）。实现时再核一次该交错（已列入 prd 风险）。

## 3. 其余 API 现状核对（与 spec ui-guidelines 一致）

- `@work(thread=True)` + `App.call_from_thread`：现行文档原样推荐（流式逐块更新 UI 的官方示例即此形态）。
- `push_screen_wait(screen)`：**只能在 worker 里调**（文档明示），配 `ModalScreen[T]` + `Screen.dismiss(value)` 拿确认结果——plan-confirm 屏的形态。
- `Log`/`RichLog` 构造参数、`auto_scroll` 默认 True、`max_lines` 默认 None（无上限——必须显式设）。

## 4. 版本

- textual 8.2.7 可正常安装运行（`uv run --with "textual>=8,<9"`），与 spec 锁定的 `textual>=8,<9` 区间一致。

## 复现

基准脚本：`textual_log_bench.py`（headless `run_test` + 生产者线程；per-line vs batch(50)；见本文件同目录或会话记录）。
