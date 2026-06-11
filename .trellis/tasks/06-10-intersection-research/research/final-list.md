# 首发清单定稿（计票 × 标注）

- 条目：**110**
- provider 分布：{'apt': 63, 'deb': 21, 'script': 14, 'snap': 6, 'ppa': 4, 'flatpak': 1, 'undecided': 1}
- 可验性：{'container': 95, 'vm': 15}
- 依赖引证票（被 ≥2 条官方步骤要求即自动入选资格）：{'curl': 22, 'wget': 9, 'gpg': 7, 'ca-certificates': 5, 'gnupg': 5, 'software-properties-common': 4, 'lsb-release': 2, 'unzip': 2, 'npm': 2}

## ai-tools（1）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| ollama | 3+0 | [script](https://github.com/ollama/ollama/blob/main/README.md) | script | - | vm | noble 仓库无 ollama 包 |

## bedrock（1）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| curl | 3+1 | [apt](https://curl.se/download.html) | apt | - | container | noble 为 8.5.0-2ubuntu10.9，上游最新 8.20.0，版本明显落后但有安全维护；作为基础工具完全够 |

## browsers（6）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| firefox | 3+1 | [apt-third-party-repo](https://support.mozilla.org/en-US/kb/install-firefox-linux) | deb | desktop | container | noble 的 firefox 包是 1:1snap1-0ubuntu5 snap 过渡空壳，apt install 实 |
| brave | 2+1 | [script](https://brave.com/linux/) | deb | desktop | container | noble 仓库无 brave/brave-browser 包（已验证 No such package） |
| chrome | 2+1 | [binary-download](https://www.google.com/chrome/) | deb | desktop | container | noble 仓库无 google-chrome-stable（专有软件，已验证 No such package）；注意  |
| chromium | 2+1 | [snap](https://snapcraft.io/chromium) | snap | desktop | vm | noble 的 chromium-browser (2:1snap1-0ubuntu2, universe) 是过渡包， |
| edge | 2+1 | [apt-third-party-repo](https://learn.microsoft.com/en-us/linux/packages) | deb | desktop | container | packages.ubuntu.com/noble/microsoft-edge-stable 确认 No such p |
| vivaldi | 2+1 | [binary-download](https://help.vivaldi.com/desktop/install-update/manual-setup-vivaldi-linux-repositories/) | deb | desktop | container | noble 无 vivaldi / vivaldi-stable（No such package），官方 .deb/仓库 |

## build-toolchain（7）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| gcc | 4+1 | [apt](https://gcc.gnu.org/install/binaries.html) | apt | - | container | noble 有 gcc (4:13.2.0-7ubuntu1) 与 build-essential 元包（含 g++/m |
| make | 3+1 | [other](https://www.gnu.org/software/make/) | apt | - | container | noble 在档 4.3-4.1build2；上游最新 4.4.1（2023），4.3 为 2020 年版本，日常构建够 |
| ninja | 3+1 | [binary-download](https://github.com/ninja-build/ninja) | apt | - | container | noble 在档 1.11.1-2（上游 v1.13.2），略旧但完全可用；注意包名是 ninja-build，二进制名 |
| cmake | 2+1 | [apt-third-party-repo](https://apt.kitware.com/) | apt | - | container | noble 为 3.28.3-1build7，上游已是 4.x，版本明显落后但完全可用。 |
| gradle | 3+0 | [script](https://docs.gradle.org/current/userguide/installation.html) | script | - | container | noble 有 gradle 4.4.1-20，上游已是 9.5.1——落后五个大版本（2017 年代码），与现代 JD |
| just | 2+1 | [apt](https://github.com/casey/just#packages) | apt | - | container | noble 为 1.21.0-1（2024 初），上游最新 1.52.0，版本明显陈旧；核心命令运行器功能可用，但缺近两 |
| maven | 3+0 | [apt](https://maven.apache.org/install.html) | apt | - | container | noble 有 maven 3.8.7-2，上游当前 3.9.16——落后一个 minor 系列，日常构建完全可用 |

## cli-utilities（12）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| bat | 2+1 | [apt](https://github.com/sharkdp/bat#on-ubuntu-using-apt) | apt | - | container | noble 为 0.24.0-1build1（上游 0.26.1，略旧）。关键：noble 的 bat 包可执行文件仍是 |
| eza | 2+1 | [apt-third-party-repo](https://github.com/eza-community/eza/blob/main/INSTALL.md) | apt | - | container | noble 为 0.18.2-1（2024 年初），明显落后上游 0.2x 系列；功能可用但缺两年的修复/特性。 |
| fd | 2+1 | [apt](https://github.com/sharkdp/fd#on-ubuntu) | apt | - | container | noble 为 9.0.0，上游 v10.4.2，落后一个大版本但完全可用；注意包名 fd-find、命令名 fdfin |
| fzf | 2+1 | [apt](https://github.com/junegunn/fzf#linux-packages) | apt | - | container | noble 为 0.44.1，上游 v0.73.1，明显陈旧；新式 shell 集成（fzf --bash/--zsh） |
| jq | 2+1 | [apt](https://jqlang.org/download/) | apt | - | container | noble 有 jq 1.7.1-3ubuntu0.24.04.2（含安全更新）；上游最新 1.8.1，略落后但完全可用 |
| p7zip | 2+1 | [binary-download](https://www.7-zip.org/download.html) | apt | - | container | noble 起上游 7-Zip 以 7zip 打包（23.01+dfsg-11，命令为 7zz），略落后官方最新但可用； |
| pandoc | 2+1 | [binary-download](https://pandoc.org/installing.html) | apt | - | container | noble 为 3.1.3+ds-2（2023），官方已迭代多个版本，陈旧但常用转换功能可用 |
| rclone | 2+1 | [script](https://rclone.org/install/) | script | - | container | noble 含 rclone 1.60.1+dfsg-3ubuntu0.24.04.5，严重陈旧（上游 1.74.3，落 |
| ripgrep | 2+1 | [apt](https://github.com/BurntSushi/ripgrep#installation) | apt | - | container | noble 含 ripgrep 14.1.0-1，与上游最新 14.1.1 仅差一个补丁版，不算陈旧 |
| rsync | 2+1 | [apt](https://rsync.samba.org/download.html) | apt | - | container | noble 含 rsync 3.2.7-1ubuntu1.5（上游 3.4.x，略旧但完全可用）；实测 24.04.4  |
| tree | 2+1 | [other](https://github.com/Old-Man-Programmer/tree) | apt | - | container | noble 为 2.1.1-2ubuntu3，上游已至 2.2.x，小幅滞后，功能无碍 |
| yq | 2+1 | [binary-download](https://github.com/mikefarah/yq#install) | snap | - | vm | noble 仓库的 yq 包（3.1.0-3, universe）是 kislyuk/yq——Python 写的 jq  |

## communication（5）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| discord | 2+1 | [binary-download](https://discord.com/download) | deb | desktop | container | packages.ubuntu.com/noble/discord 确认 No such package。 |
| signal | 2+1 | [apt-third-party-repo](https://signal.org/download/linux/) | deb | desktop | container | Ubuntu 官方仓库无 signal-desktop 包，只能走官方第三方 apt 仓库 |
| telegram | 2+1 | [binary-download](https://desktop.telegram.org/) | snap | desktop | vm | telegram-desktop 已不在 noble（packages.ubuntu.com 显示 not availa |
| thunderbird | 2+1 | [flatpak](https://support.mozilla.org/en-US/kb/installing-thunderbird-linux) | flatpak | desktop | vm | noble 的 thunderbird 是 2:1snap1-0ubuntu3 过渡包，apt 安装实际触发安装 sna |
| zoom | 2+1 | [binary-download](https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0063458) | deb | desktop | container | noble 仓库无 zoom 包（闭源专有软件） |

## containers-virtualization（4）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| docker | 4+1 | [apt-third-party-repo](https://docs.docker.com/engine/install/ubuntu/) | deb | - | vm | docker-ce 不在 Ubuntu 仓库；noble 自带 docker.io 已更新至 29.1.3-0ubunt |
| podman | 3+1 | [apt](https://podman.io/docs/installation) | apt | - | container | noble 在档 4.9.3+ds1-1ubuntu0.1，上游已 v5.8.2，落后一个大版本；官方未提供 Ubunt |
| docker-compose | 2+1 | [apt-third-party-repo](https://docs.docker.com/compose/install/linux/) | deb | - | container | noble 有 Ubuntu 自包装的 docker-compose-v2 (2.24.6)，落后上游（已 2.3x+） |
| qemu | 2+1 | [apt](https://www.qemu.org/download/) | apt | - | container | noble 含 qemu-system 1:8.2.2+ds-0ubuntu1.16（上游已到 10.x，LTS 正常滞 |

## databases（6）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| mongodb | 3+1 | [apt-third-party-repo](https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/) | deb | - | vm | noble 仓库无 mongodb（SSPL 改许可后被 Debian/Ubuntu 移除，packages.ubunt |
| postgresql | 3+1 | [apt](https://www.postgresql.org/download/linux/ubuntu/) | apt | - | vm | noble main 为 postgresql 16（16+257build1 元包），上游最新 18/19beta；1 |
| redis | 3+1 | [apt-third-party-repo](https://redis.io/docs/latest/operate/oss_and_stack/install/archive/install-redis/install-redis-on-linux/) | deb | - | vm | noble universe redis-server 5:7.0.15，明显落后于上游 Redis 8.x；官方 pa |
| sqlite | 3+1 | [binary-download](https://sqlite.org/download.html) | apt | - | container | noble main sqlite3 3.45.1（上游 3.5x），略旧但完全可用且随系统安全更新 |
| mariadb | 2+1 | [apt-third-party-repo](https://mariadb.com/kb/en/mariadb-package-repository-setup-and-usage/) | apt | - | vm | noble 为 1:10.11.13（10.11 LTS 系列，Ubuntu 持续维护）；官方仓库提供更新的 11.x  |
| mysql | 2+1 | [apt-third-party-repo](https://dev.mysql.com/doc/mysql-apt-repo-quick-guide/en/) | apt | - | vm | noble 为 8.0.46（8.0 系列，Ubuntu 持续打补丁）；官方 APT 仓库默认已是 8.4 LTS，8. |

## editors-ides（10）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| jupyterlab | 3+1 | [language-pkg-manager](https://jupyterlab.readthedocs.io/en/stable/getting_started/installation.html) | script | - | container | noble 无 jupyterlab 包（已验证 packages.ubuntu.com 报 Package not a |
| neovim | 3+1 | [binary-download](https://github.com/neovim/neovim/blob/master/INSTALL.md) | apt | - | container | noble 在档 0.9.5-6ubuntu2，上游 stable 已是 v0.12.3，明显陈旧（不少主流插件已要求  |
| vim | 3+1 | [apt](https://www.vim.org/download.php) | apt | - | container | noble main vim 2:9.1.0016（含安全更新），新鲜度足够 |
| vscode | 3+1 | [apt-third-party-repo](https://code.visualstudio.com/docs/setup/linux) | deb | desktop | container | Ubuntu 24.04 仓库无 code/vscode 包 |
| vscodium | 3+1 | [apt-third-party-repo](https://vscodium.com/#install) | deb | desktop | container | Ubuntu 24.04 仓库无 codium/vscodium 包 |
| jetbrains-idea | 2+1 | [other](https://www.jetbrains.com/help/idea/installation-guide.html) | snap | desktop | vm | 不在 Ubuntu 仓库（pkgstats 的 intellij-idea-community-edition 是 Ar |
| jetbrains-pycharm | 2+1 | [other](https://www.jetbrains.com/help/pycharm/installation-guide.html) | snap | desktop | vm | 不在 Ubuntu 仓库（pkgstats 的 pycharm-community-edition 是 Arch 包名） |
| nano | 2+1 | [other](https://www.nano-editor.org/download.php) | apt | - | container | noble 为 7.2-2ubuntu0.2，官方最新 9.0，版本陈旧但作为基础编辑器完全够用；Ubuntu 24.0 |
| sublime-text | 2+1 | [apt-third-party-repo](https://www.sublimetext.com/docs/linux_repositories.html) | deb | desktop | container | noble 无 sublime-text 包（No such package），官方 apt 仓库是唯一 deb 渠道 |
| zed | 2+1 | [script](https://zed.dev/docs/linux) | script | desktop | container | noble 仓库无 Zed 编辑器包（同名搜索只命中无关包；zfs-zed 是 ZFS 事件守护进程，无关）；Debia |

## gaming（1）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| steam | 3+1 | [binary-download](https://store.steampowered.com/about/) | deb | desktop | container | noble multiverse 有 steam-installer 1:1.0.0.79~ds-2（steam 为过渡 |

## graphics-creative（5）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| gimp | 2+1 | [binary-download](https://www.gimp.org/downloads/) | apt | desktop | container | noble 为 2.10.36，上游 3.2.4，落后一个大版本（2.x→3.x 重大升级）；2.10 仍稳定可用 |
| graphviz | 2+1 | [apt](https://graphviz.org/download/) | apt | - | container | noble 为 2.42.2（2019 年发布）；上游版本号已到 15.0.0（2026-05，GitLab relea |
| imagemagick | 2+1 | [binary-download](https://imagemagick.org/script/download.php) | apt | - | container | noble 为 IM6 旧主线（8:6.9.12.98，命令 convert/identify）；上游主线 IM7（7. |
| inkscape | 2+1 | [apt-third-party-repo](https://inkscape.org/release/inkscape-1.4.4/gnulinux/ubuntu/ppa/dl/) | ppa | desktop | container | noble 为 1.2.2（2022 年系），上游已 1.4.4——明显陈旧；官方明说「若你的 Ubuntu 尚未打包当 |
| krita | 2+1 | [binary-download](https://krita.org/en/download/) | apt | desktop | container | noble 为 1:5.2.2+dfsg-2build8，上游最新 5.3.2.1，落后一个小版本系列，可用。 |

## kubernetes-devops（3）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| ansible | 3+0 | [language-pkg-manager](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) | apt | - | container | universe 含 ansible 9.2.0+dfsg-0ubuntu5（ansible-core 2.16.3）， |
| kubectl | 3+0 | [apt-third-party-repo](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/) | deb | - | container | noble 仓库无 kubectl 包（packages.ubuntu.com 查无） |
| terraform | 3+0 | [apt-third-party-repo](https://developer.hashicorp.com/terraform/install) | deb | - | container | noble 仓库无 terraform 包（packages.ubuntu.com 查无） |

## languages-runtimes（13）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| go | 3+1 | [binary-download](https://go.dev/doc/install) | apt | - | container | noble 为 2:1.22~2build1（Go 1.22），相对上游（2026 年 1.24/1.25 线）明显陈旧 |
| nodejs | 3+1 | [script](https://nodejs.org/en/download) | apt | - | container | noble 在档 nodejs 18.19.1（不含 npm，需另装 npm 9.2.0~ds1-2）。Node 18  |
| openjdk | 3+1 | [binary-download](https://openjdk.org/install/) | apt | - | container | noble default-jdk(2:1.21-75+exp1) 指向 openjdk-21（21 为 LTS，Ubu |
| php | 3+1 | [apt](https://www.php.net/manual/en/install.unix.debian.php) | apt | - | container | noble 在档 PHP 8.3（2:8.3+93ubuntu2），上游 8.3 支持至 2027 年底，不陈旧。php |
| python | 3+1 | [preinstalled](https://docs.python.org/3/using/unix.html) | apt | - | container | noble main python3 3.12.3，Ubuntu 24.04 预装；配套生态包 python3-pip  |
| ruby | 3+1 | [apt](https://www.ruby-lang.org/en/documentation/installation/) | apt | - | container | noble ruby-full 1:3.2~ubuntu1 → Ruby 3.2（上游已到 3.4.x），版本偏旧；官方 |
| rust | 3+1 | [script](https://www.rust-lang.org/tools/install) | script | - | container | noble universe 有 rustup 1.26.0-5ubuntu0.1 和 rustc 1.75（cargo |
| bun | 3+0 | [script](https://bun.com/docs/installation) | script | - | container | Ubuntu 24.04 仓库无 bun 包 |
| deno | 3+0 | [script](https://docs.deno.com/runtime/getting_started/installation/) | script | - | container | Ubuntu 24.04 仓库无 deno 包 |
| dotnet | 2+1 | [apt](https://learn.microsoft.com/en-us/dotnet/core/install/linux-ubuntu-2404) | apt | - | container | noble-updates 为 8.0.127-0ubuntu1~24.04.1，由 Canonical 维护并随安全更 |
| kotlin | 2+1 | [snap](https://kotlinlang.org/docs/command-line.html) | snap | - | vm | noble 虽有 kotlin 包但版本 1.3.31（2019 年），上游已 2.4.0，严重过时不可用作首选。 |
| lua | 2+1 | [other](https://www.lua.org/download.html) | apt | - | container | noble 无不带版本号的 lua 包；lua5.4（5.4.6-3build2）和 lua5.3（5.3.6-2bui |
| typescript | 2+1 | [language-pkg-manager](https://www.typescriptlang.org/download/) | script | - | container | noble 仅有 node-typescript 4.8.4+ds1-2（2022 年版本，落后当前 5.x 约两个大版 |

## media（6）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| vlc | 3+1 | [snap](https://www.videolan.org/vlc/download-ubuntu.html) | apt | desktop | container | noble universe 含 vlc 3.0.20-3build6，与上游 3.0.x 最新差距很小；官方页面明确  |
| audacity | 2+1 | [binary-download](https://www.audacityteam.org/download/linux/) | apt | desktop | container | noble 为 3.4.2+dfsg-1build4，上游当前 3.7.7，版本明显陈旧 |
| ffmpeg | 2+1 | [apt](https://ffmpeg.org/download.html) | apt | - | container | noble 为 7:6.1.1（6.1 系列），上游最新 8.1.1，落后两个大版本，但由 Ubuntu 持续安全维护， |
| obs-studio | 2+1 | [apt-third-party-repo](https://obsproject.com/kb/linux-installation) | ppa | desktop | container | noble universe 为 30.0.2，明显落后官方 PPA 当前版本；OBS 官方对 Ubuntu 给出的唯一 |
| spotify | 2+1 | [snap](https://www.spotify.com/download/linux/) | deb | desktop | container | Ubuntu 官方仓库无 spotify 包；spotify-client 来自 repository.spotify. |
| yt-dlp | 2+1 | [binary-download](https://github.com/yt-dlp/yt-dlp/wiki/Installation) | ppa | - | container | noble universe 2024.04.09-1，noble-updates 无更新；yt-dlp 需频繁更新对抗 |

## network-tools（7）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| wget | 3+1 | [apt](https://www.gnu.org/software/wget/) | apt | - | container | main 仓库 1.21.4-1ubuntu4.1；priority: standard，Ubuntu 常规安装（含 S |
| aria2 | 2+1 | [other](https://aria2.github.io/) | apt | - | container | noble 为 1.37.0+debian-1build3，恰为上游最新 release（1.37.0，2023 年发布 |
| httpie | 2+1 | [apt-third-party-repo](https://httpie.io/docs/cli/debian-and-ubuntu) | apt | - | container | noble 有 httpie 3.2.2（universe），上游 latest 3.2.4（2024-11）——仅小版 |
| iperf3 | 2+1 | [apt](https://software.es.net/iperf/obtaining.html) | apt | - | container | noble 为 3.16，上游 3.21——有滞后但完全可用；官方明言不自发布二进制、Linux 走发行版包。 |
| nginx | 2+1 | [apt-third-party-repo](https://nginx.org/en/linux_packages.html#Ubuntu) | apt | - | vm | noble 为 1.24.0-2ubuntu7.x（2023 stable，Ubuntu 持续安全维护）；nginx.o |
| nmap | 2+1 | [apt](https://nmap.org/book/inst-linux.html) | apt | - | container | noble 为 7.94+git20230807 快照；官方自己提醒 Debian 系包可能滞后上游一年左右，但功能完整 |
| qbittorrent | 2+1 | [apt](https://www.qbittorrent.org/download) | apt | desktop | container | noble 含 qbittorrent 4.6.3-1build2，落后上游一个大版本（最新 5.2.1）；要新版可用官 |

## package-managers（6）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| flatpak | 2+1 | [apt](https://flatpak.org/setup/Ubuntu) | apt | - | container | noble 为 1.14.6（上游 1.18.0），1.14 系列由 Ubuntu 安全维护；官方 setup 页对 U |
| pipx | 2+1 | [apt](https://pipx.pypa.io/stable/how-to/install-pipx/) | apt | - | container | noble 含 pipx 1.4.3-1；官方文档自己点名'Ubuntu 24.04 ships v1.4.3'偏旧（上 |
| pnpm | 3+0 | [script](https://pnpm.io/installation) | script | - | container | noble 仓库无 pnpm 包 |
| poetry | 3+0 | [language-pkg-manager](https://python-poetry.org/docs/#installation) | apt | - | container | noble 有 python3-poetry 1.8.2+dfsg-1ubuntu2，上游已是 2.4.1——落后一个大 |
| uv | 3+0 | [script](https://docs.astral.sh/uv/getting-started/installation/) | script | - | container | noble 仓库无 uv 包（packages.ubuntu.com/noble/uv 返回 No such packa |
| yarn | 3+0 | [language-pkg-manager](https://yarnpkg.com/getting-started/install) | undecided | - | container | noble 的 yarn 只是 virtual package，实包为 yarnpkg 1.22.19（classic  |

## productivity（2）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| libreoffice | 2+1 | [apt](https://www.libreoffice.org/get-help/install-howto/linux/) | apt | desktop | container | noble 为 4:24.2.7-0ubuntu0.24.04.5（24.2 系列，随发行版维护更新）；上游 fresh |
| obsidian | 3+0 | [binary-download](https://obsidian.md/download) | deb | desktop | container | noble 仓库无 obsidian 包（闭源应用，不入发行版仓库） |

## security-privacy（2）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| gnupg | 2+1 | [apt](https://gnupg.org/download/index.html) | apt | - | container | noble 为 2.4.4-2ubuntu17.x；Ubuntu 24.04 标准安装（含 Server）默认已预装 g |
| keepassxc | 2+1 | [apt-third-party-repo](https://keepassxc.org/download/) | apt | desktop | container | noble 为 2.7.6+dfsg.1-1build3，上游最新 2.7.12，落后数个补丁版本但同为 2.7 系列、 |

## system-monitoring（3）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| btop | 2+1 | [binary-download](https://github.com/aristocratos/btop#installation) | apt | - | container | noble 为 1.3.0-1，上游已 1.4.7（2026-05），版本陈旧约一年半 |
| fastfetch | 2+1 | [apt-third-party-repo](https://github.com/fastfetch-cli/fastfetch#installation) | ppa | - | container | packages.ubuntu.com/noble/fastfetch 返回 Error（无此包）；README 注明  |
| htop | 2+1 | [apt](https://htop.dev/downloads.html) | apt | - | container | noble 为 3.3.0，上游 latest 3.5.1（2026-04，GitHub releases 实测），小幅 |

## terminal-shell（5）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| fish | 2+1 | [apt-third-party-repo](https://fishshell.com/) | apt | - | container | noble 为 3.7.0，上游 4.7.1（fish 4 为 Rust 重写），落后一个大版本；3.7 仍稳定可用 |
| starship | 2+1 | [script](https://starship.rs/) | script | - | container | noble 无 starship 包（packages.ubuntu.com 显示 not available in t |
| tmux | 2+1 | [apt](https://github.com/tmux/tmux/wiki/Installing) | apt | - | container | noble 为 3.4-1build1，上游已至 3.5a，略滞后但完全可用（官方 wiki 自己也注明发行版包常滞后） |
| zoxide | 2+1 | [script](https://github.com/ajeetdsouza/zoxide#installation) | script | - | container | noble universe 0.9.3-1，上游已到 0.9.x 更新版；官方 README 对 Ubuntu 的 a |
| zsh | 2+1 | [apt](https://zsh.sourceforge.io/FAQ/zshfaq01.html) | apt | - | container | noble main 5.9-6ubuntu2（5.9 即上游最新稳定版，不陈旧） |

## vcs（5）

| 工具 | 票 | 官方装法 | provider | requires | 验证 | 备注 |
|------|----|---------|----------|----------|------|------|
| git | 4+1 | [apt](https://git-scm.com/install/linux) | apt | - | container | noble 为 1:2.43.0-1ubuntu7.3，落后上游约两年版本线，但有 LTS 安全维护，日常使用无碍。 |
| gh | 3+1 | [apt-third-party-repo](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) | deb | - | container | noble 有 gh 2.45.0-1ubuntu0.3，相对上游（2026 年已 2.7x+）明显陈旧，且非 GitH |
| git-lfs | 2+1 | [apt-third-party-repo](https://github.com/git-lfs/git-lfs/blob/main/INSTALLING.md) | apt | - | container | noble 为 3.4.1（上游 v3.7.1），略旧但可用 |
| glab | 3+0 | [binary-download](https://gitlab.com/gitlab-org/cli#installation) | apt | - | container | universe 含 glab 1.36.0-1ubuntu0.3，上游最新 v1.102.0，版本明显陈旧 |
| lazygit | 2+1 | [binary-download](https://github.com/jesseduffield/lazygit#installation) | script | - | container | noble 仓库无 lazygit（已验证 Package not available）；apt install laz |
