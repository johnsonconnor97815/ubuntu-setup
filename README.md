# ubuntu-setup

把一台**全新安装的 Ubuntu**(含 Server / SSH / 无桌面)变成由 LLM 驱动的软件管理机器。每个软件的**安装 / 卸载 / 配置逻辑都是一个 bash 脚本**(`scripts/<软件>.sh`,统一接口),背后由共享库 `lib/common.sh` 把项目的安全契约**写成可复用的代码**。你有三种方式驱动这些脚本:

- **TUI**——`./bootstrap.sh` 进入的菜单,按类别浏览脚本、装/卸/配;
- **`swkit` 命令**——`swkit docker install` 这样直接跑;
- **LLM**(Claude Code / Codex)——你说"装个 docker",它在 skill 守则下调用脚本。

LLM 在三个入口里独特:它不只**调用**脚本,还能**组织、推荐、并演进**脚本——为还没覆盖的软件**写一个新脚本**(借鉴官方文档与开源做法),并在某软件打包方式 / URL / 步骤变更导致脚本过时时**把它修好**。"脚本提供稳定确定可测的执行,LLM 让脚本保持最新"——所以覆盖范围会随使用增长。仓库交付的是**一套种子脚本 + 这套机制**,不是一个预先穷举的大库。

> 没有 Python 包、没有数据驱动的 catalog 引擎(那是被放弃的旧方向)。纯 bash,每个软件一个手写(或 LLM 写)的脚本;TUI 通过读各脚本自报的 `meta` 动态发现它们。

## 快速开始

```bash
git clone <repo-url>
cd ubuntu-setup
./bootstrap.sh
```

有终端时,`./bootstrap.sh` 默认进入 **TUI**(whiptail,缺失则回退纯文本菜单):

- **安装软件**(动态浏览脚本集合,三级):**类别**(essentials / common / ai / runtime,其余归 other)→ **软件** → **操作**。进入某软件后只列它真正实现的操作——一般是**安装 / 卸载**,zsh、docker 另有**配置**;`meta` 没声明的操作不会出现。已装的软件在列表里标注 `[installed]`(实时调脚本的 `status` 判断),操作幂等(重复安全)。每个操作在**进度条**后台进行,完整日志写到 `~/.cache/ubuntu-setup/`,完成弹出结果并回到操作菜单——单个操作失败也只记下日志、不带崩整个会话。
- **设置**:切换界面**语言**(中文 / English / 日本語,记到 `~/.config/ubuntu-setup/config`);**开/关 LLM 免密 sudo**(见文末)。

脚本幂等,可随时安全重跑:已装好的组件会在**真实系统**上被检测并跳过;失败后修因重跑即可续装。全程不需要整体 root——只有确需 root 的单条命令(apt、docker 加组、zsh `chsh`)会**逐命令** `sudo`;CLI 的官方安装器与 `npm install -g` 一律以当前用户身份跑。

## 直接用 swkit

脚本集合部署后,`swkit` 会被软链到你的 PATH(`~/.local/bin/swkit`),可以不进 TUI 直接驱动:

```bash
swkit list                          # 按类别列出所有脚本,已装的标 [installed]
swkit search nginx                  # 在 key / 名称 / 描述里大小写不敏感地搜
swkit docker install                # 跑 scripts/docker.sh install
swkit docker status                 # 是否已装?退出码 0 表示是
swkit zsh configure --default-shell # 多余参数原样透传给脚本
swkit help
```

`swkit <软件> <操作> [args...]` 映射到 `scripts/<软件>.sh <操作>`,退出码原样透传。每个脚本都支持 `install`、`remove`、`status`、`meta`、`help`(部分还有 `configure`)。没有对应脚本时,`swkit` 会提示你(或 LLM)从 `scripts/TEMPLATE.sh` 复制一个出来。

## 脚本集合

- **部署位置**:`~/.local/share/ubuntu-setup/`(即 `$KIT_HOME`),收纳 `lib/`、`scripts/`、`swkit`,且**本身是一个 git 仓**。
- **种子脚本**:`git`、`curl`、`zsh`、`docker`、`node`、`claude`、`codex`。`docker` 与 `zsh` 还支持 `configure`。**`zsh configure` 是可管理的富配置**:无参 = 保守 headless 安全基线(history / 补全 / 键位 / 颜色别名 + apt 插件 + git 分支 ASCII 提示符),写入受管 drop-in `~/.config/zsh/ubuntu-setup.zsh` 并在 `~/.zshrc` 加一行 source——**重跑更新到最新、不覆盖你自己的 `~/.zshrc`**;可选 `--framework oh-my-zsh`、`--prompt git|plain|starship|powerlevel10k|pure`、`--default-shell`(锁定安全)、`--no-plugins`、`--no-aliases`。TUI 里 zsh 另有 `oh-my-zsh` / `starship` / `default-shell` 独立动作可一键选。(Starship/Powerlevel10k 的图标需本地终端装 Nerd Font;headless 建议 git/plain/Pure。)
- **统一接口**:每个 `scripts/<软件>.sh` 都支持 `meta` / `status` / `install` / `remove` / `configure`(可选) / `help`;`status` 退出码 0 当且仅当已装/已生效(这就是幂等探针),`install`/`remove` 先查 `status` 再决定动作。
- **更新不丢改动**:重跑 `./bootstrap.sh` 时,出厂脚本被刷进一条 `vendor` 分支再 `git merge` 进工作树(`main`),**绝不盲目覆盖**——LLM 新写的脚本原样保留,只有"出厂版与本地都改了同一文件"才作为合并冲突显式留给你处理。每一次改动都被 git 跟踪(可回滚、可 PR 回上游)。

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
     - Claude Code:`claude` 后直接说 "用 ubuntu-install skill 装 docker" 或 "用 zsh-setup skill 配置 zsh"
     - Codex:输入 `/ubuntu-install` 再说 "install docker",或输入 `/zsh-setup` 再说 "把 zsh 装好配好"

LLM 会先用 `swkit list` / `swkit search` 发现脚本、给出要跑哪条命令的计划等你确认、再执行,失败即停并报告卡点,装完用 `status` 验证版本。**还没有脚本覆盖的软件,LLM 可以从 `scripts/TEMPLATE.sh` 复制一个新脚本写出来**(用 `lib/common.sh` 的安全原语,往往十几行);写完 git 跟踪、可审、可回滚。守则见 [`skills/ubuntu-install/SKILL.md`](skills/ubuntu-install/SKILL.md) 与 [`skills/zsh-setup/SKILL.md`](skills/zsh-setup/SKILL.md)。

> **关于 sudo 密码**:LLM 通过自己的 shell 执行 sudo,该环境**没有交互终端,无法输入密码**。所以 `bootstrap.sh`(此刻你有终端)在 TUI 的「设置」页提供一个**开关**让你开启免密 sudo;开启就让你输一次密码、写入 `/etc/sudoers.d/ubuntu-setup-llm`,使 LLM 之后免密装软件、全自动;同一开关也能随时关闭(删除该文件)。脚本里的 `sudo_run` 会先 `sudo -n true` 探测(按退出码,不看文案),通过就直接装,否则**打印出那条要你手动执行的命令并停下**,把特权交还你——**绝不经手、回显、管道或存储你的密码,绝不自行写 NOPASSWD**。这是你在 UI 里显式授予、可见可撤的边界。

skill 部署位置:`~/.claude/skills/<name>/`(Claude Code 用户级 skill)与 `~/.codex/prompts/<name>.md`(Codex 自定义 prompt),`<name>` 为 `ubuntu-install`、`zsh-setup`。重跑 `./bootstrap.sh` 会覆盖更新到最新版本。

## 开发者

### 校验脚本

```bash
bash -n bootstrap.sh                          # 语法检查(对每个 scripts/*.sh、lib/common.sh、swkit 同样跑)
shellcheck bootstrap.sh                        # 如已安装 shellcheck
# 脚本与 swkit 会 source lib/common.sh:带 -x 跟随,用 SCRIPTDIR 让 source 路径相对每个文件解析
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh
./bootstrap.sh --help
```

### 新增一个软件

复制 `scripts/TEMPLATE.sh` 到 `scripts/<key>.sh`,保留其结构(`set -Eeuo pipefail`、`source lib/common.sh`、末尾 `kit_dispatch "$@"`),填好 `meta` / `status` / `do_install` / `do_remove`(以及可选的 `do_configure`)。所有提权 / 装包 / 改文件都走 `lib/common.sh` 的原语(`sudo_run`、`apt_install`、`backup_file` 等),不写裸 `sudo` / `apt-get` / `apt-key` / `sudo npm`。`meta` 的 `ops` 必须与实际实现的操作一致,`category` ∈ `essentials | common | ai | runtime`。写完 TUI 与 `swkit list` 会自动收录。
