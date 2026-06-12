"""The ``deb`` provider — third-party APT repos and direct ``.deb`` installs.

Two mutually exclusive modes, selected by the entry's fields (the schema
enforces exactly one; see ``catalog/schema.json``):

**Repo mode** (``key_url`` + ``repo_url`` + ``suite`` [+ ``components``,
``architectures``, ``pin``, ``name``]) configures a third-party APT repository
the modern way (verified idioms — ``.trellis/spec/core/catalog-and-providers.md``):

- the signing key is downloaded with ``curl``, dearmored iff ASCII-armored
  (``gpg --dearmor``; an already-binary keyring like Brave's is kept as-is),
  and installed **world-readable** to ``/etc/apt/keyrings/<name>.gpg`` (the
  ``_apt`` user must read it or ``apt-get update`` fails);
- the source is a **deb822** ``/etc/apt/sources.list.d/<name>.sources`` with
  ``Signed-By`` — never a one-line ``deb …`` without a scoped key;
- an optional ``pin`` writes ``/etc/apt/preferences.d/<name>`` (the Firefox
  case: the official Mozilla repo needs ``Pin-Priority: 1000`` so Ubuntu's
  snap-transition stub does not shadow the real deb);
- ``suite`` may embed ``{codename}`` (resolved from ``/etc/os-release``,
  ``UBUNTU_CODENAME`` falling back to ``VERSION_CODENAME`` — the Docker/
  HashiCorp pattern); ``components`` is omitted entirely for flat repos
  (kubectl's ``Suites: /``, Sublime's ``Suites: apt/stable/``);
  ``architectures`` defaults to the host's ``dpkg --print-architecture``.

Repo-mode ``check()`` reports PRESENT iff **all** of: the sources file matches
the expected content byte-for-byte, the keyring file exists non-empty, the pin
(when declared) matches, **and** the repo's index has actually been fetched
(its ``InRelease``/``Release`` file exists in ``/var/lib/apt/lists`` under the
exact apt-mangled name — see :meth:`lists_release_paths`). Any drift or gap is
ABSENT — ``install()`` is the convergence op and simply rewrites everything
(spec: "the repo is added iff its files exist with the expected content";
OUTDATED is reserved for version semantics, and would wrongly satisfy an
install). The fetched-lists probe is what makes the freshness guard
self-healing across runs: a repo converged without a subsequent ``apt-get
update`` (e.g. a repo-only run) re-converges next run and is then consumed.

After writing its files, repo-mode ``install()`` marks the per-run
:class:`~.aptcache.AptCache` instead of updating itself — the first package
install that follows runs ``apt-get update`` exactly once per batch of repo
changes (see ``providers/aptcache.py``).

**Direct mode** (``deb_url`` + ``package``) downloads a ``.deb`` and installs
it via ``apt-get install -y <absolute path>`` (resolves dependencies in one
step — never ``dpkg -i`` + ``apt-get -f install``). ``package`` names the
binary package the ``.deb`` provides; ``check()`` is the standard dpkg
``${Status}`` gate shared with the ``apt`` provider.

All external commands go through ``ctx.run``/the injected runner; privileged
file placement uses per-command ``sudo install`` (argv list, no shell, no
``~``). Unprivileged staging happens in a user-owned temp dir. ``root`` is the
test seam for ``check()``'s filesystem observations (and the codename read);
command argv always carry the canonical ``/etc/apt/...`` paths.

This MVP slice implements ``check`` + ``install``; ``remove``/``upgrade`` are
deferred (prd: repo removal is out of scope).
"""

from __future__ import annotations

import tempfile
from pathlib import Path
from typing import Callable, Mapping

from ..errors import CatalogError, ProviderError
from ..models import CatalogEntry
from ..runner import RunResult
from ..runner import run as default_run
from .apt import _INSTALL_TIMEOUT, dpkg_state
from .base import Ctx, State

#: canonical target paths (the argv side — never root-prefixed)
KEYRINGS_DIR = "/etc/apt/keyrings"
SOURCES_DIR = "/etc/apt/sources.list.d"
PREFERENCES_DIR = "/etc/apt/preferences.d"
_LISTS_DIR = "var/lib/apt/lists"
_OS_RELEASE = "etc/os-release"

_ARMOR_HEADER = b"-----BEGIN PGP"

#: apt's QuoteString bad set for list filenames (strutl.cc::URItoFileName) —
#: these are %-quoted; everything else printable-ASCII (incl. ``:``) is literal
_QUOTE_BAD = frozenset('\\|{}[]<>"^~_=!@#$%^&*')


class DebProvider:
    type = "deb"

    def __init__(
        self,
        run: "Callable[..., RunResult] | None" = None,
        *,
        root: "Path | str" = "/",
    ) -> None:
        # the single subprocess boundary, injected for testability
        self._run: Callable[..., RunResult] = run or default_run
        #: read-prefix for check()'s live filesystem observations (test seam)
        self._root = Path(root)

    # -- field access -----------------------------------------------------------
    @staticmethod
    def _name(entry: CatalogEntry) -> str:
        """The file basename under keyrings/sources.list.d/preferences.d
        (defaults to the entry id; the schema restricts it to the charset apt
        accepts — others are silently ignored by apt)."""
        return str(entry.fields.get("name") or entry.id)

    @staticmethod
    def _is_repo_mode(entry: CatalogEntry) -> bool:
        return "deb_url" not in entry.fields

    @staticmethod
    def _required(entry: CatalogEntry, field: str) -> str:
        value = entry.fields.get(field)
        if not value:
            # schema should prevent this; guard anyway
            raise CatalogError(f"deb entry {entry.id!r} is missing required field {field!r}")
        return str(value)

    # -- repo-mode content generation (single source of truth for check+install)
    def _codename(self, entry: CatalogEntry) -> str:
        """The host's Ubuntu codename, from ``/etc/os-release`` (the
        ``${UBUNTU_CODENAME:-$VERSION_CODENAME}`` idiom in Docker's docs)."""
        path = self._root / _OS_RELEASE
        values: "dict[str, str]" = {}
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                if "=" in line:
                    key, _, val = line.partition("=")
                    values[key.strip()] = val.strip().strip('"')
        except OSError as exc:
            raise ProviderError(
                f"cannot read {path} to resolve {{codename}}: {exc}", entry_id=entry.id
            ) from exc
        codename = values.get("UBUNTU_CODENAME") or values.get("VERSION_CODENAME")
        if not codename:
            raise ProviderError(
                f"{path} has neither UBUNTU_CODENAME nor VERSION_CODENAME",
                entry_id=entry.id,
            )
        return codename

    def _suite(self, entry: CatalogEntry) -> str:
        suite = self._required(entry, "suite")
        if "{codename}" in suite:
            suite = suite.replace("{codename}", self._codename(entry))
        return suite

    def _architectures(self, entry: CatalogEntry) -> "tuple[str, ...]":
        archs = entry.fields.get("architectures")
        if archs:
            return tuple(str(a) for a in archs)
        res = self._run(["dpkg", "--print-architecture"])
        if res.returncode != 0 or not res.stdout.strip():
            raise ProviderError(
                f"dpkg --print-architecture failed (exit {res.returncode})",
                entry_id=entry.id,
                stderr_tail=res.stderr[-500:],
            )
        return (res.stdout.strip(),)

    def keyring_path(self, entry: CatalogEntry) -> str:
        return f"{KEYRINGS_DIR}/{self._name(entry)}.gpg"

    def sources_path(self, entry: CatalogEntry) -> str:
        return f"{SOURCES_DIR}/{self._name(entry)}.sources"

    def preferences_path(self, entry: CatalogEntry) -> str:
        return f"{PREFERENCES_DIR}/{self._name(entry)}"

    def sources_content(self, entry: CatalogEntry) -> str:
        """The expected deb822 ``.sources`` body — generated for install and
        compared byte-for-byte by check (one source of truth)."""
        lines = [
            "Types: deb",
            f"URIs: {self._required(entry, 'repo_url')}",
            f"Suites: {self._suite(entry)}",
        ]
        components = entry.fields.get("components")
        if components:  # omitted entirely for flat repos (Suites: /)
            lines.append("Components: " + " ".join(str(c) for c in components))
        lines.append("Architectures: " + " ".join(self._architectures(entry)))
        lines.append(f"Signed-By: {self.keyring_path(entry)}")
        return "\n".join(lines) + "\n"

    def pin_content(self, entry: CatalogEntry) -> "str | None":
        pin = entry.fields.get("pin")
        if not pin:
            return None
        if not isinstance(pin, Mapping):
            raise CatalogError(f"deb entry {entry.id!r}: 'pin' must be a mapping")
        return (
            f"Package: {pin['package']}\n"
            f"Pin: {pin['pin']}\n"
            f"Pin-Priority: {pin['priority']}\n"
        )

    # -- the fetched-lists probe --------------------------------------------------
    @staticmethod
    def _mangle_uri(uri: str) -> str:
        """apt's ``URItoFileName`` (apt-pkg/contrib/strutl.cc, verified): scheme
        stripped, the QuoteString bad set and non-printables %-quoted lowercase
        **per byte** (note ``_`` itself becomes ``%5f``), then ``/`` -> ``_``."""
        out = []
        for byte in uri.split("://", 1)[-1].encode("utf-8"):
            ch = chr(byte)
            if ch == "/":
                out.append("_")
            elif ch in _QUOTE_BAD or byte <= 0x20 or byte >= 0x7F:
                out.append(f"%{byte:02x}")
            else:
                out.append(ch)
        return "".join(out)

    def lists_release_paths(self, entry: CatalogEntry) -> "tuple[str, ...]":
        """The canonical ``/var/lib/apt/lists`` filenames whose existence proves
        this repo's index was fetched: apt stores the release file under the
        exact mangled URI (``InRelease``, or ``Release`` when the server has no
        inline-signed variant). Exact names, never a prefix glob — a prefix
        would false-match a sibling repo whose URI merely extends this one
        (``…/apt`` vs ``…/apt/sub``) and wrongly read PRESENT."""
        base = self._required(entry, "repo_url").rstrip("/")
        suite = self._suite(entry)
        if suite == "/":  # flat repo at the root (the kubectl `Suites: /` case)
            release_base = base
        elif suite.endswith("/"):  # flat repo at a path (Sublime `apt/stable/`)
            release_base = f"{base}/{suite.rstrip('/')}"
        else:  # dists-style
            release_base = f"{base}/dists/{suite}"
        return tuple(
            f"/{_LISTS_DIR}/{self._mangle_uri(f'{release_base}/{kind}')}"
            for kind in ("InRelease", "Release")
        )

    def _lists_fetched(self, entry: CatalogEntry) -> bool:
        """``True`` iff ``apt-get update`` has ever fetched this repo's index."""
        return any(
            (self._root / canonical.lstrip("/")).is_file()
            for canonical in self.lists_release_paths(entry)
        )

    # -- filesystem observation helpers (root-prefixed reads) ----------------------
    def _read(self, canonical_path: str) -> "str | None":
        path = self._root / canonical_path.lstrip("/")
        try:
            return path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return None

    def _key_present(self, entry: CatalogEntry) -> bool:
        path = self._root / self.keyring_path(entry).lstrip("/")
        try:
            return path.stat().st_size > 0
        except OSError:
            return False

    # -- protocol -------------------------------------------------------------
    def check(self, entry: CatalogEntry) -> State:
        if not self._is_repo_mode(entry):
            return dpkg_state(self._run, self._required(entry, "package"),
                              entry_id=entry.id)

        # repo mode: PRESENT iff every artifact matches AND the index was
        # fetched; any drift/gap is ABSENT (install is the convergence op)
        if self._read(self.sources_path(entry)) != self.sources_content(entry):
            return State.ABSENT
        if not self._key_present(entry):
            return State.ABSENT
        expected_pin = self.pin_content(entry)
        if expected_pin is not None and self._read(self.preferences_path(entry)) != expected_pin:
            return State.ABSENT
        if not self._lists_fetched(entry):
            return State.ABSENT
        return State.PRESENT

    def install(self, entry: CatalogEntry, ctx: Ctx) -> None:
        if ctx.check_mode:
            return  # dry-run mutation guard: make ZERO changes
        if self._is_repo_mode(entry):
            self._install_repo(entry, ctx)
        else:
            self._install_direct(entry, ctx)

    # -- repo mode ------------------------------------------------------------
    def _install_repo(self, entry: CatalogEntry, ctx: Ctx) -> None:
        name = self._name(entry)
        # the operator keyring dir (apt 2.4+/22.04+ convention) — idempotent
        self._must(
            ctx.run(["install", "-m", "0755", "-d", KEYRINGS_DIR], sudo=True),
            entry, f"create {KEYRINGS_DIR}",
        )
        with tempfile.TemporaryDirectory(prefix="ubuntu-setup-deb-") as tmp:
            staging = Path(tmp)
            downloaded = staging / f"{name}.key"
            self._must(
                ctx.run(["curl", "-fsSL", "-o", str(downloaded),
                         self._required(entry, "key_url")]),
                entry, "download signing key",
            )
            key_src = downloaded
            if self._is_armored(downloaded):
                key_src = staging / f"{name}.gpg"
                self._must(
                    ctx.run(["gpg", "--batch", "--yes", "--dearmor",
                             "-o", str(key_src), str(downloaded)]),
                    entry, "dearmor signing key",
                )
            # world-readable (the _apt user must read it) — `install` sets the
            # mode atomically; no separate chmod step needed
            self._must(
                ctx.run(["install", "-m", "0644", str(key_src),
                         self.keyring_path(entry)], sudo=True),
                entry, "install signing key",
            )
            sources_tmp = staging / f"{name}.sources"
            sources_tmp.write_text(self.sources_content(entry), encoding="utf-8")
            self._must(
                ctx.run(["install", "-m", "0644", str(sources_tmp),
                         self.sources_path(entry)], sudo=True),
                entry, "install deb822 sources",
            )
            pin = self.pin_content(entry)
            if pin is not None:
                pin_tmp = staging / f"{name}.pref"
                pin_tmp.write_text(pin, encoding="utf-8")
                self._must(
                    ctx.run(["install", "-m", "0644", str(pin_tmp),
                             self.preferences_path(entry)], sudo=True),
                    entry, "install apt pin",
                )
        # never update here: the first package install consuming this repo
        # runs `apt-get update` once per batch of repo changes
        ctx.aptcache.mark_repo_changed()

    # -- direct mode ----------------------------------------------------------
    def _install_direct(self, entry: CatalogEntry, ctx: Ctx) -> None:
        name = self._name(entry)
        with tempfile.TemporaryDirectory(prefix="ubuntu-setup-deb-") as tmp:
            deb_path = Path(tmp) / f"{name}.deb"
            # vendor .debs are 100-200MB (chrome/discord/obsidian class): the
            # download shares the widened install timeout — the runner's 600s
            # default provably kills it on slow links (entries-deb full run,
            # 2026-06-12: obsidian's GitHub download died at exit 124)
            self._must(
                ctx.run(["curl", "-fsSL", "-o", str(deb_path),
                         self._required(entry, "deb_url")],
                        timeout=_INSTALL_TIMEOUT),
                entry, "download .deb",
            )
            # consume any pending repo change first (the .deb's dependencies
            # may resolve from a repo entry converged earlier this run)
            ctx.aptcache.ensure_fresh(ctx.run, entry_id=entry.id)
            # absolute path => apt treats it as a local file (resolving its
            # dependencies in one step), never as a repo package name
            self._must(
                ctx.run(
                    [
                        "apt-get", "install", "-y", "--no-install-recommends",
                        "-o", "Dpkg::Options::=--force-confdef",
                        "-o", "Dpkg::Options::=--force-confold",
                        str(deb_path),
                    ],
                    sudo=True,
                    timeout=_INSTALL_TIMEOUT,
                ),
                entry, f"apt-get install {self._required(entry, 'package')}",
            )

    # -- shared helpers ---------------------------------------------------------
    @staticmethod
    def _is_armored(path: Path) -> bool:
        """ASCII-armored key? (A missing file — only possible under a test fake
        that doesn't create it — counts as binary: the next real command's exit
        code surfaces any genuine download failure.)"""
        try:
            with path.open("rb") as fh:
                return fh.read(len(_ARMOR_HEADER)) == _ARMOR_HEADER
        except OSError:
            return False

    @staticmethod
    def _must(res: RunResult, entry: CatalogEntry, step: str) -> None:
        if res.returncode != 0:
            raise ProviderError(
                f"{step} failed (exit {res.returncode})",
                entry_id=entry.id,
                stderr_tail=res.stderr[-500:],
            )

    def remove(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("deb remove is deferred (repo removal is out of scope)")

    def upgrade(self, entry: CatalogEntry, ctx: Ctx) -> None:
        raise NotImplementedError("deb upgrade is deferred in this MVP slice")
