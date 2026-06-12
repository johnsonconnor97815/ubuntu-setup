# 首发准备 CI：GHA 门禁 + 全量真装回归（含 snap LXD 档）

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
GHA 可行性调研：[`../06-10-verify-infra/research/isolation-tech.md`](../06-10-verify-infra/research/isolation-tech.md)
（标准 Linux runner 2024-01 起放开 KVM；LXD 走 canonical/setup-lxd）。

## Goal

把本地已验证的测试体系搬上 GitHub Actions：PR 快速门禁 + 全量真装回归（容器四档 +
snap LXD 档）——**snap 7 条的真装验证经 CI 收口**（父任务唯一遗留项），并建成首发后的
持续回归网。

## Requirements

* **门禁 workflow**（`.github/workflows/ci.yml`）：push/PR 到 dev/main 触发——
  单元套件（`python -m unittest discover -s tests`）+ `ruff check ubuntu_setup tests`；
  Python 版本与项目一致（3.12，ubuntu-24.04 runner 自带）；分钟级完成。
* **全量回归 workflow**（`.github/workflows/catalog-verify.yml`）：`workflow_dispatch` 手动
  + `schedule` 每周一次触发（条目漂移监测：上游 URL/版本变化）；**不挂 PR**（全量真装
  几十分钟到小时级，挂 PR 不现实）。job matrix 五档并行：
  - container 四档：apt / deb / ppa / script 各跑对应遍历套件（UBUNTU_SETUP_INTEGRATION=1；
    **CI 不设 VERIFY_BASE_IMAGE**——mirror 旋钮是本机代理 MITM 的特殊处置，CI 用默认
    ubuntu:24.04）；
  - snap LXD 档：canonical/setup-lxd（或当前等价 action，实现时核实最新用法与版本 pin）
    → `tests.integration.test_system_snap`；LxdDriver 已支持 lxc 探测。
  - 各 job timeout 按本地实测耗时放宽（script 档本地 2661s → CI 设 ≥90min）；
    失败时上传 `_artifacts/` 诊断（actions/upload-artifact）。
* **验证手段（本地无法跑 GHA）**：YAML 可解析 + `actionlint` 静态检查（uvx/二进制可得则跑，
  不可得则记录）；action 版本逐个 pin 到 major（如 `actions/checkout@v4`）并联网核实存在；
  触发语法对照 GHA 官方文档。
* **README 最小补充**：CI badge + 一段「如何本地跑集成验证」（指向 tests/integration
  docstring），不展开重写 README。
* 推送与首跑由用户决定（按惯例不主动 push）。

## Acceptance Criteria

* [ ] 两个 workflow YAML 语法有效、actionlint 通过（或记录工具不可得）；action 版本均 pin 且核实。
* [ ] 门禁 job 与本地命令严格一致（unittest + ruff，同目录口径）。
* [ ] 回归 matrix 覆盖五档且互不阻塞（fail-fast: false）；artifacts 上传配置在案。
* [ ] snap 档 job 的 LXD 初始化步骤与 LxdDriver 探测路径吻合（lxc 命令可被找到）。
* [ ] README badge + 本地集成验证说明；默认套件全绿、ruff 干净。

## Out of Scope

* push / 触发首跑（用户决定）；发布流程（tag/release/PyPI）；coverage 统计。

## Technical Notes

* 本地各档实测耗时：apt 856s、deb 1734s、ppa 456s、script 2661s（CI runner 更慢，放系数 2）。
* 集成测试从仓库源码构建 wheel 注入 guest（uv 优先 pip 兜底）——CI 需装 uv 或退 pip，
  按 harness 现状选最少步骤。
* GHA ubuntu-24.04 runner 自带 docker；LXD 档用 setup-lxd 后无需 sudo 组操作（action 处理）。
