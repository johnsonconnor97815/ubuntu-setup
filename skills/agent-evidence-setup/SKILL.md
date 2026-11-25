---
name: agent-evidence-setup
description: Deploy or review shared evidence and long-term-record rules for Codex and Claude Code, preserving existing global instructions. Use for restoring this profile, checking its loading, or investigating unsupported conclusions carried through documents and memory; ordinary research does not require this setup workflow.
---

# 配置证据与长期记录规则

公共规则只有 [evidence-rules.md](assets/evidence-rules.md) 一份。配置实现是本 Skill 自带的 `scripts/setup.py`；安装副本可从任意仓库使用，不依赖原仓库路径。日常规则直接写入全局指令，不要求每次任务都调用 Skill。

## 部署和检查

1. 解析本 Skill 的实际目录，读取公共规则。确认目标用户和机器，沿用会话已有授权。Python 3.11+ 是运行条件；此流程不安装工具、不复制账号，不修改模型、MCP 或权限设置。
2. 用本 Skill 绝对路径运行 `python3 <skill-dir>/scripts/setup.py plan`。仓库内也可运行 `./swkit agent-evidence plan`。默认检查两个工具；只配置一个时传 `--target codex` 或 `--target claude`。
3. 读取预览指明的全局指令，人工核对语义冲突；有导入、项目规则或组织规则时检查相关范围。脚本只检查受管区段和同名 Skill 的内容差异，不声称自动判断所有语义冲突。不要把两种检查混为一谈。
4. 已获配置授权时执行 `configure`，然后 `status`。配置前备份，保留既有文件字节、权限与属主。已有完全一致的内容不重写；不同的同名规则或 Skill 保持原样，先报告差异，再按授权处理。不要删除定制内容来让检查通过。
5. 查看私有 HTML/JSON 报告。默认请求系统浏览器打开；自动测试用 `--no-open`。规则和 Skill 写入不证明客户端加载；使用 [验证与恢复](references/verification.md) 中的新会话检查，分别记录静态匹配、实际加载、有限行为样例和长期效果。未执行或失败的项目如实报告。

默认部署到有效 `CODEX_HOME`（默认 `~/.codex`）的全局 `AGENTS` 文件，以及 `CLAUDE_CONFIG_DIR`（默认 `~/.claude`）下的 `CLAUDE.md`。两个用户级 Skill 副本分别位于 `~/.agents/skills/agent-evidence-setup` 和 Claude 配置目录下的 `skills/agent-evidence-setup`。路径参数见脚本 `--help`。源文件只维护仓库一份，副本通过内容比较核对，不能在副本中独立演进。

## 复查具体错误

用户提供案例时，对照原始要求、实际保存的记录和后续行为，定位最早失真的阶段：提取、更新、压缩、读取或回答。区分被研究对象的行为与用户目标；拒绝本身不证明其理由正确。更正规则前，先验证现有规则是否加载、错误是否受它影响。没有真实案例时可用明确标注的模拟案例检查覆盖范围，不能声称已复现或解决实际故障。

保留技术事实和真实风险，不通过更换术语来回避判断。不要把单个项目背景写成全局授权，不全面清理历史记忆；更正只覆盖已核实且在授权内的内容。更新源规则或恢复旧版本前核对副本与后续修改，恢复方法见验证参考。
