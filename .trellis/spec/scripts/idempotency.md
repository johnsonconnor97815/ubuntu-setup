# 幂等纪律 —— 重跑必须安全

> 对应安全契约 ①(查活系统)与 ④(fail-fast/可续跑/无回滚)。见 [../lib/safety-contract.md](../lib/safety-contract.md)。

---

## `status` 是闸门

每个操作以观察真实系统为前提。`status` 退出码 0 **当且仅当**已装/已生效:

```bash
status() { have_cmd git && git --version; }
```

- 用 `have_cmd <cmd>`(在 PATH?)与 `pkg_installed <pkg>`(dpkg 状态**恰为** `install ok installed`)。
- **绝不**依赖记录的标志位/自管状态文件来判断"是否装好"。
- 组件管理器里(`go.sh`/`python.sh`),`status` 以"工具实际可用"为判据,而非"曾经装过"。

## 收敛,不累积

`do_install`/`do_remove` 先跑 `status`,已是目标态就报告并 `return 0`:

```bash
do_install() {
  if status >/dev/null 2>&1; then
    log_info "X already installed — skipping."
    return 0
  fi
  apt_install x
}
do_remove() {
  if ! status >/dev/null 2>&1; then
    log_info "X is not installed — nothing to remove."
    return 0
  fi
  apt_remove x
}
```

结论:**重跑 `bootstrap.sh` 或任一脚本第二次都是安全 no-op。**

## 改文件:先备份,再幂等追加

- 改任何配置文件前 `backup_file PATH`(时间戳副本 = 唯一撤销)。
- 追加配置行用 `append_once LINE FILE`(`grep -qxF`,重跑不出现重复)。
- 受管块/drop-in 模式:整体重生成标记块,保留用户标记外内容(见 `zsh.sh`/`tmux.sh`)。

## fail-fast,无回滚

- 脚本 `set -Eeuo pipefail`,首错即停。
- **不写回滚逻辑**——补救方式是重跑(幂等保证安全)+ 备份恢复。
- 探测/带色输出陷阱:解析 `uv tool list` 等带色输出前 `NO_COLOR=1` 并 strip ANSI,否则会误判工具未装(见 `python.sh`);判断系统状态按退出码/稳定文本,不按可翻译文案(见 `rime.sh` 的 `LC_ALL=C apt-cache policy`)。

## headless 严格 / UI 宽松(但都幂等)

- headless 路径保持严格 fail-fast。
- 交互界面里每个状态变更经 `ui_run` 单独跑(子进程),失败不杀界面循环——靠幂等重跑补救(见 [ui-conventions.md](./ui-conventions.md))。
