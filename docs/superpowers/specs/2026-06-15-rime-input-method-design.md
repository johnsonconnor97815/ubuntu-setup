# 设计:`scripts/rime.sh` —— RIME 输入法(fcitx5)安装 + 配置管理器

- 日期:2026-06-15
- 状态:设计已定稿,待实现
- 关联范式:`scripts/ghostty.sh`(桌面 GUI、SSH/headless 诚实提示、偏好 KEY=VALUE 存储 + 受管文件 backup 后整写)、`scripts/tmux.sh`(组件管理器、受管块、curated 列表 + i18n 表)、`scripts/zsh.sh`(组件管理器 bespoke `ui()`)、`scripts/fonts.sh`(纯用户态、curated、无 sudo)。

## 1. 目标与定位

把「在 Ubuntu 桌面上用 RIME 中文/CJK 输入」一键变成可管理的状态:安装承载框架 + RIME 引擎、选好输入方案、写好让应用识别输入法的环境变量,并把这些做成**可独立增删的组件**(像 `zsh.sh`/`tmux.sh`),配置收敛进**受管文件**,绝不覆盖用户自有内容。

**框架决策(已定):fcitx5**。CJK 输入体验最好、社区主流。包:`fcitx5` + `fcitx5-rime` + `fcitx5-config-qt`(+ 前端模块 + `im-config`)。RIME 用户配置目录:`~/.local/share/fcitx5/rime/`。不实现 ibus 分支(留作未来扩展;`framework` 在偏好里固定为 `fcitx5`,为日后多框架留位但当前单值)。

**诚实定位:RIME/fcitx5 是桌面 GUI 输入法。** 在 SSH / headless server 上,本机并不运行图形会话——这些设置作用于**有显示器的那台机器**。`install` 仍照常装包并写**用户自有**配置(一旦存在显示会话即生效),但 `install`/`configure`/`deploy` 检测到 `SSH_*` 时如实提示(完全照搬 `ghostty.sh` 的 `_*_where_note` 模式)。

## 2. 安装渠道与组件

渠道:**纯 apt**(RIME 与 fcitx5 都在 Ubuntu 官方仓,无需 vendor repo / snap)。

- **核心(必需,单次 `apt_install`)**:`fcitx5 fcitx5-rime fcitx5-config-qt im-config`。
  - `fcitx5-rime` 依赖 `rime-data`(brise),自带朙月拼音、注音、五笔、仓颉等内置方案。
- **前端模块(best-effort,逐个按 apt 候选探测后装)**:`fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 fcitx5-frontend-qt5`(`--no-install-recommends` 是 lib 默认,故必须显式装,否则 GTK/Qt 应用无法用 fcitx5)。逐个探测候选(仿 `_ghostty_apt_available` 的 `apt-cache policy`),缺失的跳过并 `log_warn`,不让整笔事务失败(包名跨 Ubuntu 版本可能微调)。
- **框架选择**:以普通用户跑 `im-config -n fcitx5`(写 `~/.xinputrc`,Ubuntu 御用的 IM 框架选择器,X11 会话经 `Xsession.d` 据此设置)。用户态、非交互。
- **环境变量(受管文件)**:写 `~/.config/environment.d/ubuntu-setup-rime.conf`(systemd 用户环境,GNOME/KDE 的 Wayland 与 systemd 图形会话读取):

  ```
  GTK_IM_MODULE=fcitx
  QT_IM_MODULE=fcitx
  XMODIFIERS=@im=fcitx
  ```

  这是**本 kit 100% 拥有**的受管文件(整写、收敛、写前 `backup_file`)。需重新登录生效——`install`/`configure` 如实提示。
- **自启动**:apt 装的 fcitx5 自带 `/etc/xdg/autostart/org.fcitx.Fcitx5.desktop`,登录即自启,无需我们再写 autostart;`status` 顺带探测确认。

## 3. RIME 配置模型(收敛 + 可逆)

仿 ghostty/tmux 的「偏好库 → 受管文件」收敛模型:

- **偏好库**:`~/.config/ubuntu-setup/rime.conf`(KEY=VALUE)。键:`FRAMEWORK`(固定 `fcitx5`)、`SCHEMAS`(空格分隔的启用方案,首个为默认)、`PAGE_SIZE`(候选词个数,5–10)、`RIME_ICE`(0/1)。
- **受管 RIME 文件**(写前 `backup_file`,整写,文件头注明「由 ubuntu-setup 生成,勿手改,改用 `swkit rime configure`」):
  - `~/.local/share/fcitx5/rime/default.custom.yaml` —— patch `schema_list`(启用方案,按 `SCHEMAS` 顺序)与 `menu/page_size`。RIME 把 `*.custom.yaml` 当作 patch 合并到内置默认之上,`default.custom.yaml` 正是预期的用户 patch 入口,故由我们拥有(带 backup)是正解。
  - **rime-ice 启用时**:不写 `schema_list`(交给 rime-ice 自带 `default.yaml` 管理,避免冲突),只保留 `menu/page_size` patch。
- **home 解析**:仿 `_ghostty_resolve_home`——`EUID==0 && SUDO_USER` 时**拒绝**(配置须用户态),否则用 `SUDO_USER`/`id -un` 解析真实 home。

### curated 输入方案(本地 i18n 表 `RIME_I18N`,en/zh/ja,**方案名不译**)

`fcitx5-rime`/`rime-data` 内置、零额外下载即可用:

| key | 一行说明(示意) |
|---|---|
| `luna_pinyin_simp` | 朙月拼音 · 简体输出 |
| `luna_pinyin` | 朙月拼音 · 繁简随词库 |
| `luna_pinyin_fluency` | 语句流(整句拼音) |
| `double_pinyin_flypy` | 小鹤双拼 |
| `double_pinyin` | 自然码双拼 |
| `bopomofo` | 注音 |
| `wubi86` | 五笔 86 |
| `wubi_pinyin` | 五笔·拼音混合 |
| `cangjie5` | 仓颉五代 |
| `stroke` | 五笔画(笔顺) |
| `terra_pinyin` | 地球拼音(带声调) |

外加「任意方案」:`add-schema <name>` 接受任意已存在于共享数据目录的方案 id(仿 `tmux add-plugin` 的「curated + 任意」)。

### 雾凇拼音 rime-ice(opt-in,纯用户态、无 sudo)

第三方配置仓 `iDvel/rime-ice`(GitHub),开箱带大词库 / 智能纠错 / 英文混输。设计为**清单式可逆安装**:

1. `git clone --depth 1` 到 kit 自管克隆目录 `~/.local/share/ubuntu-setup/rime-ice/`(需 `git`,缺则 `log_err` 指向 `swkit git install`)。
2. 把克隆内容**复制**(非软链,RIME 要真实文件)进 RIME 用户目录,并把所装的顶层路径记入清单 `~/.config/ubuntu-setup/rime-ice.manifest`。覆盖前对将被覆盖的同名用户文件 `backup_file`。
3. 置 `RIME_ICE=1`,重写受管 `default.custom.yaml`(去掉 `schema_list` patch),触发 deploy。
4. `remove-rime-ice`:按清单**精确删除**装入 RIME 目录的那些路径(不碰清单外的用户文件)+ 删克隆 + 置 `RIME_ICE=0` + 重写 `default.custom.yaml`(恢复内置 `schema_list`)+ deploy。
5. (隐含 `update`:克隆里 `git pull` 后重跑复制——可后续追加,首版可不做以收敛范围。)

## 4. 重新部署(deploy)

任何配置改动后 RIME 需「重新部署」才生效。fcitx5 路径:若 fcitx5 在跑则 `fcitx5-remote -r`(重载,会触发 RIME deploy);否则提示在托盘点「重新部署」或下次登录生效。**headless/SSH:** no-op + 诚实提示(此处无图形会话)。`deploy` 既是独立 op,也被 `configure`/方案改动/rime-ice 动作在末尾调用。

## 5. 接口(契约)

```
meta: key=rime name=RIME category=common
      ops=install,remove,configure,deploy,install-rime-ice,remove-rime-ice
```

- `status` —— 退 0 当且仅当 `fcitx5-rime` 已装(`pkg_installed`)。打印:fcitx5 版本、rime 引擎已装、当前框架(读 `im-config` / `~/.xinputrc`)、启用方案、rime-ice 是否在用、autostart 是否就位。
- `do_install` —— `status` 闸门;装核心 + best-effort 前端;`im-config -n fcitx5`;写 env.d 受管文件;`mkdir -p` RIME 用户目录并写出基线 `default.custom.yaml`(默认方案:`luna_pinyin_simp luna_pinyin`,`page_size=5`);末尾 `_rime_where_note` + 重新登录提示。幂等。
- `do_remove` —— **保守**:仅 `apt_remove fcitx5-rime`(本脚本主体即 RIME 引擎),**保留** fcitx5 核心、env.d、`im-config` 选择与用户 RIME 数据(避免误伤用户其他 fcitx5 引擎)。打印如何彻底卸载 fcitx5 的指引。幂等。
- `do_configure` —— 应用 flags 到偏好后整体重写受管文件并 deploy。**无参 = 保守基线**(启用 `luna_pinyin_simp luna_pinyin`、`page_size=5`,不强制 deploy 之外的动作);`--recommended` = 简体拼音优先 + `page_size=8` + deploy。flags:`--recommended`、`--schemas "a b c"`、`--default-schema <name>`、`--page-size <5-10>`、`--deploy`。
- 带参动作(经 `kit_dispatch` 路由 `do_<op>`,**不进 meta.ops**,且在 `ui()` 里交互可达):`add-schema <name>`、`remove-schema <name>`、`set-default-schema <name>`。
- `deploy` / `install-rime-ice` / `remove-rime-ice` —— 无参,进 meta.ops。

## 6. `ui()`(bespoke,仿 zsh/tmux)

`ui_supported` 否则 `ui_default_menu`。分组(视口可滚):

- **Engine / Framework**:安装/移除状态徽标、框架(fcitx5)、env.d 状态;行内 install/remove。
- **Schemas**:curated 方案勾选(空格切启用)、`d` 设为默认、`a` 加任意方案。
- **Options**:`page_size` 输入(`ui_input`)。
- **rime-ice**:install / remove 行(状态徽标)。
- **Actions**:`Deploy now`、`Apply recommended setup`。

每个状态变更经 `ui_run "<标题>" -- "$0" <op> [args]`(退屏、可见输出 + 日志、回屏重载)。顶部若检测到 SSH 显示一行诚实提示。

## 7. 安全 / 契约一致性

- 一切提权/包/文件经 lib helper:`apt_install`/`apt_remove`/`backup_file`/`sudo_run`(本脚本几乎只在 apt 时间接用到);**无裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`**。
- `im-config -n`、env.d、RIME 配置、rime-ice clone/copy **全程用户态、无 sudo**(`fonts.sh` 同款纯用户态纪律)。
- 幂等:`install`/`remove`/`install-rime-ice`/`remove-rime-ice` 都先探活后收敛;受管文件整写收敛(`cmp` 相同则不动,仿 `_ghostty_save`);改任何文件前 `backup_file`;清单式精确移除。
- fail-fast、不回滚(重跑即补救);`meta.ops` 恰列实现的无参 op,**不含 `ui`**;`category=common`。
- i18n:`RIME_I18N` 表(en/zh/ja),方案/插件名不译,符合项目规则。

## 8. 校验

- `bash -n scripts/rime.sh`
- `shellcheck -x --source-path=SCRIPTDIR scripts/rime.sh`
- `scripts/rime.sh meta`(字段齐、`ops` 与实现一致、不含 `ui`)、`status`(可独立跑)、`help` 不炸、`ui` 在无 TTY 打印指引退 0。
- 伪终端冒烟:`printf 'q' | TERM=xterm-256color script -qec 'scripts/rime.sh ui' /dev/null`。
- 文档:更新 `CLAUDE.md` 的脚本清单段(把 rime 与 ghostty/tmux 并列描述)与 `README.md`。

## 9. 明确不做(YAGNI)

- 不做 ibus 分支(用户选了 fcitx5)。
- 不深度管理每方案 patch(模糊音 / emoji / 简繁过滤器逐项)——简繁经「选 `luna_pinyin_simp` vs `luna_pinyin`」达成,够用且零风险;细粒度 patch 留给用户用 `fcitx5-config-qt` / 直接编辑。
- 不做 rime-ice 的 `update`(首版);不碰系统级 `/etc/environment`、不写 NOPASSWD。
- fcitx5 经典 UI 主题(候选框外观)属 fcitx5 而非 RIME,首版不纳入(可后续在本脚本或单独 fcitx5 脚本扩展)。
