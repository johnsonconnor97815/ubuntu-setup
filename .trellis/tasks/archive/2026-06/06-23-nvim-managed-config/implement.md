# Implement — nvim 受管配置层

> 单文件改动:`scripts/nvim.sh`(+ 文档同步)。在 worktree `feat/nvim-config` 上做。
> 每步后跑静态校验;真机端到端放最后(免密 sudo 下代跑,破坏性 op 先征同意)。

## 校验命令(每步必过)

```bash
cd /home/conn/workspace/ubuntu-setup/.claude/worktrees/nvim-config
bash -n scripts/nvim.sh
shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh        # 零告警
scripts/nvim.sh meta            # ops 与实现一致、不含 ui、新带参 op 不在 ops
scripts/nvim.sh help            # 不炸、覆盖新 op/flag
scripts/nvim.sh status          # 可独立运行
scripts/nvim.sh ui </dev/null   # 无 TTY 打印指引退 0
```

## 执行顺序

### 步骤 0 — 基线确认
- [ ] 跑一遍上面校验,确认改前全绿(基线)。

### 步骤 1 — 状态 schema + 模式检测 + 校验 helper
- [ ] 加 `_nvim_cfg_mode <appname>`(design §2,优先级:conf 锁 → manifest → 空目录 → 用户配置;appname≠nvim 强制 overlay)。
- [ ] 加 `_nvim_leader_valid` / `_nvim_colorscheme_valid` / 插件 key 校验(design §9)。
- [ ] 加受管文件路径 helper:`_nvim_cfg_overlay_file <appname>`(=`<cfg>/<appname>/after/plugin/ubuntu-setup.lua`)、`_nvim_cfg_marker` 常量。
- 校验:`bash -n` + `shellcheck`。

### 步骤 2 — lua 生成器(纯函数)
- [ ] `_nvim_gen_options`(design §5.1 curated 基线)、`_nvim_gen_keymaps`(§5.2)、`_nvim_gen_colorscheme`(§5.4)、`_nvim_gen_plugin_spec`(§5.5,curated 表 + EXTRA_PLUGIN_* + LSP 组)。
- [ ] 全部纯 stdout、无副作用、读 conf 经 `_nvim_conf_get`。
- 校验:`bash -n` + `shellcheck`;手测 `_nvim_gen_*` 输出是合法 lua 片段(可 `nvim -l` 语法检查生成串,见步骤 6)。

### 步骤 3 — 写文件:`do_config_apply` + `do_config_reset`
- [ ] `do_config_apply [--app <name>]`:解析 app(默认 nvim)→ `_nvim_cfg_mode` → 组装骨架(§6 takeover / §7 overlay)→ 路径护栏 → `backup_file`(takeover 首接管 `_nvim_backup_dir`)→ `mkdir -p` 父目录 → 写文件 → 写 `MANAGED_MODE_*` → takeover 时 `_nvim_sync` 同步插件(`_nvim_installed_ok` 闸,缺/旧则 `do_install` 后再同步,沿用 `do_install_distro` 范式)。
- [ ] takeover 写 init.lua **前检查首行 marker**:存在且无 marker ⇒ 用户文件 ⇒ fail-fast 拒绝指路(理论被检测挡住,做防御)。
- [ ] `do_config_reset [--app <name>]`:overlay 删 after/plugin 受管文件(校 marker);takeover `_nvim_backup_dir` 后删 kit init.lua + best-effort 清 `~/.local/{share,state,cache}/<app>` 的 lazy 产物(仅 takeover 自管的,谨慎);清 `MANAGED_MODE_*`。全程路径护栏。
- 校验:`bash -n` + `shellcheck`。

### 步骤 4 — 带参 setter op(都末尾调 config-apply)
- [ ] `do_set_leader` / `do_set_colorscheme` / `do_set_options` / `do_set_keymaps`(写 conf → config-apply)。
- [ ] `do_add_plugin` / `do_remove_plugin` / `do_enable_lsp`:**仅 takeover**;`_nvim_cfg_mode` 非 takeover 时拒绝 + 指路"插件交 distro";curated 走表、任意走 EXTRA_PLUGIN_*;改 conf → config-apply(含 `_nvim_sync`)。
- [ ] Node 横幅:`enable-lsp on` / curated LSP 启用后,`have_cmd node` 缺失则 `log_info` 指路 `swkit node install`(不挡)。
- 校验:`bash -n` + `shellcheck` + `meta`(确认这些**不在** ops)。

### 步骤 5 — configure flag + ui + i18n + usage + meta
- [ ] `do_configure` while-case 加 §8.2 flag(`--config-recommended`/`--options`/`--keymaps`/`--leader`/`--colorscheme`/`--cfg-plugins`/`--lsp`/`--app`);**无参分支不变**。
- [ ] `ui()` 加 "Managed config" 分组(§8.4:模式横幅 + options/keymaps 开关 + leader 输入 + colorscheme 选择器 +(takeover)plugins 勾选 + LSP 开关 + Apply recommended config + Reset),读 conf/fs、改走 `ui_run`。
- [ ] `NVIM_I18N` 加新键(en/zh/ja;插件/主题/键名不译)。
- [ ] `usage()` 补新 op/flag,写清与 distro 的 `sync/update/clean-plugins` 区别。
- [ ] 确认 `meta` 的 `ops` 不变(或仅加确属无参的);新带参 op 不进 ops。
- 校验:全套静态校验 + `help`/`status`/`ui </dev/null`。

### 步骤 6 — 静态 + 伪终端冒烟
- [ ] 用 `nvim -l`/`luac`(若有)对生成的 init.lua / after-plugin 串做语法检查(headless 生成到 temp,`nvim --headless -c 'luafile <tmp>' +q` 看无报错)。
- [ ] 伪终端冒烟:`printf 'q' | TERM=xterm-256color script -qec 'scripts/nvim.sh ui' /dev/null`(必要时 `timeout 20` 包裹,见记忆 ui-smoke-test-hang),确认渲染不崩、`q` 退出、终端复原。

### 步骤 7 — 真机端到端(★ 复核闸:破坏性 op 先征用户同意)
> 在临时 appname / 备份现有配置下做,避免污染用户真实 nvim。可用 `NVIM_APPNAME` + `--app` 隔离测试。
- [ ] 裸场景:空 `~/.config/nvim`(或临时 appname)→ `config-apply` takeover → `nvim --headless +q` 无报错 → lazy 同步 curated 插件成功 → options/colorscheme 生效 → `config-reset` 干净复原 + 留备份。
- [ ] distro 共存:装 LazyVim(或临时复用已装)→ `config-apply` overlay 写 after/plugin → `nvim --headless +q` 无报错 → kit options/colorscheme 覆盖生效 → **确认 LazyVim lua 未被改** → `add-plugin` 被拒绝指路 → `config-reset` 干净复原。
- [ ] 无参 `configure` 在干净环境零写入(grep 确认未生成受管文件、未加 MANAGED_MODE_*)。

### 步骤 8 — 文档同步(漂移防护)
- [ ] 更新根 `CLAUDE.md` 的 `nvim.sh` 段:补受管配置层(overlay/takeover、模式检测、新 op/flag、安全约束)。
- [ ] 如涉及 `skills/ubuntu-install/SKILL.md` 的 nvim 描述,同步。
- 校验:重跑全套静态校验收尾。

## 回滚点
- 每步独立、可 `git diff`/`git checkout -- scripts/nvim.sh` 回退单文件。
- 真机测试用临时 appname/备份,误操作经时间戳备份恢复。
- 受管文件全部带 marker + backup,reset op 是正规移除出口。

## 复核闸(review gates)
1. 步骤 5 后:静态全绿 + meta/ops 契约满足 → 方可进真机。
2. 步骤 7 真机:破坏性前**征用户同意**;两场景 + 无参零变化全过 → 方可进文档/收尾。
3. 收尾:`trellis-check` 质量核查 → spec 更新 → commit。
