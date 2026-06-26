# 逐条说明草表(S0 产出 · 经 context7 查证)

> 来源:Neovim `/neovim/neovim`(options 语义,已查证 scrolloff/tabstop/wrap 等)+ LazyVim `/websites/lazyvim`(extras 捆绑模式:每个 `lang.X` = treesitter parser + LSP(经 Mason)+ formatter/linter +(部分)DAP 调试;已查证 python=pyright/basedpyright、typescript=lspconfig+treesitter+mason+typescript.nvim)。colorscheme/font 为主观风格词,无需查证。
>
> **键命名**:短 = `<kind>_<name>`,完整 = `<kind>_<name>_full`(`.`/`-` → `_`)。**完整缺省时 helper fallback 到短**——所以下面凡「完整≈短」的可只写短键、省 `_full`,减少体量。
> **条目名不译**(tokyonight/lang.go/scrolloff/MesloLGS…),只译描述词。

---

## 1 · options(kind=`opt`)— 最隐晦、白话优先

| name | en 短 | en 完整(+何时用) | zh 短 | zh 完整 | ja 短 |
|---|---|---|---|---|---|
| relativenumber | line numbers relative to the cursor | Show each line's distance from the cursor (current line = 0/absolute) — makes vertical jumps like `5j`/`3k` easy. on/off | 相对当前行的行号 | 显示各行到光标的距离(当前行为 0/绝对值),便于 `5j`/`3k` 这类纵向跳转。on/off | カーソルからの相対行番号 |
| wrap | wrap long lines onto the next row | Long lines fold onto the next screen row instead of running off-screen — good for prose, usually off for code. on/off | 长行折到下一屏幕行 | 长行折到下一屏幕行而非跑出屏幕;写文章好用,代码通常关。on/off | 長い行を次の行へ折り返す |
| scrolloff | keep N lines around the cursor | Keep at least N lines visible above and below the cursor while scrolling (default 0; ~8 keeps context). integer | 光标上下保留 N 行 | 滚动时光标上下至少保留 N 行可见(默认 0,设 ~8 留出上下文)。整数 | カーソル上下に N 行確保 |
| shiftwidth | spaces per indent step | Number of spaces for each indent step (`>>`, `<<`, `=`, auto-indent). integer | 每级缩进的空格数 | 每级缩进(`>>`/`<<`/`=`/自动缩进)用的空格数。整数 | インデント1段の空白数 |
| tabstop | display width of a Tab | How many columns a Tab character occupies on screen. integer | Tab 的显示宽度 | 一个 Tab 字符在屏上占多少列。整数 | Tab の表示幅 |
| conceallevel | how concealed text shows | How text marked "conceal" (e.g. markdown markup) renders: 0 show · 1 placeholder · 2 hide · 3 hide fully. Set 2 for cleaner markdown. 0–3 | 隐藏文本的显示方式 | 标记为 conceal 的文本(如 markdown 标记)如何显示:0 显示·1 占位符·2 隐藏·3 完全隐藏;markdown 设 2 更干净。0–3 | conceal テキストの表示度 |
| background | tell nvim dark or light terminal | Tells Neovim whether your terminal background is dark or light so colorschemes pick the matching variant. dark/light | 告诉 nvim 终端是暗/亮底 | 告诉 Neovim 终端底色是暗还是亮,让主题选对应明暗变体。dark/light | 端末が暗いか明るいか |
| spell | spell checking | Highlight misspelled words — handy for prose/commit messages, off for code. on/off | 拼写检查 | 高亮拼错的词;写文章/提交信息有用,代码关掉。on/off | スペルチェック |

> zh/ja 的「完整」键大多可省(短句已够;helper fallback)。ja 完整按需补,best-effort。

## 2 · extras(kind=`ex`,name 如 `lang_go`)— LazyVim 语言/功能包

| name(extra) | en 短 | en 完整 | zh 短 | zh 完整 |
|---|---|---|---|---|
| lang.python | Python IDE layer | Python LSP (pyright/basedpyright), ruff, debugpy (DAP) + treesitter — enable for Python projects | Python 开发层 | Python 的 LSP(pyright/basedpyright)、ruff、debugpy 调试 + treesitter;写 Python 时启用 |
| lang.go | Go IDE layer | gopls LSP, gofumpt/goimports, delve (DAP) + treesitter — enable for Go projects | Go 开发层 | gopls LSP、gofumpt/goimports、delve 调试 + treesitter;写 Go 时启用 |
| lang.rust | Rust IDE layer | rust-analyzer (rustaceanvim), formatting + debugging + treesitter — enable for Rust projects | Rust 开发层 | rust-analyzer(rustaceanvim)、格式化、调试 + treesitter;写 Rust 时启用 |
| lang.json | JSON support | jsonls + SchemaStore (schema-aware completion) + treesitter | JSON 支持 | jsonls + SchemaStore(带 schema 的补全)+ treesitter |
| lang.yaml | YAML support | yamlls + SchemaStore + treesitter | YAML 支持 | yamlls + SchemaStore + treesitter |
| lang.toml | TOML support | taplo LSP + treesitter | TOML 支持 | taplo LSP + treesitter |
| lang.markdown | Markdown support | marksman LSP, markdownlint, prettier, rendering + treesitter | Markdown 支持 | marksman LSP、markdownlint、prettier、渲染 + treesitter |
| lang.docker | Docker support | dockerfile + docker-compose LSP + treesitter | Docker 支持 | dockerfile + docker-compose LSP + treesitter |
| lang.clangd | C/C++ IDE layer | clangd LSP, formatting + debugging + treesitter — enable for C/C++ projects | C/C++ 开发层 | clangd LSP、格式化、调试 + treesitter;写 C/C++ 时启用 |
| lang.java | Java IDE layer | jdtls (nvim-jdtls), debugging + treesitter — enable for Java projects | Java 开发层 | jdtls(nvim-jdtls)、调试 + treesitter;写 Java 时启用 |

> ja:短句照译(「Python 開発レイヤ」等),完整 best-effort 或 fallback。

## 3 · colorscheme(kind=`cs`,name 如 `rose_pine`)— 主观风格词

| name | en 短 | en 完整 | zh 短 | zh 完整 |
|---|---|---|---|---|
| tokyonight | LazyVim's default; clean blue-tinted | LazyVim's default — clean, blue-leaning palette (night/storm/moon dark, day light) | LazyVim 默认,偏蓝清爽 | LazyVim 默认主题,偏蓝清爽(night/storm/moon 暗、day 亮) |
| catppuccin | soft pastel, very popular | Soft pastel palette, hugely popular (mocha…dark, latte…light) | 柔和马卡龙色,超流行 | 柔和马卡龙配色,极流行(mocha 暗、latte 亮) |
| gruvbox | warm retro earth tones | Warm retro earth tones, higher contrast, easy on the eyes | 暖色复古大地色 | 暖色复古大地色,对比较高,护眼 |
| kanagawa | muted, Hokusai-inspired | Muted palette inspired by Hokusai's "Great Wave" (lotus = light) | 低饱和,葛饰北斋风 | 取自葛饰北斋《神奈川冲浪里》的低饱和配色(lotus 为亮) |
| rose-pine | low-saturation, cozy | Low-saturation, cozy "natural pine, faux fur" aesthetic (dawn = light) | 低饱和,温柔 | 低饱和的温柔「松木/绒毛」美学(dawn 为亮) |
| everforest | green-based, low-contrast | Green-based, comfortable low-contrast forest palette | 绿调,低对比 | 绿调、舒适低对比的森林配色 |

> light/dark 已由 `NVIM_THEME_MODE` 标,文案里不重复明暗、只点 light 变体名(选择器详情有空间)。

## 4 · font(kind=`font`)— Nerd Font

| name | en 短 | en 完整 | zh 短 |
|---|---|---|---|
| meslolgs | MesloLGS NF — the flagship default | MesloLGS NF — the LazyVim/Powerlevel10k flagship; crisp with full icon coverage (default) | MesloLGS NF,旗舰默认 |
| jetbrains-mono | JetBrains Mono — built for code | JetBrains Mono — tall x-height, ligatures, designed for reading code | JetBrains Mono,为代码而生 |
| firacode | Fira Code — famous ligatures | Fira Code — well-known programming ligatures (`!=`→ glyph, etc.) | Fira Code,著名连字 |
| hack | Hack — sturdy, no-nonsense | Hack — sturdy, plain monospace tuned for source code | Hack,朴素耐看 |

## 5 · autocmds(kind=`ac`)— 收编现有英文 `NVIM_AUTOCMD_DESC` 并扩成「何时用」

| name | en 短(≈现状) | en 完整 | zh 短 | zh 完整 |
|---|---|---|---|---|
| trim_whitespace | Trim trailing whitespace on save | Remove trailing whitespace on save — keeps diffs clean | 保存时去行尾空白 | 保存时删除行尾空白,保持 diff 干净 |
| disable_wrap_spell | Disable LazyVim's auto wrap+spell in text/markdown | Turn off LazyVim's automatic wrap+spell in text/markdown filetypes — for those who find it distracting | 关掉 text/markdown 的自动折行+拼写 | 关掉 LazyVim 在 text/markdown 文件类型里的自动折行+拼写,嫌干扰者用 |
| disable_highlight_yank | Disable LazyVim's highlight-on-yank flash | Disable the brief flash that highlights text you just yanked | 关掉 yank 高亮闪烁 | 关掉复制(yank)时那一下高亮闪烁 |

## 6 · 模型解释(plugins / Mason,kind 自定)

| key | en | zh |
|---|---|---|
| plugins_model_note | LazyVim already bundles the core plugins (treesitter, telescope, gitsigns, …); add EXTRA ones here by owner/repo. | LazyVim 已自带核心插件(treesitter、telescope、gitsigns…);这里按 owner/repo 加额外的。 |
| mason_model_note | Mason installs LSP servers / formatters / linters; list tools here to auto-install (ensure_installed). | Mason 装 LSP server / 格式化器 / linter;在此列出要自动安装(ensure_installed)的工具。 |

> ja 三处按上表风格补;缺则 fallback en。

## 7 · meta desc 重排(R6)

现状(342 行,run-on):
`nvim + LazyVim combo manager — best-channel binary (apt/tarball/snap) + LazyVim config, with full component config via LazyVim's official extension points (theme/font/plugins/extras/leader/keymaps/options/autocmds/Mason)`

要点已基本前置;**轻重排**目标:首句即「nvim + LazyVim combo manager」+「best-channel binary」+「LazyVim config」,能力清单收尾。建议改为:
`nvim + LazyVim combo manager — best-channel Neovim binary (apt/tarball/snap) + LazyVim, fully configurable via LazyVim's own extension points: theme/font/plugins/extras/leader/keymaps/options/autocmds/Mason`
(语义不变,把 "combo manager" 与 "best-channel binary" 顶到最前,截断也读得出重点。)
