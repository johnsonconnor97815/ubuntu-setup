# Obsidian install/manage script

## Goal

为 ubuntu-setup 新增 **`scripts/obsidian.sh`(key=`obsidian`,category=`common`)** —— Obsidian(Markdown 知识库桌面应用)的安装/卸载/更新管理器,定位同 `cursor.sh`/`vscode.sh`/`ghostty.sh`(桌面 GUI 应用)。**纯添加**:不动 lib、不动现有脚本,TUI 经 `meta` 自动发现归类。

用户价值:在全新 Ubuntu(含 Server/SSH/无桌面)上一键装好官方 Obsidian,符合 kit 的渠道保守 / 幂等 / 实时观测 / SSH 诚实契约。

## Confirmed facts(已联网核实 2026-06-22,不再询问)

- Obsidian **无 apt 源、无 vendor apt 源**;当前稳定桌面版 1.12.7(2026-03-23 发布;**运行时动态解析,不硬编码**)。
- 官方 `.deb`:GitHub releases `obsidianmd/obsidian-releases`,资产名 `obsidian_<ver>_amd64.deb`,**仅 amd64**;装上即 `/usr/bin/obsidian` + 桌面项 + `obsidian://` handler(dpkg 触发器自动注册)。
- 官方 snap:`obsidianmd` 发布,`snap install obsidian --classic`,amd64,系统托管自动更新。
- 官方 AppImage(amd64+arm64)**不自动注册** `.desktop`/URI、集成成本高;Flathub flatpak `md.obsidian.Obsidian` 社区"已验证"、kit 暂无 flatpak 支持。→ **均不纳入**(见 design.md 的渠道取舍)。
- 更新两层:Obsidian 自带更新器只补 asar(JS 层,落 `~/.config/obsidian`),**不**更新捆绑 Electron;后者须重装 `.deb`。apt 无源不更新 → 需 `update` op 重取 `.deb`(同 `cursor.sh`)。
- **无 headless/CLI 安装路径**(纯 GUI Electron 应用);SSH/headless 下同 vscode/cursor/ghostty 仅装并诚实提示、不阻断。

## Requirements

### R1 渠道与安装(do_install)
- **arch gate**:非 `amd64` → 诚实 `log_err` 指引官方 arm64 AppImage / flathub flatpak,`return 1`(无官方 .deb/snap)。
- **amd64 主路**:GitHub releases API `grep` 取 `obsidian_*_amd64.deb`(**无 jq**)→ 下到 mktemp → `apt_install "<path>"`(解依赖、**非 `dpkg -i`**)。大 `.deb` 下载 curl 仅限连接/停滞、**不加 `--max-time`**;小 JSON API 拉取加 `--max-time 30`。
- **兜底**:主路失败且 `have_cmd snap` → `sudo_run snap install obsidian --classic`。
- 装前 `status` 闸门(已装报版本、提示用 `update`);装后 SSH 提示走安全 `if…then…fi`(防末命令退出码泄露)。

### R2 update / remove / status
- **`update`**:未装→install;dpkg 装→重取 `.deb` 覆盖、报 old→new;snap 装→`snap refresh`。
- **`remove`(保守)**:dpkg→`apt_remove`(**非 purge**,留 `~/.config/obsidian`);snap→`snap remove`;PATH 但非 dpkg/snap→`log_warn`+`return 1`;**绝不 `rm -rf` 用户数据**。
- **`status`**:`pkg_installed obsidian || snap list obsidian || have_cmd obsidian` 判已装;`KIT_PROBE_ONLY` 早返(两路径同退出码);版本走 `dpkg-query`/`snap list`,**绝不启动 GUI**;只读、查活系统。

### R3 形态与集成
- `meta.ops`=`install,remove,update`(**不含 `ui`**;**无 `configure`**——vault/设置/插件是用户的,kit 不碰);`category=common`;`desc` 英文一行(房子风格)。
- i18n `OBSIDIAN_I18N`(en/zh/ja)**5 键**(`update_row`/`confirm_remove`/`foot_install`/`foot_manage`/`ssh_note`),产品名 `Obsidian`、包名 `obsidian` 不译;架构/渠道日志保持英文 `log_*`(同 cursor)。
- `ui()` 仿 `cursor.sh`(Install / 版本行+spacer / Update / Uninstall 二次确认;`ui_run`/`ui_default_menu`/三档终端降级)。
- 提权仅 `sudo_run`(`apt_install`/`apt_remove` 内含);**无整体 sudo / 裸 apt-get / apt-key / jq**。

## Acceptance Criteria

- [x] `bash -n scripts/obsidian.sh` 通过;`shellcheck -x --source-path=SCRIPTDIR scripts/obsidian.sh` **零告警**。
- [x] `meta.ops`=`install,remove,update`,**不含 `ui`**,与实现一致(`do_install`/`do_remove`/`do_update`)。
- [x] `status` 未装退 1;`help` 退 0;`ui` 无 TTY 打印指引退 0;伪终端富屏冒烟 `q` 干净退出、渲染含 Obsidian。
- [x] `swkit search/list` 发现并归类到 `common`,desc 正确。
- [x] 多代理对抗审查(4 维 × 独立 skeptic):9 发现 → 1 确认(API curl 缺 `--max-time`)→ 已修。
- [ ] **真机行为验收**(实际下载/安装/卸载/更新、`obsidian://` 处理)需 **amd64 + 图形会话**的 Ubuntu —— 静态/契约/冒烟已过,真机待验。
