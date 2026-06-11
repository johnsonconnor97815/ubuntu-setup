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

* [ ] `research/sources/*.json` 快照齐全（8 源或显式记录某源不可得的原因）。
* [ ] 计票脚本重跑可复现同一结果；N 值若调整有书面理由。
* [ ] 定稿清单（`research/final-list.md` + 机器可读 JSON）逐条标注齐全、可溯源。
* [ ] 类别空洞复查记录在案；bedrock 白名单单独成节供评审。

## Out of Scope

* 条目 YAML 落地、schema/provider/验证基建改动（归其他子任务）。
