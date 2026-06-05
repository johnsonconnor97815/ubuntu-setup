# Privilege & Safety

> How the tool acquires root, why it must not run as root, and the rules that keep an open-source `sudo`-running tool trustworthy on a stranger's machine. Owns `core/privilege.py` and the safety rules every provider obeys.

---

## Status: design-derived, not yet code-backed

Prescriptive, and the highest-stakes spec in the set: the target users are strangers running an open-source tool that executes `sudo` (`design-direction.md`). The idioms below are verified against sudo 1.9.18, sudoers(5), the Python 3 subprocess docs, and the freedesktop polkit reference. Treat every rule here as a hard constraint, not a suggestion.

---

## Rule 1 — Never run the whole app as root

The app runs as the **normal user** and escalates **individual privileged steps** via `sudo`. Running the entire CLI/TUI under `sudo` is the core anti-pattern:

- Every file the app writes (config, caches, logs, downloaded artifacts, **the user's dotfiles**) becomes `root`-owned, so the next non-root run fails with `Permission denied` and the user's home is polluted with `root:root` files they can't easily fix.
- Under `sudo`, `$HOME` is unreliable (may be `/root`), so "write `~/.bashrc`" can silently land in `/root/.bashrc`.
- A bug — or, later, model-influenced logic — runs with full root authority.

If the app nonetheless finds itself running as root (someone ran it with `sudo` anyway), it must recover the real user and drop privileges for user-side work (Rule 3).

---

## Rule 2 — Acquire `sudo` up front, keep it alive, probe before each step

In a TUI a hidden password prompt corrupts the screen or appears to hang, because the TUI owns the terminal. So:

1. **Validate up front, while the screen is in a known state:** `sudo -v` (prompts once; caches the credential — sudoers default TTL is **5 minutes**, per-terminal, *not* 15). If the user is not a sudoer this fails early and cleanly.
2. **Keep-alive during long runs** with a daemon thread that refreshes under the TTL and dies with the app:

   ```python
   # core/privilege.py
   def _keepalive(stop: threading.Event) -> None:
       while not stop.wait(50):                       # < the 5-min TTL
           subprocess.run(["sudo", "-n", "true"],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
   subprocess.run(["sudo", "-v"], check=True)         # interactive, up front
   threading.Thread(target=_keepalive, args=(stop,), daemon=True).start()
   ```

   Lifecycle: set the `stop` `Event` in a `finally`/`atexit` (and on `UserAbort`) so the loop exits cleanly; `daemon=True` guarantees the thread also dies with the process if cleanup is skipped, so a Ctrl-C landing during `stop.wait(50)` never hangs shutdown.
3. **Probe before each privileged step** with `sudo -n true` (non-interactive). Exit 0 ⇒ it will run silently; non-zero ⇒ re-prompt deliberately (`sudo -v`) or fail with a clear message — never let a password prompt surprise the UI.
4. To **read** cached state for a status display without resetting the 5-minute timer, use `sudo -Nnv`. Caveat: `-N` was added in sudo 1.9.12 — present on 24.04 (ships ≥ 1.9.13) but **not** on a stock 22.04 (ships 1.9.9). Detect support once (`sudo -h 2>&1 | grep -q -- -N`) and otherwise fall back to the plain `sudo -n true` probe. (Plain `sudo -nv` would silently re-extend the 5-minute timer, which is why `-Nnv` is preferred where available.)

`DEBIAN_FRONTEND=noninteractive` must be set in the **escalated** command's environment (`sudo DEBIAN_FRONTEND=noninteractive apt-get …`), not just the parent — `sudo`'s `env_reset` strips it otherwise. The runner handles this; see [error-and-logging.md](./error-and-logging.md).

---

## Rule 3 — When euid is 0, find the real user from `SUDO_USER` (never `~`/`$HOME`)

`getpass.getuser()`, `$USER`, and `$LOGNAME` all return `root` under sudo. Only `SUDO_USER`/`SUDO_UID`/`SUDO_GID` identify the real invoker, and the real home must come from the passwd DB, not `$HOME`:

```python
# core/privilege.py
def real_user() -> tuple[str, int, int]:
    if os.geteuid() == 0 and os.environ.get("SUDO_USER"):
        name = os.environ["SUDO_USER"]
        return name, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"])
    pw = pwd.getpwuid(os.getuid())
    return pw.pw_name, pw.pw_uid, pw.pw_gid

def real_home(name: str) -> str:
    return pwd.getpwnam(name).pw_dir          # authoritative; NOT os.path.expanduser("~")
```

Any provider that touches a user-owned path (`dotfile-block`, user `service`s, caches) resolves the path via `real_home()`. To run a child as the real user from a root context, drop privileges explicitly:

```python
subprocess.run(argv, user=uid, group=gid,
               extra_groups=(),               # REQUIRED — else root's supplementary groups leak
               env={**os.environ, "HOME": user_home, "USER": name})
```

If irrevocably dropping root in-process, order is `setgroups([]) → setgid → setuid` (uid last; it's one-way). `os.seteuid` alone does **not** drop privileges (real/saved uid stay root).

---

## Rule 4 — Touch only your own config; back up first

For `dotfile-block` and any edit to a user-authored file:

- Write a **marked managed block** (`# >>> ubuntu-setup managed: <marker> >>>` … `# <<< … <<<`) and splice only the text between *your* markers. Never rewrite the user's surrounding lines. The distinct begin/end markers (Ansible `blockinfile` `{mark}` convention) make re-runs replace, not append.
- **Back up before writing:** `cp -a <file> <file>.ubuntu-setup.<ISO-timestamp>.bak`. This backup is the only real undo the tool has (see *No rollback* in [idempotency-and-execution.md](./idempotency-and-execution.md)).
- Assume the machine is **not** pristine: an open-source user runs this over an existing `~/.bashrc`. Default to "assume fresh but fail safe" — never clobber unmanaged content.

---

## Rule 5 — Be transparent and auditable

Trust for an open-source `sudo` tool comes from the user being able to see exactly what runs:

- **Plan/preview by default** before applying (see [idempotency-and-execution.md](./idempotency-and-execution.md)).
- **The declarative catalog is readable** — a user can inspect what an entry will do; the dangerous `script` type is the rare, clearly-marked exception and requires human review.
- **Log every escalated command** (exact argv) so a run can be audited after the fact — see [error-and-logging.md](./error-and-logging.md).
- **Mark provenance:** entries carry `source: official | community | ai-generated`; AI-generated entries are never silently mixed into the trusted set, and the LLM phase may never emit `script` entries.
- **Do not ship a `curl | bash` self-installer.** A provisioning tool installed by an unreviewable pipe is self-defeating; distribute as a `pyproject.toml` package (pip/pipx) or a signed `.deb`.

---

## `sudo` vs `polkit`/`pkexec`

For a terminal app, **`sudo` (with `-n` probing + keep-alive) is the right default.** `pkexec` is a poor fit for ad-hoc "run this as root": it strips the environment (drops `DISPLAY`/`HOME`/`XAUTHORITY`), needs an auth agent (only a TTY text agent without a desktop), and upstream marks direct exec as legacy-only. Reach for polkit only if a proper privileged D-Bus mechanism is ever introduced.

---

## Anti-patterns (forbidden)

- Launching the whole app via `sudo` / requiring root for the process.
- Writing user files as root, or resolving user paths via `~`/`$HOME`/`expanduser` under sudo.
- `subprocess.run(user=…)` without `extra_groups=()` (root group leak).
- A password prompt that can fire mid-TUI without a prior `sudo -n` probe.
- `eval echo ~$SUDO_USER` (runs as root with an attacker-influenced username) — use `pwd.getpwnam` / `getent passwd "$SUDO_USER"`.
- Appending to `~/.bashrc` without markers + backup; clobbering unmanaged config.
- Trusting `SUDO_USER` for a security decision when sudoers grants `ALL`/`setenv` (it can be spoofed) — fine for attribution, not for authorization.
