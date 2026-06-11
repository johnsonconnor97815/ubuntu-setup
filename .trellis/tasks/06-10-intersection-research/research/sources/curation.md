# curation 源采集笔记（2026-06-10）

## 抓取过程

- **(a) Omakub**：GitHub contents API 枚举 `basecamp/omakub` 的 `install/`、`install/desktop(/optional)`、`install/terminal(/optional|/required)` 全部脚本，并 curl raw 确认聚合脚本实际安装内容（`apps-terminal.sh`、`libraries.sh`、`docker.sh`、`mise.sh`、`select-dev-language.sh`、`select-dev-storage.sh`、`set-gnome-extensions.sh`、`boot.sh`）。
- **(b) It's FOSS 24.04 指南**：exa fetch 正文，逐条提取安装项。
- **(c) FOSSPost 指南**：exa fetch 返回乱码（gzip 解码失败），改用 `curl --compressed` 抓 HTML 后剥标签提取正文。文章标注 "Updated: May 21, 2026"。
- **(d) Ubuntu Portal checklist**：exa fetch 正文，25 条逐条提取。

计票规则：每个软件统计在 (a)(b)(c)(d) 中的命中数，≥2 进 `curation.json` 的 tools[]，metric=命中数。

## 完整命中矩阵

### 命中 ≥2（进 tools）

| canonical | a Omakub | b It's FOSS | c FOSSPost | d Ubuntu Portal | 计 |
|---|---|---|---|---|---|
| gnome-tweaks | ✓ app-gnome-tweak-tool.sh | ✓ 第9条 | ✓ 专节 | ✓ 第20条 | 4 |
| ubuntu-restricted-extras | — | ✓ 第6条 | ✓（变体 ubuntu-restricted-addons） | ✓ 第7条 | 3 |
| gnome-extension-manager | ✓ set-gnome-extensions.sh 装 gnome-shell-extension-manager | — | ✓ 专节（经 extensions.gnome.org） | ✓ 第20条 | 3 |
| docker | ✓ terminal/docker.sh | — | — | ✓ 第19条 | 2 |
| git | ✓ boot.sh | — | — | ✓ 第16条 | 2 |
| flatpak | ✓ desktop/a-flatpak.sh | ✓ 第3条 | — | — | 2 |
| vlc | ✓ app-vlc.sh | — | ✓ 专节 | — | 2 |
| steam | ✓ optional/app-steam.sh | — | ✓ 专节 | — | 2 |
| synaptic | — | ✓ 第4条 | ✓ 专节 | — | 2 |
| curl | ✓ mise.sh 依赖 | — | — | ✓ 第16条 | 2 |
| wget | ✓ mise.sh 依赖 | — | — | ✓ 第16条 | 2 |
| gcc（build-essential 拆分） | ✓ libraries.sh | — | — | ✓ 第16条 | 2 |
| make（build-essential 拆分） | ✓ libraries.sh | — | — | ✓ 第16条 | 2 |
| firefox | — | — | ✓ 换装 DEB 版 | ✓ 第10条（仅配置预装版） | 2 |

### 命中 ≥2 但按收录规则排除

| 项 | 命中 | 排除理由 |
|---|---|---|
| libfuse2 / libfuse2t64 | b（AppImage 支持）+ c | 纯库依赖包 |
| 显卡/专有驱动（nvidia 等） | c "Install Needed Drivers" + d 第3条 | firmware/驱动 |
| Ubuntu Pro / Livepatch | c 专节 + d 第2、4条 | 订阅服务，客户端预装，非可装软件 |
| 系统更新（apt upgrade） | a/b/c/d 全部 | 操作而非软件 |

### 仅命中 1（备查）

- **仅 (a) Omakub**：
  - terminal 必装：mise、neovim、lazygit、lazydocker、zellij、btop、fastfetch、gh、fzf、ripgrep、bat、eza、zoxide、fd（fd-find）、plocate、gum（required）、apache2-utils；libraries.sh 另有 clang、rustc（apt 版）、pipx、imagemagick、sqlite（sqlite3）、postgresql-client、redis-tools、mupdf。
  - terminal 选装：语言（经 mise：nodejs、go、python、ruby、java、elixir；php+composer 走 apt；rust 走 rustup）、数据库（Docker 容器跑 mysql、redis、postgresql）、ollama、tailscale、geekbench。
  - desktop 必装：alacritty、chrome、flameshot、gnome-sushi、libreoffice、localsend、obsidian、pinta、signal、typora、vscode、wl-clipboard、xournalpp、ulauncher。
  - desktop 选装：1password、asdcontrol、audacity、brave、cursor、doom-emacs、dropbox、gimp、mainline（内核工具）、minecraft、obs-studio、retroarch、rubymine、spotify、virtualbox、windsurf、zed、zoom。
- **仅 (b) It's FOSS**：gdebi（及替代品 eddy）、cheese。
- **仅 (c) FOSSPost**：chromium（换 DEB 版）、zram、各桌面环境元包（kubuntu-desktop 等）；另有"移除 apport / snapd"属卸载建议。
- **仅 (d) Ubuntu Portal**：tmux、timeshift、gpaste、unattended-upgrades、libdvd-pkg、fonts-liberation 等字体包、ufw（预装仅配置）。

## 判读说明

- (a) 以仓库 master 分支实际脚本为准，可选项（optional/、select-*）也算 Omakub 命中——它们是策展者明确收录的菜单项。
- (b) 实为"设置向"文章，真正的安装项很少（7 个左右），对计票贡献低。
- firefox 的 2 票成色弱：c 是把预装 Snap 换成 DEB，d 只是配置预装版；按"提及"规则保留，下游合票时可酌情降权。
- curl/wget 在 Omakub 侧来自 mise.sh 顺带的 `apt install gpg wget curl`，是安装器依赖而非策展推荐，evidence 已如实标注。
- gcc/make：两清单都装 build-essential 元包，按 canonical 对齐规范拆成两条（raw_name 均为 build-essential），便于与其他源相交。

## 局限

1. **同温层互抄**：四清单同属"Ubuntu 装机指南"生态，互相借鉴明显，命中 ≥2 不构成独立信号。
2. **(b)(c) 偏桌面体验**：GNOME 调教、codecs、主题为主，开发工具几乎不出现，dev 工具在本源被系统性低估（全靠 a、d 撑）。
3. **Omakub 偏 web-dev 品味**：DHH/Rails 生态选型（mise、neovim、lazygit、Ruby 优先），个人色彩重。
4. (d) Ubuntu Portal 文章带联盟营销链接，清单本身常规但商业动机存在。
5. FOSSPost 标注 2026-05 更新、Ubuntu Portal 标注 2026-03 发布，时效尚可；It's FOSS 为 2024-05 的 24.04 首发文，距今两年。
