# ubuntu-setup

仓库包含两部分：Bash 软件管理脚本负责安装与配置，Python 只读检查原型负责检查机器状态并生成报告。两者目前各自运行，尚未接入统一的安装与检查流程。

- 软件管理：`./bootstrap.sh` 或 `swkit`，见[快速开始](#快速开始)。
- 只读检查：`./ubuntu-setup inspect`，见[只读检查原型](#只读检查原型)。

## Bash 软件管理

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成**用脚本集合管理软件**的机器。每个软件的**安装 / 卸载 / 配置逻辑都是一个 bash 脚本**(`scripts/<软件>.sh`,统一接口),背后由共享库 `lib/common.sh` 把项目的安全契约**写成可复用的代码**。脚本按类别组织,有三种方式驱动它们:

- **TUI**——`./bootstrap.sh` 进入的现代全屏菜单,按类别浏览脚本,**钻进每个软件自己的管理界面**(装/卸/配,zsh 还能勾插件、选提示符);
- **`swkit` 命令**——`swkit docker install` 直接跑,`swkit zsh` 开 zsh 的界面,`swkit ui` 开总目录;
- **LLM**(Claude Code / Codex)——你说"装个 docker",它在 skill 守则下**调用**脚本(挑对的脚本与选项、解释取舍);它只**运行并推荐**脚本,**不在你机器上编写或改写脚本**。

脚本统一在**本仓库**里维护。要新增软件覆盖或修过时的脚本,在仓库里加 / 改一个脚本(`cp scripts/TEMPLATE.sh`)、走正常 git 评审、再重跑 `bootstrap.sh` 部署——脚本提供稳定、确定、可测的执行,这是唯一权威来源。

> 软件管理部分采用纯 Bash，每个软件一个手写脚本；TUI 通过读各脚本自报的 `meta` 动态发现并归类它们。原先由数据驱动的 catalog 安装引擎已放弃。下文的 Python 原型只做检查，不执行安装脚本。

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
- **种子脚本**:`git`、`curl`、`zsh`、`fonts`、`docker`、`ghostty`、`tmux`、`rime`、`vscode`、`cursor`、`node`、`go`、`python`、`claude`、`codex`、`codegraph`、`trellis`、`mattpocock-skills`。`docker` 的 `configure` 加 docker 组 + 起服务,`git` 的 `configure` 设全局 user.name/email(写 `~/.gitconfig`,绝不 sudo);**`ghostty` 是 Ghostty 终端的安装+配置管理器**(渠道:apt〔26.04+〕→ 社区 `.deb`〔24.04/25.10〕→ snap;`swkit ghostty configure --theme <名> --font <族|none> --size <pt> --opacity <0-1> --cursor <block|bar|underline> --padding <px> --copy-on-select on|off …` 管**主题/字体/常用项**,主题按 `ghostty +list-themes` 校验、支持 `dark:…,light:…`,curated Nerd Font 经 `fonts.sh` 自动装;偏好存 `~/.config/ubuntu-setup/ghostty.conf`,写受管 drop-in `~/.config/ghostty/ubuntu-setup` 并经绝对路径 `config-file=` include 进你的 `~/.config/ghostty/config`,**不覆盖你的配置**;`swkit ghostty` 开全屏管理器。`swkit ghostty default-terminal`〔`off` 反转〕把它设为默认终端:用户态写 freedesktop `xdg-terminal-exec` 选择器(`~/.config/<desktop>-xdg-terminals.list` 首行,GNOME 25.04+ Ctrl+Alt+T 走此),best-effort 再经 `sudo update-alternatives` 注册系统 `x-terminal-emulator`(仅 .deb/apt;snap 跳过;失败仅告警)。Ghostty 是桌面 GUI 终端,SSH 时设置作用于有显示器的机器);**`tmux` 是 tmux 的安装+组件管理器**(像 `zsh` 一样按组件管理):`swkit tmux install`;`swkit tmux configure` 暴露丰富的最佳实践设置(`--theme`/`--status-position`/`--status-interval`/`--mouse`/`--clipboard`/`--focus-events`/`--aggressive-resize`/`--renumber`/`--base-index`/`--monitor-activity`/`--set-titles`/`--keymode`/`--prefix`/`--keybindings`〔`|`/`-` 分屏 + vim hjkl 窗格导航 + vi 复制〕/`--window-nav`〔Alt+1..9 跳窗口 + Shift-←/→ 前后窗口〕/`--copy-mode-key`〔自定义进 copy-mode 的键〕/`--tree-key`〔自定义窗口树 choose-tree 的键〕/`--history`/`--escape-time`/`--plugins`/`--recommended` 等)写成 `~/.tmux.conf` 里的**受管标记块**(改前备份、保留标记外内容;用主配置标记块而非单独 drop-in,因 **TPM 只从主配置 grep `@plugin`、不跟随 `source-file`**);`swkit tmux add-plugin <名|owner/repo|git-url>` / `remove-plugin <名>` 经 **TPM** 增删插件(curated:sensible / resurrect / continuum / yank / pain-control / vim-navigator / open / fzf / battery / cpu / prefix-highlight,其余按 git 仓),另有 `install-tpm` / `uninstall-tpm` / `update-plugins`、`theme <名> [flavor]`;`swkit tmux` 开全屏管理器(每个设置都是快捷 开关/选择器/输入,Appearance/Behavior/Keys/History 分组 + 视口滚动;空格勾插件、`a` 加任意仓、「Apply recommended setup」一键装 TPM+常用插件+catppuccin+人体工学键位)。无参 `configure` = 保守最佳实践基线(mouse on、vi 复制、true color、不装插件/不重映射键位);插件经 TPM 的 `bin/` 脚本无 TTY 驱动,tmux 是多路复用器、SSH/headless 完美适用);**`rime` 是 RIME 输入法的安装+组件管理器**(框架 **fcitx5**;像 `zsh`/`tmux` 一样按组件管理):`swkit rime install` 经 apt 装 `fcitx5 + fcitx5-rime + GTK/Qt IM 模块(fcitx5-frontend-all,**缺了会回退 XIM 致候选框定位错乱**)+ im-config` 并以用户态 `im-config -n fcitx5` 选定框架,写三个**受管文件**(改前备份)——IM 环境 `~/.config/environment.d/ubuntu-setup-rime.conf`(`GTK/QT/XMODIFIERS`=fcitx,需重新登录)、RIME patch `~/.local/share/fcitx5/rime/default.custom.yaml`(启用方案 + 候选词个数)、以及 **fcitx5 登录自启** `~/.config/autostart/org.fcitx.Fcitx5.desktop`(**Wayland 必需**:Ubuntu 默认的 Wayland 会话下 im-config/im-launch 不启动 IM 守护、fcitx5 包也不带 autostart,不自写则登录后无人启动 fcitx5、桌面退回自带 IBus);`swkit rime configure --schemas "luna_pinyin_simp luna_pinyin" --default-schema <id> --page-size <5-10> --recommended` 管**输入方案与选项**(curated 内置方案 luna_pinyin_simp〔简体优先〕/ luna_pinyin / bopomofo / wubi86 / cangjie5 / double_pinyin_flypy〔小鹤双拼〕… 一行说明 en/zh/ja 本地化),`add-schema`/`remove-schema`/`set-default-schema` 增删方案;**`install-rime-ice` 一键装雾凇拼音 rime-ice**(纯用户态、需 git,`git clone iDvel/rime-ice` 后清单式复制进 RIME 目录、可经 `remove-rime-ice` 精确还原);`swkit rime deploy` 触发重新部署(`fcitx5-remote -r`);`swkit rime` 开全屏管理器(空格勾方案、`d` 设默认、`a` 加任意方案、装/卸 rime-ice、Deploy/Apply recommended)。`remove` 保守(仅卸 `fcitx5-rime`,留 fcitx5/环境/数据)。RIME/fcitx5 是桌面输入法,SSH/headless 下设置作用于有显示器的机器、重新登录生效);**`fonts` 是用户态 Nerd Font 管理器**(`swkit fonts install [meslolgs|jetbrains-mono|firacode|hack]` / `swkit fonts apply [name] [size] [auto|ptyxis|gnome-terminal|gnome-desktop|instructions]` / `swkit fonts configure --font <name> --size <pt> --target <target>` / `swkit fonts ui`,装入 `~/.local/share/fonts` + `fc-cache`,把偏好保存到 `~/.config/ubuntu-setup/fonts.conf`,并用用户级 gsettings 应用到支持的本地终端/桌面 monospace,绝不 sudo);**`zsh` 是一个组件管理器**——框架(Oh My Zsh)、提示符、各插件都能**独立装/卸/增/删**,状态记在 `~/.config/zsh/ubuntu-setup.conf`,每次改动重生成受管 drop-in `~/.config/zsh/ubuntu-setup.zsh` 并在 `~/.zshrc` 加一行 source(**重跑收敛、不覆盖你自己的 `~/.zshrc`**)。动作:`install-omz` / `uninstall-omz`;`add-plugin <名|git-url>` / `remove-plugin <名>`(kit 自管插件:autosuggestions / syntax-highlighting / completions / history-substring-search / fzf / zoxide,其余按 git URL 克隆);**OMZ 原生插件** `add-omz-plugin <名>` / `remove-omz-plugin <名>`(curated:sudo / extract / colored-man-pages / command-not-found / docker / kubectl / z 等);**OMZ 设置逐项可配** `omz-setting <key> <值>`(update / magic / untracked-dirty / correction / wait-dots / hist-stamps,默认即性能/非交互安全最佳实践);`prompt git|plain|starship|powerlevel10k|pure`;`default-shell`(锁定安全);`configure [--framework|--prompt|--plugins|--omz-plugins|--omz-update|--omz-*|--no-plugins|--no-aliases|--default-shell]` 一次性全量指定;无参 = 保守 headless 基线。**`swkit zsh`(或 TUI 钻进 zsh)打开全屏组件管理器**:可交互开关框架、选提示符、空格勾选插件、`a` 键加任意 git 插件、OMZ 开启时还能勾选 OMZ 原生插件与调设置、设默认 shell——带参动作也可用 `swkit zsh add-plugin <名|url>` / `add-omz-plugin <名>` / `omz-setting <k> <v>` / `prompt <名>` 或 LLM。(**选 Starship/Powerlevel10k 会经 `fonts.sh` 自动装 MesloLGS NF**;但字形由本地客户端终端渲染,SSH 时还需在客户端装/选该字体。)**`claude` 是 Claude Code CLI 的安装器 + 扩展管理器**——装好 CLI 后,**外壳调用官方 `claude` CLI**(MCP、插件)+ 文件式(skills)管三条扩展轴:`swkit claude mcp-add <curated 名 | 名 -t stdio|http|sse -- 命令|URL>` / `mcp-remove` / `mcp-search`(curated:sequential-thinking / filesystem / memory / playwright / context7),`marketplace-add <owner/repo>` / `plugin-install <name@marketplace>` / `plugin-enable|disable`(curated marketplace:anthropics/claude-plugins-official、anthropics/skills),`skill-install <curated 名 | git-url [name] [subdir]>` / `skill-remove`(curated skill:pdf / docx / pptx / frontend-design / mcp-builder,取自 anthropics/skills)。默认 `--scope user`、全程用户态不 sudo、幂等、curated+任意添加、skill 删除前备份且 kit 自有 skill 受保护;**`swkit claude` 开三段勾选界面**(MCP / Plugins / Skills,空格切换、`x` 卸插件、「＋」行手动添加)。**`codegraph` 与 `trellis` 是两款面向 AI 编码代理的工具**(全局 npm 包、纯 CLI、绝不 sudo、缺 Node 时指向 `swkit node install`):**`codegraph`**(`@colbymchenry/codegraph`)是 100% 本地代码知识图谱——`swkit codegraph install` 装 CLI,`swkit codegraph configure [--target a,b]` = `codegraph install --yes` 把 MCP server 接入各 agent(Claude Code/Codex…),每个项目里再跑 `codegraph init -i` 建索引;**`trellis`**(`@mindfoldhq/trellis`,需 Node ≥18、运行时建议 Python ≥3.9)是把 specs/tasks/memory 持久化进 repo 的工程框架——`swkit trellis install` 装 CLI,`swkit trellis configure [--user <名>]` 在**当前 git 仓库**跑 `trellis init`(per-repo、默认从 `git config user.name` 取名、不在 git 仓内则报错,额外的 `--claude`/`--codex` 等 flag 透传);**`vscode`/`cursor` 是两款编辑器**(`swkit vscode install` 经 **Microsoft 官方 apt 源**装、回退 snap;`swkit cursor install` 取**官方 `.deb`** 经 apt 装,另有 `swkit cursor update` 重取最新 `.deb`;均为桌面 GUI 应用,SSH 下经 Remote-SSH/隧道使用);**`go`/`python` 是两套开发环境管理器**(runtime,像 `zsh`/`tmux` 一样按组件管理):**`go`** 经 `swkit go install` 装 apt `golang-go` 基础工具链,`swkit go configure --recommended`(或开 `swkit go`)一键配 **GOBIN(`~/go/bin`)上 PATH** + **GOPROXY**(curated `goproxy.cn`/`goproxy.io`/`direct` 等,经 `go env -w` 写 `~/.config/go/env`)+ **curated 工具**(`gopls`/`dlv`/`golangci-lint`/`goimports`/`staticcheck`/`gofumpt`,各经 `go install …@latest` 用户态装入 GOBIN),另有 `set-proxy`/`tools`/`update-tools`/`add-tool`/`remove-tool`;**`python`** 经 `swkit python install` 装 apt 系统层(pip+venv+dev,**绝不动系统 `python3`**),`swkit python configure --recommended`(或开 `swkit python`)装 **uv**(Astral 的现代统一管理器,官方脚本入 `~/.local/bin`、用户态不 sudo,取代 pip/venv/pipx/poetry/pyenv)+ **ruff** 等 uv 工具,另有 `install-uv`/`update-uv`/`remove-uv`、`tools`/`update-tools`/`add-tool`/`remove-tool`、`set-index`(pip+uv 包索引镜像,curated `tsinghua`/`aliyun`/`ustc`);两者的 configure/工具/代理动作均**用户态、拒绝 sudo 包裹**,仅 apt 经 `sudo_run` 逐命令提权);**`mattpocock-skills` 是 Matt Pocock skills 合集([`mattpocock/skills`](https://github.com/mattpocock/skills))的多 agent 安装器**(ai):它包一层开放 agent-skill CLI `skills`(`vercel-labs/skills`,`npx -y skills@latest`),把同一份 `SKILL.md` 装进**多个 agent**(curated:`claude-code`/`codex`/`cursor`/`opencode`/`gemini-cli`/`windsurf`/`github-copilot`,CLI 支持 70+)。**`swkit mattpocock-skills`** 开全屏管理器:**Target agents** 区勾选要配置的 agent、**Skills** 区按类目勾选要装的 skill(curated 17 个 = 仓库 plugin 钦定集,可按名加任意 skill),Actions 区一键「装推荐 17 / 更新 / 卸全部」;读直接扫各 agent 的 `~/<agent>/skills/`(离线),写走 `skills add/remove/update`。带参动作也可用 `swkit mattpocock-skills add-skill <名…>` / `remove-skill <名…>` / `set-agents <agent…>` / `update` 或 LLM;`configure --recommended` 一键装 17。目标 agent 集存 `~/.config/ubuntu-setup/mattpocock-skills.conf`,全程用户态、**绝不自动装 Node**(缺则指向 `swkit node install`、只挡写)、`remove` 永不 `--all` 以免误删其他源 skill)。
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

## 只读检查原型

计划开发一个 Ubuntu 系统初始化与维护 Agent，帮助用户了解机器现状、维护系统和驱动、补齐日常能力，再按个人用途安装软件和调整配置。

目标是在 Codex CLI、Claude Code CLI 或其他 Agent 工具中使用，暂以 Ubuntu 为首个目标平台。

兼容性是所有变更的前提：软件、系统配置和驱动都需核对目标环境、现有组件及相互依赖。计划要包含依赖升级、降级和移除等连带变更，变更后验证实际功能。存在兼容性冲突或缺少关键依据时，先解决问题，再执行受影响的变更；验证失败或等待重启时，暂缓依赖其生效的步骤。

已确定的主流程是：每次运行先收集或更新机器信息，补充用途与约束，统一规划，再依次完成系统与驱动维护、通用能力补充、个性化配置。每组变更后验证实际功能；软件、配置或硬件发生变化时，重新检查受影响的部分。

目前已实现只读检查原型：采集系统、软件、硬件与驱动信息，检查软件依赖、驱动匹配、设备功能、更新来源和部分设置的生效状态，保存机器档案并比较变化。该原型的安装、修复、任意新软件的版本选择和完整兼容性验证尚未实现。开发约定见 [AGENTS.md](AGENTS.md)。

采集由 Python 命令行程序完成，Agent 可调用它并读取 JSON 结果。当前已提供独立检测规则、能力目录、证据引用和规则版本记录，详见 [检测规则](docs/detection-rules.md)。检查原型的专用 Skill、MCP 接入和自动自进化尚未实现，后续分工与实施顺序见 [Agent 接入与能力改进](docs/agent-integration-and-evolution.md)。

### 运行原型

需要 Linux 和 Python 3.10 或更新版本。推荐从仓库根目录通过 `./ubuntu-setup` 启动；它会先寻找已经存在的 Python 3.10+ 解释器，不会因只读检查自动安装 Python。主程序使用标准库；依赖与更新检查调用系统的 `/usr/bin/python3`、`python3-apt` 和 `apt-get`，驱动检查使用 `modinfo`，绘制测试使用已有的 EGL/GLES 图形库。缺少可选工具时报告未知。

```sh
./ubuntu-setup inspect
```

如果没有找到 Python `3.10+`，启动器会返回 `runtime_unavailable`，不会修改系统。明确允许安装时执行：

```sh
swkit python configure --python 3.12
```

该操作会安装用户态 uv 和 Python `3.12`，需要联网；缺少 `curl` 时会先经 apt 安装 `curl` 和 `ca-certificates`，并会调整 shell rc 中的 PATH 和 uv 补全。它不替换 `/usr/bin/python3`。直接使用 `python3 -m ubuntu_setup` 仍可作为已确认运行时满足要求时的底层入口。

命令检查当前运行环境，使用普通用户权限，不安装软件、不更新软件包索引、不修改系统配置。程序会在自己的状态目录保存记录；检测权限不足或工具缺失的项目记为未知。

检查完成后生成 HTML 报告，并自动请求默认浏览器打开。报告先说明具体问题，紧接着列出“你现在要做”和助手的后续建议。已发现的问题、后续维护、没有查清的项目分别列出。完整检查表、电脑信息、前后变化和技术记录放在后面，按需展开；支持筛选、搜索和打印。无需弹出页面时使用 `--no-open`，无桌面环境或打开失败时仍保存报告。详见 [HTML 报告](docs/html-reports.md)。

再次运行同一命令，会与之前的档案比较。默认记录目录是 `${XDG_STATE_HOME}/ubuntu-setup/targets/local/`；未设置 `XDG_STATE_HOME` 时，使用 `~/.local/state/ubuntu-setup/targets/local/`。使用 `--state-dir` 可指定仓库之外的独立私有目录。

通过参数增加配置监测或输出结构化报告：

```sh
./ubuntu-setup inspect --watch-config /etc/apt/sources.list --format json
./ubuntu-setup inspect --format json --no-open
```

`--format json` 只改变终端输出，HTML 报告仍会生成并默认打开。配置监测只保存文件摘要和基本属性，不保存文件内容，也不代表配置已通过语法或功能验证。完整使用说明、采集范围和退出码见 [只读原型](docs/prototype.md)。

Agent 可先查询已有能力，再决定如何使用检查结果。目录查询不采集机器信息，也不写入档案：

```sh
./ubuntu-setup capabilities --format json
./ubuntu-setup capabilities --check services
```

`0.8.0` 提供 12 条已实现的规则，其中 3 条仅记录环境或清单信息。本版调整报告结构和文字，保留 `0.7.0` 的检测判断；5 项扩展检查的范围、依据和限制见 [扩展检查](docs/extended-checks.md)。检查已实现不代表结果一定通过；信息缺失、功能未确认和等待生效仍会单独列出。

默认更新检查使用本地缓存。要核实软件源签名、索引有效期和当前更新候选，可运行：

```sh
./ubuntu-setup inspect --online --timeout 30
```

联网检查只在临时目录下载索引，完成或超时后清理，不修改本机索引、不触发本机的更新钩子，不安装软件。绘制测试创建一个看不见的 1 像素画面并读回结果，不截取屏幕、不播放或录制声音、不读取键盘输入。屏幕、声音和键鼠的实际使用结果由用户确认；Agent 按报告编号记录反馈，环境变化后重新确认，具体命令见 [设备确认](docs/extended-checks.md#设备实际使用确认)。

### 模拟检查与测试

以下命令使用仓库中的合成数据，不读取本机系统信息。模拟档案必须与真实档案分开：

```sh
ubuntu_setup_demo_dir=$(mktemp -d)
./ubuntu-setup inspect --fixture tests/fixtures/desktop.json --state-dir "$ubuntu_setup_demo_dir"
```

运行自动测试：

```sh
bash -n bin/ubuntu-setup ubuntu-setup test/runtime_launcher_test.sh
shellcheck -x bin/ubuntu-setup ubuntu-setup test/runtime_launcher_test.sh
test/runtime_launcher_test.sh
python3 -m unittest discover -s tests -v
git diff --check
```

测试覆盖启动器解释器选择与阻塞输出，重复检查、软件与硬件变化、配置修改、检测失败、待重启、档案损坏、并发写入、检查中断，以及 HTML 内容转义、文案是否保持判断含义、旧报告续接和浏览器打开失败。自动测试不安装 Python、不实际弹出浏览器。`git diff --check` 只检查已跟踪差异；新增文件需另外检查。

首批只读实测环境为 Ubuntu 24.04、x86_64、Python 3.12.3。其他系统、架构、真实虚拟化环境和设备功能尚未实测；模拟结果不构成实机支持证明。实际验证记录见 [只读原型](docs/prototype.md)。

### 设计文档

设计文档按以下顺序阅读：

| 文档 | 内容与状态 |
| --- | --- |
| [检测规则与能力目录](docs/detection-rules.md) | 已实现：能力查询、规则范围、证据字段、版本变化与扩展方法 |
| [HTML 报告与自动打开](docs/html-reports.md) | 已实现：交互报告、默认打开浏览器、无桌面环境处理与旧记录兼容 |
| [工作流](docs/workflow.md) | 已确定的阶段顺序、变化处理与执行边界 |
| [机器信息与稳定性检查](docs/inventory-and-health.md) | 细节草案：采集范围、检查结果、通过条件 |
| [数据保存与任务执行](docs/storage-and-execution.md) | 细节草案：本地文件、记录字段、任务状态与中断恢复 |
| [用户交互](docs/user-interaction.md) | 细节草案：对话顺序、计划展示、授权续接与待定选择 |
| [Agent 接入与能力改进](docs/agent-integration-and-evolution.md) | 开发约定：公共程序与 Agent 的分工、能力接口、改进验证与版本采用；专用接入及自动改进待实现 |

上述设计覆盖完整产品流程，其中尚未实现的字段、路径和状态仍是草案。当前可用命令与实际存储格式以 [只读原型](docs/prototype.md) 为准。后续安装与维护步骤须在对应实现中查证并记录支持范围。
