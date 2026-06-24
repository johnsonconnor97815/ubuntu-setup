# 修复 nvim.sh 已装旧版不升级却照装新版 distro 的缺陷

## Goal

让 `scripts/nvim.sh` 在系统**已存在但低于 `NVIM_MIN_VERSION`(0.11.2)的 nvim** 时,在明确的安装/配置意图下**自动升级**到满足 curated distro 的版本(走官方 stable tarball,必要时卸掉绊脚石 apt 旧包),而不是当前"静默跳过升级、却照装一个启动即报错的 distro"。

## 背景 / 根因(已实测确认)

用户用 `nvim.sh`(`configure --recommended`)装完,启动 nvim 报:
`LazyVim requires Neovim >= 0.11.2`。实测该机:

- 实际 nvim = apt 包 `neovim 0.9.5-6ubuntu2`(`/usr/bin/nvim`),早于跑脚本就存在;
- 该机 apt candidate **也只有 0.9.5**(< 0.11.2),`apt upgrade` 救不了;
- kit `nvim.conf` 只有 `DEFAULT_EDITOR=on`、**无 `CHANNEL=`** → 证明 `do_install` 的安装分支从没真正执行。

缺陷链:`do_install`(`nvim.sh:364`)与 `configure --recommended`(`nvim.sh:734`)的闸门是 `status`,**只判 nvim 在不在、不判版本够不够**;检测到 0.9.5 已装即 `return 0` 跳过升级,但 `--recommended` 后续仍 `do_install_distro lazyvim`,`do_install_distro`(`nvim.sh:561`)版本不足时也**只 `log_warn` 然后继续 clone**。三处叠加 → 用户必装出一个跑不起来的 distro。

附带洞:`do_update`(`nvim.sh:423`)对 apt 渠道一律建议 `apt upgrade`,但当 apt candidate < min 时这是**无用建议**(仓库根本没有新版)。

## 查证依据(exa + context7)

LazyVim 官方 issue [#6421](https://github.com/LazyVim/LazyVim/issues/6421)(v15.x Migration,folke):**自 v15.x 起强制 Neovim ≥ 0.11.2**(LSP 实现大改,backport 了 `vim.lsp.is_enabled`),并明确"残留旧版 nvim → 删旧装新"是标准解法(issue 内 @gruberchris 的 0.9.5 残留案例与本例一致)。脚本硬编码的 `NVIM_MIN_VERSION="0.11.2"` 数字正确,无需改动。

## Requirements

- R1 `do_install`:闸门从"已装即跳过"改为"已装**且** ≥ `NVIM_MIN_VERSION` 才跳过";否则进入安装/升级路径。已装旧版时打印"正在升级"。
- R2 升级时若旧版是 **apt 包且 apt 候选不够新**,先 `apt_remove neovim` 再走 tarball(否则 apt 旧包与 tarball 并存、`type -a nvim` 混淆)。决策已获用户同意("必要时卸 apt 旧包")。
- R3 `do_install_distro`:版本不足时**自动触发 `do_install`** 升级,升级成功后再 `_nvim_sync`;升级失败才退化为 warn + 指路 `sync-plugins`。
- R4 `configure --recommended`:首句闸门改为"已装且够新才跳过",旧版触发升级。
- R5 `do_update`:apt 渠道但 candidate < min(且 `apt upgrade` 给不出新版)时,改为**走 tarball 升级**(必要时卸 apt 旧包),而非建议 `apt upgrade`。
- R6 同步更新 `CLAUDE.md` 中 nvim.sh 段的契约描述(do_install/do_update 行为)。
- R7 **修复 tarball 渠道的 JSON 解析**(实现中真机发现的底层 bug,被 R1 升级路径首次触发):`_nvim_install_tarball` 用 `tr '{' '\n'` + `grep -F '"name":"…"'` 解析 GitHub release API,有两处错——① API 实际是 `"name": "…"`(**冒号后有空格**),无空格 `grep -F` 匹配不到;② asset 对象内含 `"uploader": {…}` 嵌套,`tr '{' '\n'` 把 `name` 与 `digest`/`url` 切到不同段。改为稳健解析(`tr ',' '\n'` + awk 状态机:`name` 行翻转"在本 asset 内"标志、uploader 无 `"name"` key 不污染,标志为真时抓 url+digest),并把 `sha256sum -c` 信任边界保持不变。`browser_download_url` / `digest` 同 asset 唯一绑定。

## 约束(本项目铁律,不可妥协)

- C1 **幂等**:已装且够新时重跑必须是安全 no-op(R1 闸门保证)。
- C2 **逐命令 sudo**:卸包/装 tarball 只经 `sudo_run`/`apt_remove`/`apt_install`;无 TTY 且非免密时返回 `RC_NEED_SUDO` 自然中止,不绕过。
- C3 **保守基线不变**:**无参 `configure` 与无参 `status` 行为不变**——无参 baseline 仍是 `status >/dev/null || do_install`(只确保"在",不主动升级旧版);自动升级只在明确意图(`install` / `update` / `install-distro` / `--recommended`)时发生。
- C4 **只卸绊脚石**:仅当旧版是 apt 包且 apt 候选不够新才卸;**不自动卸非 apt 的旧版**(手动 tarball/snap/源码),那些走各自渠道覆盖或诚实提示。
- C5 **不碰用户配置**:升级只动 binary,绝不删 `~/.config/nvim*` / distro 数据。
- C6 `status` 的 `KIT_PROBE_ONLY` 早返路径不得引入 nvim spawn(版本探测只在真实 op 里发生)。

## Acceptance Criteria

- [x] AC1 静态校验全过:`bash -n scripts/nvim.sh`;`shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh` 零告警。
- [x] AC2 契约自测:`meta` 字段齐全、`ops` 不含 `ui`;`status` 可独立运行;`help` 不炸;`ui` 无 TTY 退 0;伪终端冒烟 `q` 干净退出。
- [x] AC3 幂等:已装 0.12.3(≥min)重跑 `install` → "already installed and new enough" no-op,版本/渠道未变。
- [x] AC4 升级路径(真机,本机 0.9.5):`swkit nvim install` 检测旧版 → 装官方 stable tarball 0.12.3 → deferred 卸 apt 0.9.5 → `nvim`=/usr/local/bin/nvim→/opt;`CHANNEL=tarball`。
- [x] AC5 distro 联动:`sync-plugins nvim` 后 LazyVim 升到 16.0.0 并正常加载(`OK nvim 0.12.3`),版本错消失。〔mason 的 tree-sitter-cli/shfmt 因 headless `+qa` 早退被中断,属 LazyVim 运行时依赖、首次交互启动自动续装,非脚本范围〕
- [~] AC6 `do_update`:apt-too-old 分支复用 `do_install`(逻辑随 AC4 的 do_install 验证);初始 apt-旧版态已被 AC4 升级消费,不再可现场复现起点。
- [x] AC7 保守基线未回归:无参 `configure` no-op rc=0;无参 `status` 行为与改前一致(C3)。
- [x] AC8 `CLAUDE.md` 的 nvim.sh 段(do_install/do_update/tarball 解析)与新行为一致(无契约漂移)。
- [x] AC9 tarball 解析(真机):修复后从 stable API 正确取出 url + 64-hex sha256(`c441b54…0724d`),`sha256sum -c` 通过,装到 `/opt`+symlink;升级实际走 tarball(不再 fallback snap)。
