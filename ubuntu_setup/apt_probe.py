"""Isolated system-Python helper. Read APT state; never commit package changes.

Online mode downloads to a parent-owned temporary directory. A fresh, allowlisted
APT configuration prevents host update hooks, cache writes and trust overrides.
Only structured results leave this process; APT messages/URLs can contain secrets.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import urlsplit


UNSAFE_OPTIONS = {"trusted", "allow-insecure", "allow-weak", "allow-downgrade-to-insecure",
                  "check-valid-until", "check-date"}


def source_overrides(paths):
    """Conservatively detect bypasses in active one-line and deb822 entries."""
    issues = []
    for path in paths:
        text = path.read_text(encoding="utf-8")
        if len(text) > 4 * 1024 * 1024:
            raise ValueError("source size")
        if path.suffix == ".sources":
            blocks = re.split(r"\n\s*\n", text)
            for block in blocks:
                fields = {}
                for line in block.splitlines():
                    if line.startswith((" ", "\t")) or line.lstrip().startswith("#") or ":" not in line:
                        continue
                    key, value = line.split(":", 1)
                    fields[key.lower()] = value.strip().lower()
                if fields.get("enabled") in {"no", "false", "0", "off"}:
                    continue
                for key in UNSAFE_OPTIONS:
                    value = fields.get(key)
                    if value is not None and value in ({"no", "false", "0", "off"} if key.startswith("check-") else {"yes", "true", "1", "on"}):
                        issues.append({"file": str(path), "option": key})
        else:
            for line in text.splitlines():
                if not re.match(r"^\s*deb(?:-src)?\s", line):
                    continue
                match = re.search(r"\[([^]]*)\]", line)
                if not match:
                    continue
                for key, value in re.findall(r"([\w-]+)\s*=\s*([^\s]+)", match[1].lower()):
                    if key in UNSAFE_OPTIONS and value in ({"no", "false", "0", "off"} if key.startswith("check-") else {"yes", "true", "1", "on"}):
                        issues.append({"file": str(path), "option": key})
    return issues


def quote_config(value):
    if any(c in value for c in "\x00\n\r"):
        raise ValueError("invalid config value")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def isolated_config(config, root):
    """Preserve source/key/pin/architecture selection; exclude executable hooks."""
    values = {
        "Dir::Etc::parts": "-", "Dir::Etc::main": "-",
        "Dir::State": str(root / "state"), "Dir::State::lists": str(root / "lists"),
        "Dir::State::status": config.find_file("Dir::State::status"),
        "Dir::Cache": str(root / "cache"), "Dir::Cache::pkgcache": "", "Dir::Cache::srcpkgcache": "",
        "Dir::Log": str(root / "log"), "APT::Get::List-Cleanup": "false",
        "APT::Get::AllowUnauthenticated": "false", "Acquire::AllowInsecureRepositories": "false",
        "Acquire::AllowDowngradeToInsecureRepositories": "false", "Acquire::AllowWeakRepositories": "false",
        "Acquire::Check-Valid-Until": "true", "Acquire::Check-Date": "true",
        "Acquire::https::Verify-Peer": "true", "Acquire::https::Verify-Host": "true",
        "Acquire::Retries": "0", "Acquire::http::Timeout": "10", "Acquire::https::Timeout": "10",
        "Acquire::Languages": "none", "APT::Sandbox::User": "", "Debug::NoLocking": "true",
    }
    for key in ("sourcelist", "sourceparts", "trusted", "trustedparts", "preferences", "preferencesparts", "netrc", "netrcparts"):
        values["Dir::Etc::" + key] = config.find_file("Dir::Etc::" + key)
    for key in ("APT::Architecture", "APT::Default-Release", "APT::Install-Recommends", "APT::Install-Suggests"):
        value = config.find(key)
        if value:
            values[key] = value
    # Explicit proxies are data. Proxy auto-detect commands and custom methods
    # are deliberately not inherited. Do not serialize these values to records.
    for key in config.keys():
        if re.fullmatch(r"Acquire::(?:http|https)::Proxy(?:::[^:]+)?", key, re.I):
            value = config.find(key)
            if value:
                values[key] = value
    lines = [key + " " + quote_config(value) + ";" for key, value in values.items()]
    architectures = config.value_list("APT::Architectures")
    lines.append("APT::Architectures { " + " ".join(quote_config(a) + ";" for a in architectures) + " };")
    return "\n".join(lines) + "\n"


def refresh_failure(text):
    # Return categories, never raw stderr, repository URLs or authentication data.
    lower = text.lower()
    if any(word in lower for word in ("no_pubkey", "badsig", "expkeysig", "not signed", "signatures couldn't", "signature verification")):
        return "signature"
    if "expired" in lower or "not valid yet" in lower:
        return "date"
    if "404" in lower or "does not have a release file" in lower:
        return "source_unavailable"
    if "resolve" in lower or "connect" in lower or "timed out" in lower or "certificate" in lower:
        return "network"
    return "refresh_failed"


def index_targets(config):
    """Let APT select real Release targets (not optional binary-all/translation
    placeholders). Read-only indextargets runs with hooks excluded. The config is
    an anonymous file descriptor, so timeout cannot leave proxy credentials on disk.
    """
    text = isolated_config(config, Path("/nonexistent/ubuntu-setup-index-query"))
    text += "Dir::State::lists " + quote_config(config.find_dir("Dir::State::lists")) + ";\n"
    fd = os.memfd_create("ubuntu-setup-apt-config", os.MFD_CLOEXEC)
    try:
        os.write(fd, text.encode())
        env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "APT_CONFIG": f"/proc/self/fd/{fd}"}
        result = subprocess.run(("/usr/bin/apt-get", "indextargets"), env=env, pass_fds=(fd,),
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
    finally:
        os.close(fd)
    if result.returncode or len(result.stdout) > 16 * 1024 * 1024:
        raise ValueError("index targets unavailable")
    targets = []
    for block in re.split(r"\n\s*\n", result.stdout.decode("utf-8").strip()):
        if not block:
            continue
        fields = {}
        for line in block.splitlines():
            key, sep, value = line.partition(":")
            if not sep or key in fields:
                raise ValueError("index target format")
            fields[key] = value.strip()
        if fields.get("Identifier") == "Packages":
            if not fields.get("Filename") or not fields.get("Repo-URI"):
                raise ValueError("index target missing fields")
            targets.append(fields)
    return targets


def refresh(config, root):
    for name in ("state", "lists/partial", "cache/archives/partial", "log"):
        (root / name).mkdir(parents=True, mode=0o700, exist_ok=True)
    path = root / "apt.conf"
    path.write_text(isolated_config(config, root), encoding="utf-8")
    path.chmod(0o600)
    env = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL": "C", "APT_CONFIG": str(path)}
    result = subprocess.run(("/usr/bin/apt-get", "update", "--error-on=any"), env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if result.returncode:
        return "failed", refresh_failure(result.stderr.decode("utf-8", "replace"))
    return "verified", ""


def analyze(apt, *, online_root=None):
    apt.init_config()
    config = apt.config
    config.set("Dir::Cache::pkgcache", "")
    config.set("Dir::Cache::srcpkgcache", "")
    apt.init_system()
    source_file = Path(config.find_file("Dir::Etc::sourcelist"))
    parts = Path(config.find_dir("Dir::Etc::sourceparts"))
    paths = ([source_file] if source_file.is_file() else []) + sorted(
        p for p in (parts.iterdir() if parts.is_dir() else []) if re.fullmatch(r"[A-Za-z0-9_.-]+\.(?:list|sources)", p.name))
    overrides = source_overrides(paths)
    # Settings that could relax trust are reported even in cache-only mode.
    for key, unsafe in (("APT::Get::AllowUnauthenticated", True), ("Acquire::AllowInsecureRepositories", True),
                        ("Acquire::AllowWeakRepositories", True), ("Acquire::AllowDowngradeToInsecureRepositories", True),
                        ("Acquire::Check-Date", False), ("Acquire::Check-Valid-Until", False)):
        if config.find_b(key, not unsafe) == unsafe:
            overrides.append({"file": "APT configuration", "option": key})
    refresh_status, refresh_error = "not_requested", ""
    if online_root is not None:
        if overrides:
            refresh_status, refresh_error = "blocked", "unsafe_source_options"
        else:
            refresh_status, refresh_error = refresh(config, online_root)
        if refresh_status == "verified":
            config.set("Dir::State::lists", str(online_root / "lists"))
    sources = apt.SourceList()
    sources.read_main_list()
    targets = index_targets(config)
    source_records = []
    for source in sources.list:
        indexes = [i for i in targets if i["Repo-URI"].rstrip("/") == source.uri.rstrip("/")
                   and (i.get("Release") or "/") == source.dist]
        source_records.append({"id": hashlib.sha256((source.uri + " " + source.dist).encode()).hexdigest()[:16],
                               "host": urlsplit(source.uri).hostname or "local",
                               "suite": source.dist, "apt_trusted": source.is_trusted,
                               "package_indexes": len(indexes), "missing_indexes": sum(not Path(i["Filename"]).is_file() for i in indexes)})
    cache = apt.Cache(None)
    depcache = apt.DepCache(cache)
    depcache.read_pinfile()
    installed = [p for p in cache.packages if p.current_ver is not None]
    broken = sorted(p.get_fullname(pretty=True) for p in installed if depcache.is_inst_broken(p))
    held = sorted(p.get_fullname(pretty=True) for p in installed if p.selected_state == apt.SELSTATE_HOLD)
    candidates = []
    for pkg in installed:
        candidate = depcache.get_candidate_ver(pkg)
        if candidate is not None and apt.version_compare(candidate.ver_str, pkg.current_ver.ver_str) > 0:
            origins = sorted({f.archive for f, _ in candidate.file_list if f.archive})
            trusted = any((index := sources.find_index(f)) is not None and index.is_trusted
                          for f, _ in candidate.file_list)
            candidates.append({"package": pkg.get_fullname(pretty=True), "installed": pkg.current_ver.ver_str,
                               "candidate": candidate.ver_str, "origins": origins, "apt_trusted": trusted,
                               "held": pkg.selected_state == apt.SELSTATE_HOLD})
    resolved = False
    try:
        resolved = depcache.upgrade(True)
    except SystemError:
        pass  # A resolver failure is an assessment result, not an empty plan.
    actions = []
    for pkg in cache.packages:
        action = ("remove" if depcache.marked_delete(pkg) else "downgrade" if depcache.marked_downgrade(pkg)
                  else "upgrade" if depcache.marked_upgrade(pkg) else "install" if depcache.marked_install(pkg) else None)
        if action:
            candidate = depcache.get_candidate_ver(pkg)
            actions.append({"package": pkg.get_fullname(pretty=True), "action": action,
                            "from": pkg.current_ver.ver_str if pkg.current_ver else None,
                            "to": candidate.ver_str if candidate and action != "remove" else None})
    actions.sort(key=lambda a: (a["action"], a["package"]))
    held_changed = sorted({a["package"] for a in actions} & set(held))
    changed_packages = {a["package"] for a in actions}
    kept_back = sorted(c["package"] for c in candidates if c["package"] not in changed_packages)
    metadata_complete = bool(targets) and all(Path(t["Filename"]).is_file() for t in targets)
    metadata_mode = "online" if refresh_status == "verified" else "cache"
    return {
        "packages": {"backend": "python-apt " + apt.VERSION, "installed_count": len(installed), "broken": broken,
                     "held": held, "held_changed": held_changed, "simulation_resolved": bool(resolved and depcache.broken_count == 0),
                     "simulation_broken_count": depcache.broken_count, "actions": actions,
                     "kept_back": kept_back,
                     "metadata_mode": metadata_mode, "metadata_complete": metadata_complete},
        "updates": {"mode": "online" if online_root else "cache", "refresh_status": refresh_status,
                    "refresh_error": refresh_error, "sources": source_records, "unsafe_options": overrides,
                    "candidates": sorted(candidates, key=lambda c: c["package"]), "metadata_complete": metadata_complete},
    }


def main():
    try:
        import apt_pkg
        result = analyze(apt_pkg, online_root=Path(sys.argv[1]) if len(sys.argv) == 2 else None)
    except ImportError:
        result = {"error": "python_apt_missing"}
    except Exception as exc:
        result = {"error": "apt_read_failed", "error_type": type(exc).__name__}
    print(json.dumps(result, ensure_ascii=False, allow_nan=False))


if __name__ == "__main__":
    main()
