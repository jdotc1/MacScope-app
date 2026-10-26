#!/usr/bin/env python3

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY_ROOT / "Scripts/qualification/stage_timing.py"


class QualificationStageTimingTests(unittest.TestCase):
    def _run(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/usr/bin/python3", "-B", str(TOOL), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_records_success_failure_attempts_and_combined_log(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / "run"
            run.mkdir()
            receipt = run / "STAGE_TIMINGS.json"
            initialized = self._run(
                "init",
                "--receipt",
                str(receipt),
                "--source-commit",
                "a" * 40,
                "--source-tree",
                "b" * 40,
                "--mode",
                "full-test",
                "--run-root",
                str(run),
            )
            self.assertEqual(initialized.returncode, 0, initialized.stderr)

            log = run / "build.log"
            succeeded = self._run(
                "run",
                "--receipt",
                str(receipt),
                "--stage",
                "xcode.debug",
                "--combined-log",
                str(log),
                "--",
                "/bin/sh",
                "-c",
                "printf 'timing summary\\n'; printf 'diagnostic\\n' >&2",
            )
            self.assertEqual(succeeded.returncode, 0, succeeded.stderr)
            self.assertEqual(succeeded.stdout, "timing summary\ndiagnostic\n")
            self.assertEqual(log.read_text(), succeeded.stdout)

            failed = self._run(
                "run",
                "--receipt",
                str(receipt),
                "--stage",
                "xcode.debug",
                "--",
                "/bin/sh",
                "-c",
                "exit 7",
            )
            self.assertEqual(failed.returncode, 7)
            document = json.loads(receipt.read_text(encoding="utf-8"))
            self.assertEqual([stage["attempt"] for stage in document["stages"]], [1, 2])
            self.assertEqual([stage["exit_code"] for stage in document["stages"]], [0, 7])
            self.assertTrue(all(stage["duration_ns"] >= 0 for stage in document["stages"]))
            self.assertEqual(document["clock"], "time.monotonic_ns")

    def test_init_rejects_a_different_exact_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary).resolve()
            receipt = run / "STAGE_TIMINGS.json"
            common = (
                "init",
                "--receipt",
                str(receipt),
                "--source-tree",
                "b" * 40,
                "--mode",
                "prepare",
                "--run-root",
                str(run),
            )
            self.assertEqual(
                self._run(*common, "--source-commit", "a" * 40).returncode, 0
            )
            rejected = self._run(*common, "--source-commit", "c" * 40)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("source differs", rejected.stderr)


if __name__ == "__main__":
    unittest.main()
