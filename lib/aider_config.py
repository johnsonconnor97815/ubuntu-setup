"""Register the isolated local Aider worker without replacing other Codex settings."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import selectors
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


def write_registration(config: Path, expected: dict, original: bytes) -> None:
    # `codex mcp add` rewrites every MCP table and can discard fields on existing
    # entries. The generic, version-checked config edit preserves those entries.
    process = subprocess.Popen(
        ["codex", "--strict-config", "app-server", "--stdio"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=dict(os.environ, CODEX_HOME=str(config.parent)),
    )
    serial, buffer = 0, b""

    def rpc(method: str, params: dict) -> dict:
        nonlocal serial, buffer
        serial += 1
        process.stdin.write(json.dumps({"id": serial, "method": method, "params": params}).encode() + b"\n")
        process.stdin.flush()
        deadline = time.monotonic() + 30
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if b"\n" not in buffer:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        raise TimeoutError(method)
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("Codex app-server exited during configuration")
                    buffer += chunk
                    continue
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") == serial:
                    if "error" in message:
                        raise RuntimeError(message["error"])
                    return message["result"]
        raise TimeoutError(method)

    try:
        rpc("initialize", {"clientInfo": {"name": "aider-setup", "version": "1"},
                           "capabilities": {"experimentalApi": True}})
        result = rpc("config/read", {"includeLayers": True})
        layer = next((item for item in result.get("layers", [])
                      if item["name"].get("file") == str(config)), None)
        if (config.read_bytes() if config.exists() else b"") != original:
            raise RuntimeError("Codex configuration changed; rerun after inspecting it")
        rpc("config/batchWrite", {"filePath": str(config),
                                  "expectedVersion": layer["version"] if layer else None,
                                  "reloadUserConfig": False,
                                  "edits": [{"keyPath": f"mcp_servers.{NAME}",
                                             "mergeStrategy": "replace", "value": expected}]})
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


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
    write_registration(config, expected, raw)
    after = tomllib.loads(config.read_text())
    actual = after.get("mcp_servers", {}).pop(NAME, {})
    if "mcp_servers" not in before and not after.get("mcp_servers"):
        after.pop("mcp_servers", None)
    if not matches(actual, expected) or after != before:
        raise RuntimeError(f"Codex settings verification failed; original backup: {backup}")
    subprocess.run(["codex", "--strict-config", "app-server", "--print-startup-config"],
                   stdout=subprocess.DEVNULL, check=True,
                   env=dict(os.environ, CODEX_HOME=str(home)))
    print(f"{NAME}: registered; unrelated settings unchanged; backup: {backup}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kit-root", required=True, type=Path)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    configure(args.kit_root, args.root, Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")))


if __name__ == "__main__":
    main()
