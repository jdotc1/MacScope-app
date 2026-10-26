#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
    bundle_tree_digests,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py"
RUN_ID = "combined-head-operability"
RUN_NONCE = "9" * 64
# BridgeFixture starts with an absent destination. Use its actual canonical
# observation, not an arbitrary digest now rejected by installer begin.
PREDECESSOR_SHA256 = hashlib.sha256(
    canonical_bytes({"identity": None, "present": False})
).hexdigest()
SOURCE_COMMIT = "1" * 40
SOURCE_TREE = "2" * 40
EXPOSED_NS = 2_000_000_000
EXPECTED_BUNDLE_IDS = {
    "MacScope": "org.macscope.app",
    "AnalysisWorkerXPCService": "org.macscope.app.AnalysisWorker",
    "AIAgentWorkerXPCService": "org.macscope.app.AIAgentWorker",
    "NativeDecompilerXPCService": "org.macscope.app.NativeDecompiler",
    "ShellBrokerXPCService": "org.macscope.app.ShellBroker",
}


def load_module():
    specification = importlib.util.spec_from_file_location(
        "ws24_emit_installed_qualification_report",
        SCRIPT,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load WS-24 report script")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


ws24_report = load_module()


class BridgeFixture:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.developer_dir = self.root / "Xcode.app/Contents/Developer"
        self.developer_dir.mkdir(parents=True)
        self.applications = self.root / "Applications"
        self.applications.mkdir()
        self.source_app = self.root / "Release/MacScope.app"
        self.installed_app = self.applications / "MacScope.app"
        self.candidate_identity = self.root / "candidate.json"
        self.artifact_parent = self.root / "installer-artifacts"
        self.artifact_parent.mkdir()
        self.artifact_root = self.artifact_parent / "acceptance"
        self.output_root = self.root / "qualification-evidence"
        self.output_root.mkdir()
        self.output = self.output_root / "WS24.aggregate.json"
        self.evidence_json = self.root / "live-evidence.json"
        self.evidence_json.write_bytes(b"[]")
        self._make_app(self.source_app)
        self._write_candidate()
        self._begin_install()
        self.pending_state = (
            self.applications
            / f".MacScope.pending-{self.candidate_digest}"
            / "transaction.json"
        )
        self.state = decode_canonical_bytes(self.pending_state.read_bytes())
        if self.state["exposed_at_unix_ns"] != EXPOSED_NS:
            raise AssertionError(f"unexpected exposure: {self.state['exposed_at_unix_ns']}")
        self.full_surface_report = self.root / "inputs/full-surface.json"
        self.legacy_grid_report = self.root / "inputs/forced-legacy-grid.json"
        self.native_xpc_report = (
            self.root / "inputs/NativeDecompilerLiveXPC.execution-report.json"
        )
        self.full_surface_report.parent.mkdir()
        self._write_json(
            self.full_surface_report,
            self.shell_report(ws24_report.FULL_SURFACE_MODE, generated=3_000),
        )
        self._write_json(
            self.legacy_grid_report,
            self.shell_report(ws24_report.LEGACY_GRID_MODE, generated=3_100),
        )
        self._write_canonical(
            self.native_xpc_report,
            {
                "ended_at_unix_ms": 3_200,
                "exit_code": 0,
                "predecessor_observations_sha256": PREDECESSOR_SHA256,
                "qualification_run": {"nonce": RUN_NONCE, "run_id": RUN_ID},
                "result": "passed",
                "schema_version": 2,
                "started_at_unix_ms": 3_150,
                "stress": None,
            },
        )
        authority, _, _ = self.authority()
        self.cli_gui_report = self.root / "inputs/cli-gui.json"
        self.mcp_report = self.root / "inputs/mcp.json"
        self._write_canonical(
            self.cli_gui_report,
            ws24_report.operability_report_document(
                report_kind=ws24_report.CLI_GUI_OPERABILITY_REPORT_KIND,
                probe_results={"cli": True, "gui": True},
                authority=authority,
            ),
        )
        self._write_canonical(
            self.mcp_report,
            ws24_report.operability_report_document(
                report_kind=ws24_report.MCP_OPERABILITY_REPORT_KIND,
                probe_results={
                    "initialize": True,
                    "readOnlyInfo": True,
                    "toolsList": True,
                },
                authority=authority,
            ),
        )
        self.gate_outputs = {
            gate_id: self.output_root / f"{gate_id}.json"
            for gate_id in ws24_report.REQUIRED_ACCEPTANCE_GATES
        }

    def _make_bundle(self, bundle: Path, executable_name: str) -> None:
        executable = bundle / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True)
        executable.write_bytes(f"fixture:{executable_name}".encode())
        executable.chmod(0o755)
        (bundle / "Contents/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": executable_name,
                    "CFBundleIdentifier": EXPECTED_BUNDLE_IDS[executable_name],
                },
                fmt=plistlib.FMT_BINARY,
                sort_keys=True,
            )
        )

    def _make_app(self, app: Path) -> None:
        self._make_bundle(app, "MacScope")
        for executable_name in (
            "AnalysisWorkerXPCService",
            "AIAgentWorkerXPCService",
            "NativeDecompilerXPCService",
            "ShellBrokerXPCService",
        ):
            self._make_bundle(
                app / "Contents/XPCServices" / f"{executable_name}.xpc",
                executable_name,
            )
        self.provenance = (
            app / "Contents/Resources" / ws24_report.PROVENANCE_NAME
        )
        self.provenance.parent.mkdir(parents=True)
        self._write_json(
            self.provenance,
            {
                "architecture": "arm64",
                "configuration": "Release",
                "deployment_target": "27.0",
                "ghostty_surface_compilation_condition": (
                    "MACSCOPE_FULL_GHOSTTY_SURFACE"
                ),
                "git_head_commit": SOURCE_COMMIT,
                "git_head_tree": SOURCE_TREE,
                "project_yml_sha256": "a" * 64,
                "qualification_eligible": True,
                "repository_clean": True,
                "schema_version": 1,
                "sdk_name": "macosx27.0",
                "sdk_version": "27.0",
                "selected_build_inputs_sha256": "b" * 64,
                "source_identity": {"kind": "fixture"},
                "swift_compiler_version": "6.4",
                "swift_target_triple": "arm64-apple-macosx27.0",
                "xcode_build": "27A5218g",
                "xcode_version": "27.0",
            },
        )

    def _write_candidate(self) -> None:
        mapping = candidate_mapping()
        mapping["source"].update(
            {"commit": SOURCE_COMMIT, "tree": SOURCE_TREE, "dirty": False}
        )
        digests = bundle_tree_digests(self.source_app)
        application = mapping["application"]
        application["bundle_identifier"] = EXPECTED_BUNDLE_IDS["MacScope"]
        application["bundle_sha256"] = digests.content_sha256
        application["closed_tree_sha256"] = digests.closed_tree_sha256
        application["root_mode"] = self.source_app.stat().st_mode & 0o7777
        application["executable_sha256"] = self.sha256(
            self.source_app / "Contents/MacOS/MacScope"
        )
        names = {
            "analysis-worker": "AnalysisWorkerXPCService",
            "ai-agent-worker": "AIAgentWorkerXPCService",
            "native-decompiler": "NativeDecompilerXPCService",
            "shell-broker": "ShellBrokerXPCService",
        }
        application["embedded_executables"] = [
            {
                "identity_id": identity_id,
                "sha256": self.sha256(
                    self.source_app
                    / "Contents/XPCServices"
                    / f"{name}.xpc/Contents/MacOS"
                    / name
                ),
            }
            for identity_id, name in sorted(names.items())
        ]
        self.application_identity = {
            "installed_bundle_sha256": application["bundle_sha256"],
            "installed_closed_tree_sha256": application["closed_tree_sha256"],
            "installed_executable_sha256": application["executable_sha256"],
            "installed_root_mode": application["root_mode"],
            "release_bundle_sha256": application["bundle_sha256"],
            "release_closed_tree_sha256": application["closed_tree_sha256"],
            "release_executable_sha256": application["executable_sha256"],
            "release_root_mode": application["root_mode"],
        }
        self.candidate_identity.write_bytes(canonical_bytes(mapping))
        authority = installer._load_source_authority(
            self.candidate_identity, self.source_app
        )
        self.candidate_digest = authority.candidate_identity_sha256

    @staticmethod
    def _atomic_rename(source: Path, destination: Path, flags: int) -> None:
        if flags != installer.RENAME_EXCL:
            raise AssertionError(f"unexpected rename flags: {flags}")
        os.rename(source, destination)

    def _begin_install(self) -> None:
        observed = installer.capture_predecessor_observation(self.installed_app)
        if observed.sha256 != PREDECESSOR_SHA256:
            raise AssertionError("fixture must begin with the exact absent predecessor")
        times = iter((1_000_000_000, EXPOSED_NS))
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = installer.main(
                [
                    "--phase",
                    "begin",
                    "--transaction-token",
                    self.candidate_digest,
                    "--candidate-identity",
                    str(self.candidate_identity),
                    "--source-app",
                    str(self.source_app),
                    "--installed-app",
                    str(self.installed_app),
                    "--artifact-root",
                    str(self.artifact_root),
                    "--qualification-run-id",
                    RUN_ID,
                    "--qualification-run-nonce",
                    RUN_NONCE,
                    "--predecessor-observations-sha256",
                    PREDECESSOR_SHA256,
                ],
                _allow_test_destination=True,
                _atomic_rename=self._atomic_rename,
                _equality_collector=lambda _source, _installed: (
                    dict(self.application_identity),
                    [],
                ),
                _clock_ns=lambda: next(times),
                _transaction_nonce_factory=lambda: "c" * 64,
            )
        if status != 0:
            raise AssertionError(stderr.getvalue())

    def shell_report(self, mode: str, *, generated: int) -> dict[str, object]:
        backend, fallback = {
            ws24_report.FULL_SURFACE_MODE: (
                ws24_report.FULL_SURFACE_BACKEND,
                None,
            ),
            ws24_report.LEGACY_GRID_MODE: (
                ws24_report.LEGACY_GRID_BACKEND,
                ws24_report.LEGACY_GRID_REASON,
            ),
        }[mode]
        suffix = "1" if mode == ws24_report.FULL_SURFACE_MODE else "2"
        executable = self.installed_app / "Contents/MacOS/MacScope"
        return {
            "acceptedTranscriptEventCount": 3,
            "appExecutablePath": str(executable),
            "appExecutableSHA256": self.sha256(executable),
            "buildProvenanceSHA256": self.sha256(
                self.installed_app
                / "Contents/Resources"
                / ws24_report.PROVENANCE_NAME
            ),
            "cleanupObservedProcessAbsent": True,
            "generatedAtUnixMilliseconds": generated,
            "launchedProcessIdentifier": 12345,
            "observedReply": "reply:combined-head",
            "reconnectAcceptedTranscriptEventCount": 1,
            "rendererEvidence": {
                "fallbackReason": fallback,
                "rendererPresented": True,
                "requestedMode": mode,
                "selectedBackend": backend,
                "shellProcessIdentifier": 12345,
                "shellRequestID": f"10000000-0000-0000-0000-00000000001{suffix}",
                "shellSessionID": f"10000000-0000-0000-0000-00000000002{suffix}",
                "transcriptOnlyFallbackPresented": False,
            },
            "schemaVersion": ws24_report.INSTALLED_SHELL_REPORT_SCHEMA_VERSION,
            "shellBrokerServiceIdentifier": (
                ws24_report.SHELL_BROKER_SERVICE_IDENTIFIER
            ),
            "shellBrokerWireProtocol": ws24_report.SHELL_BROKER_WIRE_PROTOCOL,
            "sourceCommit": SOURCE_COMMIT,
            "sourceTree": SOURCE_TREE,
            "status": "passed",
            "supportedCommands": sorted(ws24_report.REQUIRED_SHELL_COMMANDS),
        }

    def authority(self):
        return ws24_report.validate_operability_authority(
            installed_app=self.installed_app,
            source_app=self.source_app,
            candidate_identity=self.candidate_identity,
            expected_source_commit=SOURCE_COMMIT,
            qualification_run_id=RUN_ID,
            qualification_run_nonce=RUN_NONCE,
            installation_pending_state=self.pending_state,
            full_surface_report=self.full_surface_report,
            legacy_grid_report=self.legacy_grid_report,
            native_xpc_execution_report=self.native_xpc_report,
        )

    def arguments(self) -> list[str]:
        result = [
            "--source-app",
            str(self.source_app),
            "--installed-app",
            str(self.installed_app),
            "--evidence-json",
            str(self.evidence_json),
            "--candidate-identity",
            str(self.candidate_identity),
            "--expected-source-commit",
            SOURCE_COMMIT,
            "--qualification-run-id",
            RUN_ID,
            "--qualification-run-nonce",
            RUN_NONCE,
            "--installation-pending-state",
            str(self.pending_state),
            "--full-surface-report",
            str(self.full_surface_report),
            "--legacy-grid-report",
            str(self.legacy_grid_report),
            "--cli-gui-operability-report",
            str(self.cli_gui_report),
            "--mcp-operability-report",
            str(self.mcp_report),
            "--native-xpc-execution-report",
            str(self.native_xpc_report),
            "--output",
            str(self.output),
            "--xcode-developer-dir",
            str(self.developer_dir),
            "--generated-at-unix-ms",
            "3000",
        ]
        for gate_id in ws24_report.REQUIRED_ACCEPTANCE_GATES:
            result.extend(
                [
                    "--acceptance-gate-output",
                    f"{gate_id}={self.gate_outputs[gate_id]}",
                ]
            )
        return result

    @staticmethod
    def _write_json(path: Path, value: object) -> None:
        path.write_text(
            json.dumps(value, separators=(",", ":"), sort_keys=True),
            encoding="utf-8",
        )

    @staticmethod
    def _write_canonical(path: Path, value: object) -> None:
        path.write_bytes(canonical_bytes(value))

    @staticmethod
    def sha256(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()


class WS24EmitInstalledQualificationReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.fixture = BridgeFixture(Path(self.temporary.name))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def passing_live_evidence() -> list[dict[str, object]]:
        executable = "d" * 64
        return [
            ws24_report.evidence(
                gate,
                "passed",
                SOURCE_COMMIT,
                executable,
                accepted_attempts=ws24_report.MINIMUM_ACCEPTED_ATTEMPTS.get(gate, 1),
            )
            for gate in sorted(ws24_report.SUPPLIED_LIVE_GATES)
        ]

    def run_success(self, arguments: list[str] | None = None):
        installed_digest = self.fixture.sha256(
            self.fixture.installed_app / "Contents/MacOS/MacScope"
        )
        live = [
            {**item, "installedExecutableSHA256": installed_digest}
            for item in self.passing_live_evidence()
        ]
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(
                ws24_report, "normalize_input_evidence", return_value=live
            ),
            mock.patch.object(ws24_report, "run_signing_guard", return_value=True),
            mock.patch.object(
                ws24_report, "git_tree_for_commit", return_value=SOURCE_TREE
            ),
            mock.patch.object(ws24_report.platform, "machine", return_value="arm64"),
            mock.patch.object(
                ws24_report.platform,
                "mac_ver",
                return_value=("27.0", ("", "", ""), ""),
            ),
            mock.patch.object(
                ws24_report,
                "developer_directory_uses_xcode27",
                return_value=True,
            ),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status = ws24_report.main(arguments or self.fixture.arguments())
        return status, stdout.getvalue(), stderr.getvalue()

    def test_emits_schema5_aggregate_and_exact_eight_canonical_envelopes(self) -> None:
        status, stdout, stderr = self.run_success()
        self.assertEqual(status, 0, stderr)
        aggregate = decode_canonical_bytes(self.fixture.output.read_bytes())
        self.assertEqual(aggregate["schemaVersion"], 5)
        self.assertTrue(aggregate["accepted"])
        lines = stdout.splitlines()
        self.assertEqual(
            lines,
            [
                f"{gate_id}={self.fixture.gate_outputs[gate_id]}"
                for gate_id in ws24_report.REQUIRED_ACCEPTANCE_GATES
            ],
        )
        report_digest = self.fixture.sha256(self.fixture.output)
        self.assertEqual(
            aggregate["liveEvidenceSHA256"],
            self.fixture.sha256(self.fixture.evidence_json),
        )
        self.assertEqual(
            aggregate["operabilityAuthority"]["installationPendingStateSHA256"],
            self.fixture.sha256(self.fixture.pending_state),
        )
        expected_evidence = {
            "full-surface": self.fixture.sha256(
                self.fixture.full_surface_report
            ),
            "forced-legacy-grid": self.fixture.sha256(
                self.fixture.legacy_grid_report
            ),
            "cli": self.fixture.sha256(self.fixture.cli_gui_report),
            "gui": self.fixture.sha256(self.fixture.cli_gui_report),
            "mcp": self.fixture.sha256(self.fixture.mcp_report),
            "native-xpc": self.fixture.sha256(self.fixture.native_xpc_report),
            "signing": report_digest,
            "shellbroker-launchagent": report_digest,
        }
        destination_digest = hashlib.sha256(
            canonical_bytes(self.fixture.state["destination_identity"])
        ).hexdigest()
        physical: set[tuple[int, int]] = set()
        for gate_id in ws24_report.REQUIRED_ACCEPTANCE_GATES:
            path = self.fixture.gate_outputs[gate_id]
            envelope = decode_canonical_bytes(path.read_bytes())
            self.assertEqual(set(envelope), ws24_report.ACCEPTANCE_GATE_INPUT_FIELDS)
            self.assertEqual(envelope["gate_id"], gate_id)
            self.assertEqual(envelope["schema_version"], 1)
            self.assertEqual(
                envelope["input_kind"], "macscope-installer-acceptance-gate"
            )
            self.assertEqual(envelope["result"], "passed")
            self.assertIs(envelope["rolled_back"], False)
            self.assertEqual(envelope["transaction_phase"], "pending")
            self.assertEqual(envelope["evidence_sha256"], expected_evidence[gate_id])
            self.assertEqual(
                envelope["destination_identity_sha256"], destination_digest
            )
            for envelope_field, state_field in (
                ("application_executable_sha256", "application_executable_sha256"),
                ("build_provenance_sha256", "build_provenance_sha256"),
                ("candidate_file_sha256", "candidate_file_sha256"),
                ("candidate_identity_sha256", "candidate_identity_sha256"),
                ("execution_identity_sha256", "execution_identity_sha256"),
                ("qualification_run_id", "qualification_run_id"),
                ("qualification_run_nonce", "qualification_run_nonce"),
                ("source_commit", "source_commit"),
                ("source_equality_sha256", "source_equality_sha256"),
                ("source_tree", "source_tree"),
                ("transaction_id", "transaction_id"),
                ("transaction_nonce", "transaction_nonce"),
            ):
                self.assertEqual(envelope[envelope_field], self.fixture.state[state_field])
            self.assertGreaterEqual(
                envelope["started_at_unix_ns"],
                self.fixture.state["exposed_at_unix_ns"],
            )
            self.assertGreaterEqual(
                envelope["ended_at_unix_ns"], envelope["started_at_unix_ns"]
            )
            metadata = path.lstat()
            self.assertEqual(metadata.st_mode & 0o7777, 0o600)
            self.assertEqual(metadata.st_nlink, 1)
            self.assertLessEqual(metadata.st_size, 1024 * 1024)
            self.assertFalse(path.read_bytes().endswith(b"\n"))
            self.assertNotIn((metadata.st_dev, metadata.st_ino), physical)
            physical.add((metadata.st_dev, metadata.st_ino))
        aggregate_metadata = self.fixture.output.lstat()
        self.assertEqual(aggregate_metadata.st_mode & 0o7777, 0o600)
        self.assertFalse(self.fixture.output.read_bytes().endswith(b"\n"))

    def test_rejected_aggregate_publishes_no_envelopes_or_stdout(self) -> None:
        with mock.patch.object(
            ws24_report,
            "evaluate",
            return_value=(False, [], [{"code": "forced-rejection", "gate": None}]),
        ):
            status, stdout, stderr = self.run_success()
        self.assertEqual(status, 1)
        self.assertEqual(stdout, "")
        self.assertIn("aggregate qualification rejected", stderr)
        self.assertTrue(self.fixture.output.is_file())
        self.assertTrue(
            all(not path.exists() for path in self.fixture.gate_outputs.values())
        )

    def test_live_evidence_requires_governed_name_canonical_bytes_and_freshness(self) -> None:
        canonical = self.fixture.evidence_json.read_bytes()
        self.fixture.evidence_json.write_bytes(b"[\n]\n")
        status, stdout, stderr = self.run_success()
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("not canonical JSON", stderr)

        self.fixture.evidence_json.write_bytes(canonical)
        stale_ns = EXPOSED_NS - 1
        os.utime(self.fixture.evidence_json, ns=(stale_ns, stale_ns))
        status, stdout, stderr = self.run_success()
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("predates candidate exposure", stderr)

        alternate = self.fixture.root / "evidence.json"
        alternate.write_bytes(canonical)
        arguments = self.fixture.arguments()
        arguments[arguments.index(str(self.fixture.evidence_json))] = str(alternate)
        status, stdout, stderr = self.run_success(arguments)
        self.assertEqual(status, 2)
        self.assertEqual(stdout, "")
        self.assertIn("governed live-evidence.json filename", stderr)

    def test_live_execution_report_and_attempts_must_postdate_exposure(self) -> None:
        report_path = self.fixture.root / "inputs/installed-launch-smoke.json"
        report = {
            "attempts": [
                {
                    "attemptIndex": 1,
                    "endedAtUnixMilliseconds": 2,
                    "exitCode": 0,
                    "failure": None,
                    "peakResidentMemoryMegabytes": None,
                    "scenario": "installed-launch-smoke",
                    "seed": None,
                    "startedAtUnixMilliseconds": 1,
                    "timedOut": False,
                }
            ],
            "gate": "installed-launch-smoke",
            "installedExecutableSHA256": self.fixture.sha256(
                self.fixture.installed_app / "Contents/MacOS/MacScope"
            ),
            "schemaVersion": 1,
            "sourceCommit": SOURCE_COMMIT,
            "sourceTree": SOURCE_TREE,
        }
        report_path.write_bytes(canonical_bytes(report))
        descriptor = {
            "kind": ws24_report.LIVE_EXECUTION_REPORT_KIND,
            "path": str(report_path),
            "sha256": self.fixture.sha256(report_path),
        }
        with self.assertRaisesRegex(ws24_report.ReportError, "predates candidate exposure"):
            ws24_report.normalize_input_evidence(
                [{"gate": "installed-launch-smoke", "proofArtifacts": [descriptor]}],
                expected_source_commit=SOURCE_COMMIT,
                expected_source_tree=SOURCE_TREE,
                expected_installed_executable_sha256=report[
                    "installedExecutableSHA256"
                ],
                expected_exposed_at_unix_ns=EXPOSED_NS,
            )

    def test_performance_live_evidence_preserves_integer_peak_memory(self) -> None:
        report_path = self.fixture.root / "inputs/performance-gate.json"
        executable_sha256 = self.fixture.sha256(
            self.fixture.installed_app / "Contents/MacOS/MacScope"
        )
        attempts = [
            {
                "attemptIndex": 1,
                "endedAtUnixMilliseconds": 2_001,
                "exitCode": 0,
                "failure": None,
                "peakResidentMemoryMegabytes": 128,
                "scenario": scenario,
                "seed": offset,
                "startedAtUnixMilliseconds": 2_000,
                "timedOut": False,
            }
            for offset, scenario in enumerate(sorted(ws24_report.STRESS_GATES), 1)
        ]
        report_path.write_bytes(
            canonical_bytes(
                {
                    "attempts": attempts,
                    "gate": "performance-gate",
                    "installedExecutableSHA256": executable_sha256,
                    "schemaVersion": 1,
                    "sourceCommit": SOURCE_COMMIT,
                    "sourceTree": SOURCE_TREE,
                }
            )
        )
        result = ws24_report.validate_live_execution_evidence(
            "performance-gate",
            [
                {
                    "kind": ws24_report.LIVE_EXECUTION_REPORT_KIND,
                    "path": str(report_path),
                    "sha256": self.fixture.sha256(report_path),
                }
            ],
            evidence_index=1,
            expected_source_commit=SOURCE_COMMIT,
            expected_source_tree=SOURCE_TREE,
            expected_installed_executable_sha256=executable_sha256,
        )
        self.assertIs(type(result["maximumPeakResidentMemoryMegabytes"]), int)

    def test_requires_exact_gate_ids_without_duplicates_or_extras(self) -> None:
        base = self.fixture.arguments()
        marker = "--acceptance-gate-output"
        indices = [index for index, value in enumerate(base) if value == marker]
        for label, mutate in (
            ("missing", lambda args: args[: indices[0]] + args[indices[0] + 2 :]),
            (
                "duplicate",
                lambda args: args
                + [marker, args[indices[0] + 1]],
            ),
            (
                "extra",
                lambda args: args
                + [marker, f"extra={self.fixture.output_root / 'extra.json'}"],
            ),
        ):
            with self.subTest(label=label):
                with self.assertRaises(ws24_report.ReportError):
                    parsed = ws24_report.parse_arguments(mutate(list(base)))
                    ws24_report.parse_acceptance_gate_outputs(
                        parsed.acceptance_gate_output,
                        aggregate_output=parsed.output,
                    )

    def test_gate_output_paths_reject_relative_symlink_hardlink_and_preexisting(self) -> None:
        original = self.fixture.gate_outputs["cli"]
        outside = self.fixture.root / "outside"
        outside.mkdir()
        target = outside / "target.json"
        target.write_bytes(b"x")
        cases: list[tuple[str, Path]] = [
            ("relative", Path("relative.json")),
            ("preexisting", target),
            ("wrong-suffix", self.fixture.output_root / "wrong.txt"),
        ]
        nested = self.fixture.output_root / "nested"
        nested.mkdir()
        cases.append(("noncanonical", nested / ".." / "noncanonical.json"))
        symlink = self.fixture.output_root / "symlink.json"
        symlink.symlink_to(target)
        cases.append(("symlink", symlink))
        hardlink = self.fixture.output_root / "hardlink.json"
        os.link(target, hardlink)
        cases.append(("hardlink", hardlink))
        for label, replacement in cases:
            with self.subTest(label=label):
                arguments = self.fixture.arguments()
                needle = f"cli={original}"
                arguments[arguments.index(needle)] = f"cli={replacement}"
                with self.assertRaises(ws24_report.ReportError):
                    parsed = ws24_report.parse_arguments(arguments)
                    ws24_report.parse_acceptance_gate_outputs(
                        parsed.acceptance_gate_output,
                        aggregate_output=parsed.output,
                    )

    def test_reused_output_path_and_disjoint_root_are_rejected(self) -> None:
        arguments = self.fixture.arguments()
        cli = f"cli={self.fixture.gate_outputs['cli']}"
        gui_index = arguments.index(
            f"gui={self.fixture.gate_outputs['gui']}"
        )
        arguments[gui_index] = cli.replace("cli=", "gui=", 1)
        with self.assertRaisesRegex(
            ws24_report.ReportError, "distinct"
        ):
            parsed = ws24_report.parse_arguments(arguments)
            ws24_report.parse_acceptance_gate_outputs(
                parsed.acceptance_gate_output,
                aggregate_output=parsed.output,
            )
        with self.assertRaisesRegex(ws24_report.ReportError, "disjoint"):
            ws24_report._validate_qualification_evidence_root(
                self.fixture.full_surface_report.parent,
                arguments=ws24_report.parse_arguments(self.fixture.arguments()),
                pending_state=self.fixture.state,
            )

    def test_oversized_envelope_is_rejected_before_creation(self) -> None:
        evidence = {
            gate_id: ("a" * 64, EXPOSED_NS, EXPOSED_NS)
            for gate_id in ws24_report.REQUIRED_ACCEPTANCE_GATES
        }
        with (
            mock.patch.object(
                ws24_report,
                "canonical_bytes",
                return_value=b"x" * (1024 * 1024 + 1),
            ),
            self.assertRaisesRegex(ws24_report.ReportError, "exceeds one MiB"),
        ):
            ws24_report.write_acceptance_gate_outputs(
                self.fixture.gate_outputs,
                state=self.fixture.state,
                gate_evidence=evidence,
            )
        self.assertTrue(
            all(not path.exists() for path in self.fixture.gate_outputs.values())
        )

    def test_pending_state_rejects_noncanonical_substitution_and_closed_field(self) -> None:
        original = self.fixture.pending_state.read_bytes()
        state = decode_canonical_bytes(original)
        state["unexpected"] = True
        self.fixture.pending_state.write_bytes(canonical_bytes(state))
        with self.assertRaisesRegex(ws24_report.ReportError, "exact schema"):
            self.fixture.authority()
        self.fixture.pending_state.write_bytes(
            json.dumps(decode_canonical_bytes(original), indent=2).encode()
        )
        with self.assertRaisesRegex(ws24_report.ReportError, "unreadable"):
            self.fixture.authority()
        self.fixture.pending_state.write_bytes(original)
        stale_ns = EXPOSED_NS - 1
        os.utime(self.fixture.pending_state, ns=(stale_ns, stale_ns))
        with self.assertRaisesRegex(ws24_report.ReportError, "predates candidate exposure"):
            self.fixture.authority()
        self.fixture.pending_state.write_bytes(original)
        substitute_root = self.fixture.root / "substitute"
        substitute_root.mkdir(mode=0o700)
        substitute = substitute_root / "transaction.json"
        substitute.write_bytes(original)
        substitute.chmod(0o600)
        with self.assertRaises(ws24_report.ReportError):
            ws24_report.validate_operability_authority(
                installed_app=self.fixture.installed_app,
                source_app=self.fixture.source_app,
                candidate_identity=self.fixture.candidate_identity,
                expected_source_commit=SOURCE_COMMIT,
                qualification_run_id=RUN_ID,
                qualification_run_nonce=RUN_NONCE,
                installation_pending_state=substitute,
                full_surface_report=self.fixture.full_surface_report,
                legacy_grid_report=self.fixture.legacy_grid_report,
                native_xpc_execution_report=self.fixture.native_xpc_report,
            )

    def test_every_pending_binding_mutation_fails_closed(self) -> None:
        original = self.fixture.pending_state.read_bytes()
        fields = (
            "application_executable_sha256",
            "build_provenance_sha256",
            "candidate_file_sha256",
            "candidate_identity_sha256",
            "destination_identity",
            "execution_identity_sha256",
            "qualification_run_id",
            "qualification_run_nonce",
            "source_commit",
            "source_equality_sha256",
            "source_tree",
            "transaction_id",
            "transaction_nonce",
        )
        for field in fields:
            with self.subTest(field=field):
                state = decode_canonical_bytes(original)
                if field == "destination_identity":
                    state[field]["content_sha256"] = "0" * 64
                elif field in {"qualification_run_id"}:
                    state[field] = "different-run"
                elif field in {"source_commit", "source_tree"}:
                    state[field] = "0" * 40
                else:
                    state[field] = "0" * 64
                self.fixture.pending_state.write_bytes(canonical_bytes(state))
                with self.assertRaises(ws24_report.ReportError):
                    self.fixture.authority()
                self.fixture.pending_state.write_bytes(original)

    def test_native_xpc_failure_and_run_mismatch_are_rejected(self) -> None:
        original = self.fixture.native_xpc_report.read_bytes()
        for label, mutation in (
            ("failure", lambda value: value.update({"result": "failed", "exit_code": 1})),
            (
                "run",
                lambda value: value["qualification_run"].update(
                    {"run_id": "historical-run"}
                ),
            ),
        ):
            with self.subTest(label=label):
                report = decode_canonical_bytes(original)
                mutation(report)
                self.fixture.native_xpc_report.write_bytes(canonical_bytes(report))
                with self.assertRaisesRegex(ws24_report.ReportError, "native-XPC"):
                    self.fixture.authority()
                self.fixture.native_xpc_report.write_bytes(original)

    def test_pre_exposure_and_reversed_times_are_rejected(self) -> None:
        with self.assertRaisesRegex(ws24_report.ReportError, "fresh"):
            ws24_report.acceptance_gate_document(
                gate_id="cli",
                state=self.fixture.state,
                evidence_sha256="a" * 64,
                started_at_unix_ns=EXPOSED_NS - 1,
                ended_at_unix_ns=EXPOSED_NS,
            )
        with self.assertRaisesRegex(ws24_report.ReportError, "fresh"):
            ws24_report.acceptance_gate_document(
                gate_id="cli",
                state=self.fixture.state,
                evidence_sha256="a" * 64,
                started_at_unix_ns=EXPOSED_NS + 1,
                ended_at_unix_ns=EXPOSED_NS,
            )
        report = decode_canonical_bytes(self.fixture.native_xpc_report.read_bytes())
        report["started_at_unix_ms"] = 1
        report["ended_at_unix_ms"] = 1
        self.fixture.native_xpc_report.write_bytes(canonical_bytes(report))
        with self.assertRaisesRegex(ws24_report.ReportError, "predates exposure"):
            self.fixture.authority()

    def test_schema5_success_omits_error_and_injected_error_is_rejected(self) -> None:
        success = decode_canonical_bytes(self.fixture.full_surface_report.read_bytes())
        self.assertNotIn("error", success)
        success["error"] = None
        self.fixture.full_surface_report.write_bytes(
            json.dumps(success, separators=(",", ":"), sort_keys=True).encode()
        )
        with self.assertRaisesRegex(ws24_report.ReportError, r"unknown=\['error'\]"):
            self.fixture.authority()

    def test_schema5_failure_requires_nonempty_error(self) -> None:
        failed = decode_canonical_bytes(self.fixture.full_surface_report.read_bytes())
        failed["status"] = "failed"
        self.fixture.full_surface_report.write_bytes(
            json.dumps(failed, separators=(",", ":"), sort_keys=True).encode()
        )
        with self.assertRaisesRegex(ws24_report.ReportError, r"missing=\['error'\]"):
            self.fixture.authority()
        failed["error"] = "renderer failed"
        self.fixture.full_surface_report.write_bytes(
            json.dumps(failed, separators=(",", ":"), sort_keys=True).encode()
        )
        with self.assertRaisesRegex(ws24_report.ReportError, "transcript-only"):
            self.fixture.authority()

    def test_obsolete_installer_report_arguments_are_explicitly_rejected(self) -> None:
        for obsolete in (
            "--installation-operation-report",
            "--installation-source-equality-report",
            "--installation-execution-report",
        ):
            with self.subTest(obsolete=obsolete), self.assertRaises(SystemExit) as raised:
                ws24_report.parse_arguments(
                    self.fixture.arguments() + [obsolete, str(self.fixture.root / "old.json")]
                )
            self.assertEqual(raised.exception.code, 2)

    def test_missing_pending_state_is_rejected_by_parser(self) -> None:
        arguments = self.fixture.arguments()
        index = arguments.index("--installation-pending-state")
        del arguments[index : index + 2]
        with self.assertRaises(SystemExit) as raised:
            ws24_report.parse_arguments(arguments)
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
