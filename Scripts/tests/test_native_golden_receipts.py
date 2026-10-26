#!/usr/bin/env python3
"""Synthetic first-run and stale-receipt checks, without production inputs."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1] / "native-decompiler-xpc/native_golden_receipts.py"
spec = importlib.util.spec_from_file_location("golden_receipts", TOOL)
GOLDEN = importlib.util.module_from_spec(spec)
spec.loader.exec_module(GOLDEN)


class GoldenReceiptTests(unittest.TestCase):
    def test_first_digest_is_reused_without_reading_bytes_and_mutation_fails_closed(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            receipts = root / "receipts"
            receipts.mkdir(mode=0o700)
            path = root / "new-output"
            path.write_bytes(b"new")
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                                             "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts)}):
                first = GOLDEN.digest(path)
                with mock.patch.object(GOLDEN, "stable_hash", side_effect=AssertionError("repeat hash")):
                    self.assertEqual(GOLDEN.digest(path), first)
                    path.write_bytes(b"different")
                    with self.assertRaises(ValueError):
                        GOLDEN.digest(path)

    def test_staged_package_leaf_uses_snapshot_digest_and_requires_matching_metadata(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            path = root / "manifest"
            path.write_bytes(b"known")
            row = ("manifest", "file", tuple(GOLDEN.fields(path.lstat())), "a" * 64)
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view"}), \
                 mock.patch.object(GOLDEN, "package_snapshot", return_value=(root, [row], {})), \
                 mock.patch.object(GOLDEN, "stable_hash", side_effect=AssertionError("package rehash")):
                self.assertEqual(GOLDEN.digest(path, root), "a" * 64)
                path.write_bytes(b"tampered")
                with self.assertRaises(ValueError):
                    GOLDEN.digest(path, root)

    def test_unrecognized_mode_and_writable_receipts_are_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch).resolve()
            path = root / "new-output"
            path.write_bytes(b"new")
            receipts = root / "receipts"
            receipts.mkdir(mode=0o700)
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "unsupported"}):
                with self.assertRaises(ValueError):
                    GOLDEN.digest(path)
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                                             "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts)}):
                GOLDEN.digest(path)
                next(receipts.iterdir()).chmod(0o600)
                with self.assertRaises(ValueError):
                    GOLDEN.digest(path)


    def test_prior_staged_receipt_admits_exact_copy_but_not_changed_content(self):
        import sys
        sys.path.insert(0, str(TOOL.parent))
        import stage_verified_package as stage
        with tempfile.TemporaryDirectory() as scratch:
            top = Path(scratch).resolve()
            old = top / "old"; old.mkdir(mode=0o700)
            current = top / "current"; current.mkdir(mode=0o700)
            package = top / "package"; package.mkdir(mode=0o700)
            leaf = package / "leaf"; leaf.write_bytes(b"known")
            root_fields = stage._stable_tree_fields(package.lstat())
            snapshot = [("leaf", "file", stage._stable_tree_fields(leaf.lstat()), "a" * 64)]
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                    "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(old)}):
                stage._publish_staged_receipt(package, root_fields, snapshot, {})
            with mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                    "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(current),
                    "MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT": str(old)}), \
                 mock.patch.object(stage, "_reused_source_receipt", side_effect=AssertionError("unchanged copy reverified")):
                canonical, descriptor, _, accepted, _ = stage._open_verified_materialization(package, "synthetic")
                os.close(descriptor)
                self.assertEqual(accepted, tuple(snapshot))
                self.assertFalse(stage._staged_receipt_path(package).exists())
                os.utime(leaf, ns=(1, 1))  # metadata only: still admitted
                canonical, descriptor, _, accepted, _ = stage._open_verified_materialization(package, "synthetic")
                os.close(descriptor)
                self.assertEqual([row[3] for row in accepted], ["a" * 64])
                leaf.write_bytes(b"changed")
                with self.assertRaises(stage.PackageStageError):
                    stage._open_verified_materialization(package, "synthetic")


if __name__ == "__main__":
    unittest.main()
