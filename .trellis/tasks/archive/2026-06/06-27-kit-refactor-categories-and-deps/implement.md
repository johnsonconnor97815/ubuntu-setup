# Implement — 端用户分类 + facet 标签 + 声明式依赖模型

执行顺序按「先底座 schema、再展示层、再行为层、最后契约/文档/测试」。每个 review gate 跑校验后再继续。**全部代码改动在 worktree 内完成**(见 §0)。

## 0. 隔离(前置,必做)

- [ ] `EnterWorktree` 建并切入 `.claude/worktrees/kit-refactor/`(基于 `dev`)。此后所有 `scripts/`/`lib/`/`bootstrap.sh`/`swkit`/`CLAUDE.md`/`test/` 改动都在此 worktree。
- 子 agent 继承 cwd,故主会话先进 worktree 再派 `trellis-implement`/`trellis-check`。

## 1. Schema 底座(lib/cache.sh)

- [ ] 在 meta 缓存解析处(现 `category=*) _KIT_META_C=...`)新增 `tags=*) _KIT_META_T=...`、`requires=*) _KIT_META_R=...`、`recommends=*) _KIT_META_RC=...`,缺失默认空串。
- [ ] 暴露读取入口(`kit_meta_into`/`kit_meta_cached` 等)带出新全局,供 ui/resolver 零 fork 读。
- **Gate**:`bash -n lib/cache.sh`;`shellcheck -x --source-path=SCRIPTDIR lib/cache.sh`。

## 2. 展示层 — 分类(lib/ui.sh + 各脚本 category)

- [ ] `_KIT_UI_CAT_ORDER=(essentials languages editors terminal ai apps)`;**末尾保留 `other` 兜底**(自审 #4:当前 order 不含 other、落 other 者不显示),让未知 category 仍渲染。
- [ ] 新增/改 `UI_MSG[en|zh|ja:cat_languages|cat_editors|cat_terminal|cat_apps]`;移除/重映射 `cat_common`/`cat_runtime`;**保留 `cat_other`**。
- [ ] 按 design §6 表,逐脚本改 `meta` 的 `category=` 一行(24 个脚本)。
- **Gate**:`bash -n` 全脚本;`<任一脚本> meta` 打印新 category;伪终端冒烟 `printf 'q' | TERM=xterm-256color script -qec 'swkit ui' /dev/null` 看 6 类分组、干净退出。

## 3. 展示层 — facet 标签 + SSH 标灰(lib/ui.sh + 各脚本 tags)

- [ ] 按 §6 表给 `desktop-only` 集 7 个脚本 `meta` 写 `tags=`;其余写 `gui`/`cli` 描述性标签。
- [ ] **`lib/common.sh` 新增 `kit_is_ssh`**(自审 #2:lib 现无,别假设复用):判 `SSH_CONNECTION`/`SSH_TTY`/`SSH_CLIENT` 或无 `DISPLAY`/`WAYLAND_DISPLAY`。
- [ ] `lib/ui.sh`:`_ui_catalog_build`/`ui_row` 在 `kit_is_ssh` 且行含 `desktop-only` 时灰渲染 + 角标;新增 `UI_MSG[*:badge_desktop_only]` 三语;支持脚本 `meta` 的 `desktop_hint=` 覆盖角标(自审 #5,vscode/cursor 提 Remote-SSH)。**仍可导航/可选**。
- **Gate**:`shellcheck` 零告警;伪终端在 `SSH_CONNECTION=1` 注入下冒烟,确认 desktop-only 行标灰+角标且仍可选中;无注入时无差异。

## 4. 行为层 — 依赖解析器(lib/common.sh)

- [ ] 实现 `kit_deps_requires`/`kit_deps_recommends`/`kit_dep_satisfied`(**仅存在性**,丢弃 `>=ver`)/`kit_resolve_requires`(design §4):`tsort` 拓扑序 + 查环(非 0 报错退出);空图/单节点/全满足干净返回不报伪错。
- [ ] **不实现通用版本比较器**(自审 #1):版本约束仅用于显示/排序,实际强制留给消费脚本(android 的 `_android_java_gate`)。
- [ ] `kit_dispatch` 在 `install` 前调 gate;**干净剥离 `--with-requires`**(不泄漏给 op argv),识别后 `--install` 透传(拓扑序逐个 `<dep>.sh install`)。
- [ ] recommends:`install`/`status`/UI 末尾对未满足项 `log_warn` 指路,**不**自动装。
- **Gate**:`bash -n`/`shellcheck`;人造环(A→B→A)报错退出而非死循环;`--with-requires` 剥离后 op 的 `$@` 不含它。

## 5. 行为层 — 各脚本 requires/recommends + 内联 UI

- [ ] 按 §6 表给 android(`requires=java>=17`)、codegraph/trellis/mattpocock-skills(`requires=node`)、claude/codex/nvim(`recommends=node`)写 `meta`。
- [ ] `android.sh`:**`_android_java_gate` 完整保留不动**(自审 #1:它仍是实际 ≥17 强制点,覆盖解析器够不到的非 install op);`requires=java>=17` 仅信息性。把现有「装 Java 17」`ui_run` 行泛化为解析器驱动的「装 <dep> 前置」内联项。
- [ ] node-gate 脚本(codegraph/trellis/mattpocock-skills 硬、claude/codex/nvim 软):把现有「缺则指路」对齐解析器统一流程,**逐脚本核对原文案不丢失**。
- **Gate**:`<script> meta` 的 `requires`/`recommends` 与实现一致;`<script> status`/`help` 不炸;`<script> ui` 无 TTY 退 0。

## 6. 契约 + 文档(TEMPLATE / CLAUDE.md / 测试)

- [ ] `scripts/TEMPLATE.sh`:注释加 `requires`/`recommends`/`tags` 样例 + 新 category 取值。
- [ ] `CLAUDE.md`:更新 category 枚举(6 值)、新 meta 字段、解析器、tag/SSH 行为、依赖边清单。
- [ ] `test/`:meta 契约测扩展(category ∈ 6 枚举;requires/recommends/tags 格式;缺字段不报错);解析器查环测。
- **Gate**:全量 `bash -n` + `shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/*.sh bootstrap.sh` 零告警;`./bootstrap.sh --help`。

## 7. 真机端到端(行为层必做)

> 依赖解析器改安装行为,属「外部/系统变更渠道」,静态测覆盖不到。免密 sudo 下可代跑;android/java 是系统包变更,**破坏性前先征用户同意**。

- [ ] `swkit android install`(预置无 java≥17 环境)→ 断言 fail-fast + 指路 `swkit java install`,**未**动系统。
- [ ] `swkit android install --with-requires` → 断言按 java→android 拓扑序安装,装后 `swkit android status` 与 `java status` 皆 OK。
- [ ] `swkit nvim install`(无 node)→ 断言只 `log_warn` 指路、**未**装 node。
- [ ] TUI 内联:android 的 ui 界面里「装 Java(前置)」按钮经 `ui_run` 可见 sudo 装成功。

## 8. 合并回主树

- [ ] worktree 内全绿后,回主树 `git merge`,解冲突后**主树重跑** §6 Gate 全量校验。
- [ ] `ExitWorktree`。
- [ ] `task.py finish` 前:更新 spec(CLAUDE.md 已在 §6 改)、确认 ADR/CONTEXT 与最终实现一致。

## Rollback points

- 展示层(step 2–3)与行为层(step 4–5)是可分离提交。行为层真机测出问题 → 单独回退 resolver 相关提交,保留分类/标签成果。
- 每脚本 `meta` 改动是单行、幂等,易 `git revert` 单点。
