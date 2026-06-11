# 验证基建：容器/VM 真装集成测试

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)。占位 prd——启动本任务时细化。

## Goal

干净 Ubuntu 24.04 镜像里自动化真装验证每条 catalog 条目：check 幂等、install 成功、
重跑不重装；建成可持续回归网。先拿现有 2 条 apt 条目打通管线。

## 备注

* 选型（容器 vs VM、LXD/multipass/docker）启动时调研定；systemd/snap 类条目容器受限须 VM。
* 可与交集调研、引擎准备并行。
* 启动时按 brainstorm/research 流程补全 prd 与 jsonl。
