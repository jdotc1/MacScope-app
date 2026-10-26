#!/usr/bin/env python3
"""Source-boundary contracts for the Release-only Phase 2 Gate runner.

The live branch of ``runIfRequested`` is excluded from the Debug CoreTests binary by
construction. These tests intentionally inspect source order and branch shape; they do not claim
in-process behavioral coverage of that uncompiled Release path.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
APP_ENTRY = ROOT / "MacScope" / "App" / "MacScopeApp.swift"
RUNNER = (
    ROOT
    / "MacScope"
    / "Services"
    / "Phase2"
    / "QualificationGate"
    / "Phase2QualificationGateApplicationRunner.swift"
)
GATE_DIRECTORY = RUNNER.parent


def require_index(source: str, token: str, *, start: int = 0) -> int:
    index = source.find(token, start)
    if index < 0:
        raise AssertionError(f"required source token is absent: {token!r}")
    return index


class Phase2QualificationGateApplicationRunnerSourceBoundaryTests(unittest.TestCase):
    def test_gate_sources_have_no_xctest_or_test_manager_runtime_dependency(self) -> None:
        files = sorted(GATE_DIRECTORY.glob("*.swift"))
        self.assertTrue(files, "qualification gate source directory is empty")
        for path in files:
            source = path.read_text(encoding="utf-8")
            for forbidden in (
                "import XCTest",
                "XCTestCase",
                "XCTestObservation",
                "TestManager",
                "XCTRunner",
            ):
                self.assertNotIn(forbidden, source, f"{path.name}: {forbidden}")

    def test_application_entry_routes_gate_before_every_other_launch_mode(self) -> None:
        source = APP_ENTRY.read_text(encoding="utf-8")
        gate = require_index(
            source, "Phase2QualificationGateApplicationRunner.runIfRequested"
        )
        for token in (
            "MCPLauncher.requestedBinary",
            "CLIRunner.request",
            "MacScopeApp.main()",
        ):
            self.assertLess(gate, require_index(source, token), token)

    def test_debug_rejection_precedes_uncompiled_live_execution(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        debug = require_index(source, "#if DEBUG")
        for token in (
            "Task { @MainActor in",
            "Phase2QualificationGateBuildAuthority.collectCurrent()",
            ".executeSignedStandardGate(selector: request.selector)",
        ):
            self.assertLess(debug, require_index(source, token), token)

    def test_authority_proof_branch_cannot_dispatch_or_publish_evidence(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        proof_start = require_index(source, "case .authorityProof:")
        canary_start = require_index(
            source, "case .installedCanary:", start=proof_start + 1
        )
        proof_branch = source[proof_start:canary_start]

        for forbidden in (
            "OneShotClaim",
            "Canary",
            "executeSignedStandardGate",
            "executeStandard",
            "sendRequest",
            "performRequest",
            "publish",
            "write",
            "spawn",
            "Process(",
        ):
            self.assertNotIn(forbidden, proof_branch)
        self.assertIn(
            "Phase2QualificationGateBuildAuthority.collectCurrent()", proof_branch
        )
        self.assertIn("authority.isCurrent()", proof_branch)

    def test_live_branch_crosses_one_shot_boundary_once_through_composer(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        live_start = require_index(source, "case .liveGate:")
        success_exit = require_index(
            source, "Darwin.exit(EXIT_SUCCESS)", start=live_start + 1
        )
        live_branch = source[live_start:success_exit]

        self.assertEqual(live_branch.count("executeSignedStandardGate("), 1)
        self.assertIn(".executeSignedStandardGate(selector: request.selector)", live_branch)
        for forbidden in (
            "OneShotClaimWriter",
            "executeOneShot",
            "executeStandard",
            "retry",
            "fallback",
        ):
            self.assertNotIn(forbidden, live_branch)

    def test_installed_canary_uses_real_collector_once_without_full_gate(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        canary_start = require_index(source, "case .installedCanary:")
        live_start = require_index(source, "case .liveGate:", start=canary_start + 1)
        canary_branch = source[canary_start:live_start]

        self.assertEqual(canary_branch.count(".collectInstalledCanaryCurrent("), 1)
        self.assertIn(".collectInstalledCanaryCurrent(selector: request.selector)", canary_branch)
        self.assertNotIn(".collectCurrent()", canary_branch)
        self.assertEqual(canary_branch.count(".executeOneShot(session: session)"), 1)
        self.assertIn("session.buildAuthority.isCurrent()", canary_branch)
        self.assertIn("session.captureFreshObservation()", canary_branch)
        for forbidden in (
            "executeSignedStandardGate",
            "Phase2ProductionLiveQualificationExecutor",
            "Phase2ProductionProtocolFixtureExecutor",
            "retry",
            "fallback",
        ):
            self.assertNotIn(forbidden, canary_branch)

    def test_terminal_record_contract_is_canonical_single_line_and_mode_specific(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for required in (
            "options: [.sortedKeys, .withoutEscapingSlashes]",
            "data.append(0x0A)",
            '"schema_version": 1',
            '"status": "authority-verified"',
            '"git_head_commit":',
            '"app_executable_sha256":',
            '"worker_executable_sha256":',
            '"status": "completed"',
            '"status": "canary-completed"',
            '"canary_evidence_sha256":',
            '"report_id":',
            '"verdict":',
            "toStandardError: true",
            "Darwin.exit(EX_USAGE)",
            "Darwin.exit(EX_CONFIG)",
            "Darwin.exit(EX_SOFTWARE)",
        ):
            self.assertIn(required, source)


if __name__ == "__main__":
    unittest.main()
