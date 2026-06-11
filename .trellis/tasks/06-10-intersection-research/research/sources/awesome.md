# awesome —— 三个 awesome 清单交集（辅助源，合并计 1 票）

抓取日期：2026-06-10

## 抓取过程

用 `curl -sL` 抓三个清单的 raw README：

| 清单 | URL | 解析出条目数 |
|---|---|---|
| modern-unix | https://raw.githubusercontent.com/ibraheemdev/modern-unix/master/README.md | 28 |
| awesome-cli-apps | https://raw.githubusercontent.com/agarrharr/awesome-cli-apps/master/readme.md | 501 |
| awesome-shell | https://raw.githubusercontent.com/alebcay/awesome-shell/master/README.md | 363 |

解析方式：modern-unix 是 HTML 标记，用 `<a href="URL"><code>NAME</code></a>` 提取；另两个是 markdown 列表项 `- [name](url)`，跳过 `#` 锚点（TOC）。名称归一化为小写连字符后求交集，只保留出现在 ≥2 个清单中的工具。

## 判读与人工裁定

原始交集 97 条，逐条用条目 URL 复核同名是否同一项目后，最终 95 条：

- **剔除 3 条**：
  - `q` —— 同名异项目：awesome-cli-apps 的是 harelba/q（CSV 上跑 SQL），awesome-shell 的是 cal2195/q（Vim 式宏寄存器），不是同一软件。
  - `terminals-are-sexy` —— 本身是另一个 awesome 清单，不是可安装软件。
  - `wttr.in` —— `curl wttr.in` 调用的天气网络服务，不属于本机安装软件。
- **合并 2 组**：
  - `the-fuck`（aca）+ `thefuck`（ash）→ canonical `thefuck`，同为 nvbn/thefuck。
  - `exa`（ash，ogham/exa 前身）并入 `eza`（mu+aca），按同一产品计 3 票。
- **同 repo 改名/迁移已确认同项目**（GitHub redirect 验证）：`undollar`（ImFeelingDucky→xtyrrell）、`aria2`（tatsuhiro-t→aria2 org）、`fz`（fz→fz.sh）、`geeknote`（原作者→社区 fork）。
- **特殊计票**：
  - `tldr` —— awesome-shell 收录的是客户端 tldr-sh-client，按 tldr-pages 产品生态计 3 票。
  - `yq` —— 两清单分别指 kislyuk/yq 与 mikefarah/yq 两个同名实现，按 CLI 名合并计 2 票。

metric = 命中清单数（2 或 3），metric_unit = mentions。3/3 命中共 11 个：bat、broot、eza、fd、fzf、glances、httpie、jq、lsd、tldr、zoxide。

## 局限

- 三个清单互相借鉴、互抄票，**不是独立信源**，本源整体只应合并计 1 票。
- 口味偏向 Rust 系新潮 CLI 替代品，对运行时/工具链/GUI 应用几乎无覆盖（本源没有 docker、python、vscode 这类条目）。
- 收录门槛低（提 PR 即收），2/3 命中的长尾条目信息量有限，不代表实际安装量或活跃度。
- modern-unix 只有 28 条且更新停滞，3/3 封顶受其收录范围限制。

## 完整交集矩阵（95 条）

| canonical | modern-unix | awesome-cli-apps | awesome-shell | 票 |
|---|---|---|---|---|
| bat | x | x | x | 3 |
| broot | x | x | x | 3 |
| eza | x | x | x | 3 |
| fd | x | x | x | 3 |
| fzf | x | x | x | 3 |
| glances | x | x | x | 3 |
| httpie | x | x | x | 3 |
| jq | x | x | x | 3 |
| lsd | x | x | x | 3 |
| tldr | x | x | x | 3 |
| zoxide | x | x | x | 3 |
| add-gitignore |  | x | x | 2 |
| aria2 |  | x | x | 2 |
| arttime |  | x | x | 2 |
| autojump |  | x | x | 2 |
| await |  | x | x | 2 |
| bartib |  | x | x | 2 |
| bash-git-prompt |  | x | x | 2 |
| bcal |  | x | x | 2 |
| beets |  | x | x | 2 |
| bitwise |  | x | x | 2 |
| boilr |  | x | x | 2 |
| buku |  | x | x | 2 |
| carbon-now-cli |  | x | x | 2 |
| cmus |  | x | x | 2 |
| cointop |  | x | x | 2 |
| curlie | x | x |  | 2 |
| dasel |  | x | x | 2 |
| dnote |  | x | x | 2 |
| duf | x | x |  | 2 |
| dust | x | x |  | 2 |
| dzr |  | x | x | 2 |
| editly |  | x | x | 2 |
| eureka |  | x | x | 2 |
| fselect |  | x | x | 2 |
| fx |  | x | x | 2 |
| fz |  | x | x | 2 |
| gcalcli |  | x | x | 2 |
| geeknote |  | x | x | 2 |
| gifgen |  | x | x | 2 |
| git-extras |  | x | x | 2 |
| gita |  | x | x | 2 |
| goto |  | x | x | 2 |
| has |  | x | x | 2 |
| how2 |  | x | x | 2 |
| hub |  | x | x | 2 |
| imgp |  | x | x | 2 |
| just |  | x | x | 2 |
| kanban.bash |  | x | x | 2 |
| korkut |  | x | x | 2 |
| lazygit | x | x |  | 2 |
| ledger |  | x | x | 2 |
| lf |  | x | x | 2 |
| lowcharts |  | x | x | 2 |
| mcfly | x |  | x | 2 |
| moviemon |  | x | x | 2 |
| mpv |  | x | x | 2 |
| navi |  | x | x | 2 |
| ncdu |  | x | x | 2 |
| nnn |  | x | x | 2 |
| nomino |  | x | x | 2 |
| oh-my-posh |  | x | x | 2 |
| pass |  | x | x | 2 |
| pathpicker |  | x | x | 2 |
| ranger |  | x | x | 2 |
| rebound |  | x | x | 2 |
| ripgrep | x | x |  | 2 |
| saws |  | x | x | 2 |
| shallow-backup |  | x | x | 2 |
| shell2http |  | x | x | 2 |
| shellspec |  | x | x | 2 |
| sqlline |  | x | x | 2 |
| starship |  | x | x | 2 |
| stronghold |  | x | x | 2 |
| taskbook |  | x | x | 2 |
| taskwarrior |  | x | x | 2 |
| td-cli |  | x | x | 2 |
| tere |  | x | x | 2 |
| terjira |  | x | x | 2 |
| thefuck |  | x | x | 2 |
| ticker |  | x | x | 2 |
| tiptop |  | x | x | 2 |
| undollar |  | x | x | 2 |
| usql |  | x | x | 2 |
| visidata |  | x | x | 2 |
| wego |  | x | x | 2 |
| wipe-modules |  | x | x | 2 |
| xh | x |  | x | 2 |
| xiringuito |  | x | x | 2 |
| xplr |  | x | x | 2 |
| xxh |  | x | x | 2 |
| yq |  | x | x | 2 |
| yt-dlp |  | x | x | 2 |
| z |  | x | x | 2 |
| z.lua |  | x | x | 2 |