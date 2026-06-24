# nvim 受管配置层(组件管理器)

## Goal

给 `scripts/nvim.sh` 增加一个**受管配置层**:让用户(经 swkit / TUI / LLM)按组件管理 Neovim 的**实际配置**——编辑器 options、keymaps(含 leader)、内置 colorscheme,以及(仅裸 nvim 场景)curated 插件含 LSP——对标 `tmux.sh` / `ghostty.sh` / `rime.sh` 的组件管理器范式。现状的 `nvim.sh` 只能整套安装第三方 distro(LazyVim 等)、**从不碰 distro 的 lua**,缺一层"管理配置本身"的能力,本任务即填这个空。

## Background / 现状(只读,勿改动既有行为)

`nvim.sh` 已有:本体安装(apt/tarball/snap + 版本闸 `NVIM_MIN_VERSION=0.11.2`)、distro 安装器(curated lazyvim/kickstart/astronvim/nvchad + `add-distro`,经 `NVIM_APPNAME` 隔离 + manifest)、lazy.nvim headless 插件同步、外部依赖、`set-default-editor`。已有可复用基础设施:`_nvim_resolve_home`(认 `SUDO_USER`、拒绝 sudo 包裹)、`_NV_CFG/_NV_DATA/_NV_STATE/_NV_CACHE`、`_nvim_conf_get/set`(`~/.config/ubuntu-setup/nvim.conf` 的 KEY=VALUE store)、`_nvim_rc_file`、marker+`backup_file`+`grep -qxF` 受管行范式、`_nvim_path_under_config` 路径护栏、`_nvim_backup_dir`、`_nvim_name_valid`/`_nvim_giturl_valid`、`_nvim_installed_ok` 版本闸、`_nvim_sync` lazy 驱动、distro manifest、`ui()` 并行数组渲染。

## 已确认决策(经 grilling 摸清)

1. **定位**:受管配置层 / 组件管理器,对标 tmux/ghostty/rime。
2. **生效场景**:**裸 nvim + 与 distro 共存**两者都要,经 Neovim 原生 `~/.config/<appname>/after/plugin/ubuntu-setup.lua` 自动 source(已查证:lazy.nvim/LazyVim 下也被可靠 source、最后执行,见 `research/after-plugin-load-order.md`)。
3. **管理类别**:① 编辑器 options 基线 ② keymaps(含 leader)③ 内置 colorscheme ④ 插件管理。
4. **插件范围**:**仅裸 nvim** 管插件;有 distro 时只 overlay options/keymaps/colorscheme,插件交给 distro。
5. **接管判定**:复用 distro 智能默认——配置目录空/不存在 → kit 全接管(生成 init.lua + bootstrap lazy + curated 插件 + 早设 leader + options + keymaps + colorscheme);非空(已有 distro 或用户配置)→ after/plugin 叠加(只 options + keymaps〔不含 leader〕+ colorscheme,无插件)。
6. **appname 目标**:默认 `nvim`;另有 `--app <name>` 把 overlay 叠加到隔离的 distro(如 `nvim-lazyvim`)。
7. **裸场景插件集**:类 kickstart,**含 LSP**——curated essentials + nvim-lspconfig + Mason(`mason.nvim`+`mason-lspconfig`)+ **blink.cmp** 补全。Mason 本身不需 Node;用它装 Node 系 server 时提示 `swkit node install`。
8. **与现有 `--recommended` 关系**:**互不改动**。`configure --recommended`(装 LazyVim)维持现状;受管配置层走自己独立的新入口(新 op / 新 flag)。装了 distro 的人,受管层自动走 overlay。

## Requirements

### R1 受管配置层 · overlay(两场景通用)
- 经整体重生成受管文件 `~/.config/<appname>/after/plugin/ubuntu-setup.lua` 写入 options / keymaps(overlay 下不含 leader)/ colorscheme;改前对该文件 `backup_file`,保留用户在别处的内容,文件首行带 kit marker。
- 默认 appname=`nvim`;`--app <name>` 指定隔离 distro 的 appname(经 `_nvim_name_valid` 校验)。
- overlay 不管插件;colorscheme 仅限 nvim 内置主题(经合法性校验)。

### R2 受管配置层 · 裸 nvim 全接管
- 仅当配置目录空/不存在(或已被 kit takeover 标记)时:生成受管 `init.lua`(早设 leader → options → keymaps → bootstrap lazy.nvim → `require("lazy").setup` 加载 curated 插件 spec → colorscheme),整体重生成。
- takeover 前若目录非空走 `_nvim_backup_dir` 目录级备份;takeover 状态记入 nvim.conf,后续重跑识别为 takeover、不误判成 overlay。
- 插件经现有 `_nvim_sync` headless 同步。

### R3 组件:editor options 基线
- curated 最佳实践 options(行号、缩进、搜索、系统剪贴板、termguicolors、scrolloff、signcolumn、undofile、mouse、cursorline 等),可独立开关;状态存 nvim.conf。

### R4 组件:keymaps(含 leader)
- leader(默认 `空格`,可配)+ curated 便捷键(保存、窗口/缓冲切换、清搜索高亮等),可开关。
- **leader 仅 takeover 生效**(overlay 让给 distro);overlay 的 keymaps 标注 best-effort(可能被 distro 懒加载键覆盖)。

### R5 组件:内置 colorscheme
- 仅 nvim 自带主题(habamax/retrobox/slate/…),经 `nvim +colorscheme` 类校验或白名单;有 distro 时 overlay 会覆盖 distro 主题——诚实提示。

### R6 组件:插件(仅裸 nvim)
- curated 集:lazy.nvim(bootstrap)+ treesitter + telescope(+plenary)+ gitsigns + which-key + lualine + LSP 组(nvim-lspconfig + mason + mason-lspconfig + blink.cmp)。
- 各插件/LSP 组可独立增删;`add-plugin <owner/repo|git-url>` 加任意;状态存 nvim.conf;改动后重生成 init.lua spec + headless 同步。
- 有 distro 时插件相关 op **拒绝执行**并诚实指路(插件交 distro)。

### R7 op / configure / ui 接口(对标 tmux.sh)
- `meta.ops` 维持现有 + 至多新增能进 ops 的无参动作;带参 op 经 `kit_dispatch` 路由 `do_<x>`、**不进 `meta.ops`**、且在 `ui()` 交互可达。
- `configure` 新增对应 flag;**无参 `configure` 维持现状**(仅确保本体在,新机器零变化);受管配置层为 opt-in。
- `ui()` 新增受管配置分组(options / keymaps / colorscheme /(裸场景)plugins),读走 fs/conf、改走 `ui_run -- "$0" <op>`。
- 说明文案 en/zh/ja 本地化(`NVIM_I18N`,插件/主题/键名不译)。

### R8 移除 / 复位
- 提供复位 op:overlay 删 kit 受管的 after/plugin 文件(保留备份与用户内容);takeover 复位删 kit 受管 init.lua/相关产物(目录级备份后),保留用户数据;按现有 `remove-distro` 的护栏纪律。

## Constraints(项目不可妥协项,全程贯彻)

- **全程用户态**,经 `_nvim_resolve_home` 认 `SUDO_USER`、`EUID==0 && SUDO_USER` 拒绝;配置层**绝不 sudo**(仅本体 apt/tarball 经 `sudo_run` 逐命令提权,本任务不碰本体渠道)。
- **绝不自动装 Node**(Mason 的 Node 系 server 缺 Node 时指路 `swkit node install`)、**绝不 `sudo npm`**。
- **幂等**:重跑安全;改文件前 `backup_file`;受管文件整体重生成、保留用户内容;**不碰 distro 的 lua**(只往其 after/plugin 顶层加 kit 自有文件)。
- **fail-fast 无回滚**:headless 严格 fail-fast;UI 每个变更经 `ui_run` 子进程、失败不杀循环。
- name/appname/git-url/colorscheme/leader 等输入正则校验,挡注入。
- **不改动现有行为**:本体安装/distro/`--recommended`/`set-default-editor`/`update-plugins` 等保持原样。
- 文档漂移:落地后须同步根 `CLAUDE.md` 的 nvim 段、`skills/ubuntu-install/SKILL.md`(若涉及)。

## Acceptance Criteria

- [ ] `bash -n scripts/nvim.sh` 通过;`shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh` 零告警。
- [ ] `nvim.sh meta` 字段齐全,`ops` 与实现一致且**不含 `ui`**;新带参 op **不在** `ops` 里。
- [ ] `nvim.sh status` 可独立运行;`KIT_PROBE_ONLY` 早返与完整路径退出码一致(沿用现状,不退化)。
- [ ] `nvim.sh help` 不炸且覆盖新 op/flag;`nvim.sh ui` 无 TTY 下打印指引退 0。
- [ ] 伪终端冒烟:`printf 'q' | TERM=xterm-256color script -qec 'scripts/nvim.sh ui' /dev/null` 渲染不崩、`q` 干净退出、终端复原(必要时 `timeout` 包裹)。
- [ ] 无参 `configure` 在新机器零变化(不写任何受管配置文件)。
- [ ] **真机端到端(免密 sudo 下代跑,破坏性 op 先征同意)**:
  - [ ] 裸 nvim(空 `~/.config/nvim`):takeover 生成 init.lua,`nvim --headless +q` 无报错启动,curated 插件经 lazy 同步成功,options/colorscheme 生效。
  - [ ] 有 distro(已装 LazyVim):overlay 写 after/plugin,`nvim --headless +q` 无报错,kit options/colorscheme 覆盖生效,**LazyVim 的 lua 未被改动**,插件 op 被拒绝并指路。
  - [ ] 复位 op 干净移除 kit 受管文件、保留用户/distro 内容与备份。
- [ ] 根 `CLAUDE.md` nvim 段已同步描述受管配置层。

## Out of scope / 非目标

- 不改 nvim **本体**安装渠道与版本闸逻辑。
- 不在有 distro 时管理插件(交 distro);不写 distro 专属扩展点适配(只用通用 after/plugin)。
- 不自动装 Node;不解析/改写 distro 的 lua。
- 不做 per-project 配置(`.nvim.lua`/exrc 等);只管机器级用户配置。
- 不引入 cargo/Rust 工具链(blink.cmp 留默认预编译下载 + lua 回退)。
