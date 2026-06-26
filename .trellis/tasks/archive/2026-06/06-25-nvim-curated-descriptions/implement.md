# 执行计划 — nvim curated 列表逐条说明文案

> 前置:在 worktree 内做代码改动。主会话**先 `EnterWorktree`**,再派 `trellis-implement`/`trellis-check`(子 agent 继承 cwd,落在隔离区)。

> **start 前 TODO**:curate `implement.jsonl` / `check.jsonl`(现为脚手架默认),填入子 agent 需要的 spec/research 清单——至少 `.trellis/spec/lib/index.md`(ui.sh 模式)、`.trellis/spec/scripts/index.md`、本任务 prd/design,以及「ui-smoke-test-hang」「nvim-syntax-check-triggers-lazy」两条任务记忆。

## 步骤(有序)

### S0 · 查证文案素材(R7,先于落笔)
- [ ] context7 取 Neovim 文档,核实 8 个 option 语义:`relativenumber wrap scrolloff shiftwidth tabstop conceallevel background spell`。
- [ ] context7 取 LazyVim 文档,核实 10 个 extra 实际捆绑:`lang.python/go/rust/json/yaml/toml/markdown/docker/clangd/java`。
- [ ] colorscheme(6)/font(4)拟风格/出处词(无需查证)。
- [ ] 产出一张「条目 → en/zh/ja 短 + 全」草表(可暂存任务目录 research/ 或 implement 笔记),作为下一步写 i18n 的来源。
- **gate**:草表经维护者快速过目(可选)再进 S2。

### S1 · `lib/ui.sh` · ui_pick 详情行(向后兼容)
- [ ] 顶部 `declare -ga UI_PICK_DETAILS=()`(避免 SC2154、统一清理点)。
- [ ] `ui_pick` 开头:`local -a _details=( "${UI_PICK_DETAILS[@]}" ); UI_PICK_DETAILS=()`。
- [ ] 富 TTY 渲染:有 `_details` 时 `avail` 减 1,列表下方画高亮项详情(muted、按 `UI_COLS` 截断)。
- [ ] `_ui_pick_text`:有详情时编号行附 `— detail`。
- [ ] 自测:`bash -n lib/ui.sh`;`shellcheck -x --source-path=SCRIPTDIR lib/ui.sh`。
- **gate**:抽一处旧调用(go.sh/python.sh)伪终端冒烟,确认无 details 时 picker 视觉/行为不变。

### S2 · `nvim.sh` · i18n 串 + helper
- [ ] 加 `_nvim_item_desc <kind> <name> [full]`(经 `_nvim_t` 组装、full 缺 fallback 短)。
- [ ] 写入 colorscheme/font/extras/options/autocmds 的短 + 全键(en/zh/ja),条目名不译。
- [ ] 删 `NVIM_AUTOCMD_DESC`;1977 行 UI 渲染改走 `_nvim_item_desc ac`。
- [ ] 加 `plugins_model_note` / `mason_model_note`(三语)。
- [ ] `bash -n` + `shellcheck`。

### S3 · `nvim.sh` · UI 行内短说明(R3)
- [ ] extras(1936-1939)/ options(1952-1955)行内补 `${UI_MUTED}短${UI_OFF}`;autocmds 已改走 helper。
- [ ] 域 3 / 域 9 加常驻 info 行(模型解释)。

### S4 · `nvim.sh` · 选择器详情(R4)
- [ ] colorscheme 的 `ui_pick` 调用前填 `UI_PICK_DETAILS`(完整说明,与 id/label 同序);font 同。
- [ ] label 维持「name —(短)」。

### S5 · `nvim.sh` · help + list-* + meta(R4/R6)
- [ ] `usage()` Settings 段补完整说明(curated 行下)。
- [ ] `list-colorschemes`(1357)/ `list-extras`(1797)/ `list-options`(1587)/ **`list-autocmds`(1642)** 四个都改「name — 完整说明」。
- [ ] `meta()` desc 重排为要点前置一行。

### S6 · 全量校验(见下「校验命令」)

## 校验命令

```bash
# 语法(必过)
for f in bootstrap.sh lib/common.sh lib/cache.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done
# shellcheck(零新增告警)
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/cache.sh lib/ui.sh bootstrap.sh
# 契约
./scripts/nvim.sh meta            # 字段齐、ops 不含 ui、desc 已重排一行
./scripts/nvim.sh help            # 不炸、curated 带完整说明
./scripts/nvim.sh list-colorschemes; ./scripts/nvim.sh list-extras; ./scripts/nvim.sh list-options
./scripts/nvim.sh status; echo "rc=$?"
# ui 无 TTY 退 0
./scripts/nvim.sh ui; echo "rc=$?"
# 伪终端冒烟(timeout 包裹,见 ui-smoke-test-hang 记忆)
timeout 10 script -qec "printf 'jjq' | TERM=xterm-256color ./scripts/nvim.sh ui" /dev/null || true
# 回归:旧式 ui_pick 调用方不受影响
timeout 10 script -qec "printf 'q' | TERM=xterm-256color ./scripts/go.sh ui" /dev/null || true
```

## review gates
- S0 后:文案草表(可选过目)。
- S1 后:lib 改动 + 旧 picker 回归 → 才动 nvim.sh。
- S6 后:`trellis-check` 全量 → 维护者 review → 合并回 dev → 主树重跑校验 → commit。

## rollback
- 纯 worktree 改动;任一步失败 `git checkout -- <file>` 或弃 worktree。lib 改动是纯增量(默认关),回退无残留。

## 注意
- 全程**只动文案 + 渲染**,不碰 install/configure/status 行为。
- 真机端到端**不需要**(无外部 API/下载/系统包变更);冒烟即可。
- 行为验收(详情行随高亮刷新)靠伪终端冒烟 + 维护者目测。
