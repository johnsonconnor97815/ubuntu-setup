import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "aider_config", Path(__file__).resolve().parents[1] / "lib/aider_config.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AiderConfigTests(unittest.TestCase):
    def test_preserves_other_settings_and_second_run_is_noop(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "config.toml"
            original = 'model = "example"\n[mcp_servers.existing]\ncommand = "keep"\n'
            config.write_text(original)

            def run(command, **kwargs):
                if "add" not in command:
                    return
                tail = command.index("--")
                values = command[4:tail]
                env = dict(item.split("=", 1) for item in values[1::2])
                block = '\n[mcp_servers.aider-deepseek]\n'
                block += 'command = ' + json.dumps(command[tail + 1]) + '\n'
                block += 'args = ' + json.dumps(command[tail + 2:]) + '\n'
                block += '[mcp_servers.aider-deepseek.env]\n'
                block += ''.join(f'{key} = {json.dumps(value)}\n' for key, value in env.items())
                config.write_text(original + block)

            with patch.object(MODULE.subprocess, "run", side_effect=run) as invoke:
                MODULE.configure(root, root, root)
                first = config.read_bytes()
                backups = list(root.glob("config.toml.aider-backup-*"))
                self.assertEqual(len(backups), 1)
                self.assertEqual(backups[0].read_text(), original)
                self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
                MODULE.configure(root, root, root)
                self.assertEqual(invoke.call_count, 2)
                self.assertEqual(config.read_bytes(), first)
                self.assertEqual(len(list(root.glob("config.toml.aider-backup-*"))), 1)

    def test_existing_different_entry_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            config = root / "config.toml"
            original = '[mcp_servers.aider-deepseek]\ncommand = "user-owned"\n'
            config.write_text(original)
            with patch.object(MODULE.subprocess, "run") as invoke:
                with self.assertRaisesRegex(ValueError, "Existing"):
                    MODULE.configure(root, root, root)
                invoke.assert_not_called()
            self.assertEqual(config.read_text(), original)

    def test_rejects_missing_root_and_symlinked_config(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaisesRegex(ValueError, "existing absolute"):
                MODULE.configure(root, root / "missing", root)
            target = root / "original.toml"
            target.write_text('model = "keep"\n')
            (root / "config.toml").symlink_to(target)
            with self.assertRaisesRegex(ValueError, "symlink"):
                MODULE.configure(root, root, root)
            self.assertEqual(target.read_text(), 'model = "keep"\n')


if __name__ == "__main__":
    unittest.main()
