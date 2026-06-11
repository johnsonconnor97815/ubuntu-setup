# catalog-launch-essentials：首发 catalog 装机常用软件

## Goal

为开源首发准备默认 catalog：通过可溯源的多源交集调研选出「通用开发者工作站」必备软件，
落地为声明式条目，补齐所需 provider 能力，并以容器/VM 自动化真装验证背书——
一气呵成做到「首发可用」。

## Requirements

* **调研定稿**：写脚本实跑多源交集（方案 A），产出带溯源的入选清单——每条标注：命中源、
  官方推荐安装方式 + 官方文档 URL、所需 provider 类型、requires 适用条件、
  容器可验 / 须 VM 验、领域分组归属。
* **入选标准（方案 A，已拍板）**：5 核心源（SO Survey 2025、Homebrew install-on-request 365d、
  Flathub stats、Ubuntu 装机策展聚合票、Arch pkgstats），入选需 ≥3 票且核心票 ≥2，
  辅助源（JetBrains / popcon by_vote / awesome 合并票）至多补 1 票；
  三条兜底规则：bedrock 白名单、依赖引证自动票、类别空洞复查；实跑后可校准 N 并记录理由。
* **schema 环境感知**：新增声明式适用条件字段（如 `requires: [desktop]`）——脑层探测环境一次，
  browse 静态隐藏、plan/apply 自动跳过；schema 变更回写 spec；为未来条件（arch 等）留扩展。
* **planner 补强**：depends_on 闭包扩展与拓扑排序落地（第三方源 repo→package 依赖链的前置）。
* **缺口 provider 补齐**：按定稿清单的安装方式分布逐个实现（预计：deb/第三方 apt 源、script，
  可能 snap）；官方 curl-script 安装走 `script` 类型（手写幂等 check），符合 spec
  「能 provider 表达就不 curl|bash」约束。
* **条目落地**：全部入选条目写为声明式 YAML，按领域分文件（bedrock / dev-toolchain /
  containers / terminal / editors / gui-apps 等，实跑分布后定稿）+ tags 过滤；
  每条带 `source` 信任标记与安装方式溯源注释。
* **验证基建**：容器/VM 集成测试——干净 Ubuntu 24.04 镜像真装每条，验 check 幂等、
  install 成功、重跑不重装；建成可持续回归网。

## Acceptance Criteria

* [ ] 交集脚本可重跑，源数据快照与计票结果落盘 research/，入选判定机械可执行。
* [ ] 每条入选条目可溯源（命中源 + 官方安装方式出处 URL）。
* [ ] schema `requires` 字段：无桌面环境下 GUI 条目在 browse 隐藏、plan/apply 跳过（含测试）。
* [ ] planner 拓扑排序：repo 条目先于依赖它的 package 条目执行（含测试）。
* [ ] 所有条目在干净 24.04 上自动化真装通过：check 幂等、install 成功、重跑不重装。
* [ ] 不可妥协项①-⑦全部保持（尤其⑥类型分发只在注册表、⑦catalog 是数据）。

## Definition of Done

* Tests added/updated（unit + 容器/VM 集成）
* Lint / typecheck 绿
* spec 随码 reconcile（schema/provider/planner 变更回写 .trellis/spec/）
* 文档更新（README catalog 部分若有）

## Technical Approach

调研先行 → 看安装方式分布 → 引擎准备（schema requires + planner topo）与验证基建并行
→ 按 provider 分批落地条目，每批独立可验收。
provider/entries 子任务的确切数量在调研定稿后再开（数量取决于分布）。

## Decision (ADR-lite)

**Context**：首发默认 catalog 要经得起陌生开发者检视；引擎当前只有 apt provider、
schema 无环境字段、planner 无拓扑排序、无集成测试基建。

**Decision**（grillme 访谈 + brainstorm 收口，2026-06-10）：
- 画像=通用开发者工作站；定位=首发默认 catalog；调研倒逼引擎；一气呵成到首发可用。
- 入选标准=方案 A 多源交集（5 核心源 N≥3 且核心票 ≥2 + 三条兜底）；规模不预设上限。
- GUI=收录 + schema 新增 `requires` 适用条件字段（静态隐藏/跳过）。
- 安装方式=信官方、不过度设防；curl-script 走 script 类型，逐条标注官方溯源（纯文档纪律）。
- 验收=容器/VM 自动化真装；版本矩阵=仅 24.04 LTS。

**Consequences**：跨多子任务的大工程、工期由清单分布决定；遥测源偏置由兜底规则缓解；
「信官方」可能被安全敏感用户挑战——以逐条溯源标注回应；容器验不了的条目须 VM，
基建选型在验证子任务内决定。

**追加决策（2026-06-10，调研定稿后用户裁决）**：
- bedrock 评审稿 5 条全部批准：build-essential（合并 gcc+make）、zip、xz-utils、
  openssh-server、python3-venv+pip——随 apt 批次落地，溯源标 bedrock。
- thunderbird 改走官方 snap（官方顺序第二位）；flatpak provider 记 backlog，首发不建。
- yarn 落地为独立 script 条目（corepack enable，depends_on nodejs）。
- 最终分布：apt ≈70 ｜ deb 21 ｜ script 15 ｜ snap 7 ｜ ppa 4 ｜ flatpak 0，总规模 ≈117。

## Out of Scope

* 服务器运维 / 多场景分组清单（首发只做开发者工作站一份）。
* 24.04 以外的 Ubuntu 版本承诺。
* curl-script 的 checksum 锁定 / 脚本审计机制（决策：信官方）。
* dotfiles/config 类条目与 dotfile-block provider（已确认不纳入，独立任务）。
* 国内镜像源/代理适配（已确认首发不考虑，记 backlog）。
* LLM 生成条目（spec 既定 MVP 后置）。

## Technical Notes

### 仓库现状（Explore 侦察，2026-06-10）

* schema（`ubuntu_setup/catalog/schema.json` + `core/models.py`）：必填 id/description/type，
  可选 depends_on/tags/source/version/hold；无任何环境适配字段；PreconditionError 仅运行时 skip。
* provider：只有 apt 完整实现；spec 已设计 ppa/deb/snap/flatpak/dotfile-block/service/script
  但均未落地；注册表在 `core/providers/__init__.py`。
* catalog 数据：仅 `catalog/cli-tools.yaml` 2 条；loader 自动扫描 `*.yaml`，新增文件零代码。
* planner：depends_on 拓扑排序未实现。
* 测试：stdlib unittest + FakeRun（~3000 行单元）；无 CI、无容器/集成基建；
  smoke 走 `UBUNTU_SETup_SMOKE=1`。
* spec 关键约束：「能用 provider 表达的就禁止 curl|bash」；script 是逃生口、
  必须手写幂等 check、LLM 绝不生成。

### 风险缓解（访谈定）

* 条目逐条标注安装方式溯源（官方 URL + 原样命令）——回应「信任与安全」叙事，零额外工程。
* 调研先行出全量清单 → 按 provider 分批落地，每批独立可验收。
* 容器里验 systemd/snap 受限 → 调研阶段逐条标注「容器可验 / 须 VM 验」。

## Research References

* [`research/authoritative-sources.md`](research/authoritative-sources.md) — 10 类源逐个盘点；
  方案 A 推荐（已采纳）；兜底规则三条；Caveat：规模是目测，定稿前须脚本实跑交集。
* [`../06-10-intersection-research/research/conclusion.md`](../06-10-intersection-research/research/conclusion.md) —
  **交集实跑定稿（2026-06-10）**：110 条入选（+4 依赖引证 −1 合并 ≈113），N 维持不变；
  provider 缺口 deb 21 / script 14 / snap 6 / ppa 4 / flatpak 1；可验性 container 95 / VM 15；
  bedrock 评审稿 5 条待用户裁决；apt 63 条可先行落地。

## Implementation Plan（子任务拆分）

1. **catalog-intersection-research**：交集脚本 + 实跑 5 核心源 → 定稿清单
   （溯源/安装方式/requires/可验性/分组/缺口 provider/bedrock 白名单评审稿）。
2. **schema-requires-and-planner-topo**（引擎准备，可与 1 并行）：requires 字段 + 环境探测 +
   browse 隐藏/plan 跳过 + depends_on 拓扑排序 + spec 回写。
3. **catalog-verify-infra**（可与 1、2 并行）：容器/VM 真装验证基建选型与搭建
   （先用现有 2 条 apt 条目打通）。
4. **provider-***（待 1 定稿后按分布开）：预计 deb/第三方 apt 源、script，可能 snap。
5. **entries-batch-***（待 4 逐个就绪后分批）：按 provider 批次落地条目 + 全量验证跑绿。
