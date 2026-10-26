#!/usr/bin/env python3
"""Synthetic assertions for resource derivatives; never reads production cache."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1] / "qualification/derive_sleigh_resource_cache.py"
spec = importlib.util.spec_from_file_location("resource_derivative", TOOL)
DERIVE = importlib.util.module_from_spec(spec)
spec.loader.exec_module(DERIVE)


class ResourceDerivativeTests(unittest.TestCase):
    def test_delta_accepts_overlay_and_metadata_but_rejects_native_source(self):
        source = "ThirdParty/SleighNative/Source/sleigh/CMakeLists.txt"
        resource = DERIVE.RESOURCE + "AARCH64.sla"
        before = [(source, "100644", "a"), (resource, "100644", "b")]
        after = [(source, "100644", "a"), (resource, "100644", "c")]
        self.assertEqual(DERIVE.admit_delta(before, after), {resource})
        with self.assertRaises(DERIVE.DEV.Unavailable):
            DERIVE.admit_delta(before, [(source, "100644", "x"), after[1]])
        with self.assertRaises(DERIVE.DEV.Unavailable):
            DERIVE.admit_delta(before, [before[0]])

    def test_package_language_change_is_rejected_even_with_governed_overlay_change(self):
        resource = DERIVE.RESOURCE + "AARCH64.sla"
        package_language = "ThirdParty/SleighNative/package/" + DERIVE.LANGUAGE + "AARCH64.sla"
        before = [(resource, "100644", "overlay-old"), (package_language, "100644", "package-old")]
        after = [(resource, "100644", "overlay-new"), (package_language, "100644", "package-new")]
        with self.assertRaises(DERIVE.DEV.Unavailable):
            DERIVE.admit_delta(before, after)

    def test_derivation_rejects_archive_source_baseline_and_compiler_authority_changes(self):
        resource = DERIVE.RESOURCE + "AARCH64.sla"
        for authority in ("MATERIALIZATION.json", "CP1_BASELINE.json", "METADATA.sleigh.txt",
                          "LICENSE.sleigh-apache-2.0.txt", "NOTICE.ghidra.txt", "DISCLAIMER.ghidra.md",
                          "Source/MATERIALIZATION.json", "package/bin/sleigh", "package/lib/libdecomp.a"):
            with self.subTest(authority=authority):
                path = "ThirdParty/SleighNative/" + authority
                before = [(resource, "100644", "old"), (path, "100644", "authority")]
                after = [(resource, "100644", "new"), (path, "100644", "changed")]
                with self.assertRaises(DERIVE.DEV.Unavailable):
                    DERIVE.admit_delta(before, after)
        baseline = {"schemaVersion": 1, "compiler": {"sha256": "compiler"},
                    "baseline": {"artifactSha256": "archive"}, "patched": {"changedFiles": {
                        "AARCH64.sla": {"baselineSha256": "upstream", "patchedSha256": "old"}}}}
        changed = {**baseline, "patched": {"changedFiles": {
            "AARCH64.sla": {"baselineSha256": "upstream", "patchedSha256": "new"}}}}
        DERIVE.admit_pin_delta(baseline, changed)
        for key in ("compiler", "baseline"):
            with self.subTest(pin=key), self.assertRaises(DERIVE.DEV.Unavailable):
                DERIVE.admit_pin_delta(baseline, {**changed, key: {"sha256": "changed"}})
        changed["patched"]["changedFiles"]["AARCH64.sla"]["baselineSha256"] = "changed"
        with self.assertRaises(DERIVE.DEV.Unavailable):
            DERIVE.admit_pin_delta(baseline, changed)

    def test_digest_derivation_never_hashes_retained_file_and_rejects_metadata_drift(self):
        with tempfile.TemporaryDirectory() as scratch:
            payload = Path(scratch)
            (payload / "native.a").write_bytes(b"native")
            (payload / "resource.sla").write_bytes(b"new")
            prior = [{"kind": "file", "path": "native.a", "size": 6, "executable": False, "sha256": "a" * 64},
                     {"kind": "file", "path": "resource.sla", "size": 3, "executable": False, "sha256": "b" * 64}]
            replacement = {"resource.sla": {**prior[1], "sha256": "c" * 64}}
            with mock.patch.object(DERIVE.CACHE, "sha256", side_effect=AssertionError("unchanged bytes hashed")):
                result = DERIVE.records_with_evidence(payload, prior, replacement)
            self.assertEqual([record["sha256"] for record in result], ["a" * 64, "c" * 64])
            (payload / "native.a").write_bytes(b"changed size")
            with self.assertRaises(DERIVE.DEV.DevCacheError):
                DERIVE.records_with_evidence(payload, prior, replacement)

    def test_source_memo_reuses_exact_blob_and_reads_only_new_blob(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            memo = root / ".memo"
            memo.mkdir()
            old = {"path": "same", "mode": "100644", "blob_oid": "old", "sha256": "a" * 64, "size": 1}
            DERIVE.DEV.write_memo(memo / "records-parent.json", {"schema_version": 1, "records": [old]})
            new = {"path": "new", "mode": "100644", "blob_oid": "new", "sha256": "b" * 64, "size": 1}
            entries = [("same", "100644", "old"), ("new", "100644", "new")]
            with mock.patch.object(DERIVE.DEV, "blob_records", return_value=[new]) as reader:
                self.assertEqual(DERIVE.prime_records(root, root, entries, allow_new=True), [old, new])
            reader.assert_called_once_with(root, [entries[1]])
            with self.assertRaises(DERIVE.DEV.Unavailable):
                DERIVE.prime_records(root, root, [("unknown", "100644", "x")], allow_new=False)


if __name__ == "__main__":
    unittest.main()
