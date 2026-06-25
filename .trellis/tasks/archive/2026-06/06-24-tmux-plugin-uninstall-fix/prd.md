# tmux 插件/主题卸载修复

## Goal

让 `scripts/tmux.sh` 的插件与主题卸载**可靠**:删除一个插件或切换/移除主题后,对应的 TPM clone 目录确实从磁盘消失,且不依赖运行中的 tmux server,也不被 TPM 子串匹配误判保留。

## 背景 / 已复现根因

在完全隔离的沙盒(复刻 oh-my-tmux + XDG 配置 + 全套 clone)里复现到三处真实缺陷:

1. **主题 clone 永远删不掉(子串假阳性)** — `do_remove_plugin` 把删除委托给 TPM `bin/clean_plugins`,后者用子串匹配 `case "$declared" in *"$basename"*)` 决定保留。`catppuccin/tmux` / `dracula/tmux` 克隆目录名为 **`tmux`**,是声明列表里每个 `tmux-plugins/tmux-*` 的子串,故永远命中"保留"分支。沙盒实测:`theme none` 后 `tmux` clone 仍在。
2. **切/删主题不触发任何清理** — `do_theme()` 只调 `_tmux_apply`,**不调** `_tmux_run_clean_plugins`,旧主题 clone 残留。
3. **continuum 开启时 resurrect 卸不掉(静默回填)** — `_tmux_apply → _tmux_imply_resurrect` 无条件把 resurrect 加回 `PLUGINS`,使 `remove-plugin resurrect` 成 no-op,且打印 `Enabled 'resurrect'`(在删除操作里说"已启用",误导)。沙盒实测:PLUGINS 不变。

共性:删除时 kit 完全知道该删哪个 clone 目录(spec → owner/repo → basename + `_TPLUGDIR`),却依赖"需跑起 tmux server 解析路径 + 子串匹配"的脆弱 `clean_plugins`。

## Requirements

- R1 `do_remove_plugin <key>` 删除后,对应 clone 目录(`$_TPLUGDIR/<basename>`)被确定性删除,不依赖 tmux server 状态,不受子串匹配影响。
- R2 `do_theme <name> [flavor]` 切换/移除主题时,**旧主题**(若 != 新主题且有专属 clone)的 clone 目录被删除;切到带 clone 的新主题不误删。
- R3 `remove-plugin resurrect` 在 continuum 仍启用时,**明确拒绝并提示**(先移除 continuum),不再静默回填、不再打印误导性的"Enabled"。
- R4 删除 clone 必须有路径护栏(沿用 `android.sh _android_path_safe_under_home` / `nvim.sh _nvim_path_under_config` 范式):非空、解析软链防逃逸、`realpath -m` 绝对、严格在 `_TPLUGDIR` 之下、绝不等于 `_TPLUGDIR` 本身、绝不删 `tpm`;`rm -rf` 仍带 `${VAR:?}` 兜底。
- R5 全程用户态(`_tmux_resolve_paths` 已拒绝 sudo 包裹),不引入 sudo;幂等(目录不存在=no-op);保留既有 `_tmux_run_clean_plugins` 作为兜底扫尾(删任意非声明残留),但不再作为唯一删除途径。

## 非目标 / 约束

- 不改 TPM 本体、不改 install/update 流程。
- 不动受管块生成逻辑(`_tmux_emit_block`)除非 R3 需要。
- 不扩展到"主题切换的其它行为";只补"删旧主题 clone"。
- 仅 `scripts/tmux.sh` 一个文件;保持 shellcheck 零告警、`ui` 无 TTY 退 0、`meta.ops` 不含 `ui`。

## Acceptance Criteria

- [x] AC1:沙盒里 `theme catppuccin` 后 `theme none` → `tmux` clone 目录被删除(复现①修复)。
- [x] AC2:沙盒里 `remove-plugin cpu`(及任一 curated 插件)→ 其 clone 被删除,其余 clone 不动。
- [x] AC3:沙盒里 continuum 开启时 `remove-plugin resurrect` → 非 0 退出 + 清晰提示"先移除 continuum",PLUGINS 与 clone 均不变;先 `remove-plugin continuum` 再 `remove-plugin resurrect` → 两者 clone 均被删除。
- [x] AC4:路径护栏单测:伪造 `_TPLUGDIR` 外/软链/`..`/空 的目标 → 拒绝,不删除。
- [x] AC5:`bash -n` + `shellcheck -x --source-path=SCRIPTDIR scripts/tmux.sh` 零告警;`tmux meta`/`status`/`help` 正常;`tmux ui` 无 TTY 退 0。
- [x] AC6:幂等——对已不存在的 clone 再次删除为干净 no-op。
- [x] AC(追加):catppuccin→dracula 共享 basename 时保留 `tmux` clone;用户在 kit 块外自有 `@plugin` 的 clone 不被误删。

**验收结果**:隔离沙盒(复刻 oh-my-tmux + XDG)13/13 全过;`scripts/tmux.sh` shellcheck 干净;UI 伪终端冒烟退 0。已提交 dev `89cdb86`。
