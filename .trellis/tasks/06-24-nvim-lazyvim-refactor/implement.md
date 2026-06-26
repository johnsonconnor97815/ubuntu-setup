# 执行计划 — nvim+LazyVim 组合管理器重构

## 策略

单文件(`scripts/nvim.sh`)重型重构。原则:**先建新、再改线、最后删旧**——新代码经验证后才删旧机制,每个阶段关卡脚本仍 `bash -n` + `shellcheck` green、`meta`/`status`/`help` 可跑。全程在本 worktree(`.claude/worktrees/nvim-lazyvim-refactor`)内,merge 回 dev 由人工 gated。

**回滚点**:每阶段一个 worktree 分支 commit(`worktree-nvim-lazyvim-refactor`,隔离、不碰 dev),回滚 = `git reset --hard <上一阶段>`。提交节奏遵循「仅在明确要求时 commit」——若你不想要逐阶段 commit,则以 `cp scripts/nvim.sh <scratchpad>/nvim.sh.S<N>` 留快照替代。**merge 回 dev 永远人工 gated**(CLAUDE.md:Claude Code 不自动 merge)。

## 复用基线(开工先确认)

- [ ] S0 · 基线 green:`bash -n scripts/nvim.sh` + `shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh` 当前零告警(确认起点干净)。
- [ ] S0 · 留原始快照:`cp scripts/nvim.sh "$SCRATCH/nvim.sh.orig"`(整体回滚兜底)。

## 验证命令(每关卡跑)

```bash
# 静态(必过)
bash -n scripts/nvim.sh
shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh        # 零告警

# 契约
scripts/nvim.sh meta        # 字段齐全；ops 与实现一致；ops 不含 ui
scripts/nvim.sh status; echo "exit=$?"   # 组合语义；KIT_PROBE_ONLY=1 再跑一次比对退出码
scripts/nvim.sh help        # 不炸
scripts/nvim.sh ui          # 无 TTY → 打印指引退 0

# 伪终端冒烟(ui 关卡)
printf 'q' | TERM=xterm-256color script -qec 'scripts/nvim.sh ui' /dev/null
```

## 分阶段清单

### S1 · meta / status / 骨架(不删旧,先调头部)
- [ ] `meta`:`ops=install,remove,configure,update,update-plugins`,desc 改为「nvim+LazyVim 组合管理器」。
- [ ] `status`:改组合语义——`have_cmd nvim && (标记文件在 || grep -rlq LazyVim/LazyVim ~/.config/nvim/lua)`;`KIT_PROBE_ONLY` 只 stat 标记、不 spawn nvim/不 grep,早返布尔;两路径退出码一致。
- [ ] 常量:加 `NVIM_LAZYVIM_REPO`、`NVIM_MARKER_FILE` 名、plugins 文件 marker、managed block marker 对。
- [ ] **关卡**:静态 + 契约 green(此时旧 distro/双模式仍在、暂不调用它们的新路径)。

### S2 · LazyVim 落地层 + deps(新建,install 改组合)
- [ ] `_nvim_ensure_deps`:deps 集扩为 `git curl ripgrep fd-find fzf build-essential unzip gzip` + best-effort `lazygit`(装不上不报错)+ Nerd Font(沿用)+ 剪贴板(沿用)。
- [ ] `_nvim_backup_dir` → 扩展为备份四处(config + ~/.local/share/nvim + ~/.local/state/nvim + ~/.cache/nvim)或新增 `_lazyvim_backup_all`。
- [ ] 新增 `_lazyvim_marker_read/_write`(`source=cloned|adopted`)。
- [ ] 新增 `_lazyvim_land`:四分支(空→clone+rm .git+marker cloned;kit→幂等;手写 LazyVim〔grep〕→adopt;非 LazyVim→备份四处+clone+marker cloned,log_warn,ui 侧 ui_confirm)。
- [ ] 重写 `do_install` = 组合(二进制 → ensure_deps → _lazyvim_land → _nvim_sync → 提示 :LazyHealth);幂等(标记在则跳重型)。
- [ ] 重写 `do_remove`:按 `source` —— cloned 备份后删配置、adopted 只摘标记;`--purge`(cloned)删 data/state/cache。
- [ ] **关卡**:静态 + 契约 green;**真机**:干净环境 `install` → `~/.config/nvim` 有 LazyVim、无 `.git`、`:Lazy sync` 成功、`status` 转已装、重跑幂等。

### S3 · 设置域 主题/插件/Mason(`lua/plugins/ubuntu-setup.lua`)
- [ ] 纯函数 `_nvim_render_plugins_file`(读 nvim.conf `CFG_COLORSCHEME`/`PLUGINS`/`DISABLED_PLUGINS`/`EXTRA_PLUGIN_*`/`MASON_TOOLS` → stdout);首行 marker。
- [ ] 写入器 `_nvim_apply_plugins_file`:护栏 `_nvim_path_under_config` + 非 kit 文件拒写 + `backup_file` + 原子 mv + `_nvim_sync`。
- [ ] op:`set-colorscheme`(curated 表 + 非内置→映射 owner/repo 加插件 spec)、`add-plugin`/`remove-plugin`/`disable-plugin`/`enable-plugin`、`mason-add`/`mason-remove`;`list-colorschemes`。
- [ ] curated 主题→插件 repo 映射(`gruvbox→ellisonleao/gruvbox.nvim` 等)**用 context7/exa 逐一核对** repo 名。
- [ ] **关卡**:静态 green;生成器纯函数 stdout 比对;**真机**:set-colorscheme(内置 + 非内置)、add/disable-plugin、mason-add → 生成 lua、`:Lazy sync` 无报错、nvim 启动无 error。

### S4 · 设置域 leader/options/keymaps/autocmds(`lua/config/*` 受管块)
- [ ] 参数化 `_nvim_render_block <which>` + 各生成器(options.lua 块含 leader + options + `vim.g.autoformat`;keymaps.lua 块;autocmds.lua 块)。
- [ ] 写入器(tmux 范式):marker 块整体重生成、保留块外用户内容、`backup_file`、路径护栏。
- [ ] op:`set-leader`、`set-option`/`unset-option`(curated + 校验 name/value)、`add-keymap`/`remove-keymap`(mode/lhs/rhs 校验)、`add-autocmd`/`remove-autocmd`(curated + 禁用命名 augroup)。
- [ ] **关卡**:静态 green;**真机**:各 op 写对块、保留块外内容、leader/option/keymap/autocmd 在 nvim 内生效(`:lua print(vim.g.mapleader)` 等)、`set-option relativenumber off` 真覆盖 LazyVim 默认。

### S5 · 设置域 extras(`lazyvim.json` headless save)
- [ ] `extra-add`/`extra-remove`:headless 驱动 `LazyVim.config.json.data.extras` + `LazyVim.json.save()`(逐条、保留用户条目);`<cat.name>` 正则校验 + 映射全模块名;改后 `_nvim_sync` + 提示重启;`list-extras`。
- [ ] **真机核对 API 路径/时序**(design 风险点):确认 `LazyVim.json.save` / `require("lazyvim.util.json")` 与 headless 启动后 json 模块已加载;失败→启用 design 的 jq 备选(仅处理文件已存在情形)。
- [ ] **关卡**:静态 green;**真机**:`extra-add lang.go` → lazyvim.json 出现该模块、保留既有用户条目、`:Lazy sync` 装其插件、`:LazyExtras` 显示为 enabled;`extra-remove` 干净撤销。

### S6 · 字体/编辑器/迁移/收尾 op + `do_configure` 改线
- [ ] 字体:`ui()` Font 行委托 `fonts.sh install|apply`(无独立状态);SSH/TUI 诚实提示。
- [ ] 保留 `set-default-editor`、`ensure-deps`;新增 `config-show`/`config-reset`(移除 kit 受管 5 产物 + 清 nvim.conf 状态,留备份)。
- [ ] 迁移:清 kit marker 的旧 rc alias 行 + 旧 `after/plugin/ubuntu-setup.lua`;**绝不删** `~/.config/nvim-<distro>`。
- [ ] 重写 `do_configure`:无参=保守收敛(已装则重生成受管产物,未装给指引);flags `--recommended`(=install+editor on)/`--colorscheme`/`--leader`/`--editor`/`--deps`/各域。
- [ ] **关卡**:静态 + 契约 green。

### S7 · `ui()` 重画 + i18n
- [ ] `ui()` 9 域分组(本体 / 主题 / 字体 / 插件 / extras / leader+keymaps+options+autocmds / Mason / Apply recommended / Remove),读 fs+nvim.conf、改走 `ui_run -- "$0" <op>`;非选择行 info/header/spacer 跳导航。
- [ ] `NVIM_I18N` en/zh/ja 增删键(主题/extra/插件名不译);删旧 distro 相关键。
- [ ] **关卡**:静态 green;伪终端冒烟不崩、`q` 退出、终端复原;`ui` 无 TTY 退 0。

### S8 · 删除旧机制(新代码已验证后)
- [ ] 删:`NVIM_DISTRO_REPO`/`NVIM_DISTRO_ORDER`/`NVIM_RECOMMENDED_DISTRO`、`do_install_distro`/`do_remove_distro`/`do_add_distro`/`_nvim_distro_*`/manifest 全套/`_nvim_alias_*`;`_nvim_cfg_mode`/`_nvim_render_overlay`/`_nvim_render_takeover`/`_nvim_apply_overlay`/`_nvim_apply_takeover`/旧 `do_config_apply`/`do_config_reset`/`_nvim_cfg_overlay_file`/`_nvim_has_plugins`/`NVIM_PLUGIN_REPO` 等裸 nvim 残留;`update-plugins` 的 appname 参数化收敛为默认 nvim。
- [ ] `usage()` 同步重写。
- [ ] **关卡**:静态 + 全契约 green;`grep -n` 确认无悬挂引用(`NVIM_APPNAME`/`distro`/`appname`/`overlay`/`takeover` 仅在注释或已无)。

### S9 · 全量验证 + 集成
- [ ] 全套静态 + 契约 + 伪终端冒烟。
- [ ] **真机端到端**(免密 sudo;破坏性 op 先征同意):
  - 干净环境 `install`(四分支逐个:空 / 已 kit / 手写 LazyVim adopt / 非 LazyVim 替换〔需同意〕)。
  - 9 域逐个 set→验证→unset/remove→验证幂等。
  - `nvim --headless +checkhealth +qa` 或启动无 error。
  - `remove`(cloned 删配置 / adopted 不删)、`--purge`(需同意)。
- [ ] `trellis-check` 子 agent 复核(继承 worktree cwd)。
- [ ] **人工 gated**:回主树 `git merge worktree-nvim-lazyvim-refactor` → 解冲突 → 主树重跑静态 + 契约 → `ExitWorktree`。

## 子 agent 派发(可选)

派 `trellis-implement`/`trellis-check` 前:本主会话已在 worktree,子 agent 继承 cwd、写入天然落隔离区。**派发前先 curate** `implement.jsonl`(给实现 agent 的 spec 清单:`.trellis/spec/scripts/*`、`.trellis/spec/lib/safety-contract.md`、本 `prd.md`/`design.md`、现 `scripts/nvim.sh`、范式样板 `scripts/tmux.sh`/`scripts/zsh.sh`)与 `check.jsonl`(校验 agent 的契约清单)。每次派发 prompt 以 `Active task: .trellis/tasks/06-24-nvim-lazyvim-refactor` 起头。

## 回滚点汇总

| 触发 | 动作 |
|---|---|
| 某关卡静态/契约红 | `git reset --hard <上一阶段>` 或 `cp $SCRATCH/nvim.sh.S<N-1> scripts/nvim.sh` |
| 真机 install 损坏配置 | 时间戳备份恢复(`*.bak.<ts>`);adopt 分支本就不动文件 |
| extras headless 机制不通 | 退 design 的 jq 备选(S5 内分支) |
| 整体放弃 | `cp $SCRATCH/nvim.sh.orig scripts/nvim.sh`;worktree 无改动则 `ExitWorktree remove` |
