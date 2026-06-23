# Implement — Obsidian install/manage script

## 交付物

- **`scripts/obsidian.sh`(新增)** —— Obsidian 安装/卸载/更新管理器,紧贴 `cursor.sh` 范式 + `ghostty.sh` 的 GitHub-release `.deb`/snap 套路。

## 实现要点(对应 prd 的 R1–R3)

- **渠道**:amd64 主路官方 `.deb`(`_obsidian_resolve_deb` 从 GitHub API `grep` 取 `obsidian_*_amd64.deb`、无 jq;`_obsidian_install_deb` 下到 mktemp → `apt_install "$deb"`)→ snap `--classic` 兜底;非 amd64 诚实拒绝。API 拉取 `--max-time 30`,大下载不加 `--max-time`(用 `--speed-limit/--speed-time -C -`)。
- **update**:dpkg 装→重取 `.deb` 覆盖、报 old→new;snap 装→`snap refresh`;未装→install。
- **remove**:`pkg_installed`→`apt_remove`(留 `~/.config/obsidian`)/ snap→`snap remove` / unmanaged→warn+return1。
- **status**:三路探测(`pkg_installed`/`snap list`/`have_cmd`)+ `KIT_PROBE_ONLY` 早返;版本走 `dpkg-query`/`snap list`,零 GUI。
- **SSH**:`_obsidian_where_note` 用安全 `if…then…fi`。
- **i18n**:`OBSIDIAN_I18N` en/zh/ja 5 键,名不译。
- **ui()**:仿 cursor(Install / 版本行+spacer / Update / Uninstall 二次确认)。
- **meta**:`key=obsidian` `name=Obsidian` `category=common` `ops=install,remove,update`,英文 desc。

## 验证(静态 / 契约 / 冒烟,全过)

| 检查 | 结果 |
|---|---|
| `bash -n`(含全仓) | 通过 |
| `shellcheck -x --source-path=SCRIPTDIR scripts/obsidian.sh` | **零告警** |
| `meta`/`ops`↔实现 parity / `ops` 无 `ui` | ✓ install,remove,update |
| `status` 未装退 1 / `help` 退 0 / `ui` 无 TTY 退 0 | ✓ |
| 伪终端富屏冒烟(`q` 退出,`timeout` 包裹) | rc=0 不挂死、渲染含 Obsidian |
| `swkit search/list` 发现归类 common | ✓ |

## 修复记录

- 对抗审查确认 1 项:`_obsidian_resolve_deb` 的 API JSON 拉取缺读取上限 → 补 `--max-time 30`(小而有界 JSON 安全;大 `.deb` 下载仍不加,见注释)。

## 未尽 / 边界

- **真机行为验收**(实际下载/安装/卸载/更新、`obsidian://`)需 **amd64 + 图形会话**;当前为静态+契约+冒烟级保证。
- 故意不纳入 AppImage / flatpak 渠道与 arm64(诚实拒绝);无 `configure`(vault 是用户的)。
- 后续若纳入 arm64,须新增 AppImage 路径(放置 + 写 `.desktop` + 注册 URI + FUSE 依赖 + 独立 update)。
