# 交集调研：实跑多源交集定稿首发清单

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)（画像/标准/兜底规则等全部决策见父 prd）。

## Goal

把入选标准方案 A 从纸面跑成数据：采集 5 核心源 + 3 辅助源的快照，机械计票，
产出可溯源、带完整标注的首发清单定稿。

## Requirements

* 每个源产出机器可读快照（JSON：canonical 工具名 + 别名 + 证据/指标 + 来源 URL）落盘 `research/sources/`。
* 计票脚本（可重跑）：方案 A 规则——≥3 票且核心票 ≥2，辅助源（JetBrains/popcon/awesome 合并）至多补 1 票。
* 三条兜底：bedrock 白名单评审稿、依赖引证自动票、类别空洞复查（每个空类别显式记录原因）。
* 定稿清单每条标注：命中源、官方推荐安装方式 + 官方文档 URL、所需 provider 类型、
  requires 适用条件（desktop 等）、容器可验 / 须 VM 验、领域分组归属。
* 副产物：缺口 provider 清单（驱动 provider-* 子任务开题）、领域分文件方案定稿。

## Acceptance Criteria

* [x] `research/sources/*.json` 快照齐全（8/8 源，无缺失）。
* [x] 计票脚本重跑可复现同一结果（`tally.py`，禁并对拦截 24 次误合并）；N 值维持方案 A，理由见 `research/conclusion.md` §1。
* [x] 定稿清单（`research/final-list.md` + `final-list.json`）110 条逐条标注齐全、可溯源。
* [x] 类别空洞复查记录在案（conclusion.md §2c）；bedrock 白名单评审稿单独成节（§2b，待用户 PR 评审）。

## 交付物索引

* [`research/conclusion.md`](research/conclusion.md) — 结论：110 条入选 +4 依赖引证 −1 合并；provider 缺口 deb 21/script 14/snap 6/ppa 4；container 95/VM 15。
* [`research/final-list.md`](research/final-list.md) / `final-list.json` — 定稿清单（按类别分组，含官方装法溯源）。
* [`research/tally.md`](research/tally.md) / `tally.json` — 计票结果与 134 条观察区。
* `research/sources/` — 8 源快照；`tally.py` / `assemble.py` — 可重跑管线。

## Out of Scope

* 条目 YAML 落地、schema/provider/验证基建改动（归其他子任务）。
