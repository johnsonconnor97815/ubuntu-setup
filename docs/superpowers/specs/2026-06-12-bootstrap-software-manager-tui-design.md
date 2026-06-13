# 设计:bootstrap.sh 安装界面重构为「类别 → 软件 → 操作」软件管理器

- 日期:2026-06-12
- 状态:已与作者确认,待实现
- 影响文件:`bootstrap.sh`、`CLAUDE.md`、(可能)`README.md`、`skills/zsh-setup/SKILL.md`(drift 提示)

## 1. 背景与动机

当前 `bootstrap.sh` 的安装入口 `tui_install` 是一个**扁平多选 checklist**,只有 4 个固定项(Claude Code CLI、Codex CLI、Node.js+npm、LLM skills),且只能「安装」。

作者希望把它重构为**三级层级导航**:

```
类别(常用软件 / 装机必备 …) ── 回车 ──▶ 该类别下的软件列表
软件                          ── 回车 ──▶ 该软件的操作(安装 / 卸载 / 配置)
```

并借此把 TUI 从「只装固定几项」**扩成一个精选软件管理器**。

### 方向性变更:与现有约束的冲突已被作者明确接受

现行 `CLAUDE.md` 锁定了「**TUI 只菜单化 bootstrap 自身那几个固定安装项,不做通用 catalog;装完之后的通用软件管理(docker 等)交给 LLM 的 skill,不进 TUI**」。本设计**有意修改**这条约束(见 §8)。但放弃 Python/YAML **数据驱动 catalog 引擎**的硬约束**仍然保留**——新目录是**纯 bash、写死、有界**的,不引入任何数据驱动清单或外部依赖。

## 2. 已确认的决策(设计输入)

1. **范围**:扩成软件管理器(不是单纯重排现有 4 项)。
2. **边界**:精选起步集——每个软件用 bash 函数写死装/卸/配;长尾/任意软件仍交 LLM skill。
3. **操作集**:装 / 卸 / 配;没有有意义「配置」的软件**不显示**「配置」项。
4. **起步目录**:
   - 装机必备(essentials):git、curl、zsh
   - 常用软件(common):docker
   - AI 编码 CLI(ai):Claude Code CLI、Codex CLI
   - 运行时(runtime):Node.js + npm
   - LLM 资产(assets):skills
5. **执行模式**:单软件单操作——钻进某软件→选一个操作→即时执行(写日志到 `~/.cache/ubuntu-setup/`)→完成后回到该软件菜单。
6. **headless / flags**:`--only` / `--method` / `--with-node` / `--skip-skills` 等原样兼容;扩出来的 git/docker/zsh 等**只在 TUI 里管**;CI/无终端路径不变。

## 3. 架构:约定式函数注册表(方案 A)

被否决的备选:**B 声明式关联数组清单**(卸载/配置难数据化,且推回已放弃的 catalog 老路);**C 最小改动 + 另开管理页**(交付不了层级,两套 UI 并存)。

### 3.1 目录数据

```bash
# 类别顺序(显示顺序);label 经 t() 取多语言串
CATALOG=(essentials common ai runtime assets)

declare -A CAT_ITEMS=(
  [essentials]="git curl zsh"
  [common]="docker"
  [ai]="claude codex"
  [runtime]="node"
  [assets]="skills"
)
```

### 3.2 每个软件的函数约定

软件键 `<key>` 对应一组按命名约定的函数:

- `sw_<key>_status` —— 返回 0 表示「已安装/已部署」。**幂等核心**,只观察真实系统(`command -v`、`dpkg-query`、目录存在等)。
- `sw_<key>_install`
- `sw_<key>_remove`
- `sw_<key>_configure` —— **可选**。是否存在(`declare -F "sw_<key>_configure"`)决定操作菜单是否显示「配置」。

通用辅助:

- `sw_supports_op <key> <op>` → `declare -F "sw_<key>_${op}" >/dev/null`(install/remove 视为恒支持;configure 按存在与否)。
- `sw_label <key>` → 经 `t()` 取该软件的显示名(复用现有 `sw_claude` 等键,新增 `sw_git`/`sw_curl`/`sw_zsh`/`sw_docker`)。
- `sw_installed_tag <key>` → 调 `sw_<key>_status`,已装则附 `[已安装]`。

### 3.3 能力矩阵

| 软件 | `sw_*_status` 查活 | install | remove | configure |
|---|---|---|---|---|
| git | `command -v git` | `apt_install git` | `apt-get remove`(非 purge) | — |
| curl | `command -v curl` | `apt_install curl` | `apt-get remove` | — |
| zsh | `command -v zsh` | `apt_install zsh` | `apt-get remove` | 设为默认登录 shell(`chsh`);深度定制引导去 zsh-setup skill |
| docker | `command -v docker` | `apt_install docker.io`(渠道保守) | `apt-get remove docker.io` | 把当前用户加入 `docker` 组 + 启用并启动服务 |
| claude | `command -v claude` | 复用 `install_claude` | best-effort:npm 包在→`npm uninstall -g`,否则删 `~/.local/bin/claude`(+ 已知数据目录) | — |
| codex | `command -v codex` | 复用 `install_codex` | best-effort,同上(`@openai/codex` / `~/.local/bin/codex`) | — |
| node | `command -v node && command -v npm` | 复用 `install_node`(`apt_install nodejs npm`) | `apt-get remove nodejs npm` | — |
| skills | 部署目录存在(如 `~/.claude/skills/ubuntu-install`) | 复用 `deploy_skills` | 删 `~/.claude/skills/<name>` 与 `~/.codex/prompts/<name>.md`(SKILLS 数组逐个) | — |

> configure 仅 zsh、docker 有;其余软件的操作菜单只有「安装 / 卸载」。

## 4. 导航与数据流

```
run_tui  ──主菜单──▶  [安装软件] [设置] [退出]
   └ 安装软件
       tui_catalog        类别菜单:essentials/common/ai/runtime/assets + 返回
         └ tui_category(cat)   软件菜单:CAT_ITEMS[cat] 各项(带 [已安装]) + 返回
              └ tui_software(sw)   操作菜单:仅列支持的 op(安装/卸载/配置) + 返回
                   └ run_op(sw, op)   即时执行 + 写日志 → 结果框 → 回操作菜单
```

- 每级独立 `while` 循环;选「返回」或 whiptail Cancel(`ui_menu` 返回非 0 / 空)上退一层。
- 软件菜单的 `[已安装]` 标记每次进入时实时由 `sw_<key>_status` 计算(幂等查活,不缓存)。
- 操作执行后回到**操作菜单**(便于「装完再配」),用户再「返回」回软件菜单。

## 5. 操作语义(全部幂等)

- **安装**:`sw_*_status` 已装 → 报版本并跳过(沿用 `report_version` 风格);未装才装。
- **卸载**:`sw_*_status` 未装 → 提示「未安装,无需卸载」并跳过;装了才动手。apt 软件用 `apt-get remove`(**非 `purge`**,保留用户配置);CLI 走 best-effort 删除;skills 删部署产物。
- **配置**(仅 zsh、docker):必须幂等——
  - zsh:先 `getent passwd` 查当前登录 shell,已是 zsh 则跳过;否则 `sudo chsh -s "$(command -v zsh)" <user>`(逐命令 sudo,避免依赖用户密码)。深度定制(starship/插件/.zshrc)**不在 TUI 做**,提示用户用 zsh-setup skill。
  - docker:用户已在 `docker` 组则跳过该步;否则 `sudo usermod -aG docker <user>`;再 `sudo systemctl enable --now docker`(幂等)。提示需重新登录使组生效。
- **改配置文件前先备份**(那份备份是唯一的「撤销」)。

## 6. 复用、改动与删除

### 复用(不动语义)
`install_claude` / `install_codex` / `install_node` / `deploy_skills` / `apt_install` / `ensure_curl_deps` / `ensure_local_bin_on_path` / `preauth_sudo_if_needed`(扩展)/ 日志 + whiptail gauge 基础设施 / `ui_menu` / `ui_msgbox` / `ui_yesno` / i18n `t()`。

### 新增
- 目录数据 `CATALOG` / `CAT_ITEMS`。
- `sw_*` 函数族(status/install/remove/configure)。
- `sw_supports_op` / `sw_label` / `sw_installed_tag`。
- 三级菜单函数 `tui_catalog` / `tui_category` / `tui_software`。
- 单操作执行器 `run_op`(由 `run_installs` 改造,单 (sw,op),复用日志+gauge+`trap '' PIPE`+状态记录+结果框)。
- 新 i18n 串(类别标签、操作标签 安装/卸载/配置/返回、新软件标签、各类提示)。

### 删除(避免死代码)
- 旧 `tui_install`(多选)、`checklist_state`、`checklist_label`。
- `ui_checklist`(若重构后无人调用)。
- `item_label` 并入 `sw_label`;`show_install_summary` 并入 `run_op` 的结果框。

### 零改动
`run_headless` 及全部命令行 flag、`parse_args`、`usage`(仅在文案层面补充说明,逻辑不变)。

## 7. 不可妥协项的落地

| 约束 | 落地方式 |
|---|---|
| ①幂等查活 | 每个操作以 `sw_*_status` 真实观察为前提;重跑安全 no-op。 |
| ②逐命令 sudo | apt 走现有 `apt_install`(per-command sudo);docker 的 `usermod`/`systemctl`、zsh 的 `chsh` 也逐命令 `sudo`;**绝不 `sudo npm`**;卸载 CLI 时若是 npm 装的用 `npm uninstall -g`(用户身份)。 |
| ③非交互 apt | `apt-get remove` 同带 `DEBIAN_FRONTEND=noninteractive -y`。 |
| ④fail-fast / 可续跑 / 无回滚 | TUI 内单操作失败**不杀脚本**:记 `FAIL` + 日志路径 + 回菜单,靠幂等重跑补救;喂 gauge 的子 shell `trap '' PIPE`,gauge 早退也把操作跑完、状态照记。改配置前备份。headless 路径仍严格 fail-fast(本次不动)。 |
| ⑤skills 是产品资产 | skills 的部署/移除仍走 `deploy_skills` 等既有产品逻辑。 |
| sudo 预热 | 操作选定、执行前,仅对**需要 apt/usermod/chsh** 的 (sw,op) 沿用 `preauth_sudo_if_needed`(扩展为按操作判断);纯用户空间操作(claude/codex 安装、skills、CLI 的 npm 卸载)不预热、不无谓索要密码。 |

## 8. CLAUDE.md 修订

- 「项目目标」「当前状态」「领域约束」中关于「TUI 只菜单化固定几项、不做 catalog、通用软件管理交给 LLM」的措辞,改写为:
  > TUI 提供一个**精选、写死的软件目录**(类别 → 软件 → 装/卸/配),仍是**纯 bash、有界、零数据驱动**(不是被放弃的 Python/YAML catalog 引擎)。目录内是作者精选的常用软件;**长尾/任意软件,以及 configure 的深度定制,仍交给 LLM 的 skill**。二者边界:TUI = 精选起步集的开箱即用;skill = 任意软件 + 深度配置。
- 补一条 **drift 提示**:zsh / docker 的 configure 逻辑现**同时**存在于 `bootstrap.sh`(bash)与 `skills/zsh-setup/SKILL.md`(散文,面向 LLM)——改一处必查另一处(与现有 sudo 规则的 drift 提示并列)。
- `skills/zsh-setup/SKILL.md`:酌情补一句「bootstrap 的 TUI 现提供 zsh 的最小配置(设默认 shell);深度定制由本 skill 负责」,以厘清边界。

## 9. 校验与测试

- **必过**:`bash -n bootstrap.sh`;`shellcheck bootstrap.sh`(保持现有零告警水平);`./bootstrap.sh --help`。
- **函数级单测**(`source` 后):`sw_<key>_status` 各软件、`sw_supports_op`、`sw_label`、目录数据完整性(每个 `CAT_ITEMS` 里的 key 都有对应 `sw_*_install`/`sw_*_remove`)。
- **手动走查**:whiptail 路径与文本回退路径各走一遍三级导航;至少做一项软件的真装→真卸→(zsh/docker)真配,确认幂等(重复操作安全)。
- **回归**:headless 各 flag 行为不变(`--only`/`--method`/`--with-node`/`--skip-skills`/`--headless`/`--tui`)。

## 10. 已知风险 / 实现时需特别小心

1. **CLI 卸载的 best-effort 性**:Claude/Codex 官方 native installer 是否提供卸载入口未知;`rm ~/.local/bin/<cli>` 可能残留数据目录。实现时先查清官方 installer 的落地路径,卸载逻辑要保守、并在结果框说明「可能有残留,如需彻底清理请…」。区分 npm 装 vs native 装两条卸载路径。
2. **zsh configure 与 zsh-setup skill 的边界/drift**:TUI 只做「设默认 shell」这一最小且安全的子集,深度定制明确引导去 skill,避免两处逻辑膨胀冲突。
3. **docker 渠道**:本设计用 `docker.io`(Ubuntu 仓库,渠道保守,符合 skill 政策)。`docker-ce`(Docker 官方仓库)留给 LLM skill 或后续增强,不进 v1 TUI。
4. **chsh 交互**:`chsh` 在某些 PAM 配置下会索要密码;用 `sudo chsh -s <shell> <user>` 走逐命令 sudo,避免依赖用户密码、与 sudo 预热一致。
5. **gauge 单项**:单操作的 gauge 是「1 项」进度,体验上接近一闪而过。**决定:复用现有 gauge + 日志机制**(`run_installs` 改造为 `run_op`),不改用 `--infobox`——因为现有机制已带 `trap '' PIPE` + 状态文件记录,正是约束④(失败不杀脚本 + 完整日志)所需;为单操作另写一套执行/结果路径会重复且更易漏掉这些保护。
