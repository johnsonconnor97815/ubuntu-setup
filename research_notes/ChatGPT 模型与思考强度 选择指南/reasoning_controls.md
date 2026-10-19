# 思考强度：产品控制、API 支持与选择依据

## 1. 各模型实际支持什么档位，默认值是什么？

### Takeaway

截至 2026-10-09，公开 API 的 GPT-6 Astra 和 GPT-6.1 Sol 支持 `low / medium / high / xhigh / max`，GPT-6 Sol、GPT-6 Luna 另支持 `none`。6.1 Sol、6 Sol、6 Luna 的 API 默认值明确为 `medium`；本轮没有找到 Astra API 默认 effort 的明确声明，不能拿 Work/Codex 的推荐起点替代。— [Astra 模型页](https://developers.openai.com/api/docs/models/gpt-6-astra)；[6.1 Sol 模型页](https://developers.openai.com/api/docs/models/gpt-6.1-sol)；[6 Sol 模型页](https://developers.openai.com/api/docs/models/gpt-6-sol)；[Luna 模型页](https://developers.openai.com/api/docs/models/gpt-6-luna)

### Cited Findings

| API 模型 | 支持的 `reasoning.effort` | 明确写出的 API 默认值 | 直接来源 |
| --- | --- | --- | --- |
| GPT-6 Astra | `low, medium, high, xhigh, max` | 当前查阅的专属页和总指南未明确写出 | [模型页](https://developers.openai.com/api/docs/models/gpt-6-astra) |
| GPT-6.1 Sol | `low, medium, high, xhigh, max` | `medium` | [模型页](https://developers.openai.com/api/docs/models/gpt-6.1-sol) |
| GPT-6 Sol | `none, low, medium, high, xhigh, max` | `medium` | [模型页](https://developers.openai.com/api/docs/models/gpt-6-sol) |
| GPT-6 Luna | `none, low, medium, high, xhigh, max` | `medium` | [模型页](https://developers.openai.com/api/docs/models/gpt-6-luna) |

- 通用 API 枚举包含 `none, minimal, low, medium, high, xhigh, max`，但不代表每个模型全部支持。GPT-6.1 Sol 明确不支持 `none` 和 `minimal`；GPT-6 Astra 设置 `none` 会返回 HTTP 400。不要将通用 schema 或本会话工具枚举当成某模型的支持表。— [推理模型指南](https://developers.openai.com/api/docs/guides/reasoning)
- Work/Codex 官方建议：6.1 Sol 先用客户端现有默认 effort；Astra 从 `Light` 开始，配置名为 `low`；Luna 从 `High` 开始。这是面向产品的建议，不能写成 Luna 的 API 默认值为 High，也不能写成 Astra 的 API 默认值为 low。— [Models：Pick a reasoning effort](https://learn.chatgpt.com/docs/models#pick-a-reasoning-effort)
- Work/Codex 中 `Light` 是桌面应用、Work 网页和 IDE 扩展的名称，CLI 对应 `Low`。`Medium` 平衡速度和深度；`High / Extra High` 面向多步骤、多来源和需要取舍的难题。不同代际的 effort 不精确对应。— [Models](https://learn.chatgpt.com/docs/models)
- Work/Codex 的 `Max` 给单个任务更多推理时间；`Ultra` 利用子代理分担可拆开的复杂工作，包含并行协作的变化。大部分任务不需要 Max 或 Ultra。GPT-6 Luna 最高到 Max，不支持 Ultra。— [Models：Know when to use Max or Ultra](https://learn.chatgpt.com/docs/models#know-when-to-use-max-or-ultra)
- 当前公开 API 的 `reasoning.effort` 枚举没有 `ultra`。Work/Codex Ultra 不能直接照抄为 API `reasoning.effort: "ultra"`。— [Responses API reference](https://developers.openai.com/api/reference/resources/responses/methods/create)；[Models](https://learn.chatgpt.com/docs/models)
- API 另有独立的 `reasoning.mode: "standard" / "pro"`，standard 是默认；mode 选择执行方式，effort 选择其中的推理量。不要将 API pro mode、ChatGPT 的 Pro 订阅、Chat 的 GPT-6 Pro 菜单视作同一件事。前两者名称区别可确认，Chat 菜单的具体映射由 chatgpt_models 研究负责。— [Reasoning mode](https://developers.openai.com/api/docs/guides/reasoning#reasoning-mode)
- GPT-6.1 Sol 的 Work/Codex 文档写明范围为 Light 到 Ultra，但可见选项和默认值受套餐、客户端、工作区设置和发布批次影响，Max/Ultra 也依赖设置。— [Models：GPT-6.1 Sol](https://learn.chatgpt.com/docs/models#gpt-61-sol)

### Inferences

- 建议报告严格拆开普通 Chat、Work/Codex、API 三个入口。API 的技术参数作为可折叠附录或简短补充，不能把它直接当作用户在 Chat 中应看到的按钮。
- 建议写“从推荐起点开始，用自己的代表性任务比较”，不要给出未经测量的“Luna Max 等于 Astra Low”或“某档对所有任务最划算”。不同模型的同名档位不是统一智力标尺。

### Gaps

- Astra API 省略 effort 的具体默认值未找到明确的模型专属声明。官方示例中出现 `low`、`medium`、`xhigh` 都不能证明默认值；保留未知或建议显式设置。
- 未读取用户账户的实时模型菜单，因此无法确认用户套餐、客户端和当前发布批次实际提供的档位。
- GPT-5.6 遗留模型的 API 总指南写明支持 `none, low, medium, high, xhigh, max` 且默认 medium，但本轮没有分别抓取每个 5.6 子型号的专属支持表，报告不要无条件扩展到每个旧型号。— [Using GPT-6 / 旧 GPT-5.6 部分](https://developers.openai.com/api/docs/guides/latest-model)

## 2. 思考强度适合什么任务，如何理解速度、成本和质量？

### Takeaway

思考强度决定模型愿意投入多少推理工作。低档通常更快、省用量；高档对复杂规划、排错和多步分析可能有帮助，但官方要求用代表性任务检验额外等待和成本是否值得。它不是答案长度开关，也不是正确率保证。— [推理模型指南](https://developers.openai.com/api/docs/guides/reasoning)；[部署检查清单](https://developers.openai.com/api/docs/guides/deployment-checklist)

### Cited Findings

| 档位 | 官方任务定位与条件 | 来源 |
| --- | --- | --- |
| `none`（仅支持它的模型） | 对延迟极敏感、无需复杂推理或连续工具调用；如简单分类、快速检索。 | [推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `low` | 提取、分流、分类、常规改写；也用于明确范围的工具执行与简单规划，优先速度和成本。 | [部署检查清单](https://developers.openai.com/api/docs/guides/deployment-checklist)；[推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `medium` | 需要一定规划、判断和复杂推理的平衡起点；代码工作、研究、表格和幻灯片等。 | [推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `high` | 难推理、复杂排错、深入规划和价值较高的多步骤任务；宜与 medium 比较。 | [推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `xhigh` / Extra High | 深入研究、较长时间的工作、安全/代码审查、难代码任务；官方要求评测证明质量增益值得额外延迟和费用。 | [推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `max` | 最复杂且质量优先的问题；已使用 xhigh 时比较 Max 是否确有增益。 | [推理指南](https://developers.openai.com/api/docs/guides/reasoning) |
| `Ultra`（Work/Codex） | 可拆成相对独立部分的大任务，借子代理并行完成；不是所有任务都适合。 | [Models](https://learn.chatgpt.com/docs/models) |

- 推理 token 是模型在后台推理时消耗的计量单位；用户看不到完整内容，但 API 仍按 output tokens 计费。更多内部工作可能只返回很短的答案，所以最终字数不能代表总消耗。— [How reasoning works](https://developers.openai.com/api/docs/guides/reasoning#how-reasoning-works)
- 模型在各档位内还会按任务自适应，简单任务少用一些推理 token，复杂任务更多。因此某个 effort 不对应固定时间、固定 token 数或固定价格倍数。前句官方明确，后句是基于自适应机制的保守推论。— [Reasoning effort](https://developers.openai.com/api/docs/guides/reasoning#reasoning-effort)
- `text.verbosity` 才是控制答复详略的主要参数；值为 `low / medium / high`。`reasoning.effort` 管思考投入。可以要求认真分析后仅给结论，也可以用低档生成较长的模板文本。最后两个示例是参数区分的使用推论。— [Set up text.verbosity](https://developers.openai.com/api/docs/guides/deployment-checklist#set-up-textverbosity)；[Using GPT-6：Writing style](https://developers.openai.com/api/docs/guides/latest-model)
- API 的 `max_output_tokens` 同时约束推理 token、可见输出和不可见格式 token。设得过小可能在显示答案前耗尽额度，返回 incomplete；不要把它当作“最多回答多少字”。— [Controlling costs](https://developers.openai.com/api/docs/guides/reasoning#controlling-costs)
- 官方建议先提供明确任务、约束、所需输出、完成条件与验证方法；把 effort 看作调节项，不要视为挽回质量的主要手段。— [推理模型指南：提示建议](https://developers.openai.com/api/docs/guides/reasoning)
- API pro mode 可改善难题的可靠性，但会增加耗时和 token 消耗。官方建议同一模型、同一 effort 比较 standard 与 pro，记录任务是否完成、内容是否完整、证据、总 token、耗时和成本。— [Using GPT-6：Pro mode](https://developers.openai.com/api/docs/guides/latest-model)

### Inferences

- 针对用户的实用起点：常规解释、整理材料、明确的小改动用低到中；要检查多处代码、排查复杂故障、比较冲突资料或形成完整方案用中到高；只有明确发现遗漏、复杂度高且等待可接受时升 Extra High/Max。模型选择还要看任务是否反复、用量是否敏感，不能只调 effort。
- 若缺少源文件、实时资料、明确目标或验收条件，先补齐这些；提高 effort 本身不会补出不存在的证据。这是依据官方提示与验证建议作出的使用建议，并非本轮实际对照测量。
- 对“最好强度”的可复现判断，应拿相同任务和相同材料比较两个档位，检查实际正确性、遗漏、是否完成、等待与用量。报告应把建议标为起点，而不是经过该用户任务测试的最优值。

### Gaps

- 本轮仅调查官方资料，没有实测用户任务，因此没有“某模型某档省多少秒”“准确率提高多少”“必定强于另一组合”等自制数值。
- 官方对质量改善使用 can improve / evaluate 等条件性措辞；不能改写为越高必然越正确。

## 3. 工具方法、同源交叉核对及证据限制

### Takeaway

本分工实际调用 Tavily search/extract 与 Context7 resolve/query；Context7 返回当前 GPT-6 与 6.1 文档，关键档位与实时抓取一致。两者检索了同一套 OpenAI 官方来源，属于交叉核对，不是两个独立实验或独立权威。Exa 由其他研究分工使用，此处不冒认调用。

### Cited Findings

- Tavily 首个实质步骤为精确主题搜索“OpenAI models reasoning effort default GPT-6.1 Sol GPT-6 Astra”，并同期抓取 [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)。随后抓取 Astra/Luna 模型全文、Using GPT-6、Models 的 Markdown 版，以及 6.1 Sol/6 Sol 与 deployment-checklist Markdown。所有论据均来自官方 URL，搜索摘要只用于定位，模型关键支持表有后续页面提取。
- Context7 `resolve_library_id` 输入 OpenAI API，选中 `/websites/developers_openai_api`（OpenAI 开发者官网文档）。调用 3 次 `query_docs`，分别核对：① GPT-6 各模型 effort 支持/default/ultra；② effort、verbosity、输出限制与用量关系；③ Astra API default 与 Work 推荐起点区别。
- Context7 的关键原始来源为 [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)、[API deployment checklist](https://developers.openai.com/api/docs/guides/deployment-checklist)、[Responses create reference](https://developers.openai.com/api/reference/resources/responses/methods/create)、[Model guidance](https://developers.openai.com/api/docs/guides/model-guidance)。结果包含 GPT-6.1 Sol 与 GPT-6 Astra 当前文档；未遇到只返回 GPT-4/早期 GPT-5 的缓存陈旧情况。
- Context7 与 Tavily 一致确认：Astra/6.1 Sol 无 none；6 Sol/Luna 有 none；6.1 Sol/6 Sol/Luna medium 默认；mode 与 effort 独立；API effort 枚举截至 max；xhigh/max 需代表性测试证明收益。— [Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)；[Deployment checklist](https://developers.openai.com/api/docs/guides/deployment-checklist)

### Inferences

- 最终报告可以写“已用 Exa、Tavily、Context7 检索并交叉核对官方资料”（协调者确认另外分工的 Exa 已完成后），不能把三工具结果计为三份独立性能证据。
- 搜索或聚合抓取会保留网页中的多个产品变体、重复导航，官方 .md 更适合辨识正文；阅读时已按页面小节和型号核对，避免把邻近旧版文字混入当前模型。

### Gaps

- Astra 默认 effort 的专门 Context7 查询仍只返回其他模型 medium 默认及 Astra 示例，因此未解决该未知项。
- 未进行带密钥的真实 API 请求、账户菜单检查或性能测量；本文陈述的是查阅日的公开文档能力与官方使用建议。
