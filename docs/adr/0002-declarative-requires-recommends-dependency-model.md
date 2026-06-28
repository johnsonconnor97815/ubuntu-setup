# Declarative requires/recommends dependency model

Status: accepted

Cross-script prerequisites were hand-coded as one-off gates (android.sh's
`_android_java_gate` calling java.sh). We are generalizing this into a declarative,
two-tier model expressed in each script's existing `meta`, resolved by a small lib helper.

- **Two tiers**, mirroring apt: `requires=` (hard — target cannot function, maps to
  *Depends*) and `recommends=` (soft — enables a feature, maps to *Recommends*). Version
  constraints live on the edge: `requires="java>=17"`, `recommends="node"`.
- **Resolver in lib**: gather the install set's `requires` edges, `tsort` (coreutils) for
  install order + cycle detection, gate each target on its dependency's `status`.
- **Honesty-preserving resolution policy** (the load-bearing choice). Unmet **hard
  requires**: fail-fast + clear pointer on the headless/CLI path (never silently pull a
  sudo-requiring or runtime-heavy dependency); an inline install offer in the TUI
  (`ui_run -- swkit <dep> install`, sudo visible); `--with-requires` to install the chain
  on explicit opt-in. **Soft recommends** are *never* auto-installed — only pointed at.
  This generalizes android→java's current behavior rather than adopting apt's
  auto-install-Depends aggression, preserving the kit's "先计划后执行 + 绝不偷装" contract.
- **Not modeled**: user-space no-sudo helpers a script provisions inline (fonts/MesloLGS NF)
  stay an implementation detail of `configure`, not a declared edge (see "Auto-provisioned
  helper" in CONTEXT.md). And android-studio declares **no** dependency on android/java — it
  bundles its own JetBrains Runtime and manages its own SDK; the model must not naively link
  them by name.
- **Scope limit**: the declarative edge gates *installation*; run-time resolution that needs
  more than "is it installed" (android picking a ≥17 `JAVA_HOME` per sdkmanager spawn even
  when the system default is older) stays in the consuming script.

Considered and rejected: (a) apt-style auto-install of hard requires by default — too
aggressive for a tool that runs sudo on strangers' machines; (b) a third "auto-provides"
tier for fonts — promotes an implementation detail to a public dependency for little gain.
