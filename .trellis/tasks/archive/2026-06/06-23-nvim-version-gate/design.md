# 技术设计 — nvim.sh 版本闸升级

## 核心思路

引入一个内部判据函数 `_nvim_installed_ok`(已装 **且** ≥ `NVIM_MIN_VERSION`),把"是否需要动作"的闸门从现有的 `status`(只判在不在)收敛过来。**复用现有渠道选择逻辑**(`_nvim_apt_ok` → tarball → snap)做升级,不新增渠道。升级前若旧版是 apt 绊脚石就 `apt_remove`。改动集中在 4 个函数 + 1 个新 helper,不做大重构。

## 新增 helper

```bash
# Exit 0 iff nvim is installed AND >= NVIM_MIN_VERSION. Spawns nvim (real-op only, never under
# the KIT_PROBE_ONLY catalog probe). Used as the install/upgrade gate (vs status, which only
# checks presence).
_nvim_installed_ok() {
  have_cmd nvim || return 1
  _nvim_vercmp_ge "$(_nvim_running_ver)" "$NVIM_MIN_VERSION"
}
```

放在版本 helper 区(`_nvim_apt_ok` 附近,`nvim.sh:297` 之后)。`_nvim_running_ver`/`_nvim_vercmp_ge` 已存在,直接复用。

## 改动点

### 1) `do_install`(`nvim.sh:362`)— 闸门 + 升级前卸绊脚石

- 闸门 `if status >/dev/null 2>&1` → `if _nvim_installed_ok`,文案改为"已装且够新"。
- 进入安装路径后**只记标志、不立即卸**:`local drop_apt=0`;若 `have_cmd nvim`(已装旧版)打印 upgrading,且 `pkg_installed neovim && ! _nvim_apt_ok` 则 `drop_apt=1`。
- 渠道分支不变(`_nvim_apt_ok` → apt;`_nvim_install_tarball` → tarball;else snap),但采用 **deferred removal**:在 tarball / snap 分支**装好之后**才 `if (( drop_apt )); then apt_remove neovim; fi`——避免"卸了 apt 但下载失败 → 用户没 nvim"的窗口(tarball 的 `/usr/local/bin/nvim` 本就在 PATH 上盖过 apt 的 `/usr/bin/nvim`,卸 apt 只为清洁)。`_nvim_install_tarball` 已 `rm -rf $root` + 覆盖 symlink,升级幂等。

边界:已装的若是**非 apt** 旧版(手动 tarball/snap),不 `apt_remove`(C4);tarball 路径覆盖 `/opt`+symlink 即升级,snap 旧版则被新 tarball 的 `/usr/local/bin/nvim` 在 PATH 上 shadow(诚实,不强删 snap)。主 case(apt 旧版)处理干净。

### 2) `do_install_distro`(`nvim.sh:560-566`)— 版本不足自动升级

把现有 `else log_warn "missing or older…"` 分支改为:
```bash
else
  log_info "Neovim is missing or older than ${NVIM_MIN_VERSION} — installing/upgrading it first…"
  do_install
  if _nvim_installed_ok; then
    _nvim_sync "$appname" sync || log_warn "Plugin sync did not complete — re-run: ${0##*/} sync-plugins ${appname}."
  else
    log_warn "Could not get Neovim >= ${NVIM_MIN_VERSION} automatically — sync later with: ${0##*/} sync-plugins ${appname}."
  fi
fi
```
clone 仍在前(不依赖 nvim);升级放在 clone 之后、sync 之前,顺序自然。`do_install` 自身幂等,即便外层 `--recommended` 已调过一次也安全。

### 3) `configure --recommended`(`nvim.sh:734`)— 闸门换 ok 判据

`status >/dev/null 2>&1 || do_install` → `_nvim_installed_ok || do_install`。这样旧版在 `--recommended` 第一步就升级;`do_install_distro` 内的兜底是第二道保险。

### 4) `do_update`(`nvim.sh:423`)— apt 不够新走 tarball

apt 分支:`_nvim_apt_ok` 才提示 `apt upgrade`;否则(apt 候选 < min)**直接复用 `do_install; return $?`**——`do_install` 现已具备完整升级逻辑(deferred 卸 apt + tarball),不在 `do_update` 里复制一遍 tarball 步骤(更 DRY、更稳健)。snap / tarball-refetch 分支不变。

### 5) `CLAUDE.md` nvim.sh 段(R6)

更新两句:do_install "已装即幂等" → "已装**且 ≥ NVIM_MIN_VERSION** 才幂等跳过;低于则升级(apt 绊脚石先卸、走 tarball)";do_update "apt/snap 提示用 apt upgrade/snap refresh" → 补"apt 候选不够新时改走 tarball 升级"。

## 不做(范围外)

- 不改 `NVIM_MIN_VERSION` 数值(查证确认 0.11.2 正确)。
- 不改无参 `configure`/`status` 行为(C3 保守基线)。
- 不在 `status` 详情里加"版本不足"红字提示(nice-to-have,避免扩大范围;真正的闸在 op 里)。
- 不自动卸非 apt 旧版(C4)。
- 不动 distro 的 Lua / 不碰用户配置(C5)。

## 兼容 / 回滚

- 行为变化只在"已装旧版 + 明确安装意图"路径上触发;already-ok 与全新机器路径不变。
- 回滚 = `git revert` 单个 commit(纯脚本改动,无状态迁移)。失败补救靠幂等重跑(项目铁律④)。

## 数据流 / 提权边界

升级序里唯一提权点:`apt_remove neovim`、`_nvim_install_tarball` 内的 `sudo_run`。均走既有 lib helper;无 TTY 非免密时 `RC_NEED_SUDO` 自然中止(C2)。用户态部分(distro clone/alias/sync/conf)不受影响。
