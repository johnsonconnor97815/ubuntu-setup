# provider-snap：snap provider + 7 条条目（LXD 档验证）

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
逐条官方依据：final-list.json（provider_type=snap 6 条）+ thunderbird（父 prd 追加决策：改走官方 snap）。

## Goal

实现 `snap` 类型 provider，7 条 snap 档条目落地——chromium、yq、telegram、jetbrains-idea、
jetbrains-pycharm、kotlin、thunderbird。真装验证走 **LXD 档**（snapd 需 systemd，Docker 档
不可行）：套件代码完整就绪，本机无 lxd/incus 时显式 skip；装上 incus 即可解锁本地全量真跑。

## Requirements

* **snap provider**（`core/providers/snap.py` + 注册表 + schema 同步）：按 spec 设计——
  字段如 `snap`（商店名，缺省 entry id）、`classic`（布尔，confinement）、`channel`（可选）；
  check 查活系统（`snap list <name>` 或 /snap 状态，按 spec 取舍）；install
  `snap install [--classic] [--channel=…]` 逐命令 sudo；snapd 缺失 → PreconditionError
  skip（按 spec 语义，不代装 snapd）。
* **7 条条目**：商店名与 classic/channel 以官方发布页核实（jetbrains-idea/pycharm 取
  community 还是 ultimate 按官方文档与「通用开发者」定位定，写明）；GUI 5 条
  requires desktop（chromium/telegram/idea/pycharm/thunderbird），yq/kotlin CLI；
  溯源注释（snapcraft 发布者验证状态——publisher 是否官方，标注里有）。
* **验证**：单元层 FakeRun 全分支；集成层 LXD 档遍历套件（沿 test_system 模式：
  ubuntu:24.04 系统容器、snapd 就绪等待、verify_entry 协议、GUI skip→种标记），
  本机无 lxd/incus 时 setUpClass 显式 skip 带解锁指引；**若实现期间环境可用则全量真跑**，
  否则留下精确的解锁运行命令。
* thunderbird 决策落地的连带：final-list 标 flatpak 的 thunderbird 改 snap，
  对照表/计数同步；flatpak 归 backlog 的注记留在父 prd（已有）。

## Acceptance Criteria

* [ ] snap provider 注册可用；schema 拒绝非法条目；snapd 缺失 PreconditionError 路径有单测。
* [ ] 7 条条目齐备：商店名/classic/channel 经 snapcraft 页核实，溯源注释含发布者验证状态。
* [ ] LXD 档遍历套件就绪：无环境显式 skip 带指引；有环境则全量真跑累计全绿（日志留存）。
* [ ] 默认套件全绿、ruff 干净；spec 回写（snap 字段契约、snapd 前置语义）。

## Out of Scope

* flatpak provider（backlog，父 prd 决策）；snap 移除/降级路径；在宿主机安装 lxd/incus。

## Technical Notes

* 本机现状：docker 在、lxd/incus 不在——LXD 真跑解锁需用户 `sudo apt install incus`
  （或 lxd snap）后 `incus admin init --minimal`；LxdDriver 已支持 lxc/incus 同构。
* LXD 容器内 snapd 可用但启动有就绪窗口（`snap wait system seed.loaded` 惯例）；
  isolation-tech.md 有调研记录。
* snapcraft 商店名核实用 https://snapcraft.io/<name> 页面或 snap info（guest 内）。
