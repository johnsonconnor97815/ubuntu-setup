# ui() 交互界面约定

> 渲染原语在 `lib/ui.sh`。样板:`scripts/zsh.sh`(旗舰)、`scripts/git.sh`(简单)、`scripts/TEMPLATE.sh`(注释样例)。
> **UI 契约漂移**:`ui()` 约定 / `ui` 非 op / 三档降级 同时落在 `lib/ui.sh`、`TEMPLATE.sh`、两个 `SKILL.md`——改一处必查其余。

---

## `ui` 是入口模式,不是 op

`ui` 与 `meta`/`status`/`help` 同级,由 `kit_dispatch` 处理,**绝不进 `meta` 的 `ops=`**,也没有 `do_ui`。

- 有 TTY:调脚本的 `ui()`(没定义则 `ui_default_menu` 由 meta ops 合成)。
- 无 TTY(LLM 的非交互 shell):打印「用 `swkit <key> <op>`」指引并**退 0**——程序化 op 接口永远可用、不丢。

`ui()` 是**可选**的。省略则 `ui_default_menu` 兜底(状态徽章 + Install/Remove/Configure 列),对多数脚本够用。

## 三档终端降级

1. **富 TTY**:全屏 alt-screen 渲染。
2. **受限 TTY**:纯文本编号菜单。
3. **无 TTY**:静默降级 / 打印指引退 0。

手写 `ui()` 起手必须先判:

```bash
ui() {
  if ! ui_supported; then ui_default_menu; return 0; fi
  ui_begin || { ui_default_menu; return 0; }
  # ... 循环 ...
  ui_end
  return 0
}
```

`ui_begin`/`ui_end` 的 `trap ... EXIT INT TERM` 保证任何崩溃都复原终端(备用屏/光标/`stty`)。

## 每个状态变更经 `ui_run`

```bash
ui_run "$(ui_t install) git" -- "$0" install
```

`ui_run` 退出备用屏直接展示真实输出(apt/sudo 提示正常)、`tee` 到 `~/.cache/ubuntu-setup/` 日志、显示 `✓/✗`、回车再回屏。**操作失败(含 `RC_NEED_SUDO`)不杀循环**——返回退出码、点名日志、回菜单,靠幂等重跑补救。回屏后重载 `status`。

## lib/ui.sh 原语

- `ui_pick TITLE SUB FT -- id label …` 单选子菜单(设 `UI_PICK`)
  - **可选详情行**:调用**前**填全局数组 `UI_PICK_DETAILS`(与 id/label **同序等长**),`ui_pick` 在列表下方画**当前高亮项**的详情(富 TTY);**消费即清**(进函数即读入局部副本后清空全局),故不填的调用(全 kit 多数 picker)零行为变化、无跨调用串味。详情文本须**纯文本**(`ui_row` 不截断,详情行自截到 `UI_COLS-N` 后再裹 `$UI_MUTED`/`$UI_OFF`,别把色码计进宽度)。受限 TTY 回退把详情附在编号行。样板:`nvim.sh` 的 colorscheme/font 选择器。
- `ui_confirm "question?"` yes/no(返回 0/1)
- `ui_input "prompt" [def]` 单行输入(设 `UI_INPUT`)
- `ui_notify TITLE BODY` 模态信息框
- `ui_badge installed|missing|on|off|check|cross` 彩色状态字形
- `ui_header`/`ui_footer`/`ui_row`/`ui_move` + `ui_read_key`(设 `UI_KEY`:up/down/enter/space/q/esc/backspace/…)
- `ui_t KEY` i18n(en/zh/ja);软件特有串用本地表(同 `git.sh` 的 `GIT_I18N`/`_git_t`)。**名称/标识符不译**。

## 致命陷阱:`set -Eeuo pipefail` 下的 `(( ))`

移动选择项**永远用** `sel=$(( ... ))`,**绝不**用裸 `(( sel = ... ))`。裸 `(( ))` 当结果为 0 时退出码为 1,在 errexit 下会因一次按键就崩掉整个 UI。`$(( ))` 赋值形式总返回 0。

```bash
up|k)   sel=$(( (sel - 1 + n) % n )) ;;
down|j) sel=$(( (sel + 1) % n )) ;;
q|Q|esc|backspace) break ;;
```

## 带参动作要在 UI 里可达

带参 op(`add-plugin`/`add-schema`/`prompt` 等)除了经 `swkit`/LLM 调用,**也**应在 `ui()` 里交互可达(空格勾选、`a` 加任意项、子菜单)——见 `zsh.sh`/`tmux.sh`/`rime.sh`。
