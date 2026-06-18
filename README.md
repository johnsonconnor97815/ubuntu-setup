# ubuntu-setup

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成**用脚本集合管理软件**的机器。每个软件的**安装 / 卸载 / 配置逻辑都是一个 bash 脚本**(`scripts/<软件>.sh`,统一接口),背后由共享库 `lib/common.sh` 把项目的安全契约**写成可复用的代码**。脚本按类别组织,有三种方式驱动它们:

- **TUI**——`./bootstrap.sh` 进入的现代全屏菜单,按类别浏览脚本,**钻进每个软件自己的管理界面**(装/卸/配,zsh 还能勾插件、选提示符);
- **`swkit` 命令**——`swkit docker install` 直接跑,`swkit zsh` 开 zsh 的界面,`swkit ui` 开总目录;
- **LLM**(Claude Code / Codex)——你说"装个 docker",它在 skill 守则下**调用**脚本(挑对的脚本与选项、解释取舍);它只**运行并推荐**脚本,**不在你机器上编写或改写脚本**。

脚本统一在**本仓库**里维护。要新增软件覆盖或修过时的脚本,在仓库里加 / 改一个脚本(`cp scripts/TEMPLATE.sh`)、走正常 git 评审、再重跑 `bootstrap.sh` 部署——脚本提供稳定、确定、可测的执行,这是唯一权威来源。

> 没有 Python 包、没有数据驱动的 catalog 引擎(那是被放弃的旧方向)。纯 bash,每个软件一个手写的脚本;TUI 通过读各脚本自报的 `meta` 动态发现并归类它们。

## 快速开始

```bash
git clone <repo-url>
cd ubuntu-setup
./bootstrap.sh
```

有终端时,`./bootstrap.sh` 默认进入一个**现代全屏 TUI**(纯 bash + ANSI 自绘:accent 标题栏、圆角盒线、`●/○` 状态徽标、方向键导航、底部 keybind 栏;**无 whiptail 依赖**,非富终端回退纯文本编号菜单):

- **安装软件**:目录浏览器按**类别**(essentials / common / ai / runtime,其余归 other)列出脚本、实时标 `●`(已装)/`○`(未装),`→` / 回车**钻进该软件自己的管理界面**——每个脚本拥有自己手写的界面:装 / 卸 / 配,docker 显示 docker 组与服务状态,git 能设 user.name/email,**zsh 是一个组件管理器**(框架开关、提示符选择器、插件复选清单、默认 shell,见下)。操作幂等(重复安全);执行某操作时 UI **退出全屏**、直接展示真实输出(apt/sudo 密码提示正常工作)并 `tee` 到 `~/.cache/ubuntu-setup/` 的日志,完成后 `✓/✗` + 回车返回——单个操作失败只记日志、不崩会话。
- **设置**:切换界面**语言**(中文 / English / 日本語,记到 `~/.config/ubuntu-setup/config`);**开/关 LLM 免密 sudo**(见文末)。

脚本幂等,可随时安全重跑:已装好的组件会在**真实系统**上被检测并跳过;失败后修因重跑即可续装。全程不需要整体 root——只有确需 root 的单条命令(apt、docker 加组、zsh `chsh`)会**逐命令** `sudo`;CLI 的官方安装器与 `npm install -g` 一律以当前用户身份跑。

## 直接用 swkit

`bootstrap.sh` 会把 `swkit` 软链到你的 PATH(`~/.local/bin/swkit` → clone 里的 `swkit`),可以不进 TUI 直接驱动:

```bash
swkit list                          # 按类别列出所有脚本,已装的标 [installed]
swkit ui                            # 打开全屏目录(同 bootstrap 的「安装软件」)
swkit zsh                           # 打开 zsh 的组件管理器界面(无操作 = 进 UI)
swkit search nginx                  # 在 key / 名称 / 描述里大小写不敏感地搜
swkit docker install                # 跑 scripts/docker.sh install
swkit docker status                 # 是否已装?退出码 0 表示是
swkit zsh configure --default-shell # 多余参数原样透传给脚本
swkit help
```

`swkit <软件> <操作> [args...]` 映射到 `scripts/<软件>.sh <操作>`,退出码原样透传。每个脚本都支持 `install`、`remove`、`status`、`meta`、`help`、`ui`(部分还有 `configure`)。`swkit <软件>` 不带操作时,有终端则打开它的 `ui` 界面、无终端则打印用法。没有对应脚本时,`swkit` 会提示从 `scripts/TEMPLATE.sh` 复制一个出来(在仓库里加,再重跑 bootstrap 部署)。

## 脚本集合

- **运行位置**:**原地从你的 clone 跑**——没有独立部署副本。`bootstrap.sh` 只把 `swkit` 软链到 `~/.local/bin/swkit`(指向 clone 里的 `swkit`),脚本经 lib 相对自身定位找到同仓的 `lib/` 与其他脚本。clone 放哪即装哪,删了 clone 即卸载。
- **种子脚本**:`git`、`curl`、`zsh`、`fonts`、`docker`、`ghostty`、`tmux`、`rime`、`vscode`、`cursor`、`node`、`go`、`python`、`claude`、`codex`、`codegraph`、`trellis`。`docker` 的 `configure` 加 docker 组 + 起服务,`git` 的 `configure` 设全局 user.name/email(写 `~/.gitconfig`,绝不 sudo);**`ghostty` 是 Ghostty 终端的安装+配置管理器**(渠道:apt〔26.04+〕→ 社区 `.deb`〔24.04/25.10〕→ snap;`swkit ghostty configure --theme <名> --font <族|none> --size <pt> --opacity <0-1> --cursor <block|bar|underline> --padding <px> --copy-on-select on|off …` 管**主题/字体/常用项**,主题按 `ghostty +list-themes` 校验、支持 `dark:…,light:…`,curated Nerd Font 经 `fonts.sh` 自动装;偏好存 `~/.config/ubuntu-setup/ghostty.conf`,写受管 drop-in `~/.config/ghostty/ubuntu-setup` 并经绝对路径 `config-file=` include 进你的 `~/.config/ghostty/config`,**不覆盖你的配置**;`swkit ghostty` 开全屏管理器。`swkit ghostty default-terminal`〔`off` 反转〕把它设为默认终端:用户态写 freedesktop `xdg-terminal-exec` 选择器(`~/.config/<desktop>-xdg-terminals.list` 首行,GNOME 25.04+ Ctrl+Alt+T 走此),best-effort 再经 `sudo update-alternatives` 注册系统 `x-terminal-emulator`(仅 .deb/apt;snap 跳过;失败仅告警)。Ghostty 是桌面 GUI 终端,SSH 时设置作用于有显示器的机器);**`tmux` 是 tmux 的安装+组件管理器**(像 `zsh` 一样按组件管理):`swkit tmux install`;`swkit tmux configure` 暴露丰富的最佳实践设置(`--theme`/`--status-position`/`--status-interval`/`--mouse`/`--clipboard`/`--focus-events`/`--aggressive-resize`/`--renumber`/`--base-index`/`--monitor-activity`/`--set-titles`/`--keymode`/`--prefix`/`--keybindings`〔`|`/`-` 分屏 + vim hjkl 窗格导航 + vi 复制〕/`--window-nav`〔Alt+1..9 跳窗口 + Shift-←/→ 前后窗口〕/`--copy-mode-key`〔自定义进 copy-mode 的键〕/`--tree-key`〔自定义窗口树 choose-tree 的键〕/`--history`/`--escape-time`/`--plugins`/`--recommended` 等)写成 `~/.tmux.conf` 里的**受管标记块**(改前备份、保留标记外内容;用主配置标记块而非单独 drop-in,因 **TPM 只从主配置 grep `@plugin`、不跟随 `source-file`**);`swkit tmux add-plugin <名|owner/repo|git-url>` / `remove-plugin <名>` 经 **TPM** 增删插件(curated:sensible / resurrect / continuum / yank / pain-control / vim-navigator / open / fzf / battery / cpu / prefix-highlight,其余按 git 仓),另有 `install-tpm` / `uninstall-tpm` / `update-plugins`、`theme <名> [flavor]`;`swkit tmux` 开全屏管理器(每个设置都是快捷 开关/选择器/输入,Appearance/Behavior/Keys/History 分组 + 视口滚动;空格勾插件、`a` 加任意仓、「Apply recommended setup」一键装 TPM+常用插件+catppuccin+人体工学键位)。无参 `configure` = 保守最佳实践基线(mouse on、vi 复制、true color、不装插件/不重映射键位);插件经 TPM 的 `bin/` 脚本无 TTY 驱动,tmux 是多路复用器、SSH/headless 完美适用);**`rime` 是 RIME 输入法的安装+组件管理器**(框架 **fcitx5**;像 `zsh`/`tmux` 一样按组件管理):`swkit rime install` 经 apt 装 `fcitx5 + fcitx5-rime + GTK/Qt IM 模块(fcitx5-frontend-all,**缺了会回退 XIM 致候选框定位错乱**)+ im-config` 并以用户态 `im-config -n fcitx5` 选定框架,写三个**受管文件**(改前备份)——IM 环境 `~/.config/environment.d/ubuntu-setup-rime.conf`(`GTK/QT/XMODIFIERS`=fcitx,需重新登录)、RIME patch `~/.local/share/fcitx5/rime/default.custom.yaml`(启用方案 + 候选词个数)、以及 **fcitx5 登录自启** `~/.config/autostart/org.fcitx.Fcitx5.desktop`(**Wayland 必需**:Ubuntu 默认的 Wayland 会话下 im-config/im-launch 不启动 IM 守护、fcitx5 包也不带 autostart,不自写则登录后无人启动 fcitx5、桌面退回自带 IBus);`swkit rime configure --schemas "luna_pinyin_simp luna_pinyin" --default-schema <id> --page-size <5-10> --recommended` 管**输入方案与选项**(curated 内置方案 luna_pinyin_simp〔简体优先〕/ luna_pinyin / bopomofo / wubi86 / cangjie5 / double_pinyin_flypy〔小鹤双拼〕… 一行说明 en/zh/ja 本地化),`add-schema`/`remove-schema`/`set-default-schema` 增删方案;**`install-rime-ice` 一键装雾凇拼音 rime-ice**(纯用户态、需 git,`git clone iDvel/rime-ice` 后清单式复制进 RIME 目录、可经 `remove-rime-ice` 精确还原);`swkit rime deploy` 触发重新部署(`fcitx5-remote -r`);`swkit rime` 开全屏管理器(空格勾方案、`d` 设默认、`a` 加任意方案、装/卸 rime-ice、Deploy/Apply recommended)。`remove` 保守(仅卸 `fcitx5-rime`,留 fcitx5/环境/数据)。RIME/fcitx5 是桌面输入法,SSH/headless 下设置作用于有显示器的机器、重新登录生效);**`fonts` 是用户态 Nerd Font 管理器**(`swkit fonts install [meslolgs|jetbrains-mono|firacode|hack]` / `swkit fonts apply [name] [size] [auto|ptyxis|gnome-terminal|gnome-desktop|instructions]` / `swkit fonts configure --font <name> --size <pt> --target <target>` / `swkit fonts ui`,装入 `~/.local/share/fonts` + `fc-cache`,把偏好保存到 `~/.config/ubuntu-setup/fonts.conf`,并用用户级 gsettings 应用到支持的本地终端/桌面 monospace,绝不 sudo);**`zsh` 是一个组件管理器**——框架(Oh My Zsh)、提示符、各插件都能**独立装/卸/增/删**,状态记在 `~/.config/zsh/ubuntu-setup.conf`,每次改动重生成受管 drop-in `~/.config/zsh/ubuntu-setup.zsh` 并在 `~/.zshrc` 加一行 source(**重跑收敛、不覆盖你自己的 `~/.zshrc`**)。动作:`install-omz` / `uninstall-omz`;`add-plugin <名|git-url>` / `remove-plugin <名>`(kit 自管插件:autosuggestions / syntax-highlighting / completions / history-substring-search / fzf / zoxide,其余按 git URL 克隆);**OMZ 原生插件** `add-omz-plugin <名>` / `remove-omz-plugin <名>`(curated:sudo / extract / colored-man-pages / command-not-found / docker / kubectl / z 等);**OMZ 设置逐项可配** `omz-setting <key> <值>`(update / magic / untracked-dirty / correction / wait-dots / hist-stamps,默认即性能/非交互安全最佳实践);`prompt git|plain|starship|powerlevel10k|pure`;`default-shell`(锁定安全);`configure [--framework|--prompt|--plugins|--omz-plugins|--omz-update|--omz-*|--no-plugins|--no-aliases|--default-shell]` 一次性全量指定;无参 = 保守 headless 基线。**`swkit zsh`(或 TUI 钻进 zsh)打开全屏组件管理器**:可交互开关框架、选提示符、空格勾选插件、`a` 键加任意 git 插件、OMZ 开启时还能勾选 OMZ 原生插件与调设置、设默认 shell——带参动作也可用 `swkit zsh add-plugin <名|url>` / `add-omz-plugin <名>` / `omz-setting <k> <v>` / `prompt <名>` 或 LLM。(**选 Starship/Powerlevel10k 会经 `fonts.sh` 自动装 MesloLGS NF**;但字形由本地客户端终端渲染,SSH 时还需在客户端装/选该字体。)**`claude` 是 Claude Code CLI 的安装器 + 扩展管理器**——装好 CLI 后,**外壳调用官方 `claude` CLI**(MCP、插件)+ 文件式(skills)管三条扩展轴:`swkit claude mcp-add <curated 名 | 名 -t stdio|http|sse -- 命令|URL>` / `mcp-remove` / `mcp-search`(curated:sequential-thinking / filesystem / memory / playwright / context7),`marketplace-add <owner/repo>` / `plugin-install <name@marketplace>` / `plugin-enable|disable`(curated marketplace:anthropics/claude-plugins-official、anthropics/skills),`skill-install <curated 名 | git-url [name] [subdir]>` / `skill-remove`(curated skill:pdf / docx / pptx / frontend-design / mcp-builder,取自 anthropics/skills)。默认 `--scope user`、全程用户态不 sudo、幂等、curated+任意添加、skill 删除前备份且 kit 自有 skill 受保护;**`swkit claude` 开三段勾选界面**(MCP / Plugins / Skills,空格切换、`x` 卸插件、「＋」行手动添加)。**`codegraph` 与 `trellis` 是两款面向 AI 编码代理的工具**(全局 npm 包、纯 CLI、绝不 sudo、缺 Node 时指向 `swkit node install`):**`codegraph`**(`@colbymchenry/codegraph`)是 100% 本地代码知识图谱——`swkit codegraph install` 装 CLI,`swkit codegraph configure [--target a,b]` = `codegraph install --yes` 把 MCP server 接入各 agent(Claude Code/Codex…),每个项目里再跑 `codegraph init -i` 建索引;**`trellis`**(`@mindfoldhq/trellis`,需 Node ≥18、运行时建议 Python ≥3.9)是把 specs/tasks/memory 持久化进 repo 的工程框架——`swkit trellis install` 装 CLI,`swkit trellis configure [--user <名>]` 在**当前 git 仓库**跑 `trellis init`(per-repo、默认从 `git config user.name` 取名、不在 git 仓内则报错,额外的 `--claude`/`--codex` 等 flag 透传);**`vscode`/`cursor` 是两款编辑器**(`swkit vscode install` 经 **Microsoft 官方 apt 源**装、回退 snap;`swkit cursor install` 取**官方 `.deb`** 经 apt 装,另有 `swkit cursor update` 重取最新 `.deb`;均为桌面 GUI 应用,SSH 下经 Remote-SSH/隧道使用);**`go`/`python` 是两个运行时**(`swkit go install` 装 apt `golang-go` 工具链;`swkit python install` 装 pip+venv+dev 开发环境层,**绝不移除系统自带的 `python3`**)。
- **统一接口**:每个 `scripts/<软件>.sh` 都支持 `meta` / `status` / `install` / `remove` / `configure`(可选) / `help`,以及 `ui`(交互界面,入口模式,**不在 `meta` 的 `ops` 里**);`status` 退出码 0 当且仅当已装/已生效(这就是幂等探针),`install`/`remove` 先查 `status` 再决定动作。
- **更新**:在 clone 里 `git pull`(或直接改脚本)即生效——`swkit` 直指 clone,无需重新部署。脚本的唯一来源就是这个 clone;只有改了 `skills/` 才需重跑 `./bootstrap.sh` 刷新 `~/.claude`/`~/.codex` 里的 skill。(`bootstrap.sh` 还会清理旧版遗留的 `~/.local/share/ubuntu-setup` 部署副本。)

## 参数(headless)

带任一安装参数、或在无终端环境(如 CI)运行时,脚本不进 TUI,改走 headless 流程并遵循这些参数:

| 参数 | 说明 |
| --- | --- |
| `--only claude` / `--only codex` | 只装其中一个 CLI(默认两个都装) |
| `--method native` / `--method npm` | 安装方式。默认 `native`(官方安装器,无 Node 依赖);`npm` 要求已有 Node.js ≥ 18 与 npm,且绝不 `sudo npm install -g`(也绝不为满足 npm 而自动装 Node) |
| `--with-node` | 额外用 apt 装 Node.js + npm |
| `--skip-skills` | 跳过 skill 部署(不写 `~/.claude` / `~/.codex`) |
| `--headless` | 即便有终端也强制走非交互流程 |
| `--tui` | 即便带了上面的参数也强制进 TUI(仍需有终端) |
| `-h` / `--help` | 用法说明 |

headless 只装两个 CLI / Node / skills;git、curl、zsh、docker 等种子脚本可在 TUI 里管,或用 `swkit` 直接跑。

**免密 sudo** 只在 UI 里开关——**没有命令行参数**:TUI 里在「设置」页,headless 里为一次性提示。开关显示当前状态、可来回切换;非交互运行(无终端)保持现状不动。

## 装完之后

1. **登录**:分别运行 `claude` 和 `codex`,按提示完成登录。
2. **管理这台机器**,两种方式任选:
   - **自己跑脚本**:`swkit list` 浏览,`swkit docker install`、`swkit zsh configure --default-shell` 直接执行。
   - **让 LLM 管理**(任意目录下):
     - Claude Code:`claude` 后直接说 "用 ubuntu-install skill 装 docker"、"用 zsh-setup skill 配置 zsh",或 "用 claude-extensions skill 给 Claude Code 装 context7 MCP / 装个插件 / 装个 skill"
     - Codex:输入 `/ubuntu-install` 再说 "install docker",输入 `/zsh-setup` 再说 "把 zsh 装好配好",或输入 `/claude-extensions` 再说 "装个 MCP / 插件 / skill"

LLM 会先用 `swkit list` / `swkit search` 发现脚本、给出要跑哪条命令的计划等你确认、再执行,失败即停并报告卡点,装完用 `status` 验证版本。**还没有脚本覆盖的软件**,在**本仓库**里加一个脚本(`cp scripts/TEMPLATE.sh`,用 `lib/common.sh` 的安全原语,往往十几行)、走正常 git 评审、重跑 bootstrap 部署——LLM 在你机器上只运行已有脚本,不在运行时生成脚本。守则见 [`skills/ubuntu-install/SKILL.md`](skills/ubuntu-install/SKILL.md)、[`skills/zsh-setup/SKILL.md`](skills/zsh-setup/SKILL.md) 与 [`skills/claude-extensions/SKILL.md`](skills/claude-extensions/SKILL.md)。

> **关于 sudo 密码**:LLM 通过自己的 shell 执行 sudo,该环境**没有交互终端,无法输入密码**。所以 `bootstrap.sh`(此刻你有终端)在 TUI 的「设置」页提供一个**开关**让你开启免密 sudo;开启就让你输一次密码、写入 `/etc/sudoers.d/ubuntu-setup-llm`,使 LLM 之后免密装软件、全自动;同一开关也能随时关闭(删除该文件)。脚本里的 `sudo_run` 会先 `sudo -n true` 探测(按退出码,不看文案),通过就直接装,否则**打印出那条要你手动执行的命令并停下**,把特权交还你——**绝不经手、回显、管道或存储你的密码,绝不自行写 NOPASSWD**。这是你在 UI 里显式授予、可见可撤的边界。

skill 部署位置:`~/.claude/skills/<name>/`(Claude Code 用户级 skill)与 `~/.codex/prompts/<name>.md`(Codex 自定义 prompt),`<name>` 为 `ubuntu-install`、`zsh-setup`、`claude-extensions`。重跑 `./bootstrap.sh` 会覆盖更新到最新版本。

## 开发者

### 校验脚本

```bash
# 语法检查(bootstrap、两个 lib、swkit、每个脚本)
for f in bootstrap.sh lib/common.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done
# 全部 source lib,统一带 -x 跟随、用 SCRIPTDIR 让 source 路径相对每个文件解析,保持零告警
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/ui.sh bootstrap.sh
./bootstrap.sh --help
```

### 新增一个软件

复制 `scripts/TEMPLATE.sh` 到 `scripts/<key>.sh`,保留其结构(`set -Eeuo pipefail`、`source lib/common.sh`、末尾 `kit_dispatch "$@"`),填好 `meta` / `status` / `do_install` / `do_remove`(以及可选的 `do_configure`)。所有提权 / 装包 / 改文件都走 `lib/common.sh` 的原语(`sudo_run`、`apt_install`、`backup_file` 等),不写裸 `sudo` / `apt-get` / `apt-key` / `sudo npm`。`meta` 的 `ops` 必须与实际实现的操作一致,`category` ∈ `essentials | common | ai | runtime`。**交互界面**:省略 `ui()` 即可白嫖一个由 `meta` 的 `ops` 合成的菜单(`ui_default_menu`);要更丰富就用 `lib/ui.sh` 的原语(`ui_run` / `ui_pick` / `ui_confirm` / `ui_input` / `ui_badge` / `ui_header`/`ui_footer`/`ui_row`/`ui_read_key`)手写 `ui()`——`ui` 是入口模式,**不要写进 `ops`**(`scripts/TEMPLATE.sh` 有完整注释样例,`scripts/zsh.sh` 是旗舰范例)。写完 TUI 与 `swkit list` 会自动收录。
