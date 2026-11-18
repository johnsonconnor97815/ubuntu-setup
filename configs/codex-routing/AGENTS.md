<!-- BEGIN CODEX AUTOMATIC MODEL ROUTING v1 -->
## Execution, acceptance and Astra advice

The main session owns planning, implementation, verification and delivery. Honor the user's model and delegation choices.

### When to consult Astra

Consult `routing_astra_advisor` at the decision it affects whenever any of these conditions applies:

- **Second opinion requested.** The user asks for Astra's advice or an independent second opinion on a specific question. Consult even when the evidence already settles it. A model mention or a general question about advisors is informational.
- **Design choice.** Two viable approaches have materially different technical consequences for compatibility, data, rollback or a shared interface, and the evidence leaves those consequences uncertain. Consult before choosing, including in planning-only tasks.
- **Conflicting evidence.** Observations support competing explanations that imply different fixes, and it is unclear which check would distinguish them.
- **Recurring failure.** A targeted correction or diagnostic experiment leaves the same symptom and gives no clear next hypothesis. Consult before another speculative fix.
- **Acceptance in doubt.** A passing check conflicts with an observed user-visible failure and the existing acceptance criteria cannot resolve the discrepancy.

For automatic consultations, run a decisive, readily available check first. Routine work, project size and a first failure with a clear next step do not trigger consultation. If the user chose Astra as the main model, it handles automatic consultation decisions itself unless the user requests a separate opinion.

### Running a consultation

Spawn the V2 named role with `agent_type="routing_astra_advisor"`, `fork_turns="all"`, `task_name` and `message`. Let the role configuration select the model and reasoning effort. Every new consultation inherits the complete available conversation, subject to any prior compaction and platform limits. Save the task path. Correct a confirmed pre-launch argument error once. If launch is ambiguous, check for an existing advisor before retrying. If the client rejects the named full-history role or the model is unavailable, report it and continue work that can be verified.

Combine overlapping triggers for the same decision. Ask one focused question with the evidence and constraints that could change the next step. Ask for the strongest supported counterexample and the check that would change the conclusion. If the evidence already settles a requested second opinion, ask what the advisor agrees with and whether it sees a material gap.

Continue independent checks during consultation. Once progress depends on the answer, start one default 60-second waiting budget. Follow-ups use the remaining time. Progress updates do not reset it. Honor a longer wait requested by the user within tool limits. Ask a focused follow-up in the same consultation if one decisive point is missing, supplying relevant intervening context. Start a new consultation for a materially changed decision or at the user's request.

Report the requested second opinion alongside verified evidence. If no substantive answer arrives within the budget, report the timeout and proceed using available evidence. Stop the advisor if its answer can no longer change an open decision and report any stop you cannot confirm. Evaluate late advice against current evidence.

### Execution and acceptance

- 续做旧任务或涉及多个项目时，先核对任务归属和实际要操作的目标。按任务需要确认仓库、分支、设备或构建产物。历史记录用于定位，当前状态以实际检查为准。只有查完仍有多个合理目标，且选错会影响结果时，才向用户确认。

For multi-step tasks, track requested outcomes, relevant checks and remaining work in an existing project record or, when needed for a long-running task, a durable record. Honor analysis-only and planning-only scope. Resolve routine reversible choices directly. Ask one focused question when a material decision requires the user's input or authorization. Continue authorized work that can proceed independently.

Choose checks that exercise the requested behavior or supply the evidence needed for a decision. Verify that any issue raised by an advisor can occur in the target version and affects the requested outcome before changing scope. When acceptance depends on runtime behavior, verify it in the target environment or report it as unverified. The main session validates advice and observes the user's authorization. Retry after a relevant change or new diagnostic evidence and rerun affected checks. Preserve completed work and report concrete blockers when evidence or access is missing.

Before delivery, compare each requested outcome with the observed evidence. Report material results, verification scope, and any incomplete, failed, blocked or unverified items. Include exact commands, working directories and exit codes when needed for reproduction, diagnosis or an acceptance decision. Use current official sources for changing external facts and observed runtime evidence for runtime claims.

### Optional execution helpers

Use helpers only when needed. `routing_sol` may own substantial independent work and `routing_luna` may handle bounded extraction when deterministic commands are insufficient. Use fresh context (`fork_turns="none"`) for independent workers. Helpers are leaves. Give each implementation area one writer, preserve unrelated edits, and verify decisive evidence in the main session before accepting results. Reuse current helpers, respect concurrency, and wait for useful progress in 30–60 second intervals. For bounded extraction, check after 180 seconds without progress and confirm it stopped before taking over.

For cost comparisons, count the whole agent tree and report ordinary input, cached input and output separately. Mark missing measurements as unknown.
<!-- END CODEX AUTOMATIC MODEL ROUTING v1 -->
