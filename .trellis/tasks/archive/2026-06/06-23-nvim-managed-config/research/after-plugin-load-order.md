# Research: `after/plugin` 加载机制(overlay 命门)+ lazy.nvim bootstrap

日期 2026-06-23 · 来源:lazy.nvim 官方文档(lazy.folke.io/usage)、folke/lazy.nvim 源码、neovim.io/doc、社区 issue/discussion(经 context7 + exa 查证)。

## 1. 承重结论:`~/.config/<appname>/after/plugin/*.lua` 在裸 nvim 与 lazy.nvim/LazyVim 下都被可靠 source

lazy.nvim 接管启动(`vim.go.loadplugins = false`),但其启动序列(替代 Neovim 初始化第 10 步)为:

1. 所有插件的 `init()` 执行
2. `lazy=false` 的插件加载(source 各自 `/plugin`、`/ftdetect`,**不含 `/after`**)
3. rtp 里所有 `/plugin`、`/ftdetect` 被 source(**排除 `/after`**)
4. **所有 `/after/plugin` 文件被 source(含插件的 `/after`)**

且 `performance.rtp.reset = true`(默认)重置 rtp 时,**显式保留** config 的 after:

```lua
vim.opt.rtp = {
  vim.fn.stdpath("config"),               -- ~/.config/<appname>
  vim.fn.stdpath("data") .. "/site",
  M.me,                                    -- lazy.nvim 自身
  vim.env.VIMRUNTIME,
  vim.fn.fnamemodify(vim.v.progpath, ":p:h:h") .. "/lib/nvim",
  vim.fn.stdpath("config") .. "/after",   -- ← config 的 after 被保留
}
```

→ 故 `~/.config/<appname>/after/plugin/ubuntu-setup.lua` 在 LazyVim 下被 source,且在**第 4 步、最后**执行(在 distro 全部插件之后),kit 的 options/colorscheme 覆盖 distro 默认。**overlay 机制成立。**

## 2. 关键事实 / 坑

- **必须顶层 `after/plugin/`,不是 `lua/after/`。** 社区(LazyVim discussion #1464)有人把 after 放进 `lua/after/` 后失效——`lua/` 下一切按 Lua 模块对待,需 `require`。kit 必须写 `~/.config/<appname>/after/plugin/ubuntu-setup.lua`(顶层 after,自动 source)。
- **`stdpath("config")` 认 `NVIM_APPNAME`。** appname=`nvim-lazyvim` 时 config=`~/.config/nvim-lazyvim`,其 after 被保留 → 与 `--app <name>` 设计一致(overlay 文件落 `~/.config/<appname>/after/plugin/`)。
- **原生 packages(`pack/*/start`)在 lazy 下不可靠。** lazy reset packpath/rtp,`~/.local/share/nvim/site/pack/*/start/*` 不再自动加载(issue #1362)。→ 印证决策:overlay **不**管插件(插件仅裸 nvim,经 lazy 管)。
- **leader 必须早设。** `vim.g.mapleader` 要在插件加载前(init.lua 内、`require("lazy").setup` 之前)设置,after/plugin(第 4 步)太晚。→ 印证决策:overlay **不**设 leader(让给 distro);仅裸 nvim takeover 在 init.lua 早设。
- **keymaps 的 overlay 局限(诚实披露):** 普通 keymaps 在 after/plugin(最后)设,会覆盖 distro 的 eager 映射;但 distro 经 lazy **懒加载**插件时设的映射可能在 after/plugin 之后才生效(VeryLazy/插件加载时),从而盖过 kit。→ overlay 的 keymaps 标注"best-effort,可能被 distro 懒加载键覆盖"。

## 3. lazy.nvim bootstrap(裸 nvim takeover 用,官方片段)

```lua
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then error("clone lazy.nvim failed:\n" .. out) end
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "        -- 早设,插件加载前
vim.g.maplocalleader = "\\"

require("lazy").setup({
  spec = { ... },            -- kit 受管的 curated 插件 spec
  install = { colorscheme = { "habamax" } },
})
```

- kit takeover 用 `--filter=blob:none --branch=stable` clone lazy.nvim 到 `stdpath("data")/lazy/lazy.nvim`(= `~/.local/share/<appname>/lazy/lazy.nvim`,认 appname)。
- 插件同步沿用现有 `_nvim_sync`(headless `+Lazy! sync`)。
- 检测"kit 已 takeover":用 nvim.conf 状态(`MANAGED_APP`/`MANAGED_MODE`)+ init.lua 内 marker,**不能**只靠"目录非空"(takeover 后目录就非空了)。

## 4. blink.cmp(补全引擎)安装要求

- 默认 `fuzzy.implementation = 'prefer_rust_with_warning'`:有则用 Rust 预编译二进制(**自动从 GitHub 下载**,只需 curl + 网络),无则回退纯 Lua 实现(告警)。
- **不强制 Rust 工具链**:可设 `implementation = 'lua'` 完全零下载零构建;或允许默认的预编译二进制下载(curl 已是 nvim deps)。
- kickstart.nvim 与 LazyVim 现均默认 blink.cmp。
- kit 决策:用 blink.cmp;`fuzzy.implementation` 留默认(prefer_rust_with_warning,curl 拉预编译 + lua 回退),不引入 cargo。

## 5. curated 插件最小可用 spec(2025 / nvim 0.11+,经 context7 + exa 查证)

- **mason 已迁 `mason-org/`**(`williamboman/*` 仅重定向):用 `mason-org/mason.nvim`、`mason-org/mason-lspconfig.nvim`。
- **mason-lspconfig 推荐 lazy 写法**(自动 `vim.lsp.enable()` 已装 server,**无需手动 `require(...).setup()`**):
  ```lua
  { "mason-org/mason-lspconfig.nvim", opts = {},
    dependencies = { { "mason-org/mason.nvim", opts = {} }, "neovim/nvim-lspconfig" } }
  ```
- **nvim-lspconfig**:`require('lspconfig')` 框架在 0.11+ 已弃用,改 `vim.lsp.config`/`vim.lsp.enable`;但只装 lspconfig 即提供 `lsp/` 配置,mason-lspconfig 自动 enable,**无需手动接线**。server 不自动装,用户在 `:Mason` 装(Node 系 server 需 `swkit node install`)。
- **blink.cmp**:`{ "saghen/blink.cmp", version = "1.*", opts = {} }`。0.11+ 不强制手动 capabilities 接线;留默认即可工作。不手动 `require("blink.cmp")`(可能未加载)。
- **treesitter**:`{ "nvim-treesitter/nvim-treesitter", build = ":TSUpdate", config = function() require("nvim-treesitter.configs").setup({ ensure_installed = {...}, highlight = { enable = true } }) end }`(master 经典 API;main 分支重写是 opt-in,默认装 master 可用)。
- **telescope**:`{ "nvim-telescope/telescope.nvim", dependencies = { "nvim-lua/plenary.nvim" }, opts = {} }`。
- **gitsigns/which-key/lualine**:`opts = {}` 即可(lualine 图标需 Nerd Font,ensure-deps 已装)。
