#!/usr/bin/env python3
"""dev_loop native receipt roots chain across runs; synthetic DerivedData, no builds."""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


receipts = load("dev_native_receipts", "Scripts/qualification/dev_native_receipts.py")


class DevNativeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.derived = Path(self.temp.name).resolve() / "DerivedData"
        self.derived.mkdir(mode=0o700)

    def tearDown(self):
        self.temp.cleanup()

    def publish_staged(self, root):
        (Path(root) / "staged-sleigh-0123.json").write_text("{}\n")

    def test_plain_run_without_registration_stays_receipt_free(self):
        self.assertEqual(receipts.begin(self.derived, register=False), {})
        self.assertEqual(list(self.derived.iterdir()), [])

    def test_native_verbose_then_plain_run_admits_the_staged_copy(self):
        verbose = receipts.begin(self.derived, register=True)
        first = verbose["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        self.assertEqual(verbose["MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE"], "shared-view")
        self.assertNotIn("MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT", verbose)
        self.assertEqual(stat.S_IMODE(Path(first).stat().st_mode), 0o700)
        self.publish_staged(first)
        self.assertTrue(receipts.finish(self.derived, first))

        plain = receipts.begin(self.derived, register=False)
        self.assertEqual(plain["MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE"], "shared-view")
        self.assertEqual(plain["MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT"], first)
        self.assertNotEqual(plain["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"], first,
                            "source-identity receipts stay per run")

        # The stager resolves the staged copy's receipt through the prior root.
        stager = load("stage_verified_package_for_receipts",
                      "Scripts/native-decompiler-xpc/stage_verified_package.py")
        staged = self.derived / "Build/Products/Debug/NativeDecompilerPackage"
        with mock.patch.dict(os.environ, plain):
            current = stager._staged_receipt_path(staged)
            prior = stager._staged_receipt_path(staged, plain["MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT"])
        self.assertEqual(current.parent, Path(plain["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]))
        self.assertEqual(prior.parent, Path(first))

    def test_registration_moves_only_when_a_run_publishes(self):
        first = receipts.begin(self.derived, register=True)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        self.publish_staged(first)
        receipts.finish(self.derived, first)
        reused = receipts.begin(self.derived, register=False)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        self.assertFalse(receipts.finish(self.derived, reused), "a run that reused the copy keeps the old root")
        self.assertEqual(receipts.current(self.derived), Path(first))
        restaged = receipts.begin(self.derived, register=False)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        self.publish_staged(restaged)
        self.assertTrue(receipts.finish(self.derived, restaged))
        self.assertEqual(receipts.begin(self.derived, register=False)["MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT"],
                         restaged)

    def test_a_partial_publication_carries_forward_the_other_staged_receipts(self):
        # Seen live: the golden runner published only its own staged copy, the
        # pointer moved, and the XPC service copy's receipt was orphaned.
        first = receipts.begin(self.derived, register=True)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        (Path(first) / "staged-sleigh-xpc.json").write_text("xpc\n")
        (Path(first) / "staged-sleigh-golden.json").write_text("old golden\n")
        receipts.finish(self.derived, first)
        second = receipts.begin(self.derived, register=False)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        (Path(second) / "staged-sleigh-golden.json").write_text("new golden\n")
        self.assertTrue(receipts.finish(self.derived, second))
        self.assertEqual((Path(second) / "staged-sleigh-xpc.json").read_text(), "xpc\n")
        self.assertEqual((Path(second) / "staged-sleigh-golden.json").read_text(), "new golden\n")
        self.assertEqual(stat.S_IMODE((Path(second) / "staged-sleigh-xpc.json").stat().st_mode), 0o400)

    def test_first_native_verbose_registers_even_before_staging(self):
        root = receipts.begin(self.derived, register=True)["MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT"]
        self.assertTrue(receipts.finish(self.derived, root))
        self.assertEqual(receipts.current(self.derived), Path(root))

    def test_pointer_outside_derived_data_is_refused(self):
        outside = Path(self.temp.name).resolve() / "NativeIdentity.elsewhere"
        outside.mkdir(mode=0o700)
        (self.derived / receipts.POINTER).write_text(str(outside) + "\n")
        with self.assertRaises(receipts.ReceiptRootError):
            receipts.begin(self.derived, register=False)

    def test_shared_receipt_root_is_refused(self):
        root = self.derived / "NativeIdentity.open"
        root.mkdir(mode=0o755)
        root.chmod(0o755)
        with self.assertRaises(receipts.ReceiptRootError):
            receipts.finish(self.derived, str(root))

    def test_dev_loop_chains_receipts_for_every_run_and_registers_on_exit(self):
        script = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        self.assertNotIn("mktemp -d \"${DERIVED_DATA}/NativeIdentity", script)
        begin = script.index("dev_native_receipts.py\" begin")
        self.assertLess(script.index('PREPARED="$(clock)"'), begin)
        self.assertLess(begin, script.index('if [[ "${NATIVE_VERBOSE}" == 1 ]]; then\n  # One native producer'))
        self.assertLess(begin, script.index("build-for-testing ||"))
        self.assertIn("trap on_exit EXIT", script)
        self.assertIn("dev_native_receipts.py\" finish", script)


if __name__ == "__main__":
    unittest.main()
