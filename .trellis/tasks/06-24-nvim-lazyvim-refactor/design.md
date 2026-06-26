# 技术设计 — nvim+LazyVim 组合管理器重构

## 架构总览(单一基座,无双模式)

LazyVim 永远是基座 → **删除** takeover/overlay 双模式与 `_nvim_cfg_mode`。所有设置统一「往 LazyVim 官方文件叠加」,只有**一种**叠加模式。脚本结构:

```
二进制层(沿用)         install/remove/update/status，apt→tarball→snap，闸 0.11.2
   │
LazyVim 落地层(重写)   install 四分支 + 归属标记(cloned/adopted)
   │
设置层(9 域，re-home)  写入 LazyVim 官方扩展点的 5 个产物
```

## kit 的写入面(5 个产物，各自幂等重生成 + 可干净卸载)

| 产物 | 归属方式 | 承载域 |
|---|---|---|
| `~/.config/nvim/lua/plugins/ubuntu-setup.lua` | **kit 整文件**(首行 `-- >>> ubuntu-setup nvim plugins (managed) >>>`) | 主题(域1)+ 插件(域3)+ Mason spec(域9) |
| `~/.config/nvim/lua/config/options.lua` | **managed block** | leader(域5)+ options(域7) |
| `~/.config/nvim/lua/config/keymaps.lua` | **managed block** | keymaps(域6) |
| `~/.config/nvim/lua/config/autocmds.lua` | **managed block** | autocmds(域8) |
| `~/.config/nvim/lazyvim.json` | **headless `LazyVim.json.save()` 逐条合并** | extras(域4) |
| (`fonts.sh` 自管 `fonts.conf`) | 委托 `fonts.sh` | 字体(域2) |
| `~/.config/nvim/.ubuntu-setup-lazyvim` | 归属标记(`source=cloned|adopted`) | install/remove 判定 |
| `~/.config/ubuntu-setup/nvim.conf` | KEY=VALUE(沿用) | 所有域的状态镜像(供 status/ui/重生成) |

> 一个 `lua/plugins/ubuntu-setup.lua` 同时承载主题 + 插件 + Mason —— 它是纯函数整体重生成(从 nvim.conf 状态算出),三者拼进同一个 `return { ... }`。

## 二进制层(沿用现有,几乎不改)

`do_install`(二进制部分)/`do_remove`/`do_update`/`_nvim_install_tarball`/版本 helper 全部保留。唯一变化:`status` 的「已装」语义从「nvim 在」改成「**组合在**」(见下)。

## LazyVim 落地层 · install 四分支(数据流)

```
do_install:
  ensure 二进制(apt/tarball/snap，闸 0.11.2)
  _nvim_ensure_deps         # 域依赖 + Nerd Font
  _lazyvim_land:            # 四分支
    marker 在 & source=cloned/adopted → 幂等(仅 _nvim_sync)
    ~/.config/nvim 空/不存在          → git clone starter; rm -rf .git; 写 marker source=cloned
    无 marker & grep -rl 'LazyVim/LazyVim' lua/ 命中 → adopt: 写 marker source=adopted（不 clone、不动文件）
    无 marker & 非 LazyVim            → _nvim_backup_dir 四处(config+share+state+cache); clone; rm .git; marker cloned
                                          （headless 直接执行 + log_warn；ui_confirm 二次确认）
  _nvim_sync nvim sync       # :Lazy! sync
  log: 运行 :LazyHealth 检查
```

- clone 源:`https://github.com/LazyVim/starter`。
- 检测「是 LazyVim?」:`grep -rlq 'LazyVim/LazyVim' ~/.config/nvim/lua 2>/dev/null`(starter 的 `lua/config/lazy.lua` 必有此引用)。失败时偏向 adopt(保留),不轻易走破坏性替换。
- `_nvim_backup_dir` 扩展为备份四处(现仅备份单目录),按 LazyVim 官方安装指引。
- 归属标记复用 `backup_file`+marker 范式;`remove` 读 `source` 决定是否删配置(R4)。

## 设置层实现(9 域)

### 共用:`lua/plugins/ubuntu-setup.lua` 纯函数生成器(域 1/3/9)

`_nvim_render_plugins_file()` → stdout,从 nvim.conf 读 `CFG_COLORSCHEME`/`PLUGINS`/`DISABLED_PLUGINS`/`EXTRA_PLUGIN_*`/`MASON_TOOLS` 拼出:

```lua
-- >>> ubuntu-setup nvim plugins (managed) >>>  (首行 marker)
return {
  -- 域1 主题(非内置才加插件行)
  { "ellisonleao/gruvbox.nvim" },
  { "LazyVim/LazyVim", opts = { colorscheme = "gruvbox" } },
  -- 域3 插件
  { "tpope/vim-fugitive" },
  { "folke/flash.nvim", enabled = false },        -- disable-plugin
  -- 域9 Mason
  { "mason-org/mason.nvim", opts = { ensure_installed = { "stylua", "shfmt" } } },
}
```

写入:`_nvim_path_under_config` 护栏 → 非 kit 文件(首行非 marker)拒写 → `backup_file` → 原子 `mv` → `_nvim_sync`。

### 受管块:`lua/config/{options,keymaps,autocmds}.lua`(域 5/6/7/8,`tmux.sh` 范式)

每文件一个 `_nvim_*_block()` 生成器 → 整体重生成标记块,保留块外用户内容:

```lua
-- >>> ubuntu-setup nvim (managed) >>>
vim.g.mapleader = " "          -- 域5 leader（options.lua）
vim.g.maplocalleader = "\\"
vim.opt.relativenumber = false -- 域7 options
vim.g.autoformat = false       -- 域7 format-on-save
-- <<< ubuntu-setup nvim (managed) <<<
```

- 投递正确性(已查实):`lua/config/options.lua` 在 `lazy.setup` **之前**加载 → leader 赶在 keymap 映射前生效;options/keymaps/autocmds 用户文件在 LazyVim 默认**之后**加载 → 覆盖生效;**只能覆盖不能禁用**(issue #566)。
- keymaps:`vim.keymap.set("<mode>","<lhs>","<rhs>",{desc="..."})`;mode/lhs/rhs 校验挡注入。
- autocmds:curated 项(trim 尾空白等)+ `vim.api.nvim_del_augroup_by_name("lazyvim_<x>")` 禁用默认。

### extras(域4)· headless 驱动 LazyVim 自己的 json API —— **关键机制**

不用 jq 直改 `lazyvim.json`(避开 version/缺文件/migrate 脆弱)。改为 headless 让 LazyVim 自己读改存:

```bash
nvim --headless +'lua
  local Config = require("lazyvim.config")
  local extras = Config.json.data.extras or {}
  local m = "lazyvim.plugins.extras.lang.go"          -- <cat.name> 拼成全模块名
  extras = vim.tbl_filter(function(x) return x ~= m end, extras)
  if ADD then table.insert(extras, m) end             -- add 才插回
  table.sort(extras)
  Config.json.data.extras = extras
  (LazyVim.json or require("lazyvim.util.json")).save()
' +qa
```

- LazyVim 负责创建文件 / 维护 `version`/`install_version`/`news` / 迁移 —— 这正是「官方非交互等价物」。
- 保留用户经 `:LazyExtras` 加的其它条目(只动当次点名的 `m`)。
- save 后跑 `_nvim_sync nvim sync` 装新 extra 的插件 + 提示重启。
- **实现期须真机核对**:`LazyVim` 全局 / `require("lazyvim.util.json").save` 的确切模块路径与「headless 启动后 json 模块已加载」的时序(源码 `util/extras.lua` 用 `LazyVim.json.save()`、`LazyVim.config.json.data.extras`)。

### 字体(域2)· 委托 `fonts.sh`

`ui()` 的 Font 行 → `ui_run -- "$KIT_SCRIPTS_DIR/fonts.sh" install <name>` / `apply <name> <size>`。nvim.sh 不另存字体状态(读 fonts.sh 的 `fonts.conf`)。SSH/TUI 诚实提示沿用 `fonts.sh`。

## 对现有 `scripts/nvim.sh` 的复用 / 删除 / 新增清单

**复用(保留)**:整个二进制层 + `_nvim_install_tarball` + 版本 helper;`_nvim_resolve_home`/`_NV_*`/`_nvim_conf_*`/`_nvim_rc_file`;`backup_file`+marker 范式;`_nvim_path_under_config`/`_nvim_backup_dir`(扩四处);`_nvim_sync`;`_nvim_leader_valid`/`_nvim_colorscheme_valid`;`set-default-editor` 全套;`_nvim_ensure_deps`(扩 deps 集);i18n `NVIM_I18N`/`_nvim_t`;`ui()` 渲染骨架。

**删除**:`NVIM_DISTRO_REPO`/`NVIM_DISTRO_ORDER`/`do_install_distro`/`do_remove_distro`/`do_add_distro`/`_nvim_distro_*`/manifest 全套/`_nvim_alias_*`;`_nvim_cfg_mode`/takeover/overlay 渲染(`_nvim_render_overlay`/`_nvim_render_takeover`/`_nvim_apply_*`/`do_config_apply`/`do_config_reset` 改写)/`NVIM_APPNAME` 概念;`after/plugin` 投递。

**新增**:`_lazyvim_land`(四分支)+ 归属标记读写;`_nvim_render_plugins_file`(域1/3/9 合一);`_nvim_render_block`(域5/6/7/8 三文件参数化)+ 各生成器;extras headless save(域4);`mason-add/remove`、`disable/enable-plugin`、`add-keymap/remove-keymap`、`set-option/unset-option`、`add-autocmd/remove-autocmd`、`extra-add/remove`、`list-*` 等 op;`status` 组合语义 + `KIT_PROBE_ONLY` 标记 stat。

## op 路由 / status / ui

- `kit_dispatch` 路由 `do_<x>`(连字符转下划线)沿用;`meta.ops=install,remove,configure,update,update-plugins`;其余带参 op 不进 ops。
- `status`:`have_cmd nvim && [[ -f ~/.config/nvim/.ubuntu-setup-lazyvim || grep -rlq LazyVim/LazyVim ~/.config/nvim/lua ]]`;`KIT_PROBE_ONLY` 时只 stat 标记文件、不 spawn nvim、不 grep,早返布尔,两路径退出码一致。
- `ui()`:9 域分组(Neovim 本体 / 主题 / 字体 / 插件 / extras / leader+keymaps+options+autocmds / Mason / Apply recommended / Remove),读 fs+nvim.conf、改走 `ui_run -- "$0" <op>`。

## 决策 & 反转日志(可追溯到 grilling)

1. LazyVim 唯一基座、删多 distro/隔离/双模式 —— 锁定。
2. 撞配置四分支 + `source=cloned/adopted` + 无 force + 备份四处 —— 锁定。
3. **反转**:grilling 中途「不碰 `lua/config/*`」→ 改为 managed block(`tmux.sh` 范式),因 leader/keymaps/options/autocmds 的官方落点就是 `lua/config/*`,且块范式是项目既有、被接受的做法。
4. install = 整套组合(用户定)/ 默认零 extras —— 锁定。
5. **反转**:grilling 中途「砍掉 add-plugin」→ 插件管理重新纳入 + disable-plugin(G1)。
6. extras 用 `lazyvim.json` + **headless save**(非 jq)—— 自审 A3 改正。
7. 补 G1(disable-plugin)/G4(autocmds)/G2(mason);G3(透明)等记为非目标。

## 风险 & 诚实边界

- **extras headless save 的 API 路径/时序**:依赖 LazyVim 内部 `LazyVim.json.save()` 与 headless 启动时序 —— **实现期真机端到端验证**,失败则退回「读现有 `lazyvim.json` 时 jq 逐条合并、仅处理文件已存在的情形」备选。
- **tarball GitHub API 解析 + sha256**:沿用现有(已被验证过的 awk 状态机),仍需真机重跑一次。
- **adopt 检测启发式**(grep `LazyVim/LazyVim`):极少数手写配置可能漏判 → 偏向保留(adopt)而非破坏性替换。
- **行数膨胀**:~1500–1800 行(非精简),复杂度集中在 9 域生成器 —— 用纯函数生成器 + 参数化块降重。
- **真机依赖**:外部渠道(tarball/lazyvim.json/fonts.sh 联动/Mason)静态检查覆盖不到,**必须真机端到端各跑一次**(免密 sudo 下可代跑,破坏性 op 先征同意)。

## 验证策略

1. 静态:`bash -n` + `shellcheck -x --source-path=SCRIPTDIR`。
2. 契约:`meta`(ops 一致、不含 ui)/`status`(组合语义、两路径退出码一致)/`help`/`ui`(无 TTY 退 0)。
3. 隔离单测:lua 生成器纯函数 → stdout 比对;受管块保留块外内容;lazyvim.json 合并保留用户条目。
4. 真机端到端(免密 sudo):干净环境 `install` → 四分支 → 9 域逐个 set/unset → `nvim --headless +checkhealth`/启动无 error;破坏性分支(非 LazyVim 替换、`--purge`)先征同意。
5. 伪终端冒烟:`printf q | TERM=xterm-256color script -qec '... ui' /dev/null` 不崩、`q` 退出、终端复原。
