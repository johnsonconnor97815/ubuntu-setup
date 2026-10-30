"""Register the isolated local Aider worker without replacing other Codex settings."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import time
import tomllib

NAME = "aider-deepseek"
MODEL = "openai/deepseek-v4.1-flash-1017"


def registration(kit: Path, root: Path) -> dict:
    return {
        "command": "/bin/bash",
        "args": [str(kit / "scripts/aider.sh"), "serve", str(root)],
        "env": {
            "OPENAI_API_BASE": "http://127.0.0.1:18080/v1",
            "OPENAI_API_KEY": "local-only",
            "AIDER_MODEL": MODEL,
            "AIDER_WEAK_MODEL": MODEL,
            "AIDER_MODEL_SETTINGS_FILE": str(kit / "configs/aider/model-settings.yml"),
            "AIDER_MODEL_METADATA_FILE": str(kit / "configs/aider/model-metadata.json"),
            "AIDER_AUTO_COMMITS": "false",
            "AIDER_DIRTY_COMMITS": "false",
            "AIDER_GITIGNORE": "false",
            "AIDER_ANALYTICS": "false",
            "AIDER_MAP_TOKENS": "512",
            "AIDER_MAX_CHAT_HISTORY_TOKENS": "1024",
            "AIDER_TIMEOUT": "600",
        },
    }


def matches(actual: dict, expected: dict) -> bool:
    return all(actual.get(key) == value for key, value in expected.items()) and actual.get("enabled", True)


def configure(kit: Path, root: Path, home: Path) -> None:
    if not root.is_absolute() or not root.is_dir():
        raise ValueError("--root must be an existing absolute workspace directory")
    if any(char in str(root) for char in "*?[]{}\n\r"):
        raise ValueError("--root cannot contain glob metacharacters or newlines")
    config = home / "config.toml"
    if config.is_symlink():
        raise ValueError("Refusing to replace a symlinked Codex configuration")
    raw = config.read_bytes() if config.exists() else b""
    before = tomllib.loads(raw.decode())
    expected = registration(kit.resolve(), root.resolve())
    existing = before.get("mcp_servers", {}).get(NAME)
    if existing is not None:
        if matches(existing, expected):
            print(f"{NAME}: already configured; no changes")
            return
        raise ValueError(f"Existing {NAME} differs; preserve it and inspect before reconfiguring")
    home.mkdir(parents=True, exist_ok=True)
    backup = None
    if config.exists():
        backup = home / f"config.toml.aider-backup-{time.time_ns()}"
        shutil.copy2(config, backup)
        backup.chmod(0o600)
    command = ["codex", "mcp", "add", NAME]
    for key, value in expected["env"].items():
        command.extend(["--env", f"{key}={value}"])
    command.extend(["--", expected["command"], *expected["args"]])
    subprocess.run(command, check=True)
    after = tomllib.loads(config.read_text())
    actual = after.get("mcp_servers", {}).pop(NAME, {})
    if "mcp_servers" not in before and not after.get("mcp_servers"):
        after.pop("mcp_servers", None)
    if not matches(actual, expected) or after != before:
        raise RuntimeError(f"Codex settings verification failed; original backup: {backup}")
    subprocess.run(["codex", "--strict-config", "mcp", "get", NAME, "--json"],
                   stdout=subprocess.DEVNULL, check=True)
    print(f"{NAME}: registered; unrelated settings unchanged; backup: {backup}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit-root", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    configure(args.kit_root, args.root, Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))


if __name__ == "__main__":
    main()
