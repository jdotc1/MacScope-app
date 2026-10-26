from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from Scripts.reconstruction import write_execution_report as execution_report
from Scripts.reconstruction_gate_f.canonical_json import load_canonical_json


ROOT = Path(__file__).resolve().parents[2]
EMITTER = ROOT / "Scripts/reconstruction/write_execution_report.py"


class ReconstructionExecutionReportTests(unittest.TestCase):
    qualification_run_id = "task11-local-qualification"
    qualification_run_nonce = "a" * 64
    predecessor_observations_sha256 = "b" * 64

    def run_emitter(self, output: Path, *, result: str, exit_code: int | None) -> subprocess.CompletedProcess[str]:
        argv = [
            "/usr/bin/python3",
            "-B",
            str(EMITTER),
            "--output",
            str(output),
            "--started-at-unix-ms",
            "10",
            "--ended-at-unix-ms",
            "20",
            "--result",
            result,
            "--qualification-run-id",
            self.qualification_run_id,
            "--qualification-run-nonce",
            self.qualification_run_nonce,
            "--predecessor-observations-sha256",
            self.predecessor_observations_sha256,
        ]
        if exit_code is not None:
            argv.extend(("--exit-code", str(exit_code)))
        return subprocess.run(argv, text=True, capture_output=True, check=False)

    def test_emits_one_closed_canonical_pass_report(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "execution.json"
            result = self.run_emitter(output, result="passed", exit_code=0)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                load_canonical_json(output),
                {
                    "ended_at_unix_ms": 20,
                    "exit_code": 0,
                    "predecessor_observations_sha256": self.predecessor_observations_sha256,
                    "qualification_run": {
                        "nonce": self.qualification_run_nonce,
                        "run_id": self.qualification_run_id,
                    },
                    "result": "passed",
                    "schema_version": 2,
                    "started_at_unix_ms": 10,
                    "stress": None,
                },
            )
            self.assertFalse(output.read_bytes().endswith(b"\n"))
            overwrite = self.run_emitter(output, result="passed", exit_code=0)
            self.assertEqual(overwrite.returncode, 1)
            self.assertIn("absent absolute path", overwrite.stderr)

    def test_result_exit_and_timestamp_contradictions_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for index, (result, exit_code) in enumerate(
                (("passed", 1), ("failed", 0), ("unavailable", 1))
            ):
                observed = self.run_emitter(
                    root / f"report-{index}.json",
                    result=result,
                    exit_code=exit_code,
                )
                self.assertEqual(observed.returncode, 1)
            reversed_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(EMITTER),
                    "--output",
                    str(root / "reversed.json"),
                    "--started-at-unix-ms",
                    "20",
                    "--ended-at-unix-ms",
                    "10",
                    "--result",
                    "failed",
                    "--exit-code",
                    "1",
                    "--qualification-run-id",
                    self.qualification_run_id,
                    "--qualification-run-nonce",
                    self.qualification_run_nonce,
                    "--predecessor-observations-sha256",
                    self.predecessor_observations_sha256,
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(reversed_result.returncode, 1)
            self.assertIn("timestamps", reversed_result.stderr)

    def test_missing_or_self_invented_run_authority_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            missing = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(EMITTER),
                    "--output",
                    str(root / "missing.json"),
                    "--started-at-unix-ms",
                    "10",
                    "--ended-at-unix-ms",
                    "20",
                    "--result",
                    "passed",
                    "--exit-code",
                    "0",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(missing.returncode, 2)

            invalid = self.run_emitter(
                root / "invalid.json", result="passed", exit_code=0
            )
            argv = invalid.args
            assert isinstance(argv, list)
            argv[argv.index(self.qualification_run_nonce)] = "not-a-nonce"
            invalid = subprocess.run(
                argv,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(invalid.returncode, 1)
            self.assertIn("coordinator-issued", invalid.stderr)

    def test_publication_is_atomic_create_only_canonical_and_singly_linked(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "execution.json"
            result = self.run_emitter(output, result="passed", exit_code=0)
            self.assertEqual(result.returncode, 0, result.stderr)
            metadata = output.stat()
            self.assertEqual(metadata.st_nlink, 1)
            self.assertEqual(metadata.st_mode & 0o777, 0o600)
            self.assertEqual(
                sorted(path.name for path in root.iterdir()),
                ["execution.json"],
            )

            existing = root / "existing.json"
            existing.write_bytes(b"foreign")
            linked = root / "linked.json"
            os.link(existing, linked)
            with self.assertRaisesRegex(
                execution_report.ExecutionReportError,
                "absent absolute path",
            ):
                execution_report.write_create_only(
                    linked,
                    {
                        "schema_version": 2,
                    },
                )
            self.assertEqual(linked.read_bytes(), b"foreign")

    def test_noncanonical_and_hardlinked_evidence_paths_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real_parent = root / "real"
            real_parent.mkdir()
            linked_parent = root / "linked"
            linked_parent.symlink_to(real_parent, target_is_directory=True)
            with self.assertRaisesRegex(
                execution_report.ExecutionReportError,
                "canonical.*symbolic links",
            ):
                execution_report.write_create_only(
                    linked_parent / "execution.json",
                    {"schema_version": 2},
                )

            source = real_parent / "source.json"
            source.write_bytes(b"{}")
            hardlink = real_parent / "hardlink.json"
            os.link(source, hardlink)
            with self.assertRaisesRegex(
                execution_report.ExecutionReportError,
                "singly linked",
            ):
                execution_report.read_stable_regular(
                    hardlink,
                    label="evidence",
                    maximum_bytes=1024,
                    retain_payload=True,
                )

    def test_passing_native_report_requires_complete_live_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = (
                Path(temporary)
                / execution_report.NATIVE_LIVE_REPORT_NAME
            )
            passed = self.run_emitter(output, result="passed", exit_code=0)
            self.assertEqual(passed.returncode, 1)
            self.assertIn("complete sealed evidence set", passed.stderr)
            self.assertFalse(output.exists())

            failed = self.run_emitter(output, result="failed", exit_code=1)
            self.assertEqual(failed.returncode, 0, failed.stderr)
            self.assertEqual(load_canonical_json(output)["result"], "failed")

    def test_native_test_vector_requires_one_exact_executed_pass(self) -> None:
        selector = (
            "CoreTests/NativeDecompilerLiveXPCTests/"
            "testSignedServiceHonorsSupervisionAndRelaunchContract"
        )
        test_case = {
            "nodeType": "Test Case",
            "name": "testSignedServiceHonorsSupervisionAndRelaunchContract()",
            "result": "Passed",
            "children": [],
        }
        document = {
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "name": "CoreTests",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "name": "NativeDecompilerLiveXPCTests",
                            "children": [test_case],
                        }
                    ],
                }
            ]
        }
        execution_report.validate_exact_native_test_results(document, selector)

        document["testNodes"][0]["children"][0]["children"].append(dict(test_case))
        with self.assertRaisesRegex(
            execution_report.ExecutionReportError,
            "exactly one",
        ):
            execution_report.validate_exact_native_test_results(document, selector)

    def test_exit_code_is_a_real_shell_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for offset, exit_code in enumerate((-1, 256)):
                result = self.run_emitter(
                    root / f"invalid-{offset}.json",
                    result="failed",
                    exit_code=exit_code,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn("shell status range", result.stderr)


if __name__ == "__main__":
    unittest.main()
