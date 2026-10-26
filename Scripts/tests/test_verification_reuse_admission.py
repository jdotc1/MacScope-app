"""Small filesystem/policy fixtures; never exports source or invokes Xcode."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


source = load('admission_source', 'Scripts/source_export_provenance.py')
dependency = load('admission_dependency', 'Scripts/qualification/dependency_cache.py')


class VerificationReuseAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'verification'
        self.root.mkdir(mode=0o700)
        self.entry = self.root.parent / 'entry'
        self.entry.mkdir()
        (self.entry / 'ENTRY.json').write_text('{}')

    def admit(self, module):
        if module is source:
            return module._reuse_layout(self.root)
        return module.verification_identity(argparse.Namespace(
            component='fixture', key='a' * 64, binding=['verifier=identity'],
            verification_root=self.root, entry=self.entry))

    def test_owned_private_or_readable_roots_are_admitted(self):
        for mode in (0o700, 0o755):
            self.root.chmod(mode)
            for module in (source, dependency):
                with self.subTest(mode=mode, module=module.__name__):
                    self.assertTrue(self.admit(module))

    def test_group_world_write_and_foreign_owner_are_rejected(self):
        for module in (source, dependency):
            for mode in (0o770, 0o702):
                self.root.chmod(mode)
                with self.subTest(module=module.__name__, mode=mode):
                    with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                        self.admit(module)
            self.root.chmod(0o700)
            with mock.patch.object(module.os, 'getuid', return_value=os.getuid() + 1):
                with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                    self.admit(module)

    def test_indirect_and_non_directory_roots_are_rejected(self):
        original = self.root
        self.root = original.parent / 'indirect'
        self.root.symlink_to(original, target_is_directory=True)
        for module in (source, dependency):
            with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                self.admit(module)
        self.root.unlink(); self.root.write_text('ordinary file')
        for module in (source, dependency):
            with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                self.admit(module)

    def test_existing_writable_layout_is_rejected(self):
        for module, relative in ((source, 'source-exports'), (dependency, 'dependency-verifications')):
            directory = self.root / relative
            directory.mkdir(mode=0o777)
            directory.chmod(0o777)
            with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                self.admit(module)
            directory.chmod(0o700)
            self.assertTrue(self.admit(module))

    def test_layout_symlink_is_rejected_before_creating_descendants(self):
        target = self.root.parent / 'outside'
        target.mkdir()
        for module, relative in ((source, 'source-exports'), (dependency, 'dependency-verifications')):
            directory = self.root / relative
            directory.symlink_to(target, target_is_directory=True)
            with self.assertRaises((source.SourceExportError, dependency.CacheError)):
                self.admit(module)
            self.assertEqual(list(target.iterdir()), [])
            directory.unlink()

    def test_canonical_ci_reuses_verification_receipts(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        command = workflow.split('./Scripts/qualify_local_private_build.sh \\', 1)[1].split('\n\n', 1)[0]
        self.assertIn('${MACSCOPE_CI_SELECTION}', command)
        self.assertNotIn('--no-verification-reuse', command)


if __name__ == '__main__':
    unittest.main()
