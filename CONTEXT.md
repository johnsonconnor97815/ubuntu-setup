# Ubuntu Setup Kit — Context

The project glossary. This kit turns a freshly-installed Ubuntu machine (Server / SSH /
headless) into a managed dev machine through a collection of per-software bash scripts.
Only terms that carry design weight live here; general programming concepts are excluded
on purpose.

## Language

### Runtimes

**System-default runtime**:
A runtime (go/python/java/node) installed system-wide through the conservative channel
(apt / uv / openjdk) and registered as the machine's default, so that `/usr/bin/*`,
systemd services, cron, absolute-path shebangs, Gradle/sdkmanager, and other scripts all
resolve it. This is the kit's runtime model — and the reason it hand-writes the runtime
scripts instead of delegating to a version manager (see ADR-0001).
_Avoid_: global version, default version (both hide the visibility question)

**Activation-gated runtime**:
A runtime version that resolves only inside an interactive shell which has activated a
version manager (e.g. mise) and/or entered the project directory; invisible to
non-interactive shells, services, and cron. The model the kit deliberately rejects for its
system layer.
_Avoid_: shell-local version, per-project version (the latter names the *feature*, not the
visibility limitation)

### Scripts

**Config-manager script**:
A kit script whose bulk is *configuration* management (nvim, tmux, zsh, rime, ghostty,
claude, android), driving a canonical upstream (lazy.nvim, TPM, oh-my-zsh, fcitx5, …)
rather than reimplementing it. These are correct wheel-reuse, not reinvention; telling them
apart from the thin *installers* is what correctly scopes any "reinventing the wheel"
question.
_Avoid_: wrapper (undersells the managed-config layer they add on top)

### Dependencies

The model is declared in each script's `meta` and resolved by a small lib resolver
(`tsort` for ordering + cycle detection). See ADR-0002.

**Hard requires**:
A declared cross-script prerequisite (`meta` `requires="java>=17"`) the target cannot
function without; the version constraint lives on the edge. When unmet: fail-fast + pointer
on the headless/CLI path, an inline install offer in the TUI, or `--with-requires` to
install the whole chain in topological order. Maps to apt's *Depends*. Note it gates
*install*, not run time — android still picks its own `JAVA_HOME` per sdkmanager spawn.
_Avoid_: dependency (too generic — say which tier)

**Soft recommends**:
A declared cross-script dependency (`meta` `recommends="node"`) that unlocks a feature but
is not required; **never auto-installed**, only pointed at (`swkit node install`). Maps to
apt's *Recommends*. The kit's existing "Mason needs Node → point, never pull" behavior, now
formalized.
_Avoid_: optional dependency

**Auto-provisioned helper**:
A user-space, no-sudo resource a script installs inline as part of its own `configure`
(zsh/ghostty/nvim/tmux installing MesloLGS NF via fonts.sh). Deliberately **not** modeled as
a dependency — it needs no user consent and is an implementation detail, not a prerequisite
the user picks.
_Avoid_: dependency, requirement (it is neither, by design)

### Categorization

See ADR-0003.

**Primary category**:
The single end-user-facing bucket a script declares in `meta` `category=` (装机必备 /
语言与运行时 / 编辑器与 IDE / 终端与工具 / AI 工具 / 应用). Drives the TUI's grouping. Labels
are localized; software names are not.
_Avoid_: section, group

**Facet tag**:
An orthogonal, machine-readable trait in `meta` `tags=`, independent of the primary
category. The behavior-driving tag is `desktop-only` (the TUI greys + badges these on SSH
rather than hiding them); `gui`/`cli` are descriptive. Lets a tool be grouped by category
yet filtered by the GUI/SSH axis without re-bucketing.
_Avoid_: label, flag
