# Idempotency, Planning & Execution

> How a selection of catalog entries becomes an ordered, previewed, fail-fast run that is safe to repeat. Owns `core/planner.py`, `core/executor.py`, and the manifest in `core/state.py`.

---

## Status: design-derived, not yet code-backed

Prescriptive. The execution model encodes explicit design decisions from the interview (`design-direction.md`): **live-query idempotency, plan-before-apply by default, fail-fast on first error, and an exportable manifest that bridges "manager" and "provisioner".** Patterns are grounded in Ansible, Homebrew, topgrade, and nala (cited inline).

---

## Idempotency: query the system, never a ledger

The domain constraint (`CLAUDE.md`) is that any run must be safely repeatable. The mechanism:

1. **Every entry has a `check()`** (provider method, or the `check` command for `script`). It reads *real* system state and returns `State` — see [catalog-and-providers.md](./catalog-and-providers.md).
2. **The executor calls `check()` before every action** and skips when the entry is already in the desired state.
3. **There is no state ledger as a source of truth.** A file that records "I installed X" drifts the moment the user removes X by hand, then lies. We follow Homebrew's structural check (does the installed artifact actually exist) and Ansible's read-state-then-act model. The manifest (below) records *desired* state and history — it is never consulted to decide whether something is currently installed.

Anti-pattern: gating an install on a stored boolean. Always re-derive current state from the system.

---

## Planning

`core/planner.py` turns a set of desired actions (install/remove/upgrade of selected ids — from the TUI or a `--apply <manifest>` run) into an ordered `Plan`.

- **Dependency expansion + topological sort.** Expand `depends_on` into the full closure, dedupe shared subtrees with a cache, guard against cycles, then topologically sort so each entry is acted on after its dependencies (Homebrew's `Dependency.expand` + `TopologicalHash`). A `ppa`/`deb` repo entry is a dependency of the `apt` entry that needs it.
- **Plan is data.** A `Plan` is a list of `Action(entry, op, predicted_state_change)` — no side effects. It can be rendered, diffed, and unit-tested headless.

---

## Plan mode is the default (trust primitive)

Before applying, render the plan and require confirmation — the single most important trust feature for an open-source tool that runs `sudo`. This is Ansible's `--check` (would-change) plus `--diff` (what changes), and nala's "show the plan before touching the system".

- **Plan prediction comes from `check()`, enforced by `ctx.check_mode`.** The "would this change?" signal is derived by comparing each entry's `check()` `State` to the desired op — no parallel simulation path needed. In plan mode the executor sets `ctx.check_mode=True`, and every provider `install`/`remove`/`upgrade` must honor it by making **zero** changes (the mutation guard; see the `ctx` definition in [catalog-and-providers.md](./catalog-and-providers.md)). A provider whose full effect can't be predicted from `check()` alone `emit`s that, and the UI must distinguish "would change" from "cannot fully simulate", never rendering a no-op as a confirmed change (Ansible pitfall: a silent no-op in check mode looks like coverage).
- The rendered plan groups actions by op (Install / Remove / Upgrade) and shows the predicted state transition per entry.
- Diffs that could leak secrets or explode in size must be suppressible/truncatable (Ansible `diff: false` / `max_diff_size`).

---

## Execution: fail-fast

`core/executor.py` walks the ordered `Plan`. For each action: `check()` → skip if already satisfied → otherwise apply via the provider → record a `StepResult`.

**The failure policy is fail-fast (decided in `design-direction.md`):** on the first failed action, stop and report which entry failed and why. Re-running after a fix is safe because every prior step's `check()` now passes and is skipped — "fix the cause and re-run", not rollback (see *No rollback* below). Because the plan is topologically ordered, a failed prerequisite naturally prevents its dependents from running.

> Note vs prior art: topgrade defaults to *fail-soft* (keep going, summarize at the end). We deliberately chose **fail-fast** instead — simpler to reason about and safer on a stranger's machine. Keep that decision unless the user revisits it. Borrow topgrade's good parts: **detect-and-skip** entries whose provider/tool is unavailable, and emit a final **summary**.

Per-entry outcomes to record and surface: `changed` / `ok` (already satisfied, skipped) / `skipped` (unsupported on this host) / `failed`.

**Two kinds of "didn't run", kept distinct** (this is what reconciles fail-fast with detect-and-skip):

- A **`ProviderError`** — an *applicable* step failed (a command returned non-zero) — triggers **fail-fast**: stop the run, exit `1`.
- A **`PreconditionError`** — the entry isn't applicable on this host (e.g. `snapd` absent, or `software-properties-common` can't be installed) — is **skipped** (recorded `skipped`) and the run **continues**. This is detect-and-skip, not failure.
- A dependent of a *skipped* entry will, on its own turn, find its precondition unmet and either skip too or fail with its own `ProviderError` (which then stops the run). So a skip never silently leaves a half-built dependent — the topological order surfaces the consequence at the dependent.

### Distinct exit codes (headless mode)

Define unambiguous exit codes up front so the tool is scriptable (topgrade conflated "failed" and "interrupted" under 1 — don't repeat that):

- `0` — all actions ok/changed
- `1` — stopped on a failed action (fail-fast, `ProviderError`)
- `2` — usage / invalid catalog or manifest (`CatalogError`)
- `3` — interrupted (SIGINT, `UserAbort`)
- `4` — required privilege unavailable (`PrivilegeError`: not a sudoer / `sudo -v` failed)

These map 1:1 to the exception taxonomy in [error-and-logging.md](./error-and-logging.md). A `PreconditionError` is *not* a termination code — it skips one entry and the run continues.

### Signals

Propagate `SIGINT`/`SIGTERM` to the currently-running child process and abort the run; don't let Ctrl-C silently advance to the next action (topgrade bug #1093). The runner owns child-process group handling — see [error-and-logging.md](./error-and-logging.md).

---

## No rollback — idempotent + resumable instead

System provisioning has no transaction/undo: you cannot reliably un-`apt-install` (dependencies, residual config). So we do **not** implement rollback. Recovery model:

- **Resume:** fix the failing cause, re-run; satisfied steps are skipped by their `check()`.
- **The one reversible thing is config we wrote ourselves:** `dotfile-block` backs up the file before writing (timestamped `.bak`) and removes only its own marked block. That backup is the only real "undo". See [privilege-and-safety.md](./privilege-and-safety.md).

---

## The manifest (manager ↔ provisioner bridge)

`core/state.py` owns the manifest: an exportable record of **desired state** plus a transaction history.

- **Every apply is recorded as a transaction** with a run id, timestamp, the actions, and their outcomes (nala's `history.json` model). This is the audit log (also see logging in [error-and-logging.md](./error-and-logging.md)).
- **Desired state is exportable and replayable.** Ad-hoc install/remove in the TUI updates the manifest; `--apply <manifest>` on a fresh machine reconstructs the same setup. This is what makes one tool both a *manager* (interactive lifecycle) and a *provisioner* (reproducible setup) — see `design-direction.md`.
- The manifest references catalog `id`s; it does **not** duplicate install logic.

### Format

JSON, stored at `~/.local/state/ubuntu-setup/manifest.json` (XDG state dir, resolved via `real_home()` — never `/root` under sudo). Validated on load; `--apply` plans from the `desired` list.

```json
{
  "version": 1,
  "desired": [
    { "id": "ripgrep", "op": "install" },
    { "id": "docker",  "op": "install" }
  ],
  "history": [
    {
      "run_id": "2026-06-04T12:30:05Z-a1b2",
      "started_at": "2026-06-04T12:30:05Z",
      "exit_code": 0,
      "actions": [
        { "id": "ripgrep", "op": "install", "outcome": "changed" },
        { "id": "docker",  "op": "install", "outcome": "ok" }
      ]
    }
  ]
}
```

- `desired` = the user's intended end-state (ad-hoc TUI actions update it); it is *not* a record of what is currently installed — current state is always re-derived via `check()`.
- `history` = append-only transactions (nala's model): one per apply, with the `run_id`, the `actions` and their `outcome` (`changed`/`ok`/`skipped`/`failed`), and the run's `exit_code`. `outcome` values match the per-entry outcomes above; `exit_code` values match the table above.
- `version` gates forward-compatible schema migrations.

---

## The apt cache is a special, non-idempotent case

`apt-get update` has no stable end-state (Ansible reports it always "changed"). Treat it as a separate, non-state-bearing step:

- Refresh the cache **once per batch** of repo changes, not per package.
- Guard with freshness (skip if `/var/lib/apt/lists` is recent — Ansible's `cache_valid_time`), **but force an unconditional update on a brand-new machine** (a time guard wrongly skips the first-ever update; an unrelated apt op can also touch the lists dir and defeat the guard — Ansible #79206).
- After adding a `ppa`/`deb` repo, update before installing from it, or the candidate resolves stale/missing.
