# nvim curated 列表逐条说明文案

## Goal

让 `scripts/nvim.sh` 的**用户可见文案**更易懂——核心是给 curated 列表里**一个个具名条目**补上「是什么 + 何时用」的逐条说明(现在大多只列裸名字),并为承载选择器里的厚文案,给共享库 `lib/ui.sh` 的 `ui_pick` 加一个**向后兼容的「选中项详情行」**能力。受众是**人类用户**(不是 LLM),范围**只动用户可见文案 + 必要的 UI 渲染能力**,不碰代码注释、不碰外部文档、不动架构。

## Background / 现状(只读理解,勿凭记忆改)

`scripts/nvim.sh`(2229 行,nvim + LazyVim 组合管理器)的**具名条目列表**与说明现状:

| 域 | 列表 | 条目 | per-item 说明 |
|---|---|---|---|
| 1 | colorscheme | tokyonight / catppuccin / gruvbox / kanagawa / rose-pine / everforest | 仅 `dark/light` 模式标(`NVIM_THEME_MODE`),无"是什么/风格" |
| 2 | font | meslolgs / jetbrains-mono / firacode / hack | 无 |
| 3 | plugins | 用户自己 `add-plugin owner/repo`,**无 curated 清单** | 无清单可言 |
| 4 | extras | lang.python / lang.go / …(全 `lang.*`,共 10) | 无 |
| 7 | options | relativenumber / wrap / scrolloff / shiftwidth / tabstop / conceallevel / background / spell | 无(vim option 名最隐晦) |
| 8 | autocmds | trim_whitespace / disable_wrap_spell / disable_highlight_yank | ✅ 有 `NVIM_AUTOCMD_DESC`(**纯英文表、未进 i18n**) |
| 9 | Mason | 用户自己 `mason-add`,**无 curated 清单** | 无清单可言 |

关键事实:
- **只有 autocmds 有逐条说明**,且是个独立英文表(`declare -gA NVIM_AUTOCMD_DESC`),**和 tmux/rime 的三语本地化惯例不一致**。
- **真插件(域 3)与 Mason(域 9)在新架构里没有 curated 清单**——是用户按 `owner/repo` 自己加的(新架构故意砍掉了老的 treesitter/telescope/… curated 集,因 LazyVim 已捆绑核心插件)。
- `meta` 的 `desc`(342 行)是全 kit 统一的**一长行 run-on**,目录里会被截断。
- `ui_pick`(`lib/ui.sh`,colorscheme/font 选择器用)**只渲染每选项单行 label,无第二列、无详情行**;全 kit **32 处**调用它。
- 用户已在全局 CLAUDE.md 新增「**说大白话**:术语能不用就不用,必须用时紧跟一句通俗说明」——直接适用于本次文案。

## 已确认决策(经 grilling 逐条摸清;含一处对中途假设的反转)

1. **范围 = 用户可见文案**(非代码注释、非外部文档);受众 = 人类用户(非 LLM)。
2. **核心交付 = 给 curated 列表补逐条说明**,涉及 **colorscheme / font / extras / options** 四类,外加把 **autocmds** 一并纳入统一方案。
3. **i18n = 三语**(en/zh/ja)进 `NVIM_I18N`,**条目名不译**(对齐 tmux/rime 项目规范);顺手把现有英文 `NVIM_AUTOCMD_DESC` **收编进 `NVIM_I18N`**,消除风格不一致。
4. **深度 = 「是什么 + 何时用」**;术语跟一句白话(对齐新 CLAUDE.md「说大白话」)。
5. **两个文案层级**:UI 列表行内**只放短「是什么」**(放得下、对齐 autocmds);完整「是什么 + 何时用」进 **help 静态块 + `list-*` 命令 + 选择器详情行**。
6. **选择器厚文案(反转中途假设)**:`ui_pick` 装不下厚文案 → **扩 `lib/ui.sh` 给 `ui_pick` 加「选中项详情行」**(向后兼容,惠及全 kit picker),让 colorscheme/font 选择时能看到完整说明。
7. **plugins(域 3)/ Mason(域 9)**:无 curated 清单,不补逐条,改补**一句模型解释**——域 3「LazyVim 已自带核心插件(treesitter/telescope/gitsigns/…),这里按 owner/repo 加额外的」;域 9 加一句「Mason 是什么」。
8. **`list-*` 跟上**:`list-colorschemes` / `list-extras` / `list-options` 改成「name — 完整说明」,复用同一份 i18n 串(消除「help 详细但 list-* 裸名」的不对称)。
9. **`meta` desc 轻重排**:保持**一行**,把 combo / best-channel / LazyVim 提到最前(截断也看得出重点);**不碰其他脚本**的 desc。
10. **文案准确性是硬要求**(CLAUDE.md 铁律「能查证的事实别猜」):options(`scrolloff`/`conceallevel`/…)与 extras(各 `lang.*` 到底捆了啥)的说明**必须对着 Neovim/LazyVim 官方文档(context7)写**,不得凭记忆编。
11. **流程**:改 `lib/ui.sh` 与 `scripts/nvim.sh` 属代码改动 → **走 git worktree**;走完整 Trellis 流程(本任务)。

## Requirements

### R1 · `lib/ui.sh` · `ui_pick` 详情行(向后兼容)
- 新增可选全局数组 `UI_PICK_DETAILS`(与传入的 `id/label` 对**等长、按序对应**):调用方填了,`ui_pick` 在富 TTY 下于列表与 footer 之间渲染**当前高亮项**的详情(muted、按终端宽度截断);**未填则行为与现状完全一致**。
- 32 处现有调用**零改动**仍正常工作(不填 `UI_PICK_DETAILS` 即旧行为)。
- 受限 TTY 回退 `_ui_pick_text`:best-effort 把详情附在编号行(如 `n) label — detail`);无 `/dev/tty` 的 headless 行为不变。
- `ui_pick` 进入时**清空/重置** `UI_PICK_DETAILS` 的消费约定,避免跨调用串味(具体由 design 定:调用方填、ui_pick 用后不残留)。

### R2 · `nvim.sh` · 逐条说明的 i18n(三语,条目名不译)
- colorscheme(6)/ font(4)/ extras(10)/ options(8)/ autocmds(3)各条目,在 `NVIM_I18N` 里有**短说明**键 +(需要时)**完整说明**键,en/zh/ja 三语齐全;缺 ja 时 best-effort,fallback en。
- 提供一个查询 helper(如 `_nvim_item_desc <kind> <name> [full]`),完整缺失时 fallback 到短说明。
- 现有 `NVIM_AUTOCMD_DESC` 英文表**迁入** `NVIM_I18N` 并删除原表(或保留为兼容垫片,design 定);UI 渲染改走新 helper。

### R3 · `nvim.sh` · 短说明上 UI 列表行内
- extras / options / autocmds 的主 `ui()` 列表行**内嵌短说明**(灰字,对齐现有 autocmds 渲染);options 行现为 `name  value`,短说明落位由 design 定(同一行尾或紧随)。

### R4 · `nvim.sh` · 完整说明上 help + list-* + 选择器详情行
- `usage()` 的 Settings 段:curated 列表对应行补完整「是什么 + 何时用」。
- `list-colorschemes` / `list-extras` / `list-options` / **`list-autocmds`**(四个都改):改成「name — 完整说明」。font 无 `list-fonts`,完整说明只在 picker 详情 + help。
- colorscheme / font 的 `ui_pick` 调用:与 `copts`/`fopts` **同循环锁步**填 `UI_PICK_DETAILS`(下标对齐;colorscheme 尾部 `__custom__`/clear 两项 details 给空/提示),label 维持「name —(短)」。

### R5 · `nvim.sh` · plugins / Mason 模型解释
- 域 3 `ui()` 加一行灰字 info + `usage()` 加一句:LazyVim 已自带核心插件,这里按 owner/repo 加额外的。
- 域 9 同理加一句 Mason 是什么。
- 均三语进 `NVIM_I18N`。

### R6 · `nvim.sh` · meta desc 轻重排
- `meta()` 的 `desc=` 重排为一行、要点(combo / best-channel / LazyVim)前置;语义不变、不增删能力描述、不动其他脚本。

### R7 · 文案准确性
- options / extras 文案落笔前用 context7 查 Neovim / LazyVim 官方文档核实语义;colorscheme/font 给风格/出处词即可(主观,无需查证)。

## 非目标(明确排除)

- **不**重新引入 curated 插件清单(用户已否决)。
- **不**改 plugins/Mason 的"用户自加"模型本身,只补解释文案。
- **不**改其他脚本的 meta desc。
- **不**改 nvim.sh 的任何**行为/安装/配置逻辑**——纯文案 + UI 渲染能力。
- **不**给主 `ui()` 循环的列表加"选中项详情行"(Q9 已定 UI 列表只放短句;若要,留作后续)。

## Acceptance Criteria

- [ ] `bash -n` 过:`lib/ui.sh` `lib/common.sh` `lib/cache.sh` `bootstrap.sh` `swkit` 全部 `scripts/*.sh`。
- [ ] `shellcheck -x --source-path=SCRIPTDIR …` 零新增告警。
- [ ] `nvim.sh meta` 字段齐全、`ops` 与实现一致、`ops` 不含 `ui`;`desc` 已重排为要点前置的一行。
- [ ] `nvim.sh status` / `help` 可独立运行不炸;`help` 内 curated 列表带完整说明。
- [ ] `nvim.sh list-colorschemes|list-extras|list-options|list-autocmds` 输出「name — 完整说明」。
- [ ] `ui_pick` 详情行**自截断**不折行、无 ANSI 色彩残留(纯文本截断后再裹色);窄终端(<60 列)options 行内短说明不破版。
- [ ] `nvim.sh ui` 无 TTY 时打印指引退 0。
- [ ] 伪终端冒烟:`ui_pick` 详情行在富 TTY 下随高亮切换刷新、不崩、`q`/`esc` 干净退出、终端复原;**用 `timeout` 包裹**(见任务记忆 ui-smoke-test-hang)。
- [ ] 抽查另一处仍用旧式 `ui_pick`(无 `UI_PICK_DETAILS`)的脚本(如 `go.sh`/`python.sh`)picker 行为不变。
- [ ] colorscheme/font 选择器高亮某项时,详情行显示该项完整「是什么 + 何时用」。
- [ ] options/extras 文案与 Neovim/LazyVim 官方文档一致(实现时附查证来源)。
