# npm 全局 prefix 改用专属目录(`~/.npm-global`)

**根治 npm 全局 prefix 与 native 安装器(Claude)在 `~/.local/bin` 的碰撞。**

## 背景 / 问题

`claude update` 报 `Multiple installations found` / `Leftover npm global installation`,两行都指向**同一个** `~/.local/bin/claude`,并建议 `npm -g uninstall @anthropic-ai/claude-code`。但机器上**没有** npm 安装的 claude:`npm ls -g` 无此包、`~/.local/lib/node_modules/@anthropic-ai` 不存在。`npm -g uninstall` 因而是空操作,告警永不消除。

**根因(经实验确认):**

- kit 的 `npm_ensure_user_prefix` 在 apt node(npm 默认 prefix=`/usr`,不可写)下,把 npm 全局 prefix 设成 **`~/.local`**,其全局 bin 即 `~/.local/bin`。
- `scripts/claude.sh` 默认用**官方 native 安装器**,把 `claude` 落在 **`~/.local/bin`**(软链到 `~/.local/share/claude/versions/<ver>`)。
- Claude 更新器以 `<npm prefix>/bin/claude` 探测"是否存在 npm 全局安装",命中的其实是 native 软链 → **误报为 npm 残留**。
- 验证:`npm_config_prefix=~/.npm-global claude update` 时告警**立即消失**;PATH 去重则无效 —— 确认是 **npm-prefix 碰撞**,非 PATH 重复。

触发需三条件齐备:① apt node(prefix 不可写)→ ② 装过任一 npm 全局工具(`codegraph`/`trellis`/`codex`/`claude --method npm`)触发 `npm_ensure_user_prefix` 把 prefix 设成 `~/.local` → ③ native claude 落在 `~/.local/bin`。其中 ① 与 ③ 都由 kit 自身造成,所以这是 **kit 设计层面的结构性问题**,在任何新机器上都会复现,而非本机特例。

## 决策

把 kit 选定的 npm 全局**专属 prefix 从 `~/.local` 改为 `~/.npm-global`**(bin = `~/.npm-global/bin`),让 npm 全局 bin 与 native 安装器的 `~/.local/bin` **解耦**。`~/.local` 本是 npm 官方文档示例位置、并非错配;改用专属目录纯粹为隔离 kit 自身同时装的 native 安装器(及未来任何落 `~/.local/bin` 的 native 工具)。

**迁移范围:仅 fix-forward。** 改 kit 默认只对"prefix 仍是系统默认"的新机器生效;已在 `~/.local` 的老机器**不擅自搬动**(`~/.local` 亦是用户合法选择,符合 kit "不 clobber 自定义 prefix" 的安全原则)。本机由维护者**手动迁移**一次;其他老用户由文档指引按需手动迁。

**YAGNI:** 不建迁移命令、不改 node 渠道(仍 apt)、不动 native 安装路径。

## 改动

### `lib/common.sh`(核心)

- **`npm_ensure_user_prefix`** 系统默认分支:`target` 由 `$HOME/.local` 改为 `$HOME/.npm-global`;`mkdir -p "$target/lib/node_modules" "$target/bin"` 随之;函数内 `log_info`/错误信息/注释同步目录名。**早返回逻辑不变**(`npm_global_writable && return 0` —— prefix 已可写即 no-op):这是老机器 `~/.local` 不被改动的保证。
- **`npm_global_writable`** 的提示串改为 `npm config set prefix "$HOME/.npm-global"`。
- **新增 `ensure_npm_global_bin_on_path()`**:`prefix="$(npm config get prefix)"` → `bin="$prefix/bin"` → 上 PATH 并向 shell rc 追加守卫行。把 `ensure_local_bin_on_path` 的内体抽成私有 `_ensure_dir_on_path <dir>`,两者共用(DRY)。**动态按真实 prefix 派生** → 自定义 prefix 的用户也正确,不硬编码 `~/.npm-global`。

### npm 调用方(PATH 收尾改调新助手)

`scripts/codex.sh`、`scripts/codegraph.sh`、`scripts/trellis.sh`、`scripts/claude.sh`(npm 路径)装包后由 `ensure_local_bin_on_path` 改调 `ensure_npm_global_bin_on_path`。**native 路径**(claude/codex 的官方 native 安装,确实落 `~/.local/bin`)**保持** `ensure_local_bin_on_path`。

### 契约散文同步(改 lib 安全语义的硬性要求)

把"设到 `~/.local`"同步为 `~/.npm-global`:`CLAUDE.md`(②逐命令 sudo 段)、`skills/ubuntu-install/SKILL.md`、`README.md`、以及 `lib/common.sh` / `scripts/claude.sh` 内相关注释。旧设计 spec(如 `2026-06-18-codegraph-trellis-scripts-design.md`)为历史快照,**不改正文**,由本 spec 记录变更。

## 行为矩阵

| 机器 | npm prefix 现状 | `npm_ensure_user_prefix` 行为 | 结果 |
|---|---|---|---|
| 全新 | `/usr`(不可写,系统默认) | 设成 `~/.npm-global` | npm bin(`~/.npm-global/bin`)与 native claude 的 `~/.local/bin` 解耦,**无碰撞** ✓ |
| 老机器(本机) | `~/.local`(可写) | 早返回,**不动** | 碰撞仍在 → 本机手动迁移;其他老用户文档指引 |
| 自定义可写 prefix | 用户自设 | 早返回,**不动** | 新 PATH 助手按真实 prefix 派生 `<prefix>/bin`,正确 ✓ |

## 本机迁移(一次性,全用户态无 sudo)

1. `npm config set prefix ~/.npm-global`(写 `~/.npmrc`)
2. 删旧:`~/.local/bin/{codegraph,trellis}` + `~/.local/lib/node_modules/{@colbymchenry,@mindfoldhq}`
3. `swkit codegraph install && swkit trellis install`(落新 prefix;新助手自动把 `~/.npm-global/bin` 上 PATH,改 `~/.zshrc` 前 `backup_file`)
4. 校验

## 测试

- `bash -n` 全量;`shellcheck -x --source-path=SCRIPTDIR`(改过的 `lib/common.sh` + 4 个脚本)保持零告警。
- `codegraph` / `trellis` 的 `status` 在新 prefix 下通过。
- **`claude update` 不再报 multiple installations**。
- `swkit node status` 正常。

## 安全 / 不变量(不破坏)

- 仍**绝不 `sudo npm`**;仍用户态写 `~/.npmrc`;仍可 `npm config delete prefix` 还原。
- **不 clobber** 自定义 prefix,也不擅自搬动老机器的 `~/.local`。
- `ensure_npm_global_bin_on_path` 按 `npm config get prefix` 真实派生,不硬编码,避免对自定义 prefix 用户误写 PATH。
- `~/.local/bin` 仍由 `ensure_local_bin_on_path` 保证上 PATH(native claude/codex、uv、`swkit` 自身仍用它)。
