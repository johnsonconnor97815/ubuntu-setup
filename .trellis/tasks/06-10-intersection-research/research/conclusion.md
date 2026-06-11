# 交集调研结论（2026-06-10）

数据链：`sources/*.json`（8 源快照）→ `tally.py`（方案 A 计票）→ `annotate-batches.json` + `annotations.json`（110 条逐条标注）→ `assemble.py` → `final-list.{json,md}`。全链可重跑。

## 1. 结果总览

- 机械计票：598 组，**110 条入选**（≥3 票且核心票 ≥2；禁并对拦截 24 次误合并，见 tally.json `blocked_joins`）。
- 标注：110/110 全覆盖——官方装法+溯源 URL、provider 映射、requires、可验性、前置依赖。
- 兜底执行后建议规模：**110 − 1（gcc/make 合并）+ 4（依赖引证）≈ 113 条**，外加 bedrock 评审稿 ~5 条待用户裁决。

### 规模 vs 粗估（50–80）的复核

实跑 110 条高于目测，但**不建议收紧 N**：入选分布横跨 21 个类别，无「HN 时髦工具」膨胀迹象（Rust 系新潮 CLI 仅 ~6 条且各自确有 2 核心票 + awesome 辅助票）；偏高主因是 pkgstats 深扫（前 1 万名筛出 350 工具）让核心票供给比预估充足。N≥3 + 核心 ≥2 的约束仍然有效。**决定：维持方案 A 参数不变。**

## 2. 兜底规则执行结果

### 2a. 依赖引证自动票（≥2 条已入选条目的官方步骤明确要求）

来自 `final-list.json` 的 `prerequisite_citations`：curl 22、wget 9、gpg/gnupg 12、ca-certificates 5、software-properties-common 4、lsb-release 2、unzip 2、npm 2。

| 处置 | 条目 |
|------|------|
| 已在榜（无需动作） | curl、wget、gnupg（gpg 同包） |
| **依赖引证新增 4 条** | ca-certificates、software-properties-common、lsb-release、unzip（均 apt / bedrock / container 可验） |
| 排除 | npm（随 nodejs 条目自带，不独立成条） |

### 2b. bedrock 白名单评审稿（需用户 PR 评审，不走机械票）

| 候选 | 理由（可溯源） |
|------|----------------|
| build-essential | 见 §3 合并建议；popcon/pkgstats 观察区 + curation 实际计票单元 |
| zip | 与 unzip 配对；popcon+pkgstats 观察区双命中 |
| xz-utils | homebrew+popcon 观察区；解包工具链基础件 |
| openssh-server | popcon by_vote 高位；Server/SSH 场景命脉（项目 spec 明确支持该场景），桌面向源天然不列 |
| python3-venv + python3-pip | Ubuntu 拆包 + PEP 668：无 venv 则 pip 生态不可用；与已入选的 pipx/uv 配套 |

排除讨论：bash/tar/coreutils（Ubuntu 预装，check 永真，无条目价值）；openssh-client（desktop/server 均预装）。

### 2c. 类别空洞复查（21 类全非空，按规则记录薄类别原因）

| 类别 | 条数 | 判读 |
|------|------|------|
| bedrock | 1→~10 | 机械标准天然漏（调研文档预测命中），由 2a/2b 兜底填充——机制按设计工作 |
| security-privacy | 2 | 核心源不覆盖安全工序类（ufw/firewalld/pass/bitwarden 全在观察区差 1 票）。**不人工补**：越线即破坏「外部数据为准」承诺；ufw、unattended-upgrades 列入「作者推荐区」候选，留给用户日后以独立 tag/profile 表达，不进首发必备清单 |
| ai-tools | 1 | 数据源年度周期对 AI CLI 滞后（claude-code/aider 仅 1 核心票）。记录原因，不补；下次重跑交集预期自然回升 |
| gaming / productivity | 1 / 2 | 与「开发者工作站」定位一致，正常薄 |

## 3. 合并与特殊判读（落地条目时执行）

- **gcc + make → build-essential 单条**：GCC 上游不发二进制，curation 源本就按 build-essential 计票；两条票数合并，安装单元取 build-essential（净 −1 条）。
- **yarn（唯一 undecided）**：官方唯一推荐路径是 corepack（随 Node.js 分发）。建议：落地为 script 条目（`corepack enable`，check `command -v yarn`），或并入 nodejs 条目 notes——倾向前者，保持一软件一条目。
- **thunderbird（唯一 flatpak 条目）**：官方顺序 Flatpak > Snap > 发行版包。为 1 条建 flatpak provider 性价比低；候选：改走官方 snap（亦官方维护，省一个 provider）或接受 flatpak provider 排后实现。**留给落地任务与用户决策。**
- p7zip → 24.04 包名为 `7zip`；jupyterlab → pipx 形态 script；firefox 必须含官方 apt pin 步骤（否则被 Ubuntu snap 壳包盖回）。

## 4. provider 缺口 → 子任务开题建议

分布：**apt 63 ｜ deb 21 ｜ script 14 ｜ snap 6 ｜ ppa 4 ｜ flatpak 1 ｜ undecided 1**

1. **apt 63 条不依赖任何新 provider**——可在引擎准备（requires 字段）就绪后第一批落地。
2. **provider-deb**（第三方 apt 仓库，21 条）：最大缺口，最高优先。依赖 engine-prep 的 planner 拓扑排序（repo 条目 → package 条目）。
3. **provider-script**（14 条）：第二优先；每条手写幂等 check（spec 硬约束），官方命令原样收录。
4. **provider-snap**（6 条）+ **provider-ppa**（4 条）：第三批；ppa 实现与 deb 高度同构，可考虑同一任务内做。
5. **flatpak**：仅 1 条，等 thunderbird 决策后再定是否立项。

## 5. 验证基建输入（verify-infra 任务）

- **container 可验 95 条 ｜ 须 VM 15 条**。
- VM 原因分布：systemd 服务生效（docker、mongodb、redis、postgresql、mysql、mariadb、nginx、ollama）；snapd（6 条 snap）；flatpak 运行时（thunderbird）。
- 建议：容器跑 95 条常规回归；VM（LXD/multipass 选型在该任务内定）跑 15 条服务/snap 类。

## 6. Caveats

- 所有版本号/榜单为 2026-06-10 快照，落地条目前临近发布应重跑 `tally.py` 链路核对漂移。
- Homebrew Linux 子集占比无公开拆分；Flathub 对 Ubuntu snap 生态有渠道偏移——均已按方案 A 的多源交叉对冲。
- 标注中的 noble 包版本已逐条经 packages.ubuntu.com 核实，但 LTS point release 可能更新（docker.io 29.1.3 即一例）。
