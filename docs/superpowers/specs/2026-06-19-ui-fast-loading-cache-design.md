# UI 加载零卡顿:缓存 + 预加载 + 异步刷新设计

> 状态:设计已确认(2026-06-19),待实现。
> 关联:`lib/ui.sh`(`ui_catalog`/`_ui_catalog_collect`)、`lib/common.sh`、`swkit`、`bootstrap.sh`、`scripts/*.sh`。
> 前序:`2026-06-13-script-owned-tui-ui-refactor-design.md`(本设计在其 `ui_catalog` 基础上加缓存/异步层)。

## 1. 问题

把脚本集合做成 TUI 目录(`ui_catalog`)后,**进入"安装软件"目录可见 ~3 秒卡顿**,且每次从子界面返回都重复一次。

### 1.1 实测根因(本机 18 个脚本)

热路径 `_ui_catalog_collect`(`lib/ui.sh:701`)对每个 `*.sh` **fork 两个 bash 子进程**:`"$f" meta` + `"$f" status`。18 脚本 = 36 次 fork,实测串行总耗时 **~2.99s**。成本三块:

1. **基础 fork 开销**:每个子进程重新 `source` `lib/common.sh`(360 行)+ `lib/ui.sh`(760 行)再 `kit_dispatch`,≈ 0.02s × 36 ≈ 0.7s。其中 `meta`/`status` 路径**根本用不到 `ui.sh`**。
2. **重型 `status` 探测**(实测 + 调查):`python`(7+ 次 spawn:`python3` + 5×`uv tool list`,最坏 2s)、`vscode`(在 PATH 时 `code --version` 可能拉起整个 GUI,最坏 2s)、`node`(2 次 node spawn)、`go`(`go version`/`go env` spawn + 循环 6 工具)、`codegraph`/`trellis`(node CLI `--version` spawn)、`mattpocock-skills`(17 技能 × 7 agent = 119 次 fs stat)、`rime`(fcitx5 spawn)。本机合计 ~1.5s,**装了对应软件的真实机器上更重**。
3. **串行 + 无缓存 + 无预加载**,且 `ui_catalog` 每次从子 `ui()` 返回都 `refresh=1` 全量重跑。

同样的 2N/N fork 模式也存在于 `swkit list`(`cmd_list`)与 `swkit search`(N 次 meta)。

### 1.2 已确认的有利事实(实现前已核实)

- **18 个 `meta` 全部纯静态**(`cat <<'META'` / `emit_meta_line` 硬编码,无文件读、无命令)→ meta 可按脚本文件 **mtime 永久缓存**。
- **没有任何 `status` 做网络 I/O**,**没有任何 `status` 有副作用**(纯只读,无 mkdir/写文件)→ 可放心缓存 + 并行调用。

### 1.3 业界范式(exa 调研印证)

- **"缓存即 UI" + stale-while-revalidate**(ghtui、openai/codex TUI PR #17039):首帧 <50ms 从本地缓存渲染,后台刷新,数据到达再重绘;"首帧短暂显示旧值是可接受的——用户在那一瞬也无法据此行动"。
- **mtime/realpath 作 key 的缓存失效**(bash-cache、`_cached_eval`、`dev+inode+size+mtime` 校验):用文件 realpath+mtime 作 key,配 TTL 兜底 + `CACHE_DISABLE` 旁路。
- **带超时的事件轮询**(ratatui `event::poll`):主循环用超时等输入,空闲 tick 收割后台结果并重绘,绝不在主循环里做阻塞 I/O。

## 2. 目标与非目标

### 目标
1. **覆盖所有脚本**:任意数量的 `scripts/*.sh` 都受益,无需逐脚本登记。
2. **可预加载**:能在用户到达目录前把缓存热起来。
3. **合理用缓存加速**:meta/status 的探测结果缓存复用,跨 `swkit` 调用持久。
4. **UI 零卡顿**:首帧瞬时,输入永不被探测阻塞。

### 非目标
- 不引入守护进程(违背项目"全新 Ubuntu 即用 + 简单"的初衷)。
- 不改各脚本的 `status` **退出码契约**(0 ⟺ 已装/已生效)。
- 不缓存任何敏感数据(只缓存安装布尔 + 静态 meta 字段)。

## 3. 数据模型:三层,各按性质处理

| 数据 | 性质 | 策略 | 冷启动 | 热启动 |
|---|---|---|---|---|
| `meta` 字段(key/name/category/ops/desc) | 纯静态 | 按脚本 mtime 永久缓存 | 并行探测(18 并发 ≈ 0.05s) | mtime 校验后读文件,瞬时 |
| `status` 安装布尔 | 实时、只读、无副作用 | stale-while-revalidate:缓存值(或占位)瞬时渲染 → 后台并行重探 → 到达重绘 | "探测中"占位,后台数秒内填充 | 缓存值瞬时,后台静默重探自纠 |

**安全性论证(关键)**:陈旧 badge **绝不导致错误操作**。真正的 install/remove/configure 永远跑脚本本体,其 `do_install`/`do_remove` 开头的 `status` 闸门会**现场复检活系统**(幂等契约)。例:缓存说"已装"但实际被外部 `apt remove` 了 → 用户点安装 → 脚本 status 看到未装 → 正常安装。缓存只影响**显示**,不影响**行为**。这让积极缓存在本项目里是安全的。

## 4. 新模块 `lib/cache.sh`

职责单一的缓存原语,被 `common.sh` 在 source `ui.sh` 之前 source(于是 `ui.sh` 的 catalog 与 `swkit`/`bootstrap` 都拿得到)。

### 4.1 缓存位置与卫生
- 目录:`<real-home>/.cache/ubuntu-setup/catalog/`。`<real-home>` 用与 `kit_load_lang` 相同的方式解析(`EUID==0 && SUDO_USER` 时取 `getent passwd` 的 home),避免 sudo 包裹时写到 root。
- 权限:目录 `0700`(缓存含本机软件清单,虽非密钥也按保守处理)。
- 内容:每脚本一个缓存文件 `catalog/<key>.cache`(key 来自 meta;文件名仅 `[A-Za-z0-9_-]`,非法字符拒绝)。格式为简单 `field=value` 行(同 meta 风格,grep 可读,**不 source**):
  ```
  script_mtime=<脚本 .sh 的 mtime epoch>
  key=<key>
  name=<name>
  category=<category>
  ops=<ops>
  desc=<desc>
  installed=<0|1>
  status_ts=<status 探测时刻 epoch>
  ```
  meta 字段与 `script_mtime` 一起写;`installed`/`status_ts` 单独更新(status 重探只改这两行,不动 meta 行)。

### 4.2 API
- `kit_cache_dir` → 打印缓存目录(按需 `mkdir -p`,失败回退 `/tmp`)。
- `kit_meta_cached <script>` → 打印该脚本的 meta 字段块。命中条件:缓存存在且 `script_mtime` == 当前文件 mtime;否则 `"$script" meta` 重探、写缓存、再打印。
- `kit_status_cached <script>` → 打印 `installed=<0|1>`(从缓存,不触发探测;无缓存则打印 `installed=` 空,调用方按"未知/探测中"处理)。
- `kit_probe_status <script>` → 真正跑 `"$script" status >/dev/null 2>&1`、把 `installed`/`status_ts` 写入缓存。供后台 worker 与同步补齐调用。
- `kit_cache_invalidate <key>` → 删该脚本的 `installed`/`status_ts`(保留 meta),强制下次重探。
- `kit_cache_warm [dir]` → 对目录内所有脚本**并行**跑 `kit_meta_cached` + `kit_probe_status`,填满缓存。`swkit warm` 与 bootstrap 预加载调它。
- `kit_cache_clear` → 清空缓存目录(`swkit cache clear`)。
- 旁路:`KIT_NO_CACHE=1` 时所有 `kit_*_cached` 直接转发到脚本、不读不写缓存(给 LLM/调试/`--no-cache`)。

### 4.3 并行原语
- `kit_parallel_probe <dir> -- <fn>`:对目录内每个可执行 `*.sh`(跳过 `TEMPLATE.sh`)后台跑 `<fn> <script> &`,带并发上限(`min(8, nproc)`,避免低核机器过载;18 个短任务足够快),`wait` 全部。用于 cold meta(同步)与 warm(可后台)。

## 5. 事件循环改造(`lib/ui.sh`)

### 5.1 `ui_read_key` 加可选超时
签名扩展:`ui_read_key [timeout_secs]`。有 timeout 时首字节 `read -rsn1 -t <timeout>`;超时(read 返回非 0 且无字节)设 `UI_KEY="timeout"` 返回 0。无 timeout 时行为不变(全阻塞)。其余解码逻辑不变。

### 5.2 `ui_catalog` 改为 stale-while-revalidate
```
进入:
  cold-meta: kit_parallel_probe(meta) 同步并行(~0.05s) → 拿到 key/name/category/order
  从缓存装载每脚本 installed(有则用,无则标"探测中")
  立即首帧渲染
  启动后台 status 重探:对(过期/未知)脚本 kit_probe_status 并行,各写缓存文件

循环:
  渲染当前内存状态(badge: 已装/未装/探测中三态)
  ui_read_key <poll_timeout>   # 例如 0.15s
  case UI_KEY in
    timeout) 收割:重读这些脚本的 installed 缓存,有变化则更新内存数组(下轮重绘);
             若后台全部完成,停止轮询(改回阻塞 read 省 CPU)
    up/down/...) 导航(纯内存,瞬时)
    enter/right) ui_end; "$path" ui; ui_begin; kit_cache_invalidate <key>; 重启后台重探该脚本(返回后该项必新鲜)
    r) 硬刷新:对全部脚本 kit_cache_invalidate + 重启后台重探
    esc/q) 退出
```
- **三态 badge**:`installed`(实心)/`missing`(空心)/`mid`(`◐`,"探测中/未知")。`ui_badge` 已有 `mid` 态,直接复用。
- **收割机制**(文件版 mpsc):后台 worker 各自把结果写 `catalog/<key>.cache`;循环每个 timeout tick 重读相关脚本的 `installed` 行。用一个轻量"待收割集合"+ 每项 worker 完成标记(worker 写完缓存即视为完成,循环比对内存值与缓存值发现差异即更新)。判定"全部完成":待收割集合空。
- **节流**:软 TTL `KIT_STATUS_TTL`(默认如 5s)。进入时 `status_ts` 在 TTL 内的脚本不重探(直接信缓存),避免快速进出反复 spawn 18 个;超 TTL 或被精准失效的才后台重探。`r` 无视 TTL。

### 5.3 限制 TTY / 无 TTY 回退
- 受限 TTY(`_ui_catalog_text`)与 `swkit list`:无法异步重绘,改为**同步**:`kit_meta_cached`(热则瞬时)+ 对缺失/过期项 `kit_parallel_probe(status)` 并行补齐,再一次性渲染。仍远快于现状(并行 + 缓存)。
- 无 TTY:`ui` 入口照旧打印 swkit 指引退 0(不变)。

## 6. 预加载(无守护进程)

1. **持久磁盘缓存跨调用复用**:`swkit list`/catalog 第二次起恒为瞬时(缓存已落盘)。
2. **bootstrap 进 TUI 时后台预热**:`run_tui` 入口处 `kit_cache_warm "$(kit_scripts_dir)" &`(detach,忽略输出)。用户还在看顶层菜单/设置时缓存已热,进"安装软件"即瞬时。
3. **显式 `swkit warm`**:给 LLM/cron/脚本主动预热(也可 `swkit warm` 后再 `swkit list`)。

## 7. swkit 一并受益(覆盖所有入口)

- `cmd_list`:改 `kit_meta_cached` + 并行补齐 status(`kit_parallel_probe`),热则瞬时。
- `cmd_search`:只需 meta → `kit_meta_cached`,mtime 命中即瞬时。
- 新增 `swkit warm`(→ `kit_cache_warm`)、`swkit cache clear`(→ `kit_cache_clear`)。
- `swkit --no-cache <...>`:置 `KIT_NO_CACHE=1` 透传。

## 8. 重型 status 瘦身(Q2=yes)

原则:**安装布尔(`have_cmd`/`pkg_installed`/单遍 fs 扫描)与昂贵详情(版本字符串/工具枚举)分离,布尔先短路并尽早返回退出码**。catalog/`list` 本就丢弃 status 文本(`>/dev/null`),详情成本对其纯浪费;后台重探也因此更快、占位更快被填充。各脚本契约(退出码、`swkit <x> status` 的人读文本)保持:

- `mattpocock-skills.sh`:119 次 stat → 先把每个目标 agent 的 skills 目录**单遍列出**成集合,再对 17 技能做集合判存,O(agents) 次 readdir。
- `vscode.sh`:安装布尔用 `have_cmd code || pkg_installed code`,**不 spawn**;`code --version` 文本仅在确需详情时取。
- `python.sh`:安装布尔短路(`python3` + `python3 -m pip` 可用);uv 工具探测从"每工具一次 `uv tool list`"改为**单次** `uv tool list` 解析。
- `go.sh`/`node.sh`/`codegraph.sh`/`trellis.sh`:安装布尔用 `have_cmd`,版本 spawn 仅用于详情行,布尔路径不 spawn 运行时。

> 注:这些瘦身**降低后台重探与冷探测的延迟**;即便不瘦身,缓存+异步也已把成本移出热路径。两者叠加让占位态在数百毫秒内被填充。

## 9. 可选次要项(惰性 source `ui.sh`)

`common.sh` 末尾无条件 `source ui.sh`,但 `meta`/`status`/`do_*` 都不需要那 530 行。可改为**惰性**:加 `kit_load_ui`(幂等 source ui.sh),只在 `kit_dispatch` 的 `ui` 分支、`ui_default_menu`、`swkit ui`/`bootstrap` TUI 入口调用。收益:每次 meta/status fork 的基础成本约减半。
**但**:缓存+异步落地后,meta 已 mtime 缓存(几乎不 fork)、status 后台异步,该微优化边际收益变小,且改动触达每个消费方(漂移面大)。**列为可选后续**,主线完成且验证稳定后再评估是否纳入;若增加风险则不做。

## 10. 触达文件

| 文件 | 改动 |
|---|---|
| `lib/cache.sh`(新) | 缓存原语(§4) |
| `lib/common.sh` | source `cache.sh`;(可选)惰性 ui.sh |
| `lib/ui.sh` | `ui_read_key` 超时;`ui_catalog` 异步重绘 + 三态 badge + `r` 键;`_ui_catalog_collect`/`_ui_catalog_text` 走缓存 |
| `swkit` | `cmd_list`/`cmd_search` 走缓存;`warm`/`cache clear`/`--no-cache` |
| `bootstrap.sh` | `run_tui` 入口后台 `kit_cache_warm` |
| `scripts/{python,vscode,go,node,codegraph,trellis,mattpocock-skills}.sh` | status 瘦身(§8) |
| `scripts/TEMPLATE.sh` | 注释:status 布尔/详情分离约定、缓存对 status 的期望(只读、无副作用、退出码即布尔) |
| `CLAUDE.md` | 架构散文:新增 `lib/cache.sh` 角色、ui_catalog 异步模型、预加载、防漂移条目 |

## 11. 验证

- 静态:`for f in bootstrap.sh lib/*.sh swkit scripts/*.sh; do bash -n "$f"; done`;`shellcheck -x --source-path=SCRIPTDIR ...`(零告警,含新 `lib/cache.sh`)。
- 契约:每脚本 `meta` 字段齐全、`status` 可独立跑且退出码正确(瘦身后装前/装后各测)、`ui` 无 TTY 退 0、`help` 不炸。
- 缓存正确性:首次冷探测写缓存;改一个脚本 mtime → meta 重探;`kit_cache_invalidate` 后 status 重探;`KIT_NO_CACHE=1` 完全旁路;sudo 包裹时缓存落在真实用户 home。
- 异步循环:伪终端冒烟 `printf 'q' | TERM=xterm-256color script -qec 'swkit ui' /dev/null`——渲染不崩、占位态被填充后重绘、`q` 干净退出、终端复原。
- 性能实测:冷/热目录加载计时。目标:**热 < 0.1s 首帧**、**冷首帧 < ~0.1s**(meta 并行)随后异步填充,从当前 ~3s 降下来;`swkit list` 热 < 0.1s。

## 12. 风险与缓解

- **异步重绘在纯 bash 的复杂度**:用文件 + 轮询(read 超时)而非线程,逻辑直白;`ui_begin`/`ui_end` 的 `trap` 已保证任何崩溃复原终端;后台 worker 只写自己的缓存文件(无共享写冲突),孤儿 worker 写完即止、无害。
- **缓存陈旧**:见 §3 安全论证——只影响显示,行为永远现场复检;后台重探数秒自纠;`r` 硬刷新 + `KIT_NO_CACHE` 兜底。
- **并发 spawn 过载**:`kit_parallel_probe` 并发上限 `min(8, nproc)`。
- **缓存目录不可写**(只读 home/异常):回退 `/tmp`;再不行则 `KIT_NO_CACHE` 行为(直接探测,退化为并行无缓存,仍比现状快)。
