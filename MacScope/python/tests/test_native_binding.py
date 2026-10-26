"""Portable tests for the native suite's receipt-bound executable selection.

No MacScope build is needed: a temporary executable file stands in for the app binary.
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_binding as nb  # noqa: E402


class NativeBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name).resolve()
        self.app = self.root / "Release" / "MacScope.app"
        self.executable = self.app / "Contents" / "MacOS" / "MacScope"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_bytes(b"\xcf\xfa\xed\xfe stand-in executable")
        self.executable.chmod(0o755)
        self.digest = hashlib.sha256(self.executable.read_bytes()).hexdigest()

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def write_receipt(self, **overrides) -> str:
        document = {
            "receipt_kind": nb.RECEIPT_KIND,
            "schema_version": 2,
            "source": {"commit": "0" * 40},
            "artifacts": {
                "app": {
                    "path": str(self.app),
                    "closed_tree_sha256": "1" * 64,
                    "executable_sha256": self.digest,
                }
            },
        }
        document.update(overrides)
        path = self.root / "NativeLivePreparation.receipt.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return str(path)

    def test_unbound_environment_returns_none(self) -> None:
        self.assertIsNone(nb.resolve_binding({}))
        # The generic client variable is not a binding and is never used as a fallback.
        self.assertIsNone(nb.resolve_binding({"MACSCOPE_BINARY": str(self.executable)}))
        self.assertIn(nb.RECEIPT_ENV, nb.UNBOUND_REASON)

    def test_receipt_binding_verifies_executable_digest(self) -> None:
        receipt = self.write_receipt()
        binding = nb.resolve_binding({nb.RECEIPT_ENV: receipt})
        self.assertEqual(binding.executable, str(self.executable))
        self.assertEqual(binding.sha256, self.digest)
        self.assertEqual(binding.receipt, receipt)
        self.assertEqual(binding.source_commit, "0" * 40)

    def test_receipt_digest_mismatch_is_an_error(self) -> None:
        receipt = self.write_receipt()
        self.executable.write_bytes(b"rebuilt bytes")
        with self.assertRaisesRegex(nb.BindingError, "does not match its recorded digest"):
            nb.resolve_binding({nb.RECEIPT_ENV: receipt})

    def test_malformed_receipts_are_errors(self) -> None:
        cases = {
            "kind": {"receipt_kind": "something-else"},
            "schema": {"schema_version": 99},
            "no app": {"artifacts": {}},
            "bad digest": {"artifacts": {"app": {"path": str(self.app), "executable_sha256": "abc"}}},
            "not an app": {"artifacts": {"app": {"path": str(self.root), "executable_sha256": self.digest}}},
        }
        for label, overrides in cases.items():
            with self.subTest(label):
                with self.assertRaises(nb.BindingError):
                    nb.resolve_binding({nb.RECEIPT_ENV: self.write_receipt(**overrides)})
        with self.assertRaises(nb.BindingError):
            nb.resolve_binding({nb.RECEIPT_ENV: str(self.root / "missing.json")})

    def test_missing_app_executable_is_an_error(self) -> None:
        receipt = self.write_receipt()
        self.executable.unlink()
        with self.assertRaisesRegex(nb.BindingError, "does not exist"):
            nb.resolve_binding({nb.RECEIPT_ENV: receipt})

    def test_executable_and_digest_pair(self) -> None:
        binding = nb.resolve_binding({
            nb.EXECUTABLE_ENV: str(self.executable),
            nb.EXECUTABLE_SHA256_ENV: self.digest.upper(),
        })
        self.assertEqual(binding.executable, str(self.executable))
        self.assertIsNone(binding.receipt)
        with self.assertRaisesRegex(nb.BindingError, "must be set together"):
            nb.resolve_binding({nb.EXECUTABLE_ENV: str(self.executable)})
        with self.assertRaisesRegex(nb.BindingError, "does not match"):
            nb.resolve_binding({nb.EXECUTABLE_ENV: str(self.executable), nb.EXECUTABLE_SHA256_ENV: "f" * 64})

    def test_non_executable_or_relative_paths_are_errors(self) -> None:
        self.executable.chmod(0o644)
        with self.assertRaisesRegex(nb.BindingError, "not an executable regular file"):
            nb.resolve_binding({nb.EXECUTABLE_ENV: str(self.executable), nb.EXECUTABLE_SHA256_ENV: self.digest})
        with self.assertRaisesRegex(nb.BindingError, "not an absolute path"):
            nb.resolve_binding({nb.EXECUTABLE_ENV: "MacScope", nb.EXECUTABLE_SHA256_ENV: self.digest})

    def test_both_binding_forms_is_ambiguous(self) -> None:
        with self.assertRaisesRegex(nb.BindingError, "not both"):
            nb.resolve_binding({
                nb.RECEIPT_ENV: self.write_receipt(),
                nb.EXECUTABLE_ENV: str(self.executable),
                nb.EXECUTABLE_SHA256_ENV: self.digest,
            })

    def test_process_environment_is_the_default(self) -> None:
        saved = {key: os.environ.pop(key) for key in (nb.RECEIPT_ENV, nb.EXECUTABLE_ENV, nb.EXECUTABLE_SHA256_ENV) if key in os.environ}
        try:
            self.assertIsNone(nb.resolve_binding())
        finally:
            os.environ.update(saved)


if __name__ == "__main__":
    unittest.main()
