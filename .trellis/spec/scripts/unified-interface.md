# 统一接口 —— 每个脚本必须实现的约定

> 起点是 `cp scripts/TEMPLATE.sh scripts/<key>.sh`。骨架:`#!/usr/bin/env bash` →
> `set -Eeuo pipefail` → 定位并 `source lib/common.sh` → 定义下列函数 → 末尾 `kit_dispatch "$@"`。

---

## 骨架定位 lib

```bash
set -Eeuo pipefail
_kit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$_kit_here/lib/common.sh"
```

## 必需函数

### `meta`(机读自描述)

```bash
meta() {
  cat <<'META'
key=git
name=git
category=essentials
ops=install,remove,configure
desc=Distributed version control system (apt)
META
}
```

- `category ∈ essentials|languages|editors|terminal|ai|apps`(端用户 6 类,其余归 `other`;见 `docs/adr/0003`)。
- **`ops` 必须恰好列出实现了的操作**(`install,remove[,configure]` + 任何自定义 op)。
- **`ui` 是入口模式,绝不进 `ops`**(见 [ui-conventions.md](./ui-conventions.md))。
- 可选 `tags=`(空格分隔 facet):`desktop-only` 让 catalog 在 SSH/headless 下**标灰+角标、仍可选**(披露非隐藏);`gui`/`cli` 描述性;`desktop_hint=` 覆盖角标文案。
- 可选 `requires=`/`recommends=`(两档声明式跨脚本依赖,见 `docs/adr/0002`):硬 `requires="key[>=ver]"` 在 install 前**仅存在性** gate(版本信息性、由消费脚本强制),未满足 fail-fast+指路、`--with-requires` 按 `tsort` 拓扑序装链;软 `recommends="key"` 只指路**永不**自动装。

### `status`(幂等探测)

退出码 0 当且仅当已装/已生效,并打印版本。观察**真实系统**(`have_cmd`/`pkg_installed`/版本命令),绝不查记录的标志位。

```bash
status() { have_cmd git && git --version; }
```

### `do_install` / `do_remove`(闸在 status 上)

```bash
do_install() {
  if status >/dev/null 2>&1; then
    log_info "git already installed ($(git --version 2>/dev/null)) — skipping."
    return 0
  fi
  apt_install git
}
```

`do_remove` 对称:未装则提示跳过。详见 [idempotency.md](./idempotency.md)。

## 可选函数

### `do_configure`(安全最小基线 + 可选 opt-in 常用方案)

- **无参默认 = 保守 headless 安全基线**(见 `tmux.sh`/`rime.sh`/`go.sh`/`python.sh` 的无参分支)。
- 但**可以**把该软件的常用方案作为显式 opt-in(`--recommended` 等)覆盖进来(作者裁量)。
- 改文件前 `backup_file`,幂等。`git.sh` 的 `do_configure` 无参时只**报告**当前 user.name/email。
- 没有安全配置步骤就**删掉整个 `do_configure`**,且 `meta` 的 `ops` 不列 `configure`。

### 自定义动作 `do_<op>`

`meta` 的 `ops` 里声明 install/remove/configure 之外的动作,`kit_dispatch` 把未知 op `<x>` 路由到 `do_<x>`(**连字符转下划线**:`default-shell` → `do_default_shell`)。

- **无参**动作进 `meta.ops`(如 zsh 的 `install-omz`、tmux 的 `update-plugins`)。
- **带参**动作(如 zsh 的 `add-plugin <名|url>`、rime 的 `add-schema <id>`)**不一定进 `ops`**,由 `swkit`/LLM 调用,且应在 `ui()` 里交互可达。
- 参数务必校验(如 schema id 经 `^[A-Za-z0-9_]+$` 挡注入)。

## `kit_dispatch` 路由(末尾必调)

`kit_dispatch "$@"` 把子命令路由到上述函数:`meta`/`status`/`install`/`remove`/`configure`/`help`/`ui` 是固定入口,其余 `<op>` 找 `do_<op>`。它开头还会调 `kit_load_lang` 按用户语言渲染。**脚本最后一行就是它。**

## 渠道优先级(装的时候)

`apt` → vendor apt repo(`add_apt_keyring`/`add_apt_source`)→ snap → 官方 vendor 脚本(显示 URL)→ 手动二进制。**优先 apt**;择高而用时打印所用渠道(见 `ghostty.sh`)。
