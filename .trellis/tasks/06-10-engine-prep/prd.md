# 引擎准备：requires 适用条件 + planner 拓扑排序

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)（决策背景见父 prd 与
[`../06-10-intersection-research/research/conclusion.md`](../06-10-intersection-research/research/conclusion.md)）。

## Goal

为 113 条首发条目落地扫清两个引擎前置：
1. **requires 适用条件**：GUI 条目在无桌面机器上 browse 自动隐藏、plan/apply 自动跳过（首发 110 条中 GUI 约 30+ 条）。
2. **planner depends_on 拓扑排序**：repo 条目（deb/ppa）→ package 条目的依赖链是 21 条 deb + 4 条 ppa 的硬前置。

## Requirements

### A. requires 适用条件（schema + 脑层 + 脸层）

* schema（`catalog/schema.json`）：新增可选字段 `requires`，字符串数组，元素枚举暂仅 `"desktop"`（为未来 arch 等条件留扩展）；`CatalogEntry`（`core/models.py`）加 `requires: list[str]`，默认 `[]`。
* 环境探测（脑层，新模块如 `core/environment.py`）：`detect_capabilities() -> frozenset[str]`，启动时探测一次。
  **desktop 判定 = 机器装有桌面栈**（而非当前会话是否图形）：`DISPLAY`/`WAYLAND_DISPLAY` 任一存在，或 `systemctl get-default` 为 `graphical.target`，或 `/usr/share/xsessions`、`/usr/share/wayland-sessions` 非空——任一命中即有 desktop。理由：SSH 进桌面机也该能装 GUI 软件；探测走 runner/纯文件检查，不引入新依赖。
* service：scan/browse 数据源按 `entry.requires ⊆ capabilities` 过滤（不满足的条目对 TUI 不可见）；plan/apply 路径同判定自动跳过并产生显式事件/原因（不静默吞掉——清单重放在无桌面机器上要可见地 skip 而非报错）。
* TUI：browse 列表消费过滤结果即可，不在脸层重复判定（不可妥协①：判定逻辑全在 core）。

### B. planner 拓扑排序

* `core/planner.py`：依 `depends_on` 做闭包扩展（选了 docker 自动带上 docker 的 repo 条目）+ 确定性拓扑排序（尽量保持输入顺序的稳定排序）。
* 环依赖 → `CatalogError`（载入期或计划期报出，带环路径）。
* 与 requires 跳过的交互：被跳过条目的依赖者如何处置——依赖链上有 skip 则依赖者同跳（带原因），不 fail。

## Acceptance Criteria

* [ ] schema 校验：非法 requires 值被 loader 拒绝（CatalogError）；旧条目（无 requires）不受影响。
* [ ] 单测：desktop 探测在注入环境下三条判定路径各自可触发；无桌面环境 GUI 条目 scan 不可见、apply 显式 skip。
* [ ] 单测：拓扑排序——repo→package 正序、闭包自动带依赖、环报错、稳定顺序。
* [ ] 依赖链 skip 传播有测试覆盖。
* [ ] `python -m unittest discover -s tests` 全绿；ruff 无新告警。
* [ ] spec 回写（catalog-and-providers / idempotency-and-execution / authoring-guidelines 相应小节）。

## Out of Scope

* 新 provider 实现（deb/ppa/script/snap 归 provider-* 子任务）。
* 条目 YAML 落地、验证基建。
* requires 的更多条件种类（arch、ubuntu 版本等）——只留扩展点不实现。

## Technical Notes

* 仓库现状（已侦察）：schema 必填 id/description/type，可选 depends_on/tags/source/version/hold；
  loader 四道关在 `core/catalog.py`；planner 目前只保留列表顺序；service.scan 是 TUI browse 数据源。
* depends_on 引用校验已存在（loader 第四道关），拓扑只需排序+闭包，不需重做校验。
* GUI 条目清单与 requires 标注来源：`../06-10-intersection-research/research/final-list.json`。
