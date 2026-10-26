#!/usr/bin/env python3
"""Synthetic cases for SLEIGH recorded-content receipt reuse without payload hashing."""
import argparse
from datetime import datetime, timezone
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1] / 'qualification/dependency_cache.py'
spec = importlib.util.spec_from_file_location('sleigh_content_cache', TOOL)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class SleighContentReceiptReuseTests(unittest.TestCase):
    def exercise(self, *, recorded_identity_changed=False, same_size_payload_changed=False):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            verification = root / 'verification'
            verification.mkdir(mode=0o700)
            component = 'sleigh-native-source'
            def entry(key, content=b'accepted content'):
                result = root / 'artifacts/v1' / component / key
                payload = result / 'payload'
                payload.mkdir(parents=True)
                artifact = payload / 'library.a'
                artifact.write_bytes(content)
                artifact.chmod(0o444)
                records, total = cache.payload_records(payload)
                document = dict(component=component, key=key, schema_version=cache.SCHEMA_VERSION,
                                payload_records=records, payload_tree_sha256=cache.payload_tree_digest(records),
                                total_bytes=total, file_count=1)
                (result / 'ENTRY.json').write_bytes(cache.canonical_json(document))
                (result / 'ENTRY.json').chmod(0o444)
                payload.chmod(0o555)
                result.chmod(0o555)
                return result
            old = entry('a' * 64)
            current = entry('b' * 64, b'rejected content' if recorded_identity_changed else b'accepted content')
            def arguments(path):
                return argparse.Namespace(entry=path, component=component, key=path.name,
                                          verification_root=verification,
                                          binding=['domain-verifier=verify_sleigh_view',
                                                   'platform-toolchain=' + 'c' * 64,
                                                   'native-tools=' + 'd' * 64])
            old_args = arguments(old)
            key, receipt_path, identity = cache.verification_identity(old_args)
            receipt_path.parent.mkdir(parents=True, mode=0o700)
            receipt = dict(identity, entry=str(old), entry_metadata_sha256=cache.entry_metadata_digest(old),
                           verification_key=key, verification='synthetic accepted SLEIGH domain',
                           verified_at=datetime.now(timezone.utc).isoformat(), verified_run_view=str(root / 'old-view'))
            receipt_path.write_bytes(cache.canonical_json(receipt))
            receipt_path.chmod(0o444)
            # A new key has different inodes. Metadata drift preserves the recorded
            # identity; same-size byte changes are trusted under no-rehash reuse.
            leaf = current / 'payload/library.a'
            payloads = {old / 'payload/library.a', leaf}
            leaf.chmod(0o644)
            if same_size_payload_changed:
                leaf.write_bytes(b'rejected content')
            leaf.chmod(0o444)
            try:
                with mock.patch.object(cache, 'stable_file_sha256', wraps=cache.stable_file_sha256) as hashing:
                    if recorded_identity_changed:
                        with self.assertRaisesRegex(cache.CacheError, 'content differs') as failure:
                            cache.load_verification_receipt(arguments(current))
                        self.assertNotIsInstance(failure.exception, cache.NotReusableError)
                    else:
                        value, digest = cache.load_verification_receipt(arguments(current))
                        self.assertEqual(value, receipt)  # Original authority is never relabeled.
                        self.assertEqual(len(digest), 64)
                        self.assertEqual(sum(call.args[0] in payloads for call in hashing.call_args_list), 0)
                        reused, reused_digest = cache.load_verification_receipt(arguments(current))
                        self.assertEqual(reused, receipt)
                        self.assertEqual(reused_digest, digest)
                    self.assertEqual(sum(call.args[0] in payloads for call in hashing.call_args_list), 0)
            finally:
                for directory in (old, current):
                    directory.chmod(0o755)
                    (directory / 'payload').chmod(0o755)

    def test_new_key_and_metadata_same_recorded_identity_reuses_without_payload_hashing(self):
        self.exercise()

    def test_changed_recorded_identity_refuses_without_domain_verification_fallback(self):
        self.exercise(recorded_identity_changed=True)

    def test_same_size_payload_change_trusts_recorded_identity_without_payload_hashing(self):
        self.exercise(same_size_payload_changed=True)


if __name__ == '__main__':
    unittest.main()
