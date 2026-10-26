from __future__ import annotations

import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MATERIALIZER_PATH = ROOT / "Scripts" / "dependencies" / "materialize_swift_assembly.py"
IDENTITY_PATH = ROOT / "Scripts" / "swift_assembly_source_identity.py"
VENDOR_ROOT = ROOT / "ThirdParty" / "SwiftAssemblyVendor"


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MATERIALIZER = load_module("materialize_swift_assembly_test", MATERIALIZER_PATH)
IDENTITY = load_module("swift_assembly_source_identity_test", IDENTITY_PATH)


class SwiftAssemblyMaterializationTests(unittest.TestCase):
    def copy_vendor(self, destination: Path) -> Path:
        shutil.copytree(VENDOR_ROOT, destination)
        return destination

    def make_source_fixture(self, destination: Path) -> Path:
        for record in MATERIALIZER.SOURCE_FILES:
            source = VENDOR_ROOT / record.vendor_path
            target = destination / record.upstream_path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        shutil.copyfile(VENDOR_ROOT / "LICENSE", destination / "LICENSE")
        return destination

    def test_live_materialization_matches_both_independent_verifiers(self) -> None:
        self.assertEqual(MATERIALIZER.verify_root(VENDOR_ROOT, quiet=True), VENDOR_ROOT)
        self.assertEqual(IDENTITY.verify_root(VENDOR_ROOT, quiet=True), VENDOR_ROOT)

    def test_frozen_source_closure_is_exactly_the_reviewed_fifteen_files(self) -> None:
        expected = {
            "Sources/ARM64/A64BitmaskImmediate.swift",
            "Sources/ARM64/A64Decoder.swift",
            "Sources/ARM64/A64Encoder.swift",
            "Sources/ARM64/A64FloatingPointEncoder.swift",
            "Sources/ARM64/A64Formatter.swift",
            "Sources/ARM64/A64InstructionFormats.swift",
            "Sources/ARM64/A64InstructionParser.swift",
            "Sources/ARM64/A64Model.swift",
            "Sources/ARM64/A64Support.swift",
            "Sources/ARM64/A64VectorEncoder.swift",
            "Sources/ARM64/ARM64Assembler.swift",
            "Sources/Core/AssemblerError.swift",
            "Sources/Core/Endianness.swift",
            "Sources/Core/ParsedInstruction.swift",
            "Sources/Core/SourceParser.swift",
        }
        records = MATERIALIZER.SOURCE_FILES
        self.assertEqual(len(records), 15)
        self.assertEqual({record.vendor_path for record in records}, expected)
        self.assertEqual(
            {path.relative_to(VENDOR_ROOT).as_posix() for path in (VENDOR_ROOT / "Sources").rglob("*.swift")},
            expected,
        )
        self.assertEqual(IDENTITY.EXPECTED_SWIFT_SOURCES, frozenset(expected))

    def test_source_closure_rejects_content_drift_and_an_extra_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = self.make_source_fixture(Path(temporary) / "source")
            MATERIALIZER._verify_source_closure(source)

            drifted = source / MATERIALIZER.SOURCE_FILES[0].upstream_path
            drifted.write_bytes(drifted.read_bytes() + b"// drift\n")
            with self.assertRaisesRegex(MATERIALIZER.MaterializationError, "source checksum mismatch"):
                MATERIALIZER._verify_source_closure(source)

            self.make_source_fixture(source)
            extra = source / "Sources" / "Assembly" / "Extra.swift"
            extra.write_text("// unreviewed\n", encoding="utf-8")
            with self.assertRaisesRegex(MATERIALIZER.MaterializationError, "unexpected upstream source"):
                MATERIALIZER._verify_source_closure(source)

    def test_materialization_rejects_tamper_extra_source_and_identity_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)

            tampered = self.copy_vendor(base / "tampered")
            source = tampered / "Sources" / "ARM64" / "A64Support.swift"
            source.write_bytes(source.read_bytes() + b"// drift\n")
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "source checksum mismatch"):
                IDENTITY.verify_root(tampered, quiet=True)

            extra = self.copy_vendor(base / "extra")
            (extra / "Sources" / "Unreviewed.swift").write_text("// extra\n", encoding="utf-8")
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "unexpected Swift source"):
                IDENTITY.verify_root(extra, quiet=True)

            drifted_identity = self.copy_vendor(base / "identity")
            identity_path = drifted_identity / "SOURCE_IDENTITY.json"
            payload = json.loads(identity_path.read_text(encoding="utf-8"))
            payload["revision"] = "0" * 40
            identity_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "source identity checksum mismatch"):
                IDENTITY.verify_root(drifted_identity, quiet=True)

    def test_direct_source_tree_rejects_symlinks_xcframeworks_and_binary_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)

            linked = self.copy_vendor(base / "linked")
            (linked / "Sources" / "unsafe-link.swift").symlink_to("Core/Endianness.swift")
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "symbolic link"):
                IDENTITY.verify_root(linked, quiet=True)

            xcframework = self.copy_vendor(base / "xcframework")
            (xcframework / "Unexpected.xcframework").mkdir()
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "XCFramework"):
                IDENTITY.verify_root(xcframework, quiet=True)

            binary = self.copy_vendor(base / "binary")
            (binary / "Sources" / "payload.a").write_bytes(b"archive")
            with self.assertRaisesRegex(IDENTITY.SwiftAssemblySourceIdentityError, "unexpected source-tree entry"):
                IDENTITY.verify_root(binary, quiet=True)

    def test_materializer_refuses_to_overwrite_an_accepted_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            destination = self.copy_vendor(Path(temporary) / "accepted")
            before = IDENTITY.tree_digest(destination)
            with self.assertRaisesRegex(MATERIALIZER.MaterializationError, "destination already exists"):
                MATERIALIZER.materialize(Path(temporary) / "unused", destination)
            self.assertEqual(IDENTITY.tree_digest(destination), before)

    def test_offline_verifier_has_an_independent_identity_anchor(self) -> None:
        self.assertEqual(MATERIALIZER.REVISION, IDENTITY.REVISION)
        self.assertEqual(MATERIALIZER.GIT_TREE, IDENTITY.GIT_TREE)
        self.assertEqual(MATERIALIZER.LICENSE_SHA256, IDENTITY.LICENSE_SHA256)
        identity_source = IDENTITY_PATH.read_text(encoding="utf-8")
        self.assertNotIn("subprocess", identity_source)
        self.assertNotIn("urlopen", identity_source)
        self.assertNotIn("git fetch", identity_source)
        self.assertRegex(IDENTITY.EXPECTED_SOURCE_IDENTITY_SHA256, r"^[0-9a-f]{64}$")

    def test_normal_bootstrap_and_build_do_not_materialize_or_acquire_swift_assembly(self) -> None:
        bootstrap = (ROOT / "Scripts" / "bootstrap.sh").read_text(encoding="utf-8")
        project = (ROOT / "MacScope" / "project.yml").read_text(encoding="utf-8")
        self.assertNotIn("materialize_swift_assembly", bootstrap)
        self.assertNotIn("materialize_swift_assembly", project)
        self.assertNotIn("swiftbin/swift-assembly", bootstrap)
        self.assertNotIn("swiftbin/swift-assembly", project)


if __name__ == "__main__":
    unittest.main()
