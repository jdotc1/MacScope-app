#!/usr/bin/env python3
"""Synthetic signing-receipt boundaries; no Apple tools or real app reads."""
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from Scripts.qualification import install_bundle_receipt as receipt


class InstallBundleReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.app = self.root / 'build/MacScope.app'
        (self.app / 'Contents').mkdir(parents=True)
        self.payload = self.app / 'Contents/payload'
        self.payload.write_bytes(b'signed fixture')
        self.policy = self.root / 'policy.py'
        self.policy.write_text('synthetic signing policy')
        self.authorities = [self.policy]
        self.record = self.root / 'source.receipt.json'
        self.calls = 0

    def tearDown(self):
        self.temp.cleanup()

    def verifier(self, app):
        self.assertEqual(app, self.app)
        self.calls += 1
        return []

    def admit(self):
        return receipt.admit(self.app, self.record, self.authorities, self.verifier)

    def test_reboot_metadata_changes_keep_the_receipt_reusable(self):
        self.assertEqual(self.admit(), 'admitted')
        # New ctime/mtime/mode on every leaf and on the receipt, as after a
        # reboot, restore or move: identity is paths, kinds, sizes and content.
        for path in (self.payload, self.policy, self.record):
            os.utime(path, (1, 1))
        self.record.chmod(0o400)
        self.assertEqual(self.admit(), 'reused')
        self.assertEqual(self.calls, 1)

    def test_reuse_and_copy_never_reopen_source_leaves_or_repeat_verifier(self):
        self.assertEqual(self.admit(), 'admitted')
        target = self.root / 'installed/MacScope.app'
        shutil.copytree(self.app, target)
        original = Path.open
        def guarded(path, *args, **kwargs):
            if self.app in path.parents:
                self.fail('unchanged source leaf reopened: ' + str(path))
            return original(path, *args, **kwargs)
        with patch.object(Path, 'open', guarded):
            self.assertEqual(self.admit(), 'reused')
            receipt.compare_copy(self.app, target, self.record, self.authorities)
        self.assertEqual(self.calls, 1)

    def test_source_mutation_rejected_without_verifier(self):
        self.admit()
        self.payload.write_bytes(b'changed bytes, longer')
        with self.assertRaisesRegex(receipt.AdmissionError, 'source identity changed'):
            self.admit()
        # A same-size rewrite is caught by the one copy digest at install.
        self.payload.write_bytes(b'signed fixtur!')
        target = self.root / 'installed/MacScope.app'
        shutil.copytree(self.app, target)
        with self.assertRaisesRegex(receipt.AdmissionError, 'closed tree differs'):
            receipt.compare_copy(self.app, target, self.record, self.authorities)
        self.assertEqual(self.calls, 1)

    def test_closed_file_set_change_rejected(self):
        self.admit()
        (self.app / 'extra').write_text('unapproved')
        with self.assertRaises(receipt.AdmissionError):
            self.admit()
        self.assertEqual(self.calls, 1)

    def test_policy_identity_change_rejected(self):
        self.admit()
        self.policy.write_text('different policy')
        with self.assertRaisesRegex(receipt.AdmissionError, 'policy/toolchain identity changed'):
            self.admit()
        self.assertEqual(self.calls, 1)

    def test_copied_bytes_rejected_without_source_reverification(self):
        self.admit()
        target = self.root / 'installed/MacScope.app'
        shutil.copytree(self.app, target)
        (target / 'Contents/payload').write_text('corrupt')
        with self.assertRaisesRegex(receipt.AdmissionError, 'closed tree differs'):
            receipt.compare_copy(self.app, target, self.record, self.authorities)
        self.assertEqual(self.calls, 1)

    def test_no_receipt_for_failed_signing_and_no_links(self):
        with self.assertRaisesRegex(receipt.AdmissionError, 'invalid signer'):
            receipt.admit(self.app, self.record, self.authorities, lambda _: ['invalid signer'])
        self.assertFalse(self.record.exists())
        (self.app / 'link').symlink_to(self.payload)
        with self.assertRaises(receipt.AdmissionError):
            self.admit()
        self.assertEqual(self.calls, 0)

    def test_same_size_bytes_swapped_during_verification_are_refused(self):
        def swapping_verifier(app):
            self.payload.write_bytes(b'SIGNED FIXTURE')  # same size, different bytes
            return []
        with self.assertRaisesRegex(receipt.AdmissionError, 'bytes changed'):
            receipt.admit(self.app, self.record, self.authorities, swapping_verifier)
        self.assertFalse(self.record.exists())


if __name__ == '__main__':
    unittest.main()
