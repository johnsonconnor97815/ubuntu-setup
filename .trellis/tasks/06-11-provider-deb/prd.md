# provider-deb：第三方 apt 仓库 provider + 试点条目

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
需求来源：[`../06-10-intersection-research/research/conclusion.md`](../06-10-intersection-research/research/conclusion.md) §4
（deb 21 条为最大 provider 缺口）；逐条官方步骤见 final-list.json（provider_type=deb）。

## Goal

实现 `deb` 类型 provider（第三方 apt 仓库：GPG key + sources 配置 + freshness 守卫），
以 **docker、vscode 两条试点**端到端真装验证打通「repo 条目 → apt 包条目」依赖链；
剩余 19 条归 entries-deb 批次任务。

## Requirements

* **deb provider**（`core/providers/deb.py` + 注册表登记）：按 spec `catalog-and-providers.md`
  的 deb 类型设计实现 check/install——key 落 `/etc/apt/keyrings/`、源落
  `/etc/apt/sources.list.d/`（形态按 spec；spec 未锁定处遵循官方文档惯例并回写 spec）；
  幂等：key 与源文件已就位且内容一致 → PRESENT。
* **apt update freshness 守卫**：新增/变更 repo 后须 `apt-get update`；同一 run 内多个 repo
  条目不重复 update（spec 提到未代码化的全局幂等处理，本任务落地并回写 spec）。
* **试点条目**：docker（repo 条目 + docker-ce 等包条目，depends_on 链经 planner 拓扑生效；
  官方步骤含 ca-certificates/curl 前置——已在 catalog）与 vscode（microsoft repo + code 包）。
  docker 官方装 5 个包——一条目一包 + depends_on，或扩展 apt provider 多包能力，
  按 spec 取舍并记录（涉及 schema 变更须回写）。
* **下载工具边界**：key 下载走 runner（curl，catalog 已含），不引入 python http 栈；
  sudo 逐命令（不可妥协③⑤）。
* **验证**：单元层（FakeRun 全覆盖 check/install 分支与 freshness 守卫）；集成层 Docker 档
  真跑两条试点全链（fresh→install→幂等复跑）；容器内 docker-ce postinst 与 systemd 的
  交互问题（policy-rc.d 等）在 harness 侧解决并记录。
* 不可妥协项全保持：尤其⑥（类型分发只在注册表）、②（check 查活系统）。

## Acceptance Criteria

* [ ] deb provider 注册可用；非法/缺字段条目被 loader 拒绝（schema 同步）。
* [ ] 幂等：repo 已配置时 check=PRESENT，install 跳过；key/源内容漂移可检出（OUTDATED 或按 spec 语义）。
* [ ] freshness 守卫：单 run 多 repo 仅一次 apt-get update（有单测锁定）。
* [ ] docker、vscode 两条试点 Docker 档真装全链绿（含依赖链顺序断言：repo 先于包）。
* [ ] 默认套件全绿、ruff 干净；spec 回写（deb 字段契约、update 守卫、多包取舍）。

## Out of Scope

* 其余 19 条 deb 条目（entries-deb）。
* ppa provider（独立任务；实现与 deb 同构可参考本任务）。
* repo 移除/降级路径（MVP 外）。

## Technical Notes

* planner 拓扑与 requires 门已就绪（engine-prep）；验证基建与 mirror 旋钮见
  tests/integration/（本机须 UBUNTU_SETUP_VERIFY_BASE_IMAGE=mirror.gcr.io/library/ubuntu:24.04）。
* 21 条 deb 的官方步骤（key URL、源行、包名）已逐条标注在 final-list.json 的
  official_cmd/official_doc_url——provider 字段设计应让这 21 条都能声明式表达（设计时通读）。
* firefox 条目须含官方 apt pin 步骤（标注 notes 有；pin 文件也应纳入 deb 条目字段考量）。
