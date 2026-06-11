# Research: 多源交集制入选标准——权威数据源盘点与 N 值建议

- **Query**: 为「Ubuntu 通用开发者工作站装机必备软件」的多源交集制入选标准，盘点可用的权威外部数据源，给出源清单与 N 值建议
- **Scope**: external（联网调查）
- **Date**: 2026-06-10
- **方法说明**: 全部结论基于 2026-06-10 当天的联网检索（exa web search）。清单规模为目测粗估（基于各源头部条目的重叠程度），未实际跑交集脚本。

---

## 一、候选数据源逐个盘点

### 1. Stack Overflow Developer Survey 2025

| 维度 | 评估 |
|---|---|
| 是什么 | SO 年度开发者调查，第 15 届，49,000+ 受访者、177 国、62 题覆盖 314 项技术 |
| 数据怎么产生 | 自愿填答的问卷调查（self-reported survey），2025-07-29 发布 |
| 最近一期 | 2025（发布于 2025-07-29；按惯例 2026 期通常 7-8 月才发布，当前 2025 为最新） |
| 能否按「开发者常用工具」引用 | **能，且有专门板块**。`Cloud development and infrastructure tools` 板块直接给出工具使用率：Docker 71.1%、npm 56.8%、pip 40.9%、Kubernetes 28.5%、Homebrew 25.7%、Make 23.2%、APT 18.4%、Terraform 17.8%、Cargo 14.4%、Ansible 11.7%、Podman 11.1% 等；另有 Dev IDEs（VS Code 等）、协作工具（GitHub 81%、GitLab 36%）、语言（Python 58%、Bash/Shell 48.7%）、数据库（PostgreSQL 第一）板块 |
| 可引用性 | 稳定 URL，逐板块锚点：<https://survey.stackoverflow.co/2025/technology>；历年存档：<https://survey.stackoverflow.co/> |

局限：只问「类别内列出的选项」，系统级工具（curl、htop、tmux、ffmpeg 等）根本不在问卷里；偏语言/框架/云平台。

**采信建议：核心信号**（开发工具与运行时维度的最大样本调查；用它给 Docker、git、make、kubectl、语言运行时、VS Code 投票）。

### 2. GitHub Octoverse 2025 / GitHub star 数据

| 维度 | 评估 |
|---|---|
| 是什么 | GitHub 官方年度报告，基于平台遥测（180M+ 开发者的仓库/贡献活动） |
| 数据怎么产生 | 平台行为统计（非调查、非人工编辑） |
| 最近一期 | Octoverse 2025，2025-10-28 发布 |
| 能否按「开发者常用工具」引用 | **间接**。报告主题是语言（TypeScript 登顶）、AI 仓库、top projects by contributors（vllm、vscode、ollama、uv、llama.cpp…）——衡量的是「人们在开发什么/给什么贡献」，不是「工作站上装了什么」 |
| 可引用性 | <https://octoverse.github.com/>；<https://github.blog/news-insights/octoverse/octoverse-a-new-developer-joins-github-every-second-as-ai-leads-typescript-to-1/> |

**采信建议：不建议作为入选源**（度量对象错位）。**GitHub star 数可作单条目佐证**：catalog 条目溯源时附上工具自身仓库 star 数作为旁证（如 fzf 80k、bat 59k、shellcheck 39k），但 star ≠ 安装率，不计票。

### 3. Ubuntu post-install 指南与脚本（人工策展，3-5 个）

逐个盘点（star 数 / 活跃度为 2026-06 检索值）：

| 名称 | 性质 | 规模/活跃度 | 评估 |
|---|---|---|---|
| **Omakub**（basecamp/omakub，DHH 出品） | 一键把 fresh Ubuntu 24.04 变成 web-dev 工作站的策展脚本 | **8,013 star**，活跃（v1.5.0，2025-11；持续 push 至 2026-04） | 与本产品目标最同构的单一源。装机清单含：Chrome、VS Code、Neovim、Docker+lazydocker、gh、fzf、ripgrep、eza、zoxide、bat、Alacritty+Zellij、mise/nodenv/rbenv、VLC、Flameshot、Ulauncher、1Password、Spotify 等。<https://github.com/basecamp/omakub>、<https://omakub.org/>，介绍：<https://world.hey.com/dhh/introducing-omakub-354db366>，第三方清点：<https://europeantech.news/turn-ubuntu-into-the-perfect-web-dev-setup-in-a-single-command/> |
| It's FOSS《Things to do after installing Ubuntu 24.04》 | 高流量 Linux 媒体的 LTS 装机指南 | 每个 LTS 更新一篇 | 偏桌面体验（codecs、Flatpak、GNOME Tweaks、essential apps）。<https://itsfoss.com/things-to-do-after-installing-ubuntu-24-04/> |
| FOSSPost 同题指南 | 同上 | 持续更新 | Synaptic、GNOME Tweaks、VLC、Steam、zRAM 等。<https://fosspost.org/things-to-do-after-installing-ubuntu/> |
| Ubuntu Portal《24.04 Post-Install Checklist (25 items)》 | 运维向 checklist | 2026-03 发布 | **明确含 dev 条目**：Install Build Essentials、终端复用器、Docker、UFW、unattended-upgrades。<https://ubuntuportal.com/guides/ubuntu-2404-post-install-checklist/> |
| Hacking the Hike《Ubuntu 24.04 After Install Guide》 | 个人博客指南 | 2024-04 | VLC、GIMP、GParted、Synaptic、浏览器等。<https://www.hackingthehike.com/ubuntu2404-guide/> |
| snwh/ubuntu-post-install | 曾经最知名的脚本仓库 | 720 star，**2019 年起 archived** | 过时，不计票，只作历史佐证。<https://github.com/snwh/ubuntu-post-install> |
| rsnk96/Ubuntu-Setup-Scripts | DS/AI 向装机脚本 | 140 star，仍活跃 | 领域偏科（CUDA/Anaconda），不计票。<https://github.com/rsnk96/Ubuntu-Setup-Scripts> |

**采信建议：核心信号，但聚合计为一票**——取「Omakub + 3 篇活跃指南」内部 ≥2 处提及的软件，作为「Ubuntu 装机策展」这一个源的票，避免同温层互抄导致虚高。Omakub 因规模与同构性也可单列为一源（见方案 C 讨论）。

### 4. awesome 系列清单

| 清单 | star | 活跃度 | 评估 |
|---|---|---|---|
| modern-unix（ibraheemdev） | 32,854 | 最后 push 2024-09，半休眠 | 「现代替代品」主题，**强烈偏 Rust 新潮 CLI**（bat/eza/fd/ripgrep/zoxide…）。<https://github.com/ibraheemdev/modern-unix> |
| awesome-cli-apps（agarrharr） | 19,203 | 活跃（2026-04） | 几百条目，收录门槛低。<https://github.com/agarrharr/awesome-cli-apps> |
| awesome-shell（alebcay） | 36,937 | 活跃（2025-08） | shell 框架/工具向。<https://github.com/alebcay/awesome-shell> |
| Awesome-Linux-Software（luong-komorebi） | 24,980 | **2026-05 已 archived**（维护者声明：沦为自我推广目标，难保质量） | 不建议作源；其归档理由本身就是「awesome 清单可信度」的警示。<https://github.com/luong-komorebi/awesome-linux-software> |
| the-art-of-command-line（jlevy） | ~161,000 | 内容稳定（2024-06 最后 push） | 不是软件清单而是教程，但其中点名的工具（jq、htop、fzf、shellcheck、ag/rg）可作 CLI 基本盘佐证。<https://github.com/jlevy/the-art-of-command-line> |

共性问题：(a) 「被收录」信息量低——清单动辄数百条；(b) 清单之间互相抄录，**票不独立**；(c) 偏新潮 CLI，无 GUI/系统工具视角；(d) 维护质量不一且会突然归档。

**采信建议：辅助信号**。合并计为最多一票（「出现在 ≥2 个活跃 awesome 清单」才算这一票），绝不让两个 awesome 清单各自计一票。

### 5. Debian popcon（popularity-contest）

| 维度 | 评估 |
|---|---|
| 是什么 | Debian 官方的 opt-in 安装统计：志愿者机器每周上报已安装包与使用时间戳 |
| 数据怎么产生 | 真实机器遥测（opt-in 自选样本），每日汇总 |
| 最近一期 | **持续更新中**（rolling，按日刷新） |
| 能否按「开发者常用工具」引用 | 部分。`by_inst` 头部被 firmware/库包/依赖统治（intel-microcode、util-linux、systemd…），必须看 `vote`（常用）字段并人工剔除库包，才能得到 vim、git、curl 这类用户态工具的排名 |
| 可引用性 | 稳定 URL：<https://popcon.debian.org/by_inst>、<https://popcon.debian.org/by_vote>、FAQ：<https://popcon.debian.org/FAQ> |

**关键局限——Ubuntu 端已死**：popcon.ubuntu.com 后端从未被认真维护，2021 年 Ubuntu 把上报地址从默认配置移除（LP #1921178），2022 年 Canonical 决定彻底下线后端（LP #1990247），且 popularity-contest 2020 年起已不在 Ubuntu 标准 seed 中。所以现存 popcon 数据只代表 **Debian** 自选用户（偏服务器/老派用户，不区分开发者），且 snap/flatpak/手装二进制完全不可见。
来源：<https://bugs.launchpad.net/bugs/1990247>（经 lists.snapcraft.io 存档）、<https://lwn.net/Articles/826471/>、<https://bugs.launchpad.net/bugs/2130074>。

**采信建议：辅助信号**——只用 `by_vote` 来佐证传统 apt 包的基础盘地位（vim/git/curl/htop/tmux 等），不用于发现新工具，不单独成票否决。

### 6. JetBrains State of Developer Ecosystem 2025

| 维度 | 评估 |
|---|---|
| 是什么 | JetBrains 年度开发者生态调查，24,534 受访者、194 国 |
| 数据怎么产生 | 问卷调查（2025 年 4-6 月执行），按地域/职业/语言/产品使用配平，**原始匿名数据可下载** |
| 最近一期 | 2025（2025-10 发布） |
| 能否按「开发者常用工具」引用 | 可，但维度与 SO 高度重叠：语言、IDE、数据库（PostgreSQL 超 MySQL）、云平台、AI 工具。系统/CLI 工具几乎没有 |
| 可引用性 | <https://devecosystem-2025.jetbrains.com/>、tools 板块：<https://devecosystem-2025.jetbrains.com/tools-and-trends>、博客综述：<https://blog.jetbrains.com/research/2025/10/state-of-developer-ecosystem-2025/> |

局限：样本来自 JetBrains 渠道，IDE 用户偏置明显；与 SO 调查同质，二者同时给某条目投票时独立性打折。

**采信建议：辅助信号**——用于交叉验证 SO 调查中语言/IDE/数据库类条目；不给 SO 没覆盖的条目独立投票权。

### 7. Homebrew analytics（盘点中新发现，强烈建议纳入）

| 维度 | 评估 |
|---|---|
| 是什么 | Homebrew（macOS+Linux）官方安装遥测，公开 30/90/365 天全量安装统计 |
| 数据怎么产生 | opt-out 遥测，真实安装事件；区分 `install`（含依赖）与 **`install-on-request`（用户主动要求安装）**——后者正是「开发者主动装什么」的直接度量 |
| 最近一期 | rolling，按日更新（检索当日 API 数据截至 2026-06-10） |
| 能否按「开发者常用工具」引用 | **极佳**。install-on-request 30 天 Top：gh、node、awscli、uv、ffmpeg、git、go、cmake、coreutils、mise、imagemagick、yt-dlp、jq、pipx、pyenv、ollama、docker、gnupg、gcc、yq、tree、nvm、kubernetes-cli、wget… |
| 可引用性 | 稳定 URL + JSON API：<https://formulae.brew.sh/analytics/>、<https://formulae.brew.sh/analytics/install-on-request/365d/>、API 文档：<https://formulae.brew.sh/docs/api/> |

局限：用户以 macOS 开发者为主（Linuxbrew 少数）；系统预装工具（macOS 自带 curl/git 旧版）排名被压低；GUI 应用在 cask 榜单且 macOS-only 居多。

**采信建议：核心信号**（CLI 开发工具维度上目前能找到的最大规模、最新鲜的真实安装数据；取 install-on-request 365d Top-N 作票源）。

### 8. Arch Linux pkgstats（盘点中新发现）

| 维度 | 评估 |
|---|---|
| 是什么 | Arch 官方 opt-in 包统计：装 pkgstats 包后每周自动上报已装包列表，输出每包安装率 % |
| 数据怎么产生 | 真实机器遥测（opt-in），有历史曲线和对比 API |
| 最近一期 | rolling，持续更新 |
| 能否按「开发者常用工具」引用 | 好。Linux 原生、用户群偏爱好者/开发者：python 99.7%、nodejs 65%、firefox 63.5%、go 61%、chromium 48.8% 等，可逐包查询 |
| 可引用性 | <https://pkgstats.archlinux.de/>、包查询：<https://pkgstats.archlinux.de/packages>、入门/API：<https://pkgstats.archlinux.de/getting-started> |

局限：Arch 包名与 Ubuntu 不同（base-devel vs build-essential）需映射；滚动发行用户偏 power user；样本规模不公开宣传（中等）；安装率含依赖拉入（python 99.7% 显然是依赖效应），需人工判读。

**采信建议：核心信号（弱位）或高质量辅助**——它是唯一「Linux 桌面真实安装率」的活数据源，建议纳入核心组但解读时注意依赖效应。

### 9. Flathub 下载统计（盘点中新发现，GUI 维度）

| 维度 | 评估 |
|---|---|
| 是什么 | Flathub 官方公开每个应用的下载/安装统计（raw JSON），并有年度榜单 |
| 数据怎么产生 | 商店分发遥测（真实下载事件） |
| 最近一期 | rolling；另有《2025 Year in Review》：Firefox 2.7M、Chrome 2.4M、Discord 2.1M、Steam 1.3M、VS Code 792K、GIMP 902K、OBS、Spotify 1.2M… |
| 能否按「开发者常用工具」引用 | GUI 应用维度极佳；CLI 不可见 |
| 可引用性 | raw 数据：<https://flathub.org/stats/>（文档：<https://docs.flathub.org/docs/for-app-authors/maintenance>）、年榜：<https://flathub.org/en/year-in-review/2025>、第三方前端：<https://flatstat.mijorus.it/> |

局限：Flatpak 用户群偏游戏/模拟器（榜单里 RetroArch、Lutris、Dolphin 排名很高）；Ubuntu 默认走 snap，生态有偏移，但「Linux 桌面 GUI 装机率」目前没有比它更好的公开数据（Snap 商店**不公开**安装量排行）。

**采信建议：核心信号（GUI 应用维度）**——浏览器/通讯/媒体/编辑器类条目主要靠它和装机指南凑票。

### 10. 其他考察过但不建议的源

- **Snap Store**：无公开安装量排行/API，不可引用。
- **StackShare**：公司技术栈展示，自报且偏 SaaS，不适合装机清单。
- **已归档清单**（Awesome-Linux-Software、snwh/ubuntu-post-install、tprasadtp/ubuntu-post-install）：失去维护即失去时效性背书，不计票。

---

## 二、采信建议汇总表

| 源 | 类型 | 时效 | 采信 | 角色 |
|---|---|---|---|---|
| SO Developer Survey 2025 | 调查 | 年度（2025-07） | **核心** | 开发工具/运行时/IDE 的大样本民意 |
| Homebrew analytics (install-on-request 365d) | 遥测 | rolling | **核心** | CLI 开发工具真实安装率 |
| Flathub stats | 遥测 | rolling | **核心** | Linux GUI 应用真实安装率 |
| Ubuntu 装机策展聚合（Omakub + ≥3 篇活跃指南，内部 ≥2 提及算票） | 人工编辑 | 活跃 | **核心** | 「装机清单」维度，与产品目标同构 |
| Arch pkgstats | 遥测 | rolling | **核心（弱位）** | Linux 原生安装率交叉验证 |
| JetBrains DevEco 2025 | 调查 | 年度（2025-10） | 辅助 | 交叉验证 SO（语言/IDE/DB），不独立投票 |
| Debian popcon by_vote | 遥测 | rolling | 辅助 | 传统 apt 基础包佐证；样本偏 Debian 服务器 |
| awesome 清单合并票（modern-unix + awesome-cli-apps + awesome-shell，≥2 收录算一票） | 人工编辑 | 参差 | 辅助 | 新潮 CLI 工具的弱票 |
| GitHub star / Octoverse | 遥测 | 年度/实时 | 仅佐证 | 写进溯源字段，不计票 |
| Snap Store / StackShare / 已归档清单 | — | — | 不用 | 无数据 / 错位 / 失修 |

---

## 三、源组合 + N 值方案

> 规模均为目测粗估（基于各源头部条目重叠度），未跑实际交集。

### 方案 A（推荐）：5 核心源，N≥3，辅助源至多补 1 票

- 核心源（每源 1 票）：SO Survey、Homebrew analytics、Flathub stats、Ubuntu 装机策展聚合、Arch pkgstats。
- 计票规则：入选需 **≥3 票，其中 ≥2 票来自核心源**；JetBrains / popcon / awesome 合并票各至多贡献 1 票。
- 预计规模：**约 50–80 条**。CLI（git、gh、docker、jq、fzf、ripgrep、htop、tmux、cmake、ffmpeg、node/python/go 工具链…）与 GUI（Chrome、Firefox、VS Code、VLC、OBS、GIMP…）都能凑齐三票。
- 偏差风险：五个核心源里遥测占三个，新潮但还没普及的工具（如 zoxide、eza）可能差一票——可由 awesome 合并票补上，风险可控；Ubuntu 服务器场景依赖策展聚合里的 checklist 类指南，覆盖偏薄。

### 方案 B（从严）：4 个硬数据源，N≥3

- 仅用「调查+遥测」：SO Survey、Homebrew、Arch pkgstats、Flathub。
- 预计规模：**约 20–35 条**，几乎全是 CLI/运行时；GUI 应用只剩 Flathub 一个数据源，永远凑不满 3 票，**桌面应用维度系统性塌陷**。
- 适用场景：如果首发 catalog 想极小化（「先发 25 条精品」），可用 B 出 CLI 骨干，GUI 维度单独用 Flathub Top + 装机指南人工补。

### 方案 C（从宽）：8 源全计票，N≥3

- 核心 5 源 + JetBrains + popcon + awesome 合并票全部平权。
- 预计规模：**约 120–180 条**。
- 偏差风险高：SO 与 JetBrains 同质（语言/IDE 双倍计票）、awesome 与 Omakub 同温层（Rust 系新潮 CLI 极易凑 3 票），清单会向「HN 时髦工具」膨胀，违背「必备」定位；不推荐首发用。

**N 值结论**：N≥3（配 5 核心源 + 「核心票 ≥2」约束）是甜点位。N≥2 会让任意一对同温层源（awesome×Omakub、SO×JetBrains）单独抬人入选；N≥4 则 GUI 应用和服务器工具大面积漏选。

---

## 四、机械标准必然漏掉的「公认必备」与兜底规则

### 会被漏掉的典型

| 软件 | 为什么漏 |
|---|---|
| `build-essential` | Ubuntu 特有 metapackage：SO 调查不问、Homebrew 没有、Arch 叫 base-devel、awesome 不屑于列；只有运维 checklist 偶尔提（Ubuntu Portal 第 16 条） |
| `curl` / `wget` | 太基础：macOS 预装所以 Homebrew 排名极低（wget 仅 0.09%）、调查不问、清单不列；但它是几乎所有官方安装文档的第一步 |
| `ca-certificates` / `gnupg` | 纯前置依赖，无人「推荐」它，但 Docker 等官方 apt 源配置步骤明确要求 |
| `git` 边缘情况 | git 本身票够，但 `git-lfs` 这类周边可能差票 |
| `openssh-server` | Server/SSH 场景的命脉，桌面向指南不提、调查不问 |
| `unzip` / `zip` / `tar` 周边 | 同 curl，预装假象 + 太基础 |
| `software-properties-common`、`apt-transport-https` | 添加第三方源的工序性依赖，任何「软件清单」都不会列 |
| `htop` / `tmux` 边缘情况 | 可能刚好 2 票（popcon+art-of-command-line 都是辅助票），核心票不足 |
| `ufw`、`unattended-upgrades` | 安全工序类，只在 checklist 类指南出现 |
| `python3-pip` / `python3-venv` | Ubuntu 把它们从 python3 拆出来，外部源按「python」计票看不见 |

### 兜底规则建议（三条，全部可溯源）

1. **Bedrock 白名单**：人工维护一小撮（~10–20 条）系统底座包（build-essential、curl、wget、ca-certificates、gnupg、unzip、openssh-server、software-properties-common、python3-pip/venv…），溯源字段写 `bedrock`，理由必须落在两类之一：(a) 是 catalog 内 ≥k 个其他条目官方安装步骤的前置（例：Docker 官方 apt 安装文档要求 ca-certificates+curl+gnupg）；(b) Debian popcon by_vote 高位的传统基础包。白名单进 PR 评审，不走机械计票。
2. **依赖引证自动票**：凡被 ≥2 个已入选条目的官方安装文档明确要求的工具，自动获得入选资格（这条会自然捞回 curl/gpg/ca-certificates，且每条都有可引用的官方文档 URL）。
3. **类别空洞复查**：机械交集跑完后，按类别（编译工具链 / 版本管理 / 容器 / 终端 / 编辑器 / 浏览器 / 媒体 / 系统监控 / 安全）检查空洞，每个空洞类别若为空必须显式记录「为何为空或人工补了什么」，防止整个维度静默塌陷（方案 B 的 GUI 塌陷就是此类）。

---

## 五、关键引用清单（汇总）

- SO Survey 2025：<https://survey.stackoverflow.co/2025/technology>（press release：<https://stackoverflow.co/company/press/archive/stack-overflow-2025-developer-survey/>）
- Octoverse 2025：<https://octoverse.github.com/>
- Omakub：<https://github.com/basecamp/omakub>、<https://omakub.org/>
- It's FOSS 24.04 指南：<https://itsfoss.com/things-to-do-after-installing-ubuntu-24-04/>
- FOSSPost 指南：<https://fosspost.org/things-to-do-after-installing-ubuntu/>
- Ubuntu Portal checklist：<https://ubuntuportal.com/guides/ubuntu-2404-post-install-checklist/>
- Hacking the Hike 指南：<https://www.hackingthehike.com/ubuntu2404-guide/>
- modern-unix：<https://github.com/ibraheemdev/modern-unix>；awesome-cli-apps：<https://github.com/agarrharr/awesome-cli-apps>；awesome-shell：<https://github.com/alebcay/awesome-shell>；Awesome-Linux-Software（已归档）：<https://github.com/luong-komorebi/awesome-linux-software>；art-of-command-line：<https://github.com/jlevy/the-art-of-command-line>
- Debian popcon：<https://popcon.debian.org/by_inst>、FAQ：<https://popcon.debian.org/FAQ>；Ubuntu 后端下线：<https://bugs.launchpad.net/bugs/1990247>、<https://lwn.net/Articles/826471/>
- JetBrains DevEco 2025：<https://devecosystem-2025.jetbrains.com/>、<https://blog.jetbrains.com/research/2025/10/state-of-developer-ecosystem-2025/>
- Homebrew analytics：<https://formulae.brew.sh/analytics/>、API：<https://formulae.brew.sh/docs/api/>
- Arch pkgstats：<https://pkgstats.archlinux.de/>
- Flathub stats：<https://flathub.org/stats/>、<https://docs.flathub.org/docs/for-app-authors/maintenance>、<https://flathub.org/en/year-in-review/2025>

## Caveats / Not Found

- 各方案的清单规模是**头部重叠目测**，落地前应写脚本实际跑一遍交集再定稿 N。
- Snap Store 无公开安装统计（确认不可用）；Flathub 数据与 Ubuntu snap 生态存在分发渠道偏移。
- Homebrew analytics 的 Linux 子集占比未找到公开拆分数据。
- Omakub 完整软件清单未逐项核对官方 manual（引用的是 repo + 第三方报道的清点），落地计票时应以仓库 `install/` 目录为准。
