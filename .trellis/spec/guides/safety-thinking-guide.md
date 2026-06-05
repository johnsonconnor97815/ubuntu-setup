# Safety Thinking Guide

> **Purpose**: This tool runs `sudo` on strangers' machines. Before writing anything that escalates, writes user files, or runs a command, stop and ask the safety questions.

---

## Why this guide

The target users are strangers running an open-source tool that executes privileged commands (`design-direction.md`). The cost of a mistake is someone else's machine: root-owned dotfiles, a clobbered `~/.bashrc`, a half-broken system. Safety is a first-class requirement, not polish.

---

## Before escalating privilege

- [ ] Am I escalating a **single command** via `sudo`, not running the whole app as root?
- [ ] Did I validate `sudo` **up front** (`sudo -v`) while the screen is in a known state, and start the keep-alive?
- [ ] Did I **probe** with `sudo -n` before a privileged step so a password prompt can't ambush the TUI?
- [ ] Is `DEBIAN_FRONTEND=noninteractive` set **inside** the escalated command (sudo strips the parent's env)?

## Before writing a user-owned file

- [ ] Am I resolving the path via the **real user's** home (`SUDO_USER` → `pwd.getpwnam().pw_dir`), never `~`/`$HOME` (which may be `/root` under sudo)?
- [ ] Will the file end up **owned by the real user**, not root? (If running as root, drop privileges for the write.)
- [ ] Am I writing only **inside my marked block**, leaving the user's surrounding lines untouched?
- [ ] Did I **back up** the file (timestamped) before writing?
- [ ] Am I assuming the machine is **not** pristine (existing config present) and failing safe rather than clobbering?

## Before running any command

- [ ] Is it going through `core/runner.py` (argv list, `shell=False`, non-interactive env, logged)?
- [ ] Am I building a shell string from entry fields? (Injection risk — don't. Only `script` runs a shell line, and it's logged verbatim.)
- [ ] Is the exact command **logged** for audit before it runs?

## Before adding/trusting a catalog entry

- [ ] Is this expressible as a declarative `type` instead of `script`? (Prefer it.)
- [ ] If `script`: has a human reviewed it? (AI must never generate `script` entries.)
- [ ] Is `source` honest? AI/community entries are not silently promoted to the trusted set.

---

## The destructive-operation rule

There is no rollback for system changes (see [idempotency-thinking-guide.md](./idempotency-thinking-guide.md) and `../core/idempotency-and-execution.md`). So:

- The only reversible thing is config you wrote yourself — and only if you backed it up first.
- `remove`/`purge` are real losses; surface them clearly in the plan before applying.
- Plan-by-default + confirmation is the safety gate. Never apply without showing what will happen.

---

## Trust checklist (open-source `sudo` tool)

- [ ] Plan shown and confirmed before any mutation
- [ ] Every `sudo` command logged
- [ ] Catalog is human-readable; `script` entries reviewed
- [ ] Provenance marked; AI drafts isolated from the trusted set
- [ ] Tool is installed via pip/pipx/`.deb`, **not** `curl | bash`

---

**Core principle**: assume the machine belongs to someone who will be angry if you break it — because it does.
