# Implement — tmux 插件/主题卸载修复

## 执行清单(单文件 scripts/tmux.sh)

1. [ ] 在 `_tmux_run_clean_plugins`(~644)附近新增三个 helper:
   - `_tmux_remove_clone_dir <path>`(护栏 + `rm -rf`)
   - `_tmux_declared_basenames`(扫 `$_TCONF` 的 `@plugin` basename)
   - `_tmux_remove_clone_if_undeclared <spec>`(精确、尊重全局声明)
2. [ ] `do_remove_plugin`(~1316):
   - 在"确认 key 已启用"之后加 R3 的 resurrect/continuum 拒绝早退;
   - 末尾 `_tmux_apply` 后,在 `_tmux_run_clean_plugins` 之前插入 `_tmux_remove_clone_if_undeclared "$(_tmux_plugin_spec "$key")"`。
3. [ ] `do_theme`(~1333):记 `old_theme`,`_tmux_apply` 后按 design 删旧主题 clone。

## 校验命令

```bash
cd /home/conn/workspace/ubuntu-setup
bash -n scripts/tmux.sh
shellcheck -x --source-path=SCRIPTDIR scripts/tmux.sh
./scripts/tmux.sh meta && ./scripts/tmux.sh help >/dev/null && echo meta/help-ok
# ui 无 TTY 退 0
./scripts/tmux.sh ui; echo "ui exit=$?"
```

## 沙盒行为验收(隔离 HOME/XDG/TMUX_TMPDIR,短 socket 路径,git 假 clone)

复用本会话沙盒构造(scratchpad/repro + runkit.sh):务必同时隔离 `HOME`/`XDG_CONFIG_HOME`/`XDG_CACHE_HOME`/`XDG_DATA_HOME`/`TMUX_TMPDIR`(短路径),并 `-u TMUX*`,避免污染真实配置与真实 tmux server(本会话曾因只改 HOME、漏了 XDG_CONFIG_HOME 而误写真实 `~/.config/tmux/tmux.conf`,已从备份恢复)。

- [ ] AC1 `theme catppuccin` → `theme none`:`tmux` clone 目录消失。
- [ ] AC2 `remove-plugin cpu`:`tmux-cpu` 消失,其余 clone 不动。
- [ ] AC3 continuum 开:`remove-plugin resurrect` 非 0 + 提示、PLUGINS/clone 不变;`remove-plugin continuum` 后再 `remove-plugin resurrect` → 两 clone 均删。
- [ ] AC4 护栏:对 `_TPLUGDIR` 外路径 / 软链 / 含 `..` / 空 → 拒绝(`_tmux_remove_clone_dir` 直接喂构造路径单测)。
- [ ] AC5 `theme catppuccin` → `theme dracula`:`tmux` clone **保留**(二者共享 basename,不得误删)。
- [ ] AC6 幂等:对已删 clone 再 `remove-plugin` → 干净 no-op,退 0。
- [ ] 不误删用户自有插件:在 `$_TCONF` kit 块**外**手加一条 `set -g @plugin 'foo/bar'` + 造 `bar` clone,跑任意 remove → `bar` 保留。

## 回滚点

每完成一处改动跑一次 `bash -n` + `shellcheck`;沙盒验收失败则 `git checkout scripts/tmux.sh` 回到改动前。
