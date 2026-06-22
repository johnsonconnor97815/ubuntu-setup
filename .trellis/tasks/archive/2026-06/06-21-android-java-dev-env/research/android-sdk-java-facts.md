# 调研笔记:Android SDK / Java 工具链事实(带来源)

核实时间 2026-06。这些是 `design.md` 的事实地基;凡版本/外部状态敏感者,实现时按 design.md 的「不硬编码、动态解析」原则处理,本笔记只留**来源可追溯的快照**。

## Java / OpenJDK

- **AGP↔JDK**:AGP 8.x 至 9.0.1(2026-01)全要 **JDK 17**(最低=默认);Gradle 支持 JVM 17–26。来源:developer.android.com/build/releases(AGP 9.0.1、8.13.0 release notes)、/build/jdks、docs.gradle.org compatibility。→ 兼容阈值定 **17**。
- **`sdkmanager` 的 JDK**:先认 `JAVA_HOME`、否则回退 PATH `java`;新版支持 JDK 11+。来源:developer.android.com/tools/sdkmanager + sdkmanager 启动脚本(android.googlesource.com,`if [ -n "$JAVA_HOME" ]…else JAVACMD="java"`)。→ gate 用 `JAVA_HOME=…` env 前缀即可非侵入覆盖。
- **现代 OpenJDK 单一 home**:17/21 是单一 `/usr/lib/jvm/java-<N>-openjdk-<arch>`,`bin/` 同含 `java`+`javac`,**无 `jre/` 子树**(de-modularized)。来源:packages.ubuntu.com noble `openjdk-21-jdk-headless` filelist;askubuntu 目录树。→ `home` 推导 `readlink -f`/glob 安全;`-jdk-headless` 含编译器,够 Android 构建。
- **`update-alternatives` 不分组**:apt OpenJDK 把 `java`/`javac`/`jar`/`jarsigner`/`javadoc`/`keytool`/`jshell`… 注册为**独立**链;只 `--set java` 会留 `javac` 指向别 JVM(askubuntu #1187136 实例:java=8 而 javac=11)。`update-java-alternatives` 读 `/usr/lib/jvm/.*.jinfo` **分组**切。来源:Ubuntu/Debian manpage(update-alternatives / update-java-alternatives);Debian #825987(headless `.jinfo` 历史坑)。→ `set-default` 用分组切 + headless 兜底枚举 + 切后断言 `java`/`javac` 同版本。

## Android SDK(命令行)

- **无 apt 包**:SDK 只能官方 zip + `sdkmanager`。`cmdline-tools` 必须落 `$ANDROID_HOME/cmdline-tools/latest/`。来源:developer.android.com/tools/sdkmanager;actions/runner-images install-android-sdk.sh。
- **env 变量**:`ANDROID_HOME` 是**现行规范**,`ANDROID_SDK_ROOT` **已弃用但兼容**(若 `ANDROID_SDK_ROOT` 未定义则用 `ANDROID_HOME`)。来源:developer.android.com/tools/variables;NixOS/nixpkgs #448975(2025-10「ANDROID_HOME is not actually deprecated, ANDROID_SDK_ROOT is」)。→ 两个都写、注释写明、别误删 `ANDROID_HOME`。
- **许可**:`sdkmanager --licenses`(headless `yes |`)一次接受**多份**协议(android-sdk-license、android-sdk-preview-license、mips/arm、googletv、gdk 等),hash 落 `$ANDROID_HOME/licenses/`。来源:developer.android.com/tools/sdkmanager;真实 headless 运行落盘的 license 文件名。→ 许可作显式 op、不隐式进 install。
- **`repository2-*.xml` 解析**(核实 live `dl.google.com/android/repository/repository2-1.xml`):
  - `<url>` **相对**(如 `commandlinetools-linux-15641748_latest.zip`,无 scheme/host)→ 须前缀 repository base。
  - `<checksum>` **裸 SHA-1**(40 hex、**无 `type` 属性**、全文无 64-hex sha256)→ `sha1sum` 无条件校验(未来按长度兜底)。
  - `<url>`/`<checksum>`/`<size>` 同处一个 `<complete>` 块;XML 并列**多修订** + **linux/mac/win 三套** archive(背靠背)→ 须块作用域解析(host-os=linux、最新修订),非独立 `grep|head -1`。
  - 实测块样例:`<size>174244366</size><checksum>63523a02…</checksum><url>commandlinetools-linux-15641748_latest.zip</url>`。
- **`SDK_TEST_BASE_URL`**:sdkmanager **进程内**读、覆盖整个下载根(repository2-N.xml + 包 zip),须以 `/` 结尾。**不影响** kit 在 sdkmanager 存在前自己 curl 的 bootstrap zip。Google 索引**无签名、SHA1**,镜像换包同时能换 checksum(无独立信任锚;f-droid 的签名 transparency-log 才有独立锚)。来源:android.googlesource.com sdk 源(`%srepository2-%d.xml`、`SDK_TEST_BASE_URL` 替换逻辑);f-droid android-sdk-transparency-log / sdkmanager 替代实现说明。
- **镜像可用性**:**TUNA(清华)不镜像 Android SDK**(版权:「Android SDK 因版权原因,不能提供镜像服务」,其 `/android/` 是 Studio IDE + AOSP git);**腾讯**(`mirrors.cloud.tencent.com/AndroidSDK/`)、**USTC**(`mirrors.ustc.edu.cn/android/repository/`)、**阿里**托管 repository2 布局。system-images 各镜像常不全。来源:mirrors.tuna.tsinghua.edu.cn/help/AOSP/;各镜像站目录核实。→ 预设删 tsinghua,留 tencent/ustc/aliyun,默认直连。
- **emulator/headless/arch**:emulator 需 `/dev/kvm`(x86 加速)+ `libgl1`/X 库,非 headless 构建路径;无 KVM 仅软件慢路径,headless 用需 `-no-window`;system-image ABI 须配主机(x86_64↔x86_64、arm64↔arm64-v8a)。**Google Linux SDK 原生件(adb/aapt2/emulator/NDK)仅 x86_64**,arm64 主机会 `exec format error`(JAR 类 sdkmanager 仍能在 JVM 上跑)。来源:developer.android.com「Configure hardware acceleration」(2026-03);Commit451/android-arm-build-tools、nixpkgs #430486(aapt2 ELF x86-64)。

## 用法
本笔记是 design.md 的来源支撑;实现/质检时若需复核某条事实,按上面来源联网再确认(facts 可能随时间漂移,尤其 AGP/build-tools/cmdline-tools 版本号——一律动态解析,不硬编码)。
