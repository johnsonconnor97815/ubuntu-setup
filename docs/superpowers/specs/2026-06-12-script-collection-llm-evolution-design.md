# 设计:脚本集合作为唯一实现,LLM 负责调用与演进

- 日期:2026-06-12
- 状态:已与作者确认「可以,直接实施」
- 影响文件:`bootstrap.sh`、`lib/common.sh`(新)、`scripts/*.sh`(新)、`swkit`(新)、`skills/ubuntu-install/SKILL.md`、`skills/zsh-setup/SKILL.md`、`CLAUDE.md`、`README.md`
- 取代:`2026-06-12-bootstrap-software-manager-tui-design.md` 中「装/配逻辑以 `sw_<key>_*` 内联函数写死在 bootstrap.sh 内」的部分(该 spec 的 TUI 三级导航思想保留,但实现从内联函数迁移到脚本集合)

## 1. 背景与方向性变更(pivot)

**旧方向**:`bootstrap.sh` 做基础安装(装好 Claude/Codex CLI),此后一切软件的安装/配置由 **LLM 凭 skill 散文规则即兴完成**;装/配逻辑要么锁在 bootstrap 内联函数里(只 TUI 能调),要么只活在 skill 散文里(只 LLM 能用),同一软件(zsh/docker)的配置知识因此**双写**,CLAUDE.md 反复要求「改一处必查另一处」。

**新方向(本 spec)**:**脚本是所有装/配/管理功能的唯一权威实现。** 有三个入口调用同一批脚本:

1. 人 → `bootstrap.sh` 的 TUI
2. 人 → 直接跑脚本 / `swkit`
3. LLM → skill

LLM 在诸入口中独特:除**调用**脚本外,它还**组织、推荐、并演进**脚本——为未覆盖的软件**写新脚本**(借鉴官方文档与 GitHub 开源做法)、**修过时脚本**(软件版本更新导致 URL/步骤失效时)。

> **脚本 = 稳定、确定、可测的执行;LLM = 组织、推荐、并让脚本进化。** 两者融合:脚本解决「LLM 即兴装不可靠」,LLM 解决「脚本会过时」。

这也**消除双写**:覆盖到的软件,其装/配逻辑只有一处来源——脚本;skill 散文降级为「如何用脚本」+「如何按契约写脚本」。

### 与既有硬约束的关系

- **仍不引入数据驱动 catalog 引擎**:没有 Python/YAML 被引擎解释的声明式清单。脚本是**纯 bash、每软件一个、自硬编码自己的元数据**;TUI 通过读各脚本的 `meta` 子命令动态发现,这是「只读脚本自报的有界元数据」,不是被放弃的 YAML 引擎。
- **仅 Ubuntu/Debian**;**目标是刚装好的 Ubuntu**(最小 server 可能连 curl/git 都没有)。
- **开源产品**:脚本与 LLM 都在陌生人机器上跑 sudo——信任与安全是一等约束。**新增风险**:LLM 现在会**编写带 sudo 的特权脚本**,这是新攻击面(见 §9)。

## 2. 已确认的决策(设计输入)

1. **脚本形态**:每软件一个脚本 + 统一接口(非单一 dispatcher,非仅 source 的库)。
2. **覆盖与 LLM 角色**:脚本力求全覆盖,skill 退化为纯 dispatcher;但「全覆盖」靠 **LLM 演进脚本**实现(写新/改旧),不是预先穷举,也**不引入通用 `apt.sh <pkg>` 兜底**——长尾 = LLM 写一个(借助 lib 往往≈十行的)小脚本。
3. **bootstrap 去向**:保留 TUI,「安装软件」三级目录改为**调用脚本集合**;设置页(语言、免密 sudo)不变。
4. **zsh 深度配置**:功能仍由脚本实现(`scripts/zsh.sh` 含参数化 configure);LLM 是入口之一,帮用户用好脚本、并演进脚本;品味取舍(提示符/框架/Nerd Font)由 LLM 与用户对话决定。
5. **脚本位置与演进**:部署为 **git 跟踪的单一目录** `~/.local/share/ubuntu-setup/`(`$KIT_HOME`);LLM 在此读/改脚本,git 跟踪每次改动(可回滚、可 PR 回上游);bootstrap 用 **vendor 分支 + merge** 更新而非盲覆盖,LLM 新增脚本不丢。
6. **TUI 目录**:**动态发现**——TUI 扫 `$KIT_HOME/scripts/` 并读各脚本 `meta` 归类;LLM 新写的脚本自动出现。

## 3. 仓库 / 部署结构

### 3.1 仓库布局

```
bootstrap.sh              # 入口:补 kit 依赖 → 部署 kit+skills → TUI / headless
lib/common.sh             # 共享库:安全契约即代码,每个脚本 source 它
scripts/                  # 脚本集合——每软件一脚本,统一接口(开放、可被 LLM 扩充)
  git.sh curl.sh zsh.sh docker.sh node.sh claude.sh codex.sh
scripts/TEMPLATE.sh       # 新脚本模板(LLM 演进时 cp 它起步)
swkit                     # 薄启动器:swkit <软件> <操作> [args] / list / search / help
skills/
  ubuntu-install/SKILL.md # 「用 + 演进脚本」守则
  zsh-setup/SKILL.md      # zsh 品味对话 + 演进 zsh.sh
docs/ README.md CLAUDE.md LICENSE
```

### 3.2 部署到用户机(`$KIT_HOME = ~/.local/share/ubuntu-setup/`)

- `$KIT_HOME` 收纳 `lib/`、`scripts/`、`swkit`,且**本身是一个 git 仓**。
- **vendor-merge 更新模型**:
  - `$KIT_HOME` 有两条分支:`vendor`(出厂脚本的纯净副本,只由 bootstrap 写)与 `main`(用户/LLM 的改动落在这里,工作树即 `main`)。
  - 每次 bootstrap 运行:把 `$SCRIPT_DIR` 的 `lib/scripts/swkit` 刷进 `vendor` 分支并提交(若有变化);然后 `git -C $KIT_HOME merge vendor`(以 ubuntu-setup 身份)进 `main`。
  - 结果:LLM 在 `main` 上新增的脚本**不被触碰**(merge 只带来 vendor 侧的变更);只有「vendor 与 LLM 都改了同一文件」才作为**合并冲突**留在工作树,交还用户/LLM 解决(bootstrap 打印冲突文件 + 提示,**不自动解决**)。
  - 简化回退(若实现 vendor-merge 风险过高):git 仓 + 部署即 commit + 冲突显式标记。本 spec 以 vendor-merge 为目标,允许实现时先落简化版并在代码注释标注 TODO。
- **git 缺失**:deploy 优先 git;git 不可用时退化为纯 `cp` 部署并 warn「演进追踪需要 git」(并把 git 列入 kit 依赖,见 §6 ensure_kit_deps,首次运行会装上)。
- `swkit` 软链到 `~/.local/bin/swkit`(确保该目录在 PATH,复用现有 `ensure_local_bin_on_path`)。
- **skills 部署**照旧:`~/.claude/skills/<name>/` 与 `~/.codex/prompts/<name>.md`,内容里引用 `swkit`(与 `$KIT_HOME` 路径解耦)。
- **`$KIT_HOME` 解析**:用 `resolve_target_home`(已处理 sudo 包裹场景),`$KIT_HOME = <target_home>/.local/share/ubuntu-setup`。

> **「skills/kit 作为软件项」的取舍**:旧 catalog 有 `assets:skills` 项。新模型里 kit 与 skills 是**基础设施**,由 bootstrap 每次运行幂等部署/更新,**不再作为 TUI 可装卸的软件项**。如需「重新部署 skills」,重跑 `./bootstrap.sh` 即可。

## 4. 脚本统一接口契约

每个 `scripts/<name>.sh`:

- shebang `#!/usr/bin/env bash` + `set -Eeuo pipefail`。
- `source "<lib>/common.sh"`(lib 路径:脚本相对自身定位 `$KIT_HOME/lib`,见 §5 `kit_lib_dir`)。
- 定义约定函数:`meta`、`status`、`do_install`、`do_remove`、`do_configure`(可选)、`usage`。
- 末尾调用 `kit_dispatch "$@"`(lib 提供)路由子命令。

子命令(对外接口):

| 子命令 | 行为 |
|---|---|
| `meta` | 打印自描述(见下),供 TUI/`swkit list` 动态发现 |
| `status` | 退出码 0 = 已装/已生效,并打印版本/状态(**幂等核心**) |
| `install` | 幂等安装:`status` 已 0 则报版本跳过 |
| `remove` | 幂等卸载:`status` 非 0 则提示「未安装」跳过 |
| `configure [args]` | 可选;最小安全或参数化配置,幂等 |
| `help`/无参 | 用法(从 `meta` + `usage` 生成) |

`meta` 输出格式(KEY=VALUE 行,每脚本硬编码;**不是 YAML 引擎**):

```
key=docker
name=Docker (docker.io)
category=common
ops=install,remove,configure
desc=Container runtime from Ubuntu's docker.io package
```

- `category` ∈ 已知集 `essentials|common|ai|runtime`,未知归 `other`。
- `name`/`desc` 是脚本自报的字符串(可英文)——开放集无法预翻译,TUI 的固定 chrome 仍多语言,但**软件显示名用脚本自报值**(有意取舍)。
- `ops` 必须与脚本实际实现的函数一致(`install,remove` 恒有;`configure` 视 `do_configure` 是否定义)。

## 5. 共享库 `lib/common.sh` —— 安全契约即代码(冻结 API)

把 `ubuntu-install/SKILL.md` 的散文规则变成可复用、被强制的代码。**这是全体脚本的依赖,API 在实现前冻结于此。**

```
# ---- 退出码常量 ----
RC_NEED_SUDO=97          # 需要 sudo 但无法在当前(无 TTY)环境取得密码

# ---- 日志(stderr;颜色仅 tty)----
log_info MSG / log_warn MSG / log_err MSG

# ---- 探测(幂等查活)----
have_cmd CMD             # 0 = 在 PATH 上
pkg_installed PKG        # 0 = dpkg 状态恰为 "install ok installed"

# ---- sudo(②逐命令 sudo / 无整体 root / LLM 无 TTY 交还)----
sudo_available           # 0 = 有 sudo
sudo_passwordless        # 0 = `sudo -n true` 成功(按退出码,不看文案)
sudo_run CMD...          # 提权执行单条命令:
                         #   EUID==0           → 直接执行
                         #   else 免密          → sudo CMD
                         #   else 有可写 /dev/tty → sudo CMD(正常弹密码)
                         #   else(LLM 无 TTY)   → 打印「请你自己执行:sudo CMD」到 stderr,return RC_NEED_SUDO
                         # 绝不 echo/pipe/sudo -S/存密码/自写 NOPASSWD

# ---- apt(③非交互;逐命令 sudo via sudo_run)----
apt_update_once          # apt-get update(进程内首次才真跑,用全局哨兵)
apt_install PKGS...      # sudo_run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ...
apt_remove PKGS...       # sudo_run env DEBIAN_FRONTEND=noninteractive apt-get remove -y ...(remove,非 purge)

# ---- 文件(④改前备份;幂等追加)----
backup_file PATH         # 若存在:cp PATH PATH.bak.$(date +%s)
append_once LINE FILE    # grep -qxF 命中则跳过,否则追加

# ---- vendor apt 渠道(渠道优先级机械,绝不 apt-key)----
add_apt_keyring NAME KEY_URL   # curl 下载 → gpg --dearmor → /etc/apt/keyrings/NAME.gpg,chmod a+r(经 sudo_run)
add_apt_source NAME LINE       # 写 /etc/apt/sources.list.d/NAME.list(含 signed-by=,经 sudo_run)

# ---- 脚本骨架 ----
kit_lib_dir              # 返回 lib 目录(脚本据自身路径定位 $KIT_HOME/lib)
kit_dispatch "$@"        # 路由:meta/status/install/remove/configure/help → meta/status/do_install/do_remove/do_configure/usage
                         #   未定义 do_configure 时,configure 子命令报「该软件不支持配置」
                         #   无参/help → usage
emit_meta_line K V       # 可选:打印 "K=V"(便于 meta 函数书写)
```

**sudo_run 的 LLM 交还语义**是关键:脚本在 LLM 的无 TTY shell 里跑,遇到需密码的 sudo 时,`sudo_run` 自动打印「请你自己执行这条」并以 `RC_NEED_SUDO` 退出——脚本因 `set -e` 而停;skill 只需把这条转述给用户(让其开免密 sudo 或自己执行)。**统一、自动、不经手密码。**

## 6. bootstrap.sh 新形态

### 6.1 装东西全调脚本(单一来源)

`install_claude`/`install_codex`/`install_node` 及内联 `sw_*` 函数**全部删除**;改为调用 `scripts/<name>.sh <op>`。bootstrap 自身的 headless 安装也走脚本(连一致性一并拿下)。

### 6.2 启动序列

```
main:
  parse_args
  load_config（语言）
  ensure_kit_deps         # 补 git/curl/ca-certificates(kit 与 native installer 的最小依赖)
  deploy_kit              # vendor-merge 部署 lib/scripts/swkit 到 $KIT_HOME(git);软链 swkit 到 ~/.local/bin
  deploy_skills           # 照旧
  ensure_local_bin_on_path
  if have_tty 且非强制 headless: run_tui ; else run_headless
```

### 6.3 TUI(读 `$KIT_HOME/scripts` 动态目录)

- `tui_catalog`:扫 `$KIT_HOME/scripts/*.sh`,逐个读 `meta` 拿 `category`,按已知类别顺序(essentials→common→ai→runtime→other)分组;空类别不显示。
- `tui_category(cat)`:列该类别脚本,显示 `meta.name`,并实时调 `<script> status` 决定 `[已安装]` 标记。
- `tui_software(sw)`:读 `meta.ops` 只列支持的操作。
- `run_op(sw, op)`:**复用现有 gauge + 日志(`~/.cache/ubuntu-setup/`)+ `trap '' PIPE` + 状态文件 + 结果框**基础设施;唯一变化是把 `sw_<k>_<op>` 调用换成 `$KIT_HOME/scripts/<sw>.sh <op>`。`preauth_for_op` 改为「op 是 install/remove/configure 一律预热 sudo」或读 meta 标志;最简稳妥:对任意操作都在有 TTY 时 `sudo -v` 预热(脚本内 `sudo_run` 仍会二次判断,无害)。
- 操作失败(脚本非 0,含 `RC_NEED_SUDO`)记 `FAIL` + 日志路径,回菜单,不杀会话(约束④)。

### 6.4 设置页:不变(语言 + 免密 sudo 开关,逻辑照旧)。

### 6.5 headless:flag 路由到脚本(`--only`/`--method`/`--with-node`/`--skip-skills`/`--headless`/`--tui` 行为语义不变,内部改调脚本);严格 fail-fast 不变。

> `--method npm` 的「绝不 sudo npm、prefix 不可写则停」逻辑迁入 `scripts/claude.sh`/`codex.sh`(或 lib 的 npm 助手),保持原约束。

## 7. skill 重写

### 7.1 ubuntu-install:从「即兴装的散文规则」→「用 + 演进脚本」

- **§用(dispatcher)**:`swkit list` / `swkit search <x>` 发现脚本 → 出**确切计划**(要跑哪条 `swkit ... ` / 哪步要 sudo、`sudo -n true` 是否已免密)等用户确认 → 执行 → 若脚本以 `RC_NEED_SUDO` 退出则**转述交还**(让用户开免密 sudo 或自行执行)→ `<script> status` 验证并报版本/渠道。
- **§演进(新核心)**:无脚本覆盖,或脚本失效/过时 → **写或改脚本**:
  - `cp scripts/TEMPLATE.sh scripts/<key>.sh`;`source lib/common.sh`;用 lib 原语实现 `meta/status/do_install/do_remove[/do_configure]`;遵循渠道优先(apt→vendor apt repo→snap→官方脚本→手动二进制);保证幂等;改 `meta.ops`。
  - **测试**:`bash -n`;`<script> status`(装前/装后);在确认后真跑。
  - git 自动跟踪(在 `$KIT_HOME` 工作树);`git commit` 留清晰信息;鼓励 PR 回上游。
  - 参考软件官方文档/GitHub。
- **§不可妥协项作为「编写契约」**:幂等查活、逐命令 sudo、非交互 apt、改前备份、绝不 `sudo npm install -g`、绝不自写 NOPASSWD——此处以散文给出,面向「LLM 当作者」,并由 lib 代码强制。
- **§sudo 口令**:仍解释 LLM 无 TTY;但因 `sudo_run` 已自动交还,LLM 主要是「`sudo -n true` 探测 + 转述脚本的交还信息」。

### 7.2 zsh-setup:zsh 品味对话 + 演进 zsh.sh

- 机械能力进 `scripts/zsh.sh`:`install`(apt)、`status`、`remove`、`configure [--plugins ...] [--prompt builtin|starship|...] [--default-shell]`——**锁定安全**(`zsh -i -c exit` 验证通过才 `chsh`)实现在脚本内;`~/.zshrc` 基线、apt 插件路径(`dpkg -L`)、加载顺序等机械事项编码进脚本。
- skill 保留:**品味对话**(提示符/框架/Nerd Font over SSH 取舍——「不强加品味」)、锁定安全的为何、以及**如何演进 zsh.sh**(新增提示符选项等)。保持**独立 skill**(触发场景与对话都很 zsh 特化)。
- 边界 drift 提示更新:zsh 配置的**实现**现单一存在于 `scripts/zsh.sh`;skill 是对话 + 演进指引,不再平行实现 bash 逻辑。

## 8. 不可妥协项的新落地

| 约束 | 落地 |
|---|---|
| ①幂等查活 | lib 探测原语 + 每脚本 `status` 闸门(install/remove 先查 status) |
| ②逐命令 sudo / 无整体 root / 不 sudo npm / 不自写 NOPASSWD / LLM 无 TTY 交还 | lib `sudo_run` + `apt_install` 代码强制;npm 路径在脚本内守(prefix 不可写则停);skill 编写契约 |
| ③非交互 apt | lib `apt_install/apt_remove`(`DEBIAN_FRONTEND=noninteractive -y --no-install-recommends` / `remove` 非 purge) |
| ④fail-fast/可续跑/无回滚 / TUI 单操作失败不杀会话 / gauge `trap PIPE` | 脚本 `set -Eeuo pipefail` 各自 fail-fast;bootstrap `run_op` 保留失败隔离 + 日志 + 结果框;lib 改前备份是唯一「撤销」 |
| ⑤产品资产 | **kit(lib+scripts+swkit)与 skills 都部署到用户机**,同一底线:陌生人机器上站得住、渠道保守、先计划后执行、显式验证 |
| ⑥configure 双写 | **被消除**——单一来源 = 脚本;skill 散文降为「用法 + 编写契约」,不再平行实现。原 zsh/docker 的「改一处必查另一处」drift 警告作废 |

## 9. 风险 / 安全考量

1. **LLM 编写特权脚本 = 新攻击面**(开源产品、陌生人机器、sudo)。缓解:① lib 原语让安全写法成为默认、不安全写法(如 `sudo npm`、整体 root、apt-key)无原语支持;② skill 强制「先计划后执行 + 用户确认」;③ 所有改动经 git,`git diff` 可见可审、可回滚;④ 绝不自动写 NOPASSWD;⑤ 鼓励用户/上游 review 后才信任 LLM 新脚本。
2. **vendor-merge 部署复杂度**:允许先落简化版(commit-on-deploy + 冲突标记),代码注释标注升级 TODO。
3. **git 缺失/首次链**:ensure_kit_deps 装 git;装不上则退化纯 cp + warn。
4. **「全覆盖」是涌现/渐进**:v1 交付**种子脚本集**(git/curl/zsh/docker/node/claude/codex)+ TEMPLATE + 演进机制,不是预装大库。
5. **CLI 卸载 best-effort**:claude/codex 官方 native installer 卸载入口未知;脚本 remove 区分 npm 装 vs native 装,保守删 `~/.local/bin/<cli>`,结果说明「可能有残留」。
6. **动态目录 i18n**:LLM 新脚本显示名为英文——有意取舍,固定 chrome 仍多语言。
7. **TUI 启动即部署**:每次启动跑 vendor-merge(幂等,通常快 no-op);git 操作要安静、best-effort,失败不致命。

## 10. 校验与测试

- **必过**:`bash -n` 于 `bootstrap.sh`、`lib/common.sh`、每个 `scripts/*.sh`、`swkit`;`shellcheck` 全绿(保持现有零告警水平);`./bootstrap.sh --help`。
- **lib 单测**(source 后):`pkg_installed`/`have_cmd`/`sudo_passwordless`(mock)/`append_once`/`backup_file`/`kit_dispatch` 路由。
- **脚本契约测**:每个 `scripts/*.sh` 的 `meta` 输出含必需字段且 `ops` 与实现一致;`status` 可独立运行;`bash -n` 通过;`help` 不炸。
- **swkit**:`list`/`search`/无参 help/调一个脚本的 status。
- **手动走查**:whiptail 与文本回退各走一遍三级动态导航;至少一项软件真装→真卸→(zsh/docker)真配,确认幂等;模拟 LLM 演进:`cp TEMPLATE` 写一个新脚本,确认 `swkit list` 与 TUI 自动收录。
- **回归**:headless 各 flag 语义不变。
- **部署**:首次 deploy 建 `$KIT_HOME` git 仓;再次 deploy 为幂等 merge;在 `main` 手动加一个文件,deploy 后该文件仍在(不被 vendor-merge 清除)。
