---
name: ubuntu-update-review
description: Review pending Ubuntu updates with ubuntu-setup's read-only report, APT dependency simulation, and official-source stability research. Use for update checks, conflict review, and update planning; it does not authorize or perform package changes.
---

# Ubuntu Update Review

Use this skill when the user asks what can be updated, whether updates are safe, or what could break after an Ubuntu update. The skill produces an evidence-backed review. It does not install, remove, downgrade, unlock, or force any package.

## Workflow

1. **Inspect the machine first.** Run:

   ```bash
   ./ubuntu-setup inspect --online --timeout 30 --format json --no-open
   ```

   Use the JSON output as the source of truth for the run ID, report path, check results, update candidates, simulated APT actions, and `agent_research_tasks`. If the online run is not possible, use:

   ```bash
   ./ubuntu-setup inspect --format json --no-open
   ```

   Then mark version and dependency conclusions as based on cached metadata and record the metadata age or uncertainty.

2. **Treat APT as the version authority.** Candidate versions, upgrades, added packages, removals, downgrades, and kept-back packages come from APT metadata and the report's dependency simulation. Web pages and model reasoning may explain impact, but must not replace the APT result.

3. **Review conflicts before stability.** From the JSON, answer the questions in `agent_research_tasks`:

   - Does the simulation add, remove, downgrade, or keep back packages?
   - Why is each held, locked, or phased package excluded?
   - Do changed packages affect networking, containers, drivers, display, login, editors, browsers, or other uses the user has stated?
   - Does executing several updates together create a risk that separate groups would not?

   Use read-only commands when the report does not identify a cause, for example:

   ```bash
   apt-cache policy <package>
   apt-cache rdepends <package>
   apt-mark showhold
   apt-get --simulate upgrade
   ```

   If APT says a package is deferred by phasing, report it as a phased rollout rather than a dependency conflict. Do not force phased updates unless the user explicitly asks for that override and the impact is explained.

4. **Research stability with web search and LLM reasoning.** Search by package name plus the exact candidate version, target Ubuntu release, and architecture. For security updates, drivers, networking, container runtime, login-related packages, and other high-impact packages, check:

   - Ubuntu Security Notices and Ubuntu package changelogs.
   - The package vendor's release notes or security advisory.
   - Official issue trackers, status pages, or support threads when a specific regression is suspected.

   Web search finds candidate sources; the LLM maps the evidence to the APT package version, explains the impact on this machine, and identifies what is still unconfirmed. Neither may invent a version, date, affected platform, or fix. If a source discusses a different version or does not explicitly map the version, mark that item `unknown` or `not_confirmed`; do not treat the newest dated changelog as evidence for the candidate version.

   Record for each conclusion: source URL, source date, package version, target Ubuntu release and architecture, and whether the issue is confirmed for this machine. Keep official facts, model inference, and unconfirmed items separate.

5. **Say `unknown` when evidence is missing.** A passing dependency simulation means APT can construct a package plan. It does not prove the software works after upgrade. If no official or credible source describes stability, set the stability status to `unknown`; do not describe the update as stable.

6. **Group changes by impact and verification.** A useful review normally separates:

   - Security fixes that should be prioritized.
   - Infrastructure or driver updates that need service, GPU, network, or reboot verification.
   - Application updates with lower system-wide impact.

   The grouping is risk-based, not a rule that every report must have exactly three batches. State the verification and rollback limitation for every high-impact group.

7. **Do not execute from this skill.** Actual installation requires the user's explicit authorization in the current task. Before execution, re-run the online inspection and dependency simulation, present the final package actions, compatibility evidence, verification steps, and rollback limits, and stop if the result changed.

## Output

Keep unresolved questions visible in the final answer instead of hiding them behind a passing check.

Use this structure and include the run ID and report path from the JSON:

```markdown
## Conclusion

- Overall conflict status: `no_conflict_found | conflict_found | unknown`
- Overall stability status: `reasonable_to_try | concerns_found | unknown`
- High-priority action and why:
- What remains unknown:

## Evidence From This Machine

- Report run ID:
- Report path:
- APT metadata status: online / cached; age if known:
- Candidate count:
- Security candidate count:
- Simulated actions: upgrades, installs, removals, downgrades, kept-back:
- Dependency result:

## Conflict Review

For every non-routine action or unknown, list the package, current and candidate
versions, APT action, affected local use, cause and evidence, risk, and proposed
handling. Routine upgrades may be summarized as a group, but do not hide any
install, removal, downgrade, hold, lock, or phased exclusion.

## Stability Evidence

For each high-impact or security package, list the package and version, official
source URL, source date, applicable release and architecture, security impact or
behavior change, known issues, restart or reload impact, verification step,
rollback or recovery limit, and evidence status.

## Recommended Groups

For each group, list the packages and versions, why they belong together, the
required authorization, verification commands or user actions, stop condition,
and rollback or recovery limitation.

## Remaining Questions

For each unresolved item, list the question, why it matters, the evidence
needed, and who should answer it.
```
