#!/usr/bin/env python3
"""Contracts for content-addressed native decompiler build identities."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py"


def load_helper():
    specification = importlib.util.spec_from_file_location(
        "native_decompiler_source_identity_tests",
        HELPER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load native decompiler source identity helper")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class NativeDecompilerSourceIdentityTests(unittest.TestCase):
    def test_run_receipt_hashes_once_and_rejects_changed_closed_inputs(self) -> None:
        module = load_helper()
        for mutation in ("same-size-content", "added-input", "removed-input"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                root, receipts = base / "source", base / "receipts"
                (root / "inputs").mkdir(parents=True)
                receipts.mkdir(mode=0o700)
                source = root / "inputs/one"
                source.write_bytes(b"original")
                with mock.patch.object(module, "WRAPPER_FIXED", ()), \
                     mock.patch.object(module, "WRAPPER_TREES", ("inputs",)), \
                     mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts)}), \
                     mock.patch.object(module, "digest_paths", wraps=module.digest_paths) as digest:
                    accepted = module.profile_digest(root, "wrapper")
                    self.assertEqual(module.profile_digest(root, "wrapper"), accepted)
                    self.assertEqual(digest.call_count, 1)
                    if mutation == "same-size-content":
                        metadata = source.stat()
                        source.write_bytes(b"modified")
                        os.utime(source, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
                    elif mutation == "added-input":
                        (root / "inputs/two").write_bytes(b"new")
                    else:
                        source.unlink()
                    with self.assertRaisesRegex(module.SourceIdentityError, "changed"):
                        module.profile_digest(root, "wrapper")
                    self.assertEqual(digest.call_count, 1)

    def test_run_receipt_rejects_malformed_receipt_and_linked_directory(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            root, receipts = base / "source", base / "receipts"
            (root / "inputs").mkdir(parents=True)
            receipts.mkdir(mode=0o700)
            (root / "inputs/one").write_bytes(b"original")
            with mock.patch.object(module, "WRAPPER_FIXED", ()), \
                 mock.patch.object(module, "WRAPPER_TREES", ("inputs",)), \
                 mock.patch.dict(os.environ, {"MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts)}):
                module.profile_digest(root, "wrapper")
                receipt = next(receipts.glob("*.json"))
                receipt.chmod(0o600)
                receipt.write_text("not JSON", encoding="utf-8")
                receipt.chmod(0o400)
                with mock.patch.object(module, "digest_paths", side_effect=AssertionError("receipt miss rehashed source")):
                    with self.assertRaisesRegex(module.SourceIdentityError, "malformed"):
                        module.profile_digest(root, "wrapper")
                    linked = base / "linked"
                    linked.symlink_to(receipts, target_is_directory=True)
                    os.environ["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"] = str(linked)
                    with self.assertRaisesRegex(module.SourceIdentityError, "canonical"):
                        module.profile_digest(root, "wrapper")

    def test_compiled_wire_sources_change_golden_identity_for_cli_and_provenance(self) -> None:
        from Scripts.tests.test_release_build_provenance import load_generator_module

        module = load_helper()
        provenance = load_generator_module()
        for name in ("NativeDecompilerWireTargetProfile.swift", "NativeDecompilerWireAuthoredModels.swift",
                     "NativeDecompilerWireCanonicalRequest.swift"):
            with self.subTest(source=name), tempfile.TemporaryDirectory() as temporary_directory:
                root = Path(temporary_directory).resolve()
                relative = "MacScope/Models/NativeDecompilerWire/" + name
                for path in set(module.profile_paths(ROOT, "golden")) | {relative}:
                    destination = root / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / path, destination)
                wrapper = module.profile_digest(root, "wrapper")
                golden = module.profile_digest(root, "golden")
                self.assertEqual(provenance.native_decompiler_source_identities(root), (wrapper, golden))
                source = root / relative
                source.write_bytes(source.read_bytes() + b"\n// mutation regression\n")
                changed = module.profile_digest(root, "golden")
                self.assertNotEqual(changed, golden)
                self.assertEqual(module.profile_digest(root, "wrapper"), wrapper)
                self.assertEqual(provenance.native_decompiler_source_identities(root), (wrapper, changed))
                ordinary_cli = subprocess.run(
                    [sys.executable, "-B", str(root / HELPER.relative_to(ROOT)),
                     "--repository-root", str(root), "--profile", "golden"],
                    check=True, capture_output=True, text=True,
                )
                self.assertEqual(ordinary_cli.stdout.strip(), changed)

    def test_digest_changes_only_with_declared_content_or_mode(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "inputs").mkdir()
            first = root / "inputs/first.txt"
            second = root / "inputs/second.txt"
            first.write_bytes(b"one\n")
            second.write_bytes(b"two\n")

            baseline = module.digest_paths(root, ("inputs/first.txt", "inputs/second.txt"))
            (root / "unrelated.txt").write_bytes(b"ignored\n")
            self.assertEqual(
                module.digest_paths(root, ("inputs/first.txt", "inputs/second.txt")),
                baseline,
            )

            second.write_bytes(b"changed\n")
            self.assertNotEqual(
                module.digest_paths(root, ("inputs/first.txt", "inputs/second.txt")),
                baseline,
            )

    def test_digest_normalizes_nonexecutable_permissions_but_tracks_execution(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source = root / "source.sh"
            source.write_bytes(b"#!/bin/sh\nexit 0\n")
            source.chmod(0o600)

            restrictive = module.digest_paths(root, ("source.sh",))
            source.chmod(0o644)
            self.assertEqual(module.digest_paths(root, ("source.sh",)), restrictive)

            source.chmod(0o755)
            self.assertNotEqual(module.digest_paths(root, ("source.sh",)), restrictive)

    def test_digest_is_order_independent_and_rejects_symlinks(self) -> None:
        module = load_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            (root / "a").write_bytes(b"a")
            (root / "b").write_bytes(b"b")
            self.assertEqual(
                module.digest_paths(root, ("a", "b")),
                module.digest_paths(root, ("b", "a")),
            )
            (root / "link").symlink_to(root / "a")
            with self.assertRaisesRegex(module.SourceIdentityError, "symlink"):
                module.digest_paths(root, ("link",))

    def test_profiles_are_closed_over_current_build_surfaces(self) -> None:
        module = load_helper()
        wrapper = set(module.profile_paths(ROOT, "wrapper"))
        golden = set(module.profile_paths(ROOT, "golden"))
        self.assertIn("Tools/NativeDecompilerBridge/CMakeLists.txt", wrapper)
        self.assertIn("Scripts/native-decompiler-xpc/build_native_bridge.sh", wrapper)
        self.assertIn(
            "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
            wrapper,
        )
        self.assertTrue(wrapper < golden)
        self.assertIn(
            "MacScope/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm",
            golden,
        )
        self.assertRegex(module.profile_digest(ROOT, "wrapper"), r"^[0-9a-f]{64}$")
        self.assertRegex(module.profile_digest(ROOT, "golden"), r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
