# 验证基建：容器/VM 真装集成测试

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
选型依据：[`research/isolation-tech.md`](research/isolation-tech.md)；
条目分流（95 容器 / 15 VM 档）：[`../06-10-intersection-research/research/conclusion.md`](../06-10-intersection-research/research/conclusion.md) §5。

## Goal

建成可持续回归的真装验证管线：干净 Ubuntu 24.04 guest 里跑「check → install → 重跑幂等」。
本任务用现有 2 条 apt 条目（ripgrep、tree）打通全链；113 条全量验证发生在 entries-batch 任务。

## 选型（已定）

- **95 条常规档**：Docker 普通容器（自建 ubuntu:24.04 验证镜像，可并行）。
- **15 条 systemd/snap/flatpak 档**：LXD/Incus 系统容器（docker 条目开 security.nesting；
  CI 走 canonical/setup-lxd）；逃生口 `lxc launch --vm` 真 VM。
- 编排：stdlib unittest + subprocess 驱动 GuestDriver 抽象；源码以本地 wheel 注入 guest。

## Requirements

* **GuestDriver 抽象**（集成测试层，非产品代码）：`launch / push / exec / destroy` 最小接口；
  `DockerDriver`（本任务全链验证）与 `LxdDriver`（代码就绪；本机未装 lxd/incus —— **探测不到
  环境时整档优雅 skip 并写明原因，绝不在开发机上擅自安装系统软件**）。
* **wheel 注入**：构建本项目 wheel → 注入 guest → guest 内创建 venv 安装（24.04 PEP 668，
  不污染系统 python）；全程临时目录，宿主无残留。
* **验证协议**（每条目）：fresh guest → CLI headless check（期望 absent）→ apply 真装（期望成功）
  → 复跑 check/apply（期望已就位、skip、不重复安装）→ 退出码与输出断言对齐 spec 退出码表。
* **档位与开关**：集成测试默认不随单元套件跑——`UBUNTU_SETUP_INTEGRATION=1` 解锁（沿用
  UBUNTU_SETUP_SMOKE 惯例）；container/vm 两档可分开选跑；跑法写入文档。
* **诊断**：失败时收集 guest 内日志/命令输出到测试产物，便于定位。

## Acceptance Criteria

* [ ] DockerDriver：ripgrep + tree 全链真装验证绿（fresh→install→幂等复跑），并行安全。
* [ ] LxdDriver 代码与单测（mock 驱动）就绪；无 lxd/incus 环境时显式 skip 带原因。
* [ ] wheel 注入自动化且宿主零残留；guest 为干净 ubuntu:24.04（不复用脏容器）。
* [ ] 集成测试不影响默认 `python -m unittest discover -s tests`（全绿不变慢）；
  解锁命令文档化。
* [ ] ruff 无新告警；spec 回写（验证基建的运行方式与档位约定，落位 idempotency-and-execution
  或独立小节）。

## Out of Scope

* 113 条全量验证执行（entries-batch 任务，待条目落地）。
* GitHub Actions workflow 文件（管线设计保持 CI-ready，工作流文件随首发准备另立）。
* 在本开发机安装 lxd/incus（需用户自己执行；装好后 LXD 档自动解锁）。
* snap/flatpak/systemd 条目的实际验证（依赖 provider-* 任务产出条目）。

## Technical Notes

* 本机实测（research）：Docker 29.5.3 可用、/dev/kvm 存在、incus 未装（apt 可装）。
* GHA 标准 Linux runner 2024-01 起放开 KVM；LXD 走 canonical/setup-lxd action。
* flatpak 在 LXD 容器内可用性未查证——打通时实测一次，不行走 `--vm` 逃生口（记录在案）。
* 现有惯例：tests/ 镜像源码树、stdlib unittest、FakeRun、smoke 用 UBUNTU_SETUP_SMOKE=1 gate。
