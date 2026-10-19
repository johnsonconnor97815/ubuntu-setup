# ChatGPT 当前模型、产品入口与思考控制

## 1. 截至 2026-10-09，Chat 与 Work/Codex 中的模型有什么不同？

### Takeaway

必须分开写普通 Chat 与 Work/Codex：Chat 以 `GPT-6` 配合思考档位展示；Work/Codex 直接选择 `GPT-6.1 Sol`、`GPT-6 Astra`、`GPT-6 Luna` 等模型。不要把 API 型号、Work 型号和 Chat 菜单当成一张相同的菜单。

### Cited Findings

- 检索和实际抓取日期均为 **2026-10-09**。主要使用 Exa 搜索后 Exa crawling 抓取全文；未登录用户账户、未查看私人配置。以下内容来自官方公开页面，不是本机实测或第三方性能评测。
- Chat 用于问答、讨论、起草和比较；Work 用于把较大任务做到可检查的交付物，如报告、幻灯片、分析和计划；Codex 提供代码、测试、差异和审查等开发视图。Work 与 Codex 能力有重叠，Codex 也能做研究和文档工作。— [Use ChatGPT](https://learn.chatgpt.com/docs/use-chatgpt)
- **Chat：**当前模型菜单中的 `GPT-6` 替代 `Latest`，旧 `Latest` 对话保持原思考档位迁移；明确选过 `GPT-5.6 Sol` 的对话仍保留 5.6。GPT-6 菜单下，Instant、Medium、High、Extra High 由 **GPT-6 Sol** 驱动；Pro 对应 **GPT-6 Pro，由 GPT-6 Astra 驱动**。菜单显示 GPT-6，不显示 Sol。— [GPT-6 and other models in ChatGPT](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)（Exa 元数据显示发布于 2026-10-07）
- GPT-5.6 Sol 仍是 Chat 中独立可选项；GPT-5.6 Sol Pro 是 5.6 家族的 Pro 选项。官方把 5.6 Sol 用途列为复杂编码、知识工作与研究、网络安全、科学、计算机使用和设计。GPT-6 本次发布本身没有淘汰旧可选模型。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)
- **Work/Codex：**当前首推 `GPT-6.1 Sol` 处理复杂编码和多步骤代理工作；Astra 用于最难的跨代码、应用和研究的完整任务；Luna 用于目标清楚、重复多次的抽取、分类、转换和结构化摘要。官方定位 6.1 Sol 为接近 Astra 表现且成本更低，适合长期、反复运行的代码、应用和文档任务。GPT-5.6 Sol、Terra、Luna 在新模型发布期间仍可用。— [Models](https://learn.chatgpt.com/docs/models)
- 6.1 Sol 与 6 Sol 是不同版本。2026-10-07 发布说明称 6.1 Sol 改进了 6 Sol 的代理编码、计算机使用和专业工作，先向 Pro 发布，再扩展至 Plus、Business、Enterprise、Edu。— [ChatGPT release notes，October 7, 2026](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
- 需要精确处理 Learn 页“GPT-6 Sol 不在 Chat”的表述：Enterprise 当前帮助页明确区分“Work/Codex 的独立模型选项”与“Chat 中 GPT-6 的底层模型”。因此不能从 Learn 页推导“Chat 完全不使用 GPT-6 Sol”。6.1 Sol 当前为 Work/Codex 选项，不能直接推荐用户在普通 Chat 选它。— [Enterprise and Edu models and limits](https://help.openai.com/en/articles/11165333-chatgpt-enterprise-and-edu-models-and-limits)，[Models](https://learn.chatgpt.com/docs/models)

### Inferences

- 给用户的对照表应该先列 Chat 档位，再另列 Work/Codex 模型；否则“GPT-6”“GPT-6 Sol”“GPT-6 Pro”“GPT-6 Astra”很容易被误读为四个完全独立的 Chat 菜单项。
- 工作量重复且在意额度时，6.1 Sol 是值得优先试的工作模型；不应把“near-Astra”解释为任何任务、任何档位都相等，或当作独立基准测试结论。

### Gaps

- 没有检查用户实际订阅、地区、客户端版本、工作区权限或菜单；不能保证其账户已经收到新模型。
- 本研究没有运行相同任务进行实际模型对比。官方“更强/更经济”的定位，不是该用户工作负载上的已测胜率。

## 2. 各思考档位分别适合什么，默认值与接口能否互相换算？

### Takeaway

Chat 的 Medium/High/Extra High 是用户界面的思考选项；Work/Codex 还有 Light、Max、Ultra。模型和思考强度是两个独立选择，不能用档位数字或同名词简单比较不同模型，也不能把 Chat 档位直接换算成 API 参数。

### Cited Findings

- **Chat 档位官方定义：**Instant 为快速日常回答；Medium 为标准推理，适合需要更仔细分析的问题；High 为延长推理，适合复杂、多步骤工作；Extra High 为特别困难任务的最高可用推理档；Pro 使用 Astra。Pro 根据可用性还可能显示 Pro Standard 和 Pro Extended。— [Enterprise and Edu models and limits，Model picker in Chat](https://help.openai.com/en/articles/11165333-chatgpt-enterprise-and-edu-models-and-limits)
- Chat GPT-6 的 Extra High 是 **Sol 的最高思考档**；Pro 改用另一模型 Astra，所以它不能仅解释成 Sol 再多想一档。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)
- Plus/Pro 的 Instant 已不再遇到难题自动切到更高思考档；写“think harder”或“think deeply”也不会自动改变档位。安全原因的自动切换是例外。2026-09-14 发布说明也单独宣布移除该自动切换。托管工作区仍可能有管理员控制的自动路由设置，不能把消费版规则扩展到所有工作区。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)，[ChatGPT release notes，September 14, 2026](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)，[Enterprise/Edu 管理说明](https://help.openai.com/en/articles/11165333-chatgpt-enterprise-and-edu-models-and-limits)
- **Work/Codex 默认起点：**6.1 Sol 从客户端当前默认 effort 开始；Luna 从 High 开始；Astra 从 Light 开始，Light 在配置中是 `low`。Light/Low 适合快速、界限清楚的任务；Medium 在速度和深度间平衡；High/Extra High 适合多步骤、多来源、有取舍的困难任务。不同代模型的档位并不精确对应。— [Models，Pick a reasoning effort](https://learn.chatgpt.com/docs/models)
- Work 桌面和网页可从当前默认 Power 开始，向 Smarter 调获得更多推理，向 Faster 调更快、成本更低；Advanced 可选具体模型、思考档与速度。文档图片示例中有六个预设，但明确说默认值和可选项随计划、客户端、工作区和发布进度变化，因此不能把示例被选中的 `GPT-6 Sol Light` 报为所有人的默认设置。— [Models](https://learn.chatgpt.com/docs/models)
- **Max** 让单个模型在单项任务上花更多时间；**Ultra** 使用多个子代理把可拆分任务并行处理。大多数任务不需要这两个档。GPT-6 Luna 最高支持 Max，不支持 Ultra。— [Models，Know when to use Max or Ultra](https://learn.chatgpt.com/docs/models)
- 较高思考强度可能更耗额度，但不保证结果更好；较低档不等于跨模型能力更弱，例如官方举例 Astra Low 可以胜过 Sol High。若结果遗漏要求，先看要求是否清楚、文件及应用权限是否齐全；提高强度不能补回缺失的信息和访问权限。— [Managing usage with GPT-6 Astra in Work and Codex](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex)（抓取显示 Updated: yesterday）

### Inferences

- 实用 Chat 建议可写为：日常短问答/改写从 Instant；需要解释、比较或一般分析从 Medium；难调试、多来源综合、复杂计划从 High；明确需要非常细致推理且可接受等待时试 Extra High；最困难的综合任务再试 Pro。这里的场景映射是基于官方档位定义的应用建议，不是已测的最优组合。
- 给“思考强度”的通俗解释可以用“同一个任务允许模型花多少精力检查和推敲”，但要提醒 Ultra 包含协作机制变化，不只是同一个模型再想久一点。

### Gaps

- 没找到适用于所有付费 Chat 用户的统一当前默认思考档证据。只能说保留既有 Latest 的档位、计划和工作区可能设置不同默认值。
- 本组来源没有建立 Chat Medium、High、Extra High、Pro Standard/Extended 与 API `reasoning.effort` 的精确一对一关系。不要推导映射。
- 没有固定的“档位到等待秒数”或“某任务必然最佳档位”证据。

## 3. 发布进度、订阅和功能限制会怎样影响推荐？

### Takeaway

建议必须附带“以账户当前菜单为准”。Plus 可在 Work/Codex 用 Astra，但不等于能在 Chat 用 GPT-6 Pro；Pro 订阅也不意味着 Pro 模型无限量。免费计划处在新旧 Luna 的发布过渡期，公开资料尚未完全同步。

### Cited Findings

- Chat GPT-6 正向符合条件的 Plus、Pro、Business、Enterprise 发布；普通 Chat 的 GPT-6 Pro 在官方模型帮助页列为 Pro $100、Pro $200、Business、Enterprise，后续公开文档也讨论 Pro $500。精简报告最好写“符合条件的 Pro / Business / Enterprise”，避免一张很快过时的价位表。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)，[2026-10-07 发布说明](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
- Plus 包含 Work/Codex 的 Astra，**不包含 Chat 的 GPT-6 Pro**。Chat Pro 的消息额度与 Work/Codex 共享工作额度分开；Work 与 Codex 彼此共享使用量。— [Managing usage with GPT-6 Astra in Work and Codex](https://help.openai.com/en/articles/20001516-managing-usage-with-gpt-6-astra-in-work-and-codex)
- 6.1 Sol 发布包括 Plus、Pro、Business、Enterprise、Edu；Free/Go 不在首发范围；Enterprise/Edu 初始默认关闭，要管理员开启。档位与速度选项也依客户端/套餐/工作区而定。— [Models，GPT-6.1 Sol](https://learn.chatgpt.com/docs/models)
- GPT-6 Pro 有使用限额；Pro 订阅不提供无限 GPT-6 Pro。到限额后可暂时不可用或切换到另一可用模型；不同套餐可能有独立或共享 Pro 额度，换模型不必然增加额度。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)
- **已证实的功能差异：**Chat GPT-6 的 Instant 到 Extra High 支持 Intelligent UI，即文字、视觉内容和可互动元素的组合；Pro/Astra 在 Chat 不支持 Intelligent UI。此限制不等于 Pro 无法写作、分析或做研究。— [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)，[2026-10-07 发布说明](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)
- **官方页面存在发布过渡差异：**2026-10-07 release notes 明确宣布，Chat 的 GPT-6 当日从付费开始，次日向 Free/Go 扩展，Free/Go 由 GPT-6 Luna 驱动；然而 2026-10-09 实际抓取的模型帮助页仍称 Free/Go 默认及 Think 使用 GPT-5.6 Luna。应同时保留两条证据，不把所有免费账户断言为已经 GPT-6 Luna 或仍全为 GPT-5.6 Luna。— [October 7 release notes](https://help.openai.com/en/articles/6825453-chatgpt-release-notes)；旧口径仍见 [Chat 模型说明](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt)
- GPT-5.5 计划于 2026-10-14 从 ChatGPT、Work、Codex 各套餐退役，此通知不涉及 OpenAI API。此事独立于“GPT-6 发布本身不淘汰旧可选模型”的表述；不能因用户仍见旧模型就把旧型号当长期推荐。— [Models，GPT-5.5 retirement](https://learn.chatgpt.com/docs/models)

### Inferences

- 免费版在最终答复中可以只作一句附注：“免费/Go 正分批从旧 Luna 升级到 GPT-6 Luna，资料更新尚未完全同步，按你当前菜单为准。”不必让这一边界挤占主要选择建议。
- 若用户主要做可导出的报告、代码或跨应用任务，Work/Codex 模型表更实用；如果只是问答和讨论，应优先按 Chat 档位给建议。

### Gaps

- 对 GPT-6 Pro 当前是否禁用 Apps、Memory、Canvas、图像生成，未找到可充分建立完整清单的现行明确证据；本次搜索返回的是通用企业工具清单或旧版资料。不能沿用旧 GPT-5 Pro 的限制，更不能把企业套餐有某工具当成每个模型都能用该工具。
- 未确认用户账号的免费发布状态、Pro Standard/Extended 是否显示、Extra High 的具体计划权限。公开资料只承诺选项取决于可用性。
