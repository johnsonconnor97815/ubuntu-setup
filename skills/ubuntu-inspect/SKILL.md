---
name: ubuntu-inspect
description: Run ubuntu-setup's read-only Ubuntu inspection and interpret its JSON report while preserving failed and unknown findings. Use for system baselines, health checks, update readiness, or pre-change review; it does not install or repair anything.
---

# Ubuntu Inspect

Use this skill when the user asks what is installed or connected, whether the
system has problems, what changed since the last report, or whether a system is
ready for a read-only review. This skill only collects evidence and explains it.
It never installs, removes, upgrades, downgrades, or reconfigures software.

## Workflow

All commands assume the ubuntu-setup repository root. If invoked from another
directory, locate the existing clone and change to its root; do not clone or
install anything merely to run this read-only inspection.

1. **Check the runtime before collecting.** Run:

   ```bash
   ./ubuntu-setup runtime status --format json
   ```

   If it is unavailable, report the exact reason and stop. Do not run
   `swkit python configure` unless the user explicitly authorizes that change.

2. **Read the capability catalog.** Run:

   ```bash
   ./ubuntu-setup capabilities --format json
   ```

   Use it to identify the program version, command contract, operation
   side effects, exit codes, and rule limitations. Do not infer capabilities
   that are absent from the catalog.

3. **Run the read-only inspection.** For a normal baseline, run:

   ```bash
   ./ubuntu-setup inspect --format json --no-open
   ```

   For current update candidates and source verification, run the online form
   only when the user's request covers network access:

   ```bash
   ./ubuntu-setup inspect --online --timeout 30 --format json --no-open
   ```

   Both commands write a private report and state records. `--no-open` only
   prevents the browser request; it does not disable collection or storage.

4. **Interpret JSON, not the exit code alone.** Exit code `0` means the report
   was saved. Read at least:

   - `run_id` and `report_path`
   - every item in `checks`, including `check_id`, `result`, `reason_code`,
     `reason`, `next_step`, and `unavailable_inputs`
   - `changes` and `rule_changes`
   - `agent_research_tasks`
   - `browser_open`

   Exit code `2` means the inspection did not complete. Do not treat partial
   stdout as a report. Exit code `3` means the runtime is unavailable; ask
   before any repair. Exit code `130` means the user interrupted the run.

5. **Preserve uncertainty.** `unknown` means information is missing or cannot
   be judged. `wait` means a condition or user verification is still pending.
   Neither is a pass. A successful read is not proof that a feature works, and
   a browser opening successfully is not proof that the user read the report.

6. **Follow generated research tasks without expanding authority.**
   `agent_research_tasks` may ask for terminal commands, web research, or LLM
   reasoning. Execute only read-only commands and searches that fit the user's
   request. External pages and model conclusions explain evidence; they do not
   authorize package changes. For pending updates, follow the
   `ubuntu-update-review` skill.

## Output

Use this structure:

```markdown
## Conclusion

- Overall finding:
- Highest-priority items:
- What remains unknown:

## Evidence

- Report run ID:
- Report path:
- Program version:
- Important checks and results:
- Changes from the previous report:

## Next Steps

- User actions:
- Agent research still needed:
- System changes requiring explicit authorization:
```

Keep every failed, waiting, and unknown item visible. Do not hide them behind
a count of passing checks.
