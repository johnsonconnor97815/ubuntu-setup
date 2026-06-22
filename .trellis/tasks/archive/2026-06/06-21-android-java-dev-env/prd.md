# Android dev environment + Java runtime scripts

## Goal

为 ubuntu-setup 新增**两个联动的 `runtime` 脚本**:

- **`scripts/java.sh`(key=`java`)** —— OpenJDK 的安装与多版本管理器(apt 渠道)。
- **`scripts/android.sh`(key=`android`)** —— headless Android SDK 工具链(`cmdline-tools`+`sdkmanager` 驱动)的安装与组件管理器。

两脚本**单向联动**(`android→java`):Android 的 `sdkmanager`(JVM)操作需一个兼容 JDK(≥17),由 `java.sh` 提供;缺则指路 `swkit java install`,绝不自动装。

用户价值:在全新 Ubuntu(含 Server/SSH/无桌面)上一键得到可命令行构建 Android 的工具链 + 受管的多版本 JDK,符合 kit 既有安全/幂等/实时观测契约。

## Confirmed facts(已核实,不再询问)

- AGP 全系(8.x–9.0.1 / 2026-01)要 **JDK 17**(最低=默认);Gradle 支持 JVM 17–26;`sdkmanager` 认 `JAVA_HOME` 后认 PATH `java`、支持 JDK 11+。
- Android SDK **无 apt 包**;`cmdline-tools` 经官方 zip 解压到 `$ANDROID_HOME/cmdline-tools/latest/`;env 用 `ANDROID_HOME`(**现行规范**)+ `ANDROID_SDK_ROOT`(**已弃用但兼容**);许可经 `sdkmanager --licenses`(headless `yes |`),hash 落 `$ANDROID_HOME/licenses/`。
- `repository2-*.xml` 的 `<url>` 为**相对路径**,`<checksum>` 为**裸 SHA-1**(40 hex、无 `type` 属性、无 sha-256)、与 `<size>` 同处一个 `<complete>` 块;同文件并列多修订与 linux/mac/win 三套 archive。
- `SDK_TEST_BASE_URL` 仅被 sdkmanager 进程读、覆盖整个下载根(须以 `/` 结尾),**不影响** kit 自己 curl 的 bootstrap zip。
- 清华(TUNA)**不镜像** Android SDK(版权);可用镜像:tencent/ustc/aliyun。
- 现代 OpenJDK 17/21 单一 home(`bin/` 同含 `java`+`javac`、无 `jre/` 子树);apt 把各工具注册为**独立** alternatives 链(非分组),`update-java-alternatives` 才分组切。
- 项目契约(来自 `.trellis/spec/`、CLAUDE.md):逐命令 sudo 经 `sudo_run`、非交互 apt、改前 `backup_file`、`grep -qxF` 幂等、`status` 只读 + `KIT_PROBE_ONLY`、`ui` 非 op、带参 op 经 `kit_dispatch` 路由到 `do_<op>`、i18n en/zh/ja(名不译)。

## Requirements

### R1 `scripts/java.sh`
- 渠道 apt OpenJDK;curated **{17,21}** + `add-version <N>`(`^[0-9]+$` 校验 + `LC_ALL=C apt-cache` 探测);默认包 `-jdk-headless`(`--full-jdk` 选完整)。
- `set-default <N>` 经 `update-java-alternatives` **分组切**(headless 兜底枚举各链),切后断言 `java`/`javac` 同版本再写 JAVA_HOME。
- 受管 `JAVA_HOME` rc 行(go.sh `do_ensure_path` 范式);`home [<N>]` 查询 op:默认走 `/etc/alternatives/java`,**非默认走 fs glob** `/usr/lib/jvm/java-<N>-openjdk-$(dpkg --print-architecture)` + 验 `bin/javac`,**只读不 spawn JVM**,**只把路径打到 stdout**(诊断走 stderr)。
- `install` 基线=JDK 17;**纯 JDK**(不碰 Maven/Gradle)。`remove` 整体卸 + 清 env;`remove-version <N>` 粒度(卸当前默认且有存活版本时改指 + 重生成 JAVA_HOME,卸空才清行)。
- `meta.ops`=`install,remove,configure`;带参路由 op:`add-version`/`remove-version`/`set-default`/`ensure-java-home`/`home`。

### R2 `scripts/android.sh`
- `$ANDROID_HOME=~/Android/Sdk`(用户态、可覆盖、显式);env 受管块写 `ANDROID_HOME`+`ANDROID_SDK_ROOT`(注释写明弃用关系)+ PATH(`cmdline-tools/latest/bin`、`platform-tools`、`emulator`)。
- bootstrap 序:`apt_install curl unzip` → 块作用域解析 repository2 XML 取 linux 最新修订的 `<url>`(相对、拼 base)/`<checksum>`/`<size>` → **`sha1sum`+size 校验后**解压到 `cmdline-tools/latest/`(无需 Java)→ Java gate → sdkmanager。无 JDK 也先放好 cmdline-tools、`status` 显示「工具在、缺 Java」。
- `install`=cmdline-tools+platform-tools(**许可不隐式**,见 R4);`--recommended`=+最新 platform/build-tools(`sdkmanager --list` 动态解析)+emulator(**检测到 headless/无 `/dev/kvm` 则剔除 emulator**)。
- curated 组件全 opt-in 勾选:platforms/build-tools/emulator/system-images/ndk/cmake/scrcpy(apt);`add-package <pkg>` 任意(grammar `^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$` 校验)。**读=扫 `$ANDROID_HOME` fs 零 JVM、绝不调 gate**;**写=任何 sdkmanager JVM spawn 过 gate**。
- 镜像 opt-in 默认直连:`SDK_TEST_BASE_URL` 预设 **tencent/ustc/aliyun(无 tsinghua)**+任意 URL(`set-mirror` 校验拒 shell 元字符、要求 `^https?://.*/$`;非默认时打信任披露);bootstrap zip 显式拼镜像 base + 404 回退直连。
- `remove` 保守(删 env 块+kit 装的 cmdline-tools、保留下载数据、打印彻底删指引);`purge` 破坏性(`rm -rf`,前置 `_android_user_guard` + 路径校验[非空/绝对/真实 HOME 下/非 `/`/非 HOME/非软链/`${VAR:?}`]+ui 二次确认;AVD 不动)。
- emulator/arm64/SSH 诚实披露(同 ghostty/rime);system-image ABI 默认对齐 `dpkg --print-architecture`。
- `meta.ops`=`install,remove,configure,accept-licenses,purge`;带参路由 op:`add-package`/`remove-package`/`add-platform`/`remove-platform`/`set-mirror`。

### R3 联动(单向 `android→java`)
- `java.sh` 暴露 `home [<N>]` 作 API;`java.sh` 内**不得**出现 `android.sh` 引用(grep 强制)。
- `_android_java_gate`(任何 sdkmanager JVM spawn 前,**含 `--recommended` 的 `sdkmanager --list`**):经 `$KIT_SCRIPTS_DIR/java.sh` 找兼容 JDK≥17;默认≥17 直接用;默认旧但装了≥17→**仅本次** `JAVA_HOME="$(java.sh home <N>)" sdkmanager …`(进程局部、不动全局默认、**home 须判非空**);全无≥17→gate 指路 `swkit java install`、退非 0、**不自动装**。
- `android.sh status()`(含 `KIT_PROBE_ONLY`)绝不调 gate;Java 兼容横幅只由 `java.sh` 只读信号算(`pkg_installed`/`home`),零 JVM。
- ui() 顶部 Java 状态横幅 + 一行「装 Java 17」动作走 `ui_run -- "$KIT_SCRIPTS_DIR/java.sh" install`(退备用屏让 sudo 输密);headless 仅 gate。

### R4 许可(显式,不隐式)
- 独立 op `accept-licenses`;交互 `ui_confirm`+条款 URL;headless 需 `install --accept-licenses` 或单跑 `accept-licenses`,不带 flag 时放好 cmdline-tools 并提示完整前置链 `swkit java install` → `accept-licenses` → 装 platform-tools;接受时回显具体 license id。

### R5 集成与同步
- 两脚本 `category=runtime`,经 TUI catalog 的 `meta` 自动发现(**`bootstrap.sh` 不改**)。
- 各带 `JAVA_I18N`/`ANDROID_I18N`(en/zh/ja)+ `_java_t`/`_android_t`,名称不译。
- 实现后同步 **CLAUDE.md**(种子集脚本列表 + 两段要点)与各脚本头注释/`usage`/`meta.desc`;`java`/`android` 由通用 `ubuntu-install` skill 驱动,**无需改 skills、无需重跑 bootstrap**。

## Acceptance Criteria

- [ ] `bash -n scripts/java.sh scripts/android.sh` 通过;`shellcheck -x --source-path=SCRIPTDIR scripts/java.sh scripts/android.sh` 零告警。
- [ ] `java meta` 的 `ops`=`install,remove,configure`;`android meta` 的 `ops`=`install,remove,configure,accept-licenses,purge`;两者**不含** `ui` 及任何带参 op,且与实现一致。
- [ ] 两脚本 `help` 不炸;`ui` 无 TTY 打印指引退 0;伪终端冒烟渲染不崩、`q` 干净退出(交互不退则 `timeout` 包裹)。
- [ ] `status` 装前退非 0、装后退 0;`KIT_PROBE_ONLY=1` 与全量退出码一致、零 JVM spawn。
- [ ] 行为(java):`install`后 `java`/`javac` 同为 17;`add-version 21` 共存;`set-default 21` 后两者同为 21;`home 17`(21 为默认时)仍返回 17 home;`remove-version` 至空清 JAVA_HOME 行。
- [ ] 行为(android):无 JDK 机器 `install` 仍放好 cmdline-tools、status 显示「工具在、缺 Java」;装 17 后写 op 用之;默认 11 但装 17 时写 op 用 17 的 JAVA_HOME 且不改全局默认;bootstrap zip SHA-1/size 不符即中止;`purge` 拒空/`/`/`$HOME`/软链/sudo 包裹。
- [ ] 安全:`set-mirror` 拒 shell 元字符且要求 `^https?://.*/$`;`tsinghua` 不在 android 镜像预设;`java.sh` 无 `android.sh` 引用;版本/包串校验生效。

## Out of scope

- Android Studio IDE(另起 `android-studio` 脚本,用户选定)。
- Java 的 Maven/Gradle;Temurin/vendor 源 / SDKMAN(纯 apt)。
- 硬编码可装 JDK / API 级别 / build-tools 版本(实时探测/动态解析)。
- Android 自动装 Java;自动改 `qemu-kvm`/kvm 组/系统输入策略。
- 把 checksum 锚到 dl.google.com(`SDK_TEST_BASE_URL` 不可行)。

## Open questions

无。设计经一场 grilling(12 问)+ 两轮多代理对抗式审查(18 条校正 + 8 条复核修正)定稿,无阻塞规划的开放问题;详见 `design.md`。
