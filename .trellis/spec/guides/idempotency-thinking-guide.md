# Idempotency Thinking Guide

> **Purpose**: Before writing any provider or install step, make sure running it twice is a no-op the second time.

---

## Why this guide

Idempotency is a hard domain constraint (`CLAUDE.md`): the tool runs on the same machine repeatedly — incremental top-ups, retries after a failure — and must not error, double-install, or clobber. Most idempotency bugs are "I acted without checking first" or "I trusted a flag instead of the system".

---

## Before writing an install/apply step

### 1. Where is the `check`?

Every action is gated on a `check()` that reads **real** system state. If you can't write the check, the step isn't ready.

- [ ] Does this entry/provider have a `check()` that observes reality (dpkg, `snap list`, the file on disk), not a stored marker?
- [ ] Is the check **structural** (does the artifact actually exist) rather than trusting a recorded "installed" boolean? (Homebrew checks the keg dir; we check `dpkg-query ${Status}`.)
- [ ] Does the executor call `check()` *before* acting and skip when already satisfied?

### 2. Does the action converge, not accumulate?

- [ ] Re-running install on an already-installed entry → success no-op (not an error, not a second copy)?
- [ ] For config: does it write a **marked block** that gets *replaced* on re-run, not appended? (Append-without-markers is the classic non-idempotent bug.)
- [ ] Did you back up before the first write so a bad run is recoverable?

### 3. Did you distinguish "absent" from "errored"?

- [ ] Does a non-zero exit from the check mean "not installed", or could it mean a real error (e.g. `dpkg-query` exit 2, `is-enabled` returning non-zero for *masked*/*linked*)? Don't collapse every non-zero into "absent".

---

## Idempotency traps specific to this project

| Trap | Why it bites | Do instead |
|------|--------------|------------|
| Trusting a state ledger | User removes software by hand → ledger lies | Re-query the system every run |
| `apt-get update` "idempotency" | It has no stable end-state (always "changed") | Treat as a separate non-state step; guard by cache freshness; force on a fresh machine |
| Appending to `~/.bashrc` | Grows every run | Marked managed block, replace-in-place |
| Multiple snaps in one `snap install` | Fails when 2+ already installed | One snap per command, guard with `snap list` |
| `flatpak remote-add` without `--if-not-exists` | Errors on re-run | Always `--if-not-exists` |
| `is-enabled` exit code as boolean | `static`/`masked`/`linked` aren't plain enabled/disabled | Inspect the printed state string |
| `dpkg -s` as installed-check | Reports removed-not-purged as present | Gate on `${Status}` == `install ok installed` |

---

## Plan mode is part of idempotency

If a provider supports `check_mode` (dry run) but secretly does nothing useful, a plan can look complete while items were no-ops.

- [ ] Does the provider implement check mode and report *would-change* without mutating?
- [ ] Does the UI distinguish "would change" from "cannot simulate / skipped"?

---

## Checklist before committing a provider

- [ ] `check()` reads live state, no ledger
- [ ] `install`/`remove`/`upgrade` are each safe to run twice
- [ ] Non-zero exits are classified (absent vs real error)
- [ ] Config writes use markers + backup
- [ ] The apt-cache refresh is decoupled and freshness-guarded
- [ ] A unit test runs the action twice and asserts the second is a skipped no-op
