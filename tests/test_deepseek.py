import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('deepseek', Path(__file__).resolve().parents[1] / 'lib/deepseek.py')
deepseek = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deepseek)


class DeepSeekDeploymentTests(unittest.TestCase):
    def test_root_filesystem_rejected(self):
        with self.assertRaisesRegex(ValueError, 'separate from /'):
            deepseek.guard('/tmp/deepseek', '/')

    def test_missing_mount_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError, 'mounted filesystem'):
                deepseek.guard(temp + '/data', temp)

    def test_paths_with_unit_specifiers_rejected(self):
        with self.assertRaisesRegex(ValueError, 'absolute paths'):
            deepseek.guard('/data/%h/model', '/data')

    def test_integrity_and_links(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'model.gguf'
            path.write_bytes(b'known')
            item = {'size':5, 'sha256':hashlib.sha256(b'known').hexdigest()}
            deepseek.check(path, item)
            path.write_bytes(b'wrong')
            with self.assertRaisesRegex(ValueError, 'SHA256 mismatch'):
                deepseek.check(path, item)
            link = Path(temp) / 'link'
            link.symlink_to(path)
            with self.assertRaisesRegex(ValueError, 'linked'):
                deepseek.check(link, item)

    def test_download_failure_keeps_partial(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'model.gguf'
            def interrupted(command, **kwargs):
                Path(command[command.index('--output') + 1]).write_bytes(b'partial')
                raise deepseek.subprocess.CalledProcessError(18, command)
            with patch.object(deepseek.subprocess, 'run', side_effect=interrupted):
                with self.assertRaises(deepseek.subprocess.CalledProcessError):
                    deepseek.download('https://example.com/model', path, {'size':100, 'sha256':'0'*64})
            self.assertFalse(path.exists())
            self.assertEqual(path.with_suffix('.gguf.part').read_bytes(), b'partial')

    def test_service_privacy_and_mount_dependency(self):
        text = deepseek.unit_text(Path('/mnt/disk/model'), Path('/mnt/disk'), 'tester')
        self.assertIn('User=tester', text)
        self.assertIn('ConditionPathIsMountPoint=/mnt/disk', text)
        self.assertIn('BindsTo=mnt-disk.mount', text)
        self.assertIn('"--host" "127.0.0.1"', text)
        self.assertIn('ExecStartPre=/usr/bin/nvidia-smi -L', text)
        self.assertIn('MemorySwapMax=0', text)
        self.assertIn('"--lazy-mode" "on"', text)


if __name__ == '__main__':
    unittest.main()
