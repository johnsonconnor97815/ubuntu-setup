# skills/ — SKILL.md 写作约定

> **指针文档。** 权威定位在 `CLAUDE.md`「项目目标」§2-3:三个入口(bootstrap TUI / `swkit` / LLM 经 skill)**地位等同,都只是调用脚本**。skill 散文降级为「脚本必须满足的契约 + 如何用脚本」。本文件只补锚点与边界。

适用范围:写 / 改 `skills/<name>/SKILL.md`。现有三个,照着写:
- `skills/ubuntu-install/SKILL.md` — 通用「用脚本装/卸/查软件」。
- `skills/zsh-setup/SKILL.md` — zsh 组件管理器(挑组件、SSH/Nerd Font 取舍、锁定安全)。
- `skills/claude-extensions/SKILL.md` — Claude Code 扩展管理器(MCP/插件/skill 三轴)。

## 核心边界:skill 讲「怎么用」,不讲「怎么写」

- skill **运行并推荐**脚本(挑对脚本与选项、解释取舍、锁定安全),**不在运行时编写或演进脚本**。
- 唯一的「怎么做」来源是脚本(`do_install`/`do_configure` 等);skill **不得平行实现**安装/配置逻辑——那正是项目消除的旧「双写」问题。
- 脚本缺某能力 = 维护者在**仓库里**加/改脚本(`cp scripts/TEMPLATE.sh`),**不是**在用户机器上运行时改脚本。任意 git 插件等「无需改码」的扩展点(如 `add-plugin <git-url>`)除外。

## 写作要点

- **Frontmatter**:`name` + `description`。`description` 是触发器,写成「Use when the user wants to…」并铺满同义触发词(现有三个 skill 的 description 是范本)。
- **指向脚本**:正文驱动 `swkit <software> <action>`(或 `scripts/<key>.sh <action>`),列出该脚本的真实动作,不复述脚本内部实现。
- **锁定安全**:必须转达 `sudo_run` 的 `RC_NEED_SUDO=97` 行为——LLM 的 shell 无 TTY 输密,脚本会打印「请手动跑 sudo …」并退 97;让用户开免密 sudo(重跑 `./bootstrap.sh` 切开关)或自己跑那行。**绝不**让 LLM 输入/管道/存储密码或写 NOPASSWD。
- **品味**:在陌生人机器上给保守默认(headless/SSH 友好),解释取舍(token 成本、运行时/密钥/作用域、字形需本地客户端终端渲染等),不强加偏好。

## 部署(与脚本不同)

脚本**原地从 clone 跑**(`swkit` 直指 clone,改完即生效)。但 **skills 必须部署**:`bootstrap.sh` 把每个 skill 拷到 `~/.claude/skills/<name>/`(Claude Code)与 `~/.codex/prompts/<name>.md`(Codex)——这是两者从固定位置读 skill 的要求。**改了 `skills/` 必须重跑 `bootstrap.sh`** 刷新,否则用户机器上的副本是旧的。

## 漂移纪律

UI 契约(`ui()` 约定 / `ui` 非 op / 三档降级)与安全契约同时落在 `lib/`、`scripts/TEMPLATE.sh` 与各 `SKILL.md`——**改一处必查其余**。`SKILL.md` 引用的脚本动作/flag 必须与脚本实现一致(改脚本接口时回头同步对应 skill)。
