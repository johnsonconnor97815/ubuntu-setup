# 配置检查与恢复

## 设置依据与检查边界

- [OpenAI：全局 AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)：全局覆盖文件优先、项目指令可能覆盖、新启动时加载、默认指令大小限制。
- [OpenAI：配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)：`hide_agent_reasoning` 隐藏推理事件；`model_verbosity` 是另一项设置，本方案不修改它。
- [OpenAI：Skill 发现](https://learn.chatgpt.com/docs/build-skills)：仓库入口为 `.agents/skills`，支持指向实际 Skill 目录的软链。

以目标机安装的 Codex CLI 为准。脚本在隔离目录中确认 CLI 会拒绝错误类型的 `hide_agent_reasoning`，再用 `codex features list` 读取完整候选配置；任一步失败都不写入目标文件。无法确认支持时，先核对对应版本的官方文档。

这些检查不调用模型、不迁移账号，只确认目标设置的类型支持和候选配置可解析；不能证明所有配置项生效、全局规则已加载或实际回复符合标准。部署后仍需完成 [Skill 中的加载与回复验收](../SKILL.md#验收标准)。

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

测试使用临时目录和模拟 CLI，覆盖配置保护、重复执行和失败处理。它们不能代替目标机的原生 CLI 检查、浏览器显示及实际回复验收。
