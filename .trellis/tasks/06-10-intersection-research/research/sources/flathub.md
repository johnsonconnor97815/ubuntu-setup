# flathub 源采集笔记（2026-06-10）

## 抓取过程
- `GET https://flathub.org/api/v2/collection/popular?page=1..2&per_page=100`：官方 popular 榜，按近 30 天安装数 `installs_last_month` 降序，取前 200 条候选。
- 用 `GET https://flathub.org/api/v2/stats/{app_id}` 抽查交叉验证（vscode：榜内 64849 vs 端点 65116；discord：189135 vs 190479，仅为缓存时差，数据一致），未再依赖 flatstat.mijorus.it 第三方前端。
- `GET https://flathub.org/api/v2/stats` 仅有全站总量（总下载 43.0 亿、3539 个应用），无逐应用榜单，故榜单以 collection/popular 为准。

## 判读说明
- metric = `installs_last_month`（近 30 天安装数），metric_unit=downloads；Flathub 的"安装"计数实质是下载次数，含更新/重装/镜像抓取，非去重装机量。
- 收录：从前 200 名里按任务规则剔除游戏与模拟器壳（Sober/Roblox、Heroic、Lutris、Prism Launcher、RetroArch、Dolphin、PPSSPP、PCSX2、xemu、melonDS、ScummVM、Protontricks、ProtonUp-Qt、ProtonPlus、PortProton、Minecraft 系、Moonlight、Modrinth、Vinegar、Hidamari 等），保留浏览器/通讯/媒体/创作/办公/系统工具类通用桌面应用，最终 65 条（约覆盖到原榜第 88 名）。Steam 因属对齐示例予以保留；Wine/Bottles 作为通用 Windows 应用兼容层保留。
- 合并：Thunderbird 在 Flathub 有 ESR（org.mozilla.thunderbird_esr，第 8 名）与常规（org.mozilla.thunderbird，第 75 名）两个应用，合并为 canonical `thunderbird`，metric 加总（121385+22278=143663）。
- 命名：canonical 按任务对齐示例（chrome、vscode、obs-studio…）；`edge` 对齐 `chrome` 的短名风格；`bazaar` 指 Flathub 商店前端（io.github.kolunmi.Bazaar），与 VCS bzr 无关。aliases 含 flatpak app id 与常见 apt/Arch 包名。

## 局限
- Flatpak 用户群偏游戏/模拟器：原榜第 1 名是 Roblox 启动器 Sober，前 30 名近半为游戏/模拟器，通用应用排名被挤压。
- Ubuntu 默认 snap 生态有渠道偏移：Ubuntu 用户同类软件多走 snap/apt，Flathub 数字低估其在 Ubuntu 上的真实流行度。
- CLI 不可见：Flathub 只分发 GUI 应用，CLI 工具/运行时/工具链在本源完全缺位，本源只能贡献 GUI 维度票数。
- metric 是近 30 天流量而非历史累计，对老牌应用（如 GIMP、VLC）相对不利、对新晋应用（如 Zen）相对有利。
