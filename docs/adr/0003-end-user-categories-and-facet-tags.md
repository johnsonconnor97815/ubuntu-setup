# End-user category taxonomy with orthogonal facet tags

Status: accepted

The kit's `meta` categories were developer-jargon (`essentials | common | ai | runtime`)
and `common` had become an 11-script junk drawer mixing editors, terminal, IME, container,
fonts, and GUI apps. We restructure the discovery axis:

- **Six end-user-facing primary categories**: 装机必备 / 语言与运行时 / 编辑器与 IDE /
  终端与工具 / AI 工具 / 应用. Each holds 3–5 scripts; no junk drawer. Labels are localized
  (en/zh/ja, like the existing `cat_*` UI messages); software names are never translated.
- **Orthogonal facet tags** in `meta` (`tags=`): the behavior-driving one is `desktop-only`
  (drives the TUI's SSH treatment); `gui`/`cli` are descriptive. A script carries one
  primary `category` plus zero or more `tags` — the app-store "one primary category + facet
  filters" pattern, which lets the same tool be discovered by category yet filtered by the
  GUI/SSH axis without re-bucketing.
- **SSH treatment = disclose, not hide**: on SSH/headless the TUI greys out `desktop-only`
  scripts and badges them ("桌面专用 · SSH 下仅对有显示器的机器生效") but still lets the user
  install them (they are installable over SSH and take effect back at the desktop). This
  extends the kit's existing per-script SSH honesty prose into a uniform, machine-readable
  signal.

Considered and rejected: (a) coarse 2–3 buckets ("常用 / 编程 / AI") — recreates the
junk drawer, 15 scripts land in "编程"; (b) single-axis re-bucketing with no tags — cannot
express the GUI/SSH dimension the kit's headless-honesty contract needs, leaving desktop-only
disclosure stuck in per-script prose the TUI can't act on.
