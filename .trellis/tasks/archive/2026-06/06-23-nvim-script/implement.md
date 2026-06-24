# Implement — scripts/nvim.sh

**纯新增单文件** `scripts/nvim.sh`(`cp scripts/TEMPLATE.sh` 起步)。**不改任何现有文件**——TUI / swkit / ui_catalog 都动态读 `scripts/*.sh` 的 `meta` 发现并归类,新脚本自动出现,无需注册。无回滚风险。

## 有序实现清单

1. **骨架**:`cp scripts/TEMPLATE.sh scripts/nvim.sh`;改文件头 / `meta`(category=common、ops=install,remove,configure,update,update-plugins)/ `usage` / 末尾 `kit_dispatch "$@"`。→ `bash -n` 过。
2. **用户态层**:`_nvim_user_guard`(认 SUDO_USER 解析真实 home,拒绝 sudo 包裹,范式 rime `_rime_resolve_home`)+ 路径派生(`_NVIM_*` + XDG)+ `nvim.conf` 读写(grep 读不 source)。
3. **本体渠道**:`_nvim_arch`、`_nvim_vercmp`(`sort -V` 或逐段比较)、apt 候选探测(`LC_ALL=C apt-cache policy`)、`_nvim_install_tarball`(API 取 url+digest〔无 jq grep/sed〕→ curl → `sha256sum -c` → /opt + symlink)、snap 回退;`do_install` / `status`(KIT_PROBE_ONLY 早返)/ `do_remove` / `do_update`。
4. **distro 安装器**:`_NVIM_DISTROS` 表、`_nvim_backup_dir`(目录级时间戳备份)、智能默认 appname、`do_install_distro` / `do_remove_distro`(manifest + 路径护栏)/ `do_add_distro`。
5. **插件同步**:`_nvim_sync <appname> <sync|update|clean>`(`timeout` 包 headless)+ `do_sync_plugins` / `do_update_plugins` / `do_clean_plugins`。
6. **外部依赖**:`_nvim_ensure_deps`(apt: git curl build-essential ripgrep fd-find unzip + fonts.sh)+ `do_ensure_deps`。
7. **默认编辑器**:`do_set_default_editor [off]`(用户态 rc 行 + best-effort update-alternatives)。
8. **configure**:`do_configure`(flags + `--recommended` + 无参保守基线)。
9. **i18n**:`NVIM_I18N`(en/zh/ja)+ `_nvim_lang` + 查表 helper。
10. **ui()**:分组(Neovim / Distros / Plugins / External deps / Default editor / Apply recommended),读走 fs、改走 `ui_run`。
11. **收尾校验**(见下)。

## 验证命令

```bash
# 语法 + 静态(必过零告警)
bash -n scripts/nvim.sh
shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh

# 脚本契约
./scripts/nvim.sh meta        # 字段齐全;ops 与实现一致;ops 不含 ui;category=common
./scripts/nvim.sh status      # 可独立运行(装前/装后);退出码 0 iff 已装
./scripts/nvim.sh help        # 不炸
./scripts/nvim.sh ui          # 无 TTY 下打印「用 swkit nvim <op>」指引退 0

# 伪终端富屏冒烟(memory: ui 冒烟可能挂死 → 必须 timeout 包裹)
printf 'q' | timeout 10 script -qec 'TERM=xterm-256color ./scripts/nvim.sh ui' /dev/null

# 真机行为(本机有 GUI/TTY,neovim 是 TUI 可直接测)
./scripts/nvim.sh install                    # 渠道择优 + 版本闸;打印渠道
./scripts/nvim.sh status                     # 显示版本 + 渠道
./scripts/nvim.sh install-distro lazyvim     # 智能默认落点 + clone + lazy 同步
./scripts/nvim.sh remove-distro lazyvim      # 按 manifest 精确卸载 + 备份
./scripts/nvim.sh remove                     # 卸本体、保留用户配置
```

## 风险点 / 注意

- **tarball sha256 校验是信任边界**:API 解析(无 jq 的 grep/sed 取 `digest`)易脆,务必对 asset 名精确锚定;校验失败 / API 不可达 → fail-fast,**绝不**无校验落盘执行。`stable` tag 滚动 → 不硬编码 sha256/版本。
- **真机 smoke 别污染 rc / 系统**(memory: android-java-rc-pollution-pitfall):`install-distro`(写 alias)、`set-default-editor`、`ensure-deps`、`configure`/`--recommended`、`install` 都会改 rc / 装系统包。仅跑非变更检查时**只**用 `meta`/`status`/`help`/`ui`(无副作用);跑真测后清理本会话 worktree 内的 rc 改动与临时 distro 目录。
- **update-alternatives 需 sudo**:headless 无 TTY → `RC_NEED_SUDO`,best-effort 仅 `log_warn` 不中断。
- **本机可能已装 neovim**:先 `status` 看现状,验 `install` 幂等(已装报版本跳过)。
- **distro clone 需 git**:本机有则直接测;ensure-deps 会补。
- **lazy 同步耗时 / 需网络**:`timeout` 保护;离线 / CI 环境跳过同步只测 clone + manifest。

## 回滚点

- 单文件新增,`git rm scripts/nvim.sh` 即完全回滚。
- 真测产生的副作用(本机装的 neovim / distro 目录 / rc 行)与脚本代码无关,按上面 remove 系列 op + 手清 rc 还原。

## task.py start 前检查

- [ ] prd.md / design.md / implement.md 三件齐备且经用户审阅。
- [ ] 确认无需改现有文件(动态发现机制)。
- [ ] 版本闸门槛 0.11.2、curated distro 集合、渠道顺序 与 prd/design 一致。
