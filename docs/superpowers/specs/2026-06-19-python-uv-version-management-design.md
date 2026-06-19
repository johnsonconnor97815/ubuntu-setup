# Python 版本管理(`scripts/python.sh` 经 uv 管理本机 Python 解释器)

日期:2026-06-19
状态:已批准设计(经 grilling 敲定),待实现

## 目标

把 `scripts/python.sh`(现代 Python 开发环境管理器)做得更全面:在既有的「apt dev 层 + uv 生命周期 + uv 工具 + 包索引」之上,**新增一个『Python 版本』组件**——经 uv 管理本机的 Python 解释器(安装/列出/移除/升级多个版本),并能(显式 opt-in)指定本机默认 `python`/`python3` 指向哪个 uv 版本。

**这是纯添加**:apt 基础层、uv 安装/更新/移除、uv 工具、包索引镜像四块**原样不动**;只新挂一个版本组件,沿用项目「实时观测、无 pref store」的哲学(版本状态全部由 `uv python list` 实时得出)。

## 不可妥协的安全姿态(用户已选定:附加式 + 可选默认)

CLAUDE.md 铁律:本脚本**绝不碰 `python3` 本身**(系统依赖它)。本特性据此分两层:

1. **附加式(默认、零风险)**:`uv python install <ver>` 把版本化可执行文件(如 `python3.12`)装进 `~/.local/bin`,纯附加。它**不创建也不触碰**裸 `python`/`python3`。唯一可能的碰撞:装与系统**同一 minor**(如系统 3.12 上又 uv 装 3.12),此时 `~/.local/bin/python3.12` 会遮蔽 `/usr/bin/python3.12`——但那正是你点名要的 uv 构建,且你的默认 `python3` 仍是系统的。故「绝不遮蔽**默认** `python3`」成立。
2. **可选默认(显式 opt-in、带警告、可撤销)**:`set-default <ver>` = `uv python install <ver> --default`,额外装裸 `python`/`python3` 进 `~/.local/bin`。因 kit 把 `~/.local/bin` 前插 PATH(`lib/common.sh:167` `export PATH="$HOME/.local/bin:$PATH"`),这些裸 shim **会遮蔽 `/usr/bin/python3`**——但**仅对你的交互 shell**,不动 `/usr/bin/python3` 本体(系统服务/root/绝对 shebang 不受影响)。默认关闭,经 `clear-default` 随时撤销。

### uv 0.8.x 行为(调研结论,权威性高)

- `uv python install <ver>`(无 `--default`)**默认就把版本化 exec 装到 PATH 上**(此前是 preview,现已稳定)。可用 `--no-bin` / `UV_PYTHON_INSTALL_BIN=0` 退出——**本特性不用**,因为我们**就是要** `python3.X` 可直接调用。
- `--default` 才额外装裸 `python`/`python3`。
- uv **只在目标 exec 是 uv 自管时**覆盖;覆盖非 uv 管理的 exec 需 `--force`。→ 本特性**绝不传 `--force`**:若用户在 `~/.local/bin` 手放了 `python`/`python3`,uv 拒绝时如实转达其消息,绝不覆盖用户文件。
- `uv python list --managed-python` 只列 uv 自管版本(忽略系统解释器);加 `--only-installed` 只列已装(供可移除清单)。
- `uv python dir --bin` 给出 **exec/shim 目录**(默认 `~/.local/bin`,可被 `UV_PYTHON_BIN_DIR` 改);`uv python dir`(无 `--bin`)给出**安装根**(版本解压处,如 `~/.local/share/uv/python/cpython-…`)。`clear-default` 在 **`--bin`** 里删 shim;遮蔽探测看 shim 的真实路径是否落在**安装根**下。两者别混。
- `--default` 装的是裸 `python`/`python3`;**自由线程(freethreaded)变体**例外——`--default` 给的是 `python3t`/`pythont`。`clear-default` 默认处理标准 `python`/`python3`(freethreaded 默认场景罕见,作已知边角)。

### ⚠ 裸 `uv python install`(无参)陷阱——本特性绝不用

`uv python install` **不带版本参数**时,请求来源依次为:`UV_PYTHON` 环境变量 → CWD 及其父目录里的 `.python-version`/`.python-versions` → 若 uv **已装任意**受管版本则**仅校验、不装新版** → 都没有才装最新稳定版。后果:在带 `.python-version` 的目录里跑会装**那个**版本(正是我们要避开的 CWD 惊吓),或在已有版本时**什么都不做**。故**所有安装一律传显式版本**(显式 arg 令 uv 忽略 env/文件);「Install latest」靠先解析出具体版本号再显式装(见下)。

## op 面(用户选定全集,含预览特性 upgrade-versions)

| op | 形态 | 映射 | 遮蔽默认 python3? | 进 meta.ops? |
|----|------|------|------------------|-------------|
| `install-version <ver>` | 带参 | `uv python install <ver>` → `python3.X` | 否(附加) | 否(路由) |
| `remove-version <ver>` | 带参 | `uv python uninstall <ver>` | 否 | 否(路由) |
| `list-versions` | 无参 | `uv python list`(已装 + 可下载) | 否 | **是** |
| `set-default <ver>` | 带参 | `uv python install <ver> --default` | **是(opt-in,警告)** | 否(路由) |
| `clear-default` | 无参 | 删 uv 自管的裸 `python`/`python3` shim → 复位系统 | 反转遮蔽 | **是** |
| `upgrade-versions` | 无参 | `uv python upgrade`(补丁版升级,preview) | 否 | **是** |

- 带参 op 经 `kit_dispatch` 路由(同 `add-tool`/`set-index` 既有范式,**不进 `meta.ops`**)。
- `meta.ops` 新增三个无参 op:`list-versions,upgrade-versions,clear-default`。完整 `ops` 变为:
  `install,remove,configure,install-uv,remove-uv,update-uv,tools,update-tools,list-versions,upgrade-versions,clear-default`。
- **`ui` 仍不进 ops**;契约测试须确认 `ops` 恰好列实现项、不含 `ui`。

### 前置依赖(uv)

- 裸版本 op(`install-version`/`remove-version`/`set-default`/`clear-default`/`upgrade-versions`/`list-versions`)**要求 uv 已装**;缺则 `log_err` 指向 `swkit python install-uv` 并退非 0(与 `do_tools` 一致,**不**自动跑 `curl|sh`——保守、显式)。
- 仅 `configure --python`/`--default-python` 这两个 flag 走「set it up for me」语义,**确保 uv**(缺则 `do_install_uv`,同 `--recommended` 既有行为)再装版本。
- 全部新 op 经 `_py_user_guard`(**拒绝 sudo 包裹**,认 `SUDO_USER` 解析真实 home)——用户态、绝不 sudo。

## configure 与推荐流(用户选定:保守)

- **`configure` 无参 / `--recommended` 行为不变**:无参=确保 apt base + `~/.local/bin` 上 PATH;`--recommended`=base + uv + ruff + PATH。**不**自动装或设任何 uv 管理的 Python(新机器体验零变化)。
- 新增两个可脚本化 flag(供 headless/LLM):
  - `--python <ver>` → 确保 uv 后 `install-version <ver>`(附加,不遮蔽)。
  - `--default-python <ver>` → 确保 uv 后 `set-default <ver>`(装 + 设默认,opt-in 遮蔽,打印同 `set-default` 的警告)。

## set-default 护栏(用户选定:与 remove-uv 一致)

- **op 本身直接执行**(无交互 gate),保证 headless/LLM/`configure --default-python` 可用——符合项目「无 TTY 也要能跑」原则。
- 执行前 `ensure_local_bin_on_path`(保证遮蔽真的生效),并 `log_warn` 清晰告知:「`~/.local/bin/{python,python3}` 将遮蔽 `/usr/bin/python3`,仅你的交互 shell;撤销:`clear-default`;新 shell 生效」。
- **绝不传 `--force`**(见上)。
- **UI 层**额外 `ui_confirm`(默认 no)再跑——与 `remove-uv` 的 UI 二次确认同范式。

## clear-default 安全语义(精准、不误删)

- 经 `uv python dir --bin` 取 shim 目录(回退 `~/.local/bin`)。
- **只删裸 `python` 与 `python3`**,且**仅当它们是 uv 自管 symlink**(`readlink -f` 解析后落在 `uv python dir` 内)才删;普通文件/非 uv 目标**一律不动**(如实提示)。
- **绝不动版本化 exec**(`python3.12` 等保留)、绝不 `uv python uninstall`(那会连版本一起删)。
- 幂等:无 shim 时为 no-op,诚实提示「当前 `python3` 已是系统的」。

## 版本选择(用户选定:实时 + 最新 + 任意输入,不硬编码版本号)

- **不在脚本里硬编码任何 X.Y 版本号**(避免随 CPython 发版而陈旧,契合「实时观测」哲学)。
- 安装入口三种:
  1. **Install latest stable** → `_py_latest_available` 先从 `uv python list` 解析出**最新可下载 CPython** 的具体版本号,再 `install-version <该版本>`(**显式**)。**绝不**用裸 `uv python install`(无参)——见上「裸 install 陷阱」。解析不出则诚实报错并引导用「Install specific version…」。
  2. **Install specific version…** → `ui_input` 自由文本(`3.12` / `3.12.8`,高级用户亦可 `pypy@3.10` 透传给 uv);显式版本=env/`.python-version` 被忽略,无 CWD 陷阱。
  3. 已装的 uv 版本逐行列出(`uv python list --only-installed --managed-python`,可移除)。
- 完整可下载列表交给 `list-versions`(`uv python list`)查,不在 UI 里塞长列表。

### `_py_latest_available`(解析最新可下载 CPython)

`uv python list --managed-python`(含可下载项)→ 抽取 `cpython-X.Y.Z-…` 的版本号 → `sort -V` 取最高 → 回填 `X.Y.Z`。只认 cpython(排除 pypy/freethreaded)。解析失败返回非 0,调用方退回「指定版本」入口。这是唯一的「list 文本解析」,且仅用于便利按钮;失败安全。

### 版本字符串校验(防注入)

自由文本版本进 `uv python install/uninstall "$ver"`(作为**参数**,非写入被 source 的 rc,注入面低于 `set-index`)。仍校验:`[[ "$ver" =~ ^[A-Za-z0-9.@+-]+$ ]]` 否则 `log_err` 拒绝(挡空格/shell 元字符,放行 uv 的请求语法如 `cpython@3.12`)。

## status 透明度(用户选定:显式标遮蔽)

- 退出码语义不变:**0 当且仅当 apt dev base 在**。
- 一行输出在既有 `python X / pip X · uv X · tools N` 后追加:
  - `· pythons N`(N = uv 自管已装版本数,`uv python list --managed-python` 计数)。
  - **仅当** `_py_default_shadowed` 判遮蔽时,再追加 `· python3->X(uv)`(X = 该 uv 版本)。未遮蔽则零噪音。

### 遮蔽探测(供 status 与 UI 复用)

`_py_default_shadowed`:取 `command -v python3` 的真实路径(`readlink -f`),若落在 **`uv python dir`(安装根,非 `--bin`)** 之下 → 遮蔽,回填该 uv 版本号(从安装目录名 `cpython-X.Y.Z-…` 抽);否则系统默认。无 uv / `python3` 非 symlink / 解析不出 → **fail-closed 判「系统」**(保守:宁可漏报遮蔽,不误报)。

## `ui()` 集成

在既有 uv 区块**之后**(版本由 uv 提供,逻辑相邻)、dev-tools 之前,插入「Python versions」区块(整段仅当 uv 已装时出现):

键位**沿用 rime.sh 既有范式**(`space` 切换、`d` 设默认、`a` 加),footer 形如
`↑↓ move   space remove   d default   a add   ↵ run   esc/q close`:

- `header`「Python versions」+ 一行默认态:`python3 -> /usr/bin/python3 (system)` 或 `python3 -> uv 3.12 (shadowing system)`(经 `_py_default_shadowed`)。
- 已装 uv 版本逐行(`schema`-类行):`✓ 3.12.8`,当前默认版本行额外标记 `★ default`。键:
  - `space` → 移除该版本(`remove-version <ver>`;若它正是当前默认,`ui_confirm` 额外提示会一并失效遮蔽)。
  - `d` → 设为默认(`ui_confirm`「设 X 为默认?会遮蔽系统 python3」→ `set-default <ver>`)。
- `+ Install latest stable` 行(`a` 或 `↵`)→ 先解析最新版再 `install-version <版本>`。
- `+ Install specific version…` 行 → `ui_input` → 校验后 `install-version <输入>`。
- `clear-default`(复位系统)行——**仅当**当前被遮蔽时出现 → `ui_confirm` → `clear-default`。
- `upgrade-versions` 行(有已装版本时)→ `ui_run`。
- 每次状态变更经 `ui_run "<标题>" -- "$0" <op> [arg]`,随后重载实时状态。受限终端回退 `ui_default_menu`(无参 op 可达;带参版本动作回退后经 swkit 显式调用,与既有带参 op 一致)。

## 机器/项目边界(用户选定:排除)

**不纳入** uv 的项目级能力:`uv python pin`(写 CWD 的 `.python-version`)、`uv venv`/`uv init`。理由:它们依赖 CWD、是逐项目开发流,而本脚本是**本机**管理器(swkit 可从任意目录调用,`swkit python pin` 会在随机目录生成文件,语义混乱)。help/skill 指向「在项目里直接用 `uv`」。

## i18n 新增 key(en/zh/ja,`PY_I18N`)

版本号、命令名(`python`/`python3`/`uv`/`pip`)**不译**,仅说明性措辞本地化。新增(示意):
`py_versions_section` / `install_latest` / `install_specific` / `prompt_version` / `set_default` / `clear_default` / `confirm_set_default`(标题+正文,{X}=版本) / `confirm_clear_default` / `upgrade_versions` / `default_system`(`python3 -> system`) / `default_shadowed`(`-> uv {X} (shadowing system)`) / `tag_default` / `invalid_version` / `need_uv_for_versions`。

## 文档同步(避免漂移)

- **CLAUDE.md** 的 `python.sh` 段落:补「第 4 块组件·Python 版本:经 uv 管理本机解释器(install/remove/list/upgrade-versions、opt-in set-default/clear-default 遮蔽态),不硬编码版本号、实时观测,configure 加 `--python`/`--default-python`」,并把 `meta.ops` 列举处更新为含 `list-versions,upgrade-versions,clear-default`。
- 顶部文件头注释 + `usage()` + `meta` 的 `desc` 同步新 op。
- **无需** SKILL 改动:`python` 由通用 `ubuntu-install` skill 驱动,无专属 skill;若 help 文案足够,不动 skills(故无需重跑 bootstrap)。

## 验证

- `bash -n scripts/python.sh`;`shellcheck -x --source-path=SCRIPTDIR scripts/python.sh`(零告警)。
- `scripts/python.sh meta`:`ops` 含 `list-versions,upgrade-versions,clear-default`、**不含** `ui`/`install-version`/`set-default`(带参)、且与实现一致。
- `scripts/python.sh help` 不炸;`scripts/python.sh ui` 无 TTY 打印指引退 0。
- `status` 装前(退非 0)/装后(退 0,格式正确;遮蔽时含 `python3->X(uv)`)。
- 伪终端冒烟:`printf 'q' | TERM=xterm-256color script -qec 'scripts/python.sh ui' /dev/null` 渲染不崩、`q` 干净退出、终端复原。
- 行为(装有 uv 的环境):`install-version 3.12` 后 `~/.local/bin/python3.12` 在且 `python3` 仍系统;`set-default 3.12` 后 `_py_default_shadowed` 判遮蔽(`readlink -f python3` 落在 `uv python dir` 安装根下)、status 标遮蔽;`clear-default` 后 `python3` 复位系统、`python3.12` 仍在。
- 安全:版本串注入(`'3.12; rm -rf'`)被 `^[A-Za-z0-9.@+-]+$` 拒;`set-default` 绝不传 `--force`;`clear-default` 不删非 uv 管理的 `~/.local/bin/python*`。
- 反陷阱:静态确认代码**不存在裸 `uv python install`(无版本参数)**调用——所有安装路径都带显式版本(grep 审 `uv python install` 后必跟版本变量或 `--default <ver>`);「Install latest」经 `_py_latest_available` 解析后显式装,解析失败走指定版本入口而非裸装。

## 非目标(YAGNI)

- 不做项目级 `pin`/`venv`/`init`(用户已明确排除)。
- 不碰 `/usr/bin/python3` 本体、不改系统 alternatives、不写全局 shell rc(仅 uv 自管的 `~/.local/bin` shim + 既有受管 rc 行)。
- 不硬编码可装版本清单(实时由 uv 得出)。
- `--recommended` 不自动装/设任何 uv 版本(保守,用户已选定)。
- 不用 `--no-bin`(我们要版本化 exec 可直接调用)、不用 `--force`(绝不覆盖用户文件)。
