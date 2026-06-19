---
date: 2026-06-19
topic: Matt Pocock skills 多 agent 安装器(scripts/mattpocock-skills.sh)
status: approved
---

# Matt Pocock skills 多 agent 安装器(`scripts/mattpocock-skills.sh`)

## 背景与动机

用户想把 [`mattpocock/skills`](https://github.com/mattpocock/skills)(Matt Pocock 的"给真正工程师用"的 agent skills 合集)装进机器,要求:① 先研究该仓库、给出与现有脚本风格一致的安装方案;② **用本地 UI 选择要装哪些 skill**;③ **能卸载 skill**。

`claude.sh` 已有 skill 轴(`skill-install`/`skill-remove`,git clone + 拷到 `~/.claude/skills`),但**只面向 Claude Code 一个 agent**。而 `mattpocock/skills` 的官方安装路径是 `npx skills@latest add mattpocock/skills`,即 **vercel-labs/skills CLI**——一个能把同一份 skill 装进 **70+ 个 coding agent**(Claude Code / Codex / Cursor / OpenCode / Gemini CLI / Windsurf …)的"开放 agent skill 生态"工具。"不止配 Claude、还能配其他终端"正是用户要单独立项的核心动机。把这套多 agent 能力塞进本已很大的 `claude.sh` 既臃肿又不切题,故**新建独立脚本** `scripts/mattpocock-skills.sh`。

## 调研依据(2026-06-19 核验)

- **仓库 `mattpocock/skills`**:多 skill 仓,按类目分目录(`skills/engineering/`、`productivity/`、`misc/`、`personal/`、`in-progress/`、`deprecated/`),每个 skill 一个子目录含 `SKILL.md`。`.claude-plugin/plugin.json` 钦定了 **17 个**作为"插件"打包(engineering 12 + productivity 5)——本设计以此 17 个为 curated 目录。README 强调:装时**务必选上 `setup-matt-pocock-skills`**,装后运行 `/setup-matt-pocock-skills` 做问题跟踪器 / 标签 / 文档位置的一次性配置。
- **`skills` CLI(`vercel-labs/skills`,npm 包名 `skills`,latest 1.5.x,仅依赖 `yaml`)**:`bin` = `skills`/`add-skill`。命令与**非交互参数**(关键,使其可被我们自己的 UI 驱动):
  - `skills add <source> [-s <skill…>|'*'] [-a <agent…>|'*'] [-g] [-y] [--list] [--copy]`
  - `skills remove [skills…] [-s <skill…>] [-a <agent…>] [-g] [-y] [--all]`
  - `skills list`(别名 `ls`)、`skills update [skills…]`、`skills find`、`skills use`
  - `-g/--global` → 装到 `~/<agent>/skills/`(claude-code→`~/.claude/skills`、codex→`~/.codex/skills`、cursor→`~/.cursor/skills`、opencode→`~/.config/opencode/skills`、gemini-cli→`~/.gemini/skills`、windsurf→`~/.codeium/windsurf/skills`、github-copilot→`~/.copilot/skills`)。
  - skill 在所有 agent 下都是**统一的 `SKILL.md` 目录格式**,跨 agent 只是落点不同——故"读"可直接扫目录,无需格式转换。
  - 需要 **Node**(`npx`)。

## 决策

- **引擎(已与用户确认)**:**包一层官方 `skills` CLI**(而非自己 clone+copy)。理由:多 agent 能力是用户单独立项的核心诉求,而 `skills` CLI 白送 70+ agent、`list`/`remove`/`update` 语义正确、非交互参数齐全、脚本可保持小巧;代价是 Node 依赖,用 kit 现成 `swkit node install` 兜底。自己 clone+copy 虽零 Node,但要重造 add/list/remove/update 并手维护一张 70+ 项的 agent 路径表(会漂移),被否决。
- **读写分离(性能关键)**:
  - **读**(`status` / UI 状态):**直接扫**目标 agent 的全局 skills 目录(纯文件系统、离线、瞬时),**不**每帧 spawn 慢吞吞的 `npx`。为此维护一张**仅 curated 7 个 agent** 的 `agent→全局路径` 表(取自 README,小而稳)。
  - **写**(装/卸/更新):调 `npx -y skills@latest add/remove/update … -g -y`。
- **Node 守卫**:`_mps_node_gate` 检测 `node`+`npx`,缺失则 `log_*` 指向 `swkit node install` 并返回非 0(只挡"写";status/UI 读不需 Node)。仿 `claude.sh` 立场:**绝不自动装 Node、绝不 `sudo npm`**。
- **作用域**:仅 **global**(`-g`)——kit 是"配置我这台机器"。不做 per-project。
- **目标 agent 集**:可配,存 `~/.config/ubuntu-setup/mattpocock-skills.conf`(`AGENTS="claude-code codex"` 形式,kit pref store 范式)。curated 可选:`claude-code codex cursor opencode gemini-cli windsurf github-copilot`;UI 多选,`a` 可加任意 agent 名。首次默认 = 检测到的(至少 `claude-code`)。所有装/卸针对该集合。
- **curated skill 目录** = plugin.json 的 17 个,每个配 en/zh/ja 一行说明(**skill 名不译**,同项目铁律)。`setup-matt-pocock-skills` 特别标注"装后运行 /setup-matt-pocock-skills"。UI 里 `a` 可按名加任意 skill(覆盖 misc/personal/in-progress 等非 curated 的)。

## 架构

`mattpocock-skills.sh` 仍 `source lib/common.sh`、`category=ai`、以 `kit_dispatch "$@"` 收尾——**自动**出现在 bootstrap 目录与 `swkit`,**零 bootstrap 改动**。

### 常量 / 表
- `_MPS_SOURCE="mattpocock/skills"`、`_MPS_CONF="$XDG/ubuntu-setup/mattpocock-skills.conf"`。
- `_mps_skill_curated`:`case` 表,key→`类目<TAB>en 说明`(类目仅供分组展示);17 项。
- `_mps_agent_path <agent>`:curated 7 个 agent 的全局 skills 绝对路径(基于已解析的真实 HOME);未知 agent 返回非 0。
- `MPS_I18N` 关联数组(en/zh/ja),结构同 `claude.sh` 的 `CLAUDE_I18N`;`_mps_t KEY` / `_mps_tx KEY TOKEN VAL` 取值。

### 用户态守卫 / 路径解析
- `_mps_user_paths`:**拒绝 `EUID==0 && SUDO_USER`**(skills 写在 `$HOME`,须用户拥有),用 `SUDO_USER` 解析真实 home——同 `claude.sh` 的 `_claude_user_paths`。设 `_MPS_HOME`。
- agent 路径全部相对 `_MPS_HOME` 拼,绝不信任裸 `~`。

### 状态探测(离线、读)
- `_mps_skill_installed_in <skill> <agent>`:`[[ -f "$(_mps_agent_path agent)/<skill>/SKILL.md" ]]`。
- `_mps_skill_agents <skill>`:遍历目标集,回显装了该 skill 的 agent 列表。
- `_mps_installed_curated`:回显"目标集中至少一个 agent 装了的 curated skill"清单。
- `status`:`_mps_installed_curated` 非空即退 0,并打印 `<skill> → <agent…>` 概览;空则退非 0。
- **归属判定**:按 skill **名**匹配 curated 集(同名跨源极少见,注明该边界);UI 也展示"已装但非 curated"的 skill(扫目录得名)以便卸载。

### 写操作(经 `skills` CLI)
- `_mps_agents_args`:把目标集展开成 `-a a1 -a a2 …`(空集报错提示先 `set-agents`)。
- `do_install [args]`:Node 守卫 → 解析 `--skills`/`--agents`(缺省=curated 17 / 目标集)→ `npx -y skills@latest add "$_MPS_SOURCE" -g -y <-s…> <-a…>`。幂等性由 CLI 自身处理(已装跳过);装前若全部已装则 `log_info` 跳过。
- `do_remove [args]`:Node 守卫 → 缺省=从目标集所有 agent 卸掉所有 curated skill;`npx -y skills@latest remove -g -y <-s…> <-a…>`。**绝不** `--all`(那会连其他源的 skill 一起删)。
- `do_update [skills…]`:`npx -y skills@latest update -g -y [skills…]`。
- `do_configure`:`--recommended`(=装 17 到目标集)/`--skills "a b c"`/`--agents "…"`;**无参=保守基线**(仅确保默认目标集写入 conf,不装任何 skill)。
- 带参 op(`kit_dispatch` 路由、不进 meta.ops、UI 可达):
  - `add-skill <名…>` / `remove-skill <名…>`:对目标集装/卸指定 skill。
  - `set-agents <agent…>` / `add-agent <agent>` / `remove-agent <agent>`:维护目标集(校验 agent 名 `^[a-z0-9-]+$`;curated 直接认,非 curated 警告但允许)。
  - `list`:`npx -y skills@latest list -g`(直传官方列表;Node 守卫)。

### op 面(kit_dispatch)
- `meta.ops = install,remove,configure,update`(无参主操作)。**`ui` 不入 ops**。
- 带参 op 不进 meta.ops,在 `usage` 文档化、在 `ui()` 交互可达(见上)。

### `ui()`(自绘全屏,沿用 `claude.sh`/`zsh.sh` 并行数组 + header/spacer + `ui_run` 退屏跑)
- 顶部:标题 `Matt Pocock skills`;**Node 缺失**则首行红色横幅 + "run swkit node install"(读区仍可浏览,写行禁用/提示)。
- 段「Agents」:curated 7 个 + 已配的非 curated,`✓/○` 表是否在目标集;`space` 切换、`a` 加任意 agent 名。
- 段「Skills」:curated 17(按类目)+ 已装的非 curated;每行显示装在几个目标 agent(如 `claude-code, codex`);`space` = 在目标集装/卸该 skill;`a` 按名加任意 skill;`setup-matt-pocock-skills` 行附"装后运行 /setup-matt-pocock-skills"提示。
- 段「Actions」:`Install recommended (17)` / `Update all` / `Remove all (managed)`。
- 读走 fs 扫描(每帧便宜);改走 `ui_run "<标题>" -- "$0" <op> [args]` 退屏跑、可见输出 + 日志、回屏重载。
- 受限终端:`ui_default_menu` 回退(meta.ops 四项)。崩溃由 `ui_begin` 的 trap 还原终端。

## 集成 / 文档
- `CLAUDE.md`「当前状态」种子集补 `mattpocock-skills`,加一段要点(同其他脚本的描述密度)。
- `README` 种子集表补一行。
- **不**新增独立 SKILL.md(`claude-extensions` / `ubuntu-install` 已覆盖"用脚本管理 skill"的守则);在 `ubuntu-install` 的种子集描述里给一句指针即可(可选,实现时定)。
- 不改 bootstrap(TUI 经 meta 自动发现)。

## 安全
- 零新增 sudo;全程用户态、拒绝 sudo 包裹(`_mps_user_paths`)。
- **绝不自动装 Node、绝不 `sudo npm`**;Node 缺失优雅降级(读可用、写指路)。
- 写操作经官方 CLI(`-y` 非交互);`remove` 永不 `--all`,只删目标集里的指定/curated skill,避免误删其他源的 skill。
- agent / skill 名做正则校验,挡注入。
- skill 内容是上游仓库的,按"如实展示上游 description"处理(同 `claude.sh` 已装 skill 的描述取自其 `SKILL.md`)。

## 明确不做(v1 YAGNI)
- per-project 作用域 UI(只 global)。
- symlink vs copy 的 UI 开关(用 CLI 默认 symlink;`--copy` 可后续加)。
- 任意第三方源仓库的通用管理(本脚本专管 `mattpocock/skills`;源是常量,日后要泛化只需提取该常量)。
- `skills find` 的交互浏览界面(curated 17 + 按名 add 已够)。
- 自建已装清单 manifest(状态实时由 fs 扫描得出,符合 kit「幂等查活系统」原则)。

## 校验
`bash -n` → `shellcheck -x --source-path=SCRIPTDIR` → `meta` 字段齐全且 `ops` 与实现一致且不含 `ui` → `status`(装前/后,离线、无 Node 也能跑读路径)→ `ui` 无 TTY 打印指引退 0 → 伪终端冒烟 `ui`(渲染不崩、`q` 干净退出、终端复原)→ 本机 Node 在位,真跑 `add-skill grilling`(装到 claude-code)、`status`、`remove-skill grilling` 验证幂等与回退、确认 `~/.claude/skills/grilling/SKILL.md` 的增删。
