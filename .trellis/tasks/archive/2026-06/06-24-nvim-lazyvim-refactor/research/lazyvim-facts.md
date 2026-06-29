# LazyVim 查证事实(exa + context7,2026-06-24)

实现期凡涉及 LazyVim 机制,以本笔记为准;不确定处真机复核。来源已标注。

## 版本要求
- **Neovim 最低 `0.11.2`**(健康检查强制 enforce,低于即报错)。来源:LazyVim README「⚡️ Requirements」、`doc/LazyVim.txt`、issue #6421、NEWS.md。
- 最新 LazyVim **v16.0.0**(2026-06-02)。v15+ 起:treesitter 迁 **main 分支** → **装 parser 需 `tree-sitter` CLI**(LazyVim 会自动装,但需系统有 `gzip`)+ C 编译器(**不再支持 zig**);LSP 用原生 `vim.lsp.config`;mason v2.x。
- Git ≥ 2.19(partial clone)。

## 官方配置结构(`~/.config/nvim`)
```
init.lua
lua/config/{options,keymaps,autocmds,lazy}.lua   # 按名自动加载,勿手动 require
lua/plugins/*.lua                                # glob 全自动加载
```
- **加载序**:LazyVim 默认**先**加载,用户 `lua/config/*` **后**加载 → 覆盖。`options.lua` 在 `lazy.setup` **之前**(故 leader 设这里);`keymaps`/`autocmds` 在 VeryLazy。来源:lazyvim.org/configuration、/configuration/general、deepwiki getting-started/advanced-configuration。
- **options 只能覆盖不能禁用**:`{ "LazyVim/LazyVim", opts={ defaults={ options=false } } }` **无效**(issue #566);必须在 `lua/config/options.lua` 重设。autocmds/keymaps 的 `defaults.*=false` 才有效。

## 主题(域1)
- 覆盖:`lua/plugins/*.lua` 里 `{ "LazyVim/LazyVim", opts = { colorscheme = "X" } }`。默认 `tokyonight`。
- **非内置主题须连插件加**:如 `{ "ellisonleao/gruvbox.nvim" }` + 上面的 opts。
- colorscheme 可为字符串或函数(动态/base16 用函数,v1 不做)。来源:lazyvim.org/configuration、/plugins/colorscheme、ambitious-devs book ch19、discussion #7090。

## 插件(域3)
- 加:`lua/plugins/*.lua` 放 spec。禁用默认:`{ "folke/flash.nvim", enabled = false }`。来源:lazyvim.org/configuration/plugins、starter `lua/plugins/example.lua`。

## options/keymaps/autocmds(域5/6/7/8)
- 落 `lua/config/{options,keymaps,autocmds}.lua`。format-on-save:`vim.g.autoformat = false`(issue #141)。
- LazyVim 自带 `vim.g.*`:`mapleader`(空格)/`maplocalleader`(`\`)/`autoformat`/`lazyvim_picker`(telescope|fzf|auto)/`lazyvim_cmp`(blink|nvim-cmp|auto)/`ai_cmp`/`snacks_animate`/`root_spec`/`deprecation_warnings`/`trouble_lualine`。
- 禁用 LazyVim 默认 autocmd:`vim.api.nvim_del_augroup_by_name("lazyvim_<x>")`。来源:lazyvim.org/configuration/general、deepwiki advanced-configuration。

## extras(域4)· `lazyvim.json`
- 结构(严格 JSON,无注释):`{ "version": 8, "install_version": 8, "news": {…}, "extras": ["lazyvim.plugins.extras.lang.python", …] }`(extras = 排序的全模块名数组)。来源:LazyVim 源码 `lua/lazyvim/config/init.lua`。
- **仅 `:LazyExtras` toggle / migrate 时 `save()` 落盘**,普通启动**不创建**该文件 → 首装后 `extra-add` 可能撞文件缺失。
- 两条启用路径:① `lazyvim.json`(`:LazyExtras`,**自动处理 extras 导入顺序**)② `lua/plugins` 里 `{ import = … }`(**有顺序陷阱** issue #5854,维护者不建议)。
- `managed` 语义:走 `lazyvim.json` 启用 → `:LazyExtras` UI 认为 managed、用户可 toggle;走 `import` → 显示「Not managed」、用户**无法**在 UI 关。来源:discussion #2727、issue #5854、`util/extras.lua`。
- **headless save 机制(域4 落地)**:`util/extras.lua` 的 `X:toggle` 用 `LazyVim.config.json.data.extras` + `LazyVim.json.save()`。实现期真机核对:全局 `LazyVim` / `require("lazyvim.util.json").save` 的确切路径 + headless 启动后 json 模块已加载的时序。失败 → 退 jq 备选(仅处理文件已存在情形)。

## extras 全目录(`lua/lazyvim/plugins/extras/`)
- 类目:`ai/ coding/ dap/ editor/ formatting/ lang/ linting/ lsp/ test/ ui/ util/` + `vscode.lua`。
- `lang/`(48,已核全):angular ansible astro clangd clojure cmake dart docker dotnet elixir elm ember erlang git gleam go haskell helm java json julia kotlin lean markdown nix nushell ocaml php prisma python r rego ruby rust scala solidity sql svelte tailwind terraform tex thrift toml twig typst typescript vue yaml zig。
- picker/cmp/explorer 经 extras 选:`editor.telescope|fzf|snacks_picker`、`coding.blink|nvim-cmp`、`editor.neo-tree|snacks_explorer`。
- 来源:github tree `plugins/extras`、deepwiki extras-system。

## Mason(域9)
- `ensure_installed` 用 `opts_extend = { "ensure_installed" }` → **多个 spec 各加各的、安全合并不覆盖**。kit 单写一条 `{ "mason-org/mason.nvim", opts={ ensure_installed={…} } }` 安全。
- mason-lspconfig 自动 enable 已装 server;`servers={ x={ mason=false } }` 排除。来源:deepwiki mason-tool-management、lazyvim.org/configuration/examples、`plugins/lsp/init.lua`。

## 安装 / deps
- 官方装法:`git clone https://github.com/LazyVim/starter ~/.config/nvim` → `rm -rf ~/.config/nvim/.git` → `nvim`(首启 bootstrap)→ 建议 `:LazyHealth`。
- 备份:不仅 `~/.config/nvim`,**还备份** `~/.local/share/nvim`、`~/.local/state/nvim`、`~/.cache/nvim`。
- healthcheck 校验外部工具:**git / rg(ripgrep)/ fd(fdfind)/ fzf / lazygit / curl** + C 编译器 + tree-sitter CLI。来源:lazyvim.org/installation、README、deepwiki installation-and-bootstrap。
