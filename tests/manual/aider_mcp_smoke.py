"""Live opt-in check: ask Aider over MCP to edit a newly created disposable repo."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", required=True, type=Path)
    args = parser.parse_args()
    kit = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location("aider_config", kit / "lib/aider_config.py")
    config = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(config)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    run = Path.home() / ".local/state/ubuntu-setup/aider" / stamp
    run.mkdir(parents=True, mode=0o700)
    project = args.workspace.resolve() / (".aider-smoke-" + stamp)
    project.mkdir(mode=0o700)
    (project / "clamp.py").write_text("def clamp(value, minimum, maximum):\n    raise NotImplementedError\n")
    tests = project / "test_clamp.py"
    tests.write_text('''import unittest
from clamp import clamp
class ClampTests(unittest.TestCase):
    def test_inside(self): self.assertEqual(clamp(5, 0, 10), 5)
    def test_below(self): self.assertEqual(clamp(-4, 0, 10), 0)
    def test_above(self): self.assertEqual(clamp(20, 0, 10), 10)
    def test_equal(self): self.assertEqual(clamp(8, 3, 3), 3)
    def test_invalid(self):
        with self.assertRaises(ValueError): clamp(1, 10, 0)
''')
    test_hash = hashlib.sha256(tests.read_bytes()).hexdigest()
    baseline = subprocess.run([sys.executable, "-m", "unittest"], cwd=project, capture_output=True)
    assert baseline.returncode != 0, "The seed must fail before Aider edits it"
    for command in [["git", "init", "--quiet", "--initial-branch=main"],
                    ["git", "add", "clamp.py", "test_clamp.py"],
                    ["git", "-c", "user.name=Aider test", "-c", "user.email=aider-test@localhost",
                     "commit", "--quiet", "-m", "Initial isolated test"]]:
        subprocess.run(command, cwd=project, check=True)
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project)
    entry = config.registration(kit, args.workspace.resolve())
    env = os.environ.copy()
    env.update(entry["env"])
    events = []

    def record(kind, data):
        item = {"kind": kind, "data": data}
        events.append(item)
        (run / "events.json").write_text(json.dumps(events, ensure_ascii=False, indent=2))
        print(json.dumps(item, ensure_ascii=False), flush=True)

    with (run / "mcp-stderr.log").open("w") as error_log:
        process = subprocess.Popen([entry["command"], *entry["args"]], env=env, text=True,
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error_log)
        serial = 0

        def rpc(method, parameters=None, notify=False):
            nonlocal serial
            serial += 1
            request = {"jsonrpc": "2.0", "method": method, "params": parameters or {}}
            if not notify:
                request["id"] = serial
            process.stdin.write(json.dumps(request) + "\n")
            process.stdin.flush()
            if notify:
                return
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                deadline = time.monotonic() + 40
                while time.monotonic() < deadline:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        raise TimeoutError(method)
                    line = process.stdout.readline()
                    if not line:
                        raise RuntimeError("MCP exited: " + (run / "mcp-stderr.log").read_text())
                    response = json.loads(line)
                    if response.get("id") == serial:
                        if "error" in response:
                            raise RuntimeError(response)
                        return response["result"]
                raise TimeoutError(method)

        try:
            record("initialize", rpc("initialize", {
                "protocolVersion": "2025-03-26", "capabilities": {},
                "clientInfo": {"name": "local-aider-verification", "version": "1"}}))
            rpc("notifications/initialized", notify=True)
            record("tools", [tool["name"] for tool in rpc("tools/list")["tools"]])
            record("preflight", rpc("tools/call", {"name": "aider_check_progress",
                                                  "arguments": {"directory": str(project)}}))
            record("started", rpc("tools/call", {"name": "aider_message_prompt", "arguments": {
                "directory": str(project), "files": ["clamp.py"],
                "message": "Implement clamp(value, minimum, maximum) in clamp.py. Return value when "
                           "within the inclusive bounds, minimum when below, maximum when above. "
                           "Raise ValueError when minimum is greater than maximum. Only edit clamp.py. "
                           "Keep it concise and leave test_clamp.py unchanged."}}))
            started = time.monotonic()
            while time.monotonic() - started < 600:
                time.sleep(15)
                details = json.loads((project / ".aider.mcp.details.json").read_text())
                try:
                    state = Path(f'/proc/{details["processId"]}/stat').read_text().split()[2]
                except FileNotFoundError:
                    state = "gone"
                if state in ("gone", "Z"):
                    break
                print(json.dumps({"waiting_seconds": round(time.monotonic() - started),
                                  "project": str(project)}), flush=True)
            else:
                raise TimeoutError("Aider code task exceeded 600 seconds; inspect the recorded PID")
            record("progress", rpc("tools/call", {"name": "aider_check_progress", "arguments": {
                "directory": str(project), "lines": 40}}))
            result = subprocess.run([sys.executable, "-m", "unittest", "-v"], cwd=project,
                                    capture_output=True, text=True)
            head_unchanged = head == subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project)
            tests_unchanged = test_hash == hashlib.sha256(tests.read_bytes()).hexdigest()
            record("acceptance", {"project": str(project), "run": str(run),
                                  "duration_seconds": round(time.monotonic() - started, 1),
                                  "test_exit": result.returncode, "test_output": result.stdout + result.stderr,
                                  "head_unchanged": head_unchanged, "tests_unchanged": tests_unchanged,
                                  "code": (project / "clamp.py").read_text(),
                                  "diff": subprocess.check_output(["git", "diff"], cwd=project, text=True)})
            assert result.returncode == 0 and head_unchanged and tests_unchanged
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


if __name__ == "__main__":
    main()
