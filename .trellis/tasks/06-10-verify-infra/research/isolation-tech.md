# Research: 干净 Ubuntu 24.04 真装验证——隔离环境与测试编排选型

- **Query**: 为「干净 Ubuntu 24.04 上自动化真装验证 catalog 条目」选型隔离环境与测试编排方案
- **Scope**: mixed（联网调研 + 本机能力实测 + 项目内惯例核对）
- **Date**: 2026-06-10（所有 URL 均于当日访问）

---

## 0. 结论速览

**主方案（双档承载）**：

| 档位 | 承载 | 理由 |
|---|---|---|
| 95 条纯 apt/dpkg/文件档 | **Docker 普通容器**（自建 `ubuntu:24.04` 基础验证镜像） | 创建 ~1s、本地已有 Docker、GHA 开箱即用、可大规模并行 |
| 15 条 systemd/snap/flatpak 档 | **LXD 系统容器**（GHA 用 `canonical/setup-lxd`；本地 snap 装 LXD 或 apt 装 Incus 等价替换） | 系统容器原生跑完整 systemd；snapd 在一级 LXD 容器内是官方支持路径；docker 条目用 `security.nesting=true` 嵌套 |

**备方案**：15 条档升级为**真 VM**——优先 `lxc launch ubuntu:24.04 --vm`（与容器同一套 CLI/exec/file API），其次 multipass。GHA 标准 Linux runner 自 2024-01 起支持 KVM 嵌套虚拟化，本地开发机已实测有 `/dev/kvm`。

**编排**：沿用项目 stdlib `unittest` 惯例，独立 `tests/integration/`（默认 discover 不收集），以 subprocess 驱动 `docker` / `lxc` CLI，guest 内装本地构建的 wheel；环境变量分档开关（沿用现有 `UBUNTU_SETUP_SMOKE=1` 模式）。

---

## 1. 候选隔离技术逐项评估

### 1.1 Docker/Podman 普通容器（ubuntu:24.04 镜像）

- **创建速度**：秒级（镜像已缓存时 <1s 起容器）。
- **systemd**：不可用。容器内 `systemctl` 直接报 `System has not been booted with systemd as init system (PID 1)`（[Cloud ABC 博客, 2024-10-27](https://blog.cloudabc.eu/linux/container/2024/10/27/ubuntu-docker-container-systemd/)）。apt 条目的 postinst 经 `deb-systemd-invoke`/`policy-rc.d` 容忍服务不启动，纯安装验证不受影响——这正是 95 条档可用普通容器的依据。
- **snapd**：**不可用**。snapcraft 官方表态：「running snaps inside docker containers is not a supported workflow」，snap 在 LXD 容器才是支持路径（[snapcraft forum, 2019-07](https://forum.snapcraft.io/t/problem-with-squashfs-in-basic-ubuntu-18-04-docker-image/12147)）。存在 [ogra1/snapd-docker](https://github.com/ogra1/snapd-docker/blob/master/build.sh) 这种 hack（`/sbin/init` + `--cap-add SYS_ADMIN --device /dev/fuse --security-opt apparmor:unconfined` + squashfuse + 假 udevadm），但脆弱、无 confinement、非官方支持，不建议作为基建。
- **嵌套 docker**：需 `--privileged` DinD，官方镜像 `docker:dind` 可行但与「验证 catalog 真装 docker-ce」语义不符（装的是 systemd 服务）。不适合 docker 条目。
- **GHA 可用性**：runner 预装 Docker，零摩擦。
- **镜像新鲜度**：Canonical 随 point release 持续重建 `ubuntu:24.04` OCI 镜像；跑前 `docker pull` 即可。注意 noble OCI 镜像自带 `ubuntu`(uid 1000) 用户，可顺带覆盖 `SUDO_USER` 路径解析场景。
- **结论**：95 条档最优解；对 snap/systemd 档完全不够。

### 1.2 Docker/Podman + systemd 镜像（systemd 当 PID 1）

2026 年主流做法（kitchen-dokken / molecule / geerlingguy 镜像一致）：

```
镜像：ubuntu:24.04 + apt install systemd systemd-sysv dbus；CMD ["/sbin/init"]
运行：docker run -d --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /tmp <img>
```

- 现成镜像：[geerlingguy/docker-ubuntu2404-ansible](https://github.com/geerlingguy/docker-ubuntu2404-ansible)（Docker Hub 100K+ 拉取，最近 push 距今 4 天，自动随上游重建；Dockerfile 里 mask 掉 udev/getty 避免 CPU 空转）、jrei/systemd-ubuntu。
- systemd 官方立场：systemd 可以当容器 payload 的 PID 1，但需要 cgroup 子树委派写权限（[systemd CGROUP_DELEGATION 文档](https://github.com/systemd/systemd/blob/main/docs/CGROUP_DELEGATION.md)）。
- **坑**（[serverfault 1053187](https://serverfault.com/questions/1053187/systemd-fails-to-run-in-a-docker-container-when-using-cgroupv2-cgroupns-priva)、[systemd#19245](https://github.com/systemd/systemd/issues/19245)）：
  - cgroup v2 下 `--cgroupns=private` 时**不要**再 bind-mount `/sys/fs/cgroup`，两者互斥；
  - 要求 Docker ≥20.10 且宿主 cgroup v2（Ubuntu 24.04 宿主与 GHA runner 均满足）；
  - Debian/Ubuntu 系镜像还应 `echo exit 0 > /usr/sbin/policy-rc.d` 控制安装时服务自启行为。
- **Podman 优势**：command 为 init 时自动 `--systemd=true`，自动准备 tmpfs 与 cgroup，无需 privileged（[Red Hat Developer, 2019-04-24](https://developers.redhat.com/blog/2019/04/24/how-to-run-systemd-in-a-container)；molecule podman 例子同样佐证）。noble 仓库里 podman 为 4.9.3（本机 apt-cache 实测），版本偏旧。
- **snapd 仍不可用**（同 1.1），所以此方案只能覆盖 15 条档中的 8 条 systemd 服务类，覆盖不了 6 snap + 1 flatpak。
- **结论**：可作 8 条 systemd 服务条目的轻量过渡方案，但既然要为 snap 档引入 LXD/VM，不如把 15 条统一放 LXD，避免三套承载。

### 1.3 LXD / Incus 系统容器

- **创建速度**：镜像缓存后秒级启动；完整 systemd 原生作为容器 init（系统容器的设计目标）。
- **systemd**：原生支持，无任何 hack。
- **snapd**：**一级 LXD 容器内是官方支持路径**。LXD 镜像预置 fuse、`/dev/fuse`、AppArmor namespacing，专为 snapd 可用而设计（[LP#1628289 stgraber 评论](https://bugs.launchpad.net/bugs/1628289)；[snapcraft forum 官方表态](https://forum.snapcraft.io/t/problem-with-squashfs-in-basic-ubuntu-18-04-docker-image/12147)）。Canonical 自家 snapcraft 构建链就在 GHA 上用 LXD（[craft-actions snapcraft/setup](https://github.com/canonical/craft-actions/blob/main/snapcraft/setup/README.md)）。
  - **限制只在二级嵌套**：AppArmor 不支持多层 namespace 堆叠，LXD-in-LXD 的内层容器跑不了 snapd（[canonical/lxd#14770, 2025-01](https://github.com/canonical/lxd/issues/14770)）。GHA runner 本身是 VM，其上 LXD 容器是一级——不触发此限制。本地裸机同理。
  - 风险提示：2025-2026 出现过 snapd deb 回归打破「LXD 容器内装 snap」的 bug（[LP#2127244](https://bugs.launchpad.net/bugs/2127244)），属一级容器内装 LXD snap 的场景，已修复；说明这条栈偶有波动，但因是 Canonical 自家 CI 关键路径，修复响应快。
- **嵌套 docker**：官方支持。`security.nesting=true`（+ `security.syscalls.intercept.mknod/setxattr` 给 overlay2），`/var/lib/docker` 避免放 zfs 池（否则退化为 vfs 后端）（[Ubuntu 官方教程](https://ubuntu.com/tutorials/how-to-run-docker-inside-lxd-containers)；[LXD 论坛, 2021-12](https://discuss.linuxcontainers.org/t/how-to-run-docker-inside-lxc-container/13017)）。可承载 docker-ce 条目的「装好 + 服务起 + hello-world」验证。
- **GHA 可用性**：[canonical/setup-lxd](https://github.com/canonical/setup-lxd) 官方 action（v1 发布于 2025-12-11，2026-02 仍在维护），装 snap、初始化 preseed、并处理已知坑：**runner 上 Docker 的 iptables DOCKER-USER 链会掐断 lxdbr0 容器外网**，action 内置 `iptables -I DOCKER-USER -i lxdbr0 -j ACCEPT` 修复（[setup-lxd#19](https://github.com/canonical/setup-lxd/issues/19)）。
- **LXD vs Incus（2026 生态）**：
  - LXD：Canonical 控制，AGPLv3 + CLA，仅 snap 分发（snap 自动升级到 6.x 无法回退，[pieterbakker.com, 2026-05-12](https://pieterbakker.com/migrate-lxd-6x-containers-to-incus/)）。
  - Incus：社区 fork（原 LXD 维护者，Linux Containers 旗下），Apache 2.0 无 CLA；Incus 7.0 LTS 2026-05-05 发布、支持至 2031-06（[官方公告](https://discuss.linuxcontainers.org/t/incus-7-0-lts-has-been-released/26641)）；**Ubuntu 24.04 universe 仓库可直接 `apt install incus`（6.0.0-1ubuntu0.3，本机 apt-cache policy 实测）**，GHA ubuntu-24.04 runner 同样可 apt 安装；社区重心已明显移向 Incus（[bigiron.cc, 2026-05-11](https://www.bigiron.cc/guides/lxc-vs-lxd-vs-incus-on-debian)）。CLI 与 LXD 几乎同构（`lxc` → `incus`），驱动抽象层做薄即可互换。
  - **本项目取舍**：CI 上 LXD 有官方 action 兜底坑（推荐起步）；本地或想避开 snap 时 Incus apt 安装更省事。二者对本任务能力等价，封装成同一 driver 后可随时切换。
- **镜像新鲜度**：`ubuntu:` 远端镜像每日自动构建测试（[Ubuntu 博客](https://ubuntu.com/blog/lxd-virtual-machines-an-overview)）；Incus 的 images: 远端同样每日重建。
- **结论**：15 条档（8 systemd + 6 snap + 1 flatpak + docker 嵌套）的最优单一承载。flatpak-in-LXD 未单独查证（见 Caveats）。

### 1.4 multipass / QEMU+cloud-init / LXD VM（真 VM）

- **GHA KVM 现状**：标准 Linux runner 自 2024-01 SKU 升级后全部支持嵌套虚拟化，`/dev/kvm` 可用（[actions/runner-images discussion #7191](https://github.com/actions/runner-images/discussions/7191)：「All Linux runners are now on a SKU that supports nested virtualization」）；需先加 udev 规则放开 kvm 权限（[GitHub Changelog, 2024-04-02](https://github.blog/changelog/2024-04-02-github-actions-hardware-accelerated-android-virtualization-now-available/)）。Windows/macOS runner 不支持。
- **multipass**：`multipass launch 24.04 --cloud-init xxx.yaml` 即得真 Ubuntu VM（systemd+snapd+ 独立内核全有），官方 cloud-init 定制文档齐全（[multipass docs](https://documentation.ubuntu.com/multipass/en/latest/how-to-guides/manage-instances/launch-customized-instances-with-multipass-and-cloud-init/)）。2023 年底在 GHA 上不可用（[multipass#3326](https://github.com/canonical/multipass/issues/3326)），但 KVM 放开后已可用——2025-09 实测报告「Multipass works」（[runner-images#12933](https://github.com/actions/runner-images/issues/12933)）。缺点：multipass 自身经 snap 分发、实例管理粒度粗（无镜像缓存分层）、启动分钟级。
- **LXD/Incus VM**（`lxc launch ubuntu:24.04 vm1 --vm`）：与系统容器同一套 CLI/`exec`/`file push`/preseed，镜像内置 lxd-agent，镜像缓存后启动到可 exec 约 10s 量级（[simos 博客实测](https://blog.simos.info/how-to-use-virtual-machines-in-lxd/)；[LXD 官方教程](https://documentation.ubuntu.com/lxd/latest/tutorial/first_steps/)）。GHA 上验证可行，甚至无硬件虚拟化时可退化软件模拟（[runner-images#12933](https://github.com/actions/runner-images/issues/12933)）。**这是「15 条档从容器升级到 VM」最平滑的路径：driver 只需多传 `--vm`。**
- **QEMU+cloud-init 裸用**：控制力最强但要自己搭 ssh/端口/镜像管线，本项目无此必要。
- **本机能力（2026-06-10 实测）**：Ubuntu 24.04.4、64 核 /125GB、`/dev/kvm` 存在（kvm 组 + ACL）、Docker 29.5.3 已装、podman/lxd/incus/multipass 均未装。**KVM 能力确认可用。**
- **结论**：作为备方案与逃生口；不作主承载（启动慢、资源占用高、并行密度低）。

### 1.5 取舍矩阵

| 维度 | Docker 普通容器 | Docker+systemd 镜像 | LXD/Incus 系统容器 | LXD VM / multipass |
|---|---|---|---|---|
| 创建速度（镜像已缓存） | ~1s | ~2-5s | ~5-10s | ~10s（LXD VM）/ 分钟级（multipass） |
| systemd 服务验证 | 否 | 是（privileged/caps） | 是（原生） | 是（原生） |
| snapd | 否（官方不支持） | 否（hack 不可靠） | 是（一级容器官方支持） | 是 |
| flatpak | 否 | 存疑 | 大概率可（未查证） | 是 |
| 嵌套 docker（docker-ce 条目） | DinD hack | 勉强 | 是（security.nesting） | 是 |
| 内核隔离 | 共享宿主内核 | 共享宿主内核 | 共享宿主内核 | 独立内核（最接近真机） |
| GHA 可用性 | 预装，零成本 | 预装，零成本 | setup-lxd action / apt incus，~1min | KVM 已放开；LXD VM 可用 |
| 本地就绪度（本机实测） | 已装 | 已装 | 需装（snap lxd 或 apt incus） | 需装；/dev/kvm 已确认 |
| 并行密度（64 核本机） | 极高（几十个） | 高 | 高（十几个） | 低-中（受内存/启动时间限制） |
| 失败诊断 | docker logs/exec | + journalctl | lxc exec + journalctl | + 串口/console |
| 镜像新鲜度 | Canonical 随点版本重建 | 自建随基镜像重建 | ubuntu:/images: 每日重建 | cloud image 每日构建 |

---

## 2. 同类项目先例

| 项目 | 隔离技术 | 编排模式 | 对本项目的启示 |
|---|---|---|---|
| **Ansible Molecule**（[docker 示例](https://docs.ansible.com/projects/molecule/examples/docker/)、[podman 示例](https://docs.ansible.com/projects/molecule/examples/podman/)、[Red Hat 博客 2020-08](https://www.redhat.com/en/blog/developing-and-testing-ansible-roles-with-molecule-and-podman-part-1)） | Docker/Podman 容器为主；systemd 场景用 geerlingguy 系列镜像 + privileged + cgroup 挂载；delegated driver 接任意后端 | 固定测试序列 `create → converge → idempotence → verify → destroy`，**`idempotence` 是一等步骤**（converge 跑两遍、第二遍必须 0 changed） | 与本项目「check → install → 重跑幂等」完全同构；驱动层（create/exec/destroy）与断言层分离的结构值得照抄 |
| **Chef Test Kitchen / kitchen-dokken**（[官方文档](https://kitchen.ci/docs/drivers/dokken/)、[dokken-images](https://github.com/test-kitchen/dokken-images)） | Docker 容器；systemd 用 `privileged: true` + `pid_one_command: /usr/lib/systemd/systemd` + `--cgroupns=host -v /sys/fs/cgroup:rw` | driver/transport/provisioner 一体化换取速度；测试数据 bind-mount 进容器 | 明确指出 **vendor OCI 镜像太精简、不像「fresh install」**，因此维护加料镜像——我们的自建验证镜像同理（补 sudo/locales 等基础件） |
| **Canonical snapcraft 构建链**（[craft-actions](https://github.com/canonical/craft-actions/blob/main/snapcraft/setup/README.md)） | GHA 上装 LXD，所有构建在 LXD 容器内进行 | 官方 action 一步装好 LXD + 处理网络坑 | 「GHA + LXD 容器 + snap 生态」是 Canonical 自家天天在跑的路径，成熟度有背书 |
| **dotfiles 社区**（[jamesridgway, 2018](https://www.jamesridgway.co.uk/dotfiles-with-github-travis-ci-and-docker/)、[sebastienrousseau Dockerfile.test](https://github.com/sebastienrousseau/dotfiles/blob/master/Dockerfile.test)、[FPGArtktic/setup-DotFiles](https://github.com/FPGArtktic/setup-DotFiles)） | ubuntu:24.04 普通容器，`docker build` 即测试（build 失败=测试失败） | 容器内建非 root 用户 + NOPASSWD sudo 模拟真实用户环境 | 轻量档的最简组织方式；**非 root + sudo 用户**的容器布置对验证本项目提权逻辑很关键 |
| **Omakub**（[basecamp/omakub](https://github.com/basecamp/omakub/)） | 仓库内未发现自动化集成测试基建（install.sh 直跑真机/GNOME 判断） | — | 反例：纯 bash 安装器无回归网正是本项目要超越的点。**not found，确认其无可借鉴 CI** |

---

## 3. 编排层建议

### 3.1 框架与目录

- **沿用 stdlib `unittest`**（项目惯例已锁定：`pyproject.toml` 注释「Tests are stdlib unittest」，`tests/test_cli.py` 已有 `UBUNTU_SETUP_SMOKE=1` 门控的真装 smoke test 先例）。
- 集成测试放 `tests/integration/`（或独立顶层 `verify/`），**默认 `python -m unittest discover -s tests` 不收集**（单独入口跑：`python -m unittest discover -s tests/integration`），避免拖慢单测。
- 分档用环境变量门控，沿用既有模式：
  - `UBUNTU_SETUP_VERIFY=container` → 95 条档（Docker）
  - `UBUNTU_SETUP_VERIFY=system` → 15 条档（LXD/Incus 容器，必要条目 `--vm`）
- 入口包一层 `Makefile` 或 `scripts/verify.py`（构建 wheel → 建镜像 → 并行跑 → 汇总报告），CI 与本地共用同一入口。

### 3.2 Guest 驱动抽象

一个小的 `GuestDriver` 协议（与 provider 注册表思路一致，类型分发收敛在一处）：

```
start(image, opts) / exec(argv) -> (rc, out, err) / push(src, dst) / destroy()
```

实现两个：`DockerDriver`（subprocess 调 `docker run/exec/cp/rm`）、`LxdDriver`（`lxc launch/exec/file push/delete`；`--vm` 仅是 launch 参数差异；Incus 仅是二进制名差异）。molecule/kitchen 的 create→verify→destroy 生命周期照搬。

### 3.3 源码注入 guest

- **推荐：本地构建 wheel + push + venv 安装**。`pip wheel . -w dist/`，push 进 guest 后 `python3 -m venv /opt/usetup && /opt/usetup/bin/pip install dist/*.whl`。理由：
  - 最接近真实分发形态；noble 有 PEP 668（externally-managed），venv 是最干净解法；
  - 依赖仅 pyyaml/jsonschema/textual（headless 路径不 import textual，但作为依赖会被装上；如想离线/提速可 `--no-deps` + `apt install python3-yaml python3-jsonschema`）。
- bind-mount 源码 + `pip install -e .` 仅适合本地调试单条目（快），不进 CI 路径——「干净机」保真度差（挂载点污染、宿主 uid 漏入）。
- 95 条档可把「venv + wheel 安装 + `apt-get update`」**烤进自建验证镜像**（每个条目容器免重复 30s+ 的 apt update / pip install）。

### 3.4 单条目验证流与并行

每条目（独立 fresh guest）：

1. `python -m ubuntu_setup --install <id> --dry-run`（或 status 查询）→ 期望「未就位/将安装」；
2. `python -m ubuntu_setup --install <id>` 真装 → 期望 exit 0；
3. 复查 check → 期望「已就位」；
4. 重跑 install → 期望 no-op（0 个动作），即 molecule 的 idempotence 步。

并行：每条目一个容器，`concurrent.futures` 或 make `-j` 控制并发；Docker 档本机 64 核可并发 16+；LXD 档并发 4-8。apt 流量可选 apt-cacher-ng 旁路缓存（后续优化项，非 MVP）。

---

## 4. 推荐方案

### 主方案

| 项 | 95 条档 | 15 条档 |
|---|---|---|
| 承载 | Docker 普通容器，自建 `verify-base` 镜像（ubuntu:24.04 + sudo + 非 root 用户 + venv/wheel + apt lists 已 update） | LXD 系统容器（ubuntu:24.04）；docker 条目加 `security.nesting=true` + syscall intercept；snap/flatpak 条目直跑 |
| 本地 | 已具备（Docker 29.5.3 实测在） | `snap install lxd` 或 `apt install incus`（noble universe 6.0.0，实测可装）；本机 64 核/125G 余量充足 |
| GHA | ubuntu-latest 预装 Docker，直接跑 | `canonical/setup-lxd@v1`（自带 DOCKER-USER iptables 修复）；或 `apt install incus` |
| 单条耗时量级 | 镜像烤好后 ~5-30s/条（取决于包体）；并行 ×16 → 全档 ~5-10 min | 容器起 ~10s + 安装：apt 服务类 ~30-90s、snap 类 1-3min（snap 下载占大头）；并行 ×4 → 全档 ~10-20 min |
| 失败诊断 | 保留失败容器 + `docker logs`/`exec` | `lxc exec` + `journalctl -u <svc>`；可 `lxc snapshot` 留现场 |

### 备方案（逃生口）

15 条档中任何条目在系统容器内碰到 AppArmor/嵌套边界（候选风险：flatpak、docker overlay2、snapd 回归 bug），该条目单独升级为 **LXD VM**（driver 加 `--vm`，API 不变；GHA KVM 已放开，本地 `/dev/kvm` 已确认）；若整档需要 VM，则 multipass + cloud-init 是次选（管理粒度更粗）。

### 决策点（留给主 agent）

1. LXD（CI 有官方 action）还是 Incus（apt 安装、社区主导、license 干净）起步——能力等价，driver 抽象后切换成本≈0；建议 CI 先 LXD、本地随意。
2. flatpak-in-LXD 需要在管线打通时实测一次（见 Caveats）。

---

## Caveats / Not Found

- **flatpak 在 LXD 容器内的可用性未专门查证**（涉及 bubblewrap 用户命名空间 + fuse）：理论上系统容器可跑，但建议第一批实测验证，不行就走 `--vm`。
- Omakub **未找到**任何自动化安装测试基建（确认为 not found，而非漏查）。
- nix/NixOS 测试框架（QEMU VM 驱动的 NixOS test driver）本次未深入调研——与本项目 apt/snap 生态差异大，参考价值有限（未联网确认细节，仅作存目）。
- 耗时量级为基于资料与机器规格的估算，**未实际跑分**；snap 下载受网络影响波动大。
- GHA runner 镜像内容随月更新（如 ubuntu-24.04 image 中 LXD 预装状态有过反复，[canonical/lxd#16172](https://github.com/canonical/lxd/pull/16172)），CI workflow 应显式安装而非假设预装。
- 本机实测快照（2026-06-10）：Ubuntu 24.04.4 / 64 核 / 125GB / `/dev/kvm` 在 / Docker 29.5.3 在 / podman、lxd、incus、multipass 均未装 / 用户在 docker 组。
