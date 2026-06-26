# 技术设计 — nvim curated 列表逐条说明文案

## 受影响文件(仅两处代码)

- `lib/ui.sh` — 给 `ui_pick`(及回退 `_ui_pick_text`)加向后兼容的「选中项详情行」。
- `scripts/nvim.sh` — i18n 逐条说明 + UI 行内短说明 + help/list-* 完整说明 + 选择器详情 + plugins/Mason 模型解释 + meta desc 重排。

> `.trellis/` 下的 md 在主树写;`lib/ui.sh` / `scripts/nvim.sh` 的改动**在 worktree 内做**(worktree guard 会拦主树代码写入)。

## 一、`lib/ui.sh` · `ui_pick` 详情行

### 契约(向后兼容,零改 32 处现有调用)
- 引入全局数组 **`UI_PICK_DETAILS`**(默认未声明/空)。调用方在调用 `ui_pick` **之前**填:`UI_PICK_DETAILS[i]` 对应第 i 个 `id/label` 对的完整说明。
- `ui_pick` 渲染时,若 `${#UI_PICK_DETAILS[@]} -gt 0`,在列表区**下方、footer 之上**画一行(或按宽度截断的一行)**当前高亮项**的 `UI_PICK_DETAILS[$sel]`,用 `$UI_MUTED … $UI_OFF`。未填 → 不画、布局与现状字节级一致。
- **消费即用、用后即清**:`ui_pick` 在函数**开头**把 `UI_PICK_DETAILS` 读进**局部副本**(`local -a _details=( "${UI_PICK_DETAILS[@]}" )`)后立刻 `UI_PICK_DETAILS=()` 清空——避免下一次未填 details 的调用串到上次的值(同 `UI_PICK`/`UI_KEY` 这类全局的「调用边界清理」思路)。
- 详情行占 1 行,故 `avail`(列表可视行数)在有详情时 `-1`(`avail=$(( UI_ROWS - listrow - 1 - have_detail ))`),否则不变——保证布局不挤掉 footer。
- **`ui_row` 不截断**(已核实:268 行只 `\033[K` 清行后原样 `printf` label,长 label 会折行)——所以详情行**必须自己截断**到 `UI_COLS-2` 左右,且文本里**不能含 ANSI**(纯字面短语),否则 `${detail:0:n}` 会把字节宽算错、或截在转义序列中间致色彩残留。详情串本就是纯文本说明,天然满足;只要别把 `$UI_MUTED` 计进截断长度即可(先截纯文本、再裹色)。

### 受限 TTY 回退 `_ui_pick_text`
- 多接一个可选 nameref 参数或直接读全局 `UI_PICK_DETAILS`:若有详情,编号行打成 `  n) label — detail`(best-effort,过长由终端自行处理)。
- 无 `/dev/tty` 的 headless:行为完全不变(本就静默 cancel)。

### `SIGWINCH` / 退出
- 沿用现有 `_UI_WINCH`/`ui_size` 与 `ui_begin/ui_end` 的 trap 还原,不新增生命周期。

## 二、`nvim.sh` · i18n 逐条说明

### 键命名(进 `NVIM_I18N`,沿用 `lang:key` 结构)
- 短说明:`<kind>_<name>`;完整说明:`<kind>_<name>_full`。`<name>` 里的 `.`/`-` 归一为 `_`(键名安全)。
  - colorscheme:`cs_tokyonight` / `cs_tokyonight_full` … `cs_rose_pine` …
  - font:`font_meslolgs` …(短即可,font 多为已知名;`_full` 可缺,fallback 短)
  - extras:`ex_lang_go` / `ex_lang_go_full` …
  - options:`opt_scrolloff` / `opt_scrolloff_full` …
  - autocmds(收编):`ac_trim_whitespace` / `ac_trim_whitespace_full` …
- 三语 `en:`/`zh:`/`ja:`;**条目名(tokyonight/lang.go/scrolloff…)不译**,只译描述词。

### 查询 helper
```sh
# _nvim_item_desc <kind> <name> [full]
#   full 缺省=短;full=1 取 *_full,缺则 fallback 短;再 fallback en→key(同 _nvim_t)
_nvim_item_desc() { … 经 _nvim_t 组装 "<kind>_<name>"[_full] … }
```
- `NVIM_AUTOCMD_DESC` 表**删除**,UI 处(1977 行 `${NVIM_AUTOCMD_DESC[$ac]}`)改为 `$(_nvim_item_desc ac "$ac")`(短)。

### 文案准确性来源(R7)
- options:逐个对 Neovim `:help <option>`(经 context7 `/neovim/neovim` 文档)核实语义后写白话。
- extras:对 LazyVim `:help lazyvim`/官方 extras 文档核实每个 `lang.*` 实际捆绑(LSP/formatter/dap 等)后写。
- colorscheme/font:风格/出处词,主观,无需查证(但 light/dark 既有 `NVIM_THEME_MODE` 不重复)。

## 三、`nvim.sh` · 各面落法

| 面 | 现状 | 改动 |
|---|---|---|
| 主 `ui()` extras 清单(1936-1939) | `$eb $ex` | `$eb $ex  ${UI_MUTED}短说明${UI_OFF}` |
| 主 `ui()` options 表(1952-1955) | `name  value` | 行尾补 `${UI_MUTED}短说明${UI_OFF}`。**注意**:该行已用 `4空格+15宽名+值`(~20 列),80 列下仅余 ~60 给说明,且 `ui_row` 不截断 → 短说明须 **≲40 字**,完整版靠 help/list-options 兜 |
| 主 `ui()` autocmds(1975-1978) | 已内嵌 `NVIM_AUTOCMD_DESC` | 改走 `_nvim_item_desc ac`(短),行为视觉不变 |
| colorscheme `ui_pick`(font 同) | label=name(+mode) | **与 `copts`/`fopts` 同循环锁步**填 `UI_PICK_DETAILS`(下标对齐),label 维持「name —(短)」。colorscheme 的尾部 `__custom__`/clear(`""`)两项 details 给空串或一句提示(否则详情错位) |
| 域 3 plugins header/info | 仅 `plugins_none` | 加常驻 info 行(模型解释,新 i18n 键 `plugins_model_note`) |
| 域 9 Mason header/info | 仅 `mason_none` | 加常驻 info 行(`mason_model_note`) |
| `usage()` Settings 段(2191-2207) | `curated: a, b, c` | 各 curated 行下补完整说明(多行;接受 help 变长——用户已同意) |
| `list-colorschemes/extras/options/autocmds` | 裸名 shortlist | `name — 完整说明`(`_nvim_item_desc … 1`)。**四个都改**(`do_list_colorschemes` 1357 / `do_list_options` 1587 / `do_list_autocmds` 1642 / `do_list_extras` 1797);font 无 `list-fonts`,其完整说明只在 picker 详情 + help |
| `meta()` desc(342) | run-on | 重排:`nvim + LazyVim combo manager — best-channel binary (apt/tarball/snap) + LazyVim config; full component config (theme/font/plugins/extras/leader/keymaps/options/autocmds/Mason)` 量级,要点前置一行 |

> 找 `list-colorschemes`/`list-extras`/`list-options` 现有实现函数名再精确定位(实现阶段 grep)。

## 四、兼容 / 风险

- **lib 广播面**:`ui_pick` 是 32 处调用的共享原语——详情行必须**纯增量、默认关**。验证须含一处**未用 details 的脚本**(go.sh/python.sh)picker 回归。
- **三档终端**:富 TTY(详情行)/ 受限 TTY(`_ui_pick_text` 附行)/ headless(不变)各自验证;伪终端冒烟 `timeout` 包裹(ui-smoke-test-hang 记忆)。
- **i18n 体量**:约 31 条 × (短+全) × 3 语 ≈ 上百串;`NVIM_I18N` 本就大,风格统一即可;ja best-effort。
- **行宽**:options 行已较满,短说明可能在窄终端被挤——短说明要够短(几个词),全文交详情行/help。
- **纯文案 + 渲染**:不触碰任何 install/configure/status 行为分支;`status` 退出码、`ops`、`KIT_PROBE_ONLY` 路径均不变。

## 五、不做

- 不改主 `ui()` 列表为"选中详情行"模式(只 `ui_pick` 加;主循环保持短句行内,符合 Q9)。
- 不重引 curated 插件清单;不改 plugins/Mason 自加模型。
- 不动其他脚本(除非 shellcheck 因 `UI_PICK_DETAILS` 未定义在某脚本报 SC2154——则在 `lib/ui.sh` 顶部 `declare -ga UI_PICK_DETAILS=()` 一次性声明即可,属 lib 内自洽)。
