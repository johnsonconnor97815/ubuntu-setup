# Keep system-default runtime scripts; do not adopt mise

Status: accepted

The kit hand-writes go/python/java/node install + version management instead of delegating
to a polyglot version manager (mise / asdf). We evaluated replacing the runtime layer with
mise and rejected it.

The kit's purpose is to provision a fresh, often headless/SSH machine with
**system-default** runtimes — visible to `/usr/bin`, services, cron, Gradle/sdkmanager, and
absolute-path shebangs — under a zero-prerequisite, apt-first trust contract. mise installs
**activation-gated** runtimes in the user's home that resolve only in interactive shells;
it introduces a new vendor trust root and a per-`cd` code-execution surface, and it weakens
"default version" semantics (PATH/`JAVA_HOME` via shell activation instead of
`update-alternatives`). mise's one unique value — per-project version auto-switching — is
not a need for this kit's "just install working runtimes" use case.

mise may still be offered later as an *optional* extra script for users who genuinely want
per-project switching, but it is additive, never a replacement for the runtime layer's
system-integration role.

Considered options: (1) replace go/python/java/node version logic with mise — rejected;
(2) replace all four but re-register `update-alternatives` at mise's home-dir java — rejected
as fragile (a system-level alternative pointing into one user's `~/.local/share/mise`);
(3) keep the scripts, optionally add `mise.sh` — accepted shape.
