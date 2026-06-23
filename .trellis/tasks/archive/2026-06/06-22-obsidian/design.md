# Obsidian 安装管理脚本(`scripts/obsidian.sh`)

日期:2026-06-22
状态:已批准设计(经联网核实分发现状 + 仓库惯例研究敲定),待实现

## 目标

新增 `scripts/obsidian.sh`,把 **Obsidian**(Markdown 知识库桌面应用)纳入脚本集合,提供统一接口的安装 / 卸载 / 更新。定位同 `cursor.sh`/`vscode.sh`/`ghostty.sh`——**桌面 GUI 应用**(`category=common`),SSH/headless 下仅安装并诚实提示、不阻断。

**这是纯添加**:不动 lib、不动任何现有脚本;新增一个脚本文件,TUI 经 `meta` 自动发现归类。

## 已联网核实的分发事实(2026-06-22)

Obsidian **无 apt 源、无 vendor apt 源**,故本项目渠道优先级的前两档不可用。当前稳定桌面版 **1.12.7**(2026-03-23 发布;**不硬编码**,运行时动态解析)。

| 渠道 | 官方 | 架构 | 自动更新 | 桌面项 / `obsidian://` | 契合 |
|---|---|---|---|---|---|
| **官方 `.deb`**(GitHub releases `obsidianmd/obsidian-releases`)| ✅ | **仅 amd64** | 无(apt 不托管;需 `update` 重取)| **dpkg 触发器自动注册** | **最佳**,等同 `cursor.sh` |
| 官方 AppImage | ✅ | amd64 + arm64 | 无 | **不自动注册**(须手写 `.desktop` + 注册 URI)| 最差,集成成本高 |
| Flathub flatpak `md.obsidian.Obsidian` | 社区"已验证" | amd64 + arm64 | flatpak 自管 | 自动 | kit 目前无 flatpak 支持 |
| Snap(`obsidianmd` 官方发布)| ✅ | amd64 | **系统托管自动更新** | 自动 | 契合 snap 档,作兜底 |

**更新两层模型**(决定为何需要 `update` op):Obsidian 自带更新器只补 asar(JS 层,落 `~/.config/obsidian`),**不**更新捆绑的 Electron/Chromium('installer version');后者必须重装 `.deb`/AppImage。apt 无源不会更新它,故 `.deb` 安装需显式 `update` op 重取最新 `.deb`(照 `cursor.sh`)。

**无 headless/CLI 安装路径**:Obsidian 现有两个命令行面(1.12.4+ 的内置 `obsidian-cli` 是运行中 GUI 的控制器、需图形进程 + 手动开启;`obsidian-headless` 是独立 npm 包、面向付费 Sync/Publish),**均非**无图形安装/运行方式。脚本按纯 GUI Electron 应用对待。

来源:obsidian.md/download、obsidian.md/help/install、github.com/obsidianmd/obsidian-releases/releases、flathub.org/apps/md.obsidian.Obsidian、snapcraft.io/obsidian、obsidian.md/help/cli、obsidian.md/help/headless。

## 渠道策略(选定:`.deb` 主 + snap 兜底,amd64;arm64 诚实拒绝)

```
amd64:
  1. 官方 .deb(GitHub releases) ──成功──▶ /usr/bin/obsidian
       · obsidian:// + 桌面项自动注册
       · update = 重取最新 .deb
  2. 主路失败且 have_cmd snap ▶ snap install obsidian --classic
       · 系统托管自动更新
arm64 / 其它:
  无官方 .deb、无官方 snap → 诚实 log_err + 指引手装 AppImage/flatpak,return 1
```

取舍:AppImage 路径(放置文件 + 手写 `.desktop` + 注册 `obsidian://` + FUSE 依赖 + 独立 update)代码量与攻击面最大,**故意不纳入**;arm64 走诚实拒绝(`cursor.sh` 的 arch-gate `return 1` 范式),把复杂度挡在门外。

## 脚本形态

- **meta**:`key=obsidian` `name=Obsidian` `category=common` `ops=install,remove,update`,`desc` 英文一行(同 cursor/ghostty/vscode 房子风格):`Obsidian — the Markdown knowledge base (official .deb from GitHub releases; 'update' fetches the latest)`。
- **`ops` 恰列实现项,不含 `ui`**(`ui` 是入口模式,经 `kit_dispatch` 路由,无 `do_ui`)。
- **无 `do_configure`**:Obsidian 的 vault / 设置 / 插件 / 主题都在 `~/.config/obsidian`,是用户的,kit **不碰**——没有 kit 可管的配置面。
- 闭包结构沿用 `TEMPLATE.sh`:`#!/usr/bin/env bash` + `set -Eeuo pipefail` + 定位并 `source` lib + `meta`/`status`/`do_install`/`do_remove`/`do_update`/`usage`/`ui` + 末尾 `kit_dispatch "$@"`。

## `do_install`

1. **status 闸门**(先行,同 `cursor.sh`):已装则 `log_info` 报版本 + 提示用 `update`,`return 0`。先于 arch gate 还有一个好处:手装的 arm64 AppImage 会被 `status` 经 `have_cmd obsidian` 识别为已装,从而正确报「已装、用 update」而非误报架构不支持。
2. **arch gate**:`dpkg --print-architecture` 非 `amd64` → `log_err`(无官方 .deb/snap;指引官方 AppImage 或 flathub `md.obsidian.Obsidian`)+ `return 1`。两道闸都在任何副作用(curl/下载/apt)之前。
3. **确保 curl**:`have_cmd curl || apt_install curl ca-certificates`。
4. **主路 · 解析并装 .deb**(`_obsidian_resolve_deb` + `_obsidian_install_deb`,仿 `ghostty._ghostty_install_deb`):
   - curl `https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest`,`grep -oE 'https://[^"]*obsidian_[^"/]*_amd64\.deb'` 取首个资产 URL(**无 jq**)。
   - curl flags:`-fSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 --retry 3 --retry-delay 5 --retry-all-errors -C -`,**不加 `--max-time`**(墙钟上限会中断健康的慢下载)。
   - 下到 `tmp=$(mktemp -d)` 的 `obsidian.deb` → `apt_install "$tmp/obsidian.deb"`(slash 路径被 apt 当本地文件、解依赖、可净卸)→ `rm -rf "$tmp"`、透传 rc。
   - 打印所用渠道与版本(`log_info`)。
5. **兜底 · snap**:主路失败且 `have_cmd snap` → `sudo_run snap install obsidian --classic`;snap 不可用则带失败原因 `return 1`。
6. **装后**:`log_info` 提示从应用菜单或 `obsidian` 启动、日后 `swkit obsidian update` 升级;**末命令** SSH 提示走安全 `if _obsidian_in_ssh; then log_warn …; fi`(避免 `&&` 末命令泄露 false 退出码,见坑位)。

## `do_update`

- 未装 → 调 `do_install`(install-if-absent)。
- `pkg_installed obsidian` → 重解析最新 `.deb` 并 `apt_install` 覆盖当前版,报 old→new(`dpkg-query` 读旧版)。
- snap 装的(`have_cmd snap && snap list obsidian` 命中)→ `sudo_run snap refresh obsidian`。
- 末命令同样走安全 `if…then…fi` 的 SSH 提示。

## `do_remove`(保守)

1. **status 闸门**:未装 → `log_info`「未安装,无需卸载」+ `return 0`。
2. **按实时来源分支**(绝不依据记录标志):
   - `pkg_installed obsidian` → `apt_remove obsidian`(**`remove` 非 `purge`**,留 `~/.config/obsidian`),`log_info` 说明配置保留。
   - 否则 `have_cmd snap && snap list obsidian` → `sudo_run snap remove obsidian`。
   - 否则在 PATH 但非 dpkg/snap(AppImage/手装)→ `log_warn` 指引按原安装方式卸、配置保留 + `return 1`。
3. **绝不 `rm -rf` 用户数据**。

## `status`

- 已装判据:`pkg_installed obsidian || { have_cmd snap && snap list obsidian >/dev/null 2>&1; } || have_cmd obsidian`;任一成立退 0,否则退 1。
- **`KIT_PROBE_ONLY` 早返**:`[[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0`,置于任何版本探测**之前**;两条路径退出码一致。
- 版本展示:dpkg 装的 `dpkg-query -W -f='${Version}' obsidian`;snap 装的解析 `snap list obsidian`;**绝不启动 GUI** 取版本。
- 只读、查活系统、无副作用(被缓存、被 install/remove 闸门复用)。

## SSH / 架构

- `_obsidian_in_ssh()`=`[[ -n "${SSH_CONNECTION:-}${SSH_TTY:-}${SSH_CLIENT:-}" ]]`。
- `_obsidian_where_note()` 用 `if _obsidian_in_ssh; then log_warn "$(_obsidian_t ssh_note)"; fi` 形式;**凡作为 `do_install`/`do_update` 的末命令必须用此 if-form**(裸 `&&` 末命令会把非 SSH 的 false 退出码经 `set -e` 上抛,使本地成功安装误报退 1——`cursor.sh:82-86` 记录此坑)。
- ssh_note 诚实措辞:Obsidian 是桌面 GUI,SSH 下窗口跑在有显示器的机器(X11/Wayland 转发或本地运行)。
- 不按 `DISPLAY` 阻断安装——`.deb`/snap 照装,只 `log_warn`。

## i18n

- 本地表 `OBSIDIAN_I18N`(en/zh/ja)+ `_obsidian_t`,结构同 `cursor.sh`/`ui_t`,**5 个键(与 cursor.sh 一致)**:`update_row` / `confirm_remove` / `foot_install` / `foot_manage` / `ssh_note`。
- 架构拒绝与渠道/版本日志保持英文 `log_*`(**不**经 `_obsidian_t`,同 cursor.sh——这类操作性日志全项目英文)。
- **只译描述性措辞**;产品名 `Obsidian`、包名 `obsidian` 不译。

## `ui()`

几乎照搬 `cursor.sh` 的 `ui()`:
- `if ! ui_supported; then ui_default_menu; return 0; fi` 起手,`ui_begin`/`ui_end` 包住循环。
- **未装**:Install 行。
- **已装**:不可选的版本 `status` 行 + 导航**跳过**的 `spacer` + Update 行 + Uninstall 行(`ui_confirm "$(_obsidian_t confirm_remove)" n` 二次确认,文案点明留 `~/.config/obsidian`)。
- 每个状态变更经 `ui_run "<标题>" -- "$0" <op>`(退屏跑、可见输出 + 日志、回屏重载状态)。
- 无 TTY 时(`kit_dispatch ui` 在无 TTY)打印「用 swkit obsidian <op>」指引并退 0。

## 不可妥协项(lib 强制 + CLAUDE.md 契约)

- 无 `sudo` 整体包裹、无裸 `sudo`/`apt-get`/`apt-key`;提权只经 `sudo_run`(`apt_install`/`apt_remove` 已内含)。
- `.deb` 经 `apt_install "<路径>"`(解依赖、可净卸),**绝不 `dpkg -i`**。
- **无 jq**(grep 解析 GitHub API);curl 前 `have_cmd curl || apt_install curl ca-certificates`。
- arch 经 `dpkg --print-architecture` 映射,非 amd64 即 `return 1` 诚实报错。
- 幂等:`do_install`/`do_remove`/`do_update` 闸在 `status` 上;重跑安全。
- `status` 查活系统、只读、`KIT_PROBE_ONLY` 两路径退出码一致。

## 测试与验收

静态 / 契约(必过,无需图形会话):
1. `bash -n scripts/obsidian.sh`。
2. `shellcheck -x --source-path=SCRIPTDIR scripts/obsidian.sh lib/common.sh lib/cache.sh lib/ui.sh`(保持零告警)。
3. `scripts/obsidian.sh meta` 字段齐全、`ops` 与实现一致(`install,remove,update`)、**`ops` 不含 `ui`**。
4. `scripts/obsidian.sh status` 可独立运行(装前退非 0)。
5. `scripts/obsidian.sh help` 不炸。
6. `scripts/obsidian.sh ui` 在无 TTY 下打印指引退 0。
7. 伪终端冒烟:`printf 'q' | timeout 10 ... script -qec 'scripts/obsidian.sh ui' /dev/null`——渲染不崩、`q` 干净退出、终端复原(**`timeout` 包裹**,见项目记忆:某些交互 ui 不被 `q` 退出)。

**真机行为验收**(实际下载 / 安装 / 卸载 / 更新)需 **amd64 + 图形会话**的 Ubuntu:`install`→`status` 报版本→桌面菜单可见 Obsidian、`obsidian://` 可被处理→`update`→`remove` 保留 `~/.config/obsidian`。snap 兜底需在 `.deb` 解析失败或无网时另测。arm64 拒绝路径可在 arm64(或伪造 `dpkg --print-architecture`)上验证报错措辞。
