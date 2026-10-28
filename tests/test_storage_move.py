import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('storage_move', Path(__file__).parents[1]/'scripts/storage_move.py')
storage = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(storage)


class StorageMoveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.source = self.base/'source'
        self.source.mkdir()
        (self.source/'data').write_bytes(b'preserved data\x00\xff')
        self.destination = self.base/'target'
        self.record = self.base/'records'/'move.json'

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self):
        return storage.prepare(self.record, self.source, self.destination, Path('/'))

    def test_copy_switch_check_finish_preserves_content_and_link(self):
        move = self.prepare()
        move.copy()
        move.switch()
        self.assertTrue(Path(move.data['retired']).is_dir())
        move.check(['test','-f',str(self.source/'data')])
        move.finish()
        self.assertTrue(self.source.is_symlink())
        self.assertEqual((self.source/'data').read_bytes(), b'preserved data\x00\xff')
        self.assertFalse(Path(move.data['retired']).exists())

    def test_existing_destination_is_never_overwritten(self):
        self.destination.mkdir()
        with self.assertRaises(RuntimeError):
            self.prepare()

    def test_changed_source_blocks_retirement(self):
        move = self.prepare()
        move.copy()
        (self.source/'data').write_bytes(b'changed')
        with self.assertRaises(RuntimeError):
            move.switch()
        self.assertFalse(self.source.is_symlink())
        self.assertEqual((self.source/'data').read_bytes(), b'changed')
        self.assertFalse(Path(move.data['retired']).exists())

    def test_finish_requires_successful_functional_check(self):
        move = self.prepare()
        move.copy()
        move.switch()
        with self.assertRaises(RuntimeError):
            move.finish()
        self.assertTrue(Path(move.data['retired']).is_dir())

    def test_changed_link_blocks_retirement(self):
        move = self.prepare()
        move.copy()
        move.switch()
        move.check(['true'])
        self.source.unlink()
        self.source.symlink_to(self.base/'different')
        with self.assertRaises(RuntimeError):
            move.finish()
        self.assertTrue(Path(move.data['retired']).is_dir())

    def test_wrong_target_device_blocks_copy(self):
        move = self.prepare()
        move.data['target_device'] = -1
        with self.assertRaises(RuntimeError):
            move.copy()
        self.assertFalse(self.destination.exists())

    def test_open_writer_blocks_cutover(self):
        move = self.prepare()
        move.copy()
        with (self.source/'data').open('ab'):
            with self.assertRaises(RuntimeError):
                move.switch()
        self.assertFalse(self.source.is_symlink())

    def test_destination_replacement_blocks_switch(self):
        move = self.prepare()
        move.copy()
        self.destination.rename(self.base/'other')
        self.destination.mkdir()
        with self.assertRaises(RuntimeError):
            move.switch()
        self.assertFalse(self.source.is_symlink())

    def test_sparse_file_and_internal_hardlink_are_preserved(self):
        path = self.source/'sparse'
        with path.open('wb') as stream:
            stream.seek(16 * 1024 * 1024)
            stream.write(b'end')
        os.link(path, self.source/'hardlink')
        move = self.prepare()
        move.copy()
        move.verify(self.source)
        copied = self.destination/'sparse'
        self.assertEqual(copied.stat().st_ino, (self.destination/'hardlink').stat().st_ino)
        self.assertLess(copied.stat().st_blocks * 512, copied.stat().st_size)


if __name__ == '__main__':
    unittest.main()
