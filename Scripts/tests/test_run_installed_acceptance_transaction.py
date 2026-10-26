from __future__ import annotations

import contextlib
import copy
import hashlib
import io
import os
import signal
import stat
import sys
import tempfile
import time
import unittest
from collections.abc import Iterator, Mapping, Sequence
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import run_installed_acceptance_transaction as transaction
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.receipt_validator import QualificationRunAuthority


TOKEN = "a" * 64
RUN_NONCE = "b" * 64
PREDECESSOR_OBSERVATIONS = "c" * 64
TRANSACTION_ID = "d" * 64
TRANSACTION_NONCE = "e" * 64
SOURCE_COMMIT = "1" * 40
SOURCE_TREE = "2" * 40
EXECUTION_DIGEST = "3" * 64
SOURCE_EQUALITY_DIGEST = "4" * 64
APPLICATION_DIGEST = "5" * 64
PROVENANCE_DIGEST = "6" * 64
CANDIDATE_FILE_DIGEST = "7" * 64
EXPOSED_AT = 1


class ScriptedRunner:
    def __init__(
        self,
        request: transaction.BoundRequest,
        pending: transaction.PendingBinding,
    ) -> None:
        self.request = request
        self.pending = pending
        self.calls: list[
            tuple[tuple[str, ...], float, dict[str, str]]
        ] = []
        self.fail_stage: str | None = None
        self.timeout_stage: str | None = None
        self.signal_stage: str | None = None
        self.rollback_failure = False

    def stage(self, argv: tuple[str, ...]) -> str:
        if "--phase" in argv:
            return argv[argv.index("--phase") + 1]
        if len(argv) >= 3 and Path(argv[2]) == self.request.gate_plan_compiler:
            return "compiler"
        if len(argv) >= 3 and Path(argv[2]) == self.request.report_script:
            return "report"
        raise AssertionError(f"unexpected transaction argv: {argv!r}")

    def _begin_stdout(self) -> bytes:
        values = {
            "MACSCOPE_INSTALL_RELEASE_PHASE": "pending",
            "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN": TOKEN,
            "MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID": TRANSACTION_ID,
            "MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE": TRANSACTION_NONCE,
            "MACSCOPE_INSTALL_RELEASE_PENDING_STATE": str(
                self.pending.state_file.path
            ),
            "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256": (
                self.pending.state_sha256
            ),
            "MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT": str(
                self.pending.acceptance_receipt
            ),
        }
        return "".join(
            f"{key}={values[key]}\n" for key in transaction.BEGIN_STDOUT_KEYS
        ).encode("utf-8")

    def __call__(
        self,
        argv: tuple[str, ...],
        timeout_seconds: float,
        environment: Mapping[str, str],
    ) -> transaction.CommandResult:
        self.calls.append((argv, timeout_seconds, dict(environment)))
        stage = self.stage(argv)
        if stage == "rollback" and self.rollback_failure:
            return transaction.CommandResult(
                argv, 71, b"private rollback stdout\n", b"rollback refused\n"
            )
        if stage == self.timeout_stage:
            return transaction.CommandResult(
                argv,
                -signal.SIGTERM,
                b"private partial stdout",
                b"",
                timed_out=True,
            )
        if stage == self.signal_stage:
            return transaction.CommandResult(
                argv, -signal.SIGTERM, b"", b"terminated\n"
            )
        if stage == self.fail_stage:
            return transaction.CommandResult(
                argv, 70, b"private child stdout\n", b"stage refused\n"
            )
        if stage == "begin":
            stdout = self._begin_stdout()
        elif stage == "compiler":
            stdout = f"{self.request.gate_plan_path}\n".encode("utf-8")
        elif stage == "commit":
            stdout = (
                "MACSCOPE_INSTALL_RELEASE_PHASE=committed\n"
                f"MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN={TOKEN}\n"
            ).encode("utf-8")
        elif stage == "rollback":
            stdout = (
                "MACSCOPE_INSTALL_RELEASE_PHASE=rolled-back\n"
                f"MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN={TOKEN}\n"
            ).encode("utf-8")
        else:
            stdout = b"private report status\n"
        return transaction.CommandResult(argv, 0, stdout, b"")


class PreparedXctestrunSDKBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.products = Path(self.temporary.name).resolve()
        self.document = {"toolchain": {"sdk_version": "27.2"}}
        self.paths = tuple(self.products / f"{scheme}_macosx27.2-arm64.xctestrun"
                           for scheme in ("MacScopeApp", "MacScopeInstalledAppUITests"))
        for path in self.paths:
            path.write_bytes(b"receipt-bound plan")

    def test_uses_exact_27_2_preparation_sdk(self) -> None:
        self.assertEqual(transaction._prepared_xctestrun_paths(
            self.products, self.document, self.document), self.paths)

    def test_rejects_wrong_sdk_receipt_or_mismatched_receipts(self) -> None:
        wrong = {"toolchain": {"sdk_version": "27.0"}}
        for native, ui in ((wrong, wrong), (self.document, wrong), ({}, self.document)):
            with self.subTest(native=native, ui=ui):
                with self.assertRaises(transaction.TransactionError):
                    transaction._prepared_xctestrun_paths(self.products, native, ui)

    def test_rejects_ambiguous_and_indirect_products(self) -> None:
        stale = self.products / "MacScopeApp_macosx27.0-arm64.xctestrun"
        stale.write_bytes(b"stale")
        with self.assertRaises(transaction.TransactionError):
            transaction._prepared_xctestrun_paths(self.products, self.document, self.document)
        stale.unlink()
        original = self.products / "original"
        self.paths[0].rename(original)
        self.paths[0].symlink_to(original)
        with self.assertRaises(transaction.TransactionError):
            transaction._prepared_xctestrun_paths(self.products, self.document, self.document)


class InstalledAcceptanceTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.python = Path(sys.executable).resolve()

        self.candidate_root = self.root / "candidate-root"
        self.candidate_root.mkdir(mode=0o700)
        self.candidate_identity = self.candidate_root / "candidate.json"
        self._write_private(self.candidate_identity, b'{"schema_version":3}')
        self.preparation_receipt_path = (
            self.candidate_root / "NativeLivePreparation.receipt.json"
        )
        self._write_private(
            self.preparation_receipt_path, b'{"schema_version":2}'
        )
        self.installed_ui_preparation_receipt_path = (
            self.candidate_root / "InstalledUIPreparation.receipt.json"
        )
        self._write_private(
            self.installed_ui_preparation_receipt_path,
            b'{"schema_version":2}',
        )
        self.native_xctestrun_path = self.root / "Native.xctestrun"
        self._write_private(self.native_xctestrun_path, b"prepared test plan")
        self.installed_ui_xctestrun_path = self.root / "InstalledUI.xctestrun"
        self._write_private(
            self.installed_ui_xctestrun_path, b"installed UI test plan"
        )
        self.installed_ui_runner = (
            self.root / "Products/Debug/MacScopeInstalledAppUITests-Runner.app"
        )
        self.installed_ui_runner.mkdir(parents=True, mode=0o700)
        self.installed_ui_test_bundle = (
            self.installed_ui_runner
            / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        )
        self.installed_ui_test_bundle.mkdir(parents=True, mode=0o700)
        self.qualification_receipt_path = self.root / "QUALIFICATION_INPUTS.json"
        self._write_private(
            self.qualification_receipt_path, b'{"schema_version":4}'
        )

        self.source_app = self.root / "Release" / "MacScope.app"
        self.source_app.mkdir(parents=True, mode=0o700)
        self.provenance_path = (
            self.source_app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        )
        self._write_private(self.provenance_path, b"source provenance")
        self.developer_dir = self.root / "Xcode.app" / "Contents" / "Developer"
        self.developer_dir.mkdir(parents=True, mode=0o700)
        self.installed_ui_preparation_document = {
            "artifacts": {
                "ui_runner": {
                    "closed_tree_sha256": "8" * 64,
                    "executable_sha256": "9" * 64,
                },
                "ui_test_bundle": {
                    "closed_tree_sha256": "a" * 64,
                    "executable_sha256": "b" * 64,
                },
            },
            "toolchain": {"developer_dir": str(self.developer_dir)},
        }

        self.applications = self.root / "Applications"
        self.applications.mkdir(mode=0o700)
        self.installed_app = self.applications / "MacScope.app"
        self.work_root = self.root / "transaction-work"
        self.work_root.mkdir(mode=0o700)

        self.request = self._make_request()
        self.pending = self._make_pending()
        self.task10 = self._synthetic_task10()
        self.plan = self._synthetic_plan()
        self.gate_snapshots = self._synthetic_gate_snapshots()
        self.ws24_inputs = transaction.WS24Inputs(
            live_evidence=self.gate_snapshots[6][1],
            full_surface=self.gate_snapshots[2][1],
            legacy_grid=self.gate_snapshots[1][1],
            cli_gui=self.gate_snapshots[0][1],
            mcp=self.gate_snapshots[4][1],
            native_xpc=self.gate_snapshots[5][1],
        )
        self.report_plan, self.gate_plans = self._synthetic_qualification_plans()
        self.publication = self._synthetic_publication()
        self.terminal = self._synthetic_terminal()
        self.outcome = transaction.TransactionOutcome(
            self.request.result_output.path,
            {"result": "passed"},
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _write_private(path: Path, payload: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(payload)
        path.chmod(0o600)

    def _snapshot(
        self,
        path: Path,
        payload: bytes = b"evidence",
        *,
        maximum_bytes: int = 16 * 1024 * 1024,
    ) -> transaction.FileSnapshot:
        if not path.exists():
            self._write_private(path, payload)
        return transaction._read_stable_file(
            path, label=path.name, maximum_bytes=maximum_bytes
        )

    def _make_request(self) -> transaction.BoundRequest:
        return transaction.BoundRequest(
            python_executable=self.python,
            installer_script=self.python,
            report_script=self.root / "ws24_emit.py",
            gate_plan_compiler=self.root / "compile_plan.py",
            task10_matrix_script=self.root / "run_installed_task10_matrix.py",
            incremental_xcuitest_script=(
                self.root / "emit_installed_incremental_xcuitest_evidence.py"
            ),
            qualification_receipt=self._snapshot(
                self.qualification_receipt_path
            ),
            candidate_artifact_root=self.candidate_root,
            candidate_identity=self.candidate_identity,
            preparation_receipt=self._snapshot(self.preparation_receipt_path),
            installed_ui_preparation_receipt=self._snapshot(
                self.installed_ui_preparation_receipt_path
            ),
            installed_ui_preparation_document=(
                self.installed_ui_preparation_document
            ),
            installed_ui_prepared_app=self.source_app,
            installed_ui_xctestrun=self._snapshot(
                self.installed_ui_xctestrun_path
            ),
            installed_ui_test_bundle=self.installed_ui_test_bundle,
            installed_ui_runner=self.installed_ui_runner,
            native_xctestrun=self._snapshot(self.native_xctestrun_path),
            source_app=self.source_app,
            installed_app=self.installed_app,
            work_root=self.work_root,
            artifact_root=(
                self.work_root / transaction.INSTALLER_ARTIFACT_ROOT_NAME
            ),
            evidence_root=self.work_root / transaction.GATE_EVIDENCE_ROOT_NAME,
            qualification_root=(
                self.work_root / transaction.QUALIFICATION_ROOT_NAME
            ),
            gate_plan_path=(
                self.work_root
                / transaction.GATE_EVIDENCE_ROOT_NAME
                / transaction.GATE_PLAN_NAME
            ),
            result_output=transaction._plan_absent_file(
                self.work_root / transaction.RESULT_NAME,
                label="transaction result",
                maximum_bytes=transaction.MAX_RESULT_BYTES,
            ),
            qualification_run=QualificationRunAuthority(
                run_id="installed-acceptance-run", nonce=RUN_NONCE
            ),
            predecessor_observations_sha256=PREDECESSOR_OBSERVATIONS,
            xcode_developer_dir=self.developer_dir,
            source_authority=object(),
            candidate_token=TOKEN,
            candidate_identity_snapshot=self._snapshot(self.candidate_identity),
            provenance_snapshot=self._snapshot(self.provenance_path),
            timeouts=transaction.Timeouts(
                begin=11.0,
                compiler=22.0,
                report=33.0,
                commit=44.0,
                rollback=55.0,
            ),
        )

    def _pending_state(self) -> dict[str, object]:
        return {
            "acceptance_receipt_path": str(
                self.request.artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
            ),
            "application_executable_sha256": APPLICATION_DIGEST,
            "artifact_root": str(self.request.artifact_root),
            "artifact_root_identity": {
                "directory_device": 10,
                "directory_inode": 11,
                "parent_device": 12,
                "parent_inode": 13,
                "path": str(self.request.artifact_root),
                "state_at_begin": "absent",
            },
            "began_at_unix_ns": 1,
            "build_provenance_sha256": PROVENANCE_DIGEST,
            "candidate_file_sha256": CANDIDATE_FILE_DIGEST,
            "candidate_identity": {"content_sha256": TOKEN},
            "candidate_identity_sha256": TOKEN,
            "candidate_token": TOKEN,
            "destination_identity": {
                "path": str(self.installed_app),
                "content_sha256": TOKEN,
            },
            "execution_identity_sha256": EXECUTION_DIGEST,
            "exposed_at_unix_ns": EXPOSED_AT,
            "installed_app_path": str(self.installed_app),
            "phase": "pending",
            "predecessor_digest": None,
            "predecessor_identity": None,
            "predecessor_observations_sha256": PREDECESSOR_OBSERVATIONS,
            "predecessor_path": str(self.applications / ".MacScope.predecessor"),
            "predecessor_present": False,
            "qualification_run_id": self.request.qualification_run.run_id,
            "qualification_run_nonce": self.request.qualification_run.nonce,
            "schema_version": installer.PENDING_TRANSACTION_SCHEMA_VERSION,
            "source_app_path": str(self.source_app),
            "source_commit": SOURCE_COMMIT,
            "source_equality_sha256": SOURCE_EQUALITY_DIGEST,
            "source_tree": SOURCE_TREE,
            "transaction_id": TRANSACTION_ID,
            "transaction_nonce": TRANSACTION_NONCE,
        }

    def _make_pending(self) -> transaction.PendingBinding:
        state = self._pending_state()
        payload = canonical_bytes(state)
        path = (
            self.applications / f".MacScope.pending-{TOKEN}" / "transaction.json"
        )
        stable = installer.StableFile(
            path=path,
            metadata=(1, 2, 0o600, 1, len(payload), EXPOSED_AT),
            payload=payload,
        )
        return transaction.PendingBinding(
            state=state,
            state_file=stable,
            state_sha256=hashlib.sha256(payload).hexdigest(),
            transaction_id=TRANSACTION_ID,
            transaction_nonce=TRANSACTION_NONCE,
            acceptance_receipt=(
                self.request.artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
            ),
        )

    def _synthetic_plan(self) -> transaction.GatePlan:
        snapshot = self._snapshot(self.root / "fixtures" / "plan.json")
        return transaction.GatePlan(snapshot, {}, "8" * 64, ())

    def _synthetic_task10(self) -> transaction.Task10Publication:
        parent = self.root / "fixtures" / "task10"
        parent.mkdir(parents=True, mode=0o700)
        xcresult = parent / transaction.TASK10_XCRESULT_NAME
        xcresult.mkdir(mode=0o700)
        network = parent / transaction.TASK10_NETWORK_ROOT_NAME
        network.mkdir(mode=0o700)
        matrix_receipt = self._snapshot(
            parent / transaction.TASK10_MATRIX_RECEIPT_NAME,
            b"matrix receipt",
        )
        semantic = self._snapshot(
            parent / transaction.TASK10_SEMANTIC_MANIFEST_NAME,
            b"semantic manifest",
        )
        audit = self._snapshot(
            network / transaction.NETWORK_AUDIT_REPORT_NAME,
            b"network audit",
        )
        execution = self._snapshot(
            network / transaction.NETWORK_EXECUTION_REPORT_NAME,
            b"network execution",
        )
        observation = self._snapshot(
            network / transaction.NETWORK_OBSERVATION_NAME,
            b"network observation",
        )
        incremental = self._snapshot(
            network / transaction.TASK10_INCREMENTAL_EVIDENCE_NAME,
            b"incremental evidence",
        )
        metadata = parent.stat()
        paths = transaction.Task10Paths(
            xcresult=xcresult,
            semantic_manifest=transaction.PlannedFile(
                semantic.path,
                metadata.st_dev,
                metadata.st_ino,
                transaction.MAX_TASK10_SEMANTIC_MANIFEST_BYTES,
            ),
            matrix_receipt=transaction.PlannedFile(
                matrix_receipt.path,
                metadata.st_dev,
                metadata.st_ino,
                transaction.MAX_TASK10_RECEIPT_BYTES,
            ),
            network_root=network,
            incremental_evidence=incremental.path,
        )
        return transaction.Task10Publication(
            paths=paths,
            matrix_receipt=matrix_receipt,
            semantic_manifest=semantic,
            incremental_evidence=incremental,
            xcresult=transaction._directory_identity(
                xcresult, label="synthetic Task10 xcresult"
            ),
            network_root=transaction._directory_identity(
                network, label="synthetic Task10 network root"
            ),
            xcresult_bundle_sha256="c" * 64,
            xcresult_closed_tree_sha256="d" * 64,
            network_audit_report=audit,
            network_execution_report=execution,
            network_observation=observation,
        )

    def _task10_validation_fixture(self) -> dict[str, object]:
        root = self.root / "task10-validation"
        root.mkdir(mode=0o700)
        xcresult = root / transaction.TASK10_XCRESULT_NAME
        xcresult.mkdir(mode=0o700)
        network_root = root / transaction.TASK10_NETWORK_ROOT_NAME
        network_root.mkdir(mode=0o700)
        installed_executable = self.installed_app / "Contents/MacOS/MacScope"
        self._write_private(installed_executable, b"installed executable")
        observer_tool = self.root / "nettop"
        self._write_private(observer_tool, b"governed observer")

        projection = transaction.ws24.installed_selector_projection(
            transaction.ws24.load_installed_selector_catalog()
        )
        selectors = [item["test_identifier"] for item in projection]
        receipt = {
            "schema_version": transaction.matrix.SCHEMA_VERSION,
            "candidate": {
                "identity_path": str(self.candidate_identity),
                "identity_sha256": TOKEN,
                "source_commit": SOURCE_COMMIT,
                "source_tree": SOURCE_TREE,
                "preparation_receipt_path": str(
                    self.request.installed_ui_preparation_receipt.path
                ),
            },
            "execution": {
                "started_at_unix_ms": 111,
                "ended_at_unix_ms": 119,
                "result": "passed",
                "selectors": selectors,
            },
            "products": {
                "installed_app": {
                    "path": str(self.installed_app),
                    "executable_sha256": APPLICATION_DIGEST,
                },
                "xcresult": {
                    "path": str(xcresult),
                    "closed_tree_sha256": "d" * 64,
                },
            },
        }
        matrix_path = root / transaction.TASK10_MATRIX_RECEIPT_NAME
        self._write_private(matrix_path, canonical_bytes(receipt))
        matrix_sha256 = hashlib.sha256(matrix_path.read_bytes()).hexdigest()
        semantic = {
            "schema_version": 3,
            "candidate_identity_sha256": TOKEN,
            "source_xcresult": {
                "bundle_sha256": "c" * 64,
                "closed_tree_sha256": "d" * 64,
            },
            "selector_catalog_sha256": hashlib.sha256(
                canonical_bytes(selectors)
            ).hexdigest(),
            "selector_projection": projection,
            "selector_projection_sha256": hashlib.sha256(
                canonical_bytes(projection)
            ).hexdigest(),
            "observed_selector_projection": [],
            "observed_selector_projection_sha256": hashlib.sha256(
                canonical_bytes([])
            ).hexdigest(),
            "expected_selector_count": 22,
            "executed_selector_count": 22,
            "passed_selector_count": 22,
            "failed_selector_count": 0,
            "skipped_selector_count": 0,
            "selectors": [
                {"test_identifier": identifier, "status": "passed"}
                for identifier in selectors
            ],
            "result": "passed",
        }
        semantic_path = root / transaction.TASK10_SEMANTIC_MANIFEST_NAME
        self._write_private(semantic_path, canonical_bytes(semantic))
        semantic_sha256 = hashlib.sha256(semantic_path.read_bytes()).hexdigest()
        observation_path = network_root / transaction.NETWORK_OBSERVATION_NAME
        observation = b",bytes_in,bytes_out,\n"
        self._write_private(observation_path, observation)
        execution_path = (
            network_root / transaction.NETWORK_EXECUTION_REPORT_NAME
        )
        execution = {
            "schema_version": 2,
            "qualification_run": {
                "run_id": self.request.qualification_run.run_id,
                "nonce": self.request.qualification_run.nonce,
            },
            "predecessor_observations_sha256": PREDECESSOR_OBSERVATIONS,
            "started_at_unix_ms": 100,
            "ended_at_unix_ms": 130,
            "result": "passed",
            "exit_code": 0,
            "stress": None,
        }
        self._write_private(execution_path, canonical_bytes(execution))
        audit = {
            "schema_version": 4,
            "attribution": {
                "policy_id": "prearmed-kqueue-path-v1", "observer_spawn_ns": 10,
                "observer_eof_ns": 20, "queue_closed_ns": 30, "proofs": [],
                "drains": [{"drain_id": 1, "begin_monotonic_ns": 25,
                            "end_monotonic_ns": 26, "completed_to_empty": True, "events": []}],
            },
            "command_id": "installed.network-acquisition-audit",
            "evidence_layer": "installed-launch-log",
            "candidate": {
                "identity_sha256": TOKEN,
                "document_sha256": CANDIDATE_FILE_DIGEST,
                "source_commit": SOURCE_COMMIT,
                "source_tree": SOURCE_TREE,
            },
            "workload": {
                "command_id": "installed.task10-workflow",
                "started_at_unix_ms": 110,
                "ended_at_unix_ms": 120,
                "observer_ready_at_unix_ms": 100,
                "observer_readiness_precedes_workload": True,
                "observation_contains_workload": True,
                "matrix_receipt_sha256": matrix_sha256,
                "xcresult_bundle_sha256": "c" * 64,
                "xcresult_closed_tree_sha256": "d" * 64,
                "xcresult_semantic_manifest_sha256": semantic_sha256,
                "selector_catalog_sha256": hashlib.sha256(
                    canonical_bytes(selectors)
                ).hexdigest(),
                "selector_projection_sha256": hashlib.sha256(
                    canonical_bytes(projection)
                ).hexdigest(),
                "expected_selector_count": 22,
                "executed_selector_count": 22,
                "passed_selector_count": 22,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
                "matrix_result": "passed",
            },
            "executables": [
                {
                    "identity_id": "app",
                    "executable_path": str(installed_executable),
                    "executable_sha256": APPLICATION_DIGEST,
                    "processes": [
                        {"pid": 101, "start_time_unix_us": 1_000}
                    ],
                }
            ],
            "observer": {
                "observer_id": (
                    transaction.task10_evidence.network.MATRIX_OBSERVER_ID
                ),
                "evidence_scope": transaction.task10_evidence.network.MATRIX_EVIDENCE_SCOPE,
                "limitations": list(transaction.task10_evidence.network.MATRIX_LIMITATIONS),
                "observed_candidate_row_count": 0,
                "observed_foreign_row_count": 0,
                "observed_unresolved_row_count": 0,
                "tool_path": str(observer_tool),
                "tool_sha256": hashlib.sha256(
                    observer_tool.read_bytes()
                ).hexdigest(),
                "interface_scope": ["external", "undefined"],
                "loopback_excluded": True,
                "observed_sample_count": 1,
                "observed_process_row_count": 0,
                "observer_invocation_count": 1,
                "continuous_interval_started_at_unix_ms": 100,
                "continuous_interval_ready_at_unix_ms": 100,
                "continuous_interval_ended_at_unix_ms": 130,
                "readiness_frame_sha256": hashlib.sha256(
                    transaction.task10_evidence.network.MATRIX_OBSERVER_READY_FRAME
                ).hexdigest(),
                "readiness_proven": True,
                "stopped_by_auditor": True,
                "continuity_proven": True,
                "observation_byte_count": len(observation),
                "observation_sha256": hashlib.sha256(observation).hexdigest(),
                "availability": "available",
            },
            "artifacts": [],
            "started_at_unix_ms": 100,
            "ended_at_unix_ms": 130,
            "result": "passed",
            "exit_code": 0,
            "diagnostic": None,
        }
        for role, name in transaction.task10_evidence.network.MANDATORY_EXECUTABLE_NAMES.items():
            audit["executables"].append({"identity_id": role,
                "executable_path": str(self.installed_app / "Contents/XPCServices" / f"{name}.xpc"
                                       / "Contents/MacOS" / name),
                "executable_sha256": "d" * 64, "processes": []})
        audit_path = network_root / transaction.NETWORK_AUDIT_REPORT_NAME
        self._write_private(audit_path, canonical_bytes(audit))
        parent = root.stat()
        paths = transaction.Task10Paths(
            xcresult=xcresult,
            semantic_manifest=transaction.PlannedFile(
                semantic_path,
                parent.st_dev,
                parent.st_ino,
                transaction.MAX_TASK10_SEMANTIC_MANIFEST_BYTES,
            ),
            matrix_receipt=transaction.PlannedFile(
                matrix_path,
                parent.st_dev,
                parent.st_ino,
                transaction.MAX_TASK10_RECEIPT_BYTES,
            ),
            network_root=network_root,
            incremental_evidence=(
                network_root / transaction.TASK10_INCREMENTAL_EVIDENCE_NAME
            ),
        )
        fixture = {
            "paths": paths,
            "receipt": receipt,
            "receipt_sha256": matrix_sha256,
            "semantic": semantic,
            "audit": audit,
            "audit_path": audit_path,
            "execution_path": execution_path,
            "observation_path": observation_path,
            "observer_tool": observer_tool,
            "authorities": tuple(transaction.task10_evidence.network.ExecutableAuthority(
                item["identity_id"], item["executable_path"], item["executable_sha256"])
                for item in audit["executables"]),
        }
        self._refresh_task10_incremental(fixture)
        return fixture

    def _refresh_task10_incremental(self, fixture: Mapping[str, object]) -> None:
        paths = fixture["paths"]
        assert isinstance(paths, transaction.Task10Paths)
        descriptor = transaction.task10_evidence._descriptor(
            receipt_path=paths.matrix_receipt.path,
            receipt_sha256=hashlib.sha256(
                paths.matrix_receipt.path.read_bytes()
            ).hexdigest(),
            xcresult_path=paths.xcresult,
            semantic_path=paths.semantic_manifest.path,
            semantic_sha256=hashlib.sha256(
                paths.semantic_manifest.path.read_bytes()
            ).hexdigest(),
            network_report_path=fixture["audit_path"],
            network_report_sha256=hashlib.sha256(
                Path(fixture["audit_path"]).read_bytes()
            ).hexdigest(),
            execution_report_path=fixture["execution_path"],
            execution_report_sha256=hashlib.sha256(
                Path(fixture["execution_path"]).read_bytes()
            ).hexdigest(),
            observation_path=fixture["observation_path"],
            observation_sha256=hashlib.sha256(
                Path(fixture["observation_path"]).read_bytes()
            ).hexdigest(),
        )
        self._write_private(
            paths.incremental_evidence, canonical_bytes(descriptor)
        )

    @contextlib.contextmanager
    def _task10_validation_patches(
        self, fixture: Mapping[str, object]
    ) -> Iterator[None]:
        receipt = fixture["receipt"]
        receipt_sha256 = fixture["receipt_sha256"]
        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(
                    transaction.matrix,
                    "load_receipt_with_sha256",
                    return_value=(receipt, receipt_sha256),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.matrix,
                    "validate_receipt",
                    return_value=receipt_sha256,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.task10_evidence.network,
                    "load_candidate",
                    return_value=(object(), CANDIDATE_FILE_DIGEST),
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.task10_evidence.network,
                    "inspect_candidate_executables",
                    return_value=fixture["authorities"],
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.task10_evidence.network,
                    "NETTOP_PATH",
                    fixture["observer_tool"],
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.task10_evidence,
                    "candidate_identity_sha256",
                    return_value=TOKEN,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.ws24,
                    "result_bundle_sha256",
                    return_value="c" * 64,
                )
            )
            stack.enter_context(
                mock.patch.object(
                    transaction.task10_evidence.accessibility,
                    "validate_semantic_manifest",
                    return_value=fixture["semantic"],
                )
            )
            yield

    def _validate_task10_fixture(
        self, fixture: Mapping[str, object]
    ) -> transaction.Task10Publication:
        paths = fixture["paths"]
        assert isinstance(paths, transaction.Task10Paths)
        incremental = self._snapshot(
            paths.incremental_evidence,
            maximum_bytes=transaction.MAX_INCREMENTAL_XCUITEST_EVIDENCE_BYTES,
        )
        with self._task10_validation_patches(fixture):
            return transaction._validate_task10_publication(
                self.request, self.pending, paths, incremental
            )

    def test_task10_publication_accepts_authoritative_closed_schema4(self) -> None:
        fixture = self._task10_validation_fixture()

        publication = self._validate_task10_fixture(fixture)

        document = transaction.decode_canonical_bytes(
            publication.network_audit_report.payload
        )
        self.assertEqual(document["schema_version"], 4)
        self.assertEqual(
            document["workload"]["matrix_receipt_sha256"],
            publication.matrix_receipt.sha256,
        )
        self.assertEqual(document["observer"]["observed_process_row_count"], 0)

    def test_task10_publication_replays_foreign_rows_and_rejects_unknown_pid(self) -> None:
        from Scripts.tests.test_network_attribution import fixture as proof_fixture
        fixture = self._task10_validation_fixture()
        proofs, drains = proof_fixture()
        audit = fixture["audit"]
        audit["attribution"].update(proofs=proofs, drains=drains)
        audit["observer"].update(observed_process_row_count=1, observed_foreign_row_count=1)
        for pid in (10, 999):
            payload = f",bytes_in,bytes_out,\nforeign.{pid},0,0,\n".encode()
            audit["observer"].update(observation_byte_count=len(payload),
                observation_sha256=hashlib.sha256(payload).hexdigest())
            self._write_private(fixture["observation_path"], payload)
            self._write_private(fixture["audit_path"], canonical_bytes(audit))
            self._refresh_task10_incremental(fixture)
            if pid == 10:
                self._validate_task10_fixture(fixture)
            else:
                with self.assertRaises(transaction.TransactionError):
                    self._validate_task10_fixture(fixture)

    def test_task10_publication_rejects_rehashed_attribution_change(self) -> None:
        fixture = self._task10_validation_fixture()
        fixture["audit"]["attribution"]["drains"][0]["completed_to_empty"] = False
        self._write_private(fixture["audit_path"], canonical_bytes(fixture["audit"]))
        self._refresh_task10_incremental(fixture)
        with self.assertRaises(transaction.TransactionError):
            self._validate_task10_fixture(fixture)

    def test_task10_publication_rejects_legacy_schema1_even_when_rehashed(self) -> None:
        fixture = self._task10_validation_fixture()
        audit = copy.deepcopy(fixture["audit"])
        audit["schema_version"] = 1
        self._write_private(
            Path(fixture["audit_path"]), canonical_bytes(audit)
        )
        self._refresh_task10_incremental(fixture)

        with self.assertRaisesRegex(
            transaction.TransactionError, "publication is invalid"
        ):
            self._validate_task10_fixture(fixture)

    def test_task10_publication_rejects_stale_incremental_descriptor(self) -> None:
        fixture = self._task10_validation_fixture()
        paths = fixture["paths"]
        assert isinstance(paths, transaction.Task10Paths)
        descriptor = transaction.decode_canonical_bytes(
            paths.incremental_evidence.read_bytes()
        )
        descriptor["evidence"][0]["proofArtifacts"][0]["sha256"] = "0" * 64
        self._write_private(
            paths.incremental_evidence, canonical_bytes(descriptor)
        )

        with self.assertRaisesRegex(
            transaction.TransactionError, "do not cross-bind"
        ):
            self._validate_task10_fixture(fixture)

    def test_task10_publication_rejects_authority_digest_and_zero_result_mismatch(
        self,
    ) -> None:
        fixture = self._task10_validation_fixture()
        original = copy.deepcopy(fixture["audit"])
        cases = (
            (
                "candidate authority",
                lambda value: value["candidate"].__setitem__(
                    "document_sha256", "0" * 64
                ),
            ),
            (
                "matrix digest",
                lambda value: value["workload"].__setitem__(
                    "matrix_receipt_sha256", "1" * 64
                ),
            ),
            (
                "non-loopback row",
                lambda value: value["observer"].__setitem__(
                    "observed_process_row_count", 1
                ),
            ),
        )
        for label, mutate in cases:
            with self.subTest(label=label):
                audit = copy.deepcopy(original)
                mutate(audit)
                self._write_private(
                    Path(fixture["audit_path"]), canonical_bytes(audit)
                )
                self._refresh_task10_incremental(fixture)
                with self.assertRaisesRegex(
                    transaction.TransactionError, "publication is invalid"
                ):
                    self._validate_task10_fixture(fixture)

    def _synthetic_gate_snapshots(
        self,
    ) -> tuple[tuple[str, transaction.FileSnapshot], ...]:
        names = {
            "cli": transaction.CLI_GUI_REPORT_NAME,
            "forced-legacy-grid": "full-surface.legacy-grid.json",
            "full-surface": "full-surface.json",
            "gui": "gui.stdout",
            "mcp": transaction.MCP_REPORT_NAME,
            "native-xpc": transaction.ws24.NATIVE_XPC_EXECUTION_REPORT_NAME,
            "shellbroker-launchagent": transaction.LIVE_EVIDENCE_NAME,
            "signing": "signing.stdout",
        }
        return tuple(
            (
                gate_id,
                self._snapshot(
                    self.root / "fixtures" / "gate-outputs" / names[gate_id],
                    f"{gate_id} evidence".encode("utf-8"),
                ),
            )
            for gate_id in transaction.REQUIRED_ACCEPTANCE_GATES
        )

    def _synthetic_qualification_plans(
        self,
    ) -> tuple[
        transaction.PlannedFile,
        tuple[tuple[str, transaction.PlannedFile], ...],
    ]:
        parent = self.request.qualification_root
        parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        metadata = parent.stat()
        report = transaction.PlannedFile(
            parent / transaction.WS24_REPORT_NAME,
            metadata.st_dev,
            metadata.st_ino,
            8 * 1024 * 1024,
        )
        gates = tuple(
            (
                gate_id,
                transaction.PlannedFile(
                    parent / f"{gate_id}.acceptance-gate.json",
                    metadata.st_dev,
                    metadata.st_ino,
                    1024 * 1024,
                ),
            )
            for gate_id in transaction.REQUIRED_ACCEPTANCE_GATES
        )
        return report, gates

    def _synthetic_publication(self) -> transaction.WS24Publication:
        report = self._snapshot(
            self.root / "fixtures" / "publication" / transaction.WS24_REPORT_NAME,
            b"aggregate",
        )
        gates = tuple(
            (
                gate_id,
                self._snapshot(
                    self.root
                    / "fixtures"
                    / "publication"
                    / f"{gate_id}.acceptance-gate.json",
                    gate_id.encode("utf-8"),
                ),
            )
            for gate_id in transaction.REQUIRED_ACCEPTANCE_GATES
        )
        return transaction.WS24Publication(report, gates)

    def _synthetic_terminal(self) -> transaction.TerminalBinding:
        root = self.root / "fixtures" / "committed"
        state_path = root / "transaction.json"
        self._write_private(state_path, self.pending.state_file.payload)
        return transaction.TerminalBinding(
            committed_root=root,
            state=self._snapshot(
                state_path,
                maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
            ),
            acceptance_receipt=self._snapshot(
                root / "MacScopeInstaller.acceptance-receipt.json",
                b"acceptance receipt",
            ),
            commit_authority=self._snapshot(
                root / "commit-authority.json", b"commit authority"
            ),
        )

    @contextlib.contextmanager
    def _transaction_mocks(
        self,
        *,
        failing_function: str | None = None,
        pending_assert_side_effect: object | None = None,
    ) -> Iterator[dict[str, mock.Mock]]:
        defaults: dict[str, object] = {
            "require_app_quiescent": None,
            "_load_pending_binding": self.pending,
            "_create_private_directory": self.request.evidence_root,
            "_assert_pending_unchanged": None,
            "_load_gate_plan": self.plan,
            "_qualification_plans": (self.report_plan, self.gate_plans),
            "_run_task10_prerequisite": self.task10,
            "_execute_gate_plan": transaction.GateExecution(
                self.gate_snapshots, self.publication
            ),
            "_assert_snapshot_unchanged": None,
            "_validate_terminal_commit": self.terminal,
            "_publish_result": self.outcome,
        }
        with contextlib.ExitStack() as stack:
            mocks: dict[str, mock.Mock] = {}
            for name, return_value in defaults.items():
                patched = stack.enter_context(
                    mock.patch.object(transaction, name, return_value=return_value)
                )
                mocks[name] = patched
            if failing_function is not None:
                mocks[failing_function].side_effect = transaction.TransactionError(
                    f"{failing_function} refused"
                )
            if pending_assert_side_effect is not None:
                mocks["_assert_pending_unchanged"].side_effect = (
                    pending_assert_side_effect
                )
            if failing_function != "_execute_gate_plan":
                def execute_gate_plan(
                    request: transaction.BoundRequest,
                    pending: transaction.PendingBinding,
                    plan: transaction.GatePlan,
                    report_plan: transaction.PlannedFile,
                    gate_plans: Sequence[tuple[str, transaction.PlannedFile]],
                    runner: transaction.CommandRunner,
                ) -> transaction.GateExecution:
                    del plan
                    inputs = self.ws24_inputs
                    result = runner(
                        transaction._report_argv(
                            request, pending, inputs, report_plan, gate_plans
                        ),
                        min(120.0, request.timeouts.report),
                        transaction.BASE_ENVIRONMENT,
                    )
                    transaction._require_successful_command(
                        result,
                        label="final WS24 operation",
                        require_empty_stderr=True,
                    )
                    return transaction.GateExecution(
                        self.gate_snapshots, self.publication
                    )

                mocks["_execute_gate_plan"].side_effect = execute_gate_plan
            yield mocks

    def _plan_authority(self) -> dict[str, object]:
        state = self.pending.state
        return {
            "application_executable_sha256": APPLICATION_DIGEST,
            "artifact_root_identity_sha256": hashlib.sha256(
                canonical_bytes(state["artifact_root_identity"])
            ).hexdigest(),
            "artifact_root_path": str(self.request.artifact_root),
            "began_at_unix_ns": state["began_at_unix_ns"],
            "build_provenance_sha256": PROVENANCE_DIGEST,
            "candidate_file_sha256": CANDIDATE_FILE_DIGEST,
            "candidate_identity_path": str(self.candidate_identity),
            "candidate_identity_sha256": TOKEN,
            "destination_identity_sha256": hashlib.sha256(
                canonical_bytes(state["destination_identity"])
            ).hexdigest(),
            "execution_identity_sha256": EXECUTION_DIGEST,
            "exposed_at_unix_ns": EXPOSED_AT,
            "installed_app_path": str(self.installed_app),
            "installed_ui_preparation_receipt_path": str(
                self.request.installed_ui_preparation_receipt.path
            ),
            "installed_ui_preparation_receipt_sha256": (
                self.request.installed_ui_preparation_receipt.sha256
            ),
            "installed_ui_runner_closed_tree_sha256": "8" * 64,
            "installed_ui_runner_executable_sha256": "9" * 64,
            "installed_ui_runner_path": str(self.installed_ui_runner),
            "installed_ui_test_bundle_closed_tree_sha256": "a" * 64,
            "installed_ui_test_bundle_executable_sha256": "b" * 64,
            "installed_ui_test_bundle_path": str(
                self.installed_ui_test_bundle
            ),
            "installed_ui_xctestrun_path": str(
                self.request.installed_ui_xctestrun.path
            ),
            "installed_ui_xctestrun_sha256": (
                self.request.installed_ui_xctestrun.sha256
            ),
            **transaction._task10_authority_paths(self.request),
            "native_preparation_receipt_path": str(
                self.request.preparation_receipt.path
            ),
            "native_preparation_receipt_sha256": (
                self.request.preparation_receipt.sha256
            ),
            "native_xctestrun_path": str(self.request.native_xctestrun.path),
            "native_xctestrun_sha256": self.request.native_xctestrun.sha256,
            "pending_state_path": str(self.pending.state_file.path),
            "pending_state_sha256": self.pending.state_sha256,
            "predecessor_digest": None,
            "predecessor_observations_sha256": PREDECESSOR_OBSERVATIONS,
            "qualification_receipt_path": str(
                self.request.qualification_receipt.path
            ),
            "qualification_receipt_sha256": (
                self.request.qualification_receipt.sha256
            ),
            "qualification_run_id": self.request.qualification_run.run_id,
            "qualification_run_nonce": self.request.qualification_run.nonce,
            "source_app_path": str(self.source_app),
            "source_commit": SOURCE_COMMIT,
            "source_equality_sha256": SOURCE_EQUALITY_DIGEST,
            "source_tree": SOURCE_TREE,
            "transaction_id": TRANSACTION_ID,
            "transaction_nonce": TRANSACTION_NONCE,
        }

    def _plan_document(self) -> dict[str, object]:
        authority = self._plan_authority()
        authority_sha256 = hashlib.sha256(canonical_bytes(authority)).hexdigest()
        environment = {
            **transaction.BASE_ENVIRONMENT,
            "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": authority_sha256,
        }
        outputs: dict[str, tuple[Path, str]] = {
            "cli": (
                self.request.evidence_root / transaction.CLI_GUI_REPORT_NAME,
                "command-file",
            ),
            "forced-legacy-grid": (
                self.request.evidence_root / "full-surface.legacy-grid.json",
                "command-file",
            ),
            "full-surface": (
                self.request.evidence_root / "full-surface.json",
                "command-file",
            ),
            "gui": (
                self.request.evidence_root / "gui.stdout",
                "captured-stdout",
            ),
            "mcp": (
                self.request.evidence_root / transaction.MCP_REPORT_NAME,
                "command-file",
            ),
            "native-xpc": (
                self.request.evidence_root
                / "native-xpc-artifacts"
                / transaction.ws24.NATIVE_XPC_EXECUTION_REPORT_NAME,
                "command-file",
            ),
            "shellbroker-launchagent": (
                self.request.evidence_root / transaction.LIVE_EVIDENCE_NAME,
                "command-file",
            ),
            "signing": (self.report_plan.path, "command-file"),
        }
        operation_ids = {
            "cli": "cli-gui-operability",
            "gui": "cli-gui-operability",
            "forced-legacy-grid": "renderer-dual",
            "full-surface": "renderer-dual",
            "mcp": "mcp-operability",
            "native-xpc": "native-xpc-probe",
            "shellbroker-launchagent": "shellbroker-launchagent-probe",
            "signing": "ws24-installed-qualification",
        }
        timeout = {
            "cli": 60,
            "gui": 60,
            "forced-legacy-grid": 90,
            "full-surface": 90,
            "mcp": 60,
            "native-xpc": 300,
            "shellbroker-launchagent": 1860,
            "signing": 120,
        }
        argv_by_operation: dict[str, list[str]] = {}
        gates: list[dict[str, object]] = []
        for gate_id in transaction.REQUIRED_ACCEPTANCE_GATES:
            operation_id = operation_ids[gate_id]
            argv = argv_by_operation.setdefault(
                operation_id,
                [
                    str(self.python),
                    "-c",
                    f"operation={operation_id}",
                    "$(never-expanded)",
                    "*.app",
                ],
            )
            output_path, kind = outputs[gate_id]
            gates.append(
                {
                    "gate_id": gate_id,
                    "operation_id": operation_id,
                    "authority_sha256": authority_sha256,
                    "argv": argv,
                    "depends_on": (
                        [
                            item
                            for item in transaction.REQUIRED_ACCEPTANCE_GATES
                            if item != "signing"
                        ]
                        if gate_id == "signing"
                        else []
                    ),
                    "environment": dict(environment),
                    "timeout_seconds": timeout[gate_id],
                    "output": {
                        "kind": kind,
                        "maximum_bytes": (
                            transaction.GATE_OUTPUT_MAXIMUM_BYTES[gate_id]
                        ),
                        "path": str(output_path),
                        "publication": "create-only",
                    },
                }
            )
        by_id = {item["gate_id"]: item for item in gates}

        def planned_snapshot(gate_id: str) -> transaction.FileSnapshot:
            return transaction.FileSnapshot(
                Path(str(by_id[gate_id]["output"]["path"])),
                (0, 0, 0o600, 1, 1, EXPOSED_AT, EXPOSED_AT),
                b"x",
                "f" * 64,
            )

        signing = by_id["signing"]
        signing["argv"] = list(
            transaction._report_argv(
                self.request,
                self.pending,
                transaction.WS24Inputs(
                    live_evidence=planned_snapshot("shellbroker-launchagent"),
                    full_surface=planned_snapshot("full-surface"),
                    legacy_grid=planned_snapshot("forced-legacy-grid"),
                    cli_gui=planned_snapshot("cli"),
                    mcp=planned_snapshot("mcp"),
                    native_xpc=planned_snapshot("native-xpc"),
                ),
                self.report_plan,
                self.gate_plans,
            )
        )
        return {
            "schema_version": 1,
            "plan_kind": "macscope-installed-acceptance-gate-plan",
            "candidate_artifact_root": str(self.candidate_root),
            "evidence_root": str(self.request.evidence_root),
            "output_path": str(self.request.gate_plan_path),
            "authority": authority,
            "authority_sha256": authority_sha256,
            "gates": gates,
        }

    def _write_and_load_plan(
        self, document: dict[str, object]
    ) -> transaction.GatePlan:
        self.request.evidence_root.mkdir(mode=0o700, exist_ok=True)
        self.request.qualification_root.mkdir(mode=0o700, exist_ok=True)
        payload = canonical_bytes(document)
        self._write_private(self.request.gate_plan_path, payload)
        digest = hashlib.sha256(payload).hexdigest()
        with mock.patch.object(
            transaction,
            "_load_compiler_validated_plan",
            return_value=(document, digest),
        ):
            return transaction._load_gate_plan(self.request, self.pending)

    def test_parser_freezes_exact_required_boundary_and_timeout_bounds(self) -> None:
        values = [
            "--gate-plan-compiler",
            str(self.root / "compiler.py"),
            "--qualification-receipt",
            str(self.qualification_receipt_path),
            "--qualification-run-id",
            "run-authority",
            "--qualification-run-nonce",
            RUN_NONCE,
            "--predecessor-observations-sha256",
            PREDECESSOR_OBSERVATIONS,
            "--candidate-artifact-root",
            str(self.candidate_root),
            "--work-root",
            str(self.work_root),
            "--installed-app",
            str(self.installed_app),
            "--begin-timeout-seconds",
            "0.01",
            "--compiler-timeout-seconds",
            "22",
            "--report-timeout-seconds",
            "33",
            "--commit-timeout-seconds",
            "44",
            "--rollback-timeout-seconds",
            "86400",
            "--result-output",
            str(self.work_root / transaction.RESULT_NAME),
        ]
        parsed = transaction.parse_arguments(values)
        self.assertEqual(
            set(vars(parsed)),
            {
                "gate_plan_compiler",
                "qualification_receipt",
                "qualification_run_id",
                "qualification_run_nonce",
                "predecessor_observations_sha256",
                "candidate_artifact_root",
                "work_root",
                "installed_app",
                "begin_timeout_seconds",
                "compiler_timeout_seconds",
                "report_timeout_seconds",
                "commit_timeout_seconds",
                "rollback_timeout_seconds",
                "result_output",
            },
        )
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                transaction.parse_arguments(values + ["--signing-flag", "no"])
            with self.assertRaises(SystemExit):
                transaction.parse_arguments(values[:-2])
            duplicate = values + ["--work-root", str(self.root)]
            with self.assertRaises(SystemExit):
                transaction.parse_arguments(duplicate)
            too_small = list(values)
            too_small[too_small.index("0.01")] = "0.009"
            with self.assertRaises(SystemExit):
                transaction.parse_arguments(too_small)

    def test_exact_compiler_and_installer_argv_preserve_sealed_authority(self) -> None:
        self.assertEqual(
            transaction._compiler_argv(self.request, self.pending),
            (
                str(self.python),
                "-B",
                str(self.request.gate_plan_compiler),
                "--qualification-receipt",
                str(self.request.qualification_receipt.path),
                "--candidate-artifact-root",
                str(self.candidate_root),
                "--installation-pending-state",
                str(self.pending.state_file.path),
                "--evidence-root",
                str(self.request.evidence_root),
                "--output",
                str(self.request.gate_plan_path),
            ),
        )
        begin = transaction._installer_argv(self.request, "begin")
        for flag, value in (
            ("--qualification-run-id", self.request.qualification_run.run_id),
            ("--qualification-run-nonce", RUN_NONCE),
            (
                "--predecessor-observations-sha256",
                PREDECESSOR_OBSERVATIONS,
            ),
        ):
            self.assertEqual(begin.count(flag), 1)
            self.assertEqual(begin[begin.index(flag) + 1], value)
        self.assertNotIn("--acceptance-gate-input", begin)

        task10_paths = transaction.Task10Paths(
            xcresult=self.request.evidence_root / transaction.TASK10_XCRESULT_NAME,
            semantic_manifest=transaction.PlannedFile(
                self.request.evidence_root
                / transaction.TASK10_SEMANTIC_MANIFEST_NAME,
                1,
                2,
                transaction.MAX_TASK10_SEMANTIC_MANIFEST_BYTES,
            ),
            matrix_receipt=transaction.PlannedFile(
                self.request.evidence_root / transaction.TASK10_MATRIX_RECEIPT_NAME,
                1,
                2,
                transaction.MAX_TASK10_RECEIPT_BYTES,
            ),
            network_root=(
                self.request.evidence_root / "installed-task10-network"
            ),
            incremental_evidence=(
                self.request.evidence_root
                / "installed-task10-network"
                / transaction.TASK10_INCREMENTAL_EVIDENCE_NAME
            ),
        )
        task10_argv = transaction._task10_argv(self.request, task10_paths)
        self.assertEqual(
            task10_argv[task10_argv.index("--network-artifact-root") + 1],
            str(self.request.evidence_root / "installed-task10-network"),
        )
        self.assertEqual(
            task10_argv[-2:],
            ("--timeout-seconds", "1800"),
        )
        incremental_argv = transaction._incremental_xcuitest_argv(
            self.request, task10_paths
        )
        self.assertEqual(
            incremental_argv,
            (
                str(self.python),
                "-B",
                str(self.request.incremental_xcuitest_script),
                "--matrix-receipt",
                str(task10_paths.matrix_receipt.path),
                "--xcresult-semantic-manifest",
                str(task10_paths.semantic_manifest.path),
                "--network-artifact-root",
                str(task10_paths.network_root),
                "--qualification-run-id",
                self.request.qualification_run.run_id,
                "--qualification-run-nonce",
                RUN_NONCE,
                "--predecessor-observations-sha256",
                PREDECESSOR_OBSERVATIONS,
            ),
        )

        report_argv = transaction._report_argv(
            self.request,
            self.pending,
            self.ws24_inputs,
            self.report_plan,
            self.gate_plans,
        )
        expected = [
            str(self.python),
            "-B",
            str(self.request.report_script),
            "--source-app",
            str(self.source_app),
            "--installed-app",
            str(self.installed_app),
            "--evidence-json",
            str(self.ws24_inputs.live_evidence.path),
            "--candidate-identity",
            str(self.candidate_identity),
            "--expected-source-commit",
            SOURCE_COMMIT,
            "--qualification-run-id",
            self.request.qualification_run.run_id,
            "--qualification-run-nonce",
            RUN_NONCE,
            "--installation-pending-state",
            str(self.pending.state_file.path),
            "--full-surface-report",
            str(self.ws24_inputs.full_surface.path),
            "--legacy-grid-report",
            str(self.ws24_inputs.legacy_grid.path),
            "--cli-gui-operability-report",
            str(self.ws24_inputs.cli_gui.path),
            "--mcp-operability-report",
            str(self.ws24_inputs.mcp.path),
            "--native-xpc-execution-report",
            str(self.ws24_inputs.native_xpc.path),
            "--output",
            str(self.report_plan.path),
        ]
        for gate_id, plan in self.gate_plans:
            expected.extend(
                ("--acceptance-gate-output", f"{gate_id}={plan.path}")
            )
        expected.extend(
            ("--xcode-developer-dir", str(self.request.xcode_developer_dir))
        )
        self.assertEqual(report_argv, tuple(expected))

    def test_live_app_before_begin_refuses_without_install_or_rollback(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        with self._transaction_mocks() as mocks:
            mocks["require_app_quiescent"].side_effect = RuntimeError(
                "app quiescence unproven: PID 123 path=/Applications/MacScope.app/Contents/MacOS/MacScope"
            )
            with self.assertRaises(transaction.TransactionFailed) as caught:
                transaction.execute_transaction(self.request, runner=runner)
        self.assertEqual(runner.calls, [])
        self.assertFalse(caught.exception.rollback_attempted)
        self.assertIn("PID 123", caught.exception.primary)

    def test_live_app_before_rollback_retains_pending_state_and_refuses_installer(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        runner.fail_stage = "compiler"
        self._write_private(self.pending.state_file.path, self.pending.state_file.payload)
        before = self.pending.state_file.path.read_bytes()
        with self._transaction_mocks() as mocks:
            mocks["require_app_quiescent"].side_effect = [
                None, RuntimeError("app quiescence unproven: PID 456 path=/foreign/MacScope"),
            ]
            with self.assertRaises(transaction.TransactionFailed) as caught:
                transaction.execute_transaction(self.request, runner=runner)
        self.assertEqual([runner.stage(call[0]) for call in runner.calls], ["begin", "compiler"])
        self.assertFalse(caught.exception.rollback_attempted)
        self.assertIsNone(caught.exception.rollback_succeeded)
        self.assertIn("PID 456", caught.exception.rollback_diagnostic)
        self.assertEqual(self.pending.state_file.path.read_bytes(), before)

    def test_happy_transaction_orders_begin_compiler_report_commit(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        with self._transaction_mocks():
            outcome = transaction.execute_transaction(self.request, runner=runner)
        self.assertEqual(outcome, self.outcome)
        self.assertEqual(
            [runner.stage(argv) for argv, _timeout, _environment in runner.calls],
            ["begin", "compiler", "report", "commit"],
        )
        self.assertEqual(
            [timeout for _argv, timeout, _environment in runner.calls],
            [11.0, 22.0, 33.0, 44.0],
        )
        for _argv, _timeout, environment in runner.calls:
            self.assertEqual(environment, transaction.BASE_ENVIRONMENT)
        commit = runner.calls[-1][0]
        inputs = [
            commit[index + 1]
            for index, value in enumerate(commit)
            if value == "--acceptance-gate-input"
        ]
        self.assertEqual(
            inputs,
            [
                f"{gate_id}={plan.path}"
                for gate_id, plan in self.gate_plans
            ],
        )
        self.assertEqual(len(inputs), 8)

    def test_every_command_and_semantic_failure_boundary_rolls_back(self) -> None:
        function_boundaries = (
            "_load_pending_binding",
            "_create_private_directory",
            "_assert_pending_unchanged",
            "_load_gate_plan",
            "_qualification_plans",
            "_run_task10_prerequisite",
            "_execute_gate_plan",
            "_assert_snapshot_unchanged",
            "_validate_terminal_commit",
            "_publish_result",
        )
        for boundary in function_boundaries:
            with self.subTest(boundary=boundary):
                runner = ScriptedRunner(self.request, self.pending)
                with self._transaction_mocks(failing_function=boundary):
                    with self.assertRaises(transaction.TransactionFailed) as caught:
                        transaction.execute_transaction(self.request, runner=runner)
                self.assertTrue(caught.exception.rollback_attempted)
                self.assertTrue(caught.exception.rollback_succeeded)
                self.assertEqual(runner.stage(runner.calls[-1][0]), "rollback")
                self.assertEqual(runner.calls[-1][1], 55.0)
                self.assertFalse(self.request.result_output.path.exists())

        for boundary in ("begin", "compiler", "report", "commit"):
            with self.subTest(command=boundary):
                runner = ScriptedRunner(self.request, self.pending)
                runner.fail_stage = boundary
                with self._transaction_mocks():
                    with self.assertRaises(transaction.TransactionFailed) as caught:
                        transaction.execute_transaction(self.request, runner=runner)
                self.assertTrue(caught.exception.rollback_succeeded)
                self.assertEqual(runner.stage(runner.calls[-1][0]), "rollback")

    def test_stale_state_timeout_and_signal_each_trigger_rollback(self) -> None:
        stale = [
            None,
            transaction.TransactionError("substituted pending state"),
        ]
        runner = ScriptedRunner(self.request, self.pending)
        with self._transaction_mocks(pending_assert_side_effect=stale):
            with self.assertRaises(transaction.TransactionFailed) as caught:
                transaction.execute_transaction(self.request, runner=runner)
        self.assertIn("substituted pending", caught.exception.primary)
        self.assertEqual(runner.stage(runner.calls[-1][0]), "rollback")

        for kind in ("timeout", "signal"):
            with self.subTest(kind=kind):
                runner = ScriptedRunner(self.request, self.pending)
                if kind == "timeout":
                    runner.timeout_stage = "compiler"
                else:
                    runner.signal_stage = "compiler"
                with self._transaction_mocks():
                    with self.assertRaises(transaction.TransactionFailed) as caught:
                        transaction.execute_transaction(self.request, runner=runner)
                self.assertIn(kind, caught.exception.primary)
                self.assertTrue(caught.exception.rollback_succeeded)
                self.assertEqual(runner.stage(runner.calls[-1][0]), "rollback")

    def test_pending_state_path_digest_and_identity_substitution_are_rejected(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        fields = transaction._parse_key_value_stdout(
            runner._begin_stdout(),
            label="installer begin",
            expected_keys=transaction.BEGIN_STDOUT_KEYS,
        )
        with (
            mock.patch.object(
                installer,
                "_pending_read_stable",
                return_value=(self.pending.state, self.pending.state_file),
            ),
            mock.patch.object(transaction, "_validate_current_pending_authority"),
        ):
            observed = transaction._load_pending_binding(self.request, fields)
            self.assertEqual(observed.state_sha256, self.pending.state_sha256)

            substituted = dict(fields)
            substituted["MACSCOPE_INSTALL_RELEASE_PENDING_STATE"] = str(
                self.root / "substituted" / "transaction.json"
            )
            with self.assertRaisesRegex(transaction.TransactionError, "substituted"):
                transaction._load_pending_binding(self.request, substituted)

            stale = dict(fields)
            stale["MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256"] = "0" * 64
            with self.assertRaisesRegex(transaction.TransactionError, "does not bind"):
                transaction._load_pending_binding(self.request, stale)

            wrong_run = dict(self.pending.state)
            wrong_run["qualification_run_id"] = "other-run"
            with mock.patch.object(
                installer,
                "_pending_read_stable",
                return_value=(wrong_run, self.pending.state_file),
            ):
                with self.assertRaisesRegex(transaction.TransactionError, "identity"):
                    transaction._load_pending_binding(self.request, fields)

    def test_plan_hardening_accepts_only_closed_authority_ids_and_byte_caps(self) -> None:
        plan = self._write_and_load_plan(self._plan_document())
        self.assertEqual(
            tuple(gate.gate_id for gate in plan.gates),
            transaction.REQUIRED_ACCEPTANCE_GATES,
        )
        self.assertEqual(
            {gate.gate_id: gate.output.maximum_bytes for gate in plan.gates},
            transaction.GATE_OUTPUT_MAXIMUM_BYTES,
        )
        self.assertEqual(
            set(plan.authority), transaction.PLAN_AUTHORITY_FIELDS
        )

        mutations: list[tuple[str, object]] = []
        wrong_cap = self._plan_document()
        wrong_cap["gates"][0]["output"]["maximum_bytes"] = 65_535  # type: ignore[index]
        mutations.append(("wrong cap", wrong_cap))
        missing_gate = self._plan_document()
        missing_gate["gates"] = missing_gate["gates"][:-1]  # type: ignore[index]
        mutations.append(("missing gate", missing_gate))
        duplicate_gate = self._plan_document()
        duplicate_gate["gates"][-1] = duplicate_gate["gates"][0]  # type: ignore[index]
        mutations.append(("duplicate gate", duplicate_gate))
        reordered = self._plan_document()
        reordered["gates"][0], reordered["gates"][1] = (  # type: ignore[index]
            reordered["gates"][1],
            reordered["gates"][0],
        )
        mutations.append(("reordered gate", reordered))
        stale_authority = self._plan_document()
        stale_authority["authority"]["pending_state_sha256"] = "0" * 64  # type: ignore[index]
        stale_authority["authority_sha256"] = hashlib.sha256(
            canonical_bytes(stale_authority["authority"])
        ).hexdigest()
        for gate in stale_authority["gates"]:  # type: ignore[union-attr]
            gate["authority_sha256"] = stale_authority["authority_sha256"]
            gate["environment"]["MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256"] = (  # type: ignore[index]
                stale_authority["authority_sha256"]
            )
        mutations.append(("stale authority", stale_authority))
        extra_authority = self._plan_document()
        extra_authority["authority"]["synthesized"] = True  # type: ignore[index]
        mutations.append(("extra authority", extra_authority))

        for label, document in mutations:
            with self.subTest(label=label):
                other = self.root / label.replace(" ", "-")
                other.mkdir()
                request = self.request
                request = transaction.BoundRequest(
                    **{
                        **request.__dict__,
                        "evidence_root": other,
                        "gate_plan_path": other / transaction.GATE_PLAN_NAME,
                    }
                )
                document["evidence_root"] = str(other)  # type: ignore[index]
                document["output_path"] = str(  # type: ignore[index]
                    other / transaction.GATE_PLAN_NAME
                )
                for gate in document.get("gates", []):  # type: ignore[union-attr]
                    output = gate["output"]
                    output["path"] = str(other / Path(output["path"]).name)
                payload = canonical_bytes(document)
                self._write_private(request.gate_plan_path, payload)
                with mock.patch.object(
                    transaction,
                    "_load_compiler_validated_plan",
                    return_value=(
                        document,
                        hashlib.sha256(payload).hexdigest(),
                    ),
                ):
                    with self.assertRaises(transaction.TransactionError):
                        transaction._load_gate_plan(request, self.pending)

    def _system_python_fixture(self) -> Path:
        # Model Apple's canonical hardlinked file without depending on the host's
        # /usr/bin/python3 layout. Only the trusted path constant is substituted.
        executable = self.root / "system-python3"
        self._write_private(executable, b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        os.link(executable, self.root / "system-python3-hardlink")
        return executable

    def test_gate_plan_accepts_exact_apple_system_python(self) -> None:
        executable = self._system_python_fixture()
        document = self._plan_document()
        for gate in document["gates"]:  # type: ignore[union-attr]
            gate["argv"][0] = str(executable)
        with mock.patch.object(transaction, "SYSTEM_PYTHON", executable):
            plan = self._write_and_load_plan(document)
        self.assertEqual({Path(gate.argv[0]) for gate in plan.gates}, {executable})

    def test_gate_plan_rejects_other_hardlinked_executable(self) -> None:
        executable = self.root / "hardlinked-tool"
        self._write_private(executable, b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        os.link(executable, self.root / "hardlinked-tool-alias")
        document = self._plan_document()
        document["gates"][0]["argv"][0] = str(executable)  # type: ignore[index]
        with self.assertRaisesRegex(transaction.TransactionError, "single-link"):
            self._write_and_load_plan(document)

    def test_gate_executor_deduplicates_operations_and_captures_stdout_privately(self) -> None:
        plan = self._write_and_load_plan(self._plan_document())
        operations = {
            members[0].argv: members
            for members in transaction._operation_order(plan.gates)
        }
        calls: list[tuple[tuple[str, ...], float, dict[str, str]]] = []

        def run(
            argv: tuple[str, ...],
            timeout: float,
            environment: Mapping[str, str],
        ) -> transaction.CommandResult:
            calls.append((argv, timeout, dict(environment)))
            members = operations[argv]
            for member in members:
                if member.output.kind == "command-file":
                    self._write_private(
                        member.output.path,
                        f"evidence for {member.operation_id}".encode("utf-8"),
                    )
            signing = members[0].gate_id == "signing"
            stdout = (
                "".join(
                    f"{gate_id}={gate_plan.path}\n"
                    for gate_id, gate_plan in self.gate_plans
                ).encode("utf-8")
                if signing
                else f"status for {members[0].operation_id}\n".encode("utf-8")
            )
            return transaction.CommandResult(
                argv,
                0,
                stdout,
                b"" if signing else b"private gate diagnostic\n",
            )

        def validate_publication(
            request: transaction.BoundRequest,
            pending: transaction.PendingBinding,
            report_plan: transaction.PlannedFile,
            gate_plans: Sequence[tuple[str, transaction.PlannedFile]],
        ) -> transaction.WS24Publication:
            del request, pending, gate_plans
            return transaction.WS24Publication(
                transaction._read_planned_file(
                    report_plan, label="synthetic WS24 report"
                ),
                self.publication.gate_envelopes,
            )

        with (
            mock.patch.object(transaction, "_assert_pending_unchanged"),
            mock.patch.object(transaction, "_assert_snapshot_unchanged"),
            mock.patch.object(transaction, "_parse_report_stdout"),
            mock.patch.object(
                transaction,
                "_validate_ws24_publication",
                side_effect=validate_publication,
            ),
        ):
            execution = transaction._execute_gate_plan(
                self.request,
                self.pending,
                plan,
                self.report_plan,
                self.gate_plans,
                run,
            )
        self.assertEqual(
            tuple(gate_id for gate_id, _snapshot in execution.outputs),
            transaction.REQUIRED_ACCEPTANCE_GATES,
        )
        self.assertEqual(len(calls), 6)
        self.assertEqual(len({gate.operation_id for gate in plan.gates}), 6)
        for argv, _timeout, environment in calls:
            if Path(argv[2]) != self.request.report_script:
                self.assertIn("$(never-expanded)", argv)
                self.assertIn("*.app", argv)
            self.assertEqual(
                environment,
                {
                    **transaction.BASE_ENVIRONMENT,
                    "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": plan.authority_sha256,
                },
            )
        gui = dict(execution.outputs)["gui"]
        signing = dict(execution.outputs)["signing"]
        self.assertEqual(gui.payload, b"status for cli-gui-operability\n")
        self.assertEqual(signing.payload, b"evidence for ws24-installed-qualification")
        self.assertEqual(signing, execution.publication.report)
        self.assertEqual(gui.metadata[2], 0o600)

    def test_report_stdout_requires_exact_unique_sorted_envelopes(self) -> None:
        lines = list(
            f"{gate_id}={plan.path}" for gate_id, plan in self.gate_plans
        )
        payload = ("\n".join(lines) + "\n").encode("utf-8")
        self.assertIsNone(
            transaction._parse_report_stdout(payload, self.gate_plans)
        )
        cases = {
            "missing": lines[:-1],
            "duplicate": [lines[0], lines[0], *lines[2:]],
            "reordered": [lines[1], lines[0], *lines[2:]],
        }
        for label, case_lines in cases.items():
            with self.subTest(label=label):
                with self.assertRaises(transaction.TransactionError):
                    transaction._parse_report_stdout(
                        ("\n".join(case_lines) + "\n").encode("utf-8"),
                        self.gate_plans,
                    )
        with self.assertRaisesRegex(transaction.TransactionError, "LF-terminated"):
            transaction._parse_report_stdout(
                "\n".join(lines).encode("utf-8"), self.gate_plans
            )

    def test_ws24_publication_retains_exact_eight_distinct_envelopes(self) -> None:
        document = {
            "schemaVersion": (
                transaction.ws24.INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION
            ),
            "accepted": True,
            "sourceCommit": SOURCE_COMMIT,
            "sourceTree": SOURCE_TREE,
            "installedExecutableSHA256": APPLICATION_DIGEST,
        }
        report_payload = canonical_bytes(document)
        self._write_private(self.report_plan.path, report_payload)
        report_digest = hashlib.sha256(report_payload).hexdigest()
        for gate_id, plan in self.gate_plans:
            self._write_private(plan.path, canonical_bytes({"gate_id": gate_id}))
        self.assertEqual(len(report_digest), 64)
        with mock.patch.object(
            installer,
            "_acceptance_gate_records",
            return_value=(
                {gate_id: {} for gate_id in transaction.REQUIRED_ACCEPTANCE_GATES},
                EXPOSED_AT,
            ),
        ):
            publication = transaction._validate_ws24_publication(
                self.request,
                self.pending,
                self.report_plan,
                self.gate_plans,
            )
        self.assertEqual(
            tuple(gate_id for gate_id, _snapshot in publication.gate_envelopes),
            transaction.REQUIRED_ACCEPTANCE_GATES,
        )
        self.assertEqual(
            len({snapshot.path for _gate_id, snapshot in publication.gate_envelopes}),
            8,
        )

    def test_result_schema_is_closed_canonical_create_only_and_stdout_is_path_only(self) -> None:
        document = transaction._result_document(
            self.request,
            self.pending,
            self.task10,
            self.plan,
            self.publication,
            self.terminal,
            produced_at_unix_ns=10,
        )
        self.assertEqual(set(document), transaction.RESULT_TOP_LEVEL_FIELDS)
        self.assertEqual(
            set(document["candidate"]),
            {
                "artifact_root",
                "identity_path",
                "identity_sha256",
                "identity_file_sha256",
                "provenance_path",
                "provenance_sha256",
                "source_app_path",
                "source_commit",
                "source_tree",
                "application_executable_sha256",
            },
        )
        self.assertEqual(
            set(document["transaction"]),
            {
                "transaction_id",
                "transaction_nonce",
                "candidate_identity_sha256",
                "candidate_file_sha256",
                "application_executable_sha256",
                "build_provenance_sha256",
                "source_commit",
                "source_tree",
                "source_equality_sha256",
                "execution_identity_sha256",
                "destination_identity_sha256",
                "predecessor_digest",
                "predecessor_observations_sha256",
                "began_at_unix_ns",
                "exposed_at_unix_ns",
            },
        )
        self.assertEqual(
            [item["gate_id"] for item in document["gate_envelopes"]],
            list(transaction.REQUIRED_ACCEPTANCE_GATES),
        )
        self.assertEqual(
            document["installed_task10"]["network_artifact_root"]["path"],
            str(self.task10.network_root.path),
        )
        self.assertEqual(
            set(document["installed_task10"]),
            {
                "matrix_receipt",
                "xcresult",
                "xcresult_semantic_manifest",
                "network_artifact_root",
                "incremental_evidence",
            },
        )
        payload = canonical_bytes(document)
        self.assertFalse(payload.endswith(b"\n"))
        with mock.patch.object(transaction, "_assert_all_unchanged"):
            outcome = transaction._publish_result(
                self.request,
                self.pending,
                self.task10,
                self.plan,
                self.gate_snapshots,
                self.publication,
                self.terminal,
                clock_ns=lambda: 10,
            )
        self.assertEqual(outcome.result_output, self.request.result_output.path)
        self.assertEqual(self.request.result_output.path.read_bytes(), payload)
        self.assertEqual(
            stat.S_IMODE(self.request.result_output.path.stat().st_mode), 0o600
        )
        with self.assertRaises(transaction.TransactionError):
            transaction._write_create_only_bytes(
                self.request.result_output,
                payload,
                label="transaction result",
            )

        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            mock.patch.object(transaction, "parse_arguments", return_value=object()),
            mock.patch.object(transaction, "_bind_request", return_value=self.request),
            mock.patch.object(transaction, "execute_transaction", return_value=outcome),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status_code = transaction.main([], _install_signal_handlers=False)
        self.assertEqual(status_code, 0)
        self.assertEqual(stdout.getvalue(), f"{outcome.result_output}\n")
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn("PASS", stdout.getvalue())

    def test_failure_stdout_is_empty_and_rollback_failure_is_disclosed(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        runner.fail_stage = "compiler"
        runner.rollback_failure = True
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            self._transaction_mocks(),
            mock.patch.object(transaction, "parse_arguments", return_value=object()),
            mock.patch.object(transaction, "_bind_request", return_value=self.request),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            status_code = transaction.main(
                [], _runner=runner, _install_signal_handlers=False
            )
        self.assertEqual(status_code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("stage refused", stderr.getvalue())
        self.assertIn("ROLLBACK FAILED", stderr.getvalue())
        self.assertIn("rollback refused", stderr.getvalue())

    def test_rollback_quiescence_refusal_is_disclosed_without_claiming_attempt(self) -> None:
        runner = ScriptedRunner(self.request, self.pending)
        runner.fail_stage = "compiler"
        stdout = io.StringIO()
        stderr = io.StringIO()
        with (
            self._transaction_mocks() as mocks,
            mock.patch.object(transaction, "parse_arguments", return_value=object()),
            mock.patch.object(transaction, "_bind_request", return_value=self.request),
            contextlib.redirect_stdout(stdout),
            contextlib.redirect_stderr(stderr),
        ):
            mocks["require_app_quiescent"].side_effect = [
                None, RuntimeError("app quiescence unproven: PID 456 path=/foreign/MacScope"),
            ]
            status_code = transaction.main([], _runner=runner, _install_signal_handlers=False)
        self.assertEqual(status_code, 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertIn("rollback not attempted: app quiescence unproven: PID 456", stderr.getvalue())
        self.assertNotIn("ROLLBACK FAILED", stderr.getvalue())
        self.assertEqual([runner.stage(call[0]) for call in runner.calls], ["begin", "compiler"])

    def test_create_only_and_canonical_path_checks_reject_aliases_and_links(self) -> None:
        existing = self.root / "existing.json"
        self._write_private(existing, b"occupied")
        with self.assertRaises(transaction.TransactionError):
            transaction._plan_absent_file(
                existing, label="existing output", maximum_bytes=1024
            )
        alias = self.root / "alias.json"
        alias.symlink_to(existing)
        with self.assertRaises(transaction.TransactionError):
            transaction._plan_absent_file(
                alias, label="symlink output", maximum_bytes=1024
            )
        linked = self.root / "linked.json"
        os.link(existing, linked)
        with self.assertRaisesRegex(transaction.TransactionError, "single-link"):
            transaction._canonical_existing(
                existing, directory=False, label="hard-linked input"
            )

        failed_output = self.root / "failed-create-only.json"
        plan = transaction._plan_absent_file(
            failed_output, label="failed output", maximum_bytes=1024
        )
        with mock.patch.object(transaction.os, "fsync", side_effect=OSError("no sync")):
            with self.assertRaises(transaction.TransactionError):
                transaction._write_create_only_bytes(
                    plan, b"private payload", label="failed output"
                )
        self.assertFalse(failed_output.exists())

    def test_trusted_system_python_accepts_apple_system_hardlinks(self) -> None:
        executable = self._system_python_fixture()
        metadata = executable.lstat()
        self.assertTrue(stat.S_ISREG(metadata.st_mode))
        self.assertFalse(stat.S_ISLNK(metadata.st_mode))
        self.assertGreater(metadata.st_nlink, 1)
        with mock.patch.object(transaction, "SYSTEM_PYTHON", executable):
            self.assertEqual(transaction._trusted_system_python(executable), executable)

    def test_trusted_system_python_rejects_any_other_executable(self) -> None:
        executable = self.root / "python3"
        self._write_private(executable, b"#!/bin/sh\nexit 0\n")
        executable.chmod(0o700)
        with self.assertRaisesRegex(transaction.TransactionError, "exactly"):
            transaction._trusted_system_python(executable)

    def test_real_runner_preserves_literal_argv_and_separates_streams(self) -> None:
        marker = self.root / "must-not-exist"
        literal = f"$(touch {marker})"
        program = (
            "import sys;"
            "sys.stdout.write(sys.argv[1]);"
            "sys.stderr.write('separate-stderr')"
        )
        argv = (str(self.python), "-c", program, literal)
        result = transaction._run_command(
            argv, 5.0, transaction.BASE_ENVIRONMENT
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode("utf-8"), literal)
        self.assertEqual(result.stderr, b"separate-stderr")
        self.assertFalse(marker.exists())

    def test_real_runner_timeout_cancels_owned_process_group(self) -> None:
        child_pid_path = self.root / "child.pid"
        program = (
            "import pathlib,signal,subprocess,sys,time;"
            "signal.signal(signal.SIGTERM,signal.SIG_IGN);"
            "child=subprocess.Popen([sys.executable,'-c',"
            "'import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(60)']);"
            f"pathlib.Path({str(child_pid_path)!r}).write_text(str(child.pid));"
            "time.sleep(60)"
        )
        original = transaction._terminate_process_group

        def bounded_terminate(
            process: object, process_group_id: int
        ) -> bool:
            return original(
                process,
                process_group_id,
                term_grace=0.05,
                kill_grace=2.0,
            )

        with mock.patch.object(
            transaction,
            "_terminate_process_group",
            side_effect=bounded_terminate,
        ):
            result = transaction._run_command(
                (str(self.python), "-c", program),
                # Long enough for two interpreters to start on a loaded runner
                # (0.4 s expired before the child existed in nightly 38737892194).
                5.0,
                transaction.BASE_ENVIRONMENT,
            )
        self.assertTrue(result.timed_out)
        self.assertFalse(result.descendant_cleanup_failed)
        child_pid = int(child_pid_path.read_text(encoding="utf-8"))
        deadline = time.monotonic() + 2.0
        while True:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            if time.monotonic() >= deadline:
                self.fail("timed-out process-group descendant remained alive")
            time.sleep(0.02)


if __name__ == "__main__":
    unittest.main()
