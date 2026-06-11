# homebrew — Homebrew analytics install-on-request 365d

## 抓取过程

- 2026-06-10 直接 `curl -sL https://formulae.brew.sh/api/analytics/install-on-request/365d.json`（官方 API，文档 https://formulae.brew.sh/docs/api/）。
- 数据窗口 2025-06-11 ~ 2026-06-11，共 78,005 个 formula、100,959,585 次 install-on-request。
- 取榜单前 220 个 formula（多取 20 个补偿剔除量），逐条人工判读映射，最终保留 151 个 canonical 工具。
- 对个别看不出是什么的 formula（mole、mint、himalaya、unbound、watchman、kubeconform）追加 `api/formula/<name>.json` 查 desc 确认。

## 判读说明

**剔除类别**（约 60 个）：
- 纯库/依赖包：openssl@3、harfbuzz、glib、pango、boost、zlib、libpng、cairo、webp、libheif、nss、freetds、libxml2、libtiff、freetype、libffi、gobject-introspection、qt、numpy（纯 Python 库）、jpeg-xl、aom、gnutls、libpq、librsvg、libomp、ca-certificates、gettext、tcl-tk、zstd 保留（独立压缩 CLI）但 zlib 剔除。
- macOS 独占：mas、cocoapods、xcbeautify、xcodegen、xclogparser、xcresultparser、xcparse、applesimutils、idb-companion、memo（Apple Notes CLI）、mole（API desc 确认是 "Deep clean and optimize your Mac"）、colima（macOS 容器方案）、mint（Swift 工具包管理器）、swiftgen、sourcekitten。
- macOS 补 GNU 行为（Ubuntu 预装，无意义）：coreutils（榜 #9，964k！）、gnu-tar、gnu-sed、uutils-coreutils、uutils-findutils、telnet。
- 其他：hello（GNU 测试 formula，用户拿来验证 brew）、unbound（DNS 解析器，疑似依赖牵引非主动安装）。

**保留但带注**：swiftlint / swiftformat / fastlane（官方支持 Linux，用户群偏 macOS/iOS）；pkgconf→pkg-config、poppler、libtool、autoconf、automake（构建工具链，部分作依赖，按"拿不准保留"原则留下）；steipete/tap/gogcli（第三方 tap，未联网核实具体产品，evidence 已标注）。

**多版本合并**（metric 为合计）：
- python = python@3.9~3.14 六个 formula，合计 ~2.96M（单算 python@3.13 也有 761k）
- nodejs = node + node@22 + node@20，合计 ~2.94M
- openjdk = openjdk + @17 + @21 + @11，合计 ~1.03M
- postgresql = @14~@18 五个，合计 ~776k
- mysql = mysql + mysql@8.0 + mysql-client，合计 ~480k
- opencode = anomalyco/sst 两个 tap + core formula 三处同名，合计 ~767k（同一产品迁移 tap 所致）

**命名对齐**：kubernetes-cli→kubectl、awscli→aws-cli、llama.cpp→llama-cpp、supabase→supabase-cli、stripe→stripe-cli、mongodb-community→mongodb、fluxcd/tap/flux→flux、oven-sh/bun/bun→bun。llvm 保留为 llvm（formula 是完整工具链），clang 放 aliases。

## 局限

1. 用户以 macOS 开发者为主，榜单反映 macOS 偏好。
2. macOS 预装工具（git、curl、python、rsync、zsh、sqlite 等）排名被系统性压低。
3. 反向偏差：补 GNU 类包冲高（已剔除）。
4. Xcode/iOS 生态权重大（已剔除独占项，Linux 可用项保留带注）。
5. analytics 是可选上报（`brew analytics off` 可关），存在自选偏差。
6. install-on-request 已排除纯依赖牵引，但 CI 脚本批量安装也计入"请求"。
