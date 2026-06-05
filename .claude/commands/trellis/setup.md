# Trellis Setup

Bootstrap this repo's local dev environment on a freshly cloned machine: install and index Codegraph, register the codegraph MCP server into the current CLI, and set your local Trellis developer identity. Idempotent — safe to re-run.

This command drives the same flow as the `trellis-setup` skill. The repo ships the full `.trellis/` tree and a project-level `.mcp.json`, so most config travels with the clone. What is machine-local and must be set up here: the `codegraph` binary + its `.codegraph/` index, your Trellis developer identity, and (Codex only) a user-level hooks flag + one-time `/hooks` approval.

Detect which CLI you are. The shared steps are identical; only Steps 3 and 5 differ for Claude Code vs Codex CLI.

---

## Step 1: Prerequisite check (detect, do not install)

Codegraph needs Node/npm. Never auto-install Node — if missing, stop and tell the user to install it.

```bash
node -v && npm -v
```

Install the codegraph CLI globally only if it is not already on PATH, then confirm:

```bash
command -v codegraph || npm install -g @colbymchenry/codegraph
codegraph --version
```

## Step 2: Build / refresh the Codegraph index

The index lives in `.codegraph/` at the repo root (gitignored). Initialize if absent, otherwise sync, then verify:

```bash
test -d .codegraph && codegraph sync || codegraph init
codegraph status
```

`codegraph status` should report an index with symbols/files. Re-running picks `sync` once `.codegraph/` exists, so it never re-initializes.

## Step 3: Register the codegraph MCP server (CLI-specific)

- **Claude Code**: the committed project-level `.mcp.json` already declares the `codegraph` MCP server (`type: stdio`, `command: codegraph`, `args: ["serve", "--mcp"]`). It is picked up automatically once the repo is trusted — you only need the binary on PATH (Step 1). If `.mcp.json` is missing or the binary path differs, regenerate the project entry with `codegraph install -t claude -l local -y` — note this also writes `.claude/settings.json` (auto-allow permissions) and runs `codegraph init`; add `--no-permissions` to write only `.mcp.json`. The regenerated `.mcp.json` is byte-identical to the committed one.
- **Codex CLI**: codegraph can only register Codex at the **user level** (`~/.codex/config.toml`); there is no project-level Codex MCP install. Run `codegraph install -t codex -l global -y`. Re-running leaves an existing `[mcp_servers.codegraph]` entry intact. Preview without writing via `codegraph install --print-config codex`.

## Step 4: Set your Trellis developer identity

```bash
python3 .trellis/scripts/init_developer.py <your-name>
```

Idempotent: if an identity exists, it prints `Developer already initialized: <name>` and exits without overwriting. To change it, remove `.trellis/.developer` first.

## Step 5: Codex-only manual steps (guidance, not automated)

- **Claude Code**: nothing to do — hooks in committed `.claude/hooks/` + `.claude/settings.json` are active on clone.
- **Codex CLI**: the project ships `.codex/hooks.json`, but Codex will not run it until you take three user-level actions this project skill cannot perform:
  1. Enable the hooks feature in **user-level** `~/.codex/config.toml`: `[features]` → `hooks = true` (required on 0.129–0.130; may default on at 0.131+, but safe to set).
  2. Trust this project in `~/.codex/config.toml`: `[projects."/absolute/path/to/this/repo"]` → `trust_level = "trusted"` so its `.codex/` layers load.
  3. Run `/hooks` once in Codex to review and approve the project's hook definition. Unmanaged project hooks stay inactive until approved.

This command only describes these steps; it does not edit your user-level Codex config.

---

## Verification

Re-running must be side-effect-free. Confirm:

- `codegraph status` shows an index with symbols/files.
- The `codegraph` MCP tools are available in your CLI.
- `cat .trellis/.developer` shows your name.
