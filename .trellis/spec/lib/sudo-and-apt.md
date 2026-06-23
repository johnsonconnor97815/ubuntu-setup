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

## Vendor 二进制 `.deb` 渠道(curl 解析 + `apt_install` 本地路径)

有些软件**无 apt 源**,但官方发布版本化 `.deb`(GitHub releases 或下载 API)。装法见 `cursor.sh`/`ghostty.sh`/`obsidian.sh`:

```bash
have_cmd curl || apt_install curl ca-certificates           # 先确保 curl
# 1. 解析 .deb URL —— grep,绝不 jq(全新 Ubuntu 没有 jq)
url="$(curl -fsSL --connect-timeout 30 --max-time 30 \
        --retry 3 --retry-delay 5 --retry-all-errors "$api" 2>/dev/null \
       | grep -oE 'https://[^"]*_amd64\.deb' | head -n1 || true)"
[[ -n "$url" ]] || { log_err "..."; return 1; }
# 2. 下到 mktemp,装 *本地路径*
tmp="$(mktemp -d)"; deb="$tmp/pkg.deb"; rc=0
curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
     --retry 3 --retry-delay 5 --retry-all-errors -C - "$url" -o "$deb" || { rm -rf "$tmp"; return 1; }
apt_install "$deb" || rc=$?      # 含 / 的参数 → apt 当本地文件:解依赖、可净卸
rm -rf "$tmp"; return "$rc"
```

**铁律**:

- **`apt_install "<路径>.deb"` 而非 `dpkg -i`**——含 `/` 的参数被 apt-get 当文件,**解依赖**且能干净 `apt remove`;`dpkg -i` 会留未满足依赖。
- **绝不 jq** 解析 API(全新 Ubuntu 无 jq),用 `grep -oE`。
- 无 apt 源 → apt 不会升级 → 暴露 **`update` op** 重取最新 `.deb`(进 `meta.ops`,见 `cursor.sh`/`obsidian.sh`)。
- 架构经 `dpkg --print-architecture` 映射,资产不覆盖的架构 `return 1` 诚实报错(别静默选错 asset)。

### Gotcha:curl `--max-time` 二分律(小元数据**加**,大二进制**不加**)

| 调用 | `--max-time`? | stall guard | 为什么 |
|------|--------------|-------------|--------|
| 小 JSON/元数据解析(几 KB) | **加**(如 `30`) | 可省 | 有界 body 可墙钟封顶;**防握手成功后涓流/卡死无限阻塞** |
| 大二进制下载(几十~几百 MB) | **绝不加** | **必加** `--speed-limit 1024 --speed-time 60` + `--retry … -C -` | 墙钟上限会**中断健康的慢下载**;只在真停滞(<1KB/s 持续 60s)才放弃,`-C -` 断点续传 |

> 这条在 `obsidian.sh` 审查中被抓到:API 解析 curl 漏了 `--max-time`,握手后服务器涓流会挂死整脚本。**大下载与小元数据的超时策略相反,别混。**

#### Wrong
```bash
curl -fsSL --max-time 60 "$big_deb_url" -o "$deb"          # 大下载封墙钟:健康慢下载被砍断
url="$(curl -fsSL --connect-timeout 30 "$api" | grep ...)"  # 小 API 无读取上限:涓流 → 永久挂起
```
#### Correct
```bash
curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
     --retry 3 --retry-delay 5 --retry-all-errors -C - "$big_deb_url" -o "$deb"   # 大:只封连接+停滞
url="$(curl -fsSL --connect-timeout 30 --max-time 30 "$api" | grep ...)"          # 小:墙钟封顶安全
```
