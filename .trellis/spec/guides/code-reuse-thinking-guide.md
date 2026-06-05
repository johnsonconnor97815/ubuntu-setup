# Code Reuse Thinking Guide

> **Purpose**: Stop and think before creating new code - does it already exist?

---

## The Problem

**Duplicated code is the #1 source of inconsistency bugs.**

When you copy-paste or rewrite existing logic:
- Bug fixes don't propagate
- Behavior diverges over time
- Codebase becomes harder to understand

---

## Before Writing New Code

### Step 1: Search First

```bash
# Search for similar function names
grep -r "functionName" .

# Search for similar logic
grep -r "keyword" .
```

### Step 2: Ask These Questions

| Question | If Yes... |
|----------|-----------|
| Does a similar function exist? | Use or extend it |
| Is this pattern used elsewhere? | Follow the existing pattern |
| Could this be a shared utility? | Create it in the right place |
| Am I copying code from another file? | **STOP** - extract to shared |

---

## Common Duplication Patterns

### Pattern 1: Copy-Paste Functions

**Bad**: Copying a validation function to another file

**Good**: Extract to shared utilities, import where needed

### Pattern 2: Similar Components

**Bad**: Creating a new component that's 80% similar to existing

**Good**: Extend existing component with props/variants

### Pattern 3: Repeated Constants

**Bad**: Defining the same constant in multiple files

**Good**: Single source of truth, import everywhere

---

## When to Abstract

**Abstract when**:
- Same code appears 3+ times
- Logic is complex enough to have bugs
- Multiple people might need this

**Don't abstract when**:
- Only used once
- Trivial one-liner
- Abstraction would be more complex than duplication

---

## After Batch Modifications

When you've made similar changes to multiple files:

1. **Review**: Did you catch all instances?
2. **Search**: Run grep to find any missed
3. **Consider**: Should this be abstracted?

---

## Gotcha: Parallel Definitions That Must Agree

**Problem**: The same fact is encoded in several places that drift independently. In this project:

- A catalog `type`'s field set lives in `catalog/schema.json`, is read by its provider in `core/providers/`, and is documented in `catalog/authoring-guidelines.md`. Add a field in one place only and the others silently diverge.
- A provider's `check()`, `install()`, and `remove()` must reference the **same software identity** (package name, app id, unit). If `check` looks for `nodejs` but `install` installs `node`, the step is never idempotent.
- Cross-cutting command concerns (the non-interactive env, the `sudo` wrapper, exit-code handling) belong in `core/runner.py` once — copy-pasting them into each provider guarantees one provider eventually forgets `DEBIAN_FRONTEND` or `LC_ALL=C`.

**Symptom**: A new `type` validates but does nothing; a step re-runs every time (never "already installed"); one provider hangs on a debconf prompt while others don't.

**Prevention checklist**:
- [ ] Adding/renaming a catalog field? Update schema + provider + authoring doc together.
- [ ] In a provider, does `check`/`install`/`remove`/`upgrade` use one shared identity constant, not three string literals?
- [ ] Is a command concern (env, sudo, parsing) shared via the runner, not re-implemented per provider?

---

## Checklist Before Commit

- [ ] Searched for existing similar code
- [ ] No copy-pasted logic that should be shared
- [ ] Constants defined in one place
- [ ] Similar patterns follow same structure
