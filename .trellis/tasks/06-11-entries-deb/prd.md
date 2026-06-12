# entries-deb：剩余 19 条第三方仓库条目 + 全量真装验证

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
provider 与试点（docker、vscode 已落）：[`06-11-provider-deb`](../06-11-provider-deb/prd.md)；
逐条官方步骤：final-list.json（provider_type=deb 的其余 19 条）。

## Goal

把 deb 档剩余 19 条落地为声明式条目（repo 条目 + 包条目 depends_on 链），
Docker 档全量真装验证累计全绿——deb 档至此 21/21 收口。

## Requirements

* **条目集合（19 条产品）**：firefox（含官方 pin-1000）、gh、brave（二进制 key）、edge、
  signal、mongodb（`{codename}` 中段占位）、redis、vscodium、sublime-text（flat repo）、
  kubectl（flat `/`）、terraform、spotify、mariadb*、mysql*、nginx*（*这三条 final-list 判
  apt 首选——**逐条复核标注**：provider_type=deb 的才落 deb，标 apt 的已在 apt 批次，勿重复）；
  direct 模式：chrome、vivaldi、discord、zoom、obsidian、steam。
  以 final-list.json `provider_type=="deb"` 为准绳清点，与 apt 批次已落条目互斥无缝。
* **写法**：沿 provider-deb 试点惯例——repo 条目 + 包条目、溯源注释（官方 URL+验证日期）、
  GUI 条目 `requires: [desktop]`、`source: official`；repo 共享时复用（如 docker 已有）。
* **steam 特例**：i386 架构前置（`dpkg --add-architecture i386`）不在 deb provider 职责内——
  按 provider-deb 结论处理（缺架构时 PreconditionError skip 并留 note，或暂缓该条并记录），
  不得为单条目扩 provider。
* **obsidian 直链版本号**：direct 模式按 final-list 标注落地，注释写明升级即换 URL 的维护约定。
* **验证**：扩展集成遍历套件覆盖 deb 档（沿 test_container_catalog/test_container_deb 模式，
  repo→包链、恰一次 update、幂等复跑）；全量真跑累计全绿，日志留存；
  重型/慢源条目允许调并行与超时。
* **单元层**：test_catalog_content 对照表扩展（id/包名/requires/depends_on 图）。

## Acceptance Criteria

* [ ] deb 档 21/21 在 catalog 中齐备（含试点 2 条），与 final-list 逐条对照，无重复无遗漏。
* [ ] 全部条目溯源注释、requires、source 合规；repo/包 depends_on 图正确。
* [ ] Docker 档全量真跑累计全绿（留存记录；steam 特例处置记录在案）。
* [ ] 默认套件全绿、ruff 干净；authoring-guidelines 如有新写法惯例随码回写。

## Out of Scope

* snap/ppa/script 档；provider 行为变更（确有缺陷另说，最小修复+回写）。

## Technical Notes

* 本机基镜像旋钮：UBUNTU_SETUP_VERIFY_BASE_IMAGE=mirror.gcr.io/library/ubuntu:24.04。
* 第三方仓库网络可达性参差（spotify/brave 等），失败先判网络还是条目错，复跑留痕。
* mongodb 在 final-list 标 vm（systemd）——本批只验安装与幂等，与 apt 批次同口径。
