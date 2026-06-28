# 脚本集合重构:端用户分类 + facet 标签 + 声明式依赖模型

## Goal

两件事一次性落地:
1. **展示层** — 把开发者视角的 4 类(`essentials/common/ai/runtime`)重构为 6 个端用户主类目 + 正交 facet 标签,拆掉 11 脚本的 `common` 杂物抽屉。
2. **行为层** — 把硬编码的跨脚本前置(`android→java` 的 `_android_java_gate`)统一为 `meta` 声明式 `requires`/`recommends` 两档依赖模型 + `tsort` 解析器。

审计已确认**不引入** mise/eget/getnf/chezmoi/topgrade/brew 等第三方工具(架构与全部脚本保留)。依据见 `docs/adr/0001`(不用 mise)、`0002`(依赖模型)、`0003`(分类模型),术语见根 `CONTEXT.md`。

## Constraints(不可妥协,沿用 CLAUDE.md 契约)

- 不改动 kit 核心身份:零前置依赖、apt 优先、system-visible 默认版、逐命令 sudo、改前备份、幂等。
- `meta` 新字段必须**向后兼容**:缺失 `requires`/`recommends`/`tags` 一律默认空,解析器不得因此报错。
- 依赖解析**保诚实契约**:硬 `requires` 未满足时**绝不静默**跨 sudo 边界安装;软 `recommends` **永不**自动装。
- 类目标签 i18n(en/zh/ja),**软件名/distro/插件/键名不译**(沿用现有 i18n 规则)。
- 改 `scripts/`/`lib/`/`bootstrap.sh`/`swkit` 代码**先进 worktree**(worktree-guard);依赖解析器改安装行为,必须**真机端到端**跑一遍。

## Requirements

### R1 端用户分类(6 主类目)
- `meta` 的 `category=` 取值改为 6 个端用户类目(内部 key + 本地化 label):
  - 装机必备 `essentials`:git, curl, zsh, fonts
  - 语言与运行时 `languages`:node, go, python, java, android
  - 编辑器与 IDE `editors`:vscode, cursor, nvim, android-studio
  - 终端与工具 `terminal`:ghostty, tmux, docker
  - AI 工具 `ai`:claude, codex, codegraph, trellis, mattpocock-skills
  - 应用 `apps`:obsidian, wechat, rime
- `_KIT_UI_CAT_ORDER` 与 `UI_MSG[*:cat_*]` 三语标签同步更新。

### R2 facet 标签
- `meta` 增 `tags=`(空格分隔)。行为驱动标签 `desktop-only`;`gui`/`cli` 为描述性。
- `desktop-only` 集:ghostty, vscode, cursor, android-studio, obsidian, wechat, rime。
- 需在 `lib/common.sh` **新增**共享 `kit_is_ssh` 探测 helper(lib 现无,各脚本各查 `SSH_*`)。
- TUI 在 SSH/headless 下对 `desktop-only` 脚本**标灰 + 角标**(「桌面专用 · SSH 下仅对有显示器的机器生效」),**仍可选可装**(不隐藏)。
- 角标文案可被脚本 `meta` 的 `desktop_hint=` 覆盖(vscode/cursor 提 Remote-SSH 出路,避免误导)。

### R3 声明式依赖模型
- `meta` 增 `requires=`(硬)/`recommends=`(软),版本约束写在边上(如 `java>=17`)。
- 依赖边(从代码推导):
  - **requires**:`android→java>=17`、`codegraph→node`、`trellis→node`、`mattpocock-skills→node`
  - **recommends**:`claude→node`、`codex→node`、`nvim→node`
- lib 解析器:聚合安装集的 `requires` 边,`tsort` 排序 + 查环;按目标依赖的 `status` **仅存在性**闸门。**不做通用版本比较**——版本约束(`java>=17`)是信息性的(UI 显示 + 排序)。
- 解析策略:硬 requires 未满足 → headless `fail-fast`+指路;TUI 内联给「装 X」按钮(`ui_run`,sudo 可见);`--with-requires` 显式按拓扑序装全链。软 recommends → 只在 UI/输出里指路,永不自动装。
- `fonts`(用户态备料)**不进**依赖模型;`android-studio` 声明**无**依赖(自带 JRT、自管 SDK)。
- `android.sh`:`requires=java>=17` **仅信息性**(显示+排序);`_android_java_gate` **完整保留**并继续做实际 ≥17 强制(它本就在每次 sdkmanager spawn 含 install 前做、且覆盖解析器够不到的非 install op)。诚实结论:依赖模型对 android 的收益是显示与排序,不是 gate 去重。真正干净统一的是 6 条纯存在性的 node 边。

### R4 契约与文档同步
- `scripts/TEMPLATE.sh` 注释新增 `requires`/`recommends`/`tags` 字段样例 + 新 category 取值。
- `CLAUDE.md` 更新:category 枚举(6 值)、新 meta 字段、解析器、tag/SSH 行为。
- `test/` 增/改契约测(见验收)。

## Acceptance Criteria

- [ ] `for f in bootstrap.sh lib/*.sh swkit scripts/*.sh; do bash -n "$f"; done` 全过
- [ ] `shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/*.sh bootstrap.sh` 零告警
- [ ] 每个脚本 `meta` 的 `category` ∈ 新 6 枚举;`requires`/`recommends`/`tags` 字段格式合法且与实现一致;`ops` 仍不含 `ui`
- [ ] 缺 `requires`/`recommends`/`tags` 的脚本(如 git/curl)解析器与 UI 不报错(向后兼容)
- [ ] TUI 目录按 6 类分组;SSH 下 `desktop-only` 脚本标灰+角标且仍可选(伪终端冒烟)
- [ ] 新 `kit_is_ssh` helper:注入 `SSH_CONNECTION` 时 `desktop-only` 行标灰触发,无 SSH 时无差异
- [ ] 落到未知/`other` category 的脚本仍在目录显示(`other` 兜底,不消失)
- [ ] 新 category label + `badge_desktop_only` 在 **en/zh/ja 三语齐全**(i18n 规则)
- [ ] `swkit android install`(无 java)→ fail-fast + 指路 `swkit java install`;`--with-requires` 按 java→android 顺序装(**真机端到端**,免密 sudo 下代跑,先征同意)
- [ ] `--with-requires` flag 被 `kit_dispatch` 干净剥离,**不泄漏**给 op 的 argv
- [ ] 依赖图有环时解析器报错而非死循环(`tsort` 退出码);空图/单节点/全满足不报伪错
- [ ] 软 recommends(如 nvim→node)未满足时只指路、**不**自动装 node
- [ ] android `requires=java>=17` 仅信息性:`_android_java_gate` 仍是实际 ≥17 强制点(非 install op 仍受其保护)
- [ ] `<script> meta|status|help` 契约不炸;`<script> ui` 无 TTY 打印指引退 0
- [ ] `CLAUDE.md` / `TEMPLATE.sh` / `CONTEXT.md` / ADR 与实现一致
