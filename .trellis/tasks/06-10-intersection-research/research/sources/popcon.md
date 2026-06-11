# popcon — Debian Popularity Contest by_vote（辅助源）

抓取日期：2026-06-10

## 抓取过程

- `curl -sL https://popcon.debian.org/by_vote` 直接抓 60s 超时（全表约 22 MB），改抓 `by_vote.gz`（约 3.3 MB）后 gunzip，得全表 222,086 行。
- 表格列：`rank name inst vote old recent no-files`。vote = 「近期实际使用过该包内文件」的提交者人数，是比 inst（装了就算）更强的「真在用」信号，故按任务要求以 vote 榜为准。
- 用 Python 脚本按精确包名从全表提取 rank/vote/inst，套用人工维护的 canonical 映射生成 `popcon.json`，避免手抄数字出错。

## 判读说明

- **筛选深度与任务原拟不符**：任务写「取 vote 前 ~200 名中的用户态工具」，但实测前几百名几乎全是 lib*/Essential 基础件——git 仅第 319 名，curl 第 690，vim 第 1384，htop 第 1584，tmux 第 1322，build-essential 第 3273。为覆盖任务点名的工具，实际筛选深度扩到 **vote ≥ 900（约前 6100 名）**，从中人工挑出 184 个用户态工具。
- **剔除规则**：lib*、firmware、locale、内核包、X11/字体/dbus/systemd 等基础件、纯依赖包（containerd、gcc-14-base、初始化用 busybox 等）、Essential 预装件（bash/coreutils/grep/sed/tar/apt 等——catalog 里没有安装意义）、Debian 打包者专用工具（lintian/devscripts/reportbug 等）。
- **保留的边界判断**：python/perl/openssl/sudo 等虽近乎预装，但属用户主动使用的运行时/工具，保留；DE 自带应用（gnome-terminal、konsole、evince、okular）保留但在 evidence 标注「随桌面自带、数值偏高」。
- **元包失真**：vote 统计文件使用，元包没人「使用其文件」——`vlc` 元包 vote 仅 148 而 `vlc-bin` 14280；libreoffice、postgresql、imagemagick 同理。一律改用代表性实包做 raw_name 并在 evidence 注明。
- **多包合一**：gcc/g++、mtr/mtr-tiny、netcat 两实现、docker-ce/docker.io、steam 三件套等合并为一个 canonical，取 vote 最高的实包做 metric，其余进 aliases 或 evidence。
- metric = vote 人数，metric_unit 按任务统一约定填 `rank`，evidence 同时写排名与 vote/inst。

## 局限

1. 样本是 Debian popularity-contest 的 **opt-in 志愿者**，偏服务器/老派用户群，不代表 Ubuntu 桌面开发者整体。
2. **Ubuntu 端 popcon 已于 2022 年下线**，本数据为纯 Debian 视角。
3. **snap/flatpak/手动安装完全不可见**；第三方 apt 仓库包（docker-ce、google-chrome、code、spotify 等）可见但被系统性低估。
4. 现代开发者工具如 shellcheck（vote=817）、zoxide（786）、eza（781）、direnv（669）、starship（427）、lazygit 等都在 vote<900 截断线以下，未入选——这正是该源「偏老派」口味的体现，交集计票时应以其他源补足。
5. 「用户态工具」甄别为人工判断，截断线与取舍均有主观性。
