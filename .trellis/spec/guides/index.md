# Thinking Guides

> **Purpose**: Expand your thinking to catch things you might not have considered before writing code.

---

## Why Thinking Guides?

**Most bugs and tech debt come from "didn't think of that"**, not from lack of skill. For this project the recurring blind spots are: running a step that wasn't idempotent, escalating privilege carelessly, breaking a layer boundary, or duplicating a fact that then drifts. These guides ask the right questions before you code.

---

## Available Guides

| Guide | Purpose | When to Use |
|-------|---------|-------------|
| [Idempotency Thinking Guide](./idempotency-thinking-guide.md) | Make sure running a step twice is a safe no-op | Writing any provider or install/config step |
| [Safety Thinking Guide](./safety-thinking-guide.md) | Keep a `sudo`-running tool safe on a stranger's machine | Anything that escalates privilege, writes user files, or runs a command |
| [Cross-Layer Thinking Guide](./cross-layer-thinking-guide.md) | Think through data/control flow across catalog → core → provider → tui | Features spanning multiple layers |
| [Code Reuse Thinking Guide](./code-reuse-thinking-guide.md) | Identify duplication and parallel definitions that drift | When you notice repeated patterns or facts encoded in 2+ places |

---

## Quick Reference: Thinking Triggers

### Writing a provider or install step
→ Read [Idempotency](./idempotency-thinking-guide.md) **and** [Safety](./safety-thinking-guide.md)
- [ ] Is there a live-system `check()` gating the action?
- [ ] Is it safe to run twice?
- [ ] Does it escalate per-command (not whole-app root) and write user files as the real user?

### Escalating privilege / writing `~/.bashrc` / running `sudo`
→ Read [Safety](./safety-thinking-guide.md)
- [ ] `sudo -v` up front + `-n` probe before the step?
- [ ] User path resolved via `SUDO_USER`, not `~`?
- [ ] Marked block + backup, not append/clobber?

### Feature touches catalog + core + tui
→ Read [Cross-Layer](./cross-layer-thinking-guide.md)
- [ ] Dependency direction held (`core` imports nothing from `tui`)?
- [ ] Type dispatch only in the provider registry?

### Adding a field or a constant used in several places
→ Read [Code Reuse](./code-reuse-thinking-guide.md)
- [ ] Schema + provider + authoring doc updated together?
- [ ] One shared identity/constant, not copies that drift?

---

## How to Use This Directory

1. **Before coding**: skim the relevant guide.
2. **During coding**: if something feels repetitive, privileged, or cross-cutting, check the guide.
3. **After bugs**: add the new "didn't think of that" to the relevant guide (use the `trellis-update-spec` skill).

---

**Core Principle**: 30 minutes of thinking saves 3 hours of debugging — and on this project, possibly someone else's broken machine.
