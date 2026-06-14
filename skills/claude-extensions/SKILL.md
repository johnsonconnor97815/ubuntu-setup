---
name: claude-extensions
description: Use when the user wants to manage Claude Code CLI's extensions on Ubuntu/Debian — add/remove/enable/disable MCP servers (stdio/http/sse), install/uninstall/enable/disable plugins, add/remove plugin marketplaces, or install/remove skills (~/.claude/skills). Covers picking servers/plugins/skills with taste (token cost, runtimes, secrets, scope). Drives scripts/claude.sh in the ubuntu-setup kit (a Claude Code extension manager) and extends it when a capability is missing. Works on headless servers over SSH.
---

# Claude Code Extension Management

The mechanics of installing the Claude Code CLI **and managing its three extension systems**
live in one script — **`scripts/claude.sh`** in the ubuntu-setup kit, a **component manager**
runnable as `swkit claude <action>` (or, for a human at a terminal, an interactive full-screen
screen via `swkit claude` / the bootstrap catalog — see §5). That script, not this prose, is the
single implementation: it sources `lib/common.sh` (idempotency probes, back-up-before-edit) and
**shells out to the official `claude` CLI** for MCP and plugins (the authoritative interface —
it owns scopes and storage and survives format changes), and manages **skills** as directories
under `~/.claude/skills/`.

The three extension systems are independent:

- **MCP servers** (`claude mcp …`) — stdio / http / sse servers, stored per **scope** (local /
  user / project). The kit defaults to **`--scope user`** (global, all your projects).
- **Plugins & marketplaces** (`claude plugin …`) — install/enable/disable plugins from added
  marketplaces; also user scope by default.
- **Skills** (files) — a `SKILL.md` (+ assets) in `~/.claude/skills/<name>/`. No `claude` CLI for
  these; the kit clones single-skill git repos (or a subdir of a multi-skill repo) into place.

Your job:

1. **Help the user choose** extensions on a machine whose owner you've never met (§2) — which MCP
   servers, plugins, skills — weighing **token cost, runtimes, and secrets**, then invoke the right
   action. Don't impose taste; recommend conservatively.
2. **Evolve `scripts/claude.sh`** when the user wants something it doesn't know yet — a new curated
   MCP server / marketplace / skill — under the **ubuntu-install** authoring contract (§4).

Everything runs **as the normal user, user-space, with no sudo** (the config lives in `$HOME`);
extension actions **refuse a sudo-wrapped run** so `~/.claude` stays user-owned. The only thing
that ever needs sudo here is installing the CLI itself or a runtime (Node) — and the kit **never**
auto-installs Node or runs `sudo npm` (see ubuntu-install §5 for the sudo handback).

## 1. Actions (the extension manager)

Run as `swkit claude <action>` (or `scripts/claude.sh <action>`). Everything is idempotent: every
add checks existence first, every remove checks first; re-running converges. `install`/`remove`/
`status` manage the **CLI binary**; the rest manage extensions and need the CLI present.

**CLI binary**
- **`status`** — `claude --version`; exit 0 iff installed.
- **`install [--method native|npm]`** / **`remove`** — native (default, official installer, no
  Node) or npm (needs Node ≥ 18; never `sudo npm`). Remove is best-effort.

**MCP servers** (`claude mcp`)
- **`mcp-add <curated-name>`** — add a curated server, no other args. Curated:
  `sequential-thinking`, `filesystem`, `memory`, `playwright` (all run via **Node/npx**),
  `context7` (HTTP, no runtime).
- **`mcp-add <name> [-t stdio|http|sse] [-s scope] [-e K=V]... -- <command…|url>`** — add any
  server. Default `-t stdio`, `-s user`. stdio: the command goes after `--`
  (`mcp-add foo -- npx -y some-mcp`). http/sse: the URL goes after `--` (`mcp-add bar -t http -- https://…`).
  Secrets via repeated `-e KEY=value` (env) — never hard-code a token into a curated entry.
- **`mcp-remove <name>`** — remove a configured server.
- **`mcp-search <term>`** — search the official MCP registry (needs `jq`; degrades gracefully).

**Plugins & marketplaces** (`claude plugin`)
- **`marketplace-add <owner/repo|git-url|path>`** / **`marketplace-remove <name>`** — manage
  marketplaces. Curated: `anthropics/claude-plugins-official`, `anthropics/skills`.
- **`plugin-install <name@marketplace>`** / **`plugin-remove <name>`** — install / uninstall a
  plugin (scope user). After adding a marketplace, browse installables with
  `claude plugin list --available`.
- **`plugin-enable <name>`** / **`plugin-disable <name>`** — toggle a plugin **without uninstalling**
  it. Use disable to reclaim context-window tokens from a plugin you're not using right now.

**Skills** (`~/.claude/skills/<name>/`)
- **`skill-install <curated-name>`** — install a curated skill (from `anthropics/skills`):
  `pdf`, `docx`, `pptx`, `frontend-design`, `mcp-builder`.
- **`skill-install <git-url> [name] [subdir]`** — install any single-skill repo (or a `subdir`
  of a multi-skill repo — the dir that contains `SKILL.md`). A repo with many skills under
  `skills/*/` is better added as a **plugin marketplace** instead.
- **`skill-remove <name>`** — remove a skill (a tar backup is saved to `~/.cache/ubuntu-setup/`
  first). **Kit-managed skills** (`ubuntu-install`, `zsh-setup`, `claude-extensions`) are protected
  and cannot be removed through this manager.

## 2. Helping the user choose

You're on a stranger's machine — **don't impose taste.** Lay out choices, recommend conservative
defaults, then run the matching action. The three things that actually matter:

- **Token cost.** Every enabled MCP server and plugin loads tool definitions / instructions into
  the context window on each session — a big server can cost tens of thousands of tokens. Enable
  what the user needs; prefer **`plugin-disable`** over uninstall for things used occasionally;
  don't bulk-enable.
- **Runtimes.** The curated stdio MCP servers need **Node** (`npx`); `context7` is HTTP and needs
  nothing. The kit **never installs Node** — if it's missing, point the user to `swkit node install`
  and let them decide. `mcp-add` warns when a Node server is selected without Node present.
- **Secrets.** Servers that need an API key/token take it via `-e KEY=value` (env) or
  `--header "Authorization: Bearer …"`. The kit does **not** store secrets in its own state; they
  go straight to the `claude` config. Never paste a secret into a curated definition or into git.

Suggestions by axis (offer, don't impose):

- **MCP:** `sequential-thinking` (reasoning), `context7` (live library docs, no runtime),
  `filesystem` (file access — scoped to home by default), `playwright` (browser), `memory`.
  Anything else: `mcp-search <term>` or `mcp-add <name> -t … -- …`.
- **Plugins:** add `anthropics/claude-plugins-official`, then `plugin-install <name>@claude-plugins-official`;
  enable/disable as needed.
- **Skills:** the document skills (`pdf`/`docx`/`pptx`) are broadly useful; `mcp-builder` /
  `frontend-design` for those tasks. Any single-skill git repo via `skill-install <git-url>`.

**Scope:** default `user` (global) suits "set up my machine". Use `-s project` only when the user
wants an MCP server committed to a specific repo's `.mcp.json`.

Present the exact plan (which `swkit claude …`, what it adds/writes) and wait for confirmation —
ubuntu-install §5. These actions are user-space and need no sudo; say so.

## 3. Idempotency & safety

- **Idempotent / live-observed:** MCP existence via `claude mcp get` (exit code); plugins/marketplaces
  via `claude plugin list` / `marketplace list`; skills via the directory. Add/remove gate on these.
- **User-space, no sudo:** actions refuse `EUID==0 && SUDO_USER`. Files under `$HOME` stay user-owned.
- **Back up before destroying:** `skill-remove` tars the skill first. MCP/plugin changes go through
  the `claude` CLI (which edits its own config); to roll back, re-add or re-enable.
- **No Node, no `sudo npm`, no NOPASSWD** — same non-negotiables as the rest of the kit.

## 4. Evolving `scripts/claude.sh` (for what it doesn't know yet)

You can always add an arbitrary server/marketplace/skill without a code change (`mcp-add … -- …`,
`marketplace-add <repo>`, `skill-install <git-url>`). To make one **first-class** (a curated
quick-add shown in the UI), extend the script under the **ubuntu-install** authoring contract:

1. Edit `scripts/claude.sh` in `~/.local/share/ubuntu-setup/` (a git repo):
   - **Curated MCP server:** add the key to `_CLAUDE_MCP_CURATED_KEYS` and a `case` arm in
     `_claude_mcp_curated` (`transport<TAB>spec<TAB>runtime<TAB>description`). **Verify the package /
     URL is real and current** before committing — these run on strangers' machines.
   - **Curated marketplace:** add `owner/repo` to `_CLAUDE_MKT_CURATED` and a `_claude_mkt_desc` arm.
   - **Curated skill:** add the key to `_CLAUDE_SKILL_CURATED_KEYS` and a `_claude_skill_curated` arm
     (`repo<TAB>subdir<TAB>description`).
   The UI picks new curated entries up automatically (it iterates these lists).
2. **Use lib helpers / the `claude` CLI** — never raw `sudo`, `apt-get`, `apt-key`, or `sudo npm`.
   New parametric op: define `do_<op>` (hyphens→underscores), document it in `usage`, and add a row +
   handler in `ui()` (shelling out via `ui_run`). Parametric ops stay **out of `meta` ops=**; `ui` is
   never an op.
3. **Idempotent & safe:** check existence before add/remove; keep it user-space. Test (`bash -n`,
   `shellcheck -x --source-path=SCRIPTDIR`, `claude.sh status`, `claude.sh ui` on a no-TTY shell must
   print guidance and exit 0), then run for real with confirmation. Commit; consider a PR upstream.

## 5. The interactive screen, and the boundary with bootstrap

`scripts/claude.sh` defines its **own full-screen `ui()`** — a consolidated extension manager with
three sections (MCP servers, Plugins & marketplaces, Skills), each a checklist of curated quick-adds
+ currently configured items + an "add…" row. A human opens it with **`swkit claude`** (no action)
or by drilling into Claude Code from the bootstrap catalog. **Space** toggles the selected item
(add/remove a server, add/remove a marketplace, install/remove a skill, enable/disable a plugin);
**x** uninstalls a selected plugin; "add…" rows prompt for a name/command/URL. Every change shells
out via `ui_run` (visible output + log) and the screen reloads.

`ui` is an **entry mode**, not a `meta` op — never in `ops=`; on a no-TTY shell `claude.sh ui` prints
how to drive it by explicit op and exits 0. **You (the LLM)** drive extensions by explicit action —
`swkit claude mcp-add …`, `swkit claude plugin-install …`, etc. — exactly as in §1; the `ui` screen
is for the human at a terminal. There is no Claude-extension logic duplicated in bootstrap: every
entry point invokes this one script.

## 6. Verify and report

After any change: `swkit claude status`; the configured state (`claude mcp list`, `claude plugin
list`, `ls ~/.claude/skills`); and the follow-ups — **restart Claude Code / open a new session** to
pick up a new server, plugin, or skill; whether a runtime (Node) or a secret (token) is still needed
for a server to actually connect (`claude mcp get <name>` health-checks it).

## Common mistakes

- **Improvising raw `claude mcp`/`claude plugin` commands or hand-editing `~/.claude.json`** instead
  of running or evolving `scripts/claude.sh` — the point is one tested, idempotent, reviewable path.
- **Bulk-enabling MCP servers/plugins** and blowing up the context window — enable what's needed,
  `plugin-disable` the rest.
- **Selecting a Node-based MCP server with no Node installed** → it won't connect. Check first; the
  kit won't install Node for you.
- **Pasting a secret** into a curated definition or committing it — pass tokens via `-e`/`--header`.
- **Trying to `skill-install` a multi-skill repo at its root** (no `SKILL.md` there) — pass the
  `subdir`, or add it as a marketplace.
- **Forgetting to restart the session** — new servers/plugins/skills load at session start.
