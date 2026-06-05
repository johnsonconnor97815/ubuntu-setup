---
name: trellis-setup
description: "Bootstraps this repo's local dev environment on a freshly cloned machine: installs and indexes Codegraph, registers the codegraph MCP server into the current CLI (Claude Code or Codex), and sets the local Trellis developer identity. Idempotent — safe to re-run. Use right after `git clone` on a new machine, or when codegraph/Trellis identity is missing."
---

# Trellis Setup — Cross-Machine Environment Bootstrap

Bring a freshly cloned checkout of this repo to parity with the original machine. This skill orchestrates already-idempotent commands; there is no wrapper script — run each step in order and stop on the first hard failure.

The repo ships the full `.trellis/` tree and a project-level `.mcp.json`, so most config travels with the clone. What does NOT travel and must be set up locally:

- The `codegraph` binary and its index (`.codegraph/` is gitignored — machine-local).
- Your Trellis developer identity (`.trellis/.developer` is gitignored).
- For Codex only: a user-level feature flag + one-time `/hooks` approval (cannot be automated by a project skill).

**Detect which CLI you are first.** If you are Claude Code, follow the Claude notes; if you are Codex CLI, follow the Codex notes. The shared steps are identical; only steps 3 and 5 differ per CLI.

---

## Step 1 — Prerequisite check (detect, do not install)

Codegraph needs Node/npm. This skill never installs Node — if it is missing, stop and tell the user to install it.

```bash
node -v && npm -v
```

If either command fails: report that Node.js + npm must be installed first (e.g. via the system package manager or nvm), then stop.

Check whether the `codegraph` CLI is on PATH; install it globally only if absent:

```bash
command -v codegraph || npm install -g @colbymchenry/codegraph
```

Confirm it resolves:

```bash
codegraph --version
```

Idempotency: if `codegraph` already resolves, the `npm install` is skipped entirely.

## Step 2 — Build / refresh the Codegraph index

The index lives in `.codegraph/` at the repo root (gitignored). Initialize it if absent, otherwise sync incrementally:

```bash
# from the repo root
test -d .codegraph && codegraph sync || codegraph init
```

- `codegraph init` initializes `.codegraph/` and builds the initial index.
- `codegraph sync` incrementally updates an existing index.

Verify the index exists and has content:

```bash
codegraph status
```

`codegraph status` should report an index with symbols/files. Idempotency: re-running picks `sync` once `.codegraph/` exists, so it never re-initializes.

## Step 3 — Register the codegraph MCP server (CLI-specific)

**If you are Claude Code:**

The project-level `.mcp.json` is committed in this repo and already declares the `codegraph` MCP server:

```json
{ "mcpServers": { "codegraph": { "type": "stdio", "command": "codegraph", "args": ["serve", "--mcp"] } } }
```

So Claude Code picks up codegraph automatically once the repo is trusted — you only need the `codegraph` binary on PATH (done in Step 1). Nothing to write. If `.mcp.json` is somehow missing or the binary path differs, you may regenerate the project-level entry with:

```bash
codegraph install -t claude -l local -y
```

Note what `-l local` actually does (verified, v0.9.9): besides writing the project-level `.mcp.json`, it also writes/merges `.claude/settings.json` (codegraph auto-allow permissions) and runs `codegraph init` (creates/refreshes `.codegraph/`, which Step 2 already handled). The resulting `.mcp.json` is byte-identical to the one committed here, so re-running is safe/idempotent. To regenerate ONLY `.mcp.json` without touching the auto-allow permissions list, add `--no-permissions`.

**If you are Codex CLI:**

Codegraph can only register the Codex MCP server at the **user level** (`~/.codex/config.toml`) — there is no project-level Codex MCP install. Run:

```bash
codegraph install -t codex -l global -y
```

This writes (or leaves unchanged if already present) under `~/.codex/config.toml`:

```toml
[mcp_servers.codegraph]
command = "codegraph"
args = ["serve", "--mcp"]
```

Idempotency: re-running leaves an existing entry intact. To preview without writing, use `codegraph install --print-config codex`.

## Step 4 — Set your Trellis developer identity

The developer file (`.trellis/.developer`) is machine-local and not committed. Set it with your name:

```bash
python3 .trellis/scripts/init_developer.py <your-name>
```

Idempotency: if an identity already exists, the script prints `Developer already initialized: <name>` and exits 0 without overwriting. To change it, remove `.trellis/.developer` first, then re-run.

## Step 5 — Codex-only manual steps (guidance, not automated)

**Claude Code users:** nothing to do here — hooks live in committed `.claude/hooks/` + `.claude/settings.json` and are active on clone. You are done after Step 4.

**Codex CLI users:** the project ships `.codex/hooks.json`, but Codex will not run it until two user-level actions are taken — neither can be done by this project skill (project-scoped config cannot set feature flags, and hook trust requires interactive approval):

1. In your **user-level** `~/.codex/config.toml`, enable the hooks feature:
   ```toml
   [features]
   hooks = true
   ```
   (On Codex CLI 0.131+ hooks may default on; on 0.129–0.130 this flag is required. Setting it explicitly is safe either way.)
2. Trust this project so its `.codex/` layers (config, MCP, hooks) load — in `~/.codex/config.toml`:
   ```toml
   [projects."/absolute/path/to/this/repo"]
   trust_level = "trusted"
   ```
3. Launch Codex in this repo and run `/hooks` once to review and approve the project's hook definition. Unmanaged project hooks stay inactive until approved.

This skill only describes these steps; it does not edit your user-level Codex config.

---

## Done / Verification

Re-running this whole skill must be side-effect-free. Quick checks:

- `codegraph status` → shows an index with symbols/files.
- The `codegraph` MCP tools are available in your CLI (e.g. a `codegraph_*` tool, or `get_developer` for Trellis once the Trellis MCP/identity is set).
- `cat .trellis/.developer` → shows your name.

If all three hold, the environment matches the original machine.
