# provider-ppa：PPA provider + 4 条条目全量真装

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
逐条官方步骤：final-list.json（provider_type=ppa：inkscape、obs-studio、yt-dlp、fastfetch）。

## Goal

实现 `ppa` 类型 provider，4 条 PPA 档条目（repo+包链）全量落地并 Docker 档真装验证全绿——
至此容器可验的四档（apt/deb/script/ppa）全部收口。

## Requirements

* **ppa provider**（`core/providers/ppa.py` + 注册表 + schema 同步）：按 spec 设计；
  与 deb 高度同构——实现上**优先复用 deb 的机制**（key/源落盘、lists 探针、AptCache 守卫），
  形态取舍：`add-apt-repository`（需 software-properties-common，spec 有 PreconditionError
  设想）vs 直接落 sources 文件（ppa.launchpadcontent.net + Launchpad API 取签名 key），
  按 spec 与幂等可检性选定并回写；若 spec 倾向 add-apt-repository，幂等 check 仍须查
  活系统文件而非命令副作用。
* **4 条条目**：inkscape（ppa:inkscape.dev/stable，GUI requires desktop）、
  obs-studio（ppa:obsproject/obs-studio，GUI）、yt-dlp（ppa:tomtomtom/yt-dlp）、
  fastfetch（ppa:zhangsongcui3371/fastfetch）——repo 条目 + 包条目 depends_on 链、
  溯源注释（官方推荐 PPA 的出处 URL）、source: official。
* **验证**：单元层 FakeRun 全分支；集成层遍历套件覆盖 4 链（沿 deb 档模式：链序、
  恰一次 update、幂等复跑、GUI skip→种标记真装），全量真跑累计全绿。
* 不可妥协项全保持（③逐命令 sudo、⑤runner、⑥注册表分发、②活系统 check）。

## Acceptance Criteria

* [ ] ppa provider 注册可用，schema 拒绝非法条目；幂等 check 查活系统。
* [ ] 4 链真跑累计全绿（日志留存）；恰一次 apt-get update 断言。
* [ ] 与 deb 机制复用处无复制粘贴漂移（共享代码或明确注释）。
* [ ] 默认套件全绿、ruff 干净；spec 回写（ppa 字段契约与形态取舍）。

## Out of Scope

* snap 档（最后一个 provider 任务）；PPA 移除路径。

## Technical Notes

* 本机基镜像旋钮 UBUNTU_SETUP_VERIFY_BASE_IMAGE=mirror.gcr.io/library/ubuntu:24.04。
* PPA 源形态参考：noble 上 add-apt-repository 生成 .sources（deb822）+ keyring 由
  Launchpad API 获取；直接落盘形态可用
  `https://ppa.launchpadcontent.net/<owner>/<name>/ubuntu {codename} main` +
  `https://api.launchpad.net/devel/~<owner>/+archive/ubuntu/<name>?ws.op=getSigningKeyData`。
* fastfetch 已有 apt 候选？——final-list 标 ppa（noble 无包），落 ppa 档；与 apt 批次的
  fastfetch 条目（system-monitoring）核对避免重复：**apt 批次已落 fastfetch 则本批改为
  迁移该条目到 ppa 链**，对照表同步（实现时先清点）。
