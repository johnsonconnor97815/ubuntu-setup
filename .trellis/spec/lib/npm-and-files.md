# 用户态 npm 与文件操作 —— lib 原语用法

> 实现见 `lib/common.sh`。

---

## npm 全局安装:绝不 `sudo npm`

`sudo npm install -g` **严禁**(任意 lifecycle 脚本会以 root 跑任意代码)。两个原语:

### `npm_global_writable`(判定)

解析 `npm config get prefix`,确认其 `lib/node_modules`(或 prefix)对当前用户可写;不可写则**返回非 0** 并打印用户态修法,让调用方停下而不是伸手 sudo。

### `npm_ensure_user_prefix`(默认就走安全路径)

仅 npm 通道的脚本(`codegraph`/`trellis`,及 `codex`/`claude` 的 npm 方式)装前调它:

- prefix 已用户可写 → 什么都不做。
- prefix 是系统默认(`/usr`、`/usr/local`)→ 用户态写 `~/.npmrc` 把前缀改到 `~/.local`(`npm config set prefix`,无 sudo;可 `npm config delete prefix` 还原),再 `npm install -g`。
- **自定义且不可写**的前缀 → **不动它**(尊重用户选择),退回报错。
- 被 sudo 整体包裹(`EUID==0` 且有非 root 的 `SUDO_USER`)→ **直接拒绝**,提示以本人身份重跑。

装完 `npm install -g` 后调 `ensure_local_bin_on_path`,让刚装的 CLI 立即可用。

## 文件操作

### `backup_file PATH`

改任何配置文件前调用。把 `PATH` 复制成 `PATH.bak.<时间戳>`(文件不存在则 no-op)。这个备份是**唯一的撤销**。

### `append_once LINE FILE`

只在**精确匹配行**不存在时追加(`grep -qxF`),文件缺失则创建。保证重跑不累积重复行。受管配置块的标准写法。

### `ensure_local_bin_on_path`

把 `~/.local/bin` 加到本进程 PATH(刚装的 CLI 立刻可用)+ 经 `append_once` 写一行 guarded `export PATH=...` 进用户 shell rc(`~/.zshrc` 或 `~/.bashrc`)。以**用户身份**跑,绝不改别人的 dotfile;已在 PATH 或目录不存在则 no-op。

## 受管块/drop-in 的通行模式

多数组件管理脚本(`zsh.sh`/`tmux.sh`/`ghostty.sh`/`rime.sh`/`go.sh`/`python.sh`)把偏好存在 `~/.config/ubuntu-setup/<key>.conf`,每次改动**整体重生成**一个受管 drop-in 或主配置内的**标记块**,改前 `backup_file`、保留用户标记外内容。是写"可增删的配置"的标准范式——新脚本要做配置管理时照抄结构。
