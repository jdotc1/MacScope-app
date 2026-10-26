"""Synthetic-only MachOKit admission tests; never hash the repository dependency."""
from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import json
import tempfile
import unittest
from unittest import mock

import test_machokit_materialization as fixtures


class MachOKitAdmissionReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir()
        fixture = fixtures.MachOKitMaterializationTests()
        fixture.make_component_tree(self.source)
        manifest = fixture.write_manifest(self.source)
        self.identity = fixtures.load_module("machokit_admission_fixture", fixtures.IDENTITY_SCRIPT)
        self.identity.MATERIALIZATION_TREE_SHA256 = manifest["tree_sha256"]
        self.identity.GOVERNED_SOURCE_IDENTITY = manifest["governed_source_identity"]
        self.identity.COMPONENTS = tuple(
            replace(component, materialized_tree_sha256=record["tree_sha256"])
            for component, record in zip(self.identity.COMPONENTS, manifest["components"])
        )
        self.work = self.base / "views"
        self.macscope = self.base / "repository" / "MacScope"
        self.macscope.mkdir(parents=True)
        (self.macscope / "project.yml").write_text("name: fixture\n")

    def publish(self):
        return self.identity.publish_read_only_view(self.source, self.work, quiet=True)

    def test_new_view_verified_once_then_publish_verify_and_link_never_read_payload(self):
        identity = self.identity
        with mock.patch.object(identity, "_verify_root", wraps=identity._verify_root) as verify:
            root = self.publish()
            self.assertEqual(verify.call_count, 1)
        self.assertTrue(identity._admission_receipt(root).is_file())
        # A previously admitted view does not consult even the mutable source.
        (self.source / "MachOKit" / "Sources.swift").write_text("different input\n")
        with mock.patch.object(identity, "tree_digest", side_effect=AssertionError("duplicate payload hashing")), mock.patch.object(identity, "_verify_root", side_effect=AssertionError("duplicate domain check")):
            self.assertEqual(self.publish(), root)
            self.assertEqual(identity.verify_root(root, quiet=True), root)
            identity.link_root(root, self.macscope, quiet=True)
            self.assertEqual((self.macscope / "LocalPackages").resolve(), root)

    def test_existing_view_without_receipt_is_verified_once_then_reused(self):
        root = self.publish()
        self.identity._admission_receipt(root).unlink()
        with mock.patch.object(self.identity, "_verify_root", wraps=self.identity._verify_root) as verify:
            self.identity.verify_root(root, quiet=True)
            self.identity.verify_root(root, quiet=True)
            self.assertEqual(verify.call_count, 1)

    def assert_existing_receipt_refused(self, root):
        receipt = self.identity._admission_receipt(root)
        before = receipt.lstat()
        payload = receipt.read_bytes() if receipt.is_file() else None
        with mock.patch.object(self.identity, "_verify_root", side_effect=AssertionError("payload verification")), mock.patch.object(self.identity, "tree_digest", side_effect=AssertionError("payload hashing")), mock.patch.object(self.identity, "_write_admission", side_effect=AssertionError("receipt replacement")):
            with self.assertRaisesRegex(self.identity.MachOKitSourceIdentityError, "existing MachOKit admission receipt is invalid"):
                self.identity.verify_root(root, quiet=True)
        self.assertEqual(receipt.lstat().st_ino, before.st_ino)
        self.assertEqual(receipt.lstat().st_mode, before.st_mode)
        if payload is not None:
            self.assertEqual(receipt.read_bytes(), payload)

    def test_changed_pin_rejects_stale_receipt(self):
        root = self.publish()
        self.identity.MATERIALIZATION_TREE_SHA256 = "0" * 64
        self.assert_existing_receipt_refused(root)

    def test_changed_read_only_content_cannot_reuse_receipt(self):
        root = self.publish()
        leaf = root / "MachOKit" / "Sources.swift"
        leaf.chmod(0o644)
        leaf.write_text("tampered\n")
        leaf.chmod(0o444)
        self.assert_existing_receipt_refused(root)

    def test_receipt_wrong_root_or_pin_does_not_admit(self):
        root = self.publish()
        receipt = self.identity._admission_receipt(root)
        value = json.loads(receipt.read_text())
        value["root"] = str(self.source)
        value["tree_sha256"] = "0" * 64
        receipt.chmod(0o644)
        receipt.write_text(json.dumps(value))
        receipt.chmod(0o444)
        self.assert_existing_receipt_refused(root)

    def test_malformed_existing_receipt_is_preserved_without_reverification(self):
        root = self.publish()
        receipt = self.identity._admission_receipt(root)
        receipt.chmod(0o644)
        receipt.write_bytes(b"{invalid-json")
        receipt.chmod(0o444)
        self.assert_existing_receipt_refused(root)

    def test_unsafe_existing_receipt_is_preserved_without_reverification(self):
        root = self.publish()
        receipt = self.identity._admission_receipt(root)
        original = receipt.read_bytes()
        for shape in ("writable", "oversized", "symlink", "directory"):
            with self.subTest(shape=shape):
                receipt.chmod(0o644)
                if shape == "writable":
                    pass
                elif shape == "oversized":
                    receipt.write_bytes(b" " * 65537)
                    receipt.chmod(0o444)
                else:
                    receipt.unlink()
                    if shape == "symlink":
                        target = self.base / "receipt-target.json"
                        target.write_bytes(original)
                        receipt.symlink_to(target)
                    else:
                        receipt.mkdir()
                self.assert_existing_receipt_refused(root)
                if receipt.is_symlink():
                    receipt.unlink()
                elif receipt.is_dir():
                    receipt.rmdir()
                else:
                    receipt.chmod(0o644)
                    receipt.unlink()
                receipt.write_bytes(original)
                receipt.chmod(0o444)

    def test_metadata_digest_drift_is_not_automatically_readmitted(self):
        root = self.publish()
        identity = self.identity._admission_identity(root)
        identity["metadata_sha256"] = "0" * 64
        with mock.patch.object(self.identity, "_admission_identity", return_value=identity):
            self.assert_existing_receipt_refused(root)

    def test_existing_receipt_removed_during_read_does_not_trigger_first_admission(self):
        root = self.publish()
        receipt = self.identity._admission_receipt(root)
        original = Path.read_text

        def disappear(path, *args, **kwargs):
            if path == receipt:
                raise FileNotFoundError("receipt disappeared after lstat")
            return original(path, *args, **kwargs)

        with mock.patch.object(Path, "read_text", disappear):
            self.assert_existing_receipt_refused(root)

    def test_writable_or_indirect_view_rejected_before_payload_hash(self):
        root = self.publish()
        leaf = root / "MachOKit" / "Sources.swift"
        leaf.chmod(0o644)
        with mock.patch.object(self.identity, "tree_digest", side_effect=AssertionError("payload read")):
            with self.assertRaisesRegex(self.identity.MachOKitSourceIdentityError, "read-only"):
                self.identity.verify_root(root, quiet=True)
            alias = self.base / "alias"
            alias.symlink_to(root)
            with self.assertRaisesRegex(self.identity.MachOKitSourceIdentityError, "indirect"):
                self.identity.verify_root(alias, quiet=True)

    def test_new_view_preserves_and_rejects_source_symlink(self):
        leaf = self.source / "MachOKit" / "Sources.swift"
        leaf.unlink()
        leaf.symlink_to(self.source / "MachOKit" / "Package.swift")
        with self.assertRaisesRegex(self.identity.MachOKitSourceIdentityError, "symbolic link"):
            self.publish()
        self.assertFalse(list(self.work.glob("*.admission.json")))


if __name__ == "__main__":
    unittest.main()
