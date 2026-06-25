# Design — tmux 插件/主题卸载修复

仅改 `scripts/tmux.sh`。核心:用 **kit 自有、精确(非子串)、不依赖 tmux server** 的 clone 删除取代对 TPM `clean_plugins` 的脆弱委托;同时**尊重整份配置的声明集**以免误删用户自有插件。

## 关键约束(为何不能简单"删不在 PLUGINS 里的目录")

用户(尤其 oh-my-tmux)可能在 kit 受管块**之外**自有 `set -g @plugin '...'` 行。TPM `clean_plugins` 之所以读**整份配置**的 `@plugin` 集,正是为了不误删这些。所以新删除逻辑的"是否仍被声明"判定必须以 **`$_TCONF` 全文件的 `@plugin` basename 集**为权威,而非仅 kit 的 `PLUGINS`/`THEME`。`_tmux_apply` 已先把新块写入 `$_TCONF`,故删除时扫描它即拿到最新权威集。

## 新增 helper

### `_tmux_remove_clone_dir <path>` — 带护栏的 rm
沿用 `android.sh _android_path_safe_under_home` / `nvim.sh _nvim_path_under_config` 范式,锚定在 `_TPLUGDIR`:
- `[[ -d "$path" ]] || return 0` → 不存在即幂等 no-op(AC6);
- 拒绝软链路径(`-L`)、含 `..`;`realpath -m` 规范化;
- 拒绝 `target == _TPLUGDIR` 本身、`target` 不在 `"$_TPLUGDIR"/*` 之下、basename == `tpm`;
- 通过后 `rm -rf "${target:?}"` + `log_info`。失败/拒绝走 `log_warn` 返回非 0(不中断调用方)。

### `_tmux_declared_basenames` — 整份配置的声明 basename 集
扫 `$_TCONF`,awk 锚 `^[ \t]*set(-option)? +-g +@plugin`(与 TPM 同款,`#` 注释行天然不匹配),去引号取 `$4`,strip `.git`,输出 `${spec##*/}` 逐行。覆盖 kit 块 + 用户自有 `@plugin`。

### `_tmux_remove_clone_if_undeclared <spec>` — 精确、尊重全局声明
```
base = strip .git, ${spec##*/}
[[ base 非空 && base != tpm ]] 否则 return 0
若 _tmux_declared_basenames 中以精确整行(grep -qxF)含 base → 仍被声明,保留,return 0
否则 _tmux_remove_clone_dir "$_TPLUGDIR/$base"
```
精确整行匹配根除子串假阳性(`tmux` ⊂ `tmux-cpu` 不再误判)。

## 改动点

### R1 `do_remove_plugin`(~1316)
末尾 `_tmux_apply` 之后:
```
_tmux_remove_clone_if_undeclared "$(_tmux_plugin_spec "$key")"   # 精确、确定性(主)
_tmux_run_clean_plugins                                          # TPM 兜底扫尾(次,保留,非回归)
```
保留 `_tmux_run_clean_plugins` 仅作 best-effort 二次扫尾(它读整份配置,不会误删用户插件;其子串缺陷此时已被主删除覆盖)。

### R2 `do_theme`(~1333)
`_tmux_load_state` 后记 `local old_theme="$THEME"`;`_tmux_apply` 后:
```
if [[ "$old_theme" != "$name" ]]; then
  ospec="$(_tmux_theme_spec "$old_theme")" && _tmux_remove_clone_if_undeclared "$ospec"
fi
```
- catppuccin→none:旧 `catppuccin/tmux` basename `tmux`,新块无 `tmux` 声明 → 删除 ✓
- catppuccin→dracula:二者 basename 同为 `tmux`,新块声明 `dracula/tmux`(basename `tmux`)→ `_tmux_declared_basenames` 含 `tmux` → **保留**,install 复用 ✓(避免误删刚装的 dracula)
- `_tmux_theme_spec none` 返回 1 → 切自 none 时不删任何东西 ✓

### R3 `do_remove_plugin` — resurrect/continuum
在确认 `key` 已启用之后、`_tmux_apply` 之前:
```
if [[ "$key" == resurrect ]] && _tmux_list_has continuum "$PLUGINS"; then
  log_err "'resurrect' is required by 'continuum' — remove 'continuum' first ..."
  return 2
fi
```
明确拒绝,取代 `_tmux_imply_resurrect` 的静默回填 + 误导性 "Enabled"。`_tmux_imply_resurrect` 本身不改(它在 add/configure 路径仍正确)。

## 安全 / 契约

- 全程用户态;`_tmux_resolve_paths` 已拒绝 sudo 包裹,`_TPLUGDIR` 用户自有。
- 不改 `meta.ops`(无新 op);不改受管块生成(除 R3 的早退,不进 emit)。
- shellcheck:awk 内单引号片段加 `# shellcheck disable=SC2016` 如需;`rm -rf "${target:?}"` 兜底。
- 幂等;fail-safe(删除失败仅 warn,不杀流程,靠重跑/幂等补救)。

## 回滚

单文件改动,`git checkout scripts/tmux.sh` 即回滚;运行时无持久副作用(删除是目标行为本身)。
