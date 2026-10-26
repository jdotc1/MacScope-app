"""Synthetic retained Ghostty verification reuse: content keys, never entry metadata."""
import hashlib
import importlib.util
import os
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace

QUALIFICATION = Path(__file__).resolve().parents[1] / 'qualification'
sys.path.insert(0, str(QUALIFICATION))
spec = importlib.util.spec_from_file_location('retained_cache_test', QUALIFICATION / 'retained_dependency_cache.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RetainedDependencyCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.key = 'a' * 64
        cache, run = root / 'cache', root / 'run'
        self.entry = cache / 'artifacts/v1/ghostty-vt' / self.key
        (self.entry / 'payload').mkdir(parents=True)
        entry_value = {'component': 'ghostty-vt', 'file_count': 0, 'key': self.key, 'payload_records': [],
                       'payload_tree_sha256': 'b' * 64, 'schema_version': m.SCHEMA_VERSION, 'total_bytes': 0}
        (self.entry / 'ENTRY.json').write_bytes(m.canonical_json(entry_value))
        (self.entry / 'payload').chmod(0o555)
        self.addCleanup((self.entry / 'payload').chmod, 0o755)
        self.entry.chmod(0o555)
        self.addCleanup(self.entry.chmod, 0o755)
        self.write(run / 'old/QUALIFICATION_INPUTS.json', {'dependency_cache_root': str(cache)})
        self.admission = run / 'new/RETAINED_TOOLCHAIN_ADMISSION.json'
        self.write(self.admission, {'source': str(run / 'new/source'), 'retained_inputs': str(run / 'old/QUALIFICATION_INPUTS.json'),
                                    'component_keys': {'ghostty-vt': self.key}, 'platform_identity': 'c' * 64,
                                    'schema_version': 1, 'metadata': []})
        self.bindings = {'platform-toolchain': 'c' * 64, 'domain-verifier': 'verify_ghostty_vt_view'}
        self.verifications = root / 'verifications'
        self.receipt = self.verification({**self.bindings, 'native-tools': 'd' * 64})

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(m.canonical_json(value))

    def verification(self, bindings):
        value = {'bindings': bindings, 'component': 'ghostty-vt', 'entry': str(self.entry),
                 'entry_metadata_sha256': 'e' * 64,  # Historical; never compared.
                 'entry_receipt_sha256': hashlib.sha256((self.entry / 'ENTRY.json').read_bytes()).hexdigest(),
                 'key': self.key, 'schema_version': m.VERIFICATION_SCHEMA_VERSION,
                 'verification': {'domain': 'synthetic'}, 'verified_at': '2026-10-15T00:00:00Z', 'verified_run_view': '/old/run/view'}
        value['verification_key'] = hashlib.sha256(m.canonical_json(bindings)).hexdigest()
        self.assertEqual(set(value), m.VERIFICATION_RECEIPT_FIELDS)
        path = self.verifications / 'dependency-verifications/v1/ghostty-vt' / (value['verification_key'] + '.json')
        self.write(path, value)
        return path

    def arguments(self):
        return SimpleNamespace(retained_toolchain_admission=self.admission, component='ghostty-vt', key=self.key,
                               entry=self.entry, verification_root=self.verifications,
                               binding=[k + '=' + v for k, v in self.bindings.items()])

    def test_reuses_accepted_verification_despite_stale_entry_metadata(self):
        os.utime(self.entry / 'ENTRY.json', (1, 1))  # Reboot/restore-style metadata drift.
        arguments = self.arguments()
        value, digest = m.load_retained_verification_receipt(arguments)
        self.assertEqual(digest, 'retained-verification-key:' + value['verification_key'])
        self.assertEqual(arguments._reused_entry_metadata, m.entry_metadata_digest(self.entry))

    def test_changed_entry_content_or_ambiguous_receipts_refuse(self):
        self.verification({**self.bindings, 'native-tools': 'f' * 64})
        with self.assertRaisesRegex(m.CacheError, 'missing or ambiguous'):
            m.load_retained_verification_receipt(self.arguments())
        arguments = self.arguments()
        arguments.binding = ['platform-toolchain=' + '0' * 64, 'domain-verifier=verify_ghostty_vt_view']
        with self.assertRaisesRegex(m.CacheError, 'bindings differ'):
            m.load_retained_verification_receipt(arguments)

    def test_writable_payload_is_not_reusable(self):
        (self.entry / 'payload').chmod(0o755)  # e.g. a cleanup ran chmod -R u+w before deleting
        with self.assertRaisesRegex(m.NotReusableError, 'writable'):
            m.load_retained_verification_receipt(self.arguments())


if __name__ == '__main__':
    unittest.main()
