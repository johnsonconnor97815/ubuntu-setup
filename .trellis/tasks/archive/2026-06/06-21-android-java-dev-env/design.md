# 技术设计:`scripts/java.sh` + `scripts/android.sh`

来源:一场 `/grill-me` grilling(Q1–Q12)+ 两轮多代理对抗式审查 workflow(审查 #1 确认 18 条校正/驳回 12 条;审查 #2 复核 spec 本身、又修 8 条,含 1 条 high:repository2 `<checksum>` 实为裸 SHA-1)。本文件即权威蓝图,所有「〔审查校正〕」标注可追溯到审查发现。

## 架构与边界

- 两个独立的 `runtime` 脚本,各自 `source lib/common.sh`、定义 `meta`/`status`/`do_install`/`do_remove`/`do_configure`/`ui` + 带参 `do_<op>`,末尾 `kit_dispatch "$@"`。经 TUI catalog 的 `meta` 自动发现(**`bootstrap.sh` 不改**)。
- **依赖方向单向 `android → java`**(`java.sh` 不知道 `android` 存在,避免循环耦合,同 `claude`→`node`)。
- **范围**:`android.sh` 只做 headless SDK 工具链,**无 Android Studio**(Studio 是 GUI,日后单独 `android-studio`,key=`android-studio`;`~/Android/Sdk` 对齐 Studio 默认,两脚本天然收敛)。

### 共享安全姿态
- **逐命令 sudo,绝不整体 root**:`java.sh` 仅 `apt`(`apt_install`/`apt_remove`)与 `update-java-alternatives`/`update-alternatives` 经 `sudo_run`;`android.sh` 的 SDK 下载/解压/sdkmanager 流程**全程用户态**,只有少数条件性 apt 项经 `sudo_run`(缺失补 `curl`/`ca-certificates`/`unzip`、可选 `libgl1`、`scrcpy`)。
- **用户态守卫** `_java_user_guard`/`_android_user_guard`(范式同 `_go_user_guard`/`_py_user_guard`/`_mps_user_paths`:`EUID==0 && SUDO_USER` 拒绝并指路;经 `SUDO_USER`+`getent passwd` 解析真实 home,**绝不**信 `~`/`$HOME`)。
- **读/写分离**:`status`/`ui` 只读、零 JVM spawn;写操作改系统,Android 写过 Java gate。
- 幂等(`status` 闸门);改 rc/配置前 `backup_file`、追加前 `grep -qxF`。`ui` 是入口模式不进 `meta.ops`;带参 op 经 `kit_dispatch` 路由 `do_<op>`(连字符转下划线)。

---

## A. `scripts/java.sh`(key=`java`,category=runtime)

### 渠道与版本模型
- 渠道 = **apt OpenJDK**(第一梯队渠道,同 `go.sh`/`node.sh`;不加 vendor 源/不用 SDKMAN)。
- curated **{17, 21}**;8/11 等遗留版本走 `add-version <N>`。**不硬编码可装版本**——`_java_apt_available`(`LC_ALL=C apt-cache policy openjdk-<N>-jdk-headless`,按退出码/稳定文本判定)探测。
- 包 = **`openjdk-<N>-jdk-headless`**(默认,含 `javac` 全套、不拉 X/GUI);`configure --full-jdk` 选完整 `openjdk-<N>-jdk`。
- 状态实时由 `dpkg`+`update-alternatives --query java` 得出,**无 pref store**。

### 默认切换 〔审查校正:update-alternatives 不分组〕
apt OpenJDK 把每个工具(`java`/`javac`/`jar`/`jarsigner`/`javadoc`/`keytool`/`jshell`…)注册为**独立** alternatives 链。只 `--set java` 会留 `javac` 指向别的 JVM,坏掉 Android 构建。故:
- `set-default <N>` 优先 `sudo update-java-alternatives --set "java-1.<N>.0-openjdk-$(dpkg --print-architecture)"`(确切 id 从 `update-java-alternatives --list` 解析)。
- **headless 兜底**:若 `--list` 无该条目(`-jdk-headless` 可能未注册完整 `.jinfo`),回退枚举各链 `update-alternatives --list <name>` 逐个 `--set`。
- **写 JAVA_HOME 前断言** `java -version` 与 `javac -version` 主版本一致(不一致 fail-fast)。

### JAVA_HOME 受管行 + `home [<N>]` 查询 op
- 受管 rc 行(`go.sh` `do_ensure_path` 范式:`backup_file`+`grep -qxF`+`JAVA_HOME_MARKER`),指向当前默认 JDK home;切默认时重生成;`--ensure-java-home on|off`。
- **`home [<N>]`** = 对外查询 op(`android.sh` 消费的 API),**只读、不 spawn JVM**:
  - 无参/默认:`readlink -f /etc/alternatives/java` 去 `/bin/java` 两层。
  - **`home <N>`(非默认)〔审查校正:readlink 只给默认〕**:fs 探测——主 = glob `/usr/lib/jvm/java-<N>-openjdk-$(dpkg --print-architecture)`(验目录+`bin/javac`);回退 = 解析 `update-alternatives --query java` 的**逐候选 `Alternative:` 段**(非 `Value:`/`Best:`)找含 `java-<N>-openjdk` 的路径。
  - 命中**只把路径打到 stdout**(诊断/`log_*` 走 stderr,保证 `JAVA_HOME=$(java.sh home <N>)` 干净)、退 0;不存在退非 0。**绝不** `java -version`。
  - 现代 OpenJDK 17/21 单一 home(`bin/` 同含 `java`+`javac`、无 `jre/`),推导安全;`add-version` 写入的 JVM 目录命名须与 `home` 读回一致。

### op 面
| op | 形态 | 映射 | meta.ops? |
|----|------|------|-----------|
| `install` | 无参 | 装 JDK 17 + 设默认 + 写 JAVA_HOME | 是 |
| `remove` | 无参 | `apt_remove` 全部受管 openjdk JDK + 清 JAVA_HOME 行 + 复位 alternatives | 是 |
| `configure` | flag | 见下 | 是 |
| `add-version <N>` | 带参 | 校验+探测 → `apt_install openjdk-<N>-jdk-headless` | 否(路由) |
| `remove-version <N>` | 带参 | 卸单版本;卸当前默认且有存活则改指+重生成 JAVA_HOME;卸空才清行 | 否(路由) |
| `set-default <N>` | 带参 | `update-java-alternatives` 分组切 | 否(路由) |
| `ensure-java-home <on\|off>` | 带参 | 增删受管 JAVA_HOME 行 | 否(路由) |
| `home [<N>]` | 带参/无参 | 打印 JAVA_HOME(只读,stdout 仅路径) | 否(路由) |

- `install` 基线=仅 JDK 17;**纯 JDK**(不碰 Maven/Gradle)。`ops`=`install,remove,configure`。
- `configure` 无参=保守基线(确保 17+默认+JAVA_HOME);`--recommended`=17 为中心;flag:`--default <N>`/`--ensure-java-home`/`--full-jdk`。
- `<N>` 经 `_java_valid_version`(`^[0-9]+$`)校验后才拼包名/alternatives 路径(一致性/卫生;apt 经 `sudo_run "$@"` argv 数组,非 shell 注入)。

---

## B. `scripts/android.sh`(key=`android`,category=runtime)

### 位置与 env 受管块 〔审查校正:env 弃用关系〕
- `$ANDROID_HOME=~/Android/Sdk`(用户态、flag 可覆盖、始终显式)。
- env 受管**块**(begin/end 标记,同 `tmux.sh`;`backup_file`+保留块外内容):
  - `export ANDROID_HOME=$HOME/Android/Sdk` —— **现行规范变量**。
  - `export ANDROID_SDK_ROOT=$ANDROID_HOME` —— **已弃用但兼容**的别名;**注释写明此关系**(防将来误删现行的 `ANDROID_HOME`)。
  - PATH += `cmdline-tools/latest/bin`、`platform-tools`、`emulator`。
- 写哪个 rc:同 `go.sh` 的 `_*_rc_file`;`--ensure-path on|off`。

### bootstrap 序与完整性校验 〔审查校正:鸡生蛋 + zip 校验 + 解析要点〕
1. `have_cmd curl || apt_install curl ca-certificates`;`have_cmd unzip || apt_install unzip`。
2. **解析 + 下载(无需 Java)**:从 `repository2-*.xml` 取 `<url>`/`<checksum>`/`<size>`。解析要点(核实 live XML):
   - `<url>` 是**相对路径**,须前缀 repository base(默认 `https://dl.google.com/android/repository/`,或镜像 base)。
   - `<checksum>` 是**裸 SHA-1**(40 hex、无 `type`、无 sha-256);三元素须取自**同一 `<complete>` 块**——XML 并列多修订与 linux/mac/win,故**块作用域解析**(对 host-os=linux、最新修订的 `<complete>…</complete>` 跑 `awk`),**不能**三个独立 `grep|head -1`。
3. **强制校验后解压**到 `cmdline-tools/latest/`:先比 `<size>`,再 `sha1sum` 比 `<checksum>`(无需判 type;未来出现 64 hex 再按长度切 `sha256sum`),不符即删临时文件中止。该 zip 解压即执行、**无 dpkg 闸**(不同于 `.deb` 经 `apt_install` 由 dpkg 校验)。
4. **Java gate**(`_android_java_gate`)。
5. **sdkmanager 装 `platform-tools`**(+ 许可仅显式时)。
- **无 JDK 机器也先放好 cmdline-tools**(1–3 无需 Java),`status` 显示「工具在、缺 Java」,gate 在首个 sdkmanager 写处干净指路。

### install / `--recommended`
- `install`(无参)= cmdline-tools + platform-tools(**许可不隐式**);给可用 `sdkmanager`+`adb`。
- `--recommended` = + 最新稳定 `platforms;android-NN` + 匹配 `build-tools`(经 `sdkmanager --list` 动态解析、不硬编码)+ `emulator`(**检测到 headless/无 `/dev/kvm` 时剔除 emulator**)。

### 组件集(全 opt-in,curated≠默认装)
勾选清单 + `add-package <pkg>` 任意;读路径扫 fs 判已装:

| 组件 | 渠道 | 默认 |
|---|---|---|
| platform-tools | `platform-tools` | install 基线 |
| platforms | `platforms;android-NN` | `--recommended`/`add-package` |
| build-tools | `build-tools;X.Y.Z` | `--recommended`/`add-package` |
| emulator | `emulator` | `--recommended`(非 headless)/opt-in |
| system-images | `system-images;…;<abi>` | opt-in(ABI 对齐 `dpkg --print-architecture`) |
| NDK / CMake | `ndk;…` / `cmake;…` | opt-in |
| scrcpy | `apt_install scrcpy` | opt-in(sudo 项) |

- 读 = 扫 `$ANDROID_HOME/{platform-tools,platforms,build-tools,emulator,system-images,ndk,cmake,licenses}/`(纯 fs、零 JVM、**绝不调 gate**)。
- `add-package`/`remove-package` 包串经 grammar `^[A-Za-z0-9._-]+(;[A-Za-z0-9._-]+)*$` 校验;`add-platform`/`remove-platform` 的 `<N>` 按 `^[0-9]+$` 校验后拼 `platforms;android-<N>`(再走同一 grammar);`scrcpy` apt 名同样。

### 许可 〔审查校正:显式,Q12=A〕
- 独立 op `accept-licenses`(`yes | sdkmanager --licenses`,显著披露+条款 URL,回显具体 license id)。
- 交互(ui):`ui_confirm`+URL,显式 yes 才接受。
- headless:`install` **不**自动接受;需 `install --accept-licenses` 或先 `accept-licenses`;不带 flag 时放好 cmdline-tools、提示完整前置链 **`swkit java install` → `accept-licenses` → 装 platform-tools**(`accept-licenses` 本身要 spawn sdkmanager、过 Java gate,其 gate 失败消息也指向 `swkit java install`)。
- 状态:扫 `$ANDROID_HOME/licenses/`(fs、只读)。

### 镜像 〔审查校正:删 tsinghua / bootstrap zip / 信任披露 / URL 校验〕
- 机制 = `SDK_TEST_BASE_URL`(sdkmanager 进程内重写下载根)。
- curated 预设 = **tencent**(`mirrors.cloud.tencent.com/AndroidSDK/`)/ **ustc**(`mirrors.ustc.edu.cn/android/repository/`)/ **aliyun** —— **删 tsinghua**(TUNA 声明版权不镜像 SDK、其 `/android/` 是 Studio IDE+AOSP git、非 repository2;选它静默无包)。
- **bootstrap zip 镜像须显式拼接**:`SDK_TEST_BASE_URL` 对 kit 自己 curl 的 bootstrap zip 无效;设镜像时显式构造 `<mirror-base>/android/repository/commandlinetools-linux-*.zip` 并 404 回退直连。受管 rc 行仅影响后续 sdkmanager 拉取。
- 默认直连 `dl.google.com`(opt-in)。
- **信任披露 + URL 校验**:设非默认镜像打显著一行——镜像成为可执行代码来源,sdkmanager 用无签名 SHA1/同源索引,无独立信任锚(「钉 checksum 到 dl.google.com」不可行)。`set-mirror <名|url>` 按 `python.sh` 校验:拒 shell 元字符(`"`/反引号/`$`/反斜杠/换行)、要求 `^https?://.*/$`。
- 诚实提示:镜像可能滞后、system-images 常不全,失败可切直连/挂代理。

### remove / purge 〔审查校正:rm -rf 护栏〕
- `remove`(保守,同 `rime.sh`):删 env 块+kit 装的 cmdline-tools,**保留**已下载数据(可能与 Studio 共用),显著打印彻底删指引。
- `purge`(破坏性):`rm -rf "${ANDROID_HOME:?}"`,前置 `_android_user_guard`(拒 `EUID==0 && SUDO_USER`)+ 路径校验(非空、`realpath -m` 后绝对、严格在真实 `$HOME` 下、`≠/`、`≠$HOME`、原路径非软链);ui 强制 `ui_confirm`+Studio 警告;AVD 在 `~/.android/avd/` 不动。
- 组件级删(`remove-platform`/`remove-package`)走 `sdkmanager --uninstall`——需 Java、过 gate。

### emulator/arm64/headless 诚实披露 〔审查校正〕
- 选 emulator 时检测无 `DISPLAY`/`/dev/kvm` 不可读写,`log_warn`(i18n,同 ghostty/rime):emulator 是 GUI/加速组件,无 KVM 仅软件慢路径,headless 用需 `-no-window`,不在 headless 构建路径上。可选 `apt_install libgl1`;`qemu-kvm`/kvm 组只给指引。
- system-image ABI 默认 = `dpkg --print-architecture`,跨 ABI 警告。
- arm64 主机:Google Linux SDK 原生件(adb/aapt2/emulator/NDK)**仅 x86_64**,`status`/install 如实 `log_warn`。

### op 面
| op | 形态 | meta.ops? |
|----|------|-----------|
| `install`(`--accept-licenses`) / `remove` / `configure` | 无参/flag | 是 |
| `accept-licenses` / `purge` | 无参 | 是 |
| `add-package`/`remove-package`/`add-platform`/`remove-platform`/`set-mirror` | 带参 | 否(路由) |

`ops`=`install,remove,configure,accept-licenses,purge`。

---

## C. 联动契约(单向 `android → java`)

### `_android_java_gate`(任何 sdkmanager JVM spawn 前)〔审查校正:--list 也 gate〕
- **「写操作 gated」改述为「任何 sdkmanager JVM spawn 都 gated」**:`install`/`--uninstall`/`add-package`/`accept-licenses`/**`--recommended` 的 `sdkmanager --list`** 都先 `_android_java_gate || return 1`(同 `mattpocock-skills.sh` 连 `do_list` 都 gate)。gate 在 `--list` **之前**触发,让 kit 干净指路赢过 sdkmanager 原始 `die`。
- 逻辑:经 `$KIT_SCRIPTS_DIR/java.sh` 找兼容 JDK(**≥17**):
  - 默认 ≥17 → 用之。
  - 默认旧但装了 ≥17 → **仅本次** `JAVA_HOME="$("$KIT_SCRIPTS_DIR/java.sh" home <N>)" sdkmanager …`(env 前缀、进程局部、不动全局默认;sdkmanager 先认 JAVA_HOME)。
  - `home` 返回**须判非空**再用〔`export VAR=$(失败)` 在 errexit 下不中止、反而静默给空串〕。
  - 全无 ≥17 → gate:`log_err` 指路 `swkit java install`、退非 0、**绝不**自动装(同 node gate)。

### `status()` 绝不调 gate 〔审查校正:防每帧跨脚本 spawn〕
- `android.sh status()`(尤其 `KIT_PROBE_ONLY=1` 早返,镜像 `go.sh:162`)**只扫 `$ANDROID_HOME`**,绝不调 `_android_java_gate`/shell 到 `java.sh`。Java 兼容横幅只由 `java.sh` 只读信号算(`pkg_installed`/`java.sh home <N>` fs 探测),**绝不** `java -version`,故 probe 与全量两路径零 JVM、退出码恒一致。
- 单向性经评审强制:`java.sh` 内不得出现 `$KIT_SCRIPTS_DIR/android.sh`(grep 校验)。

### `ui()` 「装 Java 17」动作 〔审查校正:必须 ui_run〕
- ui() 顶部 Java 状态横幅(版本+兼容✓/✗,同 mattpocock 的 Node 横幅)。
- 缺失/不兼容时:**`ui_run "Install Java 17" -- "$KIT_SCRIPTS_DIR/java.sh" install`**(退备用屏让 sudo 密码提示落主屏;裸子壳会被备用屏重绘冲掉)。这是 AUTO-INSTALL DELEGATE 范式,但因需 sudo(不同于用户态 `fonts.sh`)**必须** `ui_run`。
- 状态重解析免费:ui() 每轮顶部重读横幅/重跑 gate(同 `zsh.sh`),装完翻到「默认≥17」分支。
- headless 仅 gate(指路、不装),匹配 `sudo_run` 的 `RC_NEED_SUDO` 与 node/codegraph GATE 先例。

---

## D. status 透明度与 `KIT_PROBE_ONLY`
- **`java.sh status`**:退 0 当且仅当至少一个受管 openjdk JDK 在(`pkg_installed`,cheap、零 JVM)。`KIT_PROBE_ONLY=1` 早返 boolean;否则追加 `default <N> · jdks <N>`。
- **`android.sh status`**:退 0 当且仅当 cmdline-tools 在(`$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager` 存在,纯 fs)。`KIT_PROBE_ONLY=1` 早返 boolean;否则追加组件计数+Java 兼容横幅(只读算法见 §C)。**全程零 JVM**。

## E. i18n 〔审查校正:项目铁律〕
- 各带 `JAVA_I18N`/`ANDROID_I18N`(en/zh/ja)+ `_java_t`/`_android_t`(同 `go.sh` `GO_I18N`+`_go_t`)。
- **名称不译**:JDK、`openjdk-<N>`、`java`/`javac`、`sdkmanager`、`platform-tools`、`build-tools`、`emulator`、`ndk`、`cmake`、`scrcpy`、`system-images`、ABI token。
- 覆盖:组件/版本说明、gate 横幅、许可披露、镜像信任披露、remove/purge 确认、emulator/arm64/SSH 提示、footer。

## 兼容性与文档同步
- **CLAUDE.md**:种子集脚本列表加 `java`/`android`;新增两段要点(同 go/python 段密度);带参 op 举例处点到新 op。
- 两脚本头注释 + `usage()` + `meta.desc` 与实现一致。
- **`bootstrap.sh` 无需改**(catalog 自动发现);**skills 无需改**(通用 `ubuntu-install` 驱动,无需重跑 bootstrap)。
- `.trellis/spec/` 编码规约**无需改**(两脚本遵循既有 scripts/lib 契约;若实现中发现新通用约定再经 `trellis-update-spec` 沉淀)。

## 重要取舍与被否方案(审查驳回,为决策背书)
- **镜像/`purge`/完整组件集「该砍」全被驳回**:`python.sh`(`set-index`/`remove-uv`)、`go.sh`、`zsh.sh`(`uninstall-omz`)早有同款先例,curated≠默认装,在范式内,**保留**。
- **认知纠错**:`export JAVA_HOME=$(java.sh home N)` 在 `set -Eeuo pipefail` 下**不会**中止(`export` 内建掩盖子替换失败),但会静默给空串 → gate 须判非空。
- 现代 OpenJDK 单一 home、`home` 跨脚本调用、env 前缀注入运行均为 kit 既有惯用法,无需新机制。

## 操作与回滚
- 全程幂等、fail-fast、无回滚——补救=重跑。改 rc/配置前 `backup_file`(时间戳副本即「撤销」)。
- 破坏性仅 `java remove`(apt remove 非 purge,保配置)与 `android purge`(多重护栏+ui 确认);`android remove` 默认保守保留 SDK 数据。
- 实现以纯拷贝部署(`swkit` 直指 clone),改完即生效;仅改 `skills/` 才需重跑 bootstrap——本任务不改 skills。
