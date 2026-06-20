# sudo 提权与 apt —— lib 原语用法

> 实现见 `lib/common.sh`。本文件讲**怎么用**,以及踩坑点。

---

## 提权:`sudo_run`(唯一途径)

```bash
sudo_run install -d -m 0755 /etc/apt/keyrings   # 单条命令逐个提权
```

`sudo_run` 的四种分支(见 `lib/common.sh` 的 `sudo_run`):

| 情形 | 行为 |
|------|------|
| 已是 root(`EUID==0`) | 直接执行 |
| sudo 免密(`sudo -n true` 成功) | `sudo CMD` |
| 有可写 `/dev/tty` | `sudo CMD`(正常弹密码) |
| 无 sudo / 无 tty 且需密码 | 打印「请手动执行 `sudo CMD`」,返回 `RC_NEED_SUDO=97` |

**`RC_NEED_SUDO=97`**:LLM 经自己的非交互 shell 跑脚本时没有 TTY、无法输密。`sudo_run` 返回 97,脚本因 `set -e` 停止。调用方/skill **按退出码 97 分支,绝不按文案判断**。

## 两个判定函数——按退出码/能否 open,绝不看文案

- `sudo_passwordless()` = `sudo -n true` 的**退出码**。classic sudo 与 sudo-rs 文案不同且会被本地化,所以**只看退出码**。
- `kit_have_tty()` = 真正去 `open /dev/tty` 读和写(`{ true </dev/tty; } && { true >/dev/tty; }`)。设备节点存在 ≠ 可打开:无控制终端时 open 会 ENXIO。**只看 `-r`/`-w` 权限位会把 headless 误判为交互。**

铁律:**凡是判断 sudo/终端状态,按稳定文本/退出码/能否 open,而非可翻译文案。** 脚本里探测 apt 候选等同理(用 `LC_ALL=C apt-cache policy`,见 `rime.sh` 的 `_rime_apt_available`)。

## SUDO_USER:解析真实用户

脚本可能被 sudo 整体包裹(`EUID==0` 且有 `SUDO_USER`)。这时:

```bash
user="${SUDO_USER:-$(id -un)}"   # 见 zsh.sh / docker.sh
```

用 `getent passwd "$SUDO_USER" | cut -d: -f6` 取真实 home(见 `lib/common.sh` 的 `kit_load_lang`)。**绝不**信任 `~`/`$HOME`——那是 root 的。

## apt(非交互)

```bash
apt_install <pkg>...    # DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends
apt_remove  <pkg>...    # remove(非 purge,保留用户配置)
apt_update_once         # 进程内首次才真跑(哨兵 _KIT_APT_UPDATED)
```

- `--no-install-recommends` 是 lib 默认;**要 recommends 包必须显式列**(见 `rime.sh` 装 `fcitx5-frontend-all`)。
- 加完 vendor 源后想立刻装新版,需清哨兵 `unset _KIT_APT_UPDATED` 强制刷新(见 `vscode.sh`)。
- 脚本**绝不**写裸 `apt-get`。

## Vendor apt 渠道(绝不 apt-key)

需要从厂商官方 apt 源取新版时:

```bash
add_apt_keyring <name> <key_url>   # 取 key、dearmor、装到 /etc/apt/keyrings/<name>.gpg
add_apt_source  <name> <line>      # 写 /etc/apt/sources.list.d/<name>.list
# line 自带 signed-by=/etc/apt/keyrings/<name>.gpg
```

`apt-key` 已废弃,**绝不使用**。真实例子见 `vscode.sh`(Microsoft 源)。
