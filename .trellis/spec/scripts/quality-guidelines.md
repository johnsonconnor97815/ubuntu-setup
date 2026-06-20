# 质量与校验 —— 提交前必过

> 无编译工具链。校验靠静态检查 + 脚本自带子命令。对应 CLAUDE.md「构建 / 校验命令」一节。

---

## 静态检查(必过)

```bash
# 语法检查——bootstrap、两个库、每个脚本、launcher
for f in bootstrap.sh lib/common.sh lib/ui.sh swkit scripts/*.sh; do bash -n "$f"; done

# shellcheck(保持零告警)。所有文件都 source lib,带 -x 跟随 source、
# 用 SCRIPTDIR 让 source-path 相对每个文件解析:
shellcheck -x --source-path=SCRIPTDIR swkit scripts/*.sh lib/common.sh lib/ui.sh bootstrap.sh

./bootstrap.sh --help   # 用法说明
```

**目标:`shellcheck` 零告警。**

## 脚本契约自测(每个新/改脚本)

用脚本自己的子命令测:

- `<script> meta`:字段齐全(`key`/`name`/`category`/`ops`/`desc`),`ops` 与实现**一致**,且 **`ops` 不含 `ui`**。
- `<script> status`:可独立运行(装前/装后都不炸),退出码语义正确(0 当且仅当已装)。
- `<script> help`:不炸。
- `<script> ui` 在**无 TTY** 下:打印指引并**退 0**。
- 富屏渲染无法 headless 自动测,用伪终端冒烟:

```bash
printf 'q' | TERM=xterm-256color script -qec '<script> ui' /dev/null
# 确认渲染不崩、q 干净退出、终端复原
```

## 贡献者工作流

1. `cp scripts/TEMPLATE.sh scripts/<key>.sh`,保留结构。
2. **一切提权/包/文件操作走 lib helper**,绝不裸 `sudo`/`apt-get`/`apt-key`/`sudo npm`(见 [../lib/safety-contract.md](../lib/safety-contract.md))。
3. `meta` 的 `ops` 恰好列实现了的操作;幂等(闸在 `status`);改文件前 `backup_file`、追加前 `grep`(`append_once`)。
4. 先计划后执行、fail-fast、不回滚(重跑即补救,故须幂等)。
5. 测试顺序:`bash -n` → `shellcheck -x` → 脚本 `status`(装前/装后)→ `ui` 无 TTY 退 0 →(伪终端冒烟)→ 确认后真跑。
6. 改动提交到**本仓库**(普通 git 流程),清晰 commit。kit 原地从 clone 跑,改完即生效;只有改 `skills/` 才需重跑 `bootstrap.sh` 刷新 `~/.claude`/`~/.codex`。

## 禁止写法(没有原语支持)

- `sudo npm install -g` / 任何以 root 跑 npm 全局安装。
- 整体 root 跑脚本逻辑(只 `sudo_run` 单条命令)。
- `apt-key`(用 `add_apt_keyring`/`add_apt_source`)。
- 裸 `apt-get`(用 `apt_install`/`apt_remove`/`apt_update_once`)。
- 自写 NOPASSWD 规则、echo/pipe 密码进 `sudo -S`、存密码。
- 按可翻译文案判断系统状态(按退出码/稳定文本)。

## 安全考量(开源产品)

脚本会在陌生人机器上跑 `sudo`,这是真实攻击面。缓解:lib 原语让安全写法成默认;skill 强制先计划后执行 + 用户确认;脚本经正常 git 评审才发布(`git diff` 可审);绝不自动写 NOPASSWD;LLM 在用户机器只**运行**已发布脚本,不在运行时生成/改写脚本。
