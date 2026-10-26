"""Data-integrity checks for the native runner; these are not installed acceptance."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'acceptance/native_workspace_acceptance.py'
spec = importlib.util.spec_from_file_location('native_workspace_acceptance', MODULE)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class NativeWorkspaceAcceptanceIntegrityTests(unittest.TestCase):
    def test_gui_lease_excludes_another_gate_until_scenario_finishes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'heavy-gate.lock'
            with runner.GUIAcceptanceLease(root, lock=lock):
                contender = os.open(lock, os.O_WRONLY)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    metadata = json.loads(lock.with_name(lock.name + '.json').read_text())
                    self.assertEqual(metadata['mode'], 'installed-gui')
                    self.assertEqual(metadata['pid'], os.getpid())
                finally:
                    os.close(contender)
            contender = os.open(lock, os.O_WRONLY)
            try:
                fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(contender)
            self.assertFalse(lock.with_name(lock.name + '.json').exists())

    def test_gui_lease_releases_after_scenario_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            lock = root / 'heavy-gate.lock'
            with self.assertRaisesRegex(RuntimeError, 'scenario failed'):
                with runner.GUIAcceptanceLease(root, lock=lock):
                    raise RuntimeError('scenario failed')
            descriptor = os.open(lock, os.O_WRONLY)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)

    def test_gui_lease_rejects_a_symlink_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / 'target'
            target.write_text('retained')
            lock = root / 'heavy-gate.lock'
            lock.symlink_to(target)
            with self.assertRaises(OSError):
                runner.GUIAcceptanceLease(root, lock=lock).acquire()
            self.assertEqual(target.read_text(), 'retained')

    def test_json_reordering_is_semantic_but_changed_values_and_binary_bytes_are_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'manifest.json').write_text('{"a":1,"b":2}')
            (root / 'payload.bin').write_bytes(b'original')
            original_hashes = runner.hash_tree(root)
            original_semantic = runner.semantic_tree(root)
            (root / 'manifest.json').write_text('{"b":2,"a":1}')
            self.assertNotEqual(original_hashes, runner.hash_tree(root))
            self.assertEqual(original_semantic, runner.semantic_tree(root))
            (root / 'manifest.json').write_text('{"b":2,"a":3}')
            self.assertNotEqual(original_semantic, runner.semantic_tree(root))
            (root / 'manifest.json').write_text('{"b":2,"a":1}')
            (root / 'payload.bin').write_bytes(b'changed')
            self.assertNotEqual(original_semantic, runner.semantic_tree(root))

    def test_output_fragment_join_does_not_count_command_echo_as_result(self):
        transcript = 'out: echo MAR\nout: KER↵\nout: MAR\nout: KER↵\nout: prompt$ '
        self.assertEqual(runner.rendered_output_lines(transcript).count('MARKER'), 1)

    def test_package_symlink_and_empty_package_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, 'Empty workspace'):
                runner.hash_tree(root)
            (root / 'manifest.json').write_text('{}')
            (root / 'link').symlink_to(root / 'manifest.json')
            with self.assertRaisesRegex(ValueError, 'symlink'):
                runner.hash_tree(root)


if __name__ == '__main__':
    unittest.main()
