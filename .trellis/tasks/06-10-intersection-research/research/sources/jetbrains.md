# jetbrains — JetBrains State of Developer Ecosystem 2025（辅助源，仅交叉验证）

抓取日期：2026-06-10。调查时间 2025-04~06，n=24,534（194 个国家/地区，数据清洗+加权后）。

## 抓取过程

1. `curl` 抓 https://devecosystem-2025.jetbrains.com/ 与 /tools-and-trends、/artificial-intelligence —— 页面是 Next.js 客户端渲染，HTML 与 exa 渲染结果里数字均为空（动画计数器）。
2. 在页面 HTML 里发现图表数据走 `/_data/*.csv`，直接 curl 拿到官方图表原始数：
   - `pl_dynamics_large.csv`：语言使用率动态（2017–2025），取 2025 列。
   - `db7.csv`：数据库使用率动态，取 2025 列。
   - `usage_ai_coding_imputed_final2.csv`：AI 工具使用率（36 个选项）。
3. **IDE/编辑器图表 2025 站点未公开发布**（探测 ide/ides/editors 等 CSV 全 404）。改为下载官方匿名原始数据 `RawData.zip`（98MB，n=24,534），对 `ides::*` 多选题（"Which IDEs or editors do you regularly use?"，35 个选项）按 `weight` 列加权自算份额，分母=回答该题的加权样本（≈23,628）。头部结果：VS Code 58.3%、IntelliJ IDEA 38.7%、PyCharm 21.0%、Visual Studio 16.6%（已排除）、Android Studio 16.1%。

## 判读说明

- **语言→运行时/工具链映射是代理**：JavaScript→nodejs、Java→openjdk、C#→dotnet、C/C++→gcc（取 C++ 25% 为 metric，C 18% 记在 evidence）、Rust→rust（aliases 含 rustup/cargo）。Shell(36%)/SQL(47%)/HTML-CSS(52%)/Objective-C 不映射为可安装条目。
- **去重**：Cursor 同时出现在 AI 图表（13%）与 ides 原始题（12.0%），取官方发布的 13% 单条目；Windsurf 同理取 ides 题 2.9%（AI 图表 2%）；Zed 取 ides 题 3.6%（AI 图表 1%）。
- **排除**：
  - Windows/macOS 独占：Visual Studio（16.6%）、Notepad++（12.0%）、Xcode（7.5%）、AppCode（0.8%）、Trae（无 Linux 版）。
  - 纯云/SaaS：AWS/GCP/Azure 等云平台图表整体不收；DynamoDB、BigQuery、Cloud Firestore、Athena、Snowflake、Redshift；ChatGPT/Gemini/Claude 的 web/app、Perplexity、Microsoft 365 Copilot、Vercel v0、Bolt、Lovable、Firebase Studio、Project IDX。
  - 库/嵌入式：H2（6%，Java 嵌入式库）。
  - IDE 内置功能：Visual Studio IntelliCode、Gemini in Android Studio、Xcode 内置 AI。
  - Meta Llama self-hosted（1%）是模型非工具，未映射成 ollama/llama.cpp（避免捏造）。
- AI 条目多数是 IDE 插件（Copilot、AI Assistant、Junie、CodeGPT、Gemini Code Assist、Cline、Continue 等），并非独立桌面软件，收录但 catalog 落地时需要按"插件"对待。

## 局限

- JetBrains 渠道样本偏置：方法论页自述"JetBrains users could have been more likely to respond"，JetBrains 系产品（各 IDE、AI Assistant 13%、Junie 5%）份额需打折看。
- 与 Stack Overflow 调查同质（开发者自报告问卷），语言/IDE 存在双倍计票风险 —— 因此本源定位为**辅助源，仅交叉验证，不独立投票**。
- IDE 份额是自算值（官方未发布该图表），与官方口径可能有 ±1pp 差异；rounding 后引用到 0.1pp。
- 使用率 ≠ 安装率；catalog 选型时仅作流行度旁证。

## 产出

- `jetbrains.json`：74 条（语言/工具链 15 + IDE/编辑器 29 + 数据库 17 + AI 工具 13）。
