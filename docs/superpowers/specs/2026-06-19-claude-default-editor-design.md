# Claude Code 默认编辑器管理(`scripts/claude.sh` 第 4 轴)

日期:2026-06-19
状态:已批准设计,待实现

## 目标

在 `scripts/claude.sh`(Claude Code 扩展管理器)里新增「指定默认编辑器」能力:用户能把 Claude Code 在交互式会话里 `Ctrl+G` 打开的外部编辑器从当前默认(常见为 VS Code)改成 vim 等;脚本**动态探测**当前机器上装了哪些编辑器,只把可用的展示为可指定项,并支持自定义命令。

## 背景:机制是 `$EDITOR` / `$VISUAL`

调研结论(权威性较高):

- Claude Code 的外部编辑器(`Ctrl+G` 把当前 prompt 在外部编辑器打开)走**标准 Unix 的 `$EDITOR` / `$VISUAL` 环境变量**。
- settings.json 里**没有**专门的 `editor` 字段,`claude config` 也**没有**编辑器相关 key。
- 所谓「默认 vscode」通常是因为环境里 `EDITOR=code`(或在 VS Code 集成终端中运行)。
- 因此「指定默认编辑器」本质 = 设置 `EDITOR` / `VISUAL`。

## 作用域决策(用户已选定)

把 `EDITOR` / `VISUAL` 写入 **`~/.claude/settings.json` 的 `env` 块**——仅对 Claude Code 生效,不改用户全局 shell。理由:

- 最贴合「**Claude 的**默认编辑器」语义,最小侵入(不污染 git/crontab 等其他读 `$EDITOR` 的工具)。
- 与 `claude.sh` 既有「以文件方式管理 `~/.claude`」的范式一致(skills 轴也是文件式)。
- settings.json 的 `env` 块是为 Claude Code 注入环境变量的受支持方式;Claude 启动时把它应用到自身进程环境,`Ctrl+G` 派生的编辑器子进程继承之。

放弃的备选:写全局 shell rc(影响所有工具,语义过宽);两处都写(改动面最大、状态需同步,无必要)。

## 候选编辑器目录(curated + 动态探测)

仿 `_claude_mcp_curated`:key → `探测命令<TAB>EDITOR 写入值<TAB>说明`。GUI 编辑器必须带阻塞参数,否则进程立即返回、Claude 误判编辑已完成。

| key      | 探测命令 | EDITOR 写入值   | 说明(en,zh/ja 本地化) |
|----------|---------|-----------------|------------------------|
| `code`   | `code`  | `code --wait`   | VS Code (waits for the tab to close) |
| `cursor` | `cursor`| `cursor --wait` | Cursor (waits for the tab to close) |
| `nvim`   | `nvim`  | `nvim`          | Neovim |
| `vim`    | `vim`   | `vim`           | Vi-compatible modal editor |
| `nano`   | `nano`  | `nano`          | Simple, always-available editor |
| `micro`  | `micro` | `micro`         | Modern, easy terminal editor |
| `emacs`  | `emacs` | `emacs -nw`     | Emacs in the terminal |
| `helix`  | `hx`    | `hx`            | Helix (hx) |

- 编辑器**专有名不翻译**(项目规则),仅说明 gloss 本地化。
- 任意命令(非 curated)亦可设置(power user / 自定义),原样写入。

## 新增动作(参数化,经 `kit_dispatch` 路由,不进 `meta.ops`)

与 `mcp-add` 等参数化 op 同范式:`meta.ops` 仍只 `install,remove`,带参动作由 `swkit`/LLM/`ui()` 调用。

- `set-editor <curated-key|任意命令>`
  - `_claude_gate`(claude 已装)→ `_claude_user_paths`(解析真实 home、**拒绝 sudo 包裹**,settings.json 须用户拥有)。
  - curated key → 解析为带阻塞参数的写入值;非 curated → 原样;首 token 不在 PATH 则 `log_warn` 提示先安装,但仍写入(允许先配置后安装)。
  - 经 jq 把 `.env.EDITOR` 与 `.env.VISUAL` 写入 settings.json。
- `clear-editor`
  - 删除 `.env.EDITOR` / `.env.VISUAL`;若 `.env` 变空则删掉 `.env`。回退到 shell `$EDITOR`。

## settings.json 安全改写

- 路径:`$_CHOME/.claude/settings.json`(`_CHOME` 来自 `_claude_user_paths`)。
- 用 `jq`;`have_cmd jq || apt_install jq`(apt 主渠道、tiny;经 `sudo_run` 逐命令提权,符合契约)。
- 文件不存在 → `mkdir -p ~/.claude` 后以 `{}` 起步。
- 改前 `backup_file`;写临时文件再原子 `mv`;jq 失败(如 JSON 损坏)则报错且不覆盖(有备份兜底)。
- 幂等:重复 set 同值结果不变。

## 状态读取(为 UI 与诚实展示)

- `_claude_editor_current`:从 settings.json 读 `.env.EDITOR`(jq;无 jq 时 grep 兜底),空=未由本 kit 设置。
- UI 顶部信息行如实显示「当前生效编辑器 + 来源」:
  - 由 Claude settings.json 设置 → `current: <值> (Claude settings)`
  - 否则取自 shell `$EDITOR` → `current: <值> ($EDITOR)`
  - 都没有 → 提示未设置(Claude 回退到系统默认 / VS Code 集成终端)。

## `ui()` 集成

在 `ui()` 的 Skills 区块之后、危险区(remove CLI)之前,插入「Default editor」区块:

- `header`「Default editor」+ 信息行(当前值/来源)。
- 每个 curated 编辑器一行:
  - 已安装(`have_cmd 探测命令`)→ 可选;当前值匹配则打 ✓。
  - 未安装 → 灰显 + `(not installed)` 标签;选中给 `ui_notify` 提示先安装,不写入。
- `+ set custom editor…` 行(`ui_input` 任意命令 → `set-editor`)。
- `use shell default (clear)` 行(仅当当前由本 kit 设置时出现)→ `ui_confirm` → `clear-editor`。

每次状态变更经 `ui_run "<标题>" -- "$0" set-editor|clear-editor …`,随后 `refresh=1` 重载。受限终端回退 `ui_default_menu`(因 set/clear 是参数化 op,菜单兜底仅展示无参 op——可接受,与既有参数化 op 一致)。

## i18n 新增 key(en/zh/ja)

`CLAUDE_I18N`:`editor_section` / `editor_set_custom` / `editor_use_default` / `prompt_editor` / `tag_not_installed` / `editor_from_settings` / `editor_from_env` / `editor_unset` / `confirm_clear_editor` / `editor_need_install`(标题+正文,{X} 替换)/ `foot_main` 复用 / `editor_desc:<key>`(8 个)。编辑器名不译。

## 文档同步(避免漂移)

- 更新 `CLAUDE.md` 中 `claude.sh` 段落:补「第 4 轴/默认编辑器:settings.json env.EDITOR/VISUAL,curated+动态探测,set-editor/clear-editor」。
- 更新 `skills/claude-extensions/SKILL.md`:简述如何用 `set-editor`/`clear-editor` 帮用户挑编辑器(品味:GUI 需 `--wait`、Claude-only 作用域)。改 skill 需重跑 `bootstrap.sh` 刷新 `~/.claude`/`~/.codex`(实现说明里提醒,不在本 worktree 自动跑)。

## 验证

- `bash -n scripts/claude.sh`;`shellcheck -x --source-path=SCRIPTDIR scripts/claude.sh`(零告警)。
- `scripts/claude.sh meta`:`ops` 仍 `install,remove`、**不含 `ui`/`set-editor`**。
- `scripts/claude.sh help` 不炸;`scripts/claude.sh ui` 无 TTY 打印指引退 0。
- 伪终端冒烟:`printf 'q' | TERM=xterm-256color script -qec 'scripts/claude.sh ui' /dev/null` 渲染不崩、`q` 干净退出。
- 行为:在装有 claude 的环境 `set-editor vim` 后,检查 `~/.claude/settings.json` 的 `.env.EDITOR == "vim"`;`clear-editor` 后该 key 消失。

## 非目标(YAGNI)

- 不支持全局 shell 作用域(用户已明确选 Claude-only)。
- 不做编辑器的安装(那是 vscode.sh/cursor.sh 或 apt 的事);本组件只「指定」,未装则提示。
- 不管理 `git` 等其他工具的编辑器。
