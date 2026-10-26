#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import os
from pathlib import Path
import stat
import tempfile
import unittest

from Scripts.reconstruction import compile_installed_acceptance_gate_plan as compiler
from Scripts.reconstruction import native_live_preparation_receipt as native_receipt
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.tests.test_ws24_emit_installed_qualification_report import (
    BridgeFixture,
    PREDECESSOR_SHA256,
    RUN_ID,
    RUN_NONCE,
    SOURCE_COMMIT,
    SOURCE_TREE,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (
    REPOSITORY_ROOT
    / "Scripts/reconstruction/compile_installed_acceptance_gate_plan.py"
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CompilerFixture:
    def __init__(self, sdk_version: str = "27.0") -> None:
        self.sdk_version = sdk_version
        self.temporary = tempfile.TemporaryDirectory(
            prefix="macscope-installed-gate-plan."
        )
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.xcode_developer_dir = self.root / "Xcode.app/Contents/Developer"
        self.xcode_developer_dir.mkdir(parents=True)
        self.qualification_run_root = self.root / "qualification-run"
        self.qualification_run_root.mkdir()
        self.candidate_root = self.qualification_run_root / "candidate-artifacts"
        self.candidate_root.mkdir()
        self.bridge = BridgeFixture(self.candidate_root)
        self.products_root = (
            self.qualification_run_root / "DerivedData/Build/Products"
        )
        debug_root = self.products_root / "Debug"
        debug_root.mkdir(parents=True)
        release_root = self.products_root / "Release"
        release_root.mkdir()
        governed_source_app = release_root / "MacScope.app"
        self.bridge.source_app.rename(governed_source_app)
        self.bridge.source_app = governed_source_app
        state = decode_canonical_bytes(self.bridge.pending_state.read_bytes())
        state["source_app_path"] = str(governed_source_app)
        self.bridge.pending_state.write_bytes(canonical_bytes(state))
        self.bridge.state = state
        self.work_root = self.root / "work"
        self.work_root.mkdir()
        self.evidence_root = self.work_root / "InstalledAcceptanceGate.evidence"
        self.evidence_root.mkdir()
        self.evidence_root.chmod(0o700)
        self.qualification_output_root = (
            self.work_root / "InstalledAcceptanceQualification.evidence"
        )
        self.qualification_output_root.mkdir(mode=0o700)
        self.output = self.evidence_root / compiler.PLAN_FILENAME
        self.qualification_receipt = (
            self.qualification_run_root / "QUALIFICATION_INPUTS.json"
        )
        self.build_source_root = self.qualification_run_root / "source"
        self.build_source_root.mkdir()
        self._write_qualification_receipt()
        self.native_xctestrun = (
            self.products_root / f"MacScopeApp_macosx{sdk_version}-arm64.xctestrun"
        )
        self.native_xctestrun.write_bytes(b"sealed native xctestrun fixture\n")
        self.native_preparation_receipt = (
            self.candidate_root / compiler.NATIVE_PREPARATION_RECEIPT_NAME
        )
        self._write_native_preparation_receipt()
        self.installed_ui_xctestrun = (
            self.products_root
            / f"MacScopeInstalledAppUITests_macosx{sdk_version}-arm64.xctestrun"
        )
        self.installed_ui_xctestrun.write_bytes(b"sealed installed UI xctestrun fixture\n")
        self.installed_ui_runner = (
            debug_root / "MacScopeInstalledAppUITests-Runner.app"
        )
        self.installed_ui_test_bundle = (
            self.installed_ui_runner
            / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        )
        self.installed_ui_test_bundle.mkdir(parents=True)
        self.installed_ui_preparation_receipt = (
            self.candidate_root
            / compiler.INSTALLED_UI_PREPARATION_RECEIPT_NAME
        )
        self._write_installed_ui_preparation_receipt()

    def close(self) -> None:
        self.temporary.cleanup()

    def __enter__(self) -> CompilerFixture:
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def _write_qualification_receipt(self) -> None:
        run_root = self.qualification_run_root
        source_identity = {
            "canonical_integration_commit": SOURCE_COMMIT,
            "canonical_integration_ref": "refs/remotes/gitfox-local/test",
            "canonical_remote_url": "/private/tmp/macscope-test.git",
            "dependency_contract": {},
            "git_head_commit": SOURCE_COMMIT,
            "git_head_tree": SOURCE_TREE,
            "git_parent_commits": [],
            "repository_clean": True,
            "schema_version": 2,
            "source_file_count": 1,
            "source_files_sha256": "7" * 64,
        }
        document = {
            "build_source_root": str(self.build_source_root),
            "dependency_cache_root": str(run_root / "dependency-cache"),
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "ghostty_artifact_manifest_sha256": "1" * 64,
            "ghostty_source_dir": str(run_root / "dependencies/ghostty-vt"),
            "ghostty_surface_artifact_root": str(
                run_root / "dependencies/ghostty-surface/GhosttyKit.xcframework"
            ),
            "ghostty_surface_manifest_sha256": "2" * 64,
            "ghostty_surface_source_dir": str(
                run_root / "dependencies/ghostty-surface/GhosttySurface"
            ),
            "mode": "full-test",
            "schema_version": 4,
            "sleigh_materialization_manifest_sha256": "3" * 64,
            "sleigh_materialization_root": str(
                run_root / "dependencies/sleigh/materialization"
            ),
            "source_identity": source_identity,
            "zig_executable": str(self.build_source_root / "ThirdParty/Zig/zig"),
        }
        self.qualification_receipt.write_bytes(canonical_bytes(document) + b"\n")

    def _write_native_preparation_receipt(self) -> None:
        source_app = self.bridge.source_app
        native_executable = (
            source_app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc"
            / "Contents/MacOS/NativeDecompilerXPCService"
        )
        document = {
            "artifacts": {
                "app": {
                    "closed_tree_sha256": self.bridge.application_identity[
                        "release_closed_tree_sha256"
                    ],
                    "executable_sha256": self.bridge.application_identity[
                        "release_executable_sha256"
                    ],
                    "path": str(source_app),
                },
                "core_tests": {
                    "closed_tree_sha256": "4" * 64,
                    "executable_sha256": "5" * 64,
                    "path": str(
                        source_app / "Contents/PlugIns/CoreTests.xctest"
                    ),
                },
                "native_decompiler": {
                    "path": str(native_executable),
                    "sha256": sha256_file(native_executable),
                },
                "xctestrun": {
                    "path": str(self.native_xctestrun),
                    "sha256": sha256_file(self.native_xctestrun),
                },
            },
            "build": {
                "configuration": native_receipt.CONFIGURATION,
                "destination": native_receipt.DESTINATION,
                "live_test_condition": native_receipt.LIVE_TEST_CONDITION,
                "preparation_mode": native_receipt.NATIVE_LIVE_PREPARATION_MODE,
                "scheme": native_receipt.SCHEME,
            },
            "receipt_kind": native_receipt.RECEIPT_KIND,
            "schema_version": native_receipt.SCHEMA_VERSION,
            "source": {
                "branch_label": "refs/remotes/gitfox-local/test",
                "commit": SOURCE_COMMIT,
                "dirty": False,
                "generated_project_sha256": "6" * 64,
                "project_yml_sha256": "7" * 64,
                "repository": str(self.candidate_root),
                "tree": SOURCE_TREE,
            },
            "toolchain": {
                "developer_dir": str(self.xcode_developer_dir),
                "sdk_build": "27A1",
                "sdk_path": "/Applications/Xcode.app/SDKs/MacOSX.sdk",
                "sdk_settings_sha256": "8" * 64,
                "sdk_version": self.sdk_version,
                "swift_version": "Swift 6.4",
                "swiftc_sha256": "9" * 64,
                "xcode_build": "27A1",
                "xcode_version": "Xcode 27.0",
                "xcodebuild_sha256": "a" * 64,
            },
        }
        self.native_preparation_receipt.write_bytes(canonical_bytes(document))

    def _write_installed_ui_preparation_receipt(self) -> None:
        document = {
            "artifacts": {
                "app": {
                    "closed_tree_sha256": self.bridge.application_identity[
                        "release_closed_tree_sha256"
                    ],
                    "executable_sha256": self.bridge.application_identity[
                        "release_executable_sha256"
                    ],
                    "path": str(self.bridge.source_app),
                },
                "ui_runner": {
                    "closed_tree_sha256": "b" * 64,
                    "executable_sha256": "c" * 64,
                    "path": str(self.installed_ui_runner),
                },
                "ui_test_bundle": {
                    "closed_tree_sha256": "d" * 64,
                    "executable_sha256": "e" * 64,
                    "path": str(self.installed_ui_test_bundle),
                },
                "xctestrun": {
                    "path": str(self.installed_ui_xctestrun),
                    "sha256": sha256_file(self.installed_ui_xctestrun),
                },
            },
            "build": {
                "configuration": native_receipt.CONFIGURATION,
                "destination": native_receipt.DESTINATION,
                "live_test_condition": native_receipt.INSTALLED_UI_TEST_CONDITION,
                "preparation_mode": native_receipt.INSTALLED_UI_PREPARATION_MODE,
                "scheme": native_receipt.INSTALLED_UI_SCHEME,
            },
            "receipt_kind": native_receipt.RECEIPT_KIND,
            "schema_version": native_receipt.SCHEMA_VERSION,
            "source": {
                "branch_label": "refs/remotes/gitfox-local/test",
                "commit": SOURCE_COMMIT,
                "dirty": False,
                "generated_project_sha256": "6" * 64,
                "project_yml_sha256": "7" * 64,
                "repository": str(self.candidate_root),
                "tree": SOURCE_TREE,
            },
            "toolchain": {
                "developer_dir": str(self.xcode_developer_dir),
                "sdk_build": "27A1",
                "sdk_path": "/Applications/Xcode.app/SDKs/MacOSX.sdk",
                "sdk_settings_sha256": "8" * 64,
                "sdk_version": self.sdk_version,
                "swift_version": "Swift 6.4",
                "swiftc_sha256": "9" * 64,
                "xcode_build": "27A1",
                "xcode_version": "Xcode 27.0",
                "xcodebuild_sha256": "a" * 64,
            },
        }
        self.installed_ui_preparation_receipt.write_bytes(canonical_bytes(document))

    def arguments(self) -> list[str]:
        return [
            "--qualification-receipt",
            str(self.qualification_receipt),
            "--candidate-artifact-root",
            str(self.candidate_root),
            "--installation-pending-state",
            str(self.bridge.pending_state),
            "--evidence-root",
            str(self.evidence_root),
            "--output",
            str(self.output),
        ]

    def namespace(self):
        return compiler.parse_arguments(self.arguments())

    def inputs(self) -> compiler.CompilationInputs:
        return compiler._load_inputs(self.namespace())

    def plan(self) -> dict[str, object]:
        return compiler.compile_plan_document(self.inputs())


class InstalledAcceptanceGatePlanCompilerTests(unittest.TestCase):
    def test_current_sdk_minor_products_round_trip_through_plan_validation(self) -> None:
        with CompilerFixture(sdk_version="27.2") as fixture:
            plan = compiler.compile_plan_document(fixture.inputs())
            compiler.validate_plan_document(plan)
            self.assertEqual(plan["authority"]["native_xctestrun_path"], str(fixture.native_xctestrun))
            self.assertEqual(plan["authority"]["installed_ui_xctestrun_path"], str(fixture.installed_ui_xctestrun))

    def test_extra_sdk_product_cannot_be_silently_selected(self) -> None:
        with CompilerFixture(sdk_version="27.2") as fixture:
            (fixture.products_root / "MacScopeApp_macosx27.0-arm64.xctestrun").write_bytes(b"stale")
            with self.assertRaises(ValueError):
                fixture.inputs()

    maxDiff = None

    def test_parser_has_exact_five_required_only_flags(self) -> None:
        values = [
            "--qualification-receipt",
            "/private/tmp/QUALIFICATION_INPUTS.json",
            "--candidate-artifact-root",
            "/private/tmp/candidate",
            "--installation-pending-state",
            "/private/tmp/transaction.json",
            "--evidence-root",
            "/private/tmp/evidence",
            "--output",
            "/private/tmp/evidence/InstalledAcceptanceGate.plan.json",
        ]
        parsed = compiler.parse_arguments(values)
        self.assertEqual(
            set(vars(parsed)),
            {
                "candidate_artifact_root",
                "evidence_root",
                "installation_pending_state",
                "output",
                "qualification_receipt",
            },
        )
        for rejected in (
            values[:-2],
            values + ["--timeout-seconds", "30"],
            values + ["--output", "/private/tmp/duplicate.json"],
            [
                *values[:-2],
                "--output=/private/tmp/evidence/InstalledAcceptanceGate.plan.json",
            ],
        ):
            with self.subTest(rejected=rejected[-2:]):
                with contextlib.redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as raised:
                        compiler.parse_arguments(rejected)
                self.assertEqual(raised.exception.code, 2)

    def test_plan_is_closed_sorted_and_fully_bound(self) -> None:
        with CompilerFixture() as fixture:
            inputs = fixture.inputs()
            plan = compiler.compile_plan_document(inputs)
            self.assertEqual(set(plan), compiler.TOP_LEVEL_FIELDS)
            self.assertEqual(plan["schema_version"], 1)
            self.assertEqual(plan["plan_kind"], compiler.PLAN_KIND)
            self.assertEqual(plan["output_path"], str(fixture.output))
            self.assertEqual(plan["evidence_root"], str(fixture.evidence_root))
            self.assertEqual(
                [gate["gate_id"] for gate in plan["gates"]],
                list(compiler.GATE_IDS),
            )
            authority = plan["authority"]
            state = fixture.bridge.state
            self.assertEqual(set(authority), compiler.AUTHORITY_FIELDS)
            for field in (
                "application_executable_sha256",
                "build_provenance_sha256",
                "candidate_file_sha256",
                "candidate_identity_sha256",
                "execution_identity_sha256",
                "predecessor_digest",
                "predecessor_observations_sha256",
                "qualification_run_id",
                "qualification_run_nonce",
                "source_commit",
                "source_equality_sha256",
                "source_tree",
                "transaction_id",
                "transaction_nonce",
            ):
                self.assertEqual(authority[field], state[field], field)
            self.assertEqual(
                plan["authority_sha256"],
                hashlib.sha256(canonical_bytes(authority)).hexdigest(),
            )
            self.assertEqual(
                authority["installed_ui_preparation_receipt_path"],
                str(fixture.installed_ui_preparation_receipt),
            )
            self.assertEqual(
                authority["installed_ui_preparation_receipt_sha256"],
                sha256_file(fixture.installed_ui_preparation_receipt),
            )
            self.assertEqual(
                authority["installed_ui_xctestrun_path"],
                str(fixture.installed_ui_xctestrun),
            )
            self.assertEqual(
                authority["installed_ui_test_bundle_path"],
                str(fixture.installed_ui_test_bundle),
            )
            self.assertEqual(
                authority["installed_ui_runner_path"],
                str(fixture.installed_ui_runner),
            )
            self.assertEqual(
                authority["installed_task10_matrix_receipt_path"],
                str(fixture.evidence_root / "InstalledTask10.matrix-receipt.json"),
            )
            self.assertEqual(
                authority["installed_task10_xcresult_path"],
                str(fixture.evidence_root / "InstalledTask10.xcresult"),
            )
            self.assertEqual(
                authority["installed_task10_xcresult_semantic_manifest_path"],
                str(
                    fixture.evidence_root
                    / "InstalledTask10.xcresult-semantic.json"
                ),
            )
            self.assertEqual(
                authority["installed_task10_network_artifact_root"],
                str(fixture.evidence_root / "installed-task10-network"),
            )
            self.assertEqual(
                authority["installed_task10_incremental_evidence_path"],
                str(
                    fixture.evidence_root
                    / "installed-task10-network"
                    / "InstalledTask10.incremental-xcuitest.evidence.json"
                ),
            )
            for gate in plan["gates"]:
                gate_id = gate["gate_id"]
                self.assertEqual(set(gate), compiler.GATE_FIELDS)
                self.assertEqual(
                    gate["authority_sha256"], plan["authority_sha256"]
                )
                self.assertEqual(
                    gate["environment"],
                    compiler._fixed_environment(plan["authority_sha256"]),
                )
                self.assertEqual(
                    gate["depends_on"],
                    list(compiler.FIXED_DEPENDENCIES[gate_id]),
                )
                self.assertEqual(
                    gate["timeout_seconds"], compiler.FIXED_TIMEOUTS[gate_id]
                )
                self.assertEqual(set(gate["output"]), compiler.OUTPUT_FIELDS)

    def test_known_frozen_argv_are_literal_and_shared_operations_match(self) -> None:
        with CompilerFixture() as fixture:
            plan = fixture.plan()
            gates = {gate["gate_id"]: gate for gate in plan["gates"]}
            authority = plan["authority"]
            evidence = fixture.evidence_root
            installed = str(fixture.bridge.installed_app)
            source = str(fixture.bridge.source_app)
            pending = str(fixture.bridge.pending_state)
            candidate = str(fixture.bridge.candidate_identity)
            cli_report = str(evidence / "cli-gui-operability.report.json")
            full = str(evidence / "full-surface.json")
            legacy = str(evidence / "full-surface.legacy-grid.json")
            native = str(
                evidence
                / "native-xpc-artifacts/NativeDecompilerLiveXPC.execution-report.json"
            )
            cli_gui = [
                "/bin/bash",
                str(REPOSITORY_ROOT / "Scripts/smoke/cli_gui_operability_smoke.sh"),
                "--mode",
                "both",
                "--app",
                installed,
                "--timeout-seconds",
                "30",
                "--binary",
                "/usr/bin/true",
                "--candidate-commit",
                SOURCE_COMMIT,
                "--output",
                cli_report,
                "--source-app",
                source,
                "--candidate-identity",
                candidate,
                "--qualification-run-id",
                RUN_ID,
                "--qualification-run-nonce",
                RUN_NONCE,
                "--installation-pending-state",
                pending,
                "--full-surface-report",
                full,
                "--legacy-grid-report",
                legacy,
                "--native-xpc-execution-report",
                native,
            ]
            self.assertEqual(gates["cli"]["argv"], cli_gui)
            self.assertEqual(gates["gui"]["argv"], cli_gui)
            self.assertEqual(
                gates["cli"]["operation_id"], "cli-gui-operability"
            )
            self.assertEqual(
                gates["gui"]["operation_id"], "cli-gui-operability"
            )
            renderer = [
                "/usr/bin/python3",
                "-B",
                str(REPOSITORY_ROOT / "Scripts/phase2/run_installed_shell_smoke.py"),
                "--app",
                installed,
                "--output",
                full,
                "--marker",
                f"macscope-installed-acceptance-{plan['authority_sha256']}",
                "--timeout-seconds",
                "30",
                "--single-launch",
                "--expected-source-commit",
                SOURCE_COMMIT,
            ]
            self.assertEqual(gates["forced-legacy-grid"]["argv"], renderer)
            self.assertEqual(gates["full-surface"]["argv"], renderer)
            self.assertEqual(
                gates["mcp"]["argv"],
                [
                    "/bin/bash",
                    str(REPOSITORY_ROOT / "Scripts/smoke/mcp_operability_smoke.sh"),
                    "--mode",
                    "installed",
                    "--app",
                    installed,
                    "--binary",
                    "/bin/ls",
                    "--candidate-commit",
                    SOURCE_COMMIT,
                    "--timeout-seconds",
                    "30",
                    "--output",
                    str(evidence / "mcp-operability.report.json"),
                    "--source-app",
                    source,
                    "--candidate-identity",
                    candidate,
                    "--qualification-run-id",
                    RUN_ID,
                    "--qualification-run-nonce",
                    RUN_NONCE,
                    "--installation-pending-state",
                    pending,
                    "--full-surface-report",
                    full,
                    "--legacy-grid-report",
                    legacy,
                    "--native-xpc-execution-report",
                    native,
                ],
            )
            self.assertEqual(
                gates["native-xpc"]["argv"],
                [
                    str(
                        REPOSITORY_ROOT
                        / "Scripts/native-decompiler-xpc/run_installed_native_xpc_gate.py"
                    ),
                    "--installed-app",
                    installed,
                    "--candidate-identity",
                    candidate,
                    "--preparation-receipt",
                    str(fixture.native_preparation_receipt),
                    "--artifact-root",
                    str(evidence / "native-xpc-artifacts"),
                    "--qualification-run-id",
                    RUN_ID,
                    "--qualification-run-nonce",
                    RUN_NONCE,
                    "--predecessor-observations-sha256",
                    PREDECESSOR_SHA256,
                    "--phase-timeout-seconds",
                    "60",
                ],
            )
            self.assertEqual(
                gates["shellbroker-launchagent"]["argv"],
                [
                    "/usr/bin/python3",
                    "-B",
                    str(
                        REPOSITORY_ROOT
                        / "Scripts/reconstruction/emit_installed_live_evidence.py"
                    ),
                    "--candidate-identity",
                    candidate,
                    "--source-app",
                    source,
                    "--installed-app",
                    installed,
                    "--installation-pending-state",
                    pending,
                    "--native-preparation-receipt",
                    str(fixture.native_preparation_receipt),
                    "--matrix-receipt",
                    str(evidence / "InstalledTask10.matrix-receipt.json"),
                    "--xcresult-semantic-manifest",
                    str(
                        evidence
                        / "InstalledTask10.xcresult-semantic.json"
                    ),
                    "--network-artifact-root",
                    str(evidence / "installed-task10-network"),
                    "--qualification-run-id",
                    RUN_ID,
                    "--qualification-run-nonce",
                    RUN_NONCE,
                    "--evidence-root",
                    str(evidence),
                    "--live-gates-timeout-seconds",
                    "1800",
                ],
            )
            self.assertEqual(
                gates["signing"]["argv"],
                [
                    "/usr/bin/python3",
                    "-B",
                    str(REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py"),
                    "--source-app",
                    source,
                    "--installed-app",
                    installed,
                    "--evidence-json",
                    str(evidence / "live-evidence.json"),
                    "--candidate-identity",
                    candidate,
                    "--expected-source-commit",
                    SOURCE_COMMIT,
                    "--qualification-run-id",
                    RUN_ID,
                    "--qualification-run-nonce",
                    RUN_NONCE,
                    "--installation-pending-state",
                    pending,
                    "--full-surface-report",
                    full,
                    "--legacy-grid-report",
                    legacy,
                    "--cli-gui-operability-report",
                    cli_report,
                    "--mcp-operability-report",
                    str(evidence / "mcp-operability.report.json"),
                    "--native-xpc-execution-report",
                    native,
                    "--output",
                    str(
                        fixture.qualification_output_root
                        / "WS24.installed-qualification.json"
                    ),
                    *[
                        token
                        for gate_id in compiler.GATE_IDS
                        for token in (
                            "--acceptance-gate-output",
                            (
                                f"{gate_id}="
                                f"{fixture.qualification_output_root / (gate_id + '.acceptance-gate.json')}"
                            ),
                        )
                    ],
                    "--xcode-developer-dir",
                    str(fixture.xcode_developer_dir),
                ],
            )
            self.assertEqual(authority["qualification_run_id"], RUN_ID)
            self.assertEqual(authority["qualification_run_nonce"], RUN_NONCE)
            self.assertEqual(
                authority["predecessor_observations_sha256"], PREDECESSOR_SHA256
            )

    def test_every_target_flag_names_the_installed_candidate(self) -> None:
        with CompilerFixture() as fixture:
            plan = fixture.plan()
            installed = str(fixture.bridge.installed_app)
            source = str(fixture.bridge.source_app)
            target_flags = {"--app", "--app-bundle", "--candidate-app", "--installed-app"}
            observed = 0
            for gate in plan["gates"]:
                argv = gate["argv"]
                for index, token in enumerate(argv[:-1]):
                    if token in target_flags:
                        observed += 1
                        self.assertEqual(argv[index + 1], installed, gate["gate_id"])
                        self.assertNotEqual(argv[index + 1], source)
            self.assertGreaterEqual(observed, len(compiler.GATE_IDS) - 2)

    def test_schema_rejects_unknown_missing_duplicate_and_substitution(self) -> None:
        with CompilerFixture() as fixture:
            plan = fixture.plan()
            mutations = {}
            unknown = copy.deepcopy(plan)
            unknown["unknown"] = True
            mutations["unknown top field"] = unknown
            missing = copy.deepcopy(plan)
            del missing["authority"]
            mutations["missing top field"] = missing
            duplicate = copy.deepcopy(plan)
            duplicate["gates"].append(copy.deepcopy(duplicate["gates"][0]))
            mutations["duplicate gate"] = duplicate
            reordered = copy.deepcopy(plan)
            reordered["gates"][0], reordered["gates"][1] = (
                reordered["gates"][1],
                reordered["gates"][0],
            )
            mutations["reordered gates"] = reordered
            substituted_argv = copy.deepcopy(plan)
            substituted_argv["gates"][0]["argv"][-1] = "substituted"
            mutations["argv substitution"] = substituted_argv
            escaped_output = copy.deepcopy(plan)
            escaped_output["gates"][0]["output"]["path"] = "/private/tmp/escape"
            mutations["output escape"] = escaped_output
            environment = copy.deepcopy(plan)
            environment["gates"][0]["environment"]["SECRET"] = "value"
            mutations["environment expansion"] = environment
            timeout = copy.deepcopy(plan)
            timeout["gates"][0]["timeout_seconds"] = 86_400
            mutations["timeout expansion"] = timeout
            transaction = copy.deepcopy(plan)
            transaction["authority"]["transaction_nonce"] = "d" * 64
            mutations["transaction substitution"] = transaction
            for label, mutated in mutations.items():
                with self.subTest(label=label):
                    with self.assertRaises(compiler.PlanCompilationError):
                        compiler.validate_plan_document(mutated)

    def test_deterministic_bytes_and_bounded_environment(self) -> None:
        with CompilerFixture() as fixture:
            inputs = fixture.inputs()
            first = compiler.compile_plan_document(inputs)
            second = compiler.compile_plan_document(inputs)
            self.assertEqual(canonical_bytes(first), canonical_bytes(second))
            self.assertLessEqual(len(canonical_bytes(first)), compiler.MAXIMUM_PLAN_BYTES)
            output_paths = []
            for gate in first["gates"]:
                self.assertEqual(
                    set(gate["environment"]), compiler.ENVIRONMENT_KEYS
                )
                self.assertNotIn("HOME", gate["environment"])
                self.assertLessEqual(
                    gate["timeout_seconds"], max(compiler.FIXED_TIMEOUTS.values())
                )
                self.assertLessEqual(
                    len(gate["argv"]), compiler.MAXIMUM_ARGV_TOKENS
                )
                self.assertGreater(gate["output"]["maximum_bytes"], 0)
                output_paths.append(Path(gate["output"]["path"]))
            self.assertEqual(len(output_paths), len(set(output_paths)))
            for gate, path in zip(first["gates"], output_paths):
                governed_root = (
                    fixture.qualification_output_root
                    if gate["gate_id"] == "signing"
                    else fixture.evidence_root
                )
                self.assertTrue(path.is_relative_to(governed_root))

    def test_publish_is_create_only_canonical_and_stdout_is_only_path(self) -> None:
        with CompilerFixture() as fixture:
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                result = compiler.main(fixture.arguments())
            self.assertEqual(result, 0, stderr.getvalue())
            self.assertEqual(stdout.getvalue(), f"{fixture.output}\n")
            self.assertEqual(stderr.getvalue(), "")
            payload = fixture.output.read_bytes()
            self.assertFalse(payload.endswith(b"\n"))
            self.assertLessEqual(len(payload), compiler.MAXIMUM_PLAN_BYTES)
            self.assertEqual(stat.S_IMODE(fixture.output.stat().st_mode), 0o600)
            self.assertEqual(decode_canonical_bytes(payload)["output_path"], str(fixture.output))
            original = payload
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                repeated = compiler.main(fixture.arguments())
            self.assertEqual(repeated, 1)
            self.assertEqual(stdout.getvalue(), "")
            self.assertIn("create-only", stderr.getvalue())
            self.assertEqual(fixture.output.read_bytes(), original)

    def test_rejects_candidate_receipt_pending_and_xctestrun_substitution(self) -> None:
        attacks = (
            "candidate",
            "qualification",
            "pending",
            "xctestrun",
            "installed-ui-receipt",
            "installed-ui-xctestrun",
            "hardlink",
        )
        for attack in attacks:
            with self.subTest(attack=attack), CompilerFixture() as fixture:
                if attack == "candidate":
                    fixture.bridge.candidate_identity.write_bytes(
                        fixture.bridge.candidate_identity.read_bytes() + b" "
                    )
                elif attack == "qualification":
                    document = decode_canonical_bytes(
                        fixture.qualification_receipt.read_bytes()[:-1]
                    )
                    document["source_identity"]["git_head_commit"] = "f" * 40
                    fixture.qualification_receipt.write_bytes(
                        canonical_bytes(document) + b"\n"
                    )
                elif attack == "pending":
                    document = decode_canonical_bytes(
                        fixture.bridge.pending_state.read_bytes()
                    )
                    document["transaction_nonce"] = "d" * 64
                    fixture.bridge.pending_state.write_bytes(canonical_bytes(document))
                elif attack == "xctestrun":
                    fixture.native_xctestrun.write_bytes(b"substituted xctestrun\n")
                elif attack == "installed-ui-receipt":
                    document = decode_canonical_bytes(
                        fixture.installed_ui_preparation_receipt.read_bytes()
                    )
                    document["build"]["preparation_mode"] = (
                        native_receipt.NATIVE_LIVE_PREPARATION_MODE
                    )
                    fixture.installed_ui_preparation_receipt.write_bytes(
                        canonical_bytes(document)
                    )
                elif attack == "installed-ui-xctestrun":
                    fixture.installed_ui_xctestrun.write_bytes(
                        b"substituted installed UI xctestrun\n"
                    )
                else:
                    os.link(
                        fixture.bridge.candidate_identity,
                        fixture.candidate_root / "candidate-hardlink.json",
                    )
                with self.assertRaises(compiler.PlanCompilationError):
                    fixture.inputs()

    def test_rejects_authority_staleness_after_initial_validation(self) -> None:
        with CompilerFixture() as fixture:
            inputs = fixture.inputs()
            fixture.native_xctestrun.write_bytes(b"changed after admission\n")
            with self.assertRaises(compiler.PlanCompilationError):
                compiler.compile_plan_document(inputs)

    def test_rejects_symlink_alias_and_non_governed_output(self) -> None:
        with CompilerFixture() as fixture:
            alias_root = fixture.root / "evidence-alias"
            alias_root.symlink_to(fixture.evidence_root, target_is_directory=True)
            arguments = fixture.arguments()
            arguments[arguments.index("--evidence-root") + 1] = str(alias_root)
            arguments[arguments.index("--output") + 1] = str(
                alias_root / compiler.PLAN_FILENAME
            )
            with self.assertRaises(compiler.PlanCompilationError):
                compiler._load_inputs(compiler.parse_arguments(arguments))
        with CompilerFixture() as fixture:
            fixture.output.symlink_to(fixture.root / "foreign-plan.json")
            with self.assertRaises(compiler.PlanCompilationError):
                fixture.inputs()
        with CompilerFixture() as fixture:
            arguments = fixture.arguments()
            arguments[arguments.index("--output") + 1] = str(
                fixture.evidence_root / "alias.json"
            )
            with self.assertRaises(compiler.PlanCompilationError):
                compiler._load_inputs(compiler.parse_arguments(arguments))


if __name__ == "__main__":
    unittest.main()
