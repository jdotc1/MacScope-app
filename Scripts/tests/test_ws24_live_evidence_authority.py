#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts" / "ws24_emit_installed_qualification_report.py"


def load_module():
    specification = importlib.util.spec_from_file_location(
        "ws24_emit_installed_qualification_report_live_authority",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load WS-24 report script")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


ws24_report = load_module()


class WS24LiveEvidenceAuthorityTests(unittest.TestCase):
    source_commit = "1" * 40
    source_tree = "2" * 40
    installed_digest = "a" * 64

    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def normalize(self, item: dict[str, object]) -> list[dict[str, object]]:
        return ws24_report.normalize_input_evidence(
            [item],
            expected_source_commit=self.source_commit,
            expected_source_tree=self.source_tree,
            expected_installed_executable_sha256=self.installed_digest,
        )

    def descriptor(self, path: Path) -> dict[str, object]:
        return {
            "kind": ws24_report.LIVE_EXECUTION_REPORT_KIND,
            "path": str(path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }

    def attempt(
        self,
        *,
        index: int,
        scenario: str,
        seed: int | None,
        peak_memory: float | None = None,
    ) -> dict[str, object]:
        return {
            "attemptIndex": index,
            "endedAtUnixMilliseconds": index * 10,
            "exitCode": 0,
            "failure": None,
            "peakResidentMemoryMegabytes": peak_memory,
            "scenario": scenario,
            "seed": seed,
            "startedAtUnixMilliseconds": (index - 1) * 10,
            "timedOut": False,
        }

    def report(self, gate: str) -> Path:
        if gate in {"installed-launch-smoke", "direct-debugger-transport-contracts"}:
            attempts = [self.attempt(index=1, scenario=gate, seed=None)]
        elif gate in ws24_report.STRESS_GATES:
            attempts = [
                self.attempt(index=index, scenario=gate, seed=index)
                for index in range(1, 11)
            ]
        else:
            attempts = [
                self.attempt(
                    index=index,
                    scenario=scenario,
                    seed=(scenario_offset * 100) + index,
                    peak_memory=128.0,
                )
                for scenario_offset, scenario in enumerate(
                    sorted(ws24_report.STRESS_GATES), start=1
                )
                for index in range(1, 11)
            ]
        path = self.root / f"{gate}.json"
        path.write_text(
            json.dumps(
                {
                    "attempts": attempts,
                    "gate": gate,
                    "installedExecutableSHA256": self.installed_digest,
                    "schemaVersion": 1,
                    "sourceCommit": self.source_commit,
                    "sourceTree": self.source_tree,
                },
                sort_keys=True,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )
        return path

    def test_every_non_ui_live_gate_rejects_arbitrary_text_with_matching_digest(self) -> None:
        for gate in sorted(ws24_report.LIVE_EXECUTION_GATES):
            with self.subTest(gate=gate):
                path = self.root / f"{gate}.txt"
                path.write_text("passed\n", encoding="utf-8")
                with self.assertRaisesRegex(
                    ws24_report.ReportError,
                    "invalid JSON",
                ):
                    self.normalize(
                        {"gate": gate, "proofArtifacts": [self.descriptor(path)]}
                    )

    def test_caller_cannot_author_live_status_or_accepted_attempt_count(self) -> None:
        gate = "direct-debugger-transport-contracts"
        path = self.report(gate)
        with self.assertRaisesRegex(
            ws24_report.ReportError,
            r"unknown=\['acceptedAttempts', 'status'\]",
        ):
            self.normalize(
                {
                    "acceptedAttempts": 999,
                    "gate": gate,
                    "proofArtifacts": [self.descriptor(path)],
                    "status": "passed",
                }
            )

    def test_stress_authority_is_derived_from_exact_physical_attempts(self) -> None:
        gate = "repeated-restart-stress"
        path = self.report(gate)

        normalized = self.normalize(
            {"gate": gate, "proofArtifacts": [self.descriptor(path)]}
        )[0]

        self.assertEqual(normalized["status"], "passed")
        self.assertEqual(normalized["acceptedAttempts"], 10)
        self.assertEqual(normalized["attemptSeeds"], list(range(1, 11)))
        self.assertEqual(normalized["durationMilliseconds"], 100)
        self.assertEqual(normalized["failureCount"], 0)

    def test_production_cli_exposes_no_signing_guard_bypass(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("--skip-signing-guard", source)
        self.assertNotIn("skip_signing_guard", source)


if __name__ == "__main__":
    unittest.main()
