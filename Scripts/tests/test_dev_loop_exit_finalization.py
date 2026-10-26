#!/usr/bin/env python3
"""dev_loop's EXIT finalization: a failed receipt registration is never a silent success.

Runs the exact exit-finalization block from Scripts/dev_loop.sh with a stub
receipt helper and lock release; no build, cache or lock is touched.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
BLOCK = SCRIPT[SCRIPT.index("# >>> exit-finalization"):SCRIPT.index("# <<< exit-finalization")]


class DevLoopExitFinalizationTests(unittest.TestCase):
    def run_body(self, body_status: int, finish_status: int, receipt_root: str = "/r"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "qualification").mkdir()
            (root / "qualification/dev_native_receipts.py").write_text(
                f"import sys\nprint('finish called', file=sys.stderr)\nsys.exit({finish_status})\n")
            released = root / "released"
            program = "\n".join([
                "set -euo pipefail",
                f"SCRIPT_DIR={root}", "DERIVED_DATA=/d", f"NATIVE_RECEIPT_ROOT={receipt_root}",
                f"release_lock() {{ touch {released}; }}",
                BLOCK,
                "trap on_exit EXIT",
                f"exit {body_status}",
            ])
            result = subprocess.run(["/bin/bash", "-c", program], capture_output=True, text=True, timeout=30)
            return result, released.exists()

    def test_finalization_failure_fails_a_successful_run_and_releases_the_lock(self):
        result, released = self.run_body(0, 1)
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("native receipt finalization failed", result.stderr)
        self.assertTrue(released)

    def test_finalization_failure_keeps_an_already_failing_status(self):
        result, released = self.run_body(7, 1)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("native receipt finalization failed", result.stderr)
        self.assertTrue(released)

    def test_successful_finalization_keeps_the_run_status(self):
        for body in (0, 5):
            result, released = self.run_body(body, 0)
            self.assertEqual(result.returncode, body, result.stderr)
            self.assertIn("finish called", result.stderr)
            self.assertNotIn("finalization failed", result.stderr)
            self.assertTrue(released)

    def test_receipt_free_runs_do_not_finalize(self):
        result, released = self.run_body(0, 1, receipt_root="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("finish called", result.stderr)
        self.assertTrue(released)

    def test_no_failure_suppression_remains(self):
        self.assertNotIn("|| true", BLOCK)


if __name__ == "__main__":
    unittest.main()
