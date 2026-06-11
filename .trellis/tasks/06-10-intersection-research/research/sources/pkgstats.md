# pkgstats（Arch Linux 包安装率）采集笔记

抓取日期：2026-06-10 ｜ source_key=pkgstats ｜ 角色：核心源弱位

## 抓取过程

- API 文档：`https://pkgstats.archlinux.de/api/doc`（OpenAPI 3.0，只读）。
- 实际调用：`GET https://pkgstats.archlinux.de/api/packages?limit=10000`（一次拿满，默认按 popularity 降序）。
- 返回字段：`name / samples / count / popularity / startMonth / endMonth`。默认统计窗口为**上一个整月**，本次为 `202605`（2026 年 5 月），样本量 n=32821 台上报机器；popularity = 该包在样本中的安装率 %。
- 总包数 35322，取前 10000 建立 name→popularity 索引，再做两轮筛选：
  1. 正则剔除明显的库/绑定/固件/字体前缀（lib*、python-*、perl-*、qt5/6-*、kf5/6-*、xorg-*、gst-*、linux-firmware*、ttf-* 等）后逐行人工扫描前 ~3200 名；
  2. 对 300+ 个已知开发工具的 Arch 包名做定点查询（覆盖 10000 名以内的全部命中）。

## 判读说明

- **字面「popularity 前 150」无法直接用**：前 150 名几乎全是 base 链路的系统库（acl、libffi、openssl……），真正的「工具」不足 10 个。因此本源实际做法是在前 1 万名里按收录范围筛工具，产出 350 条，远超「前 150」的字面口径（caveats 已注明）。
- **依赖效应逐条标注**：popularity 不区分主动安装与依赖拉入。典型案例——
  - `sqlite` 100%、`python` 99.4%、`curl` 99.98%、`gnupg` 99.96%：基础链路，几乎纯依赖效应；
  - `deno` 58.1%：被 `yt-dlp-ejs`（55.97%）作为 JS 运行时依赖拉入，真实主动安装远低于此；
  - `go` 58.4%：yay 等 AUR 助手从源构建需要 go；
  - `make`/`gcc`/`cmake`/`ninja`/`meson`：base-devel 成员或 AUR makedepends 常驻；
  - `ripgrep-all` 49.9%、`gum` 32.8%、`tesseract` 48.0%、`graphviz` 61.1%：远超其独立知名度，按依赖拉入嫌疑标注。
- **冲突变体求和**：同一产品的互斥包合并计入一条，evidence 写明各包数字，如 vscode = `visual-studio-code-bin` 20.67% + `code` 14.94% ≈ 35.6%；libreoffice = fresh + still；emacs、bun、vscodium 同理。
- **包名映射**：Arch 包名放 `raw_name`，Ubuntu apt 名/flatpak id 等放 `aliases`；`base-devel` → canonical `build-essential`（gcc/make/binutils/autotools 元包 ≈ Ubuntu build-essential）；`fd`→fd-find、`bat`→batcat、`github-cli`→gh、`bind`（Arch 单包含 dig/nslookup ≈ Ubuntu dnsutils）。
- **剔除**：库/固件/字体/KDE-GNOME 框架；DE 捆绑应用（konsole、dolphin、okular、kate、nautilus 等，安装率主要反映桌面环境选择而非软件本身）；Arch 专属工具（yay 48.5%、paru 31.7%、reflector、pacman-contrib、devtools 等，对 Ubuntu catalog 无意义）；qemu-* 子包噪声（取 qemu-base 计 qemu）。
- **redis/valkey**：Arch 2024 年用 valkey 接替 redis，redis 仅剩 2.71%（存量/AUR），valkey 4.95%，两条都收并互相注明——做交集计票时 redis 票应参考 valkey 数字。

## 局限（与 JSON caveats 对应）

1. **依赖效应**：高安装率 ≠ 高主动安装意愿，头部数字需结合 evidence 的标注打折使用。
2. **滚动发行 power user 偏置**：pkgstats 是 Arch 用户自愿装的上报工具，样本高度自选择；平铺 WM（hyprland 21.8%、sway 12.2%、i3 10.6%）、终端/AUR 生态工具占比显著高于 Ubuntu 普通开发者。
3. **样本规模中等**：月样本 ~3.3 万台；<3% 的长尾包只对应数百台机器，排名噪声大。
4. **AUR 渠道偏差**：chrome、slack、postman、1password 等闭源软件只统计经 pacman/AUR 装的用户，经 Flatpak/Snap/官方 deb 装的不计，数值系统性偏低。
5. 单条 source_url 指向 `https://pkgstats.archlinux.de/packages/<pkg>` 详情页，可逐包复核。
