# Design — 端用户分类 + facet 标签 + 声明式依赖模型

权威设计依据:`docs/adr/0001`(不用 mise/保留运行时脚本)、`docs/adr/0002`(依赖模型)、`docs/adr/0003`(分类模型);术语:根 `CONTEXT.md`。本文件只补「怎么改代码」的落地细节。

## 1. meta schema 变更(向后兼容)

`meta` 子命令新增 3 个可选字段,全部**缺失即空**:

```
category=<essentials|languages|editors|terminal|ai|apps>   # 取值改变(原 common/runtime 废弃)
tags=<空格分隔: desktop-only gui cli ...>                    # 新增,可空
requires=<空格分隔: key[>=ver] ...>                          # 新增,可空(硬依赖)
recommends=<空格分隔: key ...>                                # 新增,可空(软依赖)
```

- 解析在 `lib/cache.sh`(meta 缓存读取处,现有 `category=*) _KIT_META_C=...`)旁增 `tags=*)`/`requires=*)`/`recommends=*)` 分支,填入新全局(`_KIT_META_T`/`_KIT_META_R`/`_KIT_META_RC`)。缺字段→空串,**不报错**。
- meta 按文件 mtime 永久缓存不变;新字段随 meta 一起缓存。

## 2. 分类(展示层)

- `lib/ui.sh`:`_KIT_UI_CAT_ORDER=(essentials languages editors terminal ai apps)`;`UI_MSG[en|zh|ja:cat_languages|cat_editors|cat_terminal|cat_apps]` 三语 label 新增,`cat_common`/`cat_runtime` 处理为删除或重映射。`_ui_catalog_*` 的分组按新 order。
- **保留 `cat_other` 兜底**(自审 #4):当前 `_KIT_UI_CAT_ORDER` **不含** other,落到未知 category 的脚本可能根本不显示(既有隐患)。把 `other` 追加到 order 末尾(或渲染剩余未归类项),且别误删 `cat_other` i18n。
- 迁移映射(每脚本改 `category=` 一行):见 §6 表。
- 内部 key 用英文(`languages`/`editors`/…),label 本地化;软件名不译。
- **注**:category **值**变更(common→拆、runtime→languages)是一次性协调 cutover(本任务一次全做,无半改态);向后兼容(缺字段=空)只针对**新增**的 `tags`/`requires`/`recommends`,不适用于 category 值。

## 3. facet 标签 + SSH 标灰(展示层)

- `desktop-only` 集在各脚本 `meta` 写 `tags=desktop-only ...`。
- **新增共享 SSH 探测 helper**(自审 #2):lib 里**没有**现成的 `kit_is_ssh`/SSH helper(各脚本各查 `SSH_*`),所以 grey-out 要在 `lib/common.sh` **新建** `kit_is_ssh`(判 `SSH_CONNECTION`/`SSH_TTY`/`SSH_CLIENT` 或无 `DISPLAY`/`WAYLAND_DISPLAY`),供 ui.sh 调用。**不是**「复用现有」。
- `lib/ui.sh` 的 `_ui_catalog_build`/`ui_row` 渲染:`kit_is_ssh` 且行带 `desktop-only` → 暗色/灰 ANSI 渲染 + 末尾角标(本地化 `UI_MSG[*:badge_desktop_only]`)。**仍可导航可选可装**(不跳过、不禁用)。
- **角标文案可被脚本覆盖**(自审 #5):vscode/cursor 的 server 端 GUI 确是 desktop-only,但有 Remote-SSH 出路,通用角标对这俩略误导。允许脚本 `meta` 提供 `desktop_hint=` 覆盖默认角标(如「或在本地用 Remote-SSH 连此机」),缺省用通用文案。
- 非 SSH 时 `desktop-only` 无视觉差异。`gui`/`cli` 暂不驱动行为(描述性,留作未来过滤器)。

## 4. 依赖解析器(行为层)— lib/common.sh

新增 helper(就近 `kit_dispatch`):

- `kit_deps_requires <key>` / `kit_deps_recommends <key>`:从缓存 meta 读 `requires`/`recommends`,逐项 yield `dep[>=ver]`。
- `kit_dep_satisfied <dep-spec>`(**仅存在性**,自审 #1):解析出 `key`(**丢弃** `>=ver`),只判 `key.sh status` 是否已装。**不做通用版本比较**——版本约束是信息性的(见下)。**只读、不装**。
- **版本约束 = 信息性,不在解析器强制**(自审 #1 决议):`java>=17` 只用于 UI 显示「需 java≥17」+ `--with-requires` 排序;**实际 ≥17 强制留给 `android.sh` 的 `_android_java_gate`**(它已在每次 sdkmanager spawn 前做,含 install)。不为唯一一条已被别处强制的版本边造通用比较器。
- `kit_resolve_requires <key> [--install]`:聚合 `<key>` 的 requires 闭包 → 构造边对喂 `tsort` 得拓扑序 + 查环(`tsort` 非 0 → 报错退出,**不死循环**)。**边界**(自审 #7):空图/单节点/全满足时跳过或干净返回(`tsort` 空输入即空输出),不报伪错。
  - 默认(无 `--install`):遇未满足项 → `log_err` 指路 `swkit <dep> install` + 返回 `RC_NEED_SUDO`/非 0(headless fail-fast)。
  - `--install`(由 `--with-requires` flag 或 UI 内联触发):按拓扑序对未满足项跑 `<dep>.sh install`(经 `sudo_run`/`ui_run`,sudo 可见),再装目标。
- `kit_dispatch` 在 `install` op 前调 `kit_resolve_requires`:默认 gate;识别 `--with-requires` 透传 `--install`。
- **recommends**:不进解析器闸门。仅在 `install`/`status`/UI 末尾,对未满足的 recommends `log_warn` 指路(沿用现有 nvim→node 文案范式),**永不**自动装。

### 与现有硬编码的关系(自审 #1 校正)
- `android.sh`:`meta` 写 `requires=java>=17`,但这是**信息性**的(UI 显示 + 排序)。`_android_java_gate` **完整保留**——它已在**每次** sdkmanager spawn(含 install、含 `--recommended` 的 `--list`)前强制 java≥17,且 `add-package`/`accept-licenses` 等非 install op 解析器**根本不覆盖**。所以解析器对 android **不做** gate 去重,只提供存在性提示 + `--with-requires` 排序。诚实结论:依赖模型对 android 的收益是**显示与排序**,不是 gate 逻辑统一。
- `codegraph/trellis/mattpocock-skills`:`requires=node`(纯存在性,无版本)——这是解析器**干净统一**的主体,原各自手写「缺则指路 swkit node install」收敛为一个声明式机制,**逐脚本保留原文案**(迁移时核对不丢失)。
- `claude/codex/nvim`:`recommends=node`;原「绝不自动装、指路」即 recommends 语义,文案保持。

## 5. UI 内联装依赖(行为层)— lib/ui.sh

- 在脚本 `ui()` 或 catalog 进入某脚本前,若其 requires 未满足:给一行「装 <dep>(前置)」走 `ui_run -- "$KIT_SCRIPTS_DIR/<dep>.sh" install`(退屏、sudo 可见、回屏重载 status)。这复用 android.sh 现有的「装 Java 17」`ui_run` 范式 —— 把它泛化进解析器驱动的通用流程。

## 6. 迁移映射表(每脚本 meta)

| 脚本 | category | tags | requires | recommends |
|---|---|---|---|---|
| git | essentials | cli | | |
| curl | essentials | cli | | |
| zsh | essentials | cli | | |
| fonts | essentials | cli | | |
| node | languages | cli | | |
| go | languages | cli | | |
| python | languages | cli | | |
| java | languages | cli | | |
| android | languages | cli | java>=17 | |
| vscode | editors | gui desktop-only | | |
| cursor | editors | gui desktop-only | | |
| nvim | editors | cli | | node |
| android-studio | editors | gui desktop-only | | |
| ghostty | terminal | gui desktop-only | | |
| tmux | terminal | cli | | |
| docker | terminal | cli | | |
| claude | ai | cli | | node |
| codex | ai | cli | | node |
| codegraph | ai | cli | node | |
| trellis | ai | cli | node | |
| mattpocock-skills | ai | cli | node | |
| obsidian | apps | gui desktop-only | | |
| wechat | apps | gui desktop-only | | |
| rime | apps | gui desktop-only | | |

> 注:`android-studio` **无** requires(自带 JRT/自管 SDK,见 ADR-0002)。`fonts` 不作任何脚本的 requires(auto-provisioned helper,见 CONTEXT.md)。

## 7. 取舍与边界

- **向后兼容优先**:全程「缺字段=空」,使迁移期半改的 kit 仍可跑;也让未来新脚本不写依赖字段时零负担。
- **解析器只管安装期**:运行期的 JAVA_HOME 选择等留在消费脚本(诚实范围,ADR-0002)。
- **不引第三方**:`tsort` 取自 coreutils(已是依赖),不新增运行时。
- **回滚**:展示层(category/tags/ui.sh)与行为层(requires/resolver)在 git 上是可分离的提交;若行为层真机测出问题,可单独回退 resolver 而保留分类。
