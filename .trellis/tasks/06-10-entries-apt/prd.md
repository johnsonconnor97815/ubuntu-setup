# 条目落地 apt 批次：~70 条 + 全量真装验证

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
数据来源：[`../06-10-intersection-research/research/final-list.json`](../06-10-intersection-research/research/final-list.json)
（`provider_type == "apt"` 的 63 条）+ 父 prd 追加决策（bedrock 5 条、依赖引证 4 条、gcc+make→build-essential 合并）。

## Goal

首发 catalog 的 apt 档全部落地为声明式 YAML 条目（不依赖任何新 provider），
并经 Docker 档真装验证全量跑绿——这是 ≈117 条总盘子里最大的一批。

## Requirements

* **条目集合**：final-list.json 中 provider_type=apt 的 63 条，执行合并（gcc+make→build-essential，
  净 62）+ bedrock 5 条（build-essential 即其一、zip、xz-utils、openssh-server、python3-venv+pip）
  + 依赖引证 4 条（ca-certificates、software-properties-common、lsb-release、unzip）≈ **70 条**。
* **包名以标注为准**：用 final-list.json 的 `ubuntu_apt_package`（已逐条经 packages.ubuntu.com
  核实）；p7zip→`7zip` 等改名已在标注中。
* **YAML 组织**：按领域分文件（沿 final-list 的 category 归并为合理的文件集，如 bedrock /
  build-toolchain / languages / databases / cli-tools / gui-apps …，复用既有 cli-tools.yaml 惯例，
  ripgrep、tree 并入新结构不重复）；`tags` 取类别 + 关键字；GUI 条目带 `requires: [desktop]`
  （标注里 requires 字段为准）。
* **溯源纪律**（信任叙事的落点）：每条 YAML 注释标注官方出处 URL 与命中源摘要
  （来自 final-list.json 的 official_doc_url 与 votes）；`source` 信任标记按 spec 取值
  （首发条目由维护者编写并经评审 → official）。
* **验证**：新增集成测试——遍历 catalog 全部 apt 条目（subTest 或参数化），每条走
  verify_entry 三步协议（Docker 档、并行）；**全量真跑一次并留存结果**。重型包
  （libreoffice 等）下载量大，允许按耗时调并行度/超时。
* **loader 全量校验**：唯一 id、合 schema、depends_on 引用闭合；单元层有目录级校验测试。

## Acceptance Criteria

* [ ] ≈70 条 apt 条目落盘，loader 校验通过，旧 2 条并入新结构无重复。
* [ ] 每条带溯源注释（官方 URL + 命中源）与正确 tags/requires/source。
* [ ] 集成测试覆盖全部 apt 条目；Docker 档全量真跑绿（留存运行记录/耗时）。
* [ ] GUI 条目 requires 标注与 final-list 一致（无桌面环境自动隐藏/跳过由引擎保证）。
* [ ] 默认单元套件全绿、ruff 无新告警；spec/文档如需（catalog 文件组织说明）随码回写。

## Out of Scope

* deb/ppa/snap/script 档条目（待对应 provider 任务）。
* 升级/移除路径的验证（MVP 范围外）。

## Technical Notes

* 验证基建用法见 `tests/integration/__init__.py`；本机基镜像需
  `UBUNTU_SETUP_VERIFY_BASE_IMAGE=mirror.gcr.io/library/ubuntu:24.04`（docker.io 被代理 MITM）。
* postgresql/mysql/mariadb/nginx 在 final-list 标 vm（systemd 服务生效），但 apt 安装本身
  容器可验——本批验证只断言安装与幂等，不断言服务运行；服务生效断言留给 VM 档
  （在条目上标注 testability 供后续分流）。
* python3-venv+pip 落地形态（一条多包 or 两条）依 apt provider 的 fields 能力定，
  实现时查 schema/provider；多包不支持则拆两条。
