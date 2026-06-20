# UI 加载零卡顿 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `ui_catalog`/`swkit list` 的 ~3s 目录加载卡顿降到首帧瞬时(stale-while-revalidate),覆盖所有脚本、支持预加载、跨调用持久缓存。

**Architecture:** 新增 `lib/cache.sh`(被 `common.sh` source)做探测缓存:`meta` 按脚本 mtime 永久缓存、`status` 安装布尔缓存 + 精准失效。`ui_catalog` 改为从缓存瞬时首帧渲染 + 后台并行重探 + 超时轮询收割重绘。`bootstrap` 进 TUI 时后台预热,`swkit warm` 显式预热。重型 `status` 用 `KIT_PROBE_ONLY` 约定只算布尔、跳过昂贵详情。

**Tech Stack:** 纯 bash + ANSI(无新依赖)。缓存为 `~/.cache/ubuntu-setup/catalog/` 下的 `key=value` 文件。验证:`bash -n`、`shellcheck -x`、脚本 `status`/`meta` 契约、伪终端冒烟、计时。

## Global Constraints

(逐条 verbatim,每个任务都隐含遵守)

- 仅 bash,每软件一脚本,自硬编码 meta;不引入 Python/YAML/新运行时依赖。
- **绝不整体 root**;一切提权走 `sudo_run`;缓存/探测全程**用户态、无 sudo**;sudo 包裹时认 `SUDO_USER` 解析真实 home(同 `kit_load_lang`)。
- **不改 `status` 退出码契约**:`status` 退出 0 ⟺ 已装/已生效,两条路径(普通 / `KIT_PROBE_ONLY`)退出码必须一致。
- `status` 必须**只读、无副作用**(缓存层依赖此);`meta` 必须纯静态。
- 用户文件**grep 读、绝不 source**;改配置/受管文件前 `backup_file`,追加用 `append_once`(此项目本计划基本不涉及用户 dotfiles)。
- `meta` 的 `ops` 必须恰好列实现的操作;**`ui` 不进 `ops`**;`category ∈ essentials|common|ai|runtime`(其余 `other`)。
- i18n:`ui()` 标签经本地化表;软件/技能**名不译**;`log_*`/usage 英文。
- shellcheck 保持零告警:`shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/*.sh bootstrap.sh`。
- 缓存陈旧只影响**显示**不影响**行为**(真实 op 永远跑脚本本体,其 status 闸门现场复检)。
- `KIT_NO_CACHE=1` 必须完全旁路缓存(直接探测,不读不写)。

---

## 文件结构

| 文件 | 责任 |
|---|---|
| `lib/cache.sh`(新) | 探测缓存原语:路径解析、meta/status 缓存读写、mtime 校验、并行探测、失效、warm/clear、`KIT_NO_CACHE` 旁路 |
| `lib/common.sh`(改) | 在 source `ui.sh` 前 source `cache.sh` |
| `lib/ui.sh`(改) | `ui_read_key` 超时;`_ui_catalog_scan`(走缓存、三态);`ui_catalog` 异步重绘 + `r` 键 + 返回后失效;`_ui_catalog_text` 走缓存 |
| `swkit`(改) | `cmd_list`/`cmd_search` 走缓存;`warm`/`cache clear`/`--no-cache` |
| `bootstrap.sh`(改) | `run_tui` 入口后台 `kit_cache_warm` |
| `scripts/{node,codegraph,trellis,vscode,go,python}.sh`(改) | `KIT_PROBE_ONLY` 布尔短路 |
| `scripts/mattpocock-skills.sh`(改) | `KIT_PROBE_ONLY` 算法改造(单次 agents + 首命中早返回) |
| `scripts/TEMPLATE.sh`(改) | 注释:`KIT_PROBE_ONLY` 约定 + status 只读/退出码即布尔 |
| `CLAUDE.md`(改) | 架构散文:`lib/cache.sh` 角色、异步 catalog、预加载、防漂移 |
| `test/cache_test.sh`(新,dev-only,不部署) | `lib/cache.sh` 行为断言 |

---

## Task 1: `lib/cache.sh` 缓存原语 + 接入 common.sh

**Files:**
- Create: `lib/cache.sh`
- Modify: `lib/common.sh`(末尾 source 段)
- Test: `test/cache_test.sh`(新建)

**Interfaces:**
- Produces:
  - `kit_cache_dir` → 打印缓存目录(`mkdir -p`,失败回退 `/tmp/ubuntu-setup-catalog-$EUID`)
  - `kit_meta_cached <script>` → 打印 meta 字段块(不含 `script_mtime=` 行);mtime 命中读缓存,否则探测并写
  - `kit_status_value <script>` → 打印 `1`/`0`/``(空=无缓存);不触发探测
  - `kit_status_age <script>` → 打印自上次 status 探测的秒数(无则极大值)
  - `kit_probe_status <script>` → 跑 `KIT_PROBE_ONLY=1 "$script" status`,写 `installed`/`status_ts`,退出码=安装布尔
  - `kit_cache_invalidate <script|base>` → 删该脚本 `.status`(保留 `.meta`)
  - `kit_meta_warm <dir>` / `kit_cache_warm <dir>` → 并行预热(meta / meta+status)
  - `kit_cache_clear` → 清空缓存
  - 旁路:`KIT_NO_CACHE` 非空时 `kit_meta_cached`/`kit_status_value` 直接转发探测、不读不写

- [ ] **Step 1: 写 `lib/cache.sh`**

```bash
#!/usr/bin/env bash
#
# lib/cache.sh — catalog probe cache for the ubuntu-setup script collection.
#
# The TUI catalog (lib/ui.sh) and swkit list/search probe every script's `meta` and
# `status` by forking a subprocess per script — ~3s for the whole collection on a cold
# run. This module memoizes those probes so the catalog can paint instantly from cache and
# revalidate in the background (stale-while-revalidate). It is the data twin of ui.sh's
# rendering: ui.sh decides WHEN to show; this decides WHAT is known and how fresh.
#
# Two kinds of cached data, by nature:
#   - meta   : 100% static (hardcoded in each script) -> cached forever, keyed by the
#              script file's mtime; only re-probed when the .sh changes.
#   - status : live install boolean (read-only, no network, no side effects) -> cached
#              with a timestamp; revalidated in the background and precisely invalidated
#              after any op runs on a script.
#
# A stale badge NEVER causes a wrong action: real install/remove always runs the script,
# whose status gate re-checks the live system (idempotency). The cache only affects display.
#
# Sourced (not executed) by common.sh BEFORE ui.sh, so the catalog and swkit/bootstrap all
# share it. Honors SUDO_USER for the real home (same as kit_load_lang). User-space, no sudo.

[[ -n "${_KIT_CACHE_LOADED:-}" ]] && return 0
_KIT_CACHE_LOADED=1

# Soft TTL (seconds): a status entry younger than this is trusted without re-probing on
# catalog entry (throttles repeated spawns). Override with KIT_STATUS_TTL.
: "${KIT_STATUS_TTL:=5}"

# Resolve the real user's home, honoring a sudo wrapper (mirror kit_load_lang).
_kit_real_home() {
  local home="${HOME:-}"
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || true)"
  fi
  printf '%s' "$home"
}

_KIT_CACHE_DIR=""
kit_cache_dir() {
  if [[ -n "$_KIT_CACHE_DIR" ]]; then printf '%s' "$_KIT_CACHE_DIR"; return 0; fi
  local home dir fallback="/tmp/ubuntu-setup-catalog-$EUID"
  home="$(_kit_real_home)"
  if [[ -n "$home" ]]; then dir="$home/.cache/ubuntu-setup/catalog"; else dir="$fallback"; fi
  if ! mkdir -p "$dir" 2>/dev/null; then dir="$fallback"; mkdir -p "$dir" 2>/dev/null || true; fi
  chmod 0700 "$dir" 2>/dev/null || true
  _KIT_CACHE_DIR="$dir"
  printf '%s' "$dir"
}

# Epoch mtime of a file (0 if missing).
_kit_mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# Filename-safe base (script basename without .sh) for cache file names.
_kit_cache_base() { local b; b="$(basename "$1")"; printf '%s' "${b%.sh}"; }
_kit_cache_keysafe() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

# Read one field from a key=value file. $1 file, $2 field. Prints value, 1 if missing.
_kit_cache_field() {
  local f="$1" k="$2" line
  [[ -f "$f" ]] || return 1
  while IFS= read -r line; do
    if [[ "$line" == "$k="* ]]; then printf '%s' "${line#*=}"; return 0; fi
  done <"$f"
  return 1
}

# Print the script's meta field block, from cache when the .sh is unchanged, else (re)probe.
kit_meta_cached() {
  local script="$1" base cache mtime blob
  [[ -n "${KIT_NO_CACHE:-}" ]] && { "$script" meta 2>/dev/null; return $?; }
  base="$(_kit_cache_base "$script")"
  _kit_cache_keysafe "$base" || { "$script" meta 2>/dev/null; return $?; }
  cache="$(kit_cache_dir)/${base}.meta"
  mtime="$(_kit_mtime "$script")"
  if [[ -f "$cache" ]] && [[ "$(_kit_cache_field "$cache" script_mtime)" == "$mtime" ]]; then
    grep -v '^script_mtime=' "$cache" 2>/dev/null
    return 0
  fi
  blob="$("$script" meta 2>/dev/null)" || return 1
  { printf 'script_mtime=%s\n' "$mtime"; printf '%s\n' "$blob"; } >"$cache.tmp.$$" 2>/dev/null \
    && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
  printf '%s\n' "$blob"
}

# Probe status (boolean only), write installed + ts. Exit code = installed. KIT_PROBE_ONLY
# tells slimmed status functions to skip expensive detail.
kit_probe_status() {
  local script="$1" base cache inst ts
  if KIT_PROBE_ONLY=1 "$script" status >/dev/null 2>&1; then inst=1; else inst=0; fi
  if [[ -z "${KIT_NO_CACHE:-}" ]]; then
    base="$(_kit_cache_base "$script")"
    if _kit_cache_keysafe "$base"; then
      ts="$(date +%s 2>/dev/null || echo 0)"
      cache="$(kit_cache_dir)/${base}.status"
      { printf 'installed=%s\n' "$inst"; printf 'status_ts=%s\n' "$ts"; } >"$cache.tmp.$$" 2>/dev/null \
        && mv -f "$cache.tmp.$$" "$cache" 2>/dev/null || rm -f "$cache.tmp.$$" 2>/dev/null
    fi
  fi
  [[ "$inst" == 1 ]]
}

# Print cached install boolean (1/0) or empty if unknown. Never probes. Honors KIT_NO_CACHE
# (probes once, no write).
kit_status_value() {
  local script="$1" base cache
  if [[ -n "${KIT_NO_CACHE:-}" ]]; then
    if KIT_PROBE_ONLY=1 "$script" status >/dev/null 2>&1; then printf '1'; else printf '0'; fi
    return 0
  fi
  base="$(_kit_cache_base "$script")"
  cache="$(kit_cache_dir)/${base}.status"
  _kit_cache_field "$cache" installed 2>/dev/null || true
}

# Seconds since the last status probe (999999 if never).
kit_status_age() {
  local script base cache ts now
  script="$1"; base="$(_kit_cache_base "$script")"
  cache="$(kit_cache_dir)/${base}.status"
  ts="$(_kit_cache_field "$cache" status_ts 2>/dev/null || echo '')"
  [[ -n "$ts" ]] || { echo 999999; return 0; }
  now="$(date +%s 2>/dev/null || echo "$ts")"
  echo $(( now - ts ))
}

# Drop a script's cached status (force re-probe). Keeps meta.
kit_cache_invalidate() {
  local base; base="$(_kit_cache_base "$1")"
  _kit_cache_keysafe "$base" || return 0
  rm -f "$(kit_cache_dir)/${base}.status" 2>/dev/null || true
}

kit_cache_clear() {
  local dir; dir="$(kit_cache_dir)"
  rm -f "$dir"/*.meta "$dir"/*.status "$dir"/*.tmp.* 2>/dev/null || true
}

# Usable parallelism, capped to keep low-core machines sane.
_kit_nproc() {
  local n; n="$(nproc 2>/dev/null || echo 2)"; case "$n" in ''|*[!0-9]*) n=2 ;; esac
  (( n > 8 )) && n=8; (( n < 1 )) && n=1; printf '%s' "$n"
}

# Run FN over each script in DIR, in parallel, batched by the core cap. FN gets the path.
_kit_parallel_scripts() {
  local dir="$1" fn="$2" f cap n=0
  [[ -d "$dir" ]] || return 0
  cap="$(_kit_nproc)"
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    [[ -x "$f" ]] || continue
    [[ "$(basename "$f")" == TEMPLATE.sh ]] && continue
    "$fn" "$f" >/dev/null 2>&1 &
    (( ++n % cap == 0 )) && wait
  done
  shopt -u nullglob
  wait
}

# Warm only meta (cheap; fills meta cache so subsequent reads are warm).
kit_meta_warm() { _kit_parallel_scripts "${1:-${KIT_SCRIPTS_DIR:-}}" kit_meta_cached; }

# Warm meta then status for the whole collection (preload). meta first so .meta files exist.
kit_cache_warm() {
  local dir="${1:-${KIT_SCRIPTS_DIR:-}}"
  _kit_parallel_scripts "$dir" kit_meta_cached
  _kit_parallel_scripts "$dir" kit_probe_status
}
```

- [ ] **Step 2: 接入 common.sh** — 在末尾 `source ui.sh` 之前加 source `cache.sh`。

Modify `lib/common.sh` 末尾(当前为):
```bash
# shellcheck source=ui.sh
source "$KIT_LIB_DIR/ui.sh"
```
改为:
```bash
# Probe cache (catalog meta/status memoization), sourced before ui.sh so the catalog uses it.
# shellcheck source=cache.sh
source "$KIT_LIB_DIR/cache.sh"
# shellcheck source=ui.sh
source "$KIT_LIB_DIR/ui.sh"
```

- [ ] **Step 3: 语法 + shellcheck**

Run:
```bash
bash -n lib/cache.sh lib/common.sh
shellcheck -x --source-path=SCRIPTDIR lib/cache.sh lib/common.sh
```
Expected: 无输出(零告警)。

- [ ] **Step 4: 写行为断言 `test/cache_test.sh`**

```bash
#!/usr/bin/env bash
# test/cache_test.sh — behavior assertions for lib/cache.sh. Dev-only, not deployed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Isolated cache dir so we never touch the user's real cache.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP"; unset SUDO_USER
# shellcheck source=/dev/null
source "$HERE/lib/common.sh"

fail=0
ok()   { printf 'ok   - %s\n' "$1"; }
bad()  { printf 'FAIL - %s\n' "$1"; fail=1; }

S="$HERE/scripts/git.sh"   # cheap, always present

# meta cache: first call probes + writes, second is mtime-valid read
m1="$(kit_meta_cached "$S")"
[[ "$m1" == *"key=git"* ]] && ok "meta has key=git" || bad "meta missing key=git"
[[ -f "$(kit_cache_dir)/git.meta" ]] && ok ".meta written" || bad ".meta not written"
grep -q '^script_mtime=' "$(kit_cache_dir)/git.meta" && ok "meta carries script_mtime" || bad "meta missing script_mtime"
m2="$(kit_meta_cached "$S")"
[[ "$m1" == "$m2" ]] && ok "meta stable across calls" || bad "meta differs across calls"
[[ "$m2" != *script_mtime* ]] && ok "meta output strips script_mtime" || bad "meta output leaked script_mtime"

# mtime invalidation: bump mtime -> re-probe (still same content, but path executes)
touch "$(kit_cache_dir)/git.meta"   # make cache mtime != script mtime is hard; instead corrupt then re-read
printf 'script_mtime=0\nkey=STALE\n' >"$(kit_cache_dir)/git.meta"
m3="$(kit_meta_cached "$S")"
[[ "$m3" == *"key=git"* ]] && ok "stale mtime forces re-probe" || bad "stale mtime not re-probed"

# status: probe writes installed + ts; value reads without probing
kit_probe_status "$S" || true
v="$(kit_status_value "$S")"
[[ "$v" == 0 || "$v" == 1 ]] && ok "status value is 0/1 ($v)" || bad "status value not 0/1: '$v'"
[[ -f "$(kit_cache_dir)/git.status" ]] && ok ".status written" || bad ".status not written"
age="$(kit_status_age "$S")"; [[ "$age" =~ ^[0-9]+$ ]] && (( age < 5 )) && ok "fresh status age ($age)" || bad "bad status age: $age"

# invalidate drops status, keeps meta
kit_cache_invalidate "$S"
[[ ! -f "$(kit_cache_dir)/git.status" ]] && ok "invalidate removed .status" || bad "invalidate left .status"
[[ -f "$(kit_cache_dir)/git.meta" ]] && ok "invalidate kept .meta" || bad "invalidate removed .meta"
[[ -z "$(kit_status_value "$S")" ]] && ok "value empty after invalidate" || bad "value non-empty after invalidate"

# warm fills the collection
kit_cache_clear
kit_cache_warm "$HERE/scripts"
ls "$(kit_cache_dir)"/*.meta >/dev/null 2>&1 && ok "warm wrote .meta files" || bad "warm wrote no .meta"
ls "$(kit_cache_dir)"/*.status >/dev/null 2>&1 && ok "warm wrote .status files" || bad "warm wrote no .status"

# KIT_NO_CACHE bypass: no files read/written, still returns sane values
kit_cache_clear
KIT_NO_CACHE=1 kit_meta_cached "$S" | grep -q 'key=git' && ok "no-cache meta works" || bad "no-cache meta failed"
[[ ! -f "$(kit_cache_dir)/git.meta" ]] && ok "no-cache wrote nothing" || bad "no-cache wrote a file"
nv="$(KIT_NO_CACHE=1 kit_status_value "$S")"; [[ "$nv" == 0 || "$nv" == 1 ]] && ok "no-cache status value ($nv)" || bad "no-cache status bad: $nv"

exit "$fail"
```

- [ ] **Step 5: 跑断言,全过**

Run: `chmod +x test/cache_test.sh && bash test/cache_test.sh`
Expected: 全部 `ok -`,退出 0(无 `FAIL`)。

- [ ] **Step 6: 提交**

```bash
git add lib/cache.sh lib/common.sh test/cache_test.sh
git commit -m "feat(cache): lib/cache.sh — meta(mtime)/status 探测缓存原语 + 接入 common.sh"
```

---

## Task 2: `KIT_PROBE_ONLY` 约定 + 瘦身 7 个重型 status

**Files:**
- Modify: `scripts/node.sh:46-49`, `scripts/codegraph.sh:72-78`, `scripts/trellis.sh:91-97`, `scripts/vscode.sh:66-76`, `scripts/go.sh:160-169`, `scripts/python.sh:266-280`, `scripts/mattpocock-skills.sh:362-370`

**Interfaces:**
- Consumes: `KIT_PROBE_ONLY`(由 Task 1 的 `kit_probe_status` 设为 1)
- 约定:`status` 在 `KIT_PROBE_ONLY` 非空时**只决定安装布尔并尽早返回**,跳过版本/工具枚举等昂贵详情;两条路径退出码**必须一致**。

- [ ] **Step 1: node.sh —— 布尔短路**

`scripts/node.sh:46-49` 当前:
```bash
status() {
  have_cmd node && have_cmd npm \
    && printf 'node %s / npm %s\n' "$(node --version)" "$(npm --version)"
}
```
改为:
```bash
status() {
  have_cmd node && have_cmd npm || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  printf 'node %s / npm %s\n' "$(node --version)" "$(npm --version)"
}
```

- [ ] **Step 2: codegraph.sh —— 布尔短路**

`scripts/codegraph.sh:72-78` 当前:
```bash
status() {
  have_cmd codegraph || return 1
  local v=""
  v="$(codegraph --version 2>/dev/null | head -n1)" || v=""
  [[ -n "$v" ]] || v="codegraph (installed)"
  printf '%s\n' "$v"
}
```
改为(在 `have_cmd` 后插入短路):
```bash
status() {
  have_cmd codegraph || return 1
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
  local v=""
  v="$(codegraph --version 2>/dev/null | head -n1)" || v=""
  [[ -n "$v" ]] || v="codegraph (installed)"
  printf '%s\n' "$v"
}
```

- [ ] **Step 3: trellis.sh —— 布尔短路**

`scripts/trellis.sh:91-97`,同 codegraph,在 `have_cmd trellis || return 1` 后插入:
```bash
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
```

- [ ] **Step 4: vscode.sh —— 布尔短路(不 spawn GUI)**

`scripts/vscode.sh:66-76` 当前:
```bash
status() {
  if have_cmd code; then
    code --version 2>/dev/null | head -n1
    return 0
  fi
  if pkg_installed code; then
    printf 'code (dpkg: installed)\n'
    return 0
  fi
  return 1
}
```
改为:
```bash
status() {
  have_cmd code || pkg_installed code || return 1
  if [[ -n "${KIT_PROBE_ONLY:-}" ]]; then return 0; fi
  if have_cmd code; then code --version 2>/dev/null | head -n1; else printf 'code (dpkg: installed)\n'; fi
}
```

- [ ] **Step 5: go.sh —— 布尔短路**

`scripts/go.sh:160-169`,在 `have_cmd go || return 1` 后插入:
```bash
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
```
(其余 `go version`/`go env`/工具循环保持,仅在非 PROBE_ONLY 时执行。)

- [ ] **Step 6: python.sh —— 布尔短路**

`scripts/python.sh:266-280`,在 `_py_base_installed || return 1` 后插入:
```bash
  [[ -n "${KIT_PROBE_ONLY:-}" ]] && return 0
```
(其余 python3/pip 版本、uv 工具循环保持,仅在非 PROBE_ONLY 时执行。)

- [ ] **Step 7: mattpocock-skills.sh —— 算法改造短路(单次 agents + 首命中早返回)**

`scripts/mattpocock-skills.sh:362-370` 当前:
```bash
status() {
  _mps_user_paths >/dev/null 2>&1 || return 1
  local installed count agents
  installed="$(_mps_installed_curated)"
  [[ -n "$installed" ]] || return 1
  count="$(printf '%s\n' "$installed" | grep -c .)"
  agents="$(_mps_get_agents | tr ' ' ',')"
  printf '%s Matt Pocock skills installed (agents: %s)\n' "$count" "$agents"
}
```
改为(PROBE_ONLY:`_mps_get_agents` 只调一次、首个命中即返回,远快于 `_mps_installed_curated` 的 17×agents):
```bash
status() {
  _mps_user_paths >/dev/null 2>&1 || return 1
  if [[ -n "${KIT_PROBE_ONLY:-}" ]]; then
    local a p s
    for a in $(_mps_get_agents); do
      p="$(_mps_agent_path "$a")" || continue
      for s in $_MPS_SKILL_KEYS; do
        [[ -f "$p/$s/SKILL.md" ]] && return 0
      done
    done
    return 1
  fi
  local installed count agents
  installed="$(_mps_installed_curated)"
  [[ -n "$installed" ]] || return 1
  count="$(printf '%s\n' "$installed" | grep -c .)"
  agents="$(_mps_get_agents | tr ' ' ',')"
  printf '%s Matt Pocock skills installed (agents: %s)\n' "$count" "$agents"
}
```

- [ ] **Step 8: 语法 + shellcheck**

Run:
```bash
for f in node codegraph trellis vscode go python mattpocock-skills; do bash -n "scripts/$f.sh"; done
shellcheck -x --source-path=SCRIPTDIR scripts/node.sh scripts/codegraph.sh scripts/trellis.sh scripts/vscode.sh scripts/go.sh scripts/python.sh scripts/mattpocock-skills.sh
```
Expected: 零输出。

- [ ] **Step 9: 退出码一致性 + 提速验证**

Run(两条路径退出码必须一致;PROBE_ONLY 不慢于普通):
```bash
for f in node codegraph trellis vscode go python mattpocock-skills; do
  scripts/$f.sh status >/dev/null 2>&1; a=$?
  KIT_PROBE_ONLY=1 scripts/$f.sh status >/dev/null 2>&1; b=$?
  [[ "$a" == "$b" ]] && echo "ok   $f (rc=$a)" || echo "FAIL $f normal=$a probe=$b"
done
```
Expected: 全部 `ok`(退出码相同)。

- [ ] **Step 10: 提交**

```bash
git add scripts/node.sh scripts/codegraph.sh scripts/trellis.sh scripts/vscode.sh scripts/go.sh scripts/python.sh scripts/mattpocock-skills.sh
git commit -m "perf(scripts): KIT_PROBE_ONLY 约定 —— 重型 status 只算安装布尔、跳过昂贵详情"
```

---

## Task 3: swkit 走缓存 + warm/cache/--no-cache

**Files:**
- Modify: `swkit`(`cmd_list` 76-135、`cmd_search` 138-165、`main` 188-199、`usage`)

**Interfaces:**
- Consumes: `kit_meta_cached`/`kit_status_value`/`kit_cache_warm`/`kit_cache_clear`/`kit_meta_warm`/`_kit_parallel_scripts`(Task 1)
- `meta_field`(swkit 已有,解析 meta blob)

- [ ] **Step 1: `cmd_list` 走缓存**

把 `cmd_list`(`swkit:76-100`)循环里的探测换成缓存。当前:
```bash
    if ! blob="$("$f" meta 2>/dev/null)"; then
      log_warn "Skipping $(basename "$f"): its 'meta' failed."
      continue
    fi
    ...
    if "$f" status >/dev/null 2>&1; then installed="yes"; else installed="no"; fi
```
改为(先并行预热,再逐个读缓存):
```bash
    if ! blob="$(kit_meta_cached "$f" 2>/dev/null)"; then
      log_warn "Skipping $(basename "$f"): its 'meta' failed."
      continue
    fi
    ...
    if [[ "$(kit_status_value "$f")" == 1 ]]; then installed="yes"; else installed="no"; fi
```
并在 `cmd_list` 函数体**开头**(`local f blob ...` 之后)加一行并行预热(冷态补满缺失项,热态秒回):
```bash
  kit_cache_warm "$KIT_SCRIPTS_DIR"   # parallel meta+status; warm cache makes this near-instant
```

- [ ] **Step 2: `cmd_search` 走 meta 缓存**

`swkit:150` 当前 `blob="$("$f" meta 2>/dev/null)" || { ...; }` 改为:
```bash
    blob="$(kit_meta_cached "$f" 2>/dev/null)" || { log_warn "Skipping $(basename "$f"): its 'meta' failed."; continue; }
```
并在 `cmd_search` 开头(`local term_lc ...` 之后)加 `kit_meta_warm "$KIT_SCRIPTS_DIR"`(只需 meta)。

- [ ] **Step 3: `main` 加 warm / cache / --no-cache**

`swkit:188-199` 的 `main` 改为:
```bash
main() {
  # Global --no-cache: bypass the probe cache entirely (LLM/debugging).
  if [[ "${1:-}" == "--no-cache" ]]; then export KIT_NO_CACHE=1; shift; fi
  local first="${1:-}"
  case "$first" in
    ""|help|-h|--help) usage ;;
    list)   shift; cmd_list ;;
    search) shift; cmd_search "$@" ;;
    ui)     shift; ui_catalog "$KIT_SCRIPTS_DIR" ;;
    warm)   shift; kit_cache_warm "$KIT_SCRIPTS_DIR"; printf 'Catalog cache warmed.\n' ;;
    cache)
      shift
      case "${1:-}" in
        clear) kit_cache_clear; printf 'Catalog cache cleared.\n' ;;
        warm|"") kit_cache_warm "$KIT_SCRIPTS_DIR"; printf 'Catalog cache warmed.\n' ;;
        *) log_err "Usage: swkit cache [warm|clear]"; return 2 ;;
      esac
      ;;
    *)      cmd_run "$@" ;;
  esac
}
```

- [ ] **Step 4: usage 补两行**

在 `usage()` 的 Usage 块(`swkit:47-53`)`swkit search` 行后加:
```
  swkit warm                               Pre-probe every script into the cache (preload)
  swkit cache clear                        Clear the catalog cache
```

- [ ] **Step 5: 语法 + shellcheck**

Run:
```bash
bash -n swkit
shellcheck -x --source-path=SCRIPTDIR swkit
```
Expected: 零输出。

- [ ] **Step 6: 行为 + 提速验证**

Run:
```bash
swkit cache clear
echo "--- cold list ---"; time swkit list >/tmp/l1 2>/dev/null
echo "--- warm list ---"; time swkit list >/tmp/l2 2>/dev/null
diff <(grep -c . /tmp/l1) <(grep -c . /tmp/l2) && echo "ok: list stable cold vs warm"
grep -q 'git' /tmp/l2 && echo "ok: list has entries"
swkit --no-cache list >/dev/null 2>&1 && echo "ok: --no-cache list runs"
swkit warm >/dev/null 2>&1 && echo "ok: warm runs"
```
Expected: warm list 明显快于 cold(目标 <0.1s);两次 list 行数一致;`ok:` 行齐全。

- [ ] **Step 7: 提交**

```bash
git add swkit
git commit -m "perf(swkit): list/search 走缓存 + warm/cache/--no-cache"
```

---

## Task 4: `lib/ui.sh` 异步 catalog(stale-while-revalidate)

**Files:**
- Modify: `lib/ui.sh`(`ui_read_key` 280-320、`ui_catalog` 626-687、`_ui_catalog_collect` 701-739、`_ui_catalog_text` 742-758)

**Interfaces:**
- Consumes: `kit_meta_cached`/`kit_status_value`/`kit_status_age`/`kit_probe_status`/`kit_cache_invalidate`/`kit_meta_warm`/`KIT_STATUS_TTL`(Task 1)
- Produces(内部):`_ui_catalog_scan`(填 keys/names/cats/paths/inst)、三态 badge 渲染、后台重探 + 轮询收割

- [ ] **Step 1: `ui_read_key` 加可选超时**

`lib/ui.sh:280-283` 当前:
```bash
ui_read_key() {
  local c b1 b2 seq
  UI_KEY=""
  IFS= read -rsn1 c <&"$_UI_FD" 2>/dev/null || { UI_KEY="enter"; return 0; }
```
改为(首字节带可选超时;超时设 `UI_KEY=timeout`):
```bash
ui_read_key() {
  local c b1 b2 seq to="${1:-}"
  UI_KEY=""
  if [[ -n "$to" ]]; then
    IFS= read -rsn1 -t "$to" c <&"$_UI_FD" 2>/dev/null || { UI_KEY="timeout"; return 0; }
    [[ -z "$c" ]] && { UI_KEY="timeout"; return 0; }
  else
    IFS= read -rsn1 c <&"$_UI_FD" 2>/dev/null || { UI_KEY="enter"; return 0; }
  fi
```
(其余解码不变。注意:带超时读到的字节继续走原 case 解码。)

- [ ] **Step 2: 新 `_ui_catalog_scan`(取代 collect 的探测部分,走缓存 + 三态)**

在 `lib/ui.sh` 中新增(放在 `_ui_catalog_collect` 之前),填只含**可选项**的并行数组,`inst` 为 `1/0/-1`:
```bash
# Fill selectable-item arrays from cache: keys/names/cats/paths/inst (inst: 1 installed,
# 0 not, -1 unknown/probing). meta via kit_meta_cached (warmed in parallel first).
_ui_catalog_scan() {
  local dir="$1"; local -n _k="$2" _n="$3" _c="$4" _p="$5" _i="$6"
  _k=(); _n=(); _c=(); _p=(); _i=()
  kit_meta_warm "$dir"
  local f blob key name category v
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    [[ -x "$f" ]] || continue
    [[ "$(basename "$f")" == TEMPLATE.sh ]] && continue
    blob="$(kit_meta_cached "$f" 2>/dev/null)" || continue
    key="$(printf '%s\n' "$blob" | _ui_meta_field key)"; [[ -n "$key" ]] || continue
    name="$(printf '%s\n' "$blob" | _ui_meta_field name)"; [[ -n "$name" ]] || name="$key"
    category="$(printf '%s\n' "$blob" | _ui_meta_field category)"; [[ -n "$category" ]] || category="other"
    v="$(kit_status_value "$f")"
    case "$v" in 1) v=1 ;; 0) v=0 ;; *) v=-1 ;; esac
    _k+=("$key"); _n+=("$name"); _c+=("$category"); _p+=("$f"); _i+=("$v")
  done
  shopt -u nullglob
}
```

- [ ] **Step 3: 新 `_ui_catalog_build`(把可选数组 → 交错的 display 数组,含分类头)**

新增(替代 `_ui_catalog_collect` 里"按类别交错 + 造 label"那段;label 据 `inst` 出三态 badge):
```bash
# Build interleaved display arrays (KEYS empty = section header) from the selectable
# arrays. inst: 1 installed badge, 0 missing badge, -1 mid (probing) badge.
_ui_catalog_build() {
  local -n _sk="$1" _sn="$2" _sc="$3" _sp="$4" _si="$5"   # selectable in
  local -n _dk="$6" _dl="$7" _dp="$8"                      # display out
  _dk=(); _dl=(); _dp=()
  local -a cats=("${_KIT_UI_CAT_ORDER[@]}")
  local c seen e i lbl tag
  for c in "${_sc[@]}"; do
    seen=0; for e in "${cats[@]}"; do [[ "$e" == "$c" ]] && { seen=1; break; }; done
    (( seen )) || cats+=("$c")
  done
  local cat any
  for cat in "${cats[@]}"; do
    any=0
    for (( i=0; i<${#_sk[@]}; i++ )); do [[ "${_sc[$i]}" == "$cat" ]] && { any=1; break; }; done
    (( any )) || continue
    _dk+=(""); _dl+=("$(_ui_cat_label "$cat")"); _dp+=("")
    for (( i=0; i<${#_sk[@]}; i++ )); do
      [[ "${_sc[$i]}" == "$cat" ]] || continue
      case "${_si[$i]}" in
        1) tag="$(ui_badge installed)" ;;
        0) tag="$(ui_badge missing)" ;;
        *) tag="$(ui_badge mid)" ;;
      esac
      printf -v lbl '%s %-12s %s' "$tag" "${_sn[$i]}" "${UI_MUTED}$( [[ "${_si[$i]}" == 1 ]] && ui_t installed )${UI_OFF}"
      _dk+=("${_sk[$i]}"); _dl+=("$lbl"); _dp+=("${_sp[$i]}")
    done
  done
}
```

- [ ] **Step 4: 后台重探 + 轮询收割辅助**

新增:
```bash
# Spawn a single background reviser for the given script paths; it probes them in parallel
# and writes each .status. The UI polls the cache; we reap the wrapper opportunistically.
_UI_WARM_PID=""
_ui_spawn_probes() {
  (( $# == 0 )) && return 0
  # reap a finished previous reviser
  [[ -n "$_UI_WARM_PID" ]] && ! kill -0 "$_UI_WARM_PID" 2>/dev/null && { wait "$_UI_WARM_PID" 2>/dev/null || true; _UI_WARM_PID=""; }
  local paths=("$@")
  ( local p; for p in "${paths[@]}"; do kit_probe_status "$p" >/dev/null 2>&1 & done; wait ) &
  _UI_WARM_PID=$!
}
```

- [ ] **Step 5: 重写 `ui_catalog` 主体(异步循环)**

替换 `lib/ui.sh:626-687` 的 `ui_catalog` 为:
```bash
ui_catalog() {
  local dir="${1:-${KIT_SCRIPTS_DIR:-}}"
  _ui_ensure_style
  if [[ ! -d "$dir" ]]; then ui_notify "$(ui_t install_software)" "$(ui_t no_scripts)"; return 0; fi
  if ! ui_supported; then kit_have_tty || return 0; _ui_catalog_text "$dir"; return $?; fi

  local own=0
  if [[ "${_UI_ACTIVE:-0}" != 1 ]]; then ui_begin || { _ui_catalog_text "$dir"; return $?; }; own=1; fi

  local sel=0 rescan=1 n=0
  local -a sk=() sn=() sc=() sp=() si=()          # selectable
  local -a keys=() labels=() paths=()             # display (interleaved)
  local -a pending=()                              # paths awaiting fresh status
  while true; do
    if (( rescan )); then
      _ui_catalog_scan "$dir" sk sn sc sp si
      _ui_catalog_build sk sn sc sp si keys labels paths
      n=${#keys[@]}
      if (( n == 0 )); then ui_notify "$(ui_t install_software)" "$(ui_t no_scripts)"; break; fi
      (( sel >= n )) && sel=$(( n - 1 )); (( sel < 0 )) && sel=0
      [[ -n "${keys[$sel]}" ]] || _ui_catalog_step keys sel 1
      # which scripts need a (re)probe: unknown, or older than TTL
      pending=()
      local i
      for (( i=0; i<${#sp[@]}; i++ )); do
        if [[ "${si[$i]}" == -1 ]] || (( $(kit_status_age "${sp[$i]}") > KIT_STATUS_TTL )); then
          pending+=("${sp[$i]}")
        fi
      done
      _ui_spawn_probes "${pending[@]}"
      rescan=0
    fi

    [[ "${_UI_WINCH:-0}" == 1 ]] && { _UI_WINCH=0; ui_size; }
    local listrow=3 avail=$(( UI_ROWS - 3 - 1 )) top=0 i row
    (( avail < 1 )) && avail=1
    (( sel < top )) && top=$sel
    (( sel >= top + avail )) && top=$(( sel - avail + 1 ))
    printf '\033[2J' >&"$_UI_FD"
    ui_header "ubuntu-setup" "$(ui_t install_software)"
    row=$listrow
    for (( i=top; i<n && i<top+avail; i++ )); do
      if [[ -z "${keys[$i]}" ]]; then
        ui_move "$row" 2; printf '\033[K%s%s%s' "$UI_ACCENT$UI_BOLD" "${labels[$i]}" "$UI_OFF" >&"$_UI_FD"
      else
        ui_row "$row" "$i" "$sel" "${labels[$i]}"
      fi
      (( row++ ))
    done
    ui_footer "$(ui_t nav_catalog)"

    # Poll for input; on timeout, harvest any freshly-probed status and repaint.
    if (( ${#pending[@]} > 0 )); then ui_read_key 0.15; else ui_read_key; fi
    case "$UI_KEY" in
      timeout)
        local idx changed=0 newv
        local -a still=()
        for p in "${pending[@]}"; do
          newv="$(kit_status_value "$p")"
          if [[ -n "$newv" ]]; then
            # find this path in sp[] and update si[] if changed
            for (( idx=0; idx<${#sp[@]}; idx++ )); do
              [[ "${sp[$idx]}" == "$p" ]] || continue
              case "$newv" in 1) newv=1 ;; *) newv=0 ;; esac
              [[ "${si[$idx]}" != "$newv" ]] && { si[$idx]="$newv"; changed=1; }
              break
            done
          else
            still+=("$p")
          fi
        done
        pending=("${still[@]}")
        if (( changed )); then _ui_catalog_build sk sn sc sp si keys labels paths; fi
        ;;
      up|k)   _ui_catalog_step keys sel -1 ;;
      down|j) _ui_catalog_step keys sel 1 ;;
      home)   sel=0; [[ -z "${keys[0]}" ]] && _ui_catalog_step keys sel 1 ;;
      end)    sel=$(( n - 1 )) ;;
      r|R)    kit_cache_clear; rescan=1 ;;     # hard refresh
      enter|right|l)
        if [[ -n "${keys[$sel]}" ]]; then
          ui_end
          "${paths[$sel]}" ui || true
          kit_cache_invalidate "${paths[$sel]}"   # this script changed; re-probe on return
          ui_begin
          rescan=1
        fi
        ;;
      esc|backspace) break ;;
      q|Q) break ;;
    esac
  done
  [[ -n "$_UI_WARM_PID" ]] && { wait "$_UI_WARM_PID" 2>/dev/null || true; _UI_WARM_PID=""; }
  [[ $own == 1 ]] && ui_end
  return 0
}
```

- [ ] **Step 6: `_ui_catalog_collect` 复用新拆分(供 `_ui_catalog_text`/`swkit list-text` 兼容)**

把旧 `_ui_catalog_collect`(701-739)改为薄封装(保留签名,内部用新函数,走缓存):
```bash
_ui_catalog_collect() {
  local dir="$1"; local -n _keys="$2" _labels="$3" _paths="$4"
  local -a _sk=() _sn=() _sc=() _sp=() _si=()
  kit_cache_warm "$dir"                       # text/limited path is synchronous: fill fully
  _ui_catalog_scan "$dir" _sk _sn _sc _sp _si
  _ui_catalog_build _sk _sn _sc _sp _si _keys _labels _paths
}
```
(`_ui_catalog_text` 742-758 无需改:它调 `_ui_catalog_collect`,现在走缓存且 `kit_cache_warm` 同步补满。)

- [ ] **Step 7: 语法 + shellcheck**

Run:
```bash
bash -n lib/ui.sh
shellcheck -x --source-path=SCRIPTDIR lib/ui.sh swkit scripts/*.sh lib/common.sh lib/cache.sh bootstrap.sh
```
Expected: 零输出(`ui_catalog` 用到的 nameref 注意 SC2178/SC2034,必要时加 `# shellcheck disable=` 与现有风格一致)。

- [ ] **Step 8: 伪终端冒烟 + 计时**

Run:
```bash
# 渲染不崩、q 干净退出、终端复原
printf 'q' | TERM=xterm-256color script -qec 'swkit ui' /dev/null >/tmp/ui-smoke.log 2>&1; echo "exit=$?"
tail -3 /tmp/ui-smoke.log
# 热缓存计时(已 warm 过):catalog 首帧应瞬时
swkit warm >/dev/null 2>&1
printf 'q' | TERM=xterm-256color script -qec 'time swkit ui' /dev/null 2>&1 | grep -E 'real|exit' || true
```
Expected: `exit=0`,终端正常;无报错。

- [ ] **Step 9: 提交**

```bash
git add lib/ui.sh
git commit -m "perf(ui): ui_catalog stale-while-revalidate —— 缓存首帧+后台重探+三态 badge+r 硬刷新"
```

---

## Task 5: bootstrap 进 TUI 时后台预热

**Files:**
- Modify: `bootstrap.sh`(`run_tui` 524 起)

**Interfaces:**
- Consumes: `kit_cache_warm`(Task 1)、`kit_scripts_dir`(bootstrap 已有,434)

- [ ] **Step 1: 在 `run_tui` 入口后台预热**

在 `run_tui()` 函数体最开头(进入交互循环前)加:
```bash
  # Preload the catalog cache in the background so "Install software" is instant by the time
  # the user navigates to it. Best-effort, detached; never blocks or affects the TUI.
  kit_cache_warm "$(kit_scripts_dir)" >/dev/null 2>&1 &
```
(放在 `run_tui()` 的 `local ...`/首行之后、`while`/`ui_pick` 循环之前。)

- [ ] **Step 2: 语法 + 用法 + source 守卫**

Run:
```bash
bash -n bootstrap.sh
./bootstrap.sh --help >/dev/null && echo "ok: --help"
shellcheck -x --source-path=SCRIPTDIR bootstrap.sh
```
Expected: `ok: --help`,零 shellcheck 输出。

- [ ] **Step 3: 提交**

```bash
git add bootstrap.sh
git commit -m "perf(bootstrap): 进 TUI 时后台预热目录缓存(预加载)"
```

---

## Task 6: 文档(TEMPLATE + CLAUDE.md 防漂移)

**Files:**
- Modify: `scripts/TEMPLATE.sh`(`status` 注释)、`CLAUDE.md`(架构散文)

- [ ] **Step 1: TEMPLATE.sh 注释 `KIT_PROBE_ONLY` 约定**

在 `scripts/TEMPLATE.sh` 的 `status()` 上方注释补一段(贴合现有注释风格):
```bash
# status — exit 0 iff installed/effective. MUST be read-only (no writes/side effects): the
# catalog caches its boolean. For an EXPENSIVE status (spawns a runtime, scans many files),
# honor KIT_PROBE_ONLY: when it is set, determine the install boolean cheaply and return
# early, skipping version strings / tool enumeration. Both paths MUST return the same exit
# code. The cache/catalog sets KIT_PROBE_ONLY=1; a human `swkit <key> status` does not.
```

- [ ] **Step 2: CLAUDE.md 架构散文**

在 CLAUDE.md「真实交付物」清单里 `lib/ui.sh` 条目后,新增 `lib/cache.sh` 条目;并在 `lib/ui.sh` 的 `ui_catalog` 描述补「stale-while-revalidate(缓存首帧 + 后台重探 + 三态 badge + `r` 硬刷新)」;在 `swkit` 条目补 `warm`/`cache clear`/`--no-cache`;在 bootstrap 描述补「进 TUI 后台预热」;在「编写契约」补 `KIT_PROBE_ONLY` 约定与防漂移点(约定同时落在 `lib/cache.sh`/`TEMPLATE.sh`/本文件——改一处必查其余)。具体插入:

`lib/ui.sh——` 条目后加:
```
- `lib/cache.sh`——共享库,**目录探测缓存即代码**(性能契约):`meta` 按脚本文件 mtime 永久缓存、`status` 安装布尔缓存 + 精准失效(`kit_meta_cached`/`kit_status_value`/`kit_probe_status`/`kit_cache_invalidate`/`kit_cache_warm`/`kit_cache_clear`);被 `common.sh` 在 source `ui.sh` 前 source,故 `ui_catalog`/`swkit list,search`/`bootstrap` 共享。陈旧只影响**显示**不影响**行为**(真实 op 永远跑脚本本体、其 status 闸门现场复检)。认 `SUDO_USER` 解析真实 home、用户态、`KIT_NO_CACHE=1` 完全旁路。
```
并在领域约束新增一条不可妥协项:
```
- **⑥目录加载零卡顿(缓存即 UI)**:`ui_catalog` 用 stale-while-revalidate——`_ui_catalog_scan` 从 `lib/cache.sh` 缓存瞬时首帧渲染,后台并行 `kit_probe_status` 重探,`ui_read_key` 超时轮询收割、`status` 到达即重绘(三态 badge:已装/未装/探测中);`r` 硬刷新、返回子界面后精准失效该脚本。重型 `status` 经 **`KIT_PROBE_ONLY`** 约定(cache 探测时设)只算安装布尔、跳过昂贵详情,两条路径退出码一致。预加载:bootstrap 进 TUI 后台 `kit_cache_warm`、`swkit warm` 显式预热、磁盘缓存跨调用复用。此约定同时落在 `lib/cache.sh`/`lib/ui.sh`/`scripts/TEMPLATE.sh`/本文件——改一处必查其余。
```

- [ ] **Step 3: 校验全量静态**

Run:
```bash
for f in bootstrap.sh lib/*.sh swkit scripts/*.sh; do bash -n "$f"; done
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/ui.sh lib/cache.sh bootstrap.sh
echo "all clean"
```
Expected: `all clean`,零告警。

- [ ] **Step 4: 提交**

```bash
git add scripts/TEMPLATE.sh CLAUDE.md
git commit -m "docs: 记录 lib/cache.sh / 异步 catalog / KIT_PROBE_ONLY 约定 / 预加载(防漂移)"
```

---

## Task 7(可选,次要):惰性 source `ui.sh`

> 仅在 Task 1-6 落地且验证稳定后评估。收益(meta/status fork 基础成本减半)在缓存+异步落地后已变小,且触达每个消费方。若收益不抵风险则**不做**。

**Files:** `lib/common.sh`、`lib/ui.sh`(load guard)、`swkit`/`bootstrap.sh`/`kit_dispatch` 的 ui 入口

- [ ] **Step 1:** `common.sh` 改为不无条件 source `ui.sh`,加 `kit_load_ui`(幂等 source);在 `kit_dispatch` 的 `ui` 分支、`ui_default_menu`、`swkit ui`、`bootstrap` TUI 入口调用。
- [ ] **Step 2:** 全量 `bash -n` + `shellcheck -x` + 每脚本 `meta`/`status`/`ui`(无 TTY 退 0)契约 + 伪终端冒烟。
- [ ] **Step 3:** 计时对比确认 meta/status fork 变快;提交或回退。

---

## Self-Review(对照 spec)

- **spec §3 三层模型** → Task 1(meta mtime 缓存、status 布尔缓存)。✓
- **spec §3 安全论证** → Global Constraints + Task 6 文档。✓
- **spec §4 lib/cache.sh API** → Task 1 全量实现 + 断言。✓
- **spec §5 事件循环(超时轮询/三态/r/返回失效)** → Task 4。✓
- **spec §5.3 受限/无 TTY 回退** → Task 4 Step 6(`_ui_catalog_collect` 同步 warm)+ `_ui_catalog_text` 不变。✓
- **spec §6 预加载(磁盘持久/bootstrap 后台/swkit warm)** → Task 1(warm)+ Task 3(swkit warm)+ Task 5(bootstrap)。✓
- **spec §7 swkit list/search/warm/cache/--no-cache** → Task 3。✓
- **spec §8 重型 status 瘦身(7 脚本 + KIT_PROBE_ONLY)** → Task 2。✓
- **spec §9 惰性 ui.sh(可选)** → Task 7(标可选)。✓
- **spec §10 触达文件** → 各任务文件覆盖齐(含 TEMPLATE/CLAUDE.md)。✓
- **spec §11 验证(静态/契约/缓存正确性/异步冒烟/计时)** → 各任务 Step 含;缓存正确性在 Task 1 断言。✓
- **Placeholder 扫描**:无 TBD/TODO;每改动给出 before/after 或完整函数。✓
- **类型/命名一致**:`kit_status_value`(非 `kit_status_cached`,统一用 value 版)、`KIT_PROBE_ONLY`、`KIT_NO_CACHE`、`KIT_STATUS_TTL`、`_ui_catalog_scan`/`_ui_catalog_build`/`_ui_spawn_probes` 全计划一致。✓
  - 注:计划用 `kit_status_value` 取代 spec §4.2 的 `kit_status_cached`(打印纯值更简洁);spec §4.1 的单文件细化为 `.meta`+`.status` 两文件(写隔离,避免 meta/status 同键并发改写)。两处为实现细化,语义不变。
