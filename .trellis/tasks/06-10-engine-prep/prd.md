# 引擎准备：requires 适用条件 + planner 拓扑排序

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)。占位 prd——启动本任务时细化。

## Goal

* schema 新增声明式适用条件字段（如 `requires: [desktop]`）：脑层探测环境一次，
  browse 静态隐藏、plan/apply 自动跳过；schema 变更回写 spec。
* planner 落地 depends_on 闭包扩展与拓扑排序（第三方源 repo→package 依赖链前置）。

## 备注

* 可与交集调研并行；provider-* 子任务依赖本任务的拓扑排序。
* 启动时按 brainstorm/research 流程补全 prd 与 jsonl。
