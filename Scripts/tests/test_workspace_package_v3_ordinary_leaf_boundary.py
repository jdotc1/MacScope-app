#!/usr/bin/env python3
"""Freeze package-v3 digest and ordinary-leaf filesystem authority."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "MacScope/Models/AnalysisModels.swift"
PROBE = ROOT / "MacScope/Services/Documents/WorkspacePackageVersionProbe.swift"


def read_split_source(path: Path) -> str:
    """Read a primary Swift source plus its `<Stem>+<Topic>.swift` extension files."""
    parts = [path, *sorted(path.parent.glob(f"{path.stem}+*.swift"))]
    return "\n".join(part.read_text(encoding="utf-8") for part in parts)


def bounded_section(text: str, start: str, end: str) -> str:
    start_index = text.find(start)
    if start_index < 0:
        raise AssertionError(f"missing source boundary start: {start}")
    end_index = text.find(end, start_index + len(start))
    if end_index < 0:
        raise AssertionError(f"missing source boundary end: {end}")
    return text[start_index:end_index]


class WorkspacePackageVersion3OrdinaryLeafBoundaryTests(unittest.TestCase):
    def test_v3_digest_guard_is_version_scoped(self) -> None:
        package = read_split_source(PACKAGE)
        manifest_validation = bounded_section(
            package,
            "static func validateManifest(",
            "private static func validateAttachmentData(",
        )
        for required in (
            "manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion",
            "!isCanonicalSHA256(binary.fileHash)",
            "throw PackageError.invalidAttachmentHash(binary.attachmentRelativePath)",
        ):
            self.assertIn(required, manifest_validation)
        digest_helper = bounded_section(
            package,
            "private static func isCanonicalSHA256(",
            "static func reconstructionAttachmentURL(",
        )
        self.assertIn("value.utf8.count == 64", digest_helper)
        self.assertIn('UInt8(ascii: "a")...UInt8(ascii: "f")', digest_helper)

    def test_ordinary_leaf_reads_are_no_follow_stable_and_rejected_aliases_bind_evidence(self) -> None:
        package = read_split_source(PACKAGE)
        read_manifest = bounded_section(
            package,
            "static func readManifest(",
            "static func openPackage(",
        )
        open_package = bounded_section(
            package,
            "static func openPackage(",
            "private static func packageContents(",
        )
        self.assertIn("readRegularFile(", read_manifest)
        self.assertNotIn("Data(contentsOf:", read_manifest)
        self.assertGreaterEqual(open_package.count("readRegularFile("), 2)
        self.assertNotIn("Data(contentsOf:", open_package)

        ordinary_reader = bounded_section(
            package,
            "static func readRegularFile(",
            "private static func openRegularFileWithoutFollowingSymlinks(",
        )
        self.assertIn("before.st_nlink == 1", ordinary_reader)
        self.assertIn("stableStatus(before, after)", ordinary_reader)
        no_follow = bounded_section(
            package,
            "private static func openRegularFileWithoutFollowingSymlinks(",
            "private static func resolvedTrustRoot(",
        )
        self.assertGreaterEqual(no_follow.count("O_NOFOLLOW"), 3)
        self.assertIn("Darwin.openat", no_follow)

        probe = PROBE.read_text(encoding="utf-8")
        self.assertNotIn("requiresSingleLink: Bool = false", probe)
        # Manifest, ordinary attachments, and the instruction sidecar (#436).
        self.assertEqual(probe.count("requiresSingleLink: true"), 3)
        self.assertEqual(probe.count("requiresSingleLink: false"), 4)
        reconstruction_probe = bounded_section(
            probe,
            "if manifest.analysisFormatVersion == WorkspacePackageManifest.reconstructionFormatVersion {",
            "let declaredPaths = Set(manifest.binaries.map(\\.attachmentRelativePath))",
        )
        self.assertEqual(reconstruction_probe.count("requiresSingleLink: false"), 4)
        self.assertNotIn("requiresSingleLink: true", reconstruction_probe)
        self.assertGreaterEqual(
            reconstruction_probe.count("metadata.linkCount != 1"),
            2,
        )
        self.assertIn("guard !reconstructionHasHardLinkAlias else", reconstruction_probe)
        self.assertIn(
            'reason: "package-reconstruction-hard-link-unsupported"',
            reconstruction_probe,
        )


if __name__ == "__main__":
    unittest.main()
