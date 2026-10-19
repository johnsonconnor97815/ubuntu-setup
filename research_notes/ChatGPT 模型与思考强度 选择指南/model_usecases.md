# 当前模型定位与任务选择：2026-10-09 联网核对

## 1. 当前模型各自适合什么问题？

### Takeaway

官方当前主要推荐 GPT-6 Astra、GPT-6.1 Sol、GPT-6 Luna。三者分别侧重最难的综合任务、兼顾成本的复杂工作、明确且重复的大量任务。产品菜单与 API 型号不是一回事；本笔记的 Sol/Luna 建议用于 Work/Codex 或 API，不能直接当成普通 Chat 菜单。

### Cited Findings

- Astra 是官方最高能力选择，面向难度高的推理、编码、研究、操作电脑和制作文档。官方强调它可在代码、浏览器、专业软件之间完成多步流程。——[GPT-6 指南](https://developers.openai.com/api/docs/guides/latest-model)、[Astra 型号页](https://developers.openai.com/api/docs/models/gpt-6-astra)
- GPT-6.1 Sol 面向复杂编码、操作电脑及专业工作，官方定位是较低成本下接近 Astra 的表现；官方明确要求在自己的任务上比较质量与成本。——[Sol 型号页](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- Luna 面向明确范围、高频、大量的任务；Work/Codex 文档列举抽取、分类、转换、结构化摘要，尤其适合已经知道合格输出是什么的工作。——[Luna 型号页](https://developers.openai.com/api/docs/models/gpt-6-luna)、[Work/Codex 模型](https://learn.chatgpt.com/docs/models.md)
- Work/Codex 的当前推荐是：复杂编码及代理流程优先考虑账户可用的 GPT-6.1 Sol；最难的跨工具完整任务用 Astra；明确可重复任务用 Luna。文档说 GPT-6.1 Sol、GPT-6 Sol、GPT-6 Luna 在 ChatGPT 的 Work 和 Codex 中可用，不在 Chat 中；具体访问还受套餐、客户端、工作区设置及推出进度影响。——[Work/Codex 模型](https://learn.chatgpt.com/docs/models.md)
- 官方选择指南认为，若不在意用量和完成时间，可以默认 Astra；需要兼顾成本及延迟时，按任务与思考档位选。它同时要求用相同输入做比较，保留能够达标的较轻配置。——[选择指南](https://learn.chatgpt.com/docs/model-selection)

### Inferences

- 对常见工程工作，GPT-6.1 Sol 是合理的日常主力候选；Astra 适合作为疑难分析和高要求交付的升级选项。这里是把官方定位应用到工作流的建议，不是用户项目上的实测结论。
- Luna 不需要被理解成只能回答简单知识问答；明确、有规则、有输出检查方式的大量处理，更符合官方列举的强项。
- 不能仅从型号大小或“思考更久”推导出对用户每项工作都更好。资料是否齐全、是否实际运行验证，仍影响结果是否可信。

### Gaps

- 未检查用户账户实际模型菜单、套餐或工作区策略，不承诺每个选项都可见。
- 没有在用户的 Android 分析、Ubuntu 排障或仓库修复样本上跑对比测评。没有可引用的“某档成功率提高多少”或“绝对最优”结果。
- 本分工未独立抓取 Chat 的 GPT-6 菜单说明；普通 Chat 的具体名称与底层对应应采用 Chat 研究分工的已核实材料。

## 2. 官方对思考强度的建议是什么？

### Takeaway

需要分清客户端的通用起点、具体任务的推荐组合、API 参数默认值。它们不是同一个问题，不能一概说“所有模型默认 Medium”或“所有任务都设最高”。

### Cited Findings

- Work/Codex 的通用起点：Sol 先用客户端给出的默认档位，Luna 从 High 开始，Astra 从 Light 开始；Astra 的 Light 在配置中是 `low`。需要更多计划、分析和检查时再调高。——[Work/Codex 模型，Pick a reasoning effort](https://learn.chatgpt.com/docs/models.md)
- 同一文档解释：Light/Low 适合快速、范围明确的任务；Medium 平衡速度和深度；High/Extra High 适合难度高、步骤多、资料多或需要权衡的工作。不同代模型的档位不能完全对齐。——[Work/Codex 模型](https://learn.chatgpt.com/docs/models.md)
- 官方按具体任务给出的组合如下。——[选择指南](https://learn.chatgpt.com/docs/model-selection)

| 模型与强度 | 官方对应任务（意译） |
|---|---|
| Luna · Low | 小范围修改、范围清楚的问题、简单资料抽取 |
| Luna · Extra High | 跨应用找最新上下文、安排优先级、解决约束明确的问题 |
| GPT-6.1 Sol · Medium | 复杂技术工作、多个部分需要配合且预计会继续修改的成果 |
| GPT-6.1 Sol · Extra High | 高完成度交付、成套视觉设计、从相互冲突的证据作判断 |
| Astra · Low | 保留事实和语气细节的精简写作、改写 |
| Astra · Medium | 需要广泛背景、可靠交互、完整交付的综合项目 |
| Astra · Extra High | 要求严格的分析和复杂成果 |

- Max 给单个模型更多时间深入处理一个任务；Ultra 使用子代理并行处理能拆开的不同部分。大多数任务不需要 Max 或 Ultra。Luna 可到 Max，不支持 Ultra。——[Work/Codex 模型，Know when to use Max or Ultra](https://learn.chatgpt.com/docs/models.md)
- GPT-6.1 Sol API 接受 `low`、`medium`、`high`、`xhigh`、`max`，`medium` 是 API 默认值；不接受 `none` 或 `minimal`。这并不证明 ChatGPT 客户端一定默认同一个档位。——[Sol 型号页](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- 官方选择指南要求把其推荐作为起点，考虑执行频率、是否等着结果、结果是草稿还是对外交付，以及质量要求；用相同输入试不同设置。——[选择指南](https://learn.chatgpt.com/docs/model-selection)

### Inferences

- “Luna 通用起点 High”与“Luna Low 适合小改/提取”不是必须二选一：前者是不了解任务时的产品起点，后者是任务已明确后的针对性降档。
- 建议的升级顺序：先补齐缺失资料与验收要求；复杂度确实增加时升档；问题仍含糊、证据冲突严重或轻模型持续漏关键点，再试更强模型。建议顺序并非官方测量结论。
- 不应把 Ultra 画成单个模型继续想得更深的最后一档。它改变了工作组织方式，适合可拆分任务；Max 更接近单个难题需要长时间探索。

### Gaps

- 没有官方证据说明 `high` 到 `xhigh` 在每种用户任务上都产生稳定收益，也没有证据支持“全部选最高最省返工”。
- 未测延迟、用量、错误率；不输出预计节省百分比或每项任务固定分钟数。
- API 全型号参数、Pro 与 Ultra 的精确区别由思考控制研究分工覆盖；本笔记只保留解释任务选择所需的边界。

## 3. 如何应用到用户常见的技术工作？

### Takeaway

下面是依据官方定位推导的可执行起点，不是官方逐项认证或已测排名。日常工程可从 Sol Medium 开始；范围很小的重复处理可用 Luna Low；资料分散、证据矛盾、要求很高的任务可试 Astra Medium/Extra High。

### Cited Findings

- Sol Medium、Astra Medium/Extra High、Luna Low 的任务类别有官方直接支持；Android/APK、Ubuntu 运维的具体映射属于下表推断。——[选择指南](https://learn.chatgpt.com/docs/model-selection)
- Astra 官方适用领域包括复杂编码、研究与多工具流程，Work/Codex 文档强调为它提供来源、模板、约束和检查标准。——[GPT-6 指南](https://developers.openai.com/api/docs/guides/latest-model)、[Work/Codex 模型](https://learn.chatgpt.com/docs/models.md)

### Inferences

| 用户要做的事 | 建议起点 | 何时升级 | 交付检查重点 |
|---|---|---|---|
| 翻译短段落、改措辞、提取日志字段、把已有记录整理成表 | Luna Low | 必须保留复杂责任边界、语气和细节时可试 Astra Low | 对照原文，数字、路径、版本与含义不丢 |
| 单模块修复、加一个明确功能、检查已有脚本 | GPT-6.1 Sol Medium | 多文件联动、非直观边界、修改后反复失败时试 High/Extra High 或 Astra Medium | 实际差异、相关测试、原功能是否受影响 |
| Linux 常规故障定位、依赖和配置核查 | GPT-6.1 Sol Medium | 多服务相互影响、日志互相矛盾、涉及网络/驱动/启动链时试 Astra Medium 或 Extra High | 完整错误、环境版本、根因证据、功能验证 |
| 从 APK/DEX 已知代码提取调用点和字段映射 | GPT-6.1 Sol Medium；纯批量字段抽取可用 Luna Low | 调用链长、混淆、多层动态加载或证据相互冲突时试 Astra Extra High | 具体代码位置、路径条件、静态与运行时证据分开 |
| 复杂 Android 行为链、跨 Java/Native 分析、疑难兼容性问题 | Astra Medium，明确为困难完整分析时 Extra High | 单个核心难题经过验证仍卡住，才试 Max | 能复现的证据链；不能把静态可能性当实机成功 |
| 联网调查、多个来源比较、把冲突证据写成报告 | GPT-6.1 Sol Medium；高要求矛盾证据综合可选 Sol Extra High/Astra Extra High | 研究问题含糊、来源有较大矛盾、要求严格时用 Astra | 来源时效、逐项出处、事实和推断分开 |
| 做网站、设计配套文档和演示、从材料完成一整套交付 | GPT-6.1 Sol Medium | 成品要求高、跨文件一致性强时 Sol Extra High；步骤和工具很多时 Astra Medium | 文件完整、展示效果、引用和数值一致 |
| 审多个相互独立的模块、并行查多个研究子题，再综合 | 可用 Astra 或 Sol 的 Ultra（若界面支持） | 不把不可拆分的单问题默认改为 Ultra | 各分工边界、冲突合并、最终完整复核 |

表内具体用户任务和升级条件均为研究者推断，依据为[模型选择指南](https://learn.chatgpt.com/docs/model-selection)与[Work/Codex 模型说明](https://learn.chatgpt.com/docs/models.md)。检查点来自这些任务需要验证的实际结果，不能声称调高强度可替代它们。

### Gaps

- 推荐是否最适合该用户，需要用几项真实常见任务做同输入比较；此次联网调查没有执行这些比较。
- 来源一致性记录：Exa 抓取 `https://developers.openai.com/api/docs/guides/latest-model.md` 时返回旧标题 Using GPT-5.6；随后 Tavily 与 Exa 都抓取无 `.md` 的[当前 HTML 页面](https://developers.openai.com/api/docs/guides/latest-model)，均返回 Using GPT-6 与 Astra/6.1 Sol/Luna。原因未证实，可能是缓存或页面同步差异。当前结论采用已交叉抓取的 HTML 页面及当前型号页；未把旧 Markdown 内容当成当前型号列表。
