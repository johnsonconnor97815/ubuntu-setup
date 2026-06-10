# 引擎最薄垂直切片:runner + models + apt provider + headless apply

## Goal

在零产品代码的仓库上,落地**第一条端到端可运行的脑/手路径**:从一个声明式 catalog 条目出发,经 headless 入口规划并真实地用 `apt` 装上一个包,再把这次操作写入可导出 manifest。目的不是功能完整,而是**尽早打通 `core/runner.py`(单一 subprocess 边界)→ provider 协议 → check→apply 引擎 → manifest** 这条主干,把架构风险(脑/手/脸边界、sudo、幂等)前置验证;后续 provider 类型、生命周期动作、TUI 都在此骨架上增量叠加。

## What I already know(spec 已钉死,无需讨论)

来源:`.trellis/spec/core/{directory-structure,error-and-logging,idempotency-and-execution,catalog-and-providers,privilege-and-safety}.md`、`catalog/authoring-guidelines.md`。

- **包布局**:顶层包 `ubuntu_setup/`,`core/`(脑)、`catalog/`(数据)、`cli.py` + `__main__.py`(`python -m ubuntu_setup`)。`core/` 绝不 import `tui/`/`textual`。
- **runner 契约**(`core/runner.py`,唯一 subprocess 边界):argv 列表 + `shell=False`;默认 env 强制 `DEBIAN_FRONTEND=noninteractive`、`DEBIAN_PRIORITY=critical`、`LC_ALL=C`/`LANG=C`;特权变体前缀 `sudo` 并在 sudo 内重申 `DEBIAN_FRONTEND`;捕获 stdout/stderr + timeout,返回 `(returncode, stdout, stderr, duration)` 小结果对象;运行前记录精确 argv(审计);决策只 branch on returncode,要读输出时读机器格式字段。
- **数据模型**(`core/models.py`,纯 dataclass):`CatalogEntry`、`Action(entry, op, predicted_state_change)`、`Plan`(Action 列表,无副作用)、`StepResult`、`Manifest`。
- **catalog schema**:YAML,加载时逐条对 `catalog/schema.json` 校验。通用字段 `id`/`description`/`type`/`depends_on`(默认 `[]`)/`tags`(默认 `[]`)/`source`(默认 `community`)。`apt` 类型必填 `package`,可选 `version`/`hold`。
- **provider 协议**(`core/providers/base.py`):`State` 枚举 `ABSENT`/`PRESENT`/`OUTDATED`;`check(entry)->State`(查活系统、零变更、不需要 ctx)、`install/remove/upgrade(entry, ctx)`(幂等)。注册表 `core/providers/__init__.py` 是唯一按 `entry.type` 分发处。
- **apt idiom**:check = `dpkg-query -W -f='${Status}' <pkg>` 且输出等于 `install ok installed`(否则 ABSENT;区分「未装」与「check 命令出错」);install = `apt-get install -y --no-install-recommends <pkg>` + `-o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"`。用 `apt-get` 不用 `apt`。
- **执行模型**:executor 遍历有序 Plan,每步先 `check()`→已就位则跳过(`ok`)→否则经 provider apply(`changed`);fail-fast(首个 `ProviderError` 即停);per-entry outcome ∈ `changed`/`ok`/`skipped`/`failed`。**无回滚**。
- **manifest 格式**:JSON,`~/.local/state/ubuntu-setup/manifest.json`(经 `real_home()` 解析,绝不 `/root`);`{version, desired:[{id,op}], history:[{run_id,started_at,exit_code,actions:[{id,op,outcome}]}]}`;manifest 只引用 catalog id,绝不复制安装逻辑,绝不用于判断「当前是否已装」。
- **exit codes**:0 全 ok/changed;1 失败步停(ProviderError);2 用法/catalog/manifest 非法(CatalogError);3 中断(UserAbort);4 提权不可用(PrivilegeError)。`PreconditionError` 不是终止码,只跳过单条。
- **错误分类**(`core/errors.py`):`CatalogError`/`ProviderError`/`PrivilegeError`/`PreconditionError`/`UserAbort`。脑只抛类型化错误,cli 边界翻译成消息 + exit code。
- **privilege**(`core/privilege.py`):`sudo -v` 前置 + keepalive daemon 线程;`real_user()` 从 `SUDO_USER`、`real_home()` 从 passwd DB(绝不 `~`/`$HOME`/`expanduser`);apt 经 runner 特权变体逐命令提权,绝不整体 root。
- **依赖**:Python ≥ 3.9;`pyyaml`、`jsonschema`(本切片不需 `textual`)。
- **测试**:`tests/` 镜像包路径;runner 是唯一 subprocess 边界 → 可注入假 runner,对 check/install/executor 做无 root 单测。

## Requirements (locked)

- `pyproject.toml`(deps:`pyyaml`、`jsonschema`;Python ≥ 3.9)+ `ubuntu_setup/` 包骨架(`__init__`/`__main__`/`cli`)。
- `core/runner.py`:默认变体 + 特权(sudo)变体,按 spec 契约(argv/`shell=False`/非交互 env/`LC_ALL=C`/捕获+timeout/记 argv)。
- `core/models.py`:`CatalogEntry`/`Action`/`Plan`/`StepResult`/`Manifest` 五个 dataclass。
- `core/errors.py`:`CatalogError`/`ProviderError`/`PrivilegeError`/`PreconditionError`/`UserAbort`。
- `catalog/schema.json` + `core/catalog.py`(加载 + 逐条校验 YAML→models),含至少一个 `apt` 示例条目。
- `core/providers/{__init__(注册表), base(协议+State), apt}.py`:apt **check + install**;`remove`/`upgrade` 占位(NotImplementedError)。
- `core/privilege.py`:`real_user`/`real_home` + 前置 `sudo -v`;**无 keepalive 线程**(决策①)。
- `core/planner.py`:desired 列表 → 顺序 `Action`,**无 depends_on/拓扑**(决策①)。
- `core/executor.py`:遍历 Plan,`check()`→skip(`ok`)/apply(`changed`),fail-fast(`ProviderError`→exit 1);honor `ctx.check_mode`(决策③)。
- `core/state.py`:manifest 读 + 写(`--install` 更新 `desired`;两入口都追加 history 事务)。
- `cli.py`:`--apply <manifest>`、`--install <id>`、`--dry-run`(决策②③)+ 异常→exit code 翻译。
- 测试:假 runner 单测覆盖 runner / apt.check / executor(skip/changed/failed)/ catalog 校验 / manifest;+ 默认跳过的真实装包 smoke(决策④)。

## Decision (ADR-lite)

**Context**:这是零代码仓库的第一条端到端切片,目标是「最薄但能真装一个 apt 包」。需在「贴 spec 全量」与「最小可运行」间取舍,且不破坏后续 additive 增长。

**Decision**(4 项,均与 spec 协议签名兼容,后续叠加为 additive 改动):

1. **切片厚度 = 砍到最薄**。planner 不做 `depends_on` 闭包 / 拓扑排序——按 desired 列表顺序逐条映射成 `Action`;privilege 只做 `real_user`/`real_home` + 前置 `sudo -v`,**不**起 keepalive 线程(单包够用);apt provider **只实现 check + install**,`remove`/`upgrade` 暂以 `NotImplementedError`/`ProviderError` 占位(协议四方法签名仍按 `base.py` 保留)。
2. **入口 = `--apply <manifest>` + `--install <id>` 都做**。`--apply` 是 spec 主路径(从 manifest 的 `desired` 规划重放);`--install <id>` 让切片自给自足——直接对单个 catalog id 规划+执行,并更新 manifest 的 `desired` + 追加 history,无需手写 manifest 即可演示。
3. **实现 `--dry-run`**(可与 `--apply`/`--install` 组合)。置 `ctx.check_mode=True`,executor 走 `check()` 打印 Plan(would-install / would-skip)且**零变更**;apt.install 必须 honor `check_mode`。这验证了 spec 头号信任特性 plan-before-apply 与 check() 预测路径。
4. **测试 = 假 runner 单测为主 + 可选 smoke**。单测注入 fake runner,无 root 覆盖 runner / apt.check / executor(skip/changed/failed)/ catalog 校验 / manifest 读写;另加一个真实装包 smoke,用 pytest marker 标记、**默认跳过**(需 sudo+apt 时显式开启)。

**Consequences**:本切片不证明多条目依赖图与长跑 keepalive;executor 因 `--dry-run` 仍需 `check_mode` 守卫(非「无 plan-mode」)。remove/upgrade、拓扑排序、keepalive、其余 provider 类型在后续任务按 additive 叠加,协议不变。

## Acceptance Criteria (locked)

- [ ] `python -m ubuntu_setup --install <id>` 能把一个未安装的 apt 包真实装上,退出码 0;包已装时重跑为 no-op(outcome `ok`)、退出码 0。
- [ ] `python -m ubuntu_setup --apply <manifest>` 从 manifest 的 `desired` 规划并安装,退出码语义同上。
- [ ] `--dry-run`(与 `--apply`/`--install` 组合)打印 Plan(would-install / would-skip)且对系统**零变更**。
- [ ] 失败步触发 fail-fast,退出码 1,报出条目 id + stderr 尾部。
- [ ] catalog/manifest 非法时退出码 2;非 sudoer 时退出码 4。
- [ ] `--install` 更新 manifest 的 `desired`;两入口均追加一条 history 事务(run_id/started_at/exit_code/actions+outcome)。
- [ ] 所有外部命令都经 `core/runner.py`(无散落 subprocess);`core/` 不 import textual;类型分发只在 `providers/__init__.py`。
- [ ] 假 runner 单测覆盖 runner / apt.check / executor(skip/changed/failed)/ catalog 校验 / manifest;真实 smoke 默认跳过;lint+typecheck 绿。

## Definition of Done

- 单测通过;lint/typecheck 绿。
- 不可妥协项 ①⑤⑥ 在代码层面可验证(脑/脸分离、单一 subprocess 边界、类型分发只在注册表)。
- prd 的 Acceptance Criteria 全勾。

## Out of Scope(显式;均后续 additive 叠加)

- TUI(Textual)及任何交互界面。
- 其余 provider 类型(ppa/deb/snap/flatpak/dotfile-block/service/script)。
- apt 的 `remove`/`upgrade`(本切片占位);版本钉选(`version`)与 `hold`。
- `depends_on` 闭包 + 拓扑排序(planner 本切片仅顺序映射)。
- privilege keepalive daemon 线程、`sudo -n` 每步探针的完整形态。
- `apt-get update` 缓存刷新策略的完整实现(本切片先无条件刷一次或假定缓存可用)。
- LLM 阶段。

## Technical Notes

- 关键 spec:`core/directory-structure.md`(布局/边界)、`core/error-and-logging.md`(runner/errors/日志)、`core/idempotency-and-execution.md`(plan/executor/manifest/exit codes)、`core/catalog-and-providers.md`(provider 协议 + apt idiom)、`core/privilege-and-safety.md`(sudo/real_user)、`catalog/authoring-guidelines.md`(字段表)。
- 测试可行性:runner 单一边界 → 注入 fake 即可无 root 验证 check/install/executor。
- 增量友好:本切片保持协议签名(State/ctx/Provider)与 spec 一致,后续类型与动作是 additive 改动。
</content>
</invoke>
