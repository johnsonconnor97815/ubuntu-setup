# Neovim 管理脚本 (scripts/nvim.sh)

## Goal

为 ubuntu-setup kit 新增 `scripts/nvim.sh`,把「在全新 / 既有 Ubuntu 上安装、配置、管理 Neovim 及其配置与插件」收敛为一个符合 kit 安全契约的**组件管理脚本**,三入口(bootstrap TUI / swkit / LLM skill)统一调用。对标 ghostty / tmux / rime 那一档(安装器 + `configure` + 组件管理 + 自有 `ui()`)。

## Confirmed facts(已联网查证 2026-06-23)

### 版本与渠道
- Neovim 最新 stable = **0.12.3**(2026-06-10);GitHub release `stable` / `v0.12.3` tag。
- 官方 GitHub release Linux 资产(**现行命名**):`nvim-linux-x86_64.tar.gz` / `.appimage`、`nvim-linux-arm64.tar.gz` / `.appimage`(+ `.appimage.zsync`)。官方 INSTALL 首推 tarball 解到 `/opt` + PATH;AppImage 需 FUSE(老系统可 `--appimage-extract`)。
- apt(Ubuntu archive):26.04 = 0.11.6;24.04(noble)≈ 0.9.5(偏旧);更旧 Ubuntu 更旧。
- PPA `neovim-ppa/stable`:已陈旧 / 不可靠(最高 ~0.7.2、无 26.04 Release)→ **不用**。
- PPA `neovim-ppa/unstable`:0.12.0-dev **每日构建**,覆盖 22.04/24.04/25.04/25.10/26.04;是 dev 非 stable;签名指纹 `9DBB0BE9366964F134855E2255F96FCF8231B6DD`。
- snap:`snap install nvim --classic`,落后 upstream。
- **含义**:现代配置 / distro(LazyVim 等)需较新 neovim;旧 Ubuntu 的 apt 版本不够 → 渠道需能拿到较新版本。

### 配置与插件生态
- 配置目录 `~/.config/nvim`(受 `NVIM_APPNAME` 控制子目录,默认 `nvim`);数据 / 状态 / 缓存在 `~/.local/share/nvim`、`~/.local/state/nvim`、`~/.cache/nvim`。
- 多配置共存权威机制 = **NVIM_APPNAME**:装到 `~/.config/nvim-<name>`,以 `NVIM_APPNAME=nvim-<name> nvim` 启动(配 alias),不动用户默认 `~/.config/nvim`。
- 主流 starter / distro:LazyVim(`LazyVim/starter`)、kickstart.nvim(`nvim-lua/kickstart.nvim`)、AstroNvim(`AstroNvim/template`)、NvChad(`NvChad/starter`);LunarVim 已停维护(排除)。
- 插件管理器:几乎全部用 **lazy.nvim**;distro 自带,首次启动自动 bootstrap;可 headless 驱动 `nvim --headless "+Lazy! sync" +qa`(及 `update` / `clean`)。

### kit 范式可复用
- vendor 二进制下载范式见 `cursor.sh`(curl + 校验 + 安装、`update` op);受管配置 + `config-file` include 见 `ghostty.sh`;受管块 / 组件 / i18n / 带参 op / `ui()` 见 `tmux.sh`;opt-in git clone + manifest 精确卸载 + 用户态 guard 见 `rime.sh`。
- lib helper:`apt_install` / `apt_remove` / `apt_update_once`、`add_apt_keyring` / `add_apt_source`、`sudo_run`、`backup_file`、`append_once`、`have_cmd` / `pkg_installed`、`kit_dispatch`、`RC_NEED_SUDO`、`KIT_PROBE_ONLY`、`KIT_SCRIPTS_DIR`、`fonts.sh`(Nerd Font)。

## Requirements(初步,随 brainstorm 收敛)

- 标准 kit 脚本接口 + 自有 `ui()`;`category=common`(编辑器,同 vscode/cursor)。
- `install` / `remove` / `status`:**择优 + 版本闸**装 neovim 本体 —— apt 候选 ≥ 门槛则 apt,否则官方 stable tarball(`/opt` + PATH + sha256 校验 + `update` op),再回退 snap `--classic`;打印所用渠道;幂等;用户配置不动。
- **配置 / 插件管理 = distro 安装器模式(已定)**:
  - curated distro / starter opt-in 安装(`git clone`),改前整目录 `backup_file`、manifest 记录可精确卸载;默认隔离到 `~/.config/nvim-<name>`(NVIM_APPNAME),不覆盖用户 `~/.config/nvim`;可显式装到默认 `~/.config/nvim`。
  - 「插件管理」= 驱动 distro 内置 lazy.nvim:`nvim --headless "+Lazy! sync/update/clean" +qa`(及首次 bootstrap)。
  - kit **不**逐行解析 / 改写 distro 的 lua。
  - 受管 alias(`nvim-<name>`)经标记行写入 shell rc(对标 go.sh `ensure-path`),便于启动隔离配置。
- **默认编辑器联动**:`set-default-editor [off]` —— 用户态写 `EDITOR` / `VISUAL`=nvim 到 shell rc 受管行 + best-effort `sudo update-alternatives` 注册 / 设 `editor`(tarball 装的先 `--install`);`off` 反转。
- **外部依赖(configure 确保)**:distro 需 git / curl / C 编译器 / ripgrep / fd-find / 可选 Nerd Font;`--recommended` 一并装。绝不自动装 Node(Mason LSP 的 runtime 属 opt-in,缺则指路 `swkit node install`)。
- 全程遵守安全契约(逐命令 sudo、非交互 apt、改前备份、用户态不 sudo、下载校验为信任边界)。

## Acceptance criteria(初步)

- [ ] `bash -n` / `shellcheck -x` 零告警;`meta.ops` 与实现一致且不含 `ui`;`status` 可独立运行且 `KIT_PROBE_ONLY` 早返;`ui` 无 TTY 退 0。
- [ ] 在本机真实安装 / 卸载 neovim 成功、幂等重跑 no-op。
- [ ] 渠道择优 + 版本闸正确(apt 候选 ≥0.11.2 走 apt、否则 tarball;tarball 经 API 动态 sha256 校验通过才安装)。
- [ ] `install-distro` 智能默认:全新机接管 `~/.config/nvim`、既有配置隔离到 `nvim-<name>` + alias;`remove-distro` 按 manifest 精确卸载、改前备份。
- [ ] headless lazy 同步可驱动;`set-default-editor` 双向可逆。
- [ ] 配置 / 插件管理按选定范围可用、用户既有配置安全(备份、可精确卸载)。

## Out of scope(初步)

- 多发行版(仅 Ubuntu/Debian)。
- 在用户机器运行时由 LLM 写 / 改脚本。
- (待定)kit 不自行逐行解析 / 改写 distro 的 lua 配置。

## Open questions(blocking planning)

1. ✅ **配置 / 插件管理模型** → distro 安装器模式(经 NVIM_APPNAME 隔离、opt-in clone + manifest、lazy.nvim headless 驱动)。
2. ✅ **安装渠道策略** → 择优 + 版本闸(apt 够新→apt,否则官方 stable tarball,回退 snap;tarball 先于 snap)。
3. ✅ **范围细节** → 隔离 = 智能默认(全新机接管默认 `nvim`、既有配置隔离到 `nvim-<name>`);curated distro = LazyVim / kickstart / AstroNvim / NvChad(+任意 git-url),`--recommended` 装 LazyVim;含「设为系统默认编辑器」联动。

所有 open questions 已解决 → 见 `design.md` / `implement.md`。
