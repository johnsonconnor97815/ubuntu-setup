# 依据、验证与恢复

本标准由 2026-10-17 的用户讨论确定，作为回复偏好部署，不保证模型始终遵守。修改过程是：审查现有规则 → 保留无关配置 → 预览候选差异 → 备份 → 写入 → 检查加载 → 用真实回复验收。

## 已有依据与边界

- [OpenAI：全局 AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)：全局覆盖文件优先、项目指令可能覆盖、新启动时加载、默认指令大小限制。
- [OpenAI：配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)：`hide_agent_reasoning` 隐藏推理事件；`model_verbosity` 是另一项设置，本方案不修改它。
- [OpenAI：Skill 发现](https://learn.chatgpt.com/docs/build-skills)：仓库入口为 `.agents/skills`，支持指向实际 Skill 目录的软链。
- [NN/g](https://www.nngroup.com/articles/accordions-on-desktop/)：必要信息应直接可见，折叠本身也有操作成本。
- [GOV.UK](https://guidance.publishing.service.gov.uk/writing-to-gov-uk-standards/writing-guidelines/clear-language/)：采用常用词，必要术语首次解释，区分要求和可选事项。
- [Microsoft HAX](https://www.microsoft.com/en-us/haxtoolkit/guideline/make-clear-why-the-system-did-what-it-did/)：解释可能增加信任，却不能证明结果正确。

以上来源在 2026-10-17 已读取。可复用仍适用的依据；目标版本不匹配、配置不支持或官方行为变化时再核实，不能把本机结果外推为所有机器兼容。

原始配置过程在 `codex-cli 0.163.0` 上检查过：`codex debug prompt-input` 包含完整回复规则；本机帮助列出 F4（Inspect activity）与 Ctrl+T（完整记录）。普通用户 Shell 输出在滚动及全屏模式测试未折叠，未证明所有工具结果可折叠；不能把这些快捷键当成跨版本保证。

脚本在执行阶段用隔离目录测试错误类型会被拒绝，再让原生 CLI 读取完整候选配置；不调用模型、不迁移账号。它不使用 `--strict-config`：本次 CLI 不支持对 `features` 使用该参数，原有未知字段也可能与本任务无关。解析检查不代表所有设置生效，后续仍要验证实际加载。

## 恢复与中断续接

运行资料位于目标 `CODEX_HOME/.ubuntu-setup-response-runs/`，每次独立目录仅本人可访问。`before/` 保存修改前文件，`after/` 保存本次目标内容，`manifest.json` 记录原属主、权限、前后哈希及已完成文件；备份可能含目标机已有凭据，不能分享或提交仓库。

- 恢复前先比较当前文件与 `after/`。完全一致时，原文件存在的可恢复相应备份并核对属主、权限；原文件不存在的只删除本次新增内容，确认无其他内容后才处理空文件。
- 当前文件已有后来修改时，不能直接复制旧备份覆盖。将本次规则节和显示设置单独撤销，保留其他修改，随后再核对加载结果。
- 两个文件逐一原子替换，整组不承诺自动回滚。普通失败记录到报告后停止；强制终止可能来不及生成报告，可依据 manifest 和当前文件核对。重跑先重新探测，不只凭上次状态判定成功。
- 重复执行不改写已匹配的目标文件；仍会生成一份新的执行报告。`plan` 和 `status` 不生成报告、不创建目标目录。
- 浏览器返回成功只代表接受打开请求，不证明页面已显示；失败时用终端提供的 HTML 路径。`--no-open` 用于隔离测试或不需要浏览器的运行。

## 维护时验证

在仓库根目录运行：

```sh
python3 -m unittest discover -s test -p 'codex_response_test.py' -v
bash -n scripts/codex-response.sh
shellcheck -x --source-path=SCRIPTDIR scripts/codex-response.sh
bash test/meta_test.sh
```

测试使用临时目录和模拟 CLI；它证明配置保护、重复执行和失败处理，不证明另一台机器的原生 CLI、浏览器或模型回复。目标机仍需进行 SKILL.md 中的加载与行为验收。

2026-10-17 在本机完成了 17 项隔离测试、Bash 语法与 ShellCheck 检查、仓库组件元数据测试和 Skill 格式检查。另用原生 `codex-cli 0.163.0` 在临时目录完成首次配置和重复运行，确认已匹配文件的内容、修改时间与文件标识不变，生成了 HTML/JSON 报告且未迁移账号；`codex debug prompt-input` 确认能发现本 Skill。未调用模型验证实际回复，也未验证浏览器显示。
