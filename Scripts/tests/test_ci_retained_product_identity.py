from __future__ import annotations
import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('retained_identity', ROOT / 'Scripts/ci/retained_product_identity.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RetainedProductIdentityTests(unittest.TestCase):
    def test_recovery_package_source_changes_invalidate_retained_identity(self):
        path = 'Packages/RecoveryKit'
        pins = {p: '040000 tree ' + '1' * 40 + '\t' + p for p in module.INPUTS}
        with mock.patch.object(module, 'command', side_effect=lambda *args, **kwargs: pins[args[-1]]):
            original = module.identity(Path('/fixture'), {'toolchain': 'fixture'})
            self.assertIn(path, original['canonical_inputs'])
            pins[path] = '040000 tree ' + '2' * 40 + '\t' + path
            changed = module.identity(Path('/fixture'), {'toolchain': 'fixture'})
            self.assertNotEqual(changed['canonical_inputs'][path], original['canonical_inputs'][path])
            self.assertNotEqual(module.canonical(changed), module.canonical(original))

    def test_dependency_toolchain_and_generation_changes_invalidate_key(self):
        pins = {p: '040000 tree ' + '1' * 40 + '\t' + p for p in module.INPUTS}
        def run(*args, **kwargs):
            return pins[args[-1]]
        toolchain = {'xcode': 'Xcode27', 'sdk': '27.2', 'swift': '6.4'}
        with mock.patch.object(module, 'command', side_effect=run):
            original = module.identity(Path('/fixture'), toolchain)
            for path in module.INPUTS:
                old = pins[path]
                pins[path] = old.replace('1' * 40, '2' * 40)
                self.assertNotEqual(module.identity(Path('/fixture'), toolchain), original, path)
                pins[path] = old
            for name in toolchain:
                self.assertNotEqual(module.identity(Path('/fixture'), {**toolchain, name: 'changed'}), original)

    def test_identity_reads_canonical_git_objects_not_checkout_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            for path in module.INPUTS:
                p = root / path
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text('committed')
            subprocess.run(['git', '-C', str(root), 'add', '.'], check=True)
            subprocess.run(['git', '-C', str(root), '-c', 'user.name=Fixture', '-c', 'user.email=f@example.invalid', 'commit', '-qm', 'fixture'], check=True)
            first = module.identity(root, {'toolchain': 'fixture'})
            (root / 'MacScope/project.yml').write_text('uncommitted changed checkout')
            self.assertEqual(module.identity(root, {'toolchain': 'fixture'}), first)

    def test_missing_pin_fails_closed(self):
        with mock.patch.object(module, 'command', return_value=''):
            with self.assertRaises(ValueError):
                module.identity(Path('/fixture'), {})

    def test_derived_data_is_warm_only_under_an_unchanged_identity(self):
        self.assertEqual(module.warm_decision('k', 'k', True)[0], 'warm')
        self.assertEqual(module.warm_decision('old', 'k', True)[0], 'clean')
        self.assertEqual(module.warm_decision(None, 'k', True)[0], 'clean')
        self.assertEqual(module.warm_decision('k', 'k', False)[0], 'clean')
        self.assertFalse(hasattr(module, 'clean_reason'))  # no calendar clean

    def test_workflow_keeps_one_warm_run_root(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('      - name: Record retained-product identity', workflow)
        self.assertIn('--persistent-run nightly', workflow)
        self.assertIn('MACSCOPE_QUALIFICATION_WORK_ROOT_NAME: macscope-qualification-nightly', workflow)
        self.assertNotIn('github.run_id }}-${{ github.run_attempt', workflow)
        self.assertIn('      - name: Retain qualification timing identity\n        if: always()', workflow)
        self.assertIn('/CI_RETENTION.json', workflow)
        self.assertNotIn('--upgrade-approved-previous-pin', workflow)
        self.assertNotIn('--resume-run', workflow)
        self.assertNotIn('rm -rf', workflow)


if __name__ == '__main__':
    unittest.main()
