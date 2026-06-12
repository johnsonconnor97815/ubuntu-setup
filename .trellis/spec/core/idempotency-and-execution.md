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

- **Dependency expansion + topological sort** (code-backed: `core/planner.py::build_plan`, tests `tests/core/test_planner.py::TestClosureAndTopoSort`). Expand `depends_on` into the full closure, dedupe shared subtrees, guard against cycles, then topologically sort so each entry is acted on after its dependencies (Homebrew's `Dependency.expand` + `TopologicalHash`). A `ppa`/`deb` repo entry is a dependency of the `apt` entry that needs it. The implemented contract:
  - closure expansion applies to **install/upgrade** (a dependency converges with an implicit `install`; an explicit desired op for the same id wins); a **remove never pulls dependencies in**;
  - the order is **deterministic and stable**: depth-first in input order, dependencies before dependents, each id once — independent entries keep their listed order;
  - a dependency cycle (incl. self-dependency) raises `CatalogError` carrying the cycle path (e.g. `a -> b -> a`); the same id desired twice with **conflicting ops** is `CatalogError` (an exact duplicate is deduped); a dependency missing from the planning catalog (only possible against a filtered subset — the loader resolves `depends_on` against the full catalog) fails loudly.
- **Plan is data.** A `Plan` is a list of `Action(entry, op, predicted_state_change)` — no side effects. It can be rendered, diffed, and unit-tested headless.

---

## Plan mode is the default (trust primitive)

Before applying, render the plan and require confirmation — the single most important trust feature for an open-source tool that runs `sudo`. This is Ansible's `--check` (would-change) plus `--diff` (what changes), and nala's "show the plan before touching the system".

- **Plan prediction comes from `check()`, enforced by `ctx.check_mode`.** The "would this change?" signal is derived by comparing each entry's `check()` `State` to the desired op — no parallel simulation path needed. In plan mode the executor sets `ctx.check_mode=True`, and every provider `install`/`remove`/`upgrade` must honor it by making **zero** changes (the mutation guard; see the `ctx` definition in [catalog-and-providers.md](./catalog-and-providers.md)). A provider whose full effect can't be predicted from `check()` alone `emit`s that, and the UI must distinguish "would change" from "cannot fully simulate", never rendering a no-op as a confirmed change (Ansible pitfall: a silent no-op in check mode looks like coverage).
- **`predict_change(op, state) -> (would_change, label)`** (code-backed: `core/executor.py`, re-exported via `core/service.py`) is the single place that op-vs-state preview semantics live. Three outcomes: `(True, "<from> -> <to> (would change)")`, `(False, "already <state> (no change)")`, and `(None, "state unknown (cannot fully simulate)")` for a failed or not-yet-run `check()` — `None` must never be rendered as a confirmed change *or* a confirmed no-op. Consumers (TUI confirm screen, CLI plan rendering) print the label; they never re-derive the comparison themselves (non-negotiable ①: that derivation is brain logic). Tests: `tests/core/test_executor.py::TestPredictChange`.
- The rendered plan groups actions by op (Install / Remove / Upgrade) and shows the predicted state transition per entry.
- Diffs that could leak secrets or explode in size must be suppressible/truncatable (Ansible `diff: false` / `max_diff_size`).

---

## Execution: fail-fast

`core/executor.py` walks the ordered `Plan` as a **generator of progress events** (`core/events.py`: `RunStarted` → per step `StepStarted`, live `OutputLine`/`ctx.emit` payloads, `StepFinished` carrying the step's `StepResult` → always a final `RunFinished` with the results and exit code). For each action: `check()` → skip if already satisfied → otherwise apply via the provider (in a bridge worker thread, so provider `emit`s reach the consumer *live*, via a bounded queue — never buffered until the call returns). Consumers (the CLI, a TUI worker) just iterate; `core/service.py` wraps the stream with `cancel()` and records the transaction when the stream finishes — including on cancel or an abandoned/closed stream, never for a dry run.

**The failure policy is fail-fast (decided in `design-direction.md`):** on the first failed action, stop and report which entry failed and why. Re-running after a fix is safe because every prior step's `check()` now passes and is skipped — "fix the cause and re-run", not rollback (see *No rollback* below). Because the plan is topologically ordered, a failed prerequisite naturally prevents its dependents from running.

> Note vs prior art: topgrade defaults to *fail-soft* (keep going, summarize at the end). We deliberately chose **fail-fast** instead — simpler to reason about and safer on a stranger's machine. Keep that decision unless the user revisits it. Borrow topgrade's good parts: **detect-and-skip** entries whose provider/tool is unavailable, and emit a final **summary**.

Per-entry outcomes to record and surface: `changed` / `ok` (already satisfied, skipped) / `skipped` (unsupported on this host) / `failed`.

**Two kinds of "didn't run", kept distinct** (this is what reconciles fail-fast with detect-and-skip):

- A **`ProviderError`** — an *applicable* step failed (a command returned non-zero) — triggers **fail-fast**: stop the run, exit `1`.
- A **`PreconditionError`** — the entry isn't applicable on this host (e.g. `snapd` absent, or `software-properties-common` can't be installed) — is **skipped** (recorded `skipped`) and the run **continues**. This is detect-and-skip, not failure.
- A dependent of a *skipped* entry: if its own `check()` says it is already satisfied it stays `ok`; otherwise the executor **skips it too, naming the skipped dependency in the detail** (code-backed: the `skipped_ids` propagation in `core/executor.py`, tests `tests/core/test_executor.py::TestSkipPropagation`) — it never fails just because a dependency skipped. So a skip never silently leaves a half-built dependent — the topological order surfaces the consequence at the dependent.

### The `requires` gate (host applicability)

An entry may declare `requires: [desktop]` (see [catalog-and-providers.md](./catalog-and-providers.md)); the executor judges `entry.requires ⊆ capabilities` via `core/environment.py` **before** `check()` (code-backed, tests `tests/core/test_executor.py::TestRequiresGate`):

- an unmet requirement is an **explicit skip** — a visible `StepFinished(skipped)` with the reason, recorded in the transaction like any outcome, never a silent drop and never an error: a manifest replayed on a no-desktop machine must succeed with visible skips;
- detection is **lazy and once per run** (`environment.detect_capabilities`, probes through the runner seam): a plan with no `requires` never probes the host; callers may inject `capabilities` (the `service.apply`/`execute` parameter);
- the same skip **propagates** down the dependency chain per the rule above, and dry runs show the skip too.

The browse/scan surface applies the same judgment as a *filter*: `service.scan` does not yield inapplicable entries at all, and the TUI receives a `service.filter_catalog`-filtered catalog at startup (`cli._run_tui`) — invisibility is decided in the brain, never re-derived in the face (non-negotiable ①).

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
- `version` gates forward-compatible schema migrations. Enforce it on load: a non-integer `version`, or one **newer** than the code's `MANIFEST_VERSION`, is a `CatalogError` (exit `2`) — silently accepting a newer manifest means misreading fields written by a future schema.

### Load behavior: missing path is an error on `--apply`

`--apply <path>` with a nonexistent path must raise `CatalogError` (exit `2`), **not** be treated as an empty manifest. The first implementation silently "succeeded" on a typo'd path (planned zero actions, exit 0) and then *created* a fresh manifest file at the bogus path — masking the user's mistake. Only entry points that legitimately bootstrap state (e.g. the first `--install` on a fresh machine, writing the default XDG path) may initialize a missing manifest; an explicit replay of a user-supplied file never does.

---

## Real-install verification (the integration tier)

The unit suite proves the engine against fakes; catalog entries are additionally verified by **really installing them in disposable, clean Ubuntu 24.04 guests** (code-backed: `tests/integration/`). The protocol per entry — fresh `check` (absent; dry-run records nothing) → real install (exit 0, outcome `changed`, the binary runs, transaction recorded) → idempotent re-run (outcome `ok`, no second install) — is this spec's execution model asserted end-to-end: exit codes, stdout and manifest semantics.

Conventions (locked by the verify-infra task):

- **Two tiers** (the intersection-research split): plain **Docker containers** for the apt/dpkg/file class (`tests/integration/test_container.py`; a baked `verify-base` image = ubuntu:24.04 + NOPASSWD sudo for the stock `ubuntu` user + python3-venv + apt-packaged deps + fresh apt lists — the stock OCI image is *too* minimal to stand in for a fresh install), and **LXD/Incus system containers** for the systemd/snap/flatpak class (`tests/integration/test_system.py`; the real-VM escape hatch is the driver's `vm=True`, per-entry `config=` carries e.g. `security.nesting` for the docker entry). Drivers (`launch/exec/push/destroy`) live in `tests/integration/drivers.py` — `lxc` vs `incus` is just the binary name.
- **Gate**: everything is behind `UBUNTU_SETUP_INTEGRATION=1` (the `UBUNTU_SETUP_SMOKE` convention) — the default `python -m unittest discover -s tests` stays green and fast (gated classes skip instantly). Tiers run separately by module path: `UBUNTU_SETUP_INTEGRATION=1 python -m unittest tests.integration.test_container -v` (resp. `test_system`). Driver unit tests (mock host-run, `test_drivers.py`) are not gated.
- **Wheel injection**: the project wheel is built on the host (uv, pip fallback) into a temp dir, pushed into the guest, and installed into a `--system-site-packages` venv with `--no-deps` (24.04 is PEP 668 externally-managed; deps come from the guest's apt packages — no PyPI traffic, and headless paths never import textual). No host residue beyond setuptools' gitignored in-repo build byproducts (`build/`, `*.egg-info`); guests are one-per-entry, never reused — unique names are what make parallel entries safe.
- **Skip, never install, on the host**: a missing docker daemon or lxd/incus is an explicit skip naming the unlock step — the suite must never run sudo/apt/snap on the host.
- **Diagnostics**: on failure the guest transcript, the tool's in-guest audit log and the manifest snapshot land under `tests/integration/_artifacts/` (gitignored; override via `UBUNTU_SETUP_INTEGRATION_ARTIFACTS`; `UBUNTU_SETUP_INTEGRATION_KEEP=1` keeps the failed guest alive). `UBUNTU_SETUP_VERIFY_BASE_IMAGE` substitutes a byte-identical official base reference for hosts where docker.io sits behind a broken proxy (e.g. `mirror.gcr.io/library/ubuntu:24.04`).

---

## The apt cache is a special, non-idempotent case

`apt-get update` has no stable end-state (Ansible reports it always "changed"). Treat it as a separate, non-state-bearing step. The batching is **code-backed** (`core/providers/aptcache.py::AptCache`, tests `tests/core/test_aptcache.py`):

- **One `AptCache` guard per executor run**, shared with every step via `ctx.aptcache`. A repo-changing op (`deb` repo mode; the future `ppa`) calls `mark_repo_changed()` after writing its key/sources and **never updates itself**; a package-installing op (`apt`, `deb` direct mode) calls `ensure_fresh()` right before its `apt-get install`, which runs `apt-get update` **iff a repo change is pending** and then clears the flag. Net effect (the locked dedupe): a batch of N repo changes costs exactly one update, run before the first install that could consume them; a repo added later in the same run still triggers its own update before *its* first consumer; a plain apt run never updates. A failed update raises `ProviderError` with the pending flag intact (a retry updates again).
- After adding a `ppa`/`deb` repo, update before installing from it, or the candidate resolves stale/missing — that ordering is exactly what mark-then-consume guarantees (the planner already orders repo before package via `depends_on`).
- **The cross-run gap is closed by `check()`, not by a ledger:** a run that converges only repo entries ends with the pending change unconsumed (no update ran). The `deb` provider's repo check therefore includes the fetched-lists probe (the repo's `InRelease`/`Release` file exists in `/var/lib/apt/lists` under the exact apt-mangled name) — a configured-but-never-fetched repo reads ABSENT, so the next run re-converges it and the consuming install updates. Self-healing, consistent with "ask the system".
- A *time-based* freshness guard (Ansible's `cache_valid_time`) is deliberately **not** implemented: a time guard wrongly skips the first-ever update on a brand-new machine and is defeated by unrelated apt ops touching the lists dir (Ansible #79206). If stale Ubuntu-archive lists on a long-idle machine ever bite, revisit here rather than weakening the repo-change trigger.
