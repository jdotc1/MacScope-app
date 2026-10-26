#!/usr/bin/env python3
"""Across-run dependency receipt reuse keys on content, never entry metadata."""
import argparse
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1] / 'qualification' / 'dependency_cache.py'
spec = importlib.util.spec_from_file_location('dependency_content_reuse', TOOL)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class DependencyReceiptContentReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        for path in [self.root, *self.root.rglob('*')]:
            if not path.is_symlink():
                path.chmod(0o700 if path.is_dir() else 0o600)
        self.temporary.cleanup()

    def publish(self, entry, data=b'accepted artifact'):
        payload = entry / 'payload'
        payload.mkdir(parents=True)
        leaf = payload / 'artifact.a'
        leaf.write_bytes(data)
        leaf.chmod(0o444)
        records, total = cache.payload_records(payload)
        document = dict(component='fixture', key='a' * 64,
                        schema_version=cache.SCHEMA_VERSION,
                        payload_records=records,
                        payload_tree_sha256=cache.payload_tree_digest(records),
                        total_bytes=total, file_count=1)
        receipt = entry / 'ENTRY.json'
        receipt.write_bytes(cache.canonical_json(document))
        receipt.chmod(0o444)
        payload.chmod(0o555)
        entry.chmod(0o555)
        return leaf

    def write_receipt(self, entry, verification_root):
        arguments = argparse.Namespace(entry=entry, component='fixture', key='a' * 64,
                                       binding=['tools=' + 'b' * 64],
                                       verification_root=verification_root)
        key, path, identity = cache.verification_identity(arguments)
        value = dict(identity, entry=str(entry), verification_key=key,
                     entry_metadata_sha256=cache.entry_metadata_digest(entry),
                     verification='fixture', verified_at='2026-10-15T00:00:00Z',
                     verified_run_view=str(entry))
        path.parent.mkdir(mode=0o700, parents=True)
        path.write_bytes(cache.canonical_json(value))
        path.chmod(0o444)
        return arguments

    def replace_leaf(self, entry, data):
        payload = entry / 'payload'
        payload.chmod(0o755)
        leaf = payload / 'artifact.a'
        leaf.unlink()
        leaf.write_bytes(data)
        leaf.chmod(0o444)
        payload.chmod(0o555)

    def test_metadata_only_change_reuses_receipt_without_rehash(self):
        entry = self.root / 'cache' / ('a' * 64)
        entry.parent.mkdir()
        self.publish(entry)
        verification_root = self.root / 'verifications'
        verification_root.mkdir(mode=0o700)
        arguments = self.write_receipt(entry, verification_root)
        recorded = cache.entry_metadata_digest(entry)
        # New inode/mtime/ctime with the same bytes, a touch, and an outside
        # hardlink (nlink drift): none of these is a content change.
        self.replace_leaf(entry, b'accepted artifact')
        os.utime(entry / 'ENTRY.json', ns=(1, 1))
        os.link(entry / 'payload' / 'artifact.a', self.root / 'outside-link')
        self.assertNotEqual(recorded, cache.entry_metadata_digest(entry))
        with mock.patch.object(cache, 'stable_file_sha256', wraps=cache.stable_file_sha256) as hashing:
            cache.load_verification_receipt(arguments)
            cache.load_verification_receipt(arguments)
            self.assertEqual(hashing.call_count, 0)
        self.assertEqual(arguments._reused_entry_metadata, cache.entry_metadata_digest(entry))
        self.assertEqual([path.name for path in
                          (verification_root / 'dependency-verifications/v1/fixture').iterdir()],
                         [cache.verification_identity(arguments)[0] + '.json'])

    def test_copied_entry_with_same_bytes_reuses_receipt(self):
        original = self.root / 'original'
        self.publish(original)
        entry = self.root / 'cache' / ('a' * 64)
        entry.parent.mkdir()
        shutil.copytree(original, entry)  # every member gets a new inode and ctime
        entry.chmod(0o555)
        verification_root = self.root / 'verifications'
        verification_root.mkdir(mode=0o700)
        arguments = self.write_receipt(entry, verification_root)
        receipt = cache.verification_identity(arguments)[1]
        receipt.chmod(0o644)
        value = cache.read_canonical_json(receipt, 'receipt')
        value['entry_metadata_sha256'] = cache.entry_metadata_digest(original)
        receipt.write_bytes(cache.canonical_json(value))
        receipt.chmod(0o444)
        cache.load_verification_receipt(arguments)
        self.assertEqual(arguments._reused_entry_metadata, cache.entry_metadata_digest(entry))

    def test_payload_content_change_refuses_without_verification_fallback(self):
        entry = self.root / 'cache' / ('a' * 64)
        entry.parent.mkdir()
        self.publish(entry)
        verification_root = self.root / 'verifications'
        verification_root.mkdir(mode=0o700)
        arguments = self.write_receipt(entry, verification_root)
        self.replace_leaf(entry, b'a different, longer artifact')
        with self.assertRaisesRegex(cache.CacheError, 'content differs') as failure:
            cache.load_verification_receipt(arguments)
        self.assertNotIsInstance(failure.exception, cache.NotReusableError)
        self.assertFalse(hasattr(arguments, '_reused_entry_metadata'))

    def test_republished_entry_content_is_not_reusable(self):
        entry = self.root / 'cache' / ('a' * 64)
        entry.parent.mkdir()
        self.publish(entry)
        verification_root = self.root / 'verifications'
        verification_root.mkdir(mode=0o700)
        arguments = self.write_receipt(entry, verification_root)
        entry.chmod(0o755)
        (entry / 'payload').chmod(0o755)
        shutil.rmtree(entry, ignore_errors=False, onerror=lambda f, p, e: (os.chmod(p, 0o700), f(p)))
        self.publish(entry, b'other content')
        with self.assertRaises(cache.NotReusableError):
            cache.load_verification_receipt(arguments)


if __name__ == '__main__':
    unittest.main()
