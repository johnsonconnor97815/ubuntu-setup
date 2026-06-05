# Research: Codex CLI — skills/slash-commands, project MCP config, hooks enablement

- **Query**: How does Codex CLI ship reusable user-invokable skills/slash commands; can a project-scoped `.codex/config.toml` define `[mcp_servers]` (and what does `codegraph install --target codex` write); how is `.codex/hooks.json` activated?
- **Scope**: external (OpenAI Codex docs + GitHub repo), plus internal cross-check against this repo's `.codex/`
- **Date**: 2026-06-04
- **Target version**: Codex CLI ~0.129–0.131 (released 2026-05-07 → 2026-05-18), matching this repo's `.codex/config.toml` notes. Latest docs at developers.openai.com cross-checked.

---

## Q1 — Custom skills / slash commands / prompts discovery

**Short answer:** Codex has THREE distinct native mechanisms; `.agents/skills/` IS one of them (natively read), and **Skills are the current canonical way** to ship a reusable, user-invokable "run this routine" entry point.

### a) Native mechanisms that exist

| Mechanism | Location (project) | Location (user) | Status |
|---|---|---|---|
| **Skills** (`SKILL.md`) | `.agents/skills/` (scanned CWD → repo root) | `~/.agents/skills/` | Current / recommended |
| **Custom prompts** (`*.md` → `/prompts:<name>`) | none (project `.codex/prompts` NOT supported yet) | `~/.codex/prompts/` (= `$CODEX_HOME/prompts`) | **Deprecated**, superseded by Skills |
| **AGENTS.md** | `AGENTS.md` (repo root + nested) | `~/.codex/AGENTS.md` | Always-on instruction layer |

- **Skills** — A skill is a directory containing `SKILL.md` with YAML frontmatter (`name` + `description` required) plus optional `scripts/`, `references/`, `assets/`. Codex natively scans repo locations: it reads `.agents/skills` in **every directory from CWD up to repo root**, plus `~/.agents/skills` (USER), `/etc/codex/skills` (ADMIN). Progressive disclosure: only `name`/`description`/path go into the system prompt at session start; the `SKILL.md` body loads only when the skill is chosen. Skills can be invoked **explicitly** (e.g. `$skill-name` reference) or **implicitly** (Codex picks them when the task matches the description). Source: https://developers.openai.com/codex/skills and https://developers.openai.com/codex/concepts/customization (current). Implementation: `codex-rs/core/src/skills/loader.rs` (`skill_roots_from_layer_stack`, `discover_skills_under_root`, `parse_skill_file`) — see https://zenn.dev/takiko/articles/codex-cli-agent-skills-implementation (2026-01-12).
- **Custom prompts (deprecated)** — Markdown files in `$CODEX_HOME/prompts` (`~/.codex/prompts/*.md`); filename → `/prompts:<name>` slash command; only top-level `.md` files, non-`.md` ignored; supports `$NAME` named args (`key=value`) and `$1`/`$ARGUMENTS` positional, with `description`/`argument-hint` frontmatter. **The docs page explicitly states: "Custom prompts are deprecated. Use skills…"** They are also USER-only — NOT shareable via the repo. Source: https://developers.openai.com/codex/custom-prompts; impl `codex-rs/core/src/custom_prompts.rs` (PR https://github.com/openai/codex/pull/2696). Project-scoped `.codex/prompts` is an **open feature request, not implemented** as of 2026-01: https://github.com/openai/codex/issues/9848.
- **Built-in slash commands** — `/init`, `/review`, `/model`, `/plan`, `/mention`, `/new`, etc. are built into the TUI; you cannot add new top-level built-ins, only custom prompts (`/prompts:…`) or skills. Source: https://developers.openai.com/codex/cli/slash-commands.

### b) Is `.agents/skills/` native, or only because AGENTS.md points to it?

**`.agents/skills/` is read NATIVELY by Codex** — it is the canonical repo skill location. Codex's Rust loader scans `.agents/skills` from CWD up to the repo root independently of any AGENTS.md instruction. So in this repo the 10 `.agents/skills/<name>/SKILL.md` trees ARE discoverable by Codex on their own. The AGENTS.md pointer (the Trellis block mentioning `.agents/skills/`) is reinforcing, not the activation mechanism. Source: https://developers.openai.com/codex/skills (REPO scope = `$CWD/.agents/skills`, `$REPO_ROOT/.agents/skills`).

Note on `.codex/skills/` (this repo has an empty one): Codex's published skill scan roots are `.agents/skills` (repo/user) and `/etc/codex/skills` (admin) — **NOT** `.codex/skills`. The empty `.codex/skills/` here is not a documented native skill root; skills should live under `.agents/skills/`. (The `cli-creator` curated skill references a `.codex/skills/...` path only as a user-chosen explicit location, not an auto-scanned root.)

### c) Canonical "run this setup routine" entry point on current Codex

**A Skill** (`.agents/skills/<name>/SKILL.md`), checked into the repo. It is the only mechanism that is (1) repo-shareable, (2) natively discovered, (3) user-invokable as a slash-style `$<name>` reference AND implicitly triggerable, and (4) able to bundle `scripts/`. Custom prompts (`/prompts:<name>`) would also give a literal slash command but are deprecated and user-only (cannot ship in the repo). A plain AGENTS.md instruction works but is always-on context, not an invokable entry point.

---

## Q2 — Project-level MCP server config + `codegraph install --target codex`

**Short answer:** YES — a project-scoped `.codex/config.toml` CAN define `[mcp_servers]`, but only when the project is **trusted**. However, `codegraph install --target codex` writes to the **USER-level** `~/.codex/config.toml`, not project-level.

### Project-scoped `[mcp_servers]` is supported (trusted projects only)

- Codex loads project `.codex/config.toml` layers (root → CWD, closest wins) and merges them above user config — **only for trusted projects**; untrusted projects skip all `.codex/` layers (config, hooks, rules). Source: https://developers.openai.com/codex/config-basic and .../config-advanced (current).
- MCP servers are an allowed project-scoped key (`mcp_servers.*` is NOT in the ignored-keys list, which only blocks provider/auth/notify/profile/telemetry keys). An OpenAI maintainer confirmed: "You can define a project-local `.codex/config.toml` and specify project-specific settings like MCP servers. One caveat: project-local config.toml files are ignored if the project is not trusted." Source: https://github.com/openai/codex/issues/2628 and #2554.
- Format (stdio): `[mcp_servers.<name>]` with `command` + optional `args`, `env`, `enabled`, `startup_timeout_sec`, `tool_timeout_sec`. Source: https://developers.openai.com/codex/config-sample.
- Caveat: an open report (#2628) claims project-scoped MCP entries sometimes "show in settings but don't actually activate," steering users back to `~/.codex/config.toml` — so project-level MCP works but has had reliability complaints.

### What `codegraph install --target codex` writes (codegraph repo)

- **Target location: USER-level `~/.codex/config.toml`**, NOT project-level. The codegraph install matrix lists: Codex CLI → MCP config `~/.codex/config.toml` (TOML `[mcp_servers.codegraph]`), instructions file `~/.codex/AGENTS.md`. Source: https://github.com/colbymchenry/codegraph/issues/137 (the install/targets table).
- **Format written** (TOML `[mcp_servers.codegraph]`, stdio):
  ```toml
  [mcp_servers.codegraph]
  command = "codegraph"
  args = ["serve", "--mcp"]
  ```
  Cross-checked against codegraph's other-agent snippets which all use `command = "codegraph"`, `args = ["serve", "--mcp"]` (Claude `.claude.json` uses the same command/args). Some forks add `startup_timeout_sec = 60`. Sources: https://github.com/codeaudit/codegraph (README install description) and https://github.com/isink17/codegraph (Codex `config.toml` snippet). `codegraph serve --mcp` starts the MCP server: https://colbymchenry.github.io/codegraph/reference/mcp-server/.
- **Location flags:** `codegraph install` supports `--location global|local` and `--target=...,codex` plus `--print-config codex` (dump snippet, no writes). For Codex the documented/default write is global (`~/.codex/config.toml` + `~/.codex/AGENTS.md`); project-local surfaces are auto-wired for Cursor (`.cursor/rules/codegraph.mdc`), not specifically for Codex. Source: https://github.com/codeaudit/codegraph. (Could not pin the exact v0.9.9 source line for whether `--location local` writes Codex to a project `.codex/config.toml`; the published behavior describes Codex as the global `~/.codex` target. Treat project-local Codex write as unverified for v0.9.9.)

---

## Q3 — Codex hooks enablement (`.codex/hooks.json`)

**Short answer:** The repo's `.codex/config.toml` description is accurate **for the 0.129–0.131 era** that this repo targets. Note the latest docs have since flipped the default.

- **Feature flag:** In 0.129+, the activation flag is `[features].hooks = true` (user-level). The legacy name `codex_hooks = true` was **aliased** to `hooks` in 0.129 (PR #20522, "Alias codex_hooks feature as hooks", 2026-05-01) and emits a deprecation warning. Sources: https://github.com/openai/codex/compare/rust-v0.128.0...rust-v0.129.0 and the deprecation-warning report https://github.com/openai/codex/issues/21682 ("in Codex CLI 0.129.0, the CLI now warns that `[features].codex_hooks` is deprecated… use `[features].hooks`"). Third-party confirmation that 0.130 setup tooling emits `[features].hooks = true`: https://github.com/Yeachan-Heo/oh-my-codex/pull/2216.
- **Must be USER-level:** Feature flags persist to `$CODEX_HOME/config.toml` (i.e. `~/.codex/config.toml`); `codex features enable/disable` and `--enable` write there. Project-local `.codex/config.toml` cannot set feature flags. Source: https://developers.openai.com/codex/cli/features (`codex features enable <flag>` "write to `$CODEX_HOME/config.toml`").
- **One-time `/hooks` TUI approval:** Accurate for this era. The `/hooks` browser shipped in 0.129 (PR #19882, "Add /hooks browser for lifecycle hooks", 2026-04-30). Hook **trust enforcement** — "unmanaged hooks cannot run until the current definition has been reviewed" — landed via PR #20321 (2026-04-30) and the `/hooks` TUI review flow PR #20684 (2026-05-05), squarely in the 0.129–0.131 window. So a project `.codex/hooks.json` (an unmanaged hook) stays inactive until approved in `/hooks`; a `--dangerously-bypass-hook-trust` flag (PR #21768) can skip persisted trust for automation. Sources: https://github.com/openai/codex/releases/tag/rust-v0.129.0, https://github.com/openai/codex/pull/20321, https://github.com/openai/codex/commit/93d53f65, https://developers.openai.com/codex/cli/reference.
- **IMPORTANT drift — latest default flipped:** The CURRENT docs page now says "Hooks are enabled by default" (set `[features].hooks = false` to turn off): https://developers.openai.com/codex/hooks. Plugin hooks were enabled by default in **0.131** (PR #22549). So this repo's claim that you must explicitly set `[features].hooks = true` is correct for 0.129/0.130 but may be unnecessary on the very latest builds where hooks default on. The `/hooks` trust review still applies regardless of the default.

### Internal cross-check (this repo)
- `.codex/hooks.json` defines a `UserPromptSubmit` command hook (`python3 -X utf8 .codex/hooks/inject-workflow-state.py`, timeout 15) — schema matches the official `UserPromptSubmit` hooks.json format (PR #6fef421 / #14626; field `timeout`, also accepts `timeoutSec`). It is an unmanaged project hook → gated behind `/hooks` trust.
- `.codex/config.toml` correctly notes feature flags can't be set project-level and that `[features.multi_agent_v2]` table form is 0.131+ only (it deliberately omits that block to avoid `FeatureToml` deserialization failures on ≤0.130).

---

## Implications for a cross-CLI bootstrap skill

- **Ship the bootstrap routine as a Skill** at `.agents/skills/<name>/SKILL.md` (frontmatter `name`+`description`, optional `scripts/`). This is the only repo-shareable, natively-discovered, invokable entry point in current Codex — and `.agents/skills/` is the same convention Claude Code skills use, so one tree can serve both. Do NOT rely on `.codex/prompts` (deprecated, user-only) or the empty `.codex/skills/` (not a native scan root).
- **MCP must be assumed user-level for Codex.** `codegraph install --target codex` writes `[mcp_servers.codegraph]` to `~/.codex/config.toml`. Project-level `[mcp_servers]` works only for trusted projects and has reliability caveats — a bootstrap skill should either run `codegraph install` (user-level) or instruct the user to trust the project before relying on a project-local `.codex/config.toml` MCP entry.
- **Hooks need user-level enablement + a trust step.** A project `.codex/hooks.json` does nothing until (on 0.129/0.130) `[features].hooks = true` is in `~/.codex/config.toml` AND the hook is approved once via `/hooks`. The bootstrap routine should set the user flag, mark the project trusted (`[projects."<abs>"].trust_level = "trusted"`), and tell the user to run `/hooks` once. On latest (0.131+) the flag may be unnecessary, but the `/hooks` trust approval still is.
- **Project trust is the master gate for all `.codex/` layers** (config, MCP, hooks). Any cross-CLI bootstrap that depends on project-scoped Codex config must first ensure `[projects."/abs/path"].trust_level = "trusted"` in `~/.codex/config.toml`, or every project-local mechanism silently no-ops.

## Caveats / Not Found
- Could not pin the exact codegraph **v0.9.9** source line confirming whether `--target codex --location local` writes to a project `.codex/config.toml` vs always `~/.codex/`. Published behavior describes Codex as a global (`~/.codex`) target; project-local Codex write for v0.9.9 is unverified.
- "Hooks enabled by default" reflects the latest docs; the precise release where the user-facing default flipped from off→on isn't cleanly dated beyond plugin-hooks-default in 0.131. For the 0.129–0.131 target range, treat explicit `[features].hooks = true` as required/safe.
