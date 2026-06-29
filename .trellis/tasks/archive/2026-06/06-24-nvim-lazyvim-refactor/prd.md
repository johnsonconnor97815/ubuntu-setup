# nvim+LazyVim 组合管理器重构

## Goal

把 `scripts/nvim.sh` 从「通用多 distro Neovim 管理器」**重构**为「**nvim + LazyVim 组合管理器**」:固定基座 = nvim 二进制 + LazyVim 配置,在其上提供一套**完整的、走 LazyVim 官方扩展点的配置管理**(主题 / 字体 / 插件 / 语言功能包 / leader / keymaps / options / autocmds / Mason 工具),对标 `tmux.sh` / `ghostty.sh` / `rime.sh` 的组件管理器范式。

## Background / 现状(只读理解,勿凭记忆改)

当前 `scripts/nvim.sh`(1556 行)是三层结构:
1. **二进制层**:apt(候选 ≥ `NVIM_MIN_VERSION=0.11.2`)→ 官方 stable tarball(GitHub API 解析 + sha256 校验,装 `/opt` + symlink)→ snap;`do_install`/`do_remove`/`do_update`/`status`。
2. **distro 安装器**:curated `lazyvim`/`kickstart`/`astronvim`/`nvchad` + `add-distro` 任意 git distro,经 `NVIM_APPNAME` 隔离(空 `~/.config/nvim` 接管,否则 `nvim-<name>` + shell alias），manifest 记录、headless `:Lazy sync`。
3. **受管配置层**(由前身任务 `06-23-nvim-managed-config` 引入):takeover(kit 自有 init.lua + curated 插件 + LSP)/ overlay(`after/plugin/ubuntu-setup.lua`)双模式,管 options/keymaps/leader/colorscheme/插件。

可复用基础设施(保留):`_nvim_resolve_home`(认 `SUDO_USER`、拒 sudo 包裹)、`_NV_CFG/_NV_DATA/_NV_STATE/_NV_CACHE`、`_nvim_conf_get/set/unset`(`~/.config/ubuntu-setup/nvim.conf` 的 KEY=VALUE store)、`_nvim_rc_file`、`backup_file`+marker+`grep -qxF` 受管行/块范式、`_nvim_path_under_config` 路径护栏、`_nvim_backup_dir`、`_nvim_name_valid`/`_nvim_giturl_valid`、版本 helper(`_nvim_norm_ver`/`_nvim_vercmp_ge`/`_nvim_apt_ok`/`_nvim_installed_ok`)、`_nvim_install_tarball`(GitHub API 解析 + sha256)、`_nvim_sync`(lazy headless 驱动)、`_nvim_leader_valid`/`_nvim_colorscheme_valid`、i18n `NVIM_I18N`/`_nvim_t`、`ui()` 并行数组渲染。

## 与 `06-23-nvim-managed-config` 的关系(重要)

本任务**重构并大部分 supersede** 前身任务的产出:**takeover/overlay 双模式、`_nvim_cfg_mode`、curated 裸 nvim 插件 + LSP 组、`after/plugin` overlay 投递方式**都被替换——因为新方向是「LazyVim 永远是基座」,这些「服务于非 LazyVim 场景 / 裸 nvim 场景」的机制不再需要。但其**配置管理能力本身**(options/keymaps/leader/colorscheme/插件)被**保留并 re-home 到 LazyVim 官方文件**。`06-23` 任务目前仍 `in_progress` —— 其归档/收尾是维护者的任务管理决定,本 PRD 不代为处置,仅声明覆盖关系。

## 已确认决策(经 grilling 逐条摸清;含两处对中途结论的反转)

1. **基座**:LazyVim 是**唯一**基座。**删除**:其余 3 个 distro、`add-distro`/`install-distro`/`remove-distro` 多 distro 机制、`NVIM_APPNAME` 隔离 + manifest + alias、takeover/overlay 双模式 + `_nvim_cfg_mode`、`after/plugin` overlay 投递。
2. **落点 + 撞配置**:LazyVim 必落 `~/.config/nvim`(无隔离旁路)。撞已有配置**四分支**:空/不存在 → clone starter;**已是本 kit 的 LazyVim** → 幂等;**手写的 LazyVim** → **原地 adopt(不 clone、不动文件)**;**非 LazyVim** → 备份后替换。**无 `--force`**(时间戳备份即 failsafe)。归属标记文件记 `source=cloned|adopted`。
3. **设置投递机制 = LazyVim 官方扩展点**(反转 grilling 中途「不碰 `lua/config/*`」的结论):
   - 主题 + 插件 → kit **整文件独占** `~/.config/nvim/lua/plugins/ubuntu-setup.lua`;
   - leader / options / keymaps / autocmds → `~/.config/nvim/lua/config/{options,keymaps,autocmds}.lua` 的 **managed block**(`tmux.sh` 范式:marker + 保留块外用户内容 + 改前 `backup_file`);
   - extras → `~/.config/nvim/lazyvim.json`,经 **headless 驱动 LazyVim 自己的 `LazyVim.json.save()`**(官方非交互等价物,免去 jq 直改 JSON 的 version/缺文件脆弱);
   - 字体 → 委托现有 `fonts.sh`。
4. **`install` = 整套组合**(用户定):二进制 + deps + Nerd Font + LazyVim + headless sync 一步交付可用 LazyVim。
5. **默认零 extras**:`install`/`--recommended` 不预启用任何语言/功能包(语言因人而异、vanilla LazyVim 已是完整 IDE);extras 全 opt-in。
6. **9 个配置域**(全部 opt-in,默认 = LazyVim 基线):① 主题 ② 字体 ③ 插件(加/删/禁用/启用,**反转 grilling 中途「砍掉 add-plugin」的结论**)④ extras ⑤ leader ⑥ keymaps ⑦ options(含 format-on-save)⑧ autocmds ⑨ Mason 工具。
7. **版本闸 `0.11.2`**:已查实 = LazyVim 当前**真实最低 Neovim 要求**(健康检查强制 enforce),保留现值。
8. **deps 对齐 LazyVim healthcheck**:`git curl ripgrep fd-find fzf build-essential unzip gzip` +（best-effort）`lazygit` + Nerd Font（`fonts.sh`）+ 剪贴板；`tree-sitter` CLI 交 LazyVim 自动安装(已确保 `gzip` 在场)。

## Requirements

### R1 · 二进制层(沿用,微调)
- 渠道 apt(候选 ≥ `0.11.2`)→ 官方 stable tarball(sha256 校验)→ snap;`install`/`remove`/`update`/`status` 行为沿用现状。
- `status` 退 0 当且仅当**组合已装**(nvim 在 **且** LazyVim 标记在);`KIT_PROBE_ONLY` 早返该布尔、用**标记文件 stat**(不 grep、不 spawn nvim),两路径退出码一致。

### R2 · `install` = 整套组合(幂等)
- 顺序:确保二进制 → `ensure-deps`(含 Nerd Font）→ LazyVim 落 `~/.config/nvim` → headless `:Lazy! sync` → 提示 `:LazyHealth`。
- LazyVim 落地**四分支**(R3);clone 来源 = `https://github.com/LazyVim/starter`,clone 后 `rm -rf .git`。
- 幂等:组合已装(标记在)则跳过重型步骤、至多重 sync。

### R3 · 撞配置四分支 + 归属标记
- 写归属标记文件 `~/.config/nvim/.ubuntu-setup-lazyvim`,含 `source=cloned|adopted`。
- **空/不存在** → clone starter、`rm -rf .git`、标 `cloned`。
- **已是 kit 的 LazyVim**(标记在)→ 幂等(仅重 sync)。
- **手写 LazyVim**(无 kit 标记,但 `lua/` 下 grep 命中 `LazyVim/LazyVim`)→ **adopt:标 `adopted`,不 clone、不动既有文件**(仅后续设置域往官方文件叠加)。
- **非 LazyVim**(无标记、非 LazyVim)→ 备份 `~/.config/nvim` **及** `~/.local/share/nvim`、`~/.local/state/nvim`、`~/.cache/nvim` 到 `*.bak.<ts>` → clone → 标 `cloned`;此破坏性分支**执行 + 大声 `log_warn`**(headless/LLM 可用),`ui()` 内 `ui_confirm` 二次确认;**无 `--force`**。
- 检测启发式失败时**偏向保留**(更像 LazyVim 就 adopt,不轻易备份搬走)。

### R4 · `remove`(按归属安全卸载)
- 卸二进制(按渠道 dpkg/snap/tarball)。
- `source=cloned` → 备份后删 `~/.config/nvim` + 标记;`source=adopted` → **只摘标记、绝不动配置目录**;`--purge`(仅 cloned)额外删 data/state/cache。

### R5 · `update`
- 二进制(tarball 渠道重取最新 stable;apt/snap 渠道按现状提示/升级)+ headless `:Lazy! sync`。

### R6 · 设置域 1 — 主题(`lua/plugins/ubuntu-setup.lua`)
- `set-colorscheme <name>`:写 `{ "LazyVim/LazyVim", opts = { colorscheme = X } }`;**非内置主题**额外加 `{ "<owner/repo>" }` 插件 spec;改后 headless `:Lazy! sync`(装/清主题插件)。
- curated:`tokyonight`(默认,内置)`catppuccin`(内置)`gruvbox` `kanagawa` `rose-pine` `everforest`(需插件);接受任意名(`_nvim_colorscheme_valid` 校验)。
- 状态 nvim.conf `CFG_COLORSCHEME`;**v1 只设主题名**(透明/明暗子选项/函数式主题 = 非目标)。

### R7 · 设置域 2 — 字体(委托 `fonts.sh`)
- `ui()` 的 Font 项 → `ui_run -- "$KIT_SCRIPTS_DIR/fonts.sh" install|apply <name> [size]`;curated `MesloLGS NF`(默认)/`JetBrainsMono`/`FiraCode`/`Hack` + size。
- **诚实**:nvim 是 TUI,字体由**终端模拟器**渲染;`fonts.sh apply` 仅对**本地显示**(经 gsettings 到 Ptyxis/GNOME Terminal/GNOME monospace)生效;SSH/headless 下只装字体 + 提示在**客户端终端**选 Nerd Font;用 ghostty 的字体归 `ghostty.sh`。

### R8 · 设置域 3 — 插件(`lua/plugins/ubuntu-setup.lua`)
- `add-plugin <owner/repo|git-url>` → 追加 `{ "owner/repo" }` / `{ url = "..." }`;`remove-plugin <name>`;**`disable-plugin <name>`** → `{ "<name>", enabled = false }`;**`enable-plugin <name>`** 撤销禁用。
- 状态 nvim.conf(`PLUGINS=` + `EXTRA_PLUGIN_<slug>` + `DISABLED_PLUGINS=`);改后 headless `:Lazy! sync`。
- **边界**:kit 只「启用/禁用某插件」(最简 spec);复杂 per-plugin `opts`/`keys` 归用户在自己的 `lua/plugins/*.lua`。

### R9 · 设置域 4 — extras(`lazyvim.json`)
- `extra-add <cat.name>` / `extra-remove <cat.name>`:经 **headless 驱动 `LazyVim.config.json.data.extras` + `LazyVim.json.save()`** 逐条增删,**保留**用户经 `:LazyExtras` 加的条目(per-op 不旁敲),改后 headless `:Lazy! sync` + 提示重启。
- curated UI 短清单 `lang.python/go/rust/typescript/json/yaml/toml/markdown/docker/sh/clangd/java`;`extra-add` 接受任意合法 `<cat>.<name>`(映射到 `lazyvim.plugins.extras.<cat>.<name>`,正则校验)。
- 默认零启用;LSP server 由 Mason 装(Node 系走 Node 闸:缺则指 `swkit node install`,**绝不自动装 Node**)。

### R10 · 设置域 5/6/7/8 — leader / keymaps / options / autocmds(`lua/config/*` managed block)
- **leader**(`lua/config/options.lua` 块):`set-leader <char|space>`,写 `vim.g.mapleader`/`maplocalleader`;默认 `space`;`_nvim_leader_valid` 护栏。
- **options**(同 `options.lua` 块):`set-option <name> <value>` / `unset-option <name>`;curated 常改项 `relativenumber/wrap/scrolloff/shiftwidth/tabstop/conceallevel/background/spell` + **format-on-save**(`vim.g.autoformat`);name `^[a-z_]+$`、value 限 `on|off|整数|简单字串`;**只覆盖不禁用**(印证 LazyVim issue #566:`defaults.options=false` 无效,必须在 `lua/config/options.lua` 重设)。
- **keymaps**(`lua/config/keymaps.lua` 块):`add-keymap <mode> <lhs> <rhs> [desc]` / `remove-keymap <mode> <lhs>`;mode ∈ `n/i/v/x/s/o/t/c`,lhs/rhs 拒 `"`/`\`/换行,rhs 作命令串;另可选一组 curated QoL keymaps。
- **autocmds**(`lua/config/autocmds.lua` 块):curated 非冗余项的开关(如 trim 尾空白)+ 禁用 LazyVim 命名 augroup(`vim.api.nvim_del_augroup_by_name("lazyvim_*")`);**不**接受任意 Lua autocmd(注入风险,归用户领地)。
- 三个块同 `tmux.sh` 范式:首行 marker、整体重生成块、保留块外用户内容、改前 `backup_file`、路径护栏。

### R11 · 设置域 9 — Mason 工具(`lua/plugins/ubuntu-setup.lua` 内 mason spec)
- `mason-add <tool>` / `mason-remove <tool>`:写 `{ "mason-org/mason.nvim", opts = { ensure_installed = { ... } } }`(`opts_extend` 合并安全,已查实);改后 headless `:Lazy! sync`(Mason 下次启动装)。
- 诚实:Node 系 server 走 Node 闸;「配整门语言优先用 `extra-add lang.*`」。

### R12 · op / configure / ui / 迁移 / i18n / SSH 接口
- `meta.ops` = `install,remove,configure,update,update-plugins`;带参 op 经 `kit_dispatch` 路由 `do_<x>`、**不进 `meta.ops`**、且在 `ui()` 交互可达。
- `configure` flags:`--recommended`(= install + editor on)/各域 flag(`--colorscheme`/`--leader`/`--editor on|off`/`--deps`/…);**无参 = 保守收敛**(已装则重生成 kit 受管产物,未装只给指引、不触发重型安装)。
- 另保留 `ensure-deps`、`set-default-editor [off]`、`list-colorschemes`/`list-extras`、`config-show`/`config-reset`。
- **迁移**:清 kit 自打 marker 的旧 rc alias 行 + 旧 `after/plugin/ubuntu-setup.lua`;**绝不删**旧隔离 `~/.config/nvim-<distro>` 用户配置。
- i18n en/zh/ja(主题/extra/插件/distro 名不译);neovim 是 TUI,SSH/headless 完美适用(仅字体有客户端终端提示);`ui()` 9 域分组 + Apply recommended,读走 fs/conf、改走 `ui_run`。

### R13 · 安全 / 幂等契约(不可妥协,沿用 lib)
- 配置域全程用户态(`_nvim_resolve_home` 认 `SUDO_USER`、拒 sudo 包裹);仅二进制/apt 经 `sudo_run` 逐命令提权。
- 一切提权/包/文件操作走 lib helper;绝不裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`;**绝不自动装 Node**。
- 改文件前 `backup_file`;受管块/文件首行 marker 判归属;幂等(`status` 闸 + 重生成收敛);路径护栏 `_nvim_path_under_config` 防逃逸出 `~/.config`。
- 名/值/键正则校验挡 Lua / YAML / JSON 注入。

## 非目标(Out of scope)

- 多 distro(kickstart/astronvim/nvchad)、`NVIM_APPNAME` 隔离、任意 distro。
- 主题透明 / 明暗自动 / 函数式 colorscheme(归用户在自己 `lua/plugins`)。
- per-filetype autoformat(`vim.b.autoformat` + ftplugin)、深度 LSP server / diagnostics / formatter 配置。
- 任意 Lua autocmd(只做 curated + 禁用命名 augroup)。
- GUI nvim 前端(Neovide/nvim-qt)的 `guifont`。

## Acceptance Criteria

- [ ] 静态:`bash -n scripts/nvim.sh` 过;`shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh` 零告警。
- [ ] 契约:`nvim.sh meta` 字段齐全且 `ops` 与实现一致、`ops` **不含 `ui`**;`status` 可独立运行、退出码语义正确(组合在/不在);`help` 不炸;`ui` 在无 TTY 下打印指引退 0。
- [ ] `install` 在干净环境端到端:装二进制 + deps + Nerd Font + LazyVim(`~/.config/nvim`,无 `.git`)+ `:Lazy! sync` 成功;`status` 转为已装;重跑 `install` 幂等 no-op。
- [ ] 撞配置四分支各自正确:adopt 不动手写 LazyVim 文件;非 LazyVim 备份 config+share+state+cache 后替换;`remove` 对 `adopted` 不删配置。
- [ ] 9 域各自:`set-colorscheme`/`add-plugin`+`disable-plugin`/`extra-add`+`extra-remove`/`set-leader`/`add-keymap`/`set-option`(含 autoformat)/`add-autocmd`/`mason-add` 写对文件、幂等重生成、可 `remove`/`unset` 回退;`lua/config/*` 块保留块外用户内容;`lazyvim.json` 合并保留用户条目。
- [ ] 生成的 lua / lazyvim.json 真机加载无报错(`nvim --headless "+checkhealth" +qa` 或启动无 error)。
- [ ] 安全:配置域被 sudo 包裹时拒绝并提示;注入向量(主题/插件/键/option/extra 名带元字符)被校验挡下。
- [ ] 外部渠道(tarball GitHub API、lazyvim.json headless save、fonts.sh 联动)**真机端到端各跑一次**(静态检查覆盖不到)。
- [ ] `ui()` 伪终端冒烟:渲染不崩、`q` 干净退出、终端复原。

## Constraints

- 仅 Ubuntu/Debian;目标含全新最小 Server/SSH/无桌面。
- 遵守 `lib/` 五条安全契约(逐命令 sudo、非交互 apt、改前备份、用户态设置、保守渠道)与「目录加载零卡顿」缓存契约。
- 改 `scripts/nvim.sh` = 代码改动 → 全程在本 worktree 内完成,验证通过再 merge 回 dev。
- **诚实总账**:本次**不是精简**——保留旧 managed-config-layer 全能力 + 新增 font/extras/mason/disable/autocmds,**行数大概率 ≥ 原 1556(~1500–1800)**;收益是单一基座 + 官方正道落点 + 双模式消失。
