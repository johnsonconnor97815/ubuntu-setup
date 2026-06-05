# Align CLAUDE.md to manager product shape

## Goal

把 `CLAUDE.md`(给 Claude Code 的项目指令)与 `.trellis/spec/` 已锁定的设计对齐,
消除「章程漂移」:当前 CLAUDE.md 把项目写成**一次性安装/配置工具**,而 spec 已锁定为
**持续软件管理器(装/卸/升级/查看)+ 自动记录可导出清单(兼 provisioner)**的开源产品。
同时,CLAUDE.md「当前状态」称"尚无源代码、无法描述架构",但 `.trellis/spec/` 整套蓝图
已就绪,应改为指向 spec,而非声称无从描述。

## What I already know

- spec 源头已落地:`spec/index.md`(项目是什么 + 7 条不可妥协项)、`spec/design-direction.md`
  (锁定决策与 why)、`core/ tui/ catalog/ guides/` 各层规范。
- `design-direction.md` 自己在「待办/风险」里记着:*"CLAUDE.md 写的是一次性 provisioner,
  用户要 manager → 需回写 CLAUDE.md"*。
- `spec/index.md` 明确分工:"Project goals and constraints live in `CLAUDE.md`;
  the locked design decisions these specs encode live in design-direction.md"。
  → CLAUDE.md 管**目标 + 领域约束**,不该重复 spec 的细节实现规则。
- CLAUDE.md 当前三处漂移:
  1. L5-7「项目目标」缺 manager / 可导出清单 / 开源产品定位。
  2. L9-16「当前状态」声称无源码、无法描述架构(应指向已就绪的 spec)。
  3. L18-23「领域约束」只有 Ubuntu-fresh + 幂等两条,缺安全一等约束。

## Requirements (evolving)

- [R1] 「项目目标」对齐为:开源、面向全新 Ubuntu(含 Server/SSH/无桌面)的**持续软件管理器**
  (装/卸/升级/查看)+ 即时操作自动记录为**可导出清单**(清单重放新机 = provisioner);
  Python 大脑 + bash/subprocess 手。
- [R2] 「当前状态」改为:产品源码尚未开始,但设计蓝图已锁定于 `.trellis/spec/`;
  把原先"待补充"的入口/清单组织/职责边界,改为指向 spec 对应文档(而非声称无从描述)。
- [R3] 「领域约束」**全面对齐**(Q1=B):在保留(刚装好的 Ubuntu、幂等)基础上,把
  `spec/index.md` 的 7 条不可妥协项浓缩进领域约束——
  ①脑/脸分离(import textual 或含安装逻辑,二选一);②`check()` 为幂等引擎(查活系统,非状态账本);
  ③绝不整体 root,逐命令 sudo(`SUDO_USER` 解析用户路径);④plan-before-apply + fail-fast,重跑续装无回滚;
  ⑤单一 subprocess 边界(全走 `core/runner.py`);⑥类型分发只在 provider 注册表;
  ⑦catalog 是数据非代码(LLM 后置,只生成声明式条目)。每条精炼为一行,细节指向对应 spec。
- [R4] CLAUDE.md 保持精简、指向 spec,不复制 spec 全文(避免双写漂移);浓缩 7 条时
  每条一行 + 指向 `spec/` 对应文档,而非整段照搬。

## Open Questions

- ~~Q1 领域约束回写力度~~ → **已定:B 全面对齐**(见 Decision)。

## Acceptance Criteria (evolving)

- [ ] CLAUDE.md「项目目标」包含"持续管理器"与"可导出清单/provisioner"表述。
- [ ] CLAUDE.md「当前状态」指向 `.trellis/spec/`,不再声称"无法描述架构"。
- [ ] CLAUDE.md 与 `spec/design-direction.md`、`spec/index.md` 无矛盾表述。
- [ ] `design-direction.md`「待办/风险」中该条漂移可视为已解决(回写后在 journal 记录)。
- [ ] CLAUDE.md 仍精简,未把 spec 实现细节搬入。

## Definition of Done

- 改动仅限 `CLAUDE.md`(纯文档,无代码)。
- 与 spec 交叉核对无矛盾。
- journal 记录本次回写。

## Out of Scope

- 不动 `.trellis/spec/` 任何文件(spec 是真相源,本任务向它对齐)。
- 不写任何产品源码。
- 不引入新的设计决策(只搬运 spec 已锁定的结论)。

## Decision (ADR-lite)

- **Context**:CLAUDE.md 与 spec 存在章程漂移(一次性工具 vs 持续 manager),
  且自称"无法描述架构"而 spec 已就绪。需让 CLAUDE.md 向 spec 对齐。
- **Decision**:全面对齐(Q1=B)——产品形态改为持续 manager + 可导出清单;
  当前状态指向 `.trellis/spec/`;领域约束浓缩 spec 7 条不可妥协项(每条一行 + 指向 spec)。
- **Consequences**:CLAUDE.md 信息更全、与 spec 一致;代价是与 spec 有一定表述重复——
  以"每条一行、细节指向 spec"控制重复,避免未来双写漂移。spec 仍是唯一真相源。

## Technical Notes

- 真相源优先级:`spec/design-direction.md`(锁定决策)> `spec/index.md`(不可妥协项)
  > CLAUDE.md(目标/约束摘要)。本任务让 CLAUDE.md 向前两者对齐。
- 语言:CLAUDE.md 现为中文,保持中文。
- 文件:`/home/conn/workspace/ubuntu-setup/CLAUDE.md`(24 行)。
