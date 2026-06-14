# 设计:Oh My Zsh 最佳实践配置 + 专用 Nerd Font 管理脚本

日期:2026-06-13 · 状态:已批准设计,待实现

## 背景与问题

`scripts/zsh.sh` 已是可用的 zsh 组件管理器(安装、prompt、kit 自管插件、默认 shell)。但两处不满足用户需求:

1. **Oh My Zsh 配置过于单薄。** 启用 OMZ 时,受管 drop-in 只硬编码:
   ```zsh
   export ZSH="$HOME/.oh-my-zsh"
   ZSH_THEME="robbyrussell"   # 或外部 prompt 时为空
   plugins=(git)
   source "$ZSH/oh-my-zsh.sh"
   ```
   既**无法启用 OMZ 自带的原生插件**(`sudo`/`extract`/`colored-man-pages`/`command-not-found`/`docker`/`kubectl`/`z` 等——这正是用户说的"只有默认插件配置"),也**没有 OMZ 的常用最佳实践设置项**(更新策略、`DISABLE_MAGIC_FUNCTIONS`、`DISABLE_UNTRACKED_FILES_DIRTY`、`COMPLETION_WAITING_DOTS`、`HIST_STAMPS` 等)。

2. **字体只是警告,从未真正安装。** 选 Powerlevel10k / Starship 时,`_zsh_apply` 仅 `log_warn "install a Nerd Font in your LOCAL terminal"`,没有任何安装动作。用户要求**真正安装对应字体并应用**。

### 调研结论(联网)

- **OMZ 最佳实践**(OMZ 官方 `templates/zshrc.zsh-template` + Settings wiki + 2025 社区配置):性能/非交互安全的关键开关是 `zstyle ':omz:update' mode disabled`(用 git/kit 管更新、避免交互式更新提示卡死非交互 shell)、`DISABLE_MAGIC_FUNCTIONS="true"`、`DISABLE_UNTRACKED_FILES_DIRTY="true"`(大仓 `git status` 提速)、`COMPLETION_WAITING_DOTS="true"`、`HIST_STAMPS`;原生插件通过 `plugins=(...)` 数组启用。
- **字体**(Powerlevel10k 官方 `font.md`):推荐 **MesloLGS NF**,4 个 TTF 托管在 `romkatv/powerlevel10k-media`;Linux 命令行装法为放入 `~/.local/share/fonts/` 后 `fc-cache -f`。该字体同样适用于 Starship。

### 关键事实(决定"应用"的真实含义)

本项目主打**无桌面 Ubuntu Server + SSH**。**渲染字形的字体在用户本地客户端终端(SSH 客户端)上,不在服务器上。** 在服务器装字体只对"有本地显示/桌面"才直接生效。因此服务器侧"应用字体"的诚实含义是:把字体装进 `~/.local/share/fonts` 并 `fc-cache`(让本地显示/桌面应用即时可用),并**清楚指引用户在其客户端终端安装/选择该字体**——而不是声称在纯 Server 上"已应用"。

## 用户已拍板的设计岔路

1. **字体 → 单独建一个专门的字体管理脚本**(`scripts/fonts.sh`),不塞进 `zsh.sh`。
2. **OMZ 插件 → UI 勾选 + 任意添加 + CLI 动作**(镜像现有 kit 插件勾选区)。
3. **OMZ 设置 → 逐项可配**(带最佳实践默认值,可单独调,而非固定烤死)。

## 设计总览

两部分:**(A)** 新增 `scripts/fonts.sh` 专用 Nerd Font 管理脚本(遵守 kit 契约,自动进 bootstrap 目录);**(B)** `zsh.sh` 增 OMZ 原生插件管理 + OMZ 设置逐项可配 + 选 starship/p10k 时经 `fonts.sh` 真正安装 MesloLGS NF。外加 **(C)** 契约文档同步、**(D)** 校验。

---

## A. `scripts/fonts.sh` — 专用 Nerd Font 管理脚本

**目标:** 用户态安装/移除/管理 Nerd Font(`~/.local/share/fonts` + `fc-cache`,**不用 sudo** 写字体文件),让需要字形的 prompt/TUI/编辑器在任何本地显示场景即时可用,并对 SSH 给出诚实的客户端指引。

### meta

```
key=fonts
name=Nerd Fonts
category=common
ops=install,remove,apply,configure
desc=Nerd Fonts (MesloLGS NF for Powerlevel10k/Starship, + JetBrainsMono/FiraCode/Hack) — user-space install + fc-cache + local terminal apply
```

`ui` 是入口模式,不进 `ops`。`apply` / `configure` 是正式 op:保存字体偏好并对可检测的本地图形终端做用户级应用。

### 字体注册表(curated)

| name(键) | 字体族(family) | 安装目录 | 渠道 |
|---|---|---|---|
| `meslolgs`(默认/旗舰) | `MesloLGS NF` | `~/.local/share/fonts/MesloLGS NF/` | `romkatv/powerlevel10k-media` 的 4 个 raw TTF |
| `jetbrains-mono` | `JetBrainsMono Nerd Font` | `~/.local/share/fonts/JetBrainsMono/` | `ryanoasis/nerd-fonts` release zip |
| `firacode` | `FiraCode Nerd Font` | `~/.local/share/fonts/FiraCode/` | 同上 |
| `hack` | `Hack Nerd Font` | `~/.local/share/fonts/Hack/` | 同上 |

常量:
```sh
P10K_MEDIA="https://github.com/romkatv/powerlevel10k-media/raw/master"
NERD_FONTS_BASE="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
FONTS_KNOWN="meslolgs jetbrains-mono firacode hack"
```
MesloLGS NF 4 文件:`MesloLGS NF Regular.ttf` / `Bold.ttf` / `Italic.ttf` / `Bold Italic.ttf`(URL 中空格 `%20`)。zip 字体:`<NERD_FONTS_BASE>/<Asset>.zip`(JetBrainsMono / FiraCode / Hack)。`latest/download` 始终解析到最新 release,日志中打印 URL(渠道透明)。

### 用户/路径解析(沿用 zsh.sh 纪律)

`_fonts_resolve_home`:`EUID==0 && SUDO_USER` 时拒绝(字体文件须保持用户所有),解析 `$_FONTS_HOME`(优先 `$HOME`,否则 `getent passwd "$SUDO_USER"`),`_FONTS_DIR="$_FONTS_HOME/.local/share/fonts"`,`mkdir -p`。

### 幂等探测(契约①:查活系统,不信标志位)

`_font_installed <name>`:检查该字体安装目录下是否存在预期 TTF 文件(meslolgs 检查 `MesloLGS NF Regular.ttf`;zip 字体检查目录非空)。以**文件存在**为准(无 fontconfig 也成立)。

### 配置状态

`~/.config/ubuntu-setup/fonts.conf` 记录 `FONT=<name>`、`SIZE=<6-48>`、`TARGET=<auto|ptyxis|gnome-terminal|gnome-desktop|instructions>`。写入前若内容变化则 `backup_file` 旧文件;配置文件始终归用户所有,不经 sudo。

### status

退出码 0 当且仅当**旗舰 MesloLGS NF 已安装**(catalog 的 `[installed]` 徽标语义 = "推荐 Nerd Font 已就位");打印所有受管字体中已安装者。

### do_install [name]

1. `_fonts_resolve_home`;`name` 默认 `meslolgs`;校验属于 `FONTS_KNOWN`(否则报错列出可选)。
2. 已装则 `log_info` 跳过(幂等),`return 0`。
3. `have_cmd curl || apt_install curl ca-certificates`。
4. `have_cmd fc-cache || apt_install fontconfig || log_warn "无法装 fontconfig;字体文件已放置但未刷新缓存"`(best-effort,不因缺 sudo 中断主流程)。
5. 下载:
   - meslolgs:`mkdir -p "<dir>"`,4 次 `curl -fsSL "$P10K_MEDIA/MesloLGS%20NF%20<...>.ttf" -o "<dir>/MesloLGS NF <...>.ttf"`。
   - zip 字体:`have_cmd unzip || apt_install unzip`;`curl -fsSL "<url>" -o "$tmp/font.zip"`;`unzip -o` 仅 `*.ttf` 到 `<dir>`;清理。
6. `have_cmd fc-cache && fc-cache -f "$_FONTS_DIR" >/dev/null 2>&1 || true`。
7. `_font_guidance <name>`。

### do_remove [name]

`name` 默认 `meslolgs`;未装则提示无操作;否则 `rm -rf "<dir>"` + `fc-cache -f`。

### do_apply [name] [size] [target]

参数缺省来自配置文件,再退到 `meslolgs 12 auto`。非 `instructions` 目标会先确保字体已安装(缺失则调用 `do_install <name>`)。随后:

- SSH 会话:不声称能改客户端终端,只打印客户端安装/选择指引并退 0。
- `instructions`:只保存偏好并打印手动/客户端指引。
- `auto`:按可用 schema 尝试 Ptyxis(`org.gnome.Ptyxis` 的 `font-name`/`use-system-font`)、GNOME Terminal(`org.gnome.Terminal.ProfilesList` + `org.gnome.Terminal.Legacy.Profile` 默认 profile)、GNOME desktop monospace(`org.gnome.desktop.interface monospace-font-name`)。至少一个成功即成功;无可用目标则给手动指引。
- 显式 `ptyxis` / `gnome-terminal` / `gnome-desktop`:目标不可用或 gsettings 写入失败则非 0,避免误报"已应用"。

所有应用都是**用户级 gsettings**写入,不 sudo,不改系统字体配置。

### do_configure [opts]

`--font <name>` / `--size <6-48>` / `--target <target>` 保存偏好;默认只保存(保守 headless 安全),`--apply` 才立即调用 `do_apply`;`--no-apply` 显式只保存。无参 = 保存默认或既有偏好,不写图形终端设置。

### _font_guidance <name>(SSH 感知的"应用"指引)

- 始终:`已安装 <Family> 到 ~/.local/share/fonts 并刷新字体缓存。`
- 若 `$SSH_CONNECTION`/`$SSH_TTY` 非空(SSH 会话):`你在 SSH 会话中——字形由你的本地终端渲染,请同时在你连入的那台机器上安装/选择该字体:下载 <URLs>,把终端字体设为 '<Family>'。`
- 否则(本地/桌面):`把终端字体设为 '<Family>'(如 GNOME Terminal → Preferences → 你的 profile → Text → 自定义字体)。`
- meslolgs 额外:`Powerlevel10k 用户可运行 'p10k configure' 挑选风格。`

### ui()

`!ui_supported` → `ui_default_menu`。富屏:上半部分显示并可编辑 selected font / size / apply target,提供 "Apply selected font";下半部分每个受管字体一行(`<badge> <Family> <已装?>`),仍可 `↵/space` 安装/卸载;`a` 随时应用当前选择;`q` 退出。`ui_begin`/`ui_end` 包裹;每次状态变更经 `ui_run` 退屏可见+日志后重载。

### usage

记录 `install [name]` / `remove [name]` / `apply [name] [size] [target]` / `configure --font --size --target [--apply|--no-apply]` / 已知 name / target / SSH 字体口径。

---

## B. `zsh.sh` 改造

### B1. OMZ 原生插件管理(`OMZ_PLUGINS` 状态)

- 新状态变量 `OMZ_PLUGINS`,默认 `"git"`(保守、与 OMZ 自带模板默认一致;丰富度由可勾选的 curated 集与 CLI 提供,不靠改默认值给惊喜)。
- curated 常量:`ZSH_OMZ_KNOWN_PLUGINS="git sudo extract colored-man-pages command-not-found docker docker-compose kubectl z"`(均为 OMZ 自带;**故意不含** `zsh-autosuggestions`/`zsh-syntax-highlighting`——这两个由 kit 自有插件体系单独管理,避免双重加载)。
- `_zsh_load_state`/`_zsh_save_state` 增 `OMZ_PLUGINS`。
- drop-in 的 OMZ 块发 `plugins=(<OMZ_PLUGINS>)` 取代硬编码 `plugins=(git)`。
- 新动作(**带参,不进 `meta.ops`**,经 `kit_dispatch` 路由,镜像 add-plugin/remove-plugin):
  - `add-omz-plugin <name>`(`do_add_omz_plugin`):要求 `FRAMEWORK=oh-my-zsh`(否则报错提示先 `install-omz`);校验 `~/.oh-my-zsh/plugins/<name>` 或 `~/.oh-my-zsh/custom/plugins/<name>` 存在(契约①查活系统),不存在则报错列出可选;加入 `OMZ_PLUGINS` 后 `_zsh_apply`。
  - `remove-omz-plugin <name>`(`do_remove_omz_plugin`):从 `OMZ_PLUGINS` 移除后 `_zsh_apply`。
- `configure` 增 `--omz-plugins "git sudo ..."`(整体替换;逗号/空格分隔;每项须在 curated 集或实际存在于 OMZ 插件目录)。

### B2. OMZ 设置(逐项可配)

新增状态变量(均带最佳实践默认值;drop-in 仅在对应条件下发出对应 OMZ 变量,并写明理由注释):

| 状态变量 | 默认 | 取值 | drop-in 发出 |
|---|---|---|---|
| `OMZ_UPDATE` | `disabled` | disabled\|auto\|reminder | `zstyle ':omz:update' mode <v>` |
| `OMZ_MAGIC` | `0` | 0\|1 | `0` → `DISABLE_MAGIC_FUNCTIONS="true"` |
| `OMZ_UNTRACKED_DIRTY` | `0` | 0\|1 | `0` → `DISABLE_UNTRACKED_FILES_DIRTY="true"` |
| `OMZ_CORRECTION` | `0` | 0\|1 | `1` → `ENABLE_CORRECTION="true"` |
| `OMZ_WAIT_DOTS` | `1` | 0\|1 | `1` → `COMPLETION_WAITING_DOTS="true"` |
| `OMZ_HIST_STAMPS` | `yyyy-mm-dd` | yyyy-mm-dd\|mm/dd/yyyy\|dd.mm.yyyy\|none | 非 none → `HIST_STAMPS="<v>"` |

默认理由:禁 OMZ 自动更新(kit 用 git 管、避免非交互卡住,呼应契约③);禁 magic functions(更快、避免粘贴问题);禁 untracked-dirty(大仓 `git status` 提速);correction 默认关(打断性强);waiting dots 默认开;时间戳默认 ISO `yyyy-mm-dd`。

- 通用粒度动作 `omz-setting <key> <value>`(`do_omz_setting`,**带参,不进 ops**):key ∈ `update|magic|untracked-dirty|correction|wait-dots|hist-stamps`,布尔接受 `on/off/1/0/true/false`,枚举各自校验;改后 `_zsh_apply`。供 swkit/LLM 用,也供 UI 调。
- `configure` 增对应 flags:`--omz-update <mode>`、`--omz-magic on|off`、`--omz-untracked-dirty on|off`、`--omz-correction on|off`、`--omz-wait-dots on|off`、`--omz-hist-stamps <v>`。

### B3. drop-in 的 OMZ 块重写

```zsh
# ---- Oh My Zsh (runs its own compinit) ----
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="<theme>"
# 更新策略:kit 用 git 管 OMZ;默认 disabled 让非交互 shell 不会卡在更新提示。
zstyle ':omz:update' mode <OMZ_UPDATE>
# 行为/性能(用 `swkit zsh omz-setting <key> <v>` 修改):
DISABLE_MAGIC_FUNCTIONS="true"          # 当 OMZ_MAGIC=0
DISABLE_UNTRACKED_FILES_DIRTY="true"    # 当 OMZ_UNTRACKED_DIRTY=0
COMPLETION_WAITING_DOTS="true"          # 当 OMZ_WAIT_DOTS=1
ENABLE_CORRECTION="true"                # 当 OMZ_CORRECTION=1
HIST_STAMPS="yyyy-mm-dd"                # 当 OMZ_HIST_STAMPS != none
plugins=(<OMZ_PLUGINS>)
source "$ZSH/oh-my-zsh.sh"
```
每条 conditional 行仅在其开关满足时发出。其余(kit 自有 named 插件在 `oh-my-zsh.sh` 之后 source、syntax-highlighting 仍最后)保持现状。

### B4. zsh ↔ fonts 接通(选 prompt 时真正装字体)

`_zsh_apply` 中 starship/powerlevel10k 分支:在装好 starship/clone p10k 后,调 `_zsh_ensure_nerd_font` 取代原占位 `log_warn`。

```sh
_zsh_ensure_nerd_font() {
  local fonts="$KIT_SCRIPTS_DIR/fonts.sh"
  if [[ -x "$fonts" ]]; then
    if "$fonts" status >/dev/null 2>&1; then
      log_info "Nerd Font (MesloLGS NF) 已安装。"
    else
      log_info "经 fonts.sh 安装推荐 Nerd Font(MesloLGS NF)…"
      "$fonts" install meslolgs || log_warn "未能自动安装 Nerd Font——可自行 'swkit fonts install'。"
    fi
  else
    log_warn "未找到 fonts.sh;请自行 'swkit fonts install' 以获得 $PROMPT 字形。"
  fi
  log_warn "Nerd Font 字形在你的本地终端渲染——SSH 时也要在客户端安装/选择 MesloLGS NF。"
}
```
`KIT_SCRIPTS_DIR` 由 `lib/common.sh` 导出。`fonts.sh install` 本身幂等,可安全重入。best-effort:失败仅 warn,不中断 zsh 配置。

### B5. zsh `ui()` 增量

仅当 `installed && FRAMEWORK=oh-my-zsh` 时,在 Framework/Prompt 行之后插入(沿用主循环 parallel arrays 与内联 toggle 模式):

- header `Oh My Zsh plugins`
- curated OMZ 插件行(`dkind=omzplugin`):`<chk> <name>`,`↵/space` 切换 → `add-omz-plugin`/`remove-omz-plugin`;额外列出已在 `OMZ_PLUGINS` 中的非 curated 项(标 `(custom)`)。
- 行 `＋ add Oh My Zsh plugin…`(`dkind=omzplugin_add`):`↵` → `ui_input` 名 → `add-omz-plugin`。
- header `Oh My Zsh settings`
- 设置行(`dkind=omzsetting`):标签显示 key + 当前值;`↵` 对布尔就地翻转(`omz-setting <key> <new>`),对枚举(update/hist-stamps)`ui_pick` 选值后 `omz-setting`。

全部经 `ui_run` 退屏可见+日志后重载状态。footer 在 OMZ 开启时补 OMZ 操作提示。

### B6. meta ops 与 usage

`meta` 的 `ops` **不变**(`install,remove,configure,install-omz,uninstall-omz,default-shell`)——新动作 add-omz-plugin/remove-omz-plugin/omz-setting 带参,**不进 ops**(同 add-plugin/remove-plugin/prompt)。`usage` 增这些动作与新 configure flags 的说明。

---

## C. 契约文档同步(防漂移)

- `skills/zsh-setup/SKILL.md`:记 OMZ 插件管理(add-omz-plugin/remove-omz-plugin/omz-setting + curated 集 + `--omz-*` flags)、OMZ 设置项、与 `fonts.sh` 的集成(prompt 现经 fonts.sh 真正装 MesloLGS NF);更新字体口径(不再"仅警告")。
- `skills/ubuntu-install/SKILL.md`:种子脚本集列举处增 `fonts`(若有)。
- `CLAUDE.md`「当前状态」种子脚本集 `git curl zsh docker node claude codex` → 增 `fonts`;补 zsh 的 OMZ 插件/设置管理与 fonts.sh 接通一句。
- `README.md`:脚本列表增 `fonts`(若列举)。

## D. 校验

1. `for f in bootstrap.sh lib/*.sh swkit scripts/*.sh; do bash -n "$f"; done` 全过。
2. `shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/*.sh bootstrap.sh` 零告警。
3. 契约自测:`fonts.sh meta` 字段齐全、`ops=install,remove,apply,configure` 与实现一致且不含 `ui`;`fonts.sh status` 独立可跑;用临时 `HOME` 跑 `fonts.sh configure --font hack --size 13 --target instructions --no-apply` 与 `fonts.sh apply firacode 11 instructions`;`fonts.sh ui`(无 TTY)打印指引退 0;`zsh.sh meta` ops 不变;`zsh.sh ui`(无 TTY)退 0。
4. **真跑** `scripts/fonts.sh install meslolgs`,验证 URL 可达、4 TTF 落地、`fc-list | grep -i meslo` 命中、再次运行幂等跳过。
5. OMZ drop-in 发出:造伪 `~/.oh-my-zsh`(令 `_zsh_ensure_omz` 跳过 clone),`zsh.sh configure --framework oh-my-zsh --omz-plugins "git sudo"` 后查 `~/.config/zsh/ubuntu-setup.zsh` 含 `plugins=(git sudo)`、`zstyle ':omz:update' mode disabled`、`DISABLE_MAGIC_FUNCTIONS="true"` 等;`omz-setting correction on` 后含 `ENABLE_CORRECTION="true"`。

## 非目标(YAGNI)

- **不**做 root/system-wide 字体配置,也不声称能通过 SSH 修改客户端终端字体;`apply` 只做用户级本机 gsettings 或打印明确指引。
- **不**支持非 Nerd Font 任意字体管理(聚焦 prompt/TUI 字形需求的 curated Nerd Font 集)。
- **不**把 `zsh-autosuggestions`/`zsh-syntax-highlighting` 纳入 OMZ_PLUGINS(由 kit 自有体系管理,避免双重加载)。
