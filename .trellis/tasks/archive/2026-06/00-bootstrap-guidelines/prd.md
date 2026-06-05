# Bootstrap Task: Fill Project Development Guidelines

**You (the AI) are running this task. The developer does not read this file.**

The developer just ran `trellis init` on this project for the first time.
`.trellis/` now exists with empty spec scaffolding, and this bootstrap task
exists under `.trellis/tasks/`. When they want to work on it, they should start
this task from a session that provides Trellis session identity.

**Your job**: help them populate `.trellis/spec/` with the team's real
coding conventions. Every future AI session — this project's
`trellis-implement` and `trellis-check` sub-agents — auto-loads spec files
listed in per-task jsonl manifests. Empty spec = sub-agents write generic
code. Real spec = sub-agents match the team's actual patterns.

Don't dump instructions. Open with a short greeting, figure out if the repo
has any existing convention docs (CLAUDE.md, .cursorrules, etc.), and drive
the rest conversationally.

---

## Status (update the checkboxes as you complete each item)

- [x] Replace the generic frontend/backend template with this project's real layers (core / tui / catalog)
- [x] Fill core (brain) guidelines — directory-structure, catalog-and-providers, idempotency-and-execution, privilege-and-safety, error-and-logging
- [x] Fill tui (Textual) guidelines
- [x] Fill catalog authoring guidelines
- [x] Add project thinking guides (idempotency, safety) + adapt cross-layer / code-reuse
- [x] Verify: no placeholders, internal links resolve, index files match the file set

Note: the repo has no product source code yet, so these specs are **prescriptive** (the contract for code-to-be-written), derived from `CLAUDE.md` + `design-direction.md` and verified against current Ubuntu/apt/snap/flatpak/systemd/sudo/Textual docs. Reconcile with reality when code lands.

---

## Spec files to populate


### Root

| File | What it documents |
|------|-------------------|
| `.trellis/spec/index.md` | Project overview, architecture map, prescriptive-status note, global conventions, non-negotiables |

### Core (the brain) — `.trellis/spec/core/`

| File | What it documents |
|------|-------------------|
| `index.md` | Core layer navigation + non-negotiables |
| `directory-structure.md` | Package layout; brain/hands/face boundary; dependency direction |
| `catalog-and-providers.md` | Declarative entry, provider protocol, typed registry, verified per-provider command idioms |
| `idempotency-and-execution.md` | Live-query idempotency, dependency-ordered planning, plan-by-default, fail-fast, exit codes, manifest, apt-cache case |
| `privilege-and-safety.md` | Never-root, per-command sudo + keep-alive, `SUDO_USER` home, managed-block+backup, transparency/audit |
| `error-and-logging.md` | The single subprocess runner, exception taxonomy, audit log |

### TUI (the face) — `.trellis/spec/tui/`

| File | What it documents |
|------|-------------------|
| `index.md` | TUI layer navigation + non-negotiables |
| `ui-guidelines.md` | No-business-logic boundary; App/Screen/Widget; `reactive()`; `@work(thread=True)` worker seam; messages; interaction model; Pilot testing |

### Catalog (the data) — `.trellis/spec/catalog/`

| File | What it documents |
|------|-------------------|
| `index.md` | Catalog layer navigation + non-negotiables |
| `authoring-guidelines.md` | Entry shape, fields per `type`, `depends_on`, provenance/trust, LLM-phase constraints |

### Thinking guides — `.trellis/spec/guides/`

| File | Status |
|------|--------|
| `idempotency-thinking-guide.md` | Added (project-specific) |
| `safety-thinking-guide.md` | Added (project-specific) |
| `cross-layer-thinking-guide.md` | Rewritten for this project's layers |
| `code-reuse-thinking-guide.md` | Kept; Trellis-internal gotcha replaced with a project one |
| `index.md` | Updated to index the four guides |

Removed: the generic `.trellis/spec/backend/` and `.trellis/spec/frontend/` template directories (this is a single Python TUI app, not a web frontend/backend split).

---

## How to fill the spec

### Step 1: Import from existing convention files first (preferred)

Search the repo for existing convention docs. If any exist, read them and
extract the relevant rules into the matching `.trellis/spec/` files —
usually much faster than documenting from scratch.

| File / Directory | Tool |
|------|------|
| `CLAUDE.md` / `CLAUDE.local.md` | Claude Code |
| `AGENTS.md` | Codex / Claude Code / agent-compatible tools |
| `.cursorrules` | Cursor |
| `.cursor/rules/*.mdc` | Cursor (rules directory) |
| `.windsurfrules` | Windsurf |
| `.clinerules` | Cline |
| `.roomodes` | Roo Code |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.vscode/settings.json` → `github.copilot.chat.codeGeneration.instructions` | VS Code Copilot |
| `CONVENTIONS.md` / `.aider.conf.yml` | aider |
| `CONTRIBUTING.md` | General project conventions |
| `.editorconfig` | Editor formatting rules |

### Step 2: Analyze the codebase for anything not covered by existing docs

Scan real code to discover patterns. Before writing each spec file:
- Find 2-3 real examples of each pattern in the codebase.
- Reference real file paths (not hypothetical ones).
- Document anti-patterns the team clearly avoids.

### Step 3: Document reality, not ideals

**Critical**: write what the code *actually does*, not what it should do.
Sub-agents match the spec, so aspirational patterns that don't exist in the
codebase will cause sub-agents to write code that looks out of place.

If the team has known tech debt, document the current state — improvement
is a separate conversation, not a bootstrap concern.

---

## Quick explainer of the runtime (share when they ask "why do we need spec at all")

- Every AI coding task spawns two sub-agents: `trellis-implement` (writes
  code) and `trellis-check` (verifies quality).
- Each task has `implement.jsonl` / `check.jsonl` manifests listing which
  spec files to load.
- The platform hook auto-injects those spec files + the task's `prd.md`
  into every sub-agent prompt, so the sub-agent codes/reviews per team
  conventions without anyone pasting them manually.
- Source of truth: `.trellis/spec/`. That's why filling it well now pays
  off forever.

---

## Completion

When the developer confirms the checklist items above are done with real
examples (not placeholders), guide them to run:

```bash
python3 ./.trellis/scripts/task.py finish
python3 ./.trellis/scripts/task.py archive 00-bootstrap-guidelines
```

After archive, every new developer who joins this project will get a
`00-join-<slug>` onboarding task instead of this bootstrap task.

---

## Suggested opening line

"Welcome to Trellis! Your init just set me up to help you fill the project
spec — a one-time setup so every future AI session follows the team's
conventions instead of writing generic code. Before we start, do you have
any existing convention docs (CLAUDE.md, .cursorrules, CONTRIBUTING.md,
etc.) I can pull from, or should I scan the codebase from scratch?"
