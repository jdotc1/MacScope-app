"""Focused synthetic coverage for the signed-Debug receipt continuation."""
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import tempfile
import time
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "native-decompiler-xpc/debug_native_receipt.py"
spec = importlib.util.spec_from_file_location("debug_native_receipt", SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class DebugNativeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.receipts = self.root / "receipts"
        self.receipts.mkdir(mode=0o700)
        self.production = "Tools/NativeDecompilerBridge/fixture.cpp"
        self.old_paths = set(m.HARNESS) | {m.CONSUMERS[1], self.production}
        for relative in self.old_paths | set(m.CONSUMERS):
            p = self.repo / relative
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(relative)
        self.profile = self.write_json("profile.json", {"files": [[p, *m.fields(self.repo / p)] for p in sorted(self.old_paths)], "sha256": "old-golden"}, immutable=True)
        self.archive = self.root / "archive.a"
        self.archive.write_bytes(b"native")
        self.entry = self.write_json("entry.json", {"payload_records": [{"path": "libmacscope_native_decompiler_contract.a", "size": 6, "sha256": "native-digest"}]}, immutable=True)
        self.package = self.root / "package"
        self.package.mkdir()
        (self.package / "leaf").write_bytes(b"native-package")
        self.expected = [["leaf", "file", m.fields(self.package / "leaf"), hashlib.sha256(b"native-package").hexdigest()]]
        self.staged = self.write_json("staged.json", {"root": str(self.package), "snapshot": self.expected, "identity": {"package": {"treeSha256": "tree"}}}, immutable=True)
        self.golden_value = {"passed": True, "goldenSourceSHA256": "old-golden", "contractArchiveSHA256": "native-digest", "materializationTreeSHA256": "tree"}
        self.golden = self.write_json("golden.json", self.golden_value)
        self.provenance = self.write_json("provenance.json", {"configuration": "Debug", "qualification_eligible": False, "native_decompiler_golden_result": self.golden_value})
        self.result = self.root / "result.txt"
        self.result.write_text("CP4 production ObjC-to-Swift proof PASS: two fixtures")
        fixtures = []
        for i in range(6):
            p = self.root / f"fixture{i}.bplist"
            p.write_bytes(bytes([i]))
            fixtures.append(m.record(p))
        self.value = {"version": 1, "repository": str(self.repo), "head": "head", "tree": "tree",
                      "oldProfile": m.record(self.profile), "sources": {p: m.fields(self.repo / p) for p in self.old_paths | set(m.CONSUMERS)},
                      "blobs": {p: "blob" for p in set(m.HARNESS) | set(m.CONSUMERS)},
                      "oldGolden": m.record(self.golden), "oldProvenance": m.record(self.provenance),
                      "nativeArchive": m.record(self.archive), "nativeEntry": m.record(self.entry),
                      "stagedReceipt": m.record(self.staged), "oldEmbeddedPackage": m.snapshot(self.package),
                      "oldService": {}, "proof": {"commit": "proved", "scope": "cp4-production-boundary-only", "result": m.record(self.result), "fixtures": fixtures},
                      "toolchain": {key: "fixture-" + key for key in m.TOOLCHAIN_KEYS}, "receiptDirectory": str(self.receipts)}
        self.admission = self.root / "admission.json"
        self.environment = {"CONFIGURATION": "Debug", "MACSCOPE_DEBUG_SOURCE_IDENTITY": "runtime-only",
                            "MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION": m.LIVE, "SDK_NAME": "macosx27.2", m.ENV: str(self.admission)}
        self.environment.update(self.value["toolchain"])
        self.save_admission()

    def write_json(self, name, value, immutable=False):
        p = self.root / name
        p.write_text(json.dumps(value))
        if immutable:
            p.chmod(0o400)
        return p

    def save_admission(self):
        if self.admission.exists():
            self.admission.chmod(0o600)
        self.admission.write_text(json.dumps(self.value))
        self.admission.chmod(0o400)

    def admit(self):
        def git(command, **kwargs):
            value = command[-1]
            return ("head" if value == "HEAD" else "tree" if value == "HEAD^{tree}" else "blob") + "\n"
        with mock.patch.object(m.subprocess, "check_output", side_effect=git), mock.patch.object(m, "production_paths", return_value=self.old_paths):
            return m.admit(self.repo, self.golden, self.environment)

    def test_runtime_evidence_excludes_external_cp4_proof_from_closed_debug_payload(self):
        contents = self.root / "Service.xpc/Contents"
        golden = contents / "Resources/NativeDecompilerBridgeGolden.json"
        golden.parent.mkdir(parents=True)
        leaves = {"info_plist": contents / "Info.plist",
                  "executable": contents / "MacOS/NativeDecompilerXPCService",
                  "code_resources": contents / "_CodeSignature/CodeResources"}
        for name, path in leaves.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        value = dict(self.value)
        value["oldService"] = {name: m.fields(path) for name, path in leaves.items()}
        value["oldProvenance"] = {"fields": [0, 0, 0, 0, 0, time.time_ns(), 0]}
        value["staged"] = {"snapshot": self.expected}
        value["golden"] = self.golden_value
        value["provenance"] = {"native_decompiler_embedded_tree_sha256": "tree",
            "native_decompiler_debug_cp4_supplement": {"historical": "external only"}}
        original_proof = json.loads(json.dumps(value["proof"]))
        with mock.patch.object(m, "verify_package"):
            result = m.runtime_evidence(value, golden)
        self.assertEqual(result, {"native_decompiler_embedded_tree_sha256": "tree"})
        self.assertEqual(value["proof"], original_proof)

    def test_ordinary_mode_requires_explicit_receipt_and_matching_effective_condition(self):
        self.environment["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"] = ""
        with self.assertRaisesRegex(m.DebugReceiptError, "mode differs"):
            self.admit()
        self.value["nativeMode"] = "ordinary"
        self.save_admission()
        self.assertEqual(self.admit()["nativeMode"], "ordinary")
        self.environment["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"] = m.LIVE
        with self.assertRaisesRegex(m.DebugReceiptError, "mode differs"):
            self.admit()

    def test_ordinary_mode_accepts_xcode_omitting_its_empty_setting(self):
        self.value["nativeMode"] = "ordinary"
        self.save_admission()
        del self.environment["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"]
        self.assertEqual(self.admit()["nativeMode"], "ordinary")

    def test_empty_or_incomplete_toolchain_is_refused(self):
        for value in ({}, {"SDK_NAME": "macosx27.2"}):
            self.value["toolchain"] = value
            self.save_admission()
            with self.assertRaisesRegex(m.DebugReceiptError, "complete nonempty toolchain"):
                self.admit()

    def test_new_service_info_plist_identity_is_validated_from_digest_bytes(self):
        expected = {"CFBundleIdentifier": "org.macscope.app.NativeDecompiler",
                    "CFBundleExecutable": "NativeDecompilerXPCService", "CFBundlePackageType": "XPC!"}
        p = self.root / "new-Info.plist"
        for key in expected:
            wrong = dict(expected)
            wrong[key] = "unexpected"
            p.write_bytes(plistlib.dumps(wrong))
            with self.assertRaisesRegex(m.DebugReceiptError, "Info.plist identity differs"):
                m.new_service_digest(p, m.fields(p), "info_plist")
        payload = plistlib.dumps(expected)
        p.write_bytes(payload)
        with mock.patch.object(Path, "read_bytes", return_value=payload) as read:
            self.assertEqual(m.new_service_digest(p, m.fields(p), "info_plist"), hashlib.sha256(payload).hexdigest())
            self.assertEqual(read.call_count, 1)

    def test_accepts_original_golden_with_separate_cp4_scope(self):
        result = self.admit()
        self.assertEqual(result["golden"]["goldenSourceSHA256"], "old-golden")
        self.assertEqual(result["proof"]["scope"], "cp4-production-boundary-only")

    def test_missing_proof_is_refused(self):
        self.result.unlink()
        with self.assertRaises((OSError, m.DebugReceiptError)):
            self.admit()

    def test_tampered_proof_is_refused(self):
        self.result.write_text("CP4 production ObjC-to-Swift proof PASS: forged")
        with self.assertRaises(m.DebugReceiptError):
            self.admit()

    def test_missing_receipt_is_refused(self):
        self.profile.unlink()
        with self.assertRaises((OSError, m.DebugReceiptError)):
            self.admit()

    def test_tampered_receipt_is_refused(self):
        self.profile.chmod(0o600)
        with self.assertRaises(m.DebugReceiptError):
            self.admit()

    def test_production_mismatch_cannot_be_asserted_into_admission(self):
        p = self.repo / self.production
        p.write_text("changed implementation")
        self.value["sources"][self.production] = m.fields(p)
        self.save_admission()
        with self.assertRaisesRegex(m.DebugReceiptError, "production source differs"):
            self.admit()

    def test_release_and_source_qualified_are_refused(self):
        self.environment["CONFIGURATION"] = "Release"
        with self.assertRaises(m.DebugReceiptError):
            self.admit()
        self.environment["CONFIGURATION"] = "Debug"
        self.environment["MACSCOPE_DEBUG_SOURCE_IDENTITY"] = "source-qualified"
        with self.assertRaises(m.DebugReceiptError):
            self.admit()

    def test_unchanged_package_reuses_without_opening_bytes(self):
        prior = m.snapshot(self.package)
        with mock.patch.object(Path, "open", side_effect=AssertionError("old bytes read")):
            m.verify_package(self.package, prior, self.expected, time.time_ns(), self.receipts)

    def test_new_destination_hashes_once_then_reuses_receipt(self):
        prior = m.snapshot(self.package)
        cutoff = time.time_ns()
        new_root = self.root / "new-package"
        shutil.copytree(self.package, new_root)
        m.verify_package(new_root, prior, self.expected, cutoff, self.receipts)
        with mock.patch.object(Path, "open", side_effect=AssertionError("new bytes reread")):
            # Small receipt JSON is deliberately readable; only payload open is forbidden.
            def receipt_bytes(path):
                descriptor = os.open(path, os.O_RDONLY)
                try:
                    return os.read(descriptor, 1024 * 1024)
                finally:
                    os.close(descriptor)
            with mock.patch.object(Path, "read_bytes", receipt_bytes):
                m.verify_package(new_root, prior, self.expected, cutoff, self.receipts)

    def test_amendment_binds_immutable_prior_proof_and_baseline(self):
        prior = self.root / "prior-admission.json"
        shutil.copy2(self.admission, prior)
        self.value["priorAdmission"] = m.record(prior)
        self.save_admission()
        self.admit()
        self.value["oldEmbeddedPackage"] = {}
        self.save_admission()
        with self.assertRaisesRegex(m.DebugReceiptError, "amendment changed"):
            self.admit()

    def test_directory_copy_modes_and_old_metadata_are_bounded(self):
        nested = self.package / "nested"
        nested.mkdir(mode=0o700)
        prior = m.snapshot(self.package)
        expected = [self.expected[0], ["nested", "directory", prior["nested"], None]]
        cutoff = time.time_ns()
        copied = self.root / "directory-copy"
        shutil.copytree(self.package, copied)
        (copied / "nested").chmod(0o755)
        m.verify_package(copied, prior, expected, cutoff, self.receipts)
        (nested / "temporary").touch()
        (nested / "temporary").unlink()
        with self.assertRaisesRegex(m.DebugReceiptError, "old package directory metadata"):
            m.verify_package(self.package, prior, expected, cutoff, self.receipts)

    def test_new_xcode_copy_modes_are_admitted_once(self):
        (self.package / "leaf").chmod(0o600)
        prior = m.snapshot(self.package)
        expected = [["leaf", "file", prior["leaf"], self.expected[0][3]]]
        cutoff = time.time_ns()
        copied = self.root / "xcode-copy"
        shutil.copytree(self.package, copied)
        (copied / "leaf").chmod(0o644)
        m.verify_package(copied, prior, expected, cutoff, self.receipts)
        self.assertEqual(len(list(self.receipts.glob("new-native-leaf-*.json"))), 1)

    def test_copy_mode_widening_refuses_group_write_and_old_inodes(self):
        (self.package / "leaf").chmod(0o600)
        prior = m.snapshot(self.package)
        expected = [["leaf", "file", prior["leaf"], self.expected[0][3]]]
        cutoff = time.time_ns()
        copied = self.root / "unsafe-copy"
        shutil.copytree(self.package, copied)
        (copied / "leaf").chmod(0o664)
        with self.assertRaisesRegex(m.DebugReceiptError, "mode"):
            m.verify_package(copied, prior, expected, cutoff, self.receipts)
        (self.package / "leaf").chmod(0o644)
        with self.assertRaisesRegex(m.DebugReceiptError, "mode"):
            m.verify_package(self.package, prior, expected, cutoff, self.receipts)

    def test_changed_old_inode_is_refused_without_rehash(self):
        prior = m.snapshot(self.package)
        cutoff = time.time_ns()
        (self.package / "leaf").write_bytes(b"tamper-package")
        with mock.patch.object(Path, "open", side_effect=AssertionError("old bytes reread")):
            with self.assertRaisesRegex(m.DebugReceiptError, "old package leaf changed"):
                m.verify_package(self.package, prior, self.expected, cutoff, self.receipts)

    def test_changed_membership_is_refused(self):
        prior = m.snapshot(self.package)
        (self.package / "extra").write_bytes(b"x")
        with self.assertRaisesRegex(m.DebugReceiptError, "membership"):
            m.verify_package(self.package, prior, self.expected, time.time_ns(), self.receipts)


if __name__ == "__main__":
    unittest.main()
