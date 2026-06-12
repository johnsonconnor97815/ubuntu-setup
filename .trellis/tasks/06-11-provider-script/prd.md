# provider-script：script 逃生口 provider + 15 条官方脚本条目

父任务：[`06-10-catalog-launch-essentials`](../06-10-catalog-launch-essentials/prd.md)；
逐条官方步骤：final-list.json（provider_type=script 14 条）+ yarn（父 prd 追加决策：corepack script）。

## Goal

实现 `script` 类型 provider（声明式逃生口：手写 check + 官方安装命令原样收录），
15 条 script 档条目全量落地并真装验证——rust(rustup)、uv、bun、deno、pnpm、starship、
zoxide、lazygit、ollama、gradle、rclone、jupyterlab(pipx)、typescript(npm)、zed、yarn(corepack)。

## Requirements

* **script provider**（`core/providers/script.py` + 注册表 + schema 同步）：按 spec
  catalog-and-providers.md 的 script 设计——`check`（幂等探针，绝不允许恒真）、`install`
  必填、`remove`/`upgrade` 可选；命令经 runner 执行（argv 形态按 spec：spec 用 shell 字符串
  则经 `bash -lc` 之类受控形态，写明取舍并回写）。
* **提权语义（关键）**：script 条目多为**用户级安装**（rustup/uv/starship 装 `$HOME`，
  yarn 走 corepack）——默认以普通用户执行、不 sudo；少数需 root（ollama 装 /usr/local +
  systemd）→ 字段显式声明（如 `sudo: true`），逐命令提权，sudo 下不用 `~`（不可妥协③）。
  check 同样按声明的身份跑。
* **PATH 现实**：用户级安装落 `~/.cargo/bin`、`~/.local/bin` 等——check 探针不得依赖
  登录 shell PATH（用绝对路径或显式 PATH 前缀），条目注释写明 shell rc 由用户/官方脚本负责。
* **依赖**：typescript 需 nodejs(npm)、yarn 需 nodejs(corepack)、jupyterlab 需 pipx——
  `depends_on` 接既有 apt 条目；GUI 条目（zed）requires: [desktop]。
* **条目纪律**：install 用官方文档原样命令（信官方决策）+ 溯源注释；check 逐条手写真探针
  （文件/版本探测，禁 `true`）；source: official；**script 条目须人工审核**——最终报告中
  向用户明示全部 15 条的 check/install 供过目（spec：script 是最高风险类型）。
* **验证**：单元层 FakeRun 全分支（check 三态、sudo 路由、PATH 处理）；集成层 Docker 档
  遍历套件全量真跑（fresh→install→幂等复跑）；ollama 这类装 systemd 服务的——容器内
  官方脚本若不可行（探测 systemd 失败即退出等），定性记录并改走可行形态或标记归 LXD/VM 档，
  不得为凑绿弱化 check。

## Acceptance Criteria

* [ ] script provider 注册可用；schema 拒绝缺 check/install 的条目；check 恒真在评审中被拒。
* [ ] 15 条全落地：官方命令原样 + 手写探针 + 溯源注释 + 正确 depends_on/requires/sudo 声明。
* [ ] Docker 档全量真跑累计全绿（或个别条目定性记录归 VM 档，理由在案）。
* [ ] 用户级条目以非 root 身份安装验证（guest 内 ubuntu 用户），root 级条目逐命令 sudo。
* [ ] 默认套件全绿、ruff 干净；spec 回写（script 字段契约、执行形态、提权声明）。

## Out of Scope

* snap/ppa 档；script 的 upgrade/remove 路径实现（字段保留，MVP 不实现）。

## Technical Notes

* 本机基镜像旋钮 UBUNTU_SETUP_VERIFY_BASE_IMAGE=mirror.gcr.io/library/ubuntu:24.04；
  guest 内 ubuntu 用户 + NOPASSWD sudo 已具备（verify-base）。
* 官方脚本下载依赖 curl/ca-certificates（已在 catalog bedrock）；nodejs/pipx 为既有 apt 条目。
* zoxide 官方 README 明确反对发行版装法（删除线），install.sh 是官方路径——溯源注释要引用。
* typescript：npm 全局装（`npm install -g typescript`）需 root 或 prefix 取舍——按官方文档
  与「用户级优先」原则定，写明。
