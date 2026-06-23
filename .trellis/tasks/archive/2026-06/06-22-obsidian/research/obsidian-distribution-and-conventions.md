# Obsidian 分发现状 + 仓库范例惯例(研究持久化)

来源:并行研究 workflow(联网核实 + 仓库勘察),2026-06-22。

## A. Obsidian Linux 分发(已联网核实)

当前稳定桌面版 **1.12.7**(2026-03-23)。**运行时动态解析版本,不硬编码。**

| 渠道 | 官方 | 架构 | 自动更新 | 桌面项/`obsidian://` | 取舍 |
|---|---|---|---|---|---|
| **官方 `.deb`**(GitHub releases `obsidianmd/obsidian-releases`)| ✅ | **仅 amd64** | 无(apt 无源;需 `update` 重取)| **dpkg 触发器自动注册** | **采用为主路** |
| 官方 AppImage | ✅ | amd64+arm64 | 无 | **不自动注册**(须手写 `.desktop`+注册 URI)| 不纳入(集成成本高) |
| Flathub flatpak `md.obsidian.Obsidian` | 社区"已验证" | amd64+arm64 | flatpak 自管 | 自动 | 不纳入(kit 无 flatpak 支持) |
| Snap(`obsidianmd` 官方发布)| ✅ | amd64 | **系统托管自动更新** | 自动 | **采用为兜底** |

- `.deb` 资产 URL 形如 `…/releases/download/v<ver>/obsidian_<ver>_amd64.deb`;经 GitHub API `releases/latest` 的 `browser_download_url` 用 `grep -oE 'https://[^"]*obsidian_[^"/]*_amd64\.deb'` 取(**无 jq**)。`releases/latest` 排除 prerelease/insider。
- **更新两层模型**(决定为何需 `update` op):
  - Layer 1(app/web):Obsidian 自带更新器只下小 asar 到 `~/.config/obsidian`,与渠道无关,补特性/点版本。
  - Layer 2(installer/framework):捆绑 Electron/Chromium **不被** in-app 更新器更新,须重装 `.deb`。apt 无源 → 脚本需 `update` 重取最新 `.deb`。
- arm64:无官方 `.deb`、无官方 snap;仅 AppImage/flatpak。→ 脚本经 `dpkg --print-architecture` 在非 amd64 上诚实拒绝并指引。
- **无 headless/CLI 安装路径**:1.12.4+ 内置 `obsidian-cli` 是运行中 GUI 的控制器(需图形进程 + 手动开启);`obsidian-headless` 是独立 npm 包(付费 Sync/Publish 客户端)。均非无图形安装/运行方式 → 按纯 GUI Electron 应用对待。

来源:obsidian.md/download、/help/install、/help/updates、/help/cli、/help/headless;github.com/obsidianmd/obsidian-releases/releases;flathub.org/apps/md.obsidian.Obsidian;snapcraft.io/obsidian。

## B. 仓库范例惯例(最贴近 = `cursor.sh`)

- **`cursor.sh`**(vendor `.deb` + `update` op):`_cursor_resolve_deb` 从下载 API `grep` 取 `.deb` URL(无 jq)→ `_cursor_install_deb` 下到 mktemp → `apt_install "$deb"`。`update` 重取覆盖。**API 拉取用 `--max-time 30`**;**大 `.deb` 下载故意不加 `--max-time`**,改用 `--speed-limit 1024 --speed-time 60 --retry … -C -`。SSH 提示用安全 `if…then…fi`(末命令 `&&` 会泄露 false 退出码使本地成功安装误报退 1,见 cursor.sh:82-86)。`status` 优先 `pkg_installed`(零 GUI),`KIT_PROBE_ONLY` 早返。`ui()` 平行 `dkind`/`dlabel` 数组、跳过 `status`/`spacer` 行、动作经 `ui_run`、remove 经 `ui_confirm`。
- **`ghostty.sh`**(多渠道 highest-wins):`_ghostty_install_deb` 从 **GitHub releases API** `grep` 资产 URL → `apt_install`;`do_remove` 按实时来源分支(`pkg_installed`→`apt_remove` / snap→`sudo_run snap remove` / 否则 `log_warn`+`return 1`)。**这是 Obsidian 的 .deb 在 GitHub releases 该借的套路。**
- **`vscode.sh`**:`status` 的 `KIT_PROBE_ONLY` 早返范式(boolean 早返,版本 spawn 在后)。

## C. 关键 lib helper

`apt_install ARGS…`(**接受本地 `.deb` 路径**:含 `/` 即被 apt 当文件、解依赖)、`apt_remove`(remove 非 purge)、`have_cmd`、`pkg_installed`(仅 dpkg `install ok installed`)、`sudo_run`(唯一提权途径,内含于 apt_install/apt_remove)、`log_info/warn/err`、`kit_dispatch`(末行;路由 meta/status/install/remove/update/help/ui,未知 op→`do_<x>`)、`KIT_PROBE_ONLY`(目录缓存探测时只算安装布尔)。

## D. 项目坑位(实现必避)

- 无 jq;无 `dpkg -i`(用 `apt_install <path>`);无整体 sudo / 裸 apt-get / apt-key。
- SSH 提示末命令用 `if…then…fi`(最易埋的退出码泄露 bug)。
- `ui` **不进** `meta.ops`;`ops` 恰列实现项。
- `status` 查活系统、只读、`KIT_PROBE_ONLY` 两路径退出码一致。
- 保守 remove:留 `~/.config/obsidian`,unmanaged→warn+return1,绝不 `rm -rf`。
- arch 经 `dpkg --print-architecture`,非 amd64 即 `return 1` 诚实报错。
- i18n 只译描述措辞,产品/包名不译。
