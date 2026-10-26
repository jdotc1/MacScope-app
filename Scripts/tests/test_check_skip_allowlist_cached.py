"""dev_loop's cached skip-allowlist gate: fails in the lane, skips the 8 s scan when nothing changed."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
WRAPPER = ROOT / "Scripts/qualification/check_skip_allowlist_cached.py"


class CachedSkipAllowlistGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        (self.repo / "MacScope/Tests/CoreTests").mkdir(parents=True)
        (self.repo / "docs/qualification").mkdir(parents=True)
        (self.repo / "Scripts").mkdir()
        shutil.copy(ROOT / "Scripts/check_test_skip_allowlist.py", self.repo / "Scripts/check_test_skip_allowlist.py")
        self.stamp = self.repo / "stamp"
        self.write_test("final class One { func testAllowed() throws { throw XCTSkip(\"host\") } }")
        self.write_allowlist([{"file": "CoreTests/One.swift", "method": "testAllowed", "reason": "Requires an explicit host opt-in and a live signed worker; the delivery lane runs it with zero skips."}])

    def write_test(self, body: str) -> None:
        time.sleep(0.01)
        (self.repo / "MacScope/Tests/CoreTests/One.swift").write_text(body, encoding="utf-8")

    def write_allowlist(self, entries: list[dict[str, str]]) -> None:
        (self.repo / "docs/qualification/skip-allowlist.json").write_text(json.dumps({
            "schemaVersion": 2, "countingRule": "direct-and-file-local-transitive-swift-test-methods",
            "knownGap": "x", "entries": entries}), encoding="utf-8")

    def gate(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, "-B", str(WRAPPER), str(self.repo), str(self.stamp)],
                              capture_output=True, text=True)

    def test_pass_writes_a_stamp_and_a_new_unallowlisted_skip_fails(self) -> None:
        result = self.gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.stamp.is_file())
        self.write_test("final class One { func testAllowed() throws { throw XCTSkip(\"host\") }\n"
                        "  func testAdded() throws { throw XCTSkip(\"x\") } }")
        result = self.gate()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("CoreTests/One.swift::testAdded", result.stderr)
        self.assertIn("MACSCOPE_DEV_SKIP_ALLOWLIST_CHECK=1", result.stderr)

    def test_unchanged_inputs_reuse_the_stamp(self) -> None:
        self.assertEqual(self.gate().returncode, 0)
        before = self.stamp.stat().st_mtime_ns
        self.assertEqual(self.gate().returncode, 0)
        self.assertEqual(self.stamp.stat().st_mtime_ns, before)

    def test_absent_allowlist_skips_without_stamp(self) -> None:
        (self.repo / "docs/qualification/skip-allowlist.json").unlink()
        result = self.gate()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "skip allowlist absent; check skipped")
        self.assertEqual(result.stderr, "")
        self.assertFalse(self.stamp.exists())

    def test_dev_loop_runs_the_gate_before_taking_the_lock(self) -> None:
        script = (ROOT / "Scripts/dev_loop.sh").read_text(encoding="utf-8")
        gate = script.index('check_skip_allowlist_cached.py" \\\n')
        self.assertLess(gate, script.index('heavy_gate_lock.py" acquire'))


if __name__ == "__main__":
    unittest.main()
