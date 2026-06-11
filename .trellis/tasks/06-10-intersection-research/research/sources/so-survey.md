# so-survey — Stack Overflow Developer Survey 2025（Technology 页）

抓取日期：2026-06-10。条目数：84。

## 抓取过程

1. `mcp__exa__web_fetch_exa` 抓取 https://survey.stackoverflow.co/2025/technology 全文（约 58KB 文本），页面虽是 JS 渲染但 exa 能拿到完整图表数据，无需补抓新闻稿。
2. `curl` 取原始 HTML，核对各板块锚点 id（`#1-cloud-development`、`#1-dev-id-es`、`#1-databases`、`#1-programming-scripting-and-markup-languages`、`#1-web-frameworks-and-technologies`、`#1-stack-overflow-tags`、`#1-code-documentation-and-collaboration-tools`），逐条目 `source_url` 指向对应板块。
3. 所有 metric 取 **All Respondents** 口径（每个板块第一组数字），单位 percent。

## 取数板块与判读

- **Cloud development**（即 Cloud development and infrastructure tools）：Docker 71.1%、npm 56.8%、Pip 40.9%、Kubernetes 28.5%（映射 kubectl）、Homebrew、Make、APT、Terraform、Maven、Cargo、Gradle、pnpm、Prometheus、Ansible、Podman、Composer、Poetry、Bun、Ninja。排除云平台（AWS 43.3%、Azure、GCP、Cloudflare、Firebase、Vercel、Netlify、Heroku、Supabase、DigitalOcean、Datadog、Splunk、New Relic、Railway、IBM/Yandex Cloud）、Windows 专属（Chocolatey、MSBuild）、Arch 专属（Pacman）、项目内构建依赖（Vite 25.4%、Webpack 18.4%）。NuGet 18.9% 未单列，并入 dotnet 工具链。
- **Languages** → 运行时/工具链判读：Python 57.9→python、Bash/Shell 48.7→bash（问卷把所有 shell 合并为一项）、TypeScript→typescript、Java→java(OpenJDK)、C# 27.8→dotnet、C++ 23.5（C 22% 同口径）→gcc、PowerShell→powershell（Linux 可装 pwsh 但使用主体偏 Windows）、GDScript 3.3→godot（引擎专属语言）。JavaScript 66% 不单列——nodejs 改取 Web frameworks 板块的 Node.js 48.7%，更贴近"安装包"。截断线约 2%（收到 Zig 2.1%），排除 Windows 系（VB/VBA/Delphi）、歧义实现（Lisp、Assembly）、商业套件（MATLAB 3.9%）。
- **Databases**：收本地可装的 PostgreSQL 55.6%、MySQL、SQLite、SQL Server（官方支持 Linux）、Redis、MongoDB、MariaDB、Elasticsearch、InfluxDB、DuckDB、Cassandra、Neo4j、Valkey、ClickHouse。排除云库（DynamoDB、BigQuery、Firestore、Cosmos、Snowflake、Redshift、Databricks）、嵌入库 H2、Oracle（商业重型）、尾部 <2%（CockroachDB、PocketBase、Datomic）。
- **Dev IDEs**：VS Code 75.9%、IntelliJ 27.1%、Vim 24.3%、Cursor 17.9%、PyCharm/Android Studio 15%、Jupyter 14.1%、Neovim 14%、Nano、Sublime、Claude Code 9.7%、WebStorm、Zed、Rider、Eclipse、VSCodium、PhpStorm、Windsurf、Aider 1.9%。排除 Windows/macOS 独占（Visual Studio 29%、Notepad++ 27.4%、Xcode）、SaaS（Lovable、Bolt、Trae）、扩展（Cline/Roo）。Emacs 只出现在 write-in（0.1%），未收。
- **AI tools**：LLM 板块全是模型（GPT/Claude/Gemini…）非软件，全部排除；可本地装的 Ollama 15.3% 与 uv 9.5% 来自 "Stack Overflow tags" 板块。
- **Version control & collab**：2025 问卷已无独立 VCS 题（Git 上次出现于 2022）。GitHub 81.1% 按任务规则映射为配套 CLI gh、GitLab 35.6% 同理映射 glab——这是平台使用率不是 CLI 使用率，计票需注意口径。git 收录但 metric=null。另收 Obsidian 16.1%、Doxygen 4.3%；排除 Jira/Confluence/Notion（无官方 Linux 版）等 SaaS。

## 局限

- 封闭式问卷：选项之外的工具（curl、tmux、fzf、ripgrep、htop 等系统/终端工具）完全缺席，本源对该类目无信号。
- 平台→CLI 的映射（gh/glab）与语言→工具链的映射均为判读，不是原始数据语义。
- APT、Nano、Bash 等 Ubuntu 预装项收录仅作普及度参考，对"首发 catalog 该装什么"的票面价值有限。
- 各板块回答人数不同（1.6 万~3.2 万），跨板块的百分比不严格可比。
