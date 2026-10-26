import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

DEPENDENCIES = Path(__file__).resolve().parents[1] / 'dependencies'
sys.path.insert(0, str(DEPENDENCIES))
spec = importlib.util.spec_from_file_location('vt_stage', DEPENDENCIES / 'stage_verified_ghostty_vt.py')
vt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vt)


class GhosttyVTStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.source = self.base / 'source'
        for name in ('lib/libghostty-vt.dylib', 'lib/.macscope-ghostty-vt-manifest',
                     'include/ghostty/vt.h', 'include/ghostty/secondary.h', 'include/module.modulemap'):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.descriptor = self.base / 'descriptor.json'
        self.digest = vt.describe(self.source, self.descriptor)
        self.allowed = self.base / 'build'
        self.allowed.mkdir()
        self.destination = self.allowed / 'artifacts'

    def stage(self):
        vt.stage(self.source, self.descriptor, self.digest, self.destination, self.allowed)

    def test_actual_builder_versioned_alias_stages_ordinary_consumer_bytes(self):
        dylib = self.source / 'lib/libghostty-vt.dylib'
        versioned = self.source / 'lib/libghostty-vt.0.1.0.dylib'
        dylib.rename(versioned)
        dylib.symlink_to(versioned.name)
        # Exact alias contract asserted by test_ghostty_build_contract.py.
        self.assertEqual(vt.describe(self.source, self.descriptor), self.digest)
        self.stage()
        staged = self.destination / 'lib/libghostty-vt.dylib'
        self.assertFalse(staged.is_symlink())
        self.assertEqual(staged.read_bytes(), versioned.read_bytes())
        self.stage()
        for invalid in ('../lib/libghostty-vt.0.1.0.dylib', '/tmp/foreign.dylib', 'other.dylib'):
            dylib.unlink()
            dylib.symlink_to(invalid)
            with self.assertRaises(ValueError):
                self.stage()
        dylib.unlink()
        dylib.symlink_to(versioned.name)
        versioned.unlink()
        versioned.symlink_to(self.descriptor)
        with self.assertRaises(ValueError):
            self.stage()

    def test_retained_zig_major_version_chain_stages_exact_bytes(self):
        # Retained signed qualification run.yMNw1x uses Zig's two-link semver shape.
        dylib = self.source / 'lib/libghostty-vt.dylib'
        versioned = self.source / 'lib/libghostty-vt.0.1.0.dylib'
        major = self.source / 'lib/libghostty-vt.0.dylib'
        dylib.rename(versioned)
        major.symlink_to(versioned.name)
        dylib.symlink_to(major.name)
        self.assertEqual(vt.describe(self.source, self.descriptor), self.digest)
        self.stage()
        staged = self.destination / 'lib/libghostty-vt.dylib'
        self.assertFalse(staged.is_symlink())
        self.assertEqual(staged.read_bytes(), versioned.read_bytes())
        for invalid in ('../lib/libghostty-vt.0.1.0.dylib', 'libghostty-vt.dylib', '/tmp/foreign'):
            major.unlink()
            major.symlink_to(invalid)
            with self.assertRaises(ValueError):
                self.stage()
        major.unlink()
        major.write_bytes(versioned.read_bytes())
        with self.assertRaises(ValueError):
            self.stage()

    def test_xcode_precreated_output_dirs_and_missing_leaf_are_repaired(self):
        (self.destination / 'lib').mkdir(parents=True)
        (self.destination / 'include/ghostty').mkdir(parents=True)
        self.stage()
        self.assertEqual(vt.records(self.source), vt.records(self.destination))
        (self.destination / 'include/ghostty/secondary.h').unlink()
        self.stage()
        self.assertEqual(vt.records(self.source), vt.records(self.destination))

    def test_incomplete_existing_tree_with_unsafe_member_is_rejected(self):
        (self.destination / 'lib').mkdir(parents=True)
        (self.destination / 'include').mkdir()
        (self.destination / 'include/unsafe').symlink_to(self.descriptor)
        with self.assertRaises(ValueError):
            self.stage()
        self.assertTrue((self.destination / 'include/unsafe').is_symlink())

    def test_complete_closure_and_identical_stage_preserves_files(self):
        self.stage()
        path = self.destination / 'include/ghostty/secondary.h'
        before = path.stat()
        self.stage()
        after = path.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(vt.records(self.source), vt.records(self.destination))

    def test_changed_valid_descriptor_replaces_complete_closure(self):
        self.stage()
        (self.source / 'include/ghostty/secondary.h').write_text('changed')
        self.descriptor.chmod(0o600)
        self.descriptor.unlink()
        self.digest = vt.describe(self.source, self.descriptor)
        self.stage()
        self.assertEqual((self.destination / 'include/ghostty/secondary.h').read_text(), 'changed')

    def test_drift_in_every_consumed_leaf_preserves_prior_stage(self):
        self.stage()
        original = vt.records(self.destination)
        for leaf in vt.records(self.source):
            with self.subTest(path=leaf['path']):
                path = self.source / leaf['path']
                payload = path.read_bytes()
                path.write_bytes(payload + b'drift')
                with self.assertRaises(ValueError):
                    self.stage()
                self.assertEqual(original, vt.records(self.destination))
                path.write_bytes(payload)

    def test_unsafe_closure_and_destination_rejected(self):
        (self.source / 'include/link').symlink_to('ghostty/vt.h')
        with self.assertRaises(ValueError):
            self.stage()
        (self.source / 'include/link').unlink()
        self.destination = self.base / 'artifacts'
        with self.assertRaises(ValueError):
            self.stage()

    def test_descriptor_identity_and_added_header_rejected(self):
        self.digest = '0' * 64
        with self.assertRaises(ValueError):
            self.stage()
        self.digest = vt.describe(self.source, self.descriptor)
        (self.source / 'include/extra.h').write_text('extra')
        with self.assertRaises(ValueError):
            self.stage()

if __name__ == '__main__':
    unittest.main()
