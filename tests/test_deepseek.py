import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('deepseek', Path(__file__).resolve().parents[1] / 'lib/deepseek.py')
deepseek = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(deepseek)


class DeepSeekDeploymentTests(unittest.TestCase):
    def test_modelscope_uses_checked_immutable_file_revision(self):
        item = deepseek.MANIFEST['shards'][0]
        manifest = deepseek.MANIFEST | {'shards':[item]}
        entry = {'Path':item['path'], 'Size':item['size'], 'Sha256':item['sha256'], 'Revision':'a'*40}
        response = io.BytesIO(json.dumps({'Data':{'Files':[entry]}}).encode())
        with patch.object(deepseek.urllib.request, 'urlopen', return_value=response):
            urls = deepseek.model_download_urls('modelscope', manifest)
        self.assertEqual(urls[item['path']], f"https://modelscope.cn/models/{manifest['model_repo']}/resolve/{'a'*40}/{item['path']}")

    def test_modelscope_rejects_changed_digest(self):
        item = deepseek.MANIFEST['shards'][0]
        manifest = deepseek.MANIFEST | {'shards':[item]}
        entry = {'Path':item['path'], 'Size':item['size'], 'Sha256':'0'*64, 'Revision':'a'*40}
        response = io.BytesIO(json.dumps({'Data':{'Files':[entry]}}).encode())
        with patch.object(deepseek.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'differs from pinned model'):
                deepseek.model_download_urls('modelscope', manifest)

    def test_modelscope_rejects_moving_revision(self):
        item = deepseek.MANIFEST['shards'][0]
        manifest = deepseek.MANIFEST | {'shards':[item]}
        entry = {'Path':item['path'], 'Size':item['size'], 'Sha256':item['sha256'], 'Revision':'master'}
        response = io.BytesIO(json.dumps({'Data':{'Files':[entry]}}).encode())
        with patch.object(deepseek.urllib.request, 'urlopen', return_value=response):
            with self.assertRaisesRegex(ValueError, 'immutable'):
                deepseek.model_download_urls('modelscope', manifest)

    def test_stop_download_addresses_user_manager(self):
        script = Path(__file__).resolve().parents[1] / 'scripts/deepseek.sh'
        result = deepseek.subprocess.run([
            'bash', '-c',
            'source "$1" help >/dev/null; _deepseek_user_bus() { printf "%s\\n" "$@"; }; do_stop_download',
            'test', str(script),
        ], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout.splitlines(), ['systemctl', '--user', 'stop', 'deepseek-deploy.service'])

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
            with patch.object(deepseek.subprocess, 'run', side_effect=interrupted), patch.object(deepseek.time, 'sleep'):
                with self.assertRaises(deepseek.subprocess.CalledProcessError):
                    deepseek.download('https://example.com/model', path, {'size':100, 'sha256':'0'*64})
            self.assertFalse(path.exists())
            self.assertEqual(path.with_suffix('.gguf.part').read_bytes(), b'partial')

    def test_interrupted_transfer_resumes_without_duplicating_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / 'model.gguf'
            partial = path.with_suffix('.gguf.part')
            partial.write_bytes(b'ab')
            offsets = []
            def transfer(command, **kwargs):
                existing = partial.read_bytes()
                offsets.append(len(existing))
                if existing == b'ab':
                    partial.write_bytes(b'abcd')
                    raise deepseek.subprocess.CalledProcessError(56, command)
                self.assertEqual(existing, b'abcd')
                partial.write_bytes(b'abcdef')
            with patch.object(deepseek.subprocess, 'run', side_effect=transfer), patch.object(deepseek.time, 'sleep'):
                deepseek.download('https://example.com/model', path, {'size':6, 'sha256':hashlib.sha256(b'abcdef').hexdigest()})
            self.assertEqual(offsets, [2, 4])
            self.assertEqual(path.read_bytes(), b'abcdef')
            self.assertFalse(partial.exists())

    def test_http_error_is_not_retried_as_transport_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            with patch.object(deepseek.subprocess, 'run', side_effect=deepseek.subprocess.CalledProcessError(22, ['curl'])) as run:
                with self.assertRaises(deepseek.subprocess.CalledProcessError):
                    deepseek.download('https://example.com/missing', Path(temp)/'model', {'size':1, 'sha256':'0'*64})
            self.assertEqual(run.call_count, 1)

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
