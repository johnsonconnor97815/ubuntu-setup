# 执行计划

实现顺序铁律:**先 `java.sh`(被依赖方)后 `android.sh`(依赖方)**——`android` 的 gate 要调 `java.sh home`,Java 先就位才能端到端验联动。

## 阶段 1 — `scripts/java.sh`

- [ ] `cp scripts/TEMPLATE.sh scripts/java.sh`,填 `meta`(key=java,category=runtime,ops=`install,remove,configure`,desc)。
- [ ] `JAVA_I18N`(en/zh/ja)+ `_java_t`(照 `node.sh`/`go.sh`)。
- [ ] helper:`_java_user_guard`(拒 sudo 包裹、`SUDO_USER`+`getent` 解析 home)、`_java_rc_file`(同 `_go_rc_file`)、`_java_valid_version`(`^[0-9]+$`)、`_java_apt_available`(`LC_ALL=C apt-cache policy openjdk-<N>-jdk-headless`)、`_java_jvm_home <N>`(fs glob `/usr/lib/jvm/java-<N>-openjdk-$(dpkg --print-architecture)` + 验 `bin/javac`,回退解析 `update-alternatives --query java` 候选段)。
- [ ] `status`(`pkg_installed` 任一受管 JDK;`KIT_PROBE_ONLY` 早返;否则 `default <N> · jdks <N>`)。
- [ ] `do_install`(基线 JDK 17:`apt_install openjdk-17-jdk-headless` → `do_set_default 17` → `do_ensure_java_home on`)。
- [ ] `do_remove`(`apt_remove` 全部受管 JDK + 清 JAVA_HOME 行 + 复位 alternatives)。
- [ ] 带参 `do_add_version`/`do_remove_version`(卸默认且有存活→改指+重生成 JAVA_HOME;卸空→清行)/`do_set_default`(`update-java-alternatives --set` 分组切,headless 兜底枚举各链,**切后断言 `java`/`javac` 同版本、不一致 fail-fast**)/`do_ensure_java_home <on|off>`(`go.sh do_ensure_path` 范式)。
- [ ] `do_home [<N>]`(**stdout 仅路径、诊断走 stderr、零 JVM**;无参走 `/etc/alternatives/java`,带参走 `_java_jvm_home`)。
- [ ] `do_configure`(无参=确保 17+默认+JAVA_HOME;`--recommended`/`--default`/`--ensure-java-home`/`--full-jdk`)。
- [ ] `ui`(组件管理界面:版本勾选/`d` 设默认/`a` 加/JAVA_HOME 开关/Apply recommended;`ui_run` 跑每个变更)。
- [ ] `usage`。

## 阶段 2 — `scripts/android.sh`

- [ ] `cp scripts/TEMPLATE.sh scripts/android.sh`,填 `meta`(key=android,category=runtime,ops=`install,remove,configure,accept-licenses,purge`,desc)。
- [ ] `ANDROID_I18N`+`_android_t`。
- [ ] helper:`_android_user_guard`、`_android_rc_file`、`_android_home`(默认 `~/Android/Sdk`、解析真实 home)、`_android_arch`(`dpkg --print-architecture`→abi)、`_android_in_ssh`/`_android_no_kvm`(`/dev/kvm` 可读写探测)、`_android_resolve_cmdline_zip`(块作用域 awk 解析 repository2 XML 取 linux 最新 `<url>`相对+`<checksum>`+`<size>`)、`_android_verify_zip`(size+`sha1sum`)、`_android_mirror_base`(预设 tencent/ustc/aliyun + rc 读)、`_android_valid_pkg`(grammar 校验)、`_android_valid_mirror`(拒 shell 元字符+`^https?://.*/$`)。
- [ ] `_android_java_gate`(经 `$KIT_SCRIPTS_DIR/java.sh` 找 ≥17:默认≥17 用之;默认旧但装了→`JAVA_HOME=$(java.sh home <N>)`**判非空**;全无→指路退非 0 不自动装)。**任何 sdkmanager JVM spawn(含 `--list`)前调它**。
- [ ] `_android_sdkmanager`(包装:gate → `JAVA_HOME=… SDK_TEST_BASE_URL=… "$sdkmanager"`)。
- [ ] `status`(cmdline-tools 在?`KIT_PROBE_ONLY` 早返;否则扫 fs 组件计数 + Java 兼容横幅[**只读、不调 gate、零 JVM**];无 JDK 显示「工具在缺 Java」)。
- [ ] `do_install`(序:ensure curl/unzip → resolve+下载+**校验**+解压 cmdline-tools〔无 Java〕→ gate → sdkmanager platform-tools;`--accept-licenses` 才接受许可,否则放好工具+提示前置链)。
- [ ] `do_accept_licenses`(gate → `yes | sdkmanager --licenses`,披露+URL+回显 id)。
- [ ] `do_remove`(保守:删 env 块+kit 装 cmdline-tools,保留数据,打印彻底删指引)。
- [ ] `do_purge`(`_android_user_guard` + 路径校验 + `rm -rf "${ANDROID_HOME:?}"`;ui 二次确认)。
- [ ] 带参 `do_add_package`/`do_remove_package`/`do_add_platform`/`do_remove_platform`(经 `_android_sdkmanager`,包串校验)、`do_set_mirror`(校验+写受管 rc 行)。
- [ ] `do_configure`(无参=保守;`--recommended`=动态解析最新 platform/build-tools + emulator〔非 headless〕;`--accept-licenses`/`--mirror`/`--ensure-path`)。
- [ ] emulator/arm64/SSH 诚实披露贯穿 install/选 emulator/status。
- [ ] `ui`(组件勾选两区 + Java 横幅 + 装 Java 17 行[`ui_run -- java.sh install`] + 镜像/许可/purge)。
- [ ] `usage`。

## 阶段 3 — 文档同步

- [ ] **CLAUDE.md**:种子集脚本列表加 `java`/`android`;新增两段要点(同 go/python 段密度)。
- [ ] 各脚本头注释 + `usage` + `meta.desc` 一致。

## 校验命令(每脚本写完即跑)

```bash
for f in scripts/java.sh scripts/android.sh; do bash -n "$f"; done
shellcheck -x --source-path=SCRIPTDIR scripts/java.sh scripts/android.sh   # 零告警
scripts/java.sh meta     # ops=install,remove,configure;不含 ui/带参 op
scripts/android.sh meta  # ops=install,remove,configure,accept-licenses,purge
scripts/java.sh help; scripts/android.sh help            # 不炸

# status 装前退非 0(捕获退出码断言):
for s in java android; do scripts/$s.sh status; rc=$?; [ $rc -ne 0 ] && echo "OK $s 装前非0" || echo "FAIL $s 装前应非0"; done
# KIT_PROBE_ONLY 与全量退出码一致(装前/装后各跑一次):
for s in java android; do scripts/$s.sh status >/dev/null 2>&1; a=$?; KIT_PROBE_ONLY=1 scripts/$s.sh status >/dev/null 2>&1; b=$?; [ $a -eq $b ] && echo "OK $s parity" || echo "FAIL $s parity($a/$b)"; done

# ui 无 TTY 退 0;伪终端冒烟两脚本都跑(交互可能不退 → timeout 包裹,见记忆 ui-smoke-test-hang):
for s in java android; do timeout 10 bash -c "printf 'q' | TERM=xterm-256color script -qec 'scripts/$s.sh ui' /dev/null" || true; done

# 单向性:java.sh 不得 shell-out 到 android(收紧到调用形,放过注释里提及文件名):
grep -nE 'KIT_SCRIPTS_DIR[^\n]*android|["'"'"' ]\./?(scripts/)?android\.sh' scripts/java.sh && echo "FAIL: java 调用了 android" || echo "OK 单向"
# tsinghua 不在 android 镜像预设(只查预设表/数组,放过解释性注释):
grep -nE 'ANDROID_MIRROR|MIRROR_(ORDER|PRESET)' scripts/android.sh | grep -i tsinghua && echo "FAIL: tsinghua 在预设" || echo "OK 无 tsinghua 预设"

# 装后(过用户评审 + task.py start + 实装后)复跑:status 退 0、java/javac 同版本等(见 prd 验收项)。
```

## 风险文件 / 回滚点

- 改 **CLAUDE.md**(阶段 3)——纯文档,git 可回滚。
- 两脚本为**新增文件**,不动既有脚本/lib;`swkit` 直指 clone,改完即生效。
- 全程幂等无回滚,补救=重跑;`backup_file` 是配置/rc 的唯一撤销。

## task.py start 前的 follow-up

- [ ] `prd.md` 验收项可测(已具备);`design.md`/`implement.md` 齐(complex 任务要求)。
- [ ] `implement.jsonl`/`check.jsonl` 填入相关 `.trellis/spec/` 清单(供 sub-agent 自动加载)。
- [ ] 用户评审 `prd.md`/`design.md` 通过后才 `task.py start`(用户已选「评审后实现」)。
