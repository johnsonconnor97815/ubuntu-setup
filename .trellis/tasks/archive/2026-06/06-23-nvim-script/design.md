# Design — scripts/nvim.sh(Neovim 组件管理器)

对标 `ghostty.sh`(渠道择优 + 受管配置)/ `tmux.sh`(组件 / i18n / 带参 op / ui)/ `rime.sh`(opt-in clone + manifest + 用户态 guard)/ `cursor.sh`(vendor 二进制下载 + update)。纯 bash,`source lib/common.sh`。

## 1. 总体架构

- `category=common`(编辑器,同 vscode/cursor)。
- **两层职责**:
  1. **neovim 本体**(系统级,经 `sudo_run`):择优 + 版本闸装 / 卸 / 更新。
  2. **配置 + 插件**(用户态,`_nvim_user_guard`):distro 安装器(opt-in clone + manifest)、lazy 插件同步、外部依赖、默认编辑器联动。
- 所有"昂贵详情"在 `status` 经 `KIT_PROBE_ONLY` 早返跳过。

## 2. 路径与状态

用户态全部经 `_nvim_user_guard`(认 `SUDO_USER` 解析真实 home,`EUID==0 && SUDO_USER` 时拒绝并提示以本人身份重跑,范式见 `rime.sh:343` `_rime_resolve_home`)。派生:

- `_NVIM_CFG_HOME=$HOME/.config`、`_NVIM_DATA_HOME=$HOME/.local/share`、`_NVIM_STATE_HOME=$HOME/.local/state`、`_NVIM_CACHE_HOME=$HOME/.cache`(尊重 `XDG_*` 若设)。
- 偏好 / manifest:`~/.config/ubuntu-setup/nvim.conf`(`KEY=VALUE`,grep 读不 source,范式见 tmux/rime)。记录:
  - `CHANNEL=`(末次本体安装渠道:apt|tarball|snap,仅供显示)
  - `DEFAULT_EDITOR=`(on|off)
  - `DISTROS=`(空格分隔的已装 `appname:distroname` 列表,作 manifest)
- distro 安装目录:`~/.config/<appname>`(appname 默认 `nvim` 或隔离 `nvim-<name>`);数据 / 状态 / 缓存在 `~/.local/{share,state,cache}/<appname>`。
- tarball 安装根:`/opt/nvim-linux-<arch>`,symlink `/usr/local/bin/nvim`(系统级,经 sudo)。
- 受管 rc:alias 行与 `EDITOR`/`VISUAL` 行经 marker + `backup_file` + `grep -qxF` 写入用户 shell rc(范式见 `go.sh do_ensure_path`)。

## 3. neovim 本体:渠道择优 + 版本闸

`NVIM_MIN_VERSION=0.11.2`(满足全部 curated distro,见 prd 查证)。`_nvim_arch`:`dpkg --print-architecture` → `amd64`→`x86_64`、`arm64`→`arm64`(其余报错)。

### do_install(择优,打印所用渠道)
1. **apt**:`LC_ALL=C apt-cache policy neovim` 取 `Candidate:`,`_nvim_vercmp` 比较 ≥ `NVIM_MIN_VERSION` → `apt_install neovim`,`CHANNEL=apt`。(`LC_ALL=C` 避免本地化文案误判,铁律同 rime/android。)
2. 否则 **官方 stable tarball**(`_nvim_install_tarball`):
   - 从 GitHub API `https://api.github.com/repos/neovim/neovim/releases/tags/stable` 取 JSON;解析目标 asset(`nvim-linux-<arch>.tar.gz`)的 `browser_download_url` 与 `digest`(`sha256:<hex>`)。**stable tag 滚动 → 不硬编码 sha256/版本**。
     - 解析无 jq:用 `grep`/`sed` 在 asset 名锚定的块内取 `browser_download_url` 与 `digest`(参 cursor.sh 的 `grep -oE` 风格;digest 形如 `"digest":"sha256:..."`)。若 API 不可达 / 解析失败 → fail-fast 报错(不回退无校验下载)。
   - `curl -fSL --retry 3 -C -` 下到 `mktemp -d`;`printf '%s  %s' "$hex" "$file" | sha256sum -c -` 校验(**信任边界**,参 android.sh 的"解压即执行需校验")。
   - `sudo_run rm -rf /opt/nvim-linux-<arch>`;`sudo_run tar -C /opt -xzf <file>`;`sudo_run ln -sfn /opt/nvim-linux-<arch>/bin/nvim /usr/local/bin/nvim`。`CHANNEL=tarball`。
   - 旧 glibc 机器:`nvim --version` 失败时 `log_warn` 指向 `neovim/neovim-releases`(unsupported),不自动兜底。
3. 否则回退 **snap**:`sudo_run snap install nvim --classic`,`CHANNEL=snap`。
4. 全程 `log_info` 打印最终渠道。

### status
`have_cmd nvim || return 1`;`KIT_PROBE_ONLY` 早返 0;否则 `nvim --version | head -n1` + 探测渠道(dpkg / snap / `/usr/local/bin/nvim` symlink)+ 已装 distro 计数。两路径退出码一致。

### do_remove(保守)
按来源择一:`pkg_installed neovim`→`apt_remove neovim`;snap→`sudo_run snap remove nvim`;tarball→`sudo_run rm -rf /opt/nvim-linux-<arch>` + 删 symlink。**保留** `~/.config/nvim*`(用户配置)与 distro 目录;打印彻底清理指引。

### do_update(进 meta.ops)
仅 tarball 渠道有意义(apt/snap 随系统更新,检测到则 `log_info` 提示用 `apt upgrade`/`snap refresh`);tarball 渠道 → 重跑 `_nvim_install_tarball`(重取最新 stable + 校验 + 覆盖)。

## 4. 配置 + 插件:distro 安装器

curated 表(`_NVIM_DISTROS`,name→repo):
- `lazyvim` → `https://github.com/LazyVim/starter`
- `kickstart` → `https://github.com/nvim-lua/kickstart.nvim`
- `astronvim` → `https://github.com/AstroNvim/template`
- `nvchad` → `https://github.com/NvChad/starter`

### do_install_distro <name> [appname](带参,kit_dispatch 路由)
- 校验 name(curated 或 conf 里 `EXTRA_DISTRO_<name>` 记录的任意 git-url);name/appname 正则 `^[A-Za-z0-9._-]+$` 挡注入。
- **智能默认** appname:有显式 `[appname]` 用之;否则探测 `~/.config/nvim` 不存在 / 空 → `nvim`(接管),非空 → `nvim-<name>`(隔离)。`log_info` 告知最终落点。
- `_nvim_node_gate`? 不需要(neovim 本体不依赖 Node)。需 `have_cmd git`(无则报错指路 `swkit git install`);git 由 lib `apt_install git` 可补(configure 确保)。
- 目标 `~/.config/<appname>` 若非空 → `_nvim_backup_dir`(时间戳重命名 / tar 备份,**目录级**,因 `backup_file` 只处理单文件)。
- `git clone --depth 1 <repo> ~/.config/<appname>`(保留 `.git` 便于辨识与后续;starter 模板用户可自行 reinit)。
- manifest:`DISTROS` 追加 `<appname>:<name>`(去重)。
- 隔离(appname≠nvim)→ 写受管 alias 行 `alias nvim-<name>='NVIM_APPNAME=<appname> nvim'` 到 shell rc。
- 若 `have_cmd nvim` 且版本够 → `_nvim_sync <appname>`(headless lazy 同步,超时保护);否则 `log_warn` 提示先 `swkit nvim install`。

### do_remove_distro <name|appname>(带参)
- 从 `DISTROS` manifest 解析 appname;路径护栏(在 `~/.config/` 下、非空、非 `..`/绝对逃逸,参 rime remove-rime-ice / android purge 护栏)。
- `_nvim_backup_dir ~/.config/<appname>` 后 `rm -rf`;删 `~/.local/{share,state,cache}/<appname>`(distro 运行产物,无珍贵用户数据);删受管 alias 行;`DISTROS` 移除该项。

### 插件同步 `_nvim_sync <appname> <sync|update|clean>`
`timeout`(防卡)包 `NVIM_APPNAME=<appname> nvim --headless "+Lazy! <op>" +qa`。
- `sync-plugins [appname]` / `update-plugins`(进 meta.ops,无参对 `nvim`)/ `clean-plugins [appname]`。

### add-distro <name> <git-url> / 任意
conf 记 `EXTRA_DISTRO_<name>=<git-url>`,之后 `install-distro <name>` 可用。

## 5. 外部依赖(configure 确保)

`_nvim_ensure_deps`:`apt_install git curl build-essential ripgrep fd-find unzip`(fd 命令为 `fdfind`,Ubuntu 包名 `fd-find`)。Nerd Font 经 `"$KIT_SCRIPTS_DIR/fonts.sh" install meslolgs`(范式同 tmux/ghostty)。剪贴板 `xclip`/`wl-clipboard` best-effort(有 DISPLAY/WAYLAND 才有意义,SSH 提示)。**绝不装 Node**(Mason LSP runtime 属 opt-in,缺则指路 `swkit node install`)。

## 6. 默认编辑器联动 `do_set_default_editor [off]`(带参)

- 用户态:写 / 删受管 rc 行 `export EDITOR=nvim` / `export VISUAL=nvim`(marker + backup + grep,范式 go.sh)。
- best-effort 系统:`sudo update-alternatives --install /usr/bin/editor editor /usr/local/bin/nvim 60`(tarball 装的需先 install;apt neovim 已自注册)+ `--set editor`;失败 / `RC_NEED_SUDO` 仅 `log_warn` 不中断。
- `off` 反转:删 rc 行;`sudo update-alternatives --auto editor`(best-effort)。
- 状态存 `DEFAULT_EDITOR=on|off`。

## 7. meta.ops 与带参 op

- `meta.ops=install,remove,configure,update,update-plugins`。
- **带参 op(kit_dispatch 路由 `do_<x>`,不进 meta.ops,ui 可达)**:`install-distro` / `remove-distro` / `add-distro` / `sync-plugins` / `clean-plugins` / `set-default-editor` / `ensure-deps`。
- `do_configure` flags:`--recommended`(neovim 本体 + 外部依赖 + Nerd Font + 装 LazyVim〔默认 distro〕+ 同步 + set-default-editor on)/ `--distro <name>` / `--editor on|off` / `--deps`(只装外部依赖)。**无参 = 保守基线**:仅确保 neovim 本体在(不装 distro / 不设编辑器 / 不装额外依赖)。

## 8. ui()

`ui_supported || { ui_default_menu; return 0; }`;`ui_begin/ui_end` 包循环;每个状态变更 `ui_run "<标题>" -- "$0" <op> [args]`。分组(`tmux.sh` 范式):
- **Neovim**:渠道 + 版本 badge;装 / 卸 / 更新本体。
- **Distros**:curated 勾选(已装 ✓ + appname)、`→` 装 / 卸 / 设默认、`a` 加任意 git-url。
- **Plugins**:对选中 appname sync / update / clean。
- **External deps**:ripgrep / fd / Nerd Font 等装(已装灰显)。
- **Default editor**:开关。
- **Apply recommended**:一键。

读走 fs(扫 `~/.config/nvim*` + manifest),改走 `ui_run`。无 TTY → `ui` 打印指引退 0(`kit_dispatch` 兜底)。

## 9. i18n

`NVIM_I18N`(en/zh/ja),distro / 依赖一行说明本地化,**distro 名不译**(同 tmux/rime 规则)。`_nvim_lang` 解析 `UI_LANG`。

## 10. 安全契约落地

- 本体安装(apt/snap/tarball→/opt + symlink)经 `sudo_run` 逐命令提权;**其余全部用户态**(`_nvim_user_guard` 拒绝 sudo 包裹)。
- tarball **API 动态 sha256 校验** = 信任边界;API/校验失败 fail-fast,**绝不**无校验落盘执行。
- 改配置目录前 `_nvim_backup_dir`;manifest 精确卸载 + 路径护栏(挡绝对 / `..` / 逃逸 `~/.config`)。
- 非交互 apt(lib);改前备份;append 前 grep;fail-fast 不回滚(重跑即补救,故幂等)。
- 绝不 `sudo npm` / 绝不自动装 Node / 绝不 `apt-key`。

## 11. 边角 / 兼容

- arm64:tarball/apt 均有 arm64;snap 有。无特殊。
- SSH / headless:neovim 是 TUI(非 GUI),SSH 完美适用,无"仅桌面"提示;Nerd Font 字形由本地客户端终端渲染(同 fonts.sh 的 SSH 提示);剪贴板 OSC52 / xclip 视环境。
- 旧 glibc:tarball 可能跑不起,`log_warn` 指 `neovim-releases`。
- 多 distro 共存:NVIM_APPNAME 隔离,各自 alias。

## 12. 取舍记录

- **本体渠道把 tarball 排在 snap 前**(偏离契约字面顺序):neovim 官方首推 tarball、永远最新 stable、有完整 API sha256 校验。已与用户确认。
- **distro 模式,不自建受管配置**:不重复造 distro 轮子;kit 不解析 / 改写 lua,插件经 lazy headless 驱动。
- **保留 `.git`**:便于辨识 kit 所装 + 用户自更新;卸载按 manifest 整目录删。
- **不纳入 Mason LSP 自动装**:需各 runtime(Node/Python/…),属 opt-in;MVP 只保证插件同步。
