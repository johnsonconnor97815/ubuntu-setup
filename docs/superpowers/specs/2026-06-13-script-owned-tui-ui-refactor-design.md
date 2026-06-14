---
date: 2026-06-13
topic: 现代化 TUI + 脚本自有 UI 重构
status: approved
supersedes_partially:
  - 2026-06-12-bootstrap-software-manager-tui-design.md (whiptail 渲染部分)
---

# 现代化 TUI + 脚本自有 UI 重构

## 背景与动机

现状(见 `bootstrap.sh`):全部 UI 逻辑(`ui_menu`/`ui_yesno`/`ui_msgbox`/`tui_catalog`/`tui_category`/
`tui_software`/`run_op`)写死在 bootstrap 里,基于 **whiptail 蓝框 + 纯文本回退**。脚本本身**没有 UI**:
只通过 `meta` 的 `ops=` 报告操作,TUI 把它们摊成扁平菜单项。

两个问题:

1. **观感老套**。whiptail 的蓝底对话框正是现代 TUI 设计文章点名的 "old-fashioned" 反例
   (ASCII `+ - |` 方框、无语义配色、无 keybind 栏)。
2. **脚本的丰富能力进不了 UI**。`zsh.sh` 是个组件管理器,但其带参动作(`add-plugin <名>`、
   `prompt <名>`)无法从 TUI 驱动,只能靠 `swkit`/LLM。TUI 里的 zsh 只剩几个无参 op,贫瘠。

目标:① 把界面换成**自绘的现代全屏 TUI**(纯 bash + ANSI,零新依赖);② 让**每个脚本拥有自己手写的
丰富 UI**,bootstrap 退化成"发现脚本 + 委派到脚本 UI"的瘦启动器。

## 调研依据(现代 TUI 设计要点)

来自 lazygit / k9s / gum 等项目与两篇 TUI 设计文章,落到本设计的具体做法:

- **固定三区**:顶部 accent 标题栏 + 中部内容 + 底部 keybind 提示栏(只显 3–5 个关键键)。
- **Unicode 圆角盒线** `╭╮╰╯─│`(ASCII 方框是老套之源);选中行用左缘 `▸` + accent 高亮。
- **语义配色**:ok 绿 / warn 黄 / err 红 / info 青 / accent;状态用图标 `●`(已装)`○`(未装)
  `◐`(进行中)`✓`/`✗`;原则"16 色能用,truecolor 更美",且尊重 `$NO_COLOR`。
- **常规列表语义**:`↑/↓`(兼容 `k/j`)只移动,`Enter`/`Space` 激活,`Esc`/`Backspace` 返回/取消,`q` 关闭/退出;目录层级可额外用 `→` 进入。
- **终端安全(不可妥协)**:备用屏幕缓冲(alt-screen)、`stty -g` 存档 + `trap … EXIT INT TERM` 还原、
  `SIGWINCH` 重绘。这恰好契合本项目"fail-safe / 改前可还原"的底线。

## 架构

### 新增 `lib/ui.sh` —— "UI 原语即代码"

与 `lib/common.sh` 把安全契约写成可复用代码同构,`lib/ui.sh` 把现代 TUI 渲染写成可复用代码。
**`lib/common.sh` 末尾 `source` 它**,于是 bootstrap、swkit、每个脚本都自动获得同一套渲染原语——
零重复、观感统一,且消除"UI 逻辑双写"。bootstrap 中所有 `ui_*`/`tui_*`/`run_op` **迁出**到此。

`ui.sh` 是被 `source` 的库(像 `common.sh`):只定义函数与只读量,不设 `set -e`,带幂等加载守卫
`_KIT_UI_LOADED`。

### 能力分层(三档终端)

| 档 | 判定 | 行为 |
|----|------|------|
| 富 TTY | `/dev/tty` 可开 + `TERM` 支持光标寻址(`tput cup` 可用、`TERM≠dumb`) | 全屏 alt-screen 渲染 + 方向键导航 |
| 受限 TTY | `/dev/tty` 可开但终端不富(dumb/无寻址) | 便捷循环退化为纯文本编号菜单(类似现回退);脚本 bespoke 屏退化到 `ui_default_menu` |
| 无 TTY | `/dev/tty` 不可开(LLM/headless/cron) | `ui_*` 拒绝;`<script> ui` 打印"这是交互界面,请用 `swkit <key> <op>`" 并退出 0 |

`ui_supported`(富 TTY?)= `kit_have_tty` 且 `TERM` 富。无 TTY 探测复用 `common.sh` 的 `kit_have_tty`
(真正 open `/dev/tty`,不看权限位)。

### `lib/ui.sh` API(原语词汇)

生命周期 / 安全:
- `ui_supported` → 富 TTY 返回 0。
- `ui_begin` → `stty -g` 存档到全局;`tput smcup`(备用屏)、`tput civis`(隐光标)、`stty -echo -icanon min 1 time 0`;
  `trap '_ui_restore' EXIT INT TERM` + `trap '_ui_winch=1' WINCH`。
- `ui_end` → 幂等还原(`stty "$saved"`、`tput cnorm`、`tput rmcup`);清 trap。
- `_ui_init_palette` → 据 `tput colors` + `$NO_COLOR` 设 `UI_ACCENT/UI_MUTED/UI_OK/UI_WARN/UI_ERR/UI_INFO/UI_SELBG/UI_BOLD/UI_DIM/UI_OFF`;
  无色时全为空串。盒线字符据 locale(UTF-8?)选圆角或 ASCII。

积木:
- `ui_size`(设 `UI_ROWS/UI_COLS`)、`ui_move ROW COL`、`ui_clear`。
- `ui_header TITLE [RIGHT]`(第 1 行 accent 标题栏,右侧可放状态)。
- `ui_footer "↑↓ 移动  ↵/space 选择  esc/q 返回"`(末行 keybind 栏;顶层可改成 `esc/q 退出`)。
- `ui_box ROW COL W H [TITLE]`(圆角盒)。
- `ui_text ROW COL "str"`(按宽截断打印)。
- `ui_badge installed|missing|on|off|active|...` → 上色字形(`●○◐✓✗`)。
- `ui_row ROW W "label" SELECTED [right]`(列表行:选中则 `▸`+accent)。
- `ui_read_key` → 解码一个逻辑键:`up down left right enter esc space tab backspace home end pgup pgdn`
  及裸字符(字母作快捷键)。`read -rsn1` + CSI 续读(`read -rsn2 -t 0.0005`)。

便捷循环(覆盖 90%,免每脚本重写导航;在受限 TTY 自动退化为编号菜单):
- `ui_pick TITLE SUB FOOTER -- id1 lbl1 [id2 lbl2 …]` → 单选菜单循环,回 id(取消回空)。
  支持每项可带徽标/右提示(扩展形式 `--rows` 见实现);目录浏览与各脚本动作菜单都用它。
- `ui_confirm "问题" [y|n]` → 模态是非(回 0/1)。
- `ui_notify TITLE BODY` → 模态信息框(任意键关闭)。
- `ui_input "提示" [默认]` → 单行输入(临时恢复 echo/cooked 读 `/dev/tty`)。
- `ui_run TITLE -- cmd…` → **退出备用屏**,实时显示真实输出(apt/sudo 提示正常),
  `tee` 到时间戳日志,显示 `✓完成 / ✗失败(日志:PATH)`,回车后回 UI。**替代 whiptail gauge**;
  失败只记不抛(对齐约束④:操作失败不杀菜单)。返回命令退出码供调用方记 OK/FAIL。
- `ui_catalog DIR` → 顶层目录浏览器:读各脚本 `meta` 按类别分组、`●/○` 标已装、`→`/`Enter` 进入
  `<script> ui`(子进程)。bootstrap 与 `swkit ui` 共用。坏 `meta` 的脚本跳过并告警(沿用现策略)。

i18n:
- `ui_t KEY` → 据 `$UI_LANG`(en/zh/ja)查通用 UI chrome 表(back/install/remove/configure/apply/cancel/
  yes/no/installed/not_installed/running/done/failed/press_enter/move/select/quit/search/settings…)。
  软件名/插件名等专有名词不翻译(沿用现规则)。bootstrap 载入语言后 `export UI_LANG` 传子进程。

### 跨进程模型(Model 2:每个 UI 入口自包含一段 alt-screen)

`ui_catalog` 选中脚本后,**不**嵌套备用屏:先 `ui_end`(回主屏),再跑 `<script> ui`(它自有
`ui_begin`/`ui_end`),子进程返回后 `ui_begin` 重绘。避免嵌套 smcup/rmcup 串台,且保进程隔离
(脚本 UI 崩溃不污染启动器)。`ui_run` 同理:运行真实命令前 `ui_end`、后 `ui_begin`。

### 脚本"拥有 UI"的约定

- 脚本可定义 `ui()`。`kit_dispatch` 把 `ui` 当**入口模式**(类同 `meta`/`status`/`help`,**不**进 `meta.ops`):
  - 富/受限 TTY → 调 `ui()`(脚本内部可再用 `ui_supported` 决定富屏或退化)。
  - 无 TTY → 打印 `swkit <key> <op>` 指引,退出 0。
- 脚本**没**定义 `ui()` → `kit_dispatch ui` 用 `ui_default_menu`(由 `meta.ops` 合成的动作菜单)兜底。
  新脚本/TEMPLATE 白嫖可用界面。
- `ui_default_menu` 也是 bespoke 屏在受限 TTY 下的统一退化目标。
- **程序化契约完全不动**:`install|remove|configure|<op> [args]` 与退出码原样,swkit/LLM 不受影响。
  UI 纯属增量。

### bootstrap.sh 瘦身

- **保留**:`running_as_sudo_wrapper`/`resolve_target_*`/`ensure_user_dir`/依赖补齐/`deploy_kit*`(vendor-merge)/
  `install_swkit_path`/`deploy_skills`/免密 sudo 开关/i18n 载入(`load_config`/`save_lang`)/headless 流程
  (`--only/--method/--with-node/--skip-skills/--headless/--tui`)/`verify_cli`/`print_next_steps`。
- **移除**:`has_whiptail`/`ui_menu`/`ui_yesno`/`ui_msgbox`/`tui_catalog`/`tui_category`/`tui_software`/
  `run_op`/`op_label`/`preauth_for_op`/`cat_label`/`kit_each_script`(目录遍历移入 `ui_catalog`)→ 去 `lib/ui.sh`。
- **丢弃 whiptail 依赖**:回退路径改为 `lib/ui.sh` 自有的纯文本编号菜单。
- 交互入口 `run_tui` → 顶层菜单只列"安装软件/设置",退出走 `esc/q`;"安装软件"=`ui_catalog`;
  "设置"=语言 + 免密 sudo 开关 callback 仍由 bootstrap 提供,返回走 `esc/q`。设置页的 sudo 开关与语言切换仍是 bootstrap 的
  职责(涉及 sudoers/config 持久化),`ui_main` 通过回调/或 bootstrap 自绘设置子屏调用它们。
  实现取舍:`ui_main` 接受少量"设置项"回调,保持 bootstrap 拥有特权操作,`lib/ui.sh` 只负责渲染。
- 免密 sudo 的对话框从 `ui_yesno`/`ui_msgbox` 改用 `ui_confirm`/`ui_notify`。

### 每个脚本的 UI(全部手写)

- **zsh(旗舰)**:混合屏——框架开关(omz on/off)、提示符选择器(git/plain/starship/p10k/pure)、
  **插件复选清单**(space 切换已知插件、`a` 经 `ui_input` 加任意 git URL)、默认 shell 动作、装/卸 zsh。
  实时读 `~/.config/zsh/ubuntu-setup.conf`;应用即调既有 `_zsh_apply` 重生成 drop-in。用 `ui_supported`
  判富屏,否则退 `ui_default_menu`。作为其余脚本 UI 的参考样板。
- **docker**:状态行 + 徽标(在 docker 组?服务运行?);动作 装/卸/配置 经 `ui_run`。
- **claude / codex**:状态(版本);装(native/npm 子选择)/卸;装后登录提示(`ui_notify`)。
- **node**:node/npm 版本徽标;装/卸。
- **git**:版本徽标;装/卸;**额外** `user.name`/`user.email` 配置(`ui_input` → `git config --global`)。
- **curl**:版本徽标;装/卸。
- **TEMPLATE.sh**:加 `ui()` 注释样例 + 说明(省略则自动菜单)。

### swkit

- bare `swkit <sw>`(无 op):TTY 下跑 `<script> ui`,否则打印脚本 usage(现行为)。
- 新增 `swkit ui` → `ui_catalog "$KIT_SCRIPTS_DIR"`。
- `swkit help` 增列 `ui` 用法。`list`/`search`/`<sw> <op> [args]` 不变。

## 校验

- `bash -n bootstrap.sh lib/*.sh swkit scripts/*.sh` 全过。
- `shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh`、`shellcheck lib/common.sh lib/ui.sh bootstrap.sh` 零告警。
- 每脚本:`meta` 字段齐全且 `ops` 与实现一致(`ui` 不在 `ops`)、`status` 独立可跑、`help` 不炸、
  `ui` 在无 TTY 下打印指引退 0。
- `./bootstrap.sh --help`。
- 富屏渲染无法 headless 自动测;冒烟 `ui_supported` 假路径 + 用 `script(1)`/伪 TTY 烟测 `ui_read_key` 解码与
  `ui_pick` 一轮(尽力)。

## 文档同步

CLAUDE.md(架构:`lib/ui.sh`、`ui()` 约定、丢弃 whiptail、脚本拥有 UI)、AGENTS.md、README.md、
`skills/ubuntu-install/SKILL.md`、`skills/zsh-setup/SKILL.md`(编写契约加 `ui()` 守则:用共享原语、
富/受限/无-TTY 三档、`ui` 不进 `ops`)。漂移警告:`lib/ui.sh` 的 UI 契约与 SKILL 散文同步。

## YAGNI(明确不做)

鼠标支持;truecolor-only 特性(必须 16 色可用);超出脚本现有状态文件的额外持久化;
多发行版;把 catalog 变回数据驱动引擎(脚本仍自报 `meta`)。

## 安全考量

`ui_run` 退出备用屏后跑真实命令,sudo 密码提示走真实终端(比现 gauge-pipe 更正——现方案靠 preauth
绕开 pipe 无法输密)。免密 sudo 写 sudoers 仍只经 bootstrap 设置页、UI 交互(无 flag,沿用用户记忆)。
所有改动经 git 跟踪、可 `git diff` 审。`ui.sh` 不引入任何提权原语,渲染与特权严格分离。
