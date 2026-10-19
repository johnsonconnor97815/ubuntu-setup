# 按任务选择 ChatGPT 模型与思考强度

**对你常做的代码修改、Android 分析和 Linux 排障，建议把 GPT-6.1 Sol · Medium 作为 Work/Codex 的日常起点；疑难综合分析再试 GPT-6 Astra；规则明确的批量整理可用 GPT-6 Luna。** 如果使用普通 Chat，日常问答从 Instant 开始，需要分析时选 Medium，复杂问题再升 High 或 Extra High。这些是依据官方定位给出的使用建议，本次没有运行模型对比测试，不能称为你的任务上的最优组合。思考强度可以理解为允许模型投入多少精力推敲和检查；更高档通常增加等待和用量，不能保证结果更好。([官方模型选择指南](https://learn.chatgpt.com/docs/model-selection)、[Astra 使用量与质量说明](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex))

核对日期：**2026-10-09**。本次已使用 **Exa、Tavily、Context7** 检索并交叉核对 OpenAI 官方资料。三种工具主要查询同一套官方材料，因此不构成三份独立性能评测；未检查你的账户菜单，也未实测 API 或修改主机。

**先看使用入口，才能选对名称。** 普通 Chat 主要提供对话和问答；Work 面向报告、分析等完整交付；Codex 提供代码、差异、测试和审查等开发视图。当前普通 Chat 以 `GPT-6` 配合档位展示，Work/Codex 则可以直接选 Sol、Astra、Luna 等型号。([ChatGPT 使用说明](https://learn.chatgpt.com/docs/use-chatgpt)、[模型说明](https://learn.chatgpt.com/docs/models))

普通 Chat 的当前对应关系如下。表内“适合的任务”是把官方档位定义转成日常选择建议。([Chat 模型与档位](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)、[档位定义](https://help.openai.com/en/articles/11165333-chatgpt-enterprise-and-edu-models-and-limits))

| 普通 Chat 选项 | 实际对应 | 适合的任务 |
| --- | --- | --- |
| GPT-6 · Instant | GPT-6 Sol | 简短问答、翻译、改措辞、整理现成材料，重视响应速度 |
| GPT-6 · Medium | GPT-6 Sol | 解释原理、比较方案、一般分析，适合作为分析类问题的起点 |
| GPT-6 · High | GPT-6 Sol | 复杂排错、多步计划、多个来源的综合判断 |
| GPT-6 · Extra High | GPT-6 Sol 的最高思考档 | 特别困难、需要细致检查且可以接受更多等待的问题 |
| GPT-6 · Pro | GPT-6 Astra | 最难的综合分析和高要求成果；它涉及模型变化 |

**Plus/Pro 的 Instant 当前不会因问题变难而自动升档，写“认真想”也不会改变所选档位。** 需要更深分析时，应在界面切换；托管工作区可能另有管理员设置。GPT-5.6 Sol 仍是独立选项，现有流程依赖它时可以保留并比较；本指南主要讨论新模型。选项还取决于套餐、客户端、工作区及发布进度：Plus 可使用 Work/Codex 的 Astra，并不因此获得普通 Chat 的 GPT-6 Pro。([Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)、[工作区说明](https://help.openai.com/en/articles/11165333-chatgpt-enterprise-and-edu-models-and-limits)、[Astra 访问与用量](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex))

**Work/Codex 可以先按任务类型选模型，再调强度。** 官方当前推荐的主线如下；这里的“起点”是产品使用建议，与 API 不传参数时的默认值需要分开理解。

| 模型 | 官方主要定位 | 建议起点与调整 |
| --- | --- | --- |
| GPT-6.1 Sol | 复杂编码、操作电脑、多步骤专业工作；兼顾质量和用量 | 官方通用建议先用客户端当前默认档位；具体技术任务可从 Medium 开始。([型号页](https://developers.openai.com/api/docs/models/gpt-6.1-sol)、[任务选择指南](https://learn.chatgpt.com/docs/model-selection)) |
| GPT-6 Astra | 最难的推理、编码、研究和跨应用完整任务 | 官方通用起点为 Light；综合项目可用 Medium，严格分析可试 Extra High。([模型说明](https://learn.chatgpt.com/docs/models)、[任务选择指南](https://learn.chatgpt.com/docs/model-selection)) |
| GPT-6 Luna | 目标明确、反复执行的抽取、分类、转换、结构化摘要 | 官方通用起点为 High；已明确范围的小修改和简单提取可降到 Low。([模型说明](https://learn.chatgpt.com/docs/models)、[任务选择指南](https://learn.chatgpt.com/docs/model-selection)) |

Luna 的两个建议针对不同情形：尚未细分任务时采用通用起点；已经知道输入、规则和合格输出时，可以尝试较低档。Astra 同样能用低档处理保留语气与事实细节的改写，并非只有难题才能使用。若不在意等待和用量，官方允许以 Astra 为默认；日常反复做工程任务时，Sol 是值得先比较的选择。([官方选择指南](https://learn.chatgpt.com/docs/model-selection))

下面把这些定位应用到你的常见工作。**具体组合与升级条件是研究建议，没有在你的项目上测量排名。** 依据为官方的模型定位和任务组合建议。([模型选择指南](https://learn.chatgpt.com/docs/model-selection))

| 任务 | 建议起点 | 何时升级或换模型 | 必须检查的结果 |
| --- | --- | --- | --- |
| 提取日志字段、整理已有记录、批量格式转换 | Luna · Low | 持续漏掉复杂规则时先补规则，再提高强度 | 数字、版本、路径、字段是否完整 |
| 小功能、单模块修复、脚本维护 | 6.1 Sol · Medium | 多文件联动或反复失败时试 High/Extra High | 实际差异、相关测试、原功能 |
| Linux 依赖、配置和常规故障定位 | 6.1 Sol · Medium | 多服务相互影响、证据矛盾时试 Astra · Medium | 完整报错、环境版本、根因及功能验证 |
| APK/DEX 调用链、跨 Java/Native 行为分析 | 6.1 Sol · Medium；困难综合问题用 Astra · Medium | 多层动态加载、混淆或证据冲突时试 Extra High | 代码位置、执行条件；区分静态可能性与实机结果 |
| 联网调查、比较资料、形成报告 | 6.1 Sol · Medium | 来源冲突大、判断要求高时试 Sol/Astra · Extra High | 来源日期、直接出处、事实与推断 |
| 网站、配套文档、演示等完整交付 | 6.1 Sol · Medium | 成品要求高时试 Extra High；跨工具步骤很多时试 Astra | 文件完整、展示效果、各处内容一致 |

**提高强度应针对已发现的问题。** Light/Low 适合范围清楚的工作；Medium 是平衡起点；High/Extra High 适合步骤多、资料多、需要权衡的问题。同名档位不能横向当作统一能力分数，官方明确指出 Astra Low 可以胜过 Sol High；提高强度也不保证输出更好。([模型档位说明](https://learn.chatgpt.com/docs/models)、[Astra 使用建议](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex))

实用的调整顺序是：先补齐目标、源文件、最新资料和验收条件；仍有推理遗漏，再升一档；复杂度超过当前模型的稳定表现时，换 Astra 比较。用相同材料检查答案是否正确、是否漏项、是否完成任务，再看等待和用量。**缺失事实需要查来源，代码是否可用需要测试，真实设备行为需要实机证据；高档位不能替代这些。** 这套顺序是根据官方提示与评测建议形成的工作方法。([推理模型指南](https://developers.openai.com/api/docs/guides/reasoning)、[部署检查清单](https://developers.openai.com/api/docs/guides/deployment-checklist))

Max 和 Ultra 适合更少见的需求：**Max 让单个模型对一项任务投入更多推理；Ultra 使用子代理分担可拆开的部分。** 因此，一个难以拆开的核心问题可比较 Extra High 与 Max；多个独立模块或研究子题才值得考虑 Ultra。多数任务不需要这两档，Luna 最高支持 Max，不支持 Ultra。([Max 与 Ultra 说明](https://learn.chatgpt.com/docs/models#know-when-to-use-max-or-ultra))

**如果通过 API 调用，按型号核对参数。** API 是程序调用模型的接口，`reasoning.effort` 控制思考投入；当前支持情况如下。

| API 型号 | 支持的 `reasoning.effort` | 已明确的 API 默认值 |
| --- | --- | --- |
| [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) | `low / medium / high / xhigh / max` | `medium` |
| [GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) | `low / medium / high / xhigh / max` | 本次查阅未找到明确声明，建议显式设置 |
| [GPT-6 Sol](https://developers.openai.com/api/docs/models/gpt-6-sol) | `none / low / medium / high / xhigh / max` | `medium` |
| [GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) | `none / low / medium / high / xhigh / max` | `medium` |

Work/Codex 的 Light 对应配置中的 `low`；普通 Chat 档位与 API 参数的完整一对一关系，本次未找到依据。公开 API 的 effort **没有 `ultra`**，也不能因为通用参数表出现 `minimal` 就认为上述型号支持它。Astra 的产品建议起点 Light 不能用来证明 API 默认是 `low`。([模型说明](https://learn.chatgpt.com/docs/models)、[推理指南](https://developers.openai.com/api/docs/guides/reasoning)、[Responses API 参数](https://developers.openai.com/api/reference/resources/responses/methods/create))

思考强度也不决定答案长度：`text.verbosity` 才主要控制输出详略。你可以要求模型仔细分析后只给简短结论。([输出详略设置](https://developers.openai.com/api/docs/guides/deployment-checklist#set-up-textverbosity))

本次资料有两处需要保留边界：Free/Go 的发布说明已宣布升级至 GPT-6 Luna，模型帮助页仍保留 GPT-5.6 Luna 口径，实际可用项以账户菜单为准；`latest-model.md` 的一次提取返回旧内容，本报告采用已交叉核对的当前 HTML 页面及各型号专属页。前者影响账户是否已收到模型，后者未被用来确定当前型号。([10 月 7 日发布说明](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)、[Chat 模型帮助页](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)、[当前 GPT-6 指南](https://developers.openai.com/api/docs/guides/latest-model))

对你而言，最有价值的下一步是选几项经常遇到、能判断成败的真实任务，保留同一份输入比较相邻配置。选出能稳定达到要求的组合后，再作为日常设置；需要升级时，也能知道究竟是缺资料、任务更复杂，还是当前模型持续漏掉关键点。
