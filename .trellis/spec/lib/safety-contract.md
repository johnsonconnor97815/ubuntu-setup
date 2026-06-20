# 安全契约 —— 5 条不可妥协项

> 唯一权威来源是 **CLAUDE.md「领域约束」一节 + `lib/common.sh` 代码**。本文件是给
> 写/改 `scripts/` 的人看的**实操摘要**:每条底线 + 强制它的 lib 原语。改安全语义先改
> 那两处,本文件跟随。

每条都既是 `lib/common.sh` 的代码强制,又是贡献者必须贯彻的纪律。**违反任何一条 = 不可合并。**

---

## ① 幂等、查活系统

每个操作以**观察真实系统**为前提,绝不依赖记录的标志位。

- 探测原语:`have_cmd <cmd>`(在 PATH?)、`pkg_installed <pkg>`(dpkg 状态**恰为** `install ok installed`——removed-but-not-purged 不算)。
- 每个脚本的 `status()` 是闸门:**退出码 0 当且仅当已装/已生效**,并打印版本。
- `do_install`/`do_remove` 先跑 `status`:已装则报版本跳过、未装则提示跳过。
- 重跑任何脚本第二次都是安全 no-op。

## ② 绝不整体 root,逐命令 sudo

脚本以普通用户跑,只对确需 root 的**单条**命令提权。

- **唯一**提权途径:`sudo_run CMD...`。`EUID==0` 直接执行;免密则 `sudo CMD`;有可写 `/dev/tty` 则 `sudo CMD`(正常弹密码);否则打印「请你自己执行:sudo CMD」并返回 `RC_NEED_SUDO=97`,脚本因 `set -e` 而停。
- **绝不** echo/pipe/here-string 密码进 `sudo -S`、**绝不**存密码、**绝不**自写 NOPASSWD 规则。
- 被 sudo 整体包裹时,用 `SUDO_USER` 解析真实用户 home/身份,**绝不**信任 `~`/`$HOME`。
- 详见 [sudo-and-apt.md](./sudo-and-apt.md)。

## ③ 非交互 apt

每条 apt 命令都免交互,绝不在无桌面 server 上卡 debconf 提示。

- 用 `apt_install`(`env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends`)、`apt_remove`(用 `remove` 而非 `purge`,保留用户配置)、`apt_update_once`(进程内首次才真跑,用哨兵 `_KIT_APT_UPDATED`)。
- 脚本**不写**裸 `apt-get`。

## ④ fail-fast、可续跑、无回滚

- 每个脚本 `set -Eeuo pipefail`,首错即停;补救方式是**重跑**(靠 ① 的幂等保证安全)。
- 改任何配置文件前先 `backup_file PATH`(时间戳副本是唯一的"撤销")。
- 追加配置用 `append_once LINE FILE`(`grep -qxF`,重跑不累积)。
- **没有回滚机制**——不写复杂的撤销逻辑;幂等 + 备份 + 重跑就是恢复路径。

## ⑤ kit 与 skill 都是面向陌生人机器的产品资产

脚本会在作者从未见过的机器上跑 `sudo`,信任与安全是一等约束。

- **渠道保守**,优先级固定:`apt` → vendor apt repo(`add_apt_keyring`/`add_apt_source`,key 进 `/etc/apt/keyrings` + `signed-by=`,**绝不** `apt-key`)→ snap → 官方 vendor 脚本(**显示 URL**)→ 手动二进制(最后手段)。
- npm 全局安装一律**用户态**,**`sudo npm install -g` 严禁**(见 [npm-and-files.md](./npm-and-files.md))。
- 先计划后执行、显式验证。

---

## "不安全写法没有原语"

这是本库的核心设计:`sudo npm`、整体 root、`apt-key` **故意没有 helper**。如果你发现自己要写裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`,说明你绕开了契约——停下,找对应 lib helper;没有就说明该操作本就不该做。
