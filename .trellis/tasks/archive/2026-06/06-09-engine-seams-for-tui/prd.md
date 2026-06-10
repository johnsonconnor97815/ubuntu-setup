# PRD: 引擎接缝（为 TUI 铺路）— engine-seams-for-tui

> 来源：2026-06-09 grillme 访谈（议题：范围切法 / sudo 时机 / 接缝形态 / 扫描策略 / op 范围 / 进度粒度 / 取消语义 / pre-mortem）。
> 总路线已拍板：**①引擎接缝（本任务）→ ②三屏闭环（browse / plan-confirm / progress）→ ③installed 屏（先定义再做）**。
> 本任务不写任何 `tui/` 代码，全部改动可用 headless CLI 验收。

## 背景

TUI 即将开工，但引擎现状有四个缺口挡在前面：

1. `execute()` 自身不发逐步事件（`emit` 回调只透传给 provider，apt provider 也没用）——progress 屏要的事件流不存在。
2. `cli.main()` 把 catalog→manifest→plan→sudo→execute→记账内联在自己函数里——TUI worker 需要同一套编排，无共享入口。
3. `privilege.py` 只有交互式 `ensure_sudo()`；keep-alive、`-Nnv` 静默探测、22.04 回退全部 deferred——「探测自适应」的 sudo 策略无引擎支撑。
4. `runner.run()` 一次性 capture，跑完才返回——行级实时日志不可能。

## 范围（四件套）

### 1. `execute()` → 事件生成器
- 重构为生成器，yield 结构化事件；词汇表至少含 **StepStarted / OutputLine / StepFinished** 及 run 级结束信息（具体字段实现时定，dataclass、定义在 core 内）。
- 事件必须携带渲染进度所需的信息：总步数/序号（如 RunStarted 带 total，或 StepStarted 带 index/total）；StepFinished 携带 Outcome（changed/ok/skipped/failed）——**detect-and-skip 与 fail-fast 的区分在事件流里必须可见**（spec idempotency「两种 didn't run 保持区分」）。
- CLI 改为消费生成器打印；`tests/core/test_executor.py` 跟随迁移。
- 与 spec `tui/ui-guidelines.md`「脑以迭代器/生成器暴露进度」对齐；provider 侧 `Ctx.emit` 契约保留，由 executor 桥接进生成器流。

### 2. core 编排 facade
- 新增 core 编排模块（如 `core/service.py`，命名实现时定）：load → plan → apply → record 的共享入口，cli 与未来 tui 共用。
- 全量状态扫描入口（**已拍板纳入**，2026-06-09）：对 catalog 逐条 `check()`、流式产出 `(entry, state)` 的生成器。这是任务② browse 屏第一个要调的接缝且实现极薄。注意 `check()` 可抛 `ProviderError`（如 dpkg rc≥2 的真实 DB 错误）——扫描入口需有错误通道（如产出 state 或 error 的并集形态），单条坏条目不得炸掉整个扫描。
- `cli.main` 瘦身为参数解析 + 渲染 + exit code。
- facade 是纯逻辑：**core/ 绝不 import textual**（不可妥协项①）。

### 3. privilege 补全（「探测自适应」的引擎侧）
- 静默探测：`sudo -Nnv` 读取缓存凭证状态（不重置 TTL）；启动时检测 `-N` 支持（`sudo -h` grep），22.04 回退 `sudo -n true`。
- keep-alive：apply 期间 daemon 线程按 5 分钟 TTL 内周期刷新，随进程退出。
- 每步前探测（`sudo -n true`）：凭证失效时干净失败并给出「需要交互提权」的明确信号——**绝不让密码提示突袭调用方**；TUI 侧的 `app.suspend()` 提示属于任务②，本任务只提供信号。
- 测试矩阵显式枚举（fake run 注入，不真跑 sudo）：无 tty / NOPASSWD / 凭证已缓存 / 凭证过期 / 无 `-N`（22.04）。

### 4. runner 流式路径
- 新增流式变体（Popen 逐行读；行回调或迭代器形态实现时定），供 executor 转成 OutputLine 事件。
- **必须暴露程序化终止句柄**（terminate → 宽限 → kill 升级，含进程组处理）：这是任务②「取消 = 杀当前步」的引擎前提，也是 spec 信号传播要求（error-and-logging「Child-process-group handling」）的落地点。现有 `run()` 只能靠终端信号到达前台进程组，无法从另一线程程序化终止——TUI 取消键走的正是后者。
- **提权步骤的终止有 EPERM 墙**（已实证核实）：apt 步骤的子进程是 `sudo -n env … apt-get`，认证后全程 root；普通用户进程对 root 进程 `Popen.terminate()/killpg()` 一律 `EPERM`（kill(2) 权限规则；终端 Ctrl-C 能到达是内核前台进程组信号绕过 uid 检查，程序化信号没有这条路）。终止句柄对提权步骤必须走**提权 kill**（经 runner 边界执行形如 `sudo -n kill -- -<pgid>`；凭证失效时降级为「无法取消，等待当前步完成」且该降级对消费者可感知），机制实现时定形，但**必须覆盖 sudo 路径**——只对非提权命令可用的终止句柄等于没有。
- 流式变体与 facade 保留既有 run 注入缝（provider 构造器 `run=` 与 `ctx.run`、privilege 的 `run=`；`tests/_fakes.py` 的 FakeRun 契约延伸，不另起炉灶）。
- 保留现有 `run()` 兼容路径；流式路径必须保持既有语义：argv 列表、非交互环境、`LC_ALL=C`、argv 审计日志、超时（语义要重新明确：总时长 vs 静默时长；现 `run()` 是总时长、超时返回 124 不抛）（单一 subprocess 边界，不可妥协项⑤）。
- 日志洪水的**节流是 UI 侧（任务②）责任**；但 runner/executor 不得因消费慢而无界缓冲（背压/有界策略实现时定）。

## 已知架构难点（实现前必读）

**同步生成器 × 步内实时事件是矛盾的，必须显式桥接。** `execute()` 改成同步生成器后，`provider.install(entry, ctx)` 是一次阻塞调用——apt-get 跑几十秒期间，生成器卡在这一行，**无法 yield 任何东西**。而 OutputLine 恰恰产生在这次调用内部（流式 runner → `ctx.emit`）。「纯生成器」与「行级实时」不能靠直觉同时成立，需要明确的桥接设计，方向（实现时定形）：

- executor 对每步：`yield StepStarted` → **工作线程**里跑 provider 方法（`ctx.emit` 改为入一个有界队列）→ 主生成器循环 drain 队列逐个 yield OutputLine → join 线程 → `yield StepFinished`。生产者-消费者，对 provider 协议零侵入、emit 契约不变、消费方看到的仍是纯生成器。
- 禁止的偷懒解法：provider 跑完后把缓冲的行一次性补发——行级「实时」名存实亡，等于回到 step 级。
- 队列必须**有界**（消费慢不允许无界缓冲，见 runner 节）。

这是任务①技术不确定性最高的一块，提交点 a 先攻它。

**取消必须是消费者可达的接缝，不能只停在 runner 层。** 任务②的 TUI worker 手里只有 apply 返回的事件生成器，而当前步的 runner 调用埋在桥接工作线程内的 provider 方法里——「runner 有终止句柄」不等于「消费者按得到取消键」。任务①必须定形的取消契约：

- apply 产物除可迭代外提供 **`cancel()`**（控制对象具体形态实现时定，锁定的是「消费者一个调用即可终止当前步」；`cancel()` 内部触达当前步的 runner 终止句柄，含上面的提权 kill 路径）。
- 取消后的事件与记账语义：被杀的步以明确事件收尾（形如 StepFinished 带 cancelled/failed 语义，词形实现时定）、run 级结束信息照发、`record_transaction` 照常记录已发生的步骤——审计不缺页。
- **生成器被 `close()`/弃用（GeneratorExit）时的桥接收尾是契约的一部分**：生产者线程不得永久阻塞在满队列上，在跑子进程的归宿（终止或等完）必须明确。注意 spec ui-guidelines 的 worker 示例在 `is_cancelled()` 时直接 `return` 弃用生成器——正好踩这条路径，spec 修订时一并核对。

## 非目标（本任务不做）
- 任何 `tui/` 代码、任何 textual 依赖引入。
- apt `remove`/`upgrade` 实现（已拍板：切片② UI 只露 install，provider 不动）。
- 入口 argparse 改造（裸命令进 TUI 是任务②的事；本任务不破坏 `--install`/`--apply`）。
- installed 屏定义（任务③的前置问题）。

## 验收
- 既有测试全部迁移后通过；新增：生成器事件序列断言（含 skipped 与 fail-fast 停止的事件形态）、facade 单测、privilege 矩阵单测、runner 流式单测（fake 慢命令逐行 + 终止句柄：terminate 后宽限收尾/升级 kill；提权 kill 的 argv 构造可像 `build_argv` 一样脱离真 sudo 单测）。
- **executor 级实时性交错测试**：fake provider 在 install 内分批 emit 并用同步原语制造步内停顿，断言消费者在 provider 调用返回（StepFinished）**之前**已收到 OutputLine——让被禁止的「缓冲补发」解法必然挂测试（事件序列断言区分不了它，只有交错断言能）。
- 取消契约测试：fake 慢 provider 下 `cancel()` 后生成器以定义好的事件形态正常终结、记账含已发生步骤；生成器 `close()` 后桥接线程可 join、无线程泄漏。
- headless 等价性：`--install`/`--apply`/`--dry-run` 语义与现在一致（打印格式可因消费生成器微调）；`--apply` 多条目 manifest 能看到逐步事件驱动的输出。
- 不可妥协项①②③④⑤不回归（本任务重写 privilege，③逐命令 sudo/SUDO_USER 规则直接相关）；exit code 表（0/1/2/3/4）不回归——headless 无 tty 且无凭证时仍以 exit 4 干净失败。

## 风险与推进方式
- **体量**：四件套 review 大 → 按三个提交点推进：a（生成器+facade，含线程桥接）→ b（privilege）→ c（runner 流式+接入 OutputLine）。
- **生成器×线程桥接是最大不确定点** → 提交点 a 先攻；桥接形态定型前不动 b/c。
- **流式 runner 的超时/部分输出语义易踩坑** → 先写测试再实现。
- **privilege 真机行为无法单测全覆盖** → 矩阵用 fake run；真机冒烟手测记入 journal，**必须含提权步骤的取消路径**（提权 kill 成功 / 凭证失效降级）——EPERM 语义 fake 不出来，只有真机能验。

## 需同步修订的 spec（与代码一并交付，不许默默偏离）
- `core/directory-structure.md`：模块清单补 facade；「design-derived, not yet code-backed」状态按落地情况 reconcile（spec 自述要求）。
- `core/error-and-logging.md`：runner 合同补流式变体与程序化终止语义（含提权 kill 路径与降级）。
- `core/idempotency-and-execution.md`：executor 描述对齐生成器形态（事件流取代「emit 透传」表述处）。
- `core/privilege-and-safety.md`：Rule 2 的 keep-alive/探测示例改为经由 runner（现示例裸 `subprocess.run` 与不可妥协项⑤、本任务「fake run 注入」测试口径冲突）；补探测 API 真实签名与「凭证失效 → 干净失败信号」的引擎侧语义；reconcile「not yet code-backed」状态头。
- `tui/ui-guidelines.md`：核对「脑暴露生成器」示例代码与真实接口签名一致；worker 示例 `is_cancelled()` 直接 `return` 弃用生成器的写法须与取消契约（close 时桥接收尾）核对。
- `core/catalog-and-providers.md`：若桥接给 `Ctx` 增改成员（如行事件接线），ctx 表格同步。

## 路线图上下文（供任务②③立项时引用）
- **任务② 三屏闭环**：browse（进屏后台 worker 全量 check() 流式刷新；只露 install）；plan-confirm；progress（行级日志，**节流/批量 marshal 是一等需求**——pre-mortem 首选死因是「慢/卡」，而行级日志正是最大卡源；取消 = 杀当前步 + 明示「系统可能半装，建议 `dpkg --configure -a`」+ 用户收尾，工具不自动补救）；sudo 探测自适应的 TUI 侧（apply 前无凭证则 `app.suspend()` 提示）；入口改造（裸命令进 TUI，headless 不回归）；Pilot 测试；动手前先出一页 wireframe（UI 设计无 spec）。
- **任务② 前置查证**：Textual 日志组件（RichLog）扛高频 append 的能力**未联网确认**，动手前查文档/实测。
- **任务③ installed 屏**：先回答「给用户看什么 browse 给不了的」（manifest 声明视角？声明 vs 实际 diff？）再立项。
