# 磁盘清理与双模型风险报告

版本：`0.13.0`。`cleanup` 命令分两步运行：先生成 HTML 风险报告，再由用户逐项选择删除。计划阶段先用 PackyApi 提供的 JEV 模型初筛，再用独立 LLM 复核并给出风险等级；本命令不会因为模型判断结果自动删除文件。

## 能做什么

- 默认扫描当前用户的 XDG 缓存目录、`/tmp` 中属于当前用户的旧条目，以及回收站文件目录的顶层条目。
- 只把 7 天以上未修改的普通文件和目录交给 JEV；目录按内部最新修改时间判断。符号链接、套接字和其他特殊文件跳过。
- 发送给两个模型的信息都是相对路径、来源类型、文件或目录类型、大小和修改年龄；不读取、不上传文件内容。
- JEV 返回 `noul` 概率。概率大于或等于阈值时交给独立 LLM，否则标记为未复核。默认阈值是 `0.8`。
- 独立 LLM 对每个初筛通过条目返回：
  - `llm_recommendation`：`delete`、`review` 或 `keep`
  - `risk_level`：`low`、`medium` 或 `high`
  - `risk_score`：`0` 到 `100`
  - `llm_reason`：中文理由
- HTML 报告列出条目 ID、完整路径、类型、大小、年龄、JEV 概率、独立 LLM 建议、风险和理由。
- 执行前重新核对路径、类型、大小、顶层与目录内部最新 `mtime`、inode、设备号和目录总大小；任何不匹配都跳过该项。

## 使用

先在环境中提供 PackyApi 令牌：

```sh
export PACKY_API_KEY='<你的 PackyApi 令牌>'
```

JEV 默认请求 `https://cf.api.fan/v1/systemone`，模型为 `jev-latest`。独立 LLM 默认使用本机 Ollama 的 OpenAI 兼容接口：

```sh
export PACKY_API_BASE_URL='https://cf.api.fan/v1'
export PACKY_JEV_MODEL='jev-latest'
export UBUNTU_SETUP_REVIEW_LLM_BASE_URL='http://127.0.0.1:11434/v1'
export UBUNTU_SETUP_REVIEW_LLM_MODEL='qwen3.8:27b'
```

生成报告：

```sh
./ubuntu-setup cleanup --state-dir ~/.local/state/ubuntu-setup/cleanup --format json
```

计划保存到 `plans/<plan-id>.json`，HTML 报告保存到 `reports/<plan-id>.html`，权限为 `0600`；终端输出还包含 `plan_path`、`report_path` 和汇总结果。默认请求浏览器打开报告，自动化调用可加 `--no-open`。

清理状态目录必须是仓库之外的私有目录。目录由当前用户创建和管理，权限为 `0700`。

确认删除前必须逐项查看报告中的路径和风险。删除是永久删除，不进入回收站；必须提供计划文件、精确的计划 ID 和至少一个条目 ID：

```sh
./ubuntu-setup cleanup --delete \
  --state-dir ~/.local/state/ubuntu-setup/cleanup \
  --plan-file <plan-path> \
  --confirm <plan-id> \
  --select <entry-id> \
  --select <entry-id>
```

执行记录保存到 `executions/<plan-id>.json`。同一个计划只能执行一次；条目变化后须重新生成计划。只有用户选中的条目会被核对和删除，未选择条目不会处理。

常用参数：

| 参数 | 默认值 | 含义 |
| --- | --- | --- |
| `--root PATH` | 无 | 额外扫描指定目录的顶层条目，可重复指定 |
| `--min-age-days` | `7` | 只考虑多少天未修改的条目 |
| `--max-candidates` | `50` | 最多交给 JEV 判断的数量，最大 `200` |
| `--threshold` | `0.8` | JEV 初筛进入独立 LLM 复核的概率阈值 |
| `--timeout` | `30` | JEV 请求超时秒数 |
| `--review-base-url` | `http://127.0.0.1:11434/v1` | 独立 LLM 的 OpenAI 兼容地址 |
| `--review-model` | `qwen3.8:27b` | 独立 LLM 模型名 |
| `--review-timeout` | `120` | 独立 LLM 请求超时秒数 |

## 边界与限制

- JEV 和独立 LLM 只是候选依据，不是删除授权；最终授权来自用户核对报告后明确选择的条目 ID 和 `--confirm <plan-id>`。
- 删除不可自动恢复。不要对没有备份的用户数据目录使用 `--root`。
- 默认不清理系统级 APT 缓存、日志、容器镜像、虚拟机磁盘或需要 root 权限的对象。
- 模型只看路径和元数据，可能误判，也不能证明文件当前没有被活动程序使用。执行后应用重建缓存属于正常情况。
- 独立复核 LLM 默认要求本机地址；远程复核服务必须使用 HTTPS，避免元数据明文出网。
- 计划阶段需要 PackyApi 和复核 LLM 都可用；任一模型失败时不生成计划，也不会删除文件。
- 自定义 `--root` 会扩大扫描范围，Agent 必须完整展示路径与风险，不能代替用户选择。
