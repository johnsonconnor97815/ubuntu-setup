# Design — nvim 受管配置层

> 全部新增代码落在 `scripts/nvim.sh`(单文件组件管理器,沿用现有结构)。复用现有 helper,不新增 lib 原语。所有标识符前缀 `_nvim_*` / `do_*`,沿用现状命名。

## 1. 总体架构

受管配置层是 `nvim.sh` 在"本体 + distro 安装器"之上的**第三层**。核心是一个**纯函数生成器** + **模式分发器**:

```
状态(nvim.conf KEY=VALUE)
   │  CFG_OPTIONS / CFG_KEYMAPS / CFG_LEADER / CFG_COLORSCHEME / CFG_PLUGINS / CFG_LSP …
   ▼
_nvim_cfg_gen_body()  ──生成 options/keymaps/colorscheme 的 lua 片段(纯 stdout,无副作用)
   │
   ├─ overlay 模式 →  写 ~/.config/<appname>/after/plugin/ubuntu-setup.lua
   │                   (options + keymaps〔无 leader〕+ colorscheme;无插件)
   │
   └─ takeover 模式 → 写 ~/.config/nvim/init.lua
                       (leader 早设 + options + keymaps + lazy bootstrap + 插件 spec + colorscheme)
                       + _nvim_sync 同步插件
```

**单一生成器、双写法**:options/keymaps/colorscheme 的 lua 由同一组 `_nvim_gen_*` 函数产出,overlay 与 takeover 只是把它们**组合进不同骨架**(after/plugin 文件 vs init.lua),避免逻辑双写。

## 2. 模式检测 `_nvim_cfg_mode <appname>`

判定某 appname 的受管配置该走 takeover 还是 overlay,**按优先级**(echo `takeover`/`overlay`,诊断走 stderr):

1. **nvim.conf 已记录** `MANAGED_MODE_<appname>` → 直接返回它(takeover 一旦确立就不因"目录现在非空"翻车;这是关键幂等护栏)。
2. **该 appname 是 kit 装的 distro**(`_nvim_manifest_has <appname>`)→ `overlay`(distro 拥有插件/init.lua,kit 只叠加)。
3. **配置目录 `~/.config/<appname>` 不存在 / 空**(复用 `do_install_distro` 的空判据:`! -d || -z "$(ls -A)"`)→ `takeover`。
4. **否则(用户自有非空配置)** → `overlay`。

- `--app <name>` 显式指定时,只允许 overlay(takeover 仅对默认 `nvim` 且目录空时自动成立;对隔离 appname 不做 takeover——它要么是 distro 要么是用户的)。规则:appname≠`nvim` ⇒ 强制 overlay。
- takeover 落地后写 `MANAGED_MODE_nvim=takeover` 进 nvim.conf;overlay 写 `MANAGED_MODE_<appname>=overlay`。复位 op 清除对应键。

## 3. 受管文件与 marker

| 文件 | 模式 | 归属判定 |
|---|---|---|
| `~/.config/<appname>/after/plugin/ubuntu-setup.lua` | overlay | 首行 `-- >>> ubuntu-setup nvim config (managed) >>>` marker |
| `~/.config/nvim/init.lua` | takeover | 首行同款 marker;**仅当首行是 kit marker 才整体重生成/复位**,否则视为用户文件→拒绝接管(回退报错指路) |
| `~/.config/ubuntu-setup/nvim.conf` | 两者 | 现有 KEY=VALUE store,新增 CFG_* 键 |

- 写前 `backup_file <目标>`(单文件;init.lua 也是单文件,`backup_file` 足够,takeover **首次**接管整目录另走 `_nvim_backup_dir`)。
- overlay 文件**整体重生成**(kit 全权拥有该文件;它在 after/plugin 顶层,是 kit 自有文件、不动 distro lua)。`mkdir -p` 其父目录 `after/plugin/`。
- takeover init.lua 整体重生成,但**写前检查首行 marker**:无 marker 且文件存在 ⇒ 用户自有 init.lua ⇒ 当作"非空用户配置",检测应已判 overlay;若强行 takeover(理论不可达)则 fail-fast 拒绝。

## 4. 状态 schema(nvim.conf 新增键)

```
MANAGED_MODE_<appname>=takeover|overlay      # 模式锁(模式检测优先级 1)
CFG_OPTIONS=on|off                            # options 基线开关(默认 off=不写)
CFG_KEYMAPS=on|off                            # keymaps 开关
CFG_LEADER=<single-char-or-space-token>       # leader,默认 space;校验
CFG_COLORSCHEME=<builtin-name>|""             # 空=不设
CFG_PLUGINS=<space-list>                      # 裸场景启用的 curated 插件键
CFG_LSP=on|off                                # 裸场景 LSP 组(lspconfig+mason+blink)
EXTRA_PLUGIN_<key>=<owner/repo|giturl>        # add-plugin 记录的任意插件
```

- 读用 `_nvim_conf_get`(缺键正常、返回空),写用 `_nvim_conf_set`。各组件**独立**,与现有 `CHANNEL`/`DEFAULT_EDITOR`/`EXTRA_DISTRO_*` 键并存,互不干扰。
- "受管配置层是否启用过"由"是否存在任一 `MANAGED_MODE_*` 键"判断——无则无参 `configure`/新机器零变化(满足验收)。

## 5. lua 生成器(纯函数,stdout)

### 5.1 `_nvim_gen_options` → options 片段
从 curated 表逐项 `vim.opt.<x> = <v>`。curated 基线(`CFG_OPTIONS=on` 时全量,best-practice、保守):
`number/relativenumber`、`expandtab/shiftwidth=2/tabstop=2/smartindent`、`ignorecase/smartcase`、`termguicolors`、`scrolloff=4`、`signcolumn=yes`、`undofile`、`mouse=a`、`cursorline`、`clipboard=unnamedplus`(系统剪贴板;SSH/OSC52 由终端处理)、`splitright/splitbelow`、`wrap=false`。
> 首版把 options 作**一个开关**(on=写全量基线),不逐项 flag——降复杂度;逐项可后续迭代(nvim.conf 已可扩展)。

### 5.2 `_nvim_gen_keymaps` → keymaps 片段
curated QoL 键(`vim.keymap.set`):`<leader>w`=保存、`<leader>q`=关窗、`<Esc>`=清搜索高亮(`:nohlsearch`)、`<C-h/j/k/l>`=窗格切换、`<S-h>/<S-l>`=buffer 前后、`<leader>e`=`:Explore`。**不**与常见 distro 重度冲突的子集。

### 5.3 leader(仅 takeover)
takeover init.lua 顶部:`vim.g.mapleader = "<CFG_LEADER>"`、`vim.g.maplocalleader = "\\"`,在 lazy bootstrap 之前。overlay 文件**不**含 leader。

### 5.4 `_nvim_gen_colorscheme` → colorscheme 片段
`pcall(vim.cmd.colorscheme, "<name>")`(pcall 防主题不存在时报错中断)。仅当 `CFG_COLORSCHEME` 非空。

### 5.5 `_nvim_gen_plugin_spec`(仅 takeover)→ lazy spec 片段
从 `CFG_PLUGINS` + `CFG_LSP` + `EXTRA_PLUGIN_*` 映射到 lazy plugin spec 字符串。curated 键 → 仓库 + 最小 `opts`/`config`:

| key | repo | 备注 |
|---|---|---|
| treesitter | nvim-treesitter/nvim-treesitter | `build=":TSUpdate"`、ensure 基础 parser |
| telescope | nvim-telescope/telescope.nvim | dep `nvim-lua/plenary.nvim` |
| gitsigns | lewis6991/gitsigns.nvim | `opts={}` |
| which-key | folke/which-key.nvim | `opts={}` |
| lualine | nvim-lualine/lualine.nvim | `opts={}`(图标需 Nerd Font,deps 已装) |
| (LSP 组,CFG_LSP=on) | mason-org/mason.nvim + mason-org/mason-lspconfig.nvim(dep lspconfig+mason)+ neovim/nvim-lspconfig + saghen/blink.cmp | **已查证**(2025/nvim0.11+):mason 已迁 `mason-org/`;mason-lspconfig 经 lazy deps 自动 `vim.lsp.enable()` 已装 server、无需手动 setup;blink `version="1.*"` opts 留默认;server 由用户在 `:Mason` 装 |

- `EXTRA_PLUGIN_<key>` → `{ "<owner/repo>" }` 裸 spec(无 opts;用户自担配置)。
- spec 片段拼进 `require("lazy").setup({ spec = { <这里> }, install = { colorscheme = { "<CFG_COLORSCHEME or habamax>" } }, })`。

## 6. init.lua 骨架(takeover)

```lua
-- >>> ubuntu-setup nvim config (managed) >>>
-- 本文件由 swkit nvim 生成,会被整体重写;自定义请放到 ~/.config/nvim/lua/ 下并在末尾 require。
vim.g.mapleader = " "
vim.g.maplocalleader = "\\"
<options 片段>          -- 早于插件,影响一致
<keymaps 片段>
-- bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local out = vim.fn.system({ "git","clone","--filter=blob:none","--branch=stable",
    "https://github.com/folke/lazy.nvim.git", lazypath })
  if vim.v.shell_error ~= 0 then error("clone lazy.nvim failed:\n"..out) end
end
vim.opt.rtp:prepend(lazypath)
require("lazy").setup({
  spec = { <plugin spec 片段> },
  install = { colorscheme = { "<colorscheme or habamax>" } },
  checker = { enabled = false },
})
<colorscheme 片段>      -- setup 之后再 pcall colorscheme(确保主题插件/内置可用)
-- <<< ubuntu-setup nvim config (managed) <<<
```

## 7. after/plugin 骨架(overlay)

```lua
-- >>> ubuntu-setup nvim config (managed) >>>
-- 由 swkit nvim 生成;在所有插件/distro 之后执行(after/plugin),覆盖其 options/colorscheme。
<options 片段>
<keymaps 片段>          -- best-effort:可能被 distro 懒加载键覆盖
<colorscheme 片段>
-- <<< ubuntu-setup nvim config (managed) <<<
```

## 8. op / configure / ui 表面

### 8.1 新增带参 op(经 `kit_dispatch` 路由 `do_<x>`,**不进 `meta.ops`**)
- `config-apply [--app <name>]` — 据状态重生成受管文件(overlay 或 takeover);**幂等核心**,所有改状态的 op 末尾都调它。
- `config-reset [--app <name>]` — 移除该 appname 的受管文件 + 清 `MANAGED_MODE_*`(takeover 走目录级备份 + 删 kit init.lua;overlay 删 after/plugin 文件)。
- `set-leader <char>` / `set-colorscheme <name|"">` / `set-options on|off` / `set-keymaps on|off`(各自写 conf 后调 config-apply)。
- `add-plugin <key|owner/repo|giturl>` / `remove-plugin <key>`(仅 takeover;有 distro/overlay 时拒绝指路)。
- `enable-lsp on|off`(仅 takeover)。
> 命名注意:现有 `update-plugins`/`sync-plugins`/`clean-plugins` 是 distro lazy 驱动,语义不同;新插件管理用 `add-plugin`/`remove-plugin`(裸场景受管 spec 的增删),与之并存且文档/usage 写清区别。

### 8.2 `configure` 新 flag(layer-on,沿用现有 while-case)
- `--config-recommended` — 受管配置层一键:options on + keymaps on + 一个内置 colorscheme +(若 takeover)装 curated 插件 + LSP。**独立于** `--recommended`(后者装 LazyVim,不动)。
- `--options on|off` / `--keymaps on|off` / `--leader <c>` / `--colorscheme <n>` / `--cfg-plugins "<list>"` / `--lsp on|off` / `--app <name>`。
- **无参 `configure` 不变**(仅确保本体)。

### 8.3 `meta.ops`
维持 `install,remove,configure,update,update-plugins`(新无参动作如需要可加 `config-apply`?——**不加**:它是带参/内部用,保持 ops 稳定)。新带参 op 全部经 kit_dispatch、不进 ops(契约要求)。

### 8.4 `ui()` 新增分组
在现有 Distros / Plugins(distro)/ Ext deps / Editor 之上,新增 **"Managed config"** 区(仅 installed 时显示),按当前默认 nvim 的模式渲染:
- 模式横幅:`takeover`(裸 nvim)/`overlay (distro: <name>)`。
- Options 开关、Keymaps 开关、Leader 输入、Colorscheme 选择器(内置主题列表)。
- 仅 takeover 时多出 Plugins 勾选区(curated + `a` 加任意 + LSP 开关)。
- "Apply recommended config"(= `--config-recommended`)、"Reset managed config"(二次确认)。
- 读走 conf/fs,改走 `ui_run -- "$0" <op>`,返回后重载。

## 9. 校验 / 安全

- `_nvim_leader_valid`:单字符或 `space`/`,`/`\` 等已知安全 token;拒绝含 `"` `\`(裸)`$` 反引号等会在 lua 字符串注入的字符(leader 以 `vim.g.mapleader = "<x>"` 写入,空格写成 `" "`)。
- `_nvim_colorscheme_valid`:`^[A-Za-z0-9_-]+$`;可选 best-effort 校验在不在 `nvim +"echo getcompletion('','color')"`(沿用"宽松校验"思路,失败仅 warn 不挡)。
- 插件 key:curated 走表;任意 `owner/repo` 校验 `^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`,git-url 复用 `_nvim_giturl_valid`。
- appname 复用 `_nvim_name_valid` + `_nvim_path_under_config` 护栏(写/删 after/plugin 与 init.lua 前都过路径护栏)。
- 全程 `_nvim_resolve_home`(拒绝 sudo 包裹);**无任何 sudo**;**无 Node 自动安装**(LSP 组装好后,`enable-lsp`/UI 检测 `have_cmd node` 缺失则横幅指路 `swkit node install`,不挡)。
- 幂等:config-apply 可反复跑;backup 在每次重写前;reset 保留备份。

## 10. 取舍 / 风险

- **options 首版做单一开关而非逐项 flag**:降复杂度、快落地;逐项是后续迭代(状态已可扩展)。tmux.sh 逐项是因其 options 多且强需独立;nvim 基线作为一组更自然。
- **overlay keymaps best-effort**:distro 懒加载键可能盖过 kit;诚实文档化,不强行 hook VeryLazy(那会接近"改写 distro 行为")。
- **takeover 一旦确立用 conf 锁**:避免"接管后目录非空 → 误判 overlay"。代价:用户手删 conf 锁会回退启发式——可接受(reset op 是正规出口)。
- **不逐 distro 适配**:只用通用 after/plugin;个别 distro(如严格自管的)overlay 的 colorscheme 可能被其 autocmd 再次覆盖——属已知边界,文档说明,用户可改用其 distro 原生方式。
- **blink.cmp 预编译下载**:首次插件同步需网络拉预编译二进制;离线则 lua 回退(已查证),不引入 cargo。

## 11. 不做(本任务边界)

见 prd.md「Out of scope」。强调:不改本体渠道/版本闸、不解析 distro lua、不 per-project、不自动 Node、不动现有 `--recommended`。
