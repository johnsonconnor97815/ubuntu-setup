# Core (the Brain) — Spec Index

> Coding guidelines for `ubuntu_setup/core/` and `ubuntu_setup/cli.py`: the pure-logic layer that loads the catalog, plans, checks state, escalates privilege, and executes — with no Textual imports.

---

## Status

This project has no source code yet. These specs are **prescriptive** — the contract the first `core/` code must follow, derived from `CLAUDE.md` and `design-direction.md` and from current Ubuntu/apt/snap/flatpak/systemd/sudo documentation. Reconcile with reality once code lands.

---

## Guidelines

| Guide | What it covers |
|-------|----------------|
| [Directory Structure](./directory-structure.md) | Package layout; the brain / hands / face boundary; module dependency direction |
| [Catalog & Providers](./catalog-and-providers.md) | The declarative entry, the `check/install/remove/upgrade` provider protocol, the typed registry, and the verified command idioms per provider |
| [Idempotency, Planning & Execution](./idempotency-and-execution.md) | Live-query idempotency, dependency-ordered planning, plan-by-default, fail-fast execution, exit codes, the manifest, the apt-cache special case |
| [Privilege & Safety](./privilege-and-safety.md) | Never-run-as-root, per-command `sudo` + keep-alive, `SUDO_USER` home resolution, managed-block + backup, transparency/audit |
| [Errors, Runner & Logging](./error-and-logging.md) | The single subprocess boundary, the exception taxonomy, the audit log |

---

## The non-negotiables

1. **No `textual` import under `core/`.** The brain is headless-testable and runnable via `--apply`.
2. **`check()` is the idempotency engine** — query the live system, never a state ledger.
3. **Every external command goes through `core/runner.py`** (argv list, non-interactive env, logged).
4. **Never run as root; escalate per command.** Resolve user paths via `SUDO_USER`, never `~` under sudo.
5. **Plan before apply; fail fast on first error.** Re-run to resume — there is no rollback.
6. **Type dispatch lives only in the provider registry.** Adding a software type is a local change.
