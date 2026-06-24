# 执行计划 — nvim.sh 版本闸升级

## 有序清单

1. **新增 `_nvim_installed_ok`**(`nvim.sh` 版本 helper 区,`_nvim_apt_ok` 之后 ~L297)。
   - 校验点:`bash -n`。
2. **改 `do_install`**(R1+R2,~L362)。
   - 闸门 `status` → `_nvim_installed_ok`,文案"已装且够新"。
   - 渠道选择前插入升级序(已装旧版 → 提示升级;apt 绊脚石且 `! _nvim_apt_ok` → `apt_remove neovim`)。
3. **改 `do_install_distro`**(R3,~L560-566)。
   - 版本不足 `else` 分支:`log_warn` → `do_install` 升级,再按 `_nvim_installed_ok` 决定 sync / 退化 warn。
4. **改 `configure --recommended`**(R4,~L734)。
   - `status >/dev/null 2>&1 || do_install` → `_nvim_installed_ok || do_install`。
   - **不动**无参 baseline 那句(C3)。
5. **改 `do_update`**(R5,~L423)。
   - apt 分支:`_nvim_apt_ok` 才建议 `apt upgrade`;否则卸 apt 包 + `_nvim_install_tarball` + `CHANNEL=tarball`。
6. **改 `CLAUDE.md`**(R6)nvim.sh 段 do_install / do_update 两句描述。
7. **更新 `usage()` 文案(若需要)**:`install` 一行从"Idempotent"补一句"已装旧版会升级"(可选,保持简洁)。

## 校验命令(每改完一轮跑)

```bash
# 语法(必过)
bash -n scripts/nvim.sh
# shellcheck 零告警
shellcheck -x --source-path=SCRIPTDIR scripts/nvim.sh
# 全量(确保没碰坏别的)
for f in bootstrap.sh lib/common.sh lib/cache.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/cache.sh lib/ui.sh bootstrap.sh
```

## 契约自测(AC2)

```bash
scripts/nvim.sh meta                 # 字段齐全;ops=install,remove,configure,update,update-plugins(不含 ui)
scripts/nvim.sh status; echo "rc=$?" # 可独立运行(本机 0.9.5:rc=0,因 have_cmd nvim)
scripts/nvim.sh help >/dev/null      # 不炸
scripts/nvim.sh ui; echo "rc=$?"     # 无 TTY 打印指引退 0
printf 'q' | TERM=xterm-256color timeout 10 script -qec 'scripts/nvim.sh ui' /dev/null  # 伪终端冒烟,q 干净退出
```
注:ui 冒烟用 `timeout` 包裹(见项目记忆 ui-smoke-test-hang)。

## 真机行为验收(AC4/AC5/AC6 — 需 sudo,本机正是 0.9.5)

⚠️ 这些会**改本机系统**(卸 apt neovim + 装 tarball)。在**有 TTY 的终端**跑(sudo 弹密码),或确认免密 sudo 后由 Bash 跑。先取得用户确认再执行——属验证步骤,不在 commit 前置硬门槛(可标注"真机验收待执行")。

```bash
swkit nvim install            # 期望:检测 0.9.5 旧版 → 卸 apt → 装 tarball ≥0.11.2
nvim --version                # 期望:v0.11.x
grep CHANNEL ~/.config/ubuntu-setup/nvim.conf   # 期望:CHANNEL=tarball
nvim                          # 期望:LazyVim 正常 bootstrap,不再报版本
```

## Review gate

- 2.2 Quality check:静态 + 契约自测全过;人读 diff 确认 C1-C6 未违背(尤其 C3 无参基线、C4 只卸 apt)。
- 真机 AC4-AC6 若未当场执行,在 finish 时如实标注"已静态/契约验证,真机升级路径待用户在 TTY 终端执行"。

## Rollback points

- 每个清单项是独立编辑,任一步 `bash -n`/`shellcheck` 失败即就地修,不继续。
- 整体回滚 = 丢弃 `scripts/nvim.sh` + `CLAUDE.md` 的工作区改动(`git checkout --`)或 revert commit。
