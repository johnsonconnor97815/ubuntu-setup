---
date: 2026-06-14
topic: Claude Code 扩展管理器(MCP / Plugins / Skills)
status: approved
---

# Claude Code 扩展管理器(MCP / Plugins / Skills)

## 背景与动机

现状(见 `scripts/claude.sh`):它只是一个**安装器**——`install`(native / npm)、`remove`、`status`,
加一个仅含安装/卸载的 `ui()`。但 Claude Code CLI 本身有三套可被脚本化管理的**扩展系统**:

1. **MCP servers** —— `claude mcp add/remove/list/get`(stdio / http / sse),作用域 local/user/project。
2. **Plugins & marketplaces** —— `claude plugin install/uninstall/enable/disable/list` + `claude plugin marketplace add/list/remove`。
3. **Skills** —— **纯文件式**:`~/.claude/skills/<name>/SKILL.md`(无 `claude skill` 子命令)。

用户希望"配置一台新机器的 Claude Code"时,这三者能像装软件一样被**发现、安装、增删、开关**,并**集中进现有 TUI**。
本设计把 `claude.sh` 从安装器**升级为组件管理器**,完全复刻 `zsh.sh` 旗舰范式("装软件 + 在同一界面管理其组件")。

## 调研依据(参考的开源项目)

调研于 2026-06-14。核心结论:**Claude Code 已自带非交互 CLI 原语**,第三方"管理器"主要补的是
"好用的选择 UI" 与 "enable/disable 不删配置(省 context)"。因此本项目**外壳调用官方 `claude` CLI**,
而非手改 JSON(后者脆弱)。本机实测 `claude 2.1.177` 的子命令语法已确认。

- **官方 CLI + `CLAUDE_CODE_PLUGIN_SEED_DIR`**(code.claude.com/docs)——基础;install/enable/remove 一律走它,幂等、官方、面向未来。
- **spences10/mcpick**(MIT)——统一 MCP+plugins+marketplaces 管理器,**TTY-TUI / headless-CLI 双模**、**写前回滚备份**。与本 kit 的 `have_tty` 双模、`backup_file` 同构。
- **kaldown/ccpm**(Rust/Ratatui, MIT)——插件 TUI:多作用域优先级**可视化**、**原子写 + 文件锁**。
- **henkisdabro/Claude-Code-MCP-Server-Selector**(MIT)——MCP 选择器,提出 **disabled→enabled→paused 三态**、强调"单个大 server 吃 5万–8万 token";本项目采用 **enable/disable 不删** 的轻量版。
- **modelcontextprotocol/registry**(Apache-2.0)——官方 MCP 目录,`GET https://registry.modelcontextprotocol.io/v0/servers?search=` 返回 `{servers, metadata}`,可 `curl|jq`。本项目用于可选的 `mcp-search`。
- **anthropics/claude-plugins-official** + **hesreallyhim/awesome-claude-code** / **travisvn/awesome-claude-skills** ——curated 种子来源(marketplace / skill)。
- **standardbeagle/mcp-tui** 的 "按 `c` 复制等效命令" ——本 kit 已天然满足(`ui_run` 标题即所跑命令、并 tee 到日志)。

## 决策(已与用户确认)

- **架构**:并入 `claude.sh` 单脚本组件管理器(非三个独立脚本、非独立 `claude-ext.sh`)。理由:Claude Code 是**一个软件**,三轴是它的扩展;`install/remove/status` 对 CLI 本体语义自然;单一目录入口即"集中进 UI";共享 helper(home 解析、claude 探测、安装闸)只此一份;与 `zsh.sh` 旗舰范式同构。
- **生态来源**:**curated + 实时混合**。内置一小份核验过的速选清单(MCP servers / marketplaces / skills),同时尽力实时列出(加了 marketplace 后 `claude plugin list --available`;有 jq 时可选 `mcp-search` 查官方 registry)。**始终允许手动 add 任意 name/url/git**。

## 架构

`claude.sh` 仍 `source lib/common.sh`、`category=ai`、以 `kit_dispatch "$@"` 收尾——因此**自动**出现在
bootstrap 目录与 `swkit`,**零 bootstrap 改动**。

### 不变量
- `install [--method native|npm]` / `remove` / `status`:CLI 本体,逻辑不动。
- 全程**用户态、无新增 sudo 路径**(claude 配置在 `$HOME`)。扩展操作**拒绝 `EUID==0 && SUDO_USER`**(避免 root 拥有 `~/.claude`),用 `SUDO_USER` 解析真实 home——同 `zsh.sh` 的 `_resolve_paths`。
- **幂等**:每个 add 先查存在(MCP 用 `claude mcp get` 退出码;plugin/marketplace 用 list 文本匹配;skill 用目录存在),每个 remove 先查存在。
- 扩展操作的前置闸:`status` 不通过则打印「先装 Claude Code(`swkit claude install`)」并退 0——同 zsh「先装 zsh」。

### 三轴

**① MCP servers**(外壳 `claude mcp`,默认 `--scope user`)
- curated 速选目录:一小份 `readonly` 表(key→transport+命令/URL+是否需 token/运行时);每项实时态由 `claude mcp get <key>` 退出码判定(0=已配)。
- `do_mcp_add <name> [--transport stdio|http|sse] [--scope s] [--env K=V]... -- <cmd…|url>`:curated 名走内置定义;否则透传给 `claude mcp add`。先 `get` 查重。
- `do_mcp_remove <name>`:先 `get` 查在,再 `claude mcp remove`。
- `do_mcp_search <term>`(可选,jq-gated):`curl` 官方 registry,列名+描述;缺 jq/网络则 `log_warn` 降级。
- 列表解析:`claude mcp list` 行形如 `<name>: <cmd|url> [(HTTP)] - <status>`;**过滤掉 `plugin:` / `claude.ai ` 前缀**(那些由插件/账户托管,非用户 `mcp add`);名取首个 `": "` 之前。

**② Plugins & marketplaces**(外壳 `claude plugin`,默认 `--scope user`)
- curated marketplaces:`anthropics/claude-plugins-official` 等;勾选→`marketplace-add <owner/repo>` / `marketplace-remove <name>`;查重读 `claude plugin marketplace list`。
- 插件:`plugin-install <name@mkt>` / `plugin-remove <name>` / `plugin-enable <name>` / `plugin-disable <name>`。
- 列表解析:`claude plugin list` 文本(`  ❯ <id>` + 其后 `Status: … enabled`);`--json` 字段(id/enabled/scope)备用。加了 marketplace 后 `claude plugin list --available` 实时列可装项。

**③ Skills**(文件式,`~/.claude/skills/<name>/`)
- 列表:扫 `*/SKILL.md`,grep/sed 读 frontmatter `name`/`description`(无依赖)。
- `skill-install <git-url|curated-name> [subdir]`:`git clone --depth=1` 到 `~/.claude/skills/<name>`;若 `SKILL.md` 不在仓根则用 `subdir` 或一层探测;已存在则跳过。多技能合集建议走插件/marketplace 轴(注明)。curated 取若干单技能仓。
- `skill-remove <name>`:确认 + 备份目录(tar 到 `~/.cache/ubuntu-setup/`)+ 删除。**护栏**:kit 自部署的 skill(`ubuntu-install`/`zsh-setup`/`claude-extensions`)**不可删**(避免破坏 kit 自身)。

### op 面(kit_dispatch)
- `meta.ops = install,remove`(仅无参主操作)。**`ui` 不入 ops**。
- 带参 op 由 `kit_dispatch` 路由到 `do_<op>`(连字符→下划线),**不进 meta.ops**,在 `usage` 文档化、在 `ui()` 里交互可达:
  `mcp-add` `mcp-remove` `mcp-search` `marketplace-add` `marketplace-remove` `plugin-install` `plugin-remove` `plugin-enable` `plugin-disable` `skill-install` `skill-remove`。

### 统一 `ui()`(沿用 `zsh.sh` 并行数组 + header/spacer + `ui_run` 退屏跑结构)
- 未装:仅 Install 行(`ui_pick` native/npm)。
- 已装:`ui_header "Claude Code · extension manager" "vX.Y ✓"`,然后:
  - 段「MCP servers」:已配置(可删,过滤托管项)→ curated 未配置(可加)→「＋ add MCP server…」(`ui_input` 名+命令/URL)。
  - 段「Plugins」:marketplaces(curated 勾选 +「＋ add marketplace…」)→ 已装插件(enable/disable/remove)。
  - 段「Skills」:已装(可删,kit 自有除外)→ curated(可加)→「＋ add skill from git…」。
  - 底部「✗ Uninstall Claude Code」。
- 受限终端:`ui_default_menu` 回退(`meta.ops` 仅 install/remove,故回退菜单只这两项——可接受,富终端才是扩展管理的主场)。
- 每个状态变更经 `ui_run "<标题>" -- "$0" <op> [args]`:退备用屏跑、可见输出 + 日志、回屏重载状态。崩溃由 `ui_begin` 的 trap 还原终端。

## 集成 / 文档 / 技能
- 新增 `skills/claude-extensions/SKILL.md`(对标 `zsh-setup`):教 LLM/用户**有品味地选** server/插件/skill,讲 token 成本、运行时(node/uv)、密钥安全、作用域、锁定安全纪律,以及如何演进 `claude.sh`。`bootstrap.sh` 的 skills 部署列表补上它。
- `skills/ubuntu-install/SKILL.md`:种子集描述里给 `claude` 加一句"现在也管理 MCP/插件/skill"的指针。
- 同步 `CLAUDE.md`「当前状态」对 `claude.sh` 的描述、`README` 种子集。

## 安全
- 零新增 sudo;扩展操作用户态,拒绝 sudo 包裹。
- 需 node/uv/token 的 server 在标签/状态如实提示;**绝不自动装 Node**(沿用 claude.sh 立场,指向 `swkit node install`);`mcp-search` 的 jq 缺失优雅降级。
- 直接改文件前 `backup_file`(基本走 CLI,极少直接改);skill 删除前备份目录 + kit 自有护栏。
- LLM 写/改本脚本仍受 skill「先计划后执行 + 用户确认 + git 可审」约束。

## 明确不做(v1 YAGNI)
- live registry 浏览界面(只留可选 `mcp-search`)。
- per-server 密钥管理 UI(经 `-e`/`--header`/CLI,密钥不入 kit 状态)。
- project-scope 的 UI 开关(默认 user;`--scope` 留给高级用户/LLM)。
- 插件 `userConfig`/`channels` 编辑、`paused` 三态(只 enable/disable)。

## 校验
`bash -n` → `shellcheck -x --source-path=SCRIPTDIR` → `claude.sh status`(装前/后)→ `meta` 字段齐全且
`ops` 与实现一致且不含 `ui` → `claude.sh ui` 无 TTY 打印指引退 0 → 伪终端冒烟 `ui` → 本机已装 claude,真跑
`mcp-add/mcp-remove`、`marketplace-add`、`skill-install/remove` 验证幂等与回退。
