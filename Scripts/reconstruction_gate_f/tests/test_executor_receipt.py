from __future__ import annotations

import contextlib
import hashlib
import io
import plistlib
import struct
import tempfile
import unittest
from unittest import mock
from dataclasses import replace
from pathlib import Path
import zlib

from Scripts.reconstruction.run_authority_stress import (
    SWIFT_TEST_SELECTOR,
    compile_authority_stress_plan,
    execute_python_adapters,
    plan_mapping,
)
from Scripts.reconstruction.installed_matrix_receipt import (
    PRESENTATION_SCENARIO,
    PRESENTATION_TEST_IDENTIFIER,
    PRESENTATION_VARIANTS,
    expected_presentation_attachment_name,
)
from Scripts.reconstruction_gate_f.canonical_json import (
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
    load_canonical_json,
    write_canonical_json,
)
from Scripts.reconstruction_gate_f.command_catalog import (
    INDEPENDENT_REVIEW_COMMAND_LENSES,
    SIGNED_XPC_SERVICE_IDENTITIES,
    command_templates,
)
from Scripts.reconstruction_gate_f.executor_receipt import (
    ReceiptEmissionError,
    _validate_legacy_physical_evidence as _emit_executor_receipt,
    main,
)
from Scripts.reconstruction_gate_f.gate_specific_artifact_validator import (
    GateSpecificArtifactError,
    validate_gate_specific_artifacts,
)
from Scripts.reconstruction_gate_f.merge_authority_evidence import create_evidence
from Scripts.reconstruction_gate_f import executor_receipt as executor_receipt_module
from Scripts.reconstruction_gate_f import (
    gate_specific_artifact_validator as gate_validator_module,
)
from Scripts.reconstruction_gate_f.receipt_validator import (
    QualificationRunAuthority,
    _validate_physical_receipt as validate_receipt,
)
from Scripts.reconstruction_gate_f.schema import (
    ArtifactKind,
    EvidenceLayer,
    EvidenceStatus,
    ReceiptType,
    candidate_identity_sha256,
    candidate_to_mapping,
    parse_candidate_identity,
)
from Scripts.reconstruction_gate_f.tests import parsed_candidate, sha
from Scripts.reconstruction_gate_f.tests.test_merge_authority_evidence import (
    postmerge_fixture,
    prospective_fixture,
)
from Scripts.ws24_emit_installed_qualification_report import (
    installed_selector_projection,
    load_installed_selector_catalog,
)

QUALIFICATION_RUN = QualificationRunAuthority(
    run_id="gate-f-qualification-20260828",
    nonce=sha("9"),
)
QUALIFICATION_RUN_MAPPING = {
    "run_id": QUALIFICATION_RUN.run_id,
    "nonce": QUALIFICATION_RUN.nonce,
}


def emit_executor_receipt(request: object, *, artifact_root: Path):
    return _emit_executor_receipt(
        request,
        artifact_root=artifact_root,
        qualification_run_authority=QUALIFICATION_RUN,
    )


class GateFExecutorReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve(strict=True)
        self.signed_worker_payload = b"candidate-ai-agent-worker-v1\n"
        worker_sha256 = hashlib.sha256(self.signed_worker_payload).hexdigest()
        candidate = parsed_candidate()
        self.candidate = replace(
            candidate,
            application=replace(
                candidate.application,
                embedded_executables=tuple(
                    replace(item, sha256=worker_sha256)
                    if item.identity_id == "ai-agent-worker"
                    else item
                    for item in candidate.application.embedded_executables
                ),
                qualification_executables=tuple(
                    replace(item, sha256=worker_sha256)
                    if item.identity_id == "ai-agent-worker"
                    else item
                    for item in candidate.application.qualification_executables
                ),
            ),
        )
        self.templates = {item.command_id: item for item in command_templates()}

    def tearDown(self) -> None:
        self.temporary.cleanup()

    @staticmethod
    def _descriptor(
        path: Path,
        *,
        candidate_digest: str,
        layer: EvidenceLayer,
        receipt_id: str,
        command_id: str,
        artifact_id: str,
        kind: ArtifactKind,
        command_output: str,
        media_type: str,
    ) -> dict[str, object]:
        payload = path.read_bytes()
        return {
            "schema_version": 1,
            "artifact_id": artifact_id,
            "candidate_identity_sha256": candidate_digest,
            "evidence_layer": layer.value,
            "root_id": "qualification-run",
            "relative_path": path.name,
            "kind": kind.value,
            "media_type": media_type,
            "byte_count": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "producer_receipt_id": receipt_id,
            "command_id": command_id,
            "command_output": command_output,
        }

    def _signed_xpc_request(
        self,
        *,
        report: dict[str, object] | None = None,
        command_id: str = "task8.signed-worker-parity",
    ) -> dict[str, object]:
        layer = EvidenceLayer.SIGNED_XPC
        receipt_id = "receipt-signed-xpc"
        template = self.templates[command_id]
        expected_identity_id = SIGNED_XPC_SERVICE_IDENTITIES[command_id]
        selector_index = template.argv.index("--only-testing") if "--only-testing" in template.argv else -1
        selector = (
            template.argv[selector_index + 1]
            if selector_index >= 0
            else "CoreTests/Phase2LiveAIAgentXPCProductionGateTests/"
            "testSignedWorkerCompletesReconstructionRoundThenFinalSynthesisExactlyOnce"
        )
        execution_output = next(
            item for item in template.generated_artifacts if item.endswith("EXECUTION_REPORT")
        )
        test_results_output = next(
            item for item in template.generated_artifacts if item.endswith("TEST_RESULTS")
        )
        executable_output = next(
            item for item in template.generated_artifacts if item.endswith("EXECUTABLE")
        )
        candidate_digest = candidate_identity_sha256(self.candidate)
        report_path = self.root / "execution-report.json"
        write_canonical_json(
            report_path,
            report
            or {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "passed",
                "exit_code": 0,
                "stress": None,
            },
        )
        executable_path = self.root / "signed-worker"
        executable_path.write_bytes(self.signed_worker_payload)
        test_results_path = self.root / "test-results.json"
        write_canonical_json(
            test_results_path,
            self._passing_test_results(selector),
        )
        report_artifact = self._descriptor(
            report_path,
            candidate_digest=candidate_digest,
            layer=layer,
            receipt_id=receipt_id,
            command_id=command_id,
            artifact_id="artifact-execution-report",
            kind=ArtifactKind.JSON,
            command_output=f"artifact:{execution_output}",
            media_type="application/json",
        )
        test_results_artifact = self._descriptor(
            test_results_path,
            candidate_digest=candidate_digest,
            layer=layer,
            receipt_id=receipt_id,
            command_id=command_id,
            artifact_id="artifact-test-results",
            kind=ArtifactKind.TEST_RESULTS,
            command_output=f"artifact:{test_results_output}",
            media_type="application/json",
        )
        executable_artifact = self._descriptor(
            executable_path,
            candidate_digest=candidate_digest,
            layer=layer,
            receipt_id=receipt_id,
            command_id=command_id,
            artifact_id="artifact-signed-worker",
            kind=ArtifactKind.SIGNED_EXECUTABLE,
            command_output=f"artifact:{executable_output}",
            media_type="application/octet-stream",
        )
        log_path = self.root / "signed-worker.log"
        log_path.write_text("governed signed-worker fixture log\n", encoding="utf-8")
        log_artifact = self._descriptor(
            log_path,
            candidate_digest=candidate_digest,
            layer=layer,
            receipt_id=receipt_id,
            command_id=command_id,
            artifact_id="artifact-signed-worker-log",
            kind=ArtifactKind.JSON,
            command_output=f"log:{template.generated_logs[0]}",
            media_type="text/plain",
        )
        service = next(
            item
            for item in self.candidate.application.qualification_executables
            if item.identity_id == expected_identity_id
        )
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.SIGNED_XPC.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-signed-xpc",
            "command_id": command_id,
            "scenario_id": "scenario-signed-xpc",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": "artifact-execution-report",
            "executor": {
                "executor_id": "local-xcode27",
                "host": "macos-arm64-xcode27",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": "macos-arm64-xcode27",
                "execution_mode": "executor-required",
                "argv_sha256": sha("c"),
                "working_directory_sha256": sha("d"),
                "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": [
                report_artifact,
                test_results_artifact,
                executable_artifact,
                log_artifact,
            ],
            "constituents": [
                {
                "selector_id": command_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": [
                        "artifact-execution-report",
                        "artifact-signed-worker",
                        "artifact-signed-worker-log",
                        "artifact-test-results",
                    ],
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "service_identity_id": expected_identity_id,
                "service_bundle_id": service.bundle_identifier,
                "service_executable_sha256": service.sha256,
                "selector_count": 1,
                "failed_count": 0,
                "failure_stage": None,
                "failure_reason": None,
            },
        }

    @staticmethod
    def _t10c_manifest_sha256(rows: dict[str, str]) -> str:
        framed = b"".join(
            path.encode("utf-8")
            + b"\0"
            + rows[path].encode("ascii")
            + b"\n"
            for path in sorted(rows)
        )
        return hashlib.sha256(framed).hexdigest()

    def _t10c_current_source_request(
        self,
        *,
        source_commit: str | None = None,
        dirty_input_paths: list[str] | None = None,
        review_gap_ids: list[str] | None = None,
        uncaught_mutation: int | None = None,
        review_authority: dict[str, object] | None = None,
        bundle_manifest_sha256: str | None = None,
    ) -> dict[str, object]:
        command_id = "evidence.t10c-current-source-adjudication"
        receipt_id = "receipt-t10c-current-source"
        layer = EvidenceLayer.INDEPENDENT_REVIEW
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        audited_commit = source_commit or self.candidate.source.commit
        dirty_paths = [] if dirty_input_paths is None else dirty_input_paths
        finding_ids = [
            *(f"T10A-P1-{index:03d}" for index in range(1, 7)),
            *(f"T10A-P2-{index:03d}" for index in range(1, 9)),
            *(f"T10A-P3-{index:03d}" for index in (1, 2, 3, 5)),
        ]
        gap_ids = ["T10A-P2-006", "T10A-P2-008", "T10A-P3-003"]
        mappings: list[dict[str, object]] = []
        findings: list[dict[str, object]] = []
        for index, finding_id in enumerate(finding_ids, 1):
            if finding_id in {"T10A-P1-005", "T10A-P3-002"}:
                current_path = (
                    "MacScope/Features/Reconstruction/"
                    "ReconstructionStatusProjection.swift"
                )
                current_symbol = "ReconstructionStatusProjection"
                blob_identity = "reconstruction-status-projection"
            else:
                current_path = f"MacScope/CurrentSource{index:02d}.swift"
                current_symbol = f"currentSourceSymbol{index:02d}"
                blob_identity = finding_id
            blob_sha256 = hashlib.sha256(f"blob-{blob_identity}".encode()).hexdigest()
            fingerprint_sha256 = hashlib.sha256(
                f"fingerprint-{finding_id}".encode()
            ).hexdigest()
            mappings.append(
                {
                    "classification": "materially-changed",
                    "currentAnchor": f"anchor-{finding_id}",
                    "currentAnchorLineDiagnosticOnly": index,
                    "currentBlobSHA256": blob_sha256,
                    "currentPath": current_path,
                    "currentSymbol": current_symbol,
                    "directlyEvaluable": True,
                    "findingID": finding_id,
                    "requiredTokens": [f"token-{finding_id}"],
                    "semanticFingerprintSHA256": fingerprint_sha256,
                }
            )
            if finding_id in gap_ids:
                outcome = "confirmed-current-evidence-gap"
                severity = "P2" if finding_id == "T10A-P3-003" else "P1"
                installed_required = True
                blocks = "GateF"
            else:
                outcome = "already-fixed-on-current-source"
                severity = "none"
                installed_required = False
                blocks = "neither"
            findings.append(
                {
                    "blocks": blocks,
                    "closestTestSuite": f"CurrentSourceSuite{index:02d}",
                    "confidence": "high",
                    "currentBlobSHA256": blob_sha256,
                    "currentPath": current_path,
                    "currentSeverity": severity,
                    "currentSymbol": current_symbol,
                    "evidenceClass": "exact-current-worktree-source",
                    "expectedProductionBehavior": f"behavior-{finding_id}",
                    "findingID": finding_id,
                    "installedExecutionRequired": installed_required,
                    "minimalVectorIDs": [f"vector-{finding_id}"],
                    "originalSeverity": finding_id.split("-")[1],
                    "outcome": outcome,
                    "productChangeRequired": False,
                    "semanticFingerprintSHA256": fingerprint_sha256,
                    "unresolvedAssumptions": [],
                }
            )
        current_source = {
            "dirtyInputPaths": dirty_paths,
            "headCommit": audited_commit,
            "headTree": self.candidate.source.tree,
            "identityInterpretation": "exact candidate commit and tree",
            "inputPathCount": 18,
            "worktreeInputManifestSHA256": sha("1"),
        }
        source_drift = {
            "allSymbolsResolved": True,
            "currentSource": current_source,
            "mappingCount": 18,
            "mappings": mappings,
            "originalSource": {"commit": "1" * 40, "tree": "2" * 40},
            "schemaVersion": 1,
            "taskID": "RECON-R1-T10C",
        }
        adjudication = {
            "confirmedCurrentDefectCount": 0,
            "findingCount": 18,
            "findings": findings,
            "openSeverityCounts": {"P1": 2, "P2": 1},
            "outcomeCounts": {
                "already-fixed-on-current-source": 15,
                "confirmed-current-evidence-gap": 3,
                "obsolete-after-source-change": 0,
            },
            "productSourceChangeRequired": False,
            "schemaVersion": 1,
            "sourceIdentity": current_source,
            "taskID": "RECON-R1-T10C",
        }
        source_path = self.root / "SOURCE_DRIFT.json"
        adjudication_path = self.root / "FINDING_ADJUDICATION.json"
        source_path.write_bytes(canonical_bytes(source_drift) + b"\n")
        adjudication_path.write_bytes(canonical_bytes(adjudication) + b"\n")

        bundle_files = [
            "COVERAGE_MATRIX.json",
            "FINDING_ADJUDICATION.json",
            "FINDING_ADJUDICATION.md",
            "INSTALLED_SELECTORS.md",
            "README.md",
            "RETURN.json",
            "RETURN_HANDOFF.md",
            "SELECTED_VECTORS.json",
            "SOURCE_DRIFT.json",
            "T10A_ARCHIVE_VERIFICATION.json",
            "T10A_ARCHIVE_VERIFICATION.md",
            "VALIDATION.md",
            "VECTOR_SELECTION.json",
            "VECTOR_SELECTION.md",
        ]
        ledger = {
            name: (
                hashlib.sha256(source_path.read_bytes()).hexdigest()
                if name == source_path.name
                else hashlib.sha256(adjudication_path.read_bytes()).hexdigest()
                if name == adjudication_path.name
                else hashlib.sha256(f"fixture-{name}".encode()).hexdigest()
            )
            for name in bundle_files
        }
        ledger_path = self.root / "bundle.sha256"
        ledger_path.write_text(
            "".join(f"{ledger[name]}  {name}\n" for name in sorted(ledger)),
            encoding="utf-8",
        )
        expected_authority: dict[str, object] = {
            "review_commit": self.candidate.source.commit,
            "review_tree": self.candidate.source.tree,
            "p0_count": 0,
            "p1_count": 2,
            "p2_count": 1,
            "p3_count": 0,
            "unresolved_blocking_count": 3,
        }
        mutations = [
            {
                "mutation_id": f"T10C-M{index:02d}",
                "caught": index != uncaught_mutation,
            }
            for index in range(1, 25)
        ]
        review_path = self.root / "current-source-independent-review.json"
        review = {
            "schema_version": 1,
            "report_kind": "t10c-current-source-independent-review",
            "reviewer_id": "independent-reviewer",
            "observed_at_unix_ms": 1_000,
            "candidate_commit": self.candidate.source.commit,
            "candidate_tree": self.candidate.source.tree,
            "dirty_input_paths": [],
            "source_drift_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
            "finding_adjudication_sha256": hashlib.sha256(
                adjudication_path.read_bytes()
            ).hexdigest(),
            "bundle_ledger_sha256": hashlib.sha256(ledger_path.read_bytes()).hexdigest(),
            "bundle_manifest_sha256": bundle_manifest_sha256
            or self._t10c_manifest_sha256(ledger),
            "bundle_file_count": 14,
            "finding_count": 18,
            "fixed_count": 15,
            "evidence_gap_count": 3,
            "obsolete_count": 0,
            "gap_ids": review_gap_ids or gap_ids,
            "mutation_count": 24,
            "mutation_caught_count": 23 if uncaught_mutation is not None else 24,
            "mutations": mutations,
            "authority": review_authority or expected_authority,
            "result": "passed",
            "exit_code": 0,
            "diagnostic": None,
        }
        write_canonical_json(review_path, review)
        execution_path = self.root / "current-source-review-execution-report.json"
        write_canonical_json(
            execution_path,
            {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "failed",
                "exit_code": 1,
                "stress": None,
            },
        )
        paths = {
            "SOURCE_DRIFT.json": (source_path, ArtifactKind.JSON, "application/json"),
            "FINDING_ADJUDICATION.json": (
                adjudication_path,
                ArtifactKind.JSON,
                "application/json",
            ),
            "bundle.sha256": (ledger_path, ArtifactKind.JSON, "text/plain"),
            "current-source-independent-review.json": (
                review_path,
                ArtifactKind.REVIEW_REPORT,
                "application/json",
            ),
            "current-source-review-execution-report.json": (
                execution_path,
                ArtifactKind.JSON,
                "application/json",
            ),
        }
        artifacts: list[dict[str, object]] = []
        execution_artifact_id = "artifact-t10c-execution"
        for index, output in enumerate(template.generated_artifacts):
            name = next(name for name in paths if output.endswith(name))
            path, kind, media_type = paths[name]
            artifact_id = (
                execution_artifact_id
                if name == "current-source-review-execution-report.json"
                else f"artifact-t10c-{index}"
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=artifact_id,
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type=media_type,
                )
            )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INDEPENDENT_REVIEW.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-t10c-current-source",
            "command_id": command_id,
            "scenario_id": "t10c.current-source-adjudication",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "independent-reviewer",
                "host": "independent-reviewer",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("c"),
                "working_directory_sha256": sha("d"),
                "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": command_id,
                    "status": "failed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": expected_authority,
        }

    def _independent_review_lens_request(self, command_id: str) -> dict[str, object]:
        lens_id = INDEPENDENT_REVIEW_COMMAND_LENSES[command_id]
        reviewer_id = f"reviewer-{lens_id}"
        receipt_id = f"receipt-{lens_id}"
        layer = EvidenceLayer.INDEPENDENT_REVIEW
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        prerequisite_ids = sorted(template.prerequisite_ids)
        prerequisites = [
            {
                "command_id": item,
                "receipt_id": f"receipt-{item}",
                "canonical_sha256": hashlib.sha256(item.encode()).hexdigest(),
                "qualification_run_id": QUALIFICATION_RUN.run_id,
                "qualification_run_nonce": QUALIFICATION_RUN.nonce,
            }
            for item in prerequisite_ids
        ]
        prerequisite_digest = canonical_sha256(prerequisites)
        topics = dict(
            (
                ("ai-protocol-signed-xpc", ["ai-registry-protocol-xpc-identity", "handle-authority", "multi-round-receipts-crash-recovery"]),
                ("corpus-package-persistence", ["corpus-package-persistence-identity", "tamper-resistance", "migration-atomicity"]),
                ("evidence-retrieval-scheduling", ["evidence-provenance-freshness", "deterministic-retrieval", "scheduler-concurrency-cancellation"]),
                ("scope-installed-ui-governance", ["scope-containment-ui-product-behavior", "signing-build-governance", "false-green-test-audit"]),
            )
        )[lens_id]
        path = self.root / f"{lens_id}-review-report.json"
        write_canonical_json(path, {
            "schema_version": 1, "report_kind": "independent-review-lens-report",
            "lens_id": lens_id, "reviewer_id": reviewer_id,
            "observed_at_unix_ms": 1_001, "candidate_commit": self.candidate.source.commit,
            "candidate_tree": self.candidate.source.tree, "candidate_identity_sha256": candidate_digest,
            "command_id": command_id, "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"), "governed_diff_sha256": sha("c"),
            "prerequisite_receipts": prerequisites, "prerequisite_receipts_sha256": prerequisite_digest,
            "scope_topics": topics, "findings": [], "p0_count": 0, "p1_count": 0,
            "p2_count": 0, "p3_count": 0, "unresolved_blocking_count": 0,
            "result": "passed", "exit_code": 0, "diagnostic": None,
        })
        report_output = next(output for output in template.generated_artifacts if output.endswith(path.name))
        report_artifact_id = f"artifact-{lens_id}"
        artifacts = [self._descriptor(
            path, candidate_digest=candidate_digest, layer=layer, receipt_id=receipt_id,
            command_id=command_id, artifact_id=report_artifact_id,
            kind=ArtifactKind.REVIEW_REPORT, command_output=f"artifact:{report_output}",
            media_type="application/json",
        )]
        execution_path = self.root / f"{lens_id}-review-execution-report.json"
        write_canonical_json(
            execution_path,
            {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256(prerequisites),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "passed",
                "exit_code": 0,
                "stress": None,
            },
        )
        execution_output = next(
            output
            for output in template.generated_artifacts
            if output.endswith(execution_path.name)
        )
        artifacts.append(
            self._descriptor(
                execution_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id=f"artifact-{lens_id}-execution",
                kind=ArtifactKind.JSON,
                command_output=f"artifact:{execution_output}",
                media_type="application/json",
            )
        )
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INDEPENDENT_REVIEW.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-independent-review",
            "command_id": command_id,
            "scenario_id": "merge.governed-files-changed",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": f"artifact-{lens_id}-execution",
            "executor": {
                "executor_id": reviewer_id,
                "host": "independent-reviewer",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("c"),
                "working_directory_sha256": sha("d"),
                "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": [],
                "prerequisite_receipts": prerequisites,
            },
            "artifacts": artifacts,
            "constituents": [{
                "selector_id": lens_id, "status": "passed", "evidence_layer": layer.value,
                "candidate_identity_sha256": candidate_digest, "artifact_ids": [report_artifact_id],
            }],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "review_commit": self.candidate.source.commit,
                "review_tree": self.candidate.source.tree,
                "p0_count": 0,
                "p1_count": 0,
                "p2_count": 0,
                "p3_count": 0,
                "unresolved_blocking_count": 0,
            },
        }

    def _independent_review_request(self) -> dict[str, object]:
        command_id = "review.independent"
        receipt_id = "receipt-independent-review"
        layer = EvidenceLayer.INDEPENDENT_REVIEW
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        artifacts: list[dict[str, object]] = []
        constituents: list[dict[str, object]] = []
        prerequisites: list[dict[str, object]] = []
        for index, (lens_command_id, lens_id) in enumerate(INDEPENDENT_REVIEW_COMMAND_LENSES.items(), 1):
            lens_receipt, _ = emit_executor_receipt(
                self._independent_review_lens_request(lens_command_id), artifact_root=self.root
            )
            receipt_path = self.root / f"{lens_id}-review-receipt.json"
            write_canonical_json(receipt_path, lens_receipt)
            prerequisite = {
                "command_id": lens_command_id,
                "receipt_id": lens_receipt["receipt_id"],
                "canonical_sha256": lens_receipt["canonical_sha256"],
                "qualification_run_id": QUALIFICATION_RUN.run_id,
                "qualification_run_nonce": QUALIFICATION_RUN.nonce,
            }
            prerequisites.append(prerequisite)
            output = next(item for item in template.generated_artifacts if item.endswith(receipt_path.name))
            artifact_id = f"artifact-review-receipt-{index}"
            artifacts.append(self._descriptor(
                receipt_path, candidate_digest=candidate_digest, layer=layer,
                receipt_id=receipt_id, command_id=command_id, artifact_id=artifact_id,
                kind=ArtifactKind.REVIEW_REPORT, command_output=f"artifact:{output}",
                media_type="application/json",
            ))
            constituents.append({
                "selector_id": lens_command_id, "status": "passed", "evidence_layer": layer.value,
                "candidate_identity_sha256": candidate_digest, "artifact_ids": [artifact_id],
            })
        execution_path = self.root / "independent-review-execution-report.json"
        write_canonical_json(execution_path, {
            "schema_version": 2, "qualification_run": dict(QUALIFICATION_RUN_MAPPING), "predecessor_observations_sha256": canonical_sha256(prerequisites), "started_at_unix_ms": 2_000, "ended_at_unix_ms": 3_000,
            "result": "passed", "exit_code": 0, "stress": None,
        })
        execution_output = next(item for item in template.generated_artifacts if item.endswith(execution_path.name))
        artifacts.append(self._descriptor(
            execution_path, candidate_digest=candidate_digest, layer=layer, receipt_id=receipt_id,
            command_id=command_id, artifact_id="artifact-review-execution", kind=ArtifactKind.JSON,
            command_output=f"artifact:{execution_output}", media_type="application/json",
        ))
        return {
            "schema_version": 2, "qualification_run": dict(QUALIFICATION_RUN_MAPPING), "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge", "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INDEPENDENT_REVIEW.value, "receipt_id": receipt_id,
            "requirement_id": "gate-f-independent-review", "command_id": command_id,
            "scenario_id": "merge.governed-files-changed", "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"), "qualified_premerge_authority_sha256": None,
            "attempt": 1, "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": "artifact-review-execution",
            "executor": {"executor_id": "independent-reviewer", "host": "independent-reviewer", "platform": "macos", "architecture": "arm64", "os_version": "macos-27"},
            "command_authority": {"host": template.host.value, "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("c"), "working_directory_sha256": sha("d"), "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts), "generated_logs": [],
                "prerequisite_receipts": prerequisites},
            "artifacts": artifacts, "constituents": constituents, "skips": [], "diagnostic": None,
            "authority": {"review_commit": self.candidate.source.commit, "review_tree": self.candidate.source.tree,
                "p0_count": 0, "p1_count": 0, "p2_count": 0, "p3_count": 0, "unresolved_blocking_count": 0},
        }

    def _deterministic_evidence_request(self) -> dict[str, object]:
        command_id = "reconstruction.deterministic-evidence"
        receipt_id = "receipt-deterministic-evidence"
        layer = EvidenceLayer.XCODE_FOCUSED
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        selector = (
            "CoreTests/ReconstructionDeterministicEvidenceEmitterTests/"
            "testEmitsCanonicalDeterministicEvidenceArtifacts"
        )
        compared = (
            ("corpus", "corpus-manifest.json", "CORPUS", "CORPUS_TWO"),
            (
                "evidence-frontier",
                "evidence-frontier.json",
                "FRONTIER",
                "FRONTIER_TWO",
            ),
            (
                "retrieval-packet",
                "retrieval-packet.json",
                "RETRIEVAL_PACKET",
                "RETRIEVAL_PACKET_TWO",
            ),
            ("receipt", "tool-receipt.json", "RECEIPT", "RECEIPT_TWO"),
            ("checkpoint", "checkpoint.json", "CHECKPOINT", "CHECKPOINT_TWO"),
        )
        artifacts: list[dict[str, object]] = []
        comparison_rows: list[dict[str, object]] = []
        for index, (artifact_id, filename, first_suffix, second_suffix) in enumerate(
            compared
        ):
            descriptors: list[dict[str, object]] = []
            for process_index, suffix in enumerate(
                (first_suffix, second_suffix), start=1
            ):
                path = self.root / f"fresh-process-{process_index}-{filename}"
                write_canonical_json(path, {"artifact": filename, "schema_version": 1})
                output = next(
                    item for item in template.generated_artifacts if item.endswith(suffix)
                )
                descriptor = self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=f"artifact-deterministic-{index}-{process_index}",
                    kind=ArtifactKind.JSON,
                    command_output=f"artifact:{output}",
                    media_type="application/json",
                )
                artifacts.append(descriptor)
                descriptors.append(descriptor)
            comparison_rows.append(
                {
                    "artifact_id": artifact_id,
                    "byte_count": descriptors[0]["byte_count"],
                    "relative_path": filename,
                    "sha256": descriptors[0]["sha256"],
                }
            )
        payload_specs = (
            (
                "DeterministicEvidence.comparison.json",
                "COMPARISON",
                ArtifactKind.JSON,
                {
                    "artifacts": comparison_rows,
                    "candidate_identity_sha256": candidate_digest,
                    "command_id": command_id,
                    "fresh_process_count": 2,
                    "schema_version": 1,
                },
            ),
            (
                "DeterministicEvidence.execution-report.json",
                "EXECUTION_REPORT",
                ArtifactKind.JSON,
                {
                    "schema_version": 2,
                    "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                    "predecessor_observations_sha256": canonical_sha256([]),
                    "started_at_unix_ms": 1_000,
                    "ended_at_unix_ms": 2_000,
                    "result": "passed",
                    "exit_code": 0,
                    "stress": None,
                },
            ),
            (
                "fresh-process-1.test-results.json",
                "TEST_RESULTS_ONE",
                ArtifactKind.TEST_RESULTS,
                self._passing_test_results(selector),
            ),
            (
                "fresh-process-2.test-results.json",
                "TEST_RESULTS_TWO",
                ArtifactKind.TEST_RESULTS,
                self._passing_test_results(selector),
            ),
        )
        execution_artifact_id = "artifact-deterministic-execution"
        for index, (filename, suffix, kind, payload) in enumerate(payload_specs, 10):
            path = self.root / filename
            write_canonical_json(path, payload)
            output = next(
                item for item in template.generated_artifacts if item.endswith(suffix)
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=(
                        execution_artifact_id
                        if suffix == "EXECUTION_REPORT"
                        else f"artifact-deterministic-{index}"
                    ),
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type="application/json",
                )
            )
        log_path = self.root / "deterministic-evidence.log"
        log_path.write_text("deterministic evidence fixture\n", encoding="utf-8")
        artifacts.append(
            self._descriptor(
                log_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id="artifact-deterministic-log",
                kind=ArtifactKind.JSON,
                command_output=f"log:{template.generated_logs[0]}",
                media_type="text/plain",
            )
        )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.TEST_RESULT.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-deterministic-evidence",
            "command_id": command_id,
            "scenario_id": "persistence.atomic-initial-transaction",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "local-xcode27",
                "host": template.host.value,
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("c"),
                "working_directory_sha256": sha("d"),
                "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": command_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "selector_catalog_sha256": self.candidate.selector_catalog_sha256,
                "expected_selector_count": 1,
                "executed_selector_count": 1,
                "passed_selector_count": 1,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
            },
        }

    def _refresh_descriptor(self, request: dict[str, object], path: Path) -> None:
        artifact = next(
            item
            for item in request["artifacts"]
            if isinstance(item, dict) and item["relative_path"] == path.name
        )
        artifact["byte_count"] = path.stat().st_size
        artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def _rebind_t10c_source_artifact(self, request: dict[str, object]) -> None:
        source_path = self.root / "SOURCE_DRIFT.json"
        ledger_path = self.root / "bundle.sha256"
        ledger = {}
        for line in ledger_path.read_text(encoding="utf-8").splitlines():
            digest, name = line.split("  ", 1)
            ledger[name] = digest
        ledger[source_path.name] = hashlib.sha256(source_path.read_bytes()).hexdigest()
        ledger_path.write_text(
            "".join(f"{ledger[name]}  {name}\n" for name in sorted(ledger)),
            encoding="utf-8",
        )
        review_path = self.root / "current-source-independent-review.json"
        review = load_canonical_json(review_path)
        review["source_drift_sha256"] = ledger[source_path.name]
        review["bundle_ledger_sha256"] = hashlib.sha256(
            ledger_path.read_bytes()
        ).hexdigest()
        review["bundle_manifest_sha256"] = self._t10c_manifest_sha256(ledger)
        write_canonical_json(review_path, review)
        for path in (source_path, ledger_path, review_path):
            artifact = next(
                item
                for item in request["artifacts"]
                if item["relative_path"] == path.name
            )
            artifact["byte_count"] = path.stat().st_size
            artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def _merge_authority_request(self, *, postmerge: bool) -> dict[str, object]:
        if postmerge:
            candidate, observation, secondary = postmerge_fixture()
            kind = "postmerge"
            command_id = "postmerge.exact-tree-proof"
            layer = EvidenceLayer.POST_MERGE
            receipt_type = ReceiptType.POST_MERGE
            phase = "postmerge"
            receipt_id = "receipt-postmerge-proof"
            file_specs = {
                "postmerge-observation.json": (
                    "postmerge-observation",
                    ArtifactKind.MERGE_PROOF,
                ),
                "postmerge-workflow.json": (
                    "postmerge-workflow",
                    ArtifactKind.TEST_RESULTS,
                ),
                "postmerge-authority.json": (
                    "postmerge-authority",
                    ArtifactKind.JSON,
                ),
                "postmerge-execution-report.json": (
                    "postmerge-execution-report",
                    ArtifactKind.JSON,
                ),
            }
        else:
            candidate, observation, secondary = prospective_fixture()
            kind = "prospective"
            command_id = "merge.prospective-tree"
            layer = EvidenceLayer.PROSPECTIVE_MERGE_TREE
            receipt_type = ReceiptType.PROSPECTIVE_MERGE_TREE
            phase = "premerge"
            receipt_id = "receipt-prospective-proof"
            file_specs = {
                "prospective-merge-observation.json": (
                    "prospective-merge-observation",
                    ArtifactKind.JSON,
                ),
                "prospective-merge-governed-diff.json": (
                    "prospective-governed-diff",
                    ArtifactKind.MERGE_PROOF,
                ),
                "prospective-merge-authority.json": (
                    "prospective-merge-authority",
                    ArtifactKind.JSON,
                ),
                "prospective-merge-execution-report.json": (
                    "prospective-merge-execution-report",
                    ArtifactKind.JSON,
                ),
            }
        template = self.templates[command_id]
        create_evidence(
            kind=kind,
            candidate_value=candidate_to_mapping(candidate),
            observation=observation,
            secondary=secondary,
            output_directory=self.root,
            qualification_run_id=QUALIFICATION_RUN.run_id,
            qualification_run_nonce=QUALIFICATION_RUN.nonce,
            predecessor_observations_sha256=canonical_sha256([]),
        )
        candidate_digest = candidate_identity_sha256(candidate)
        artifacts: list[dict[str, object]] = []
        for index, (filename, (output_suffix, artifact_kind)) in enumerate(
            sorted(file_specs.items())
        ):
            output = next(
                item for item in template.generated_artifacts if item.endswith(output_suffix)
            )
            path = self.root / filename
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=f"artifact-merge-{index}",
                    kind=artifact_kind,
                    command_output=f"artifact:{output}",
                    media_type="application/json",
                )
            )
        report_name = (
            "postmerge-execution-report.json"
            if postmerge
            else "prospective-merge-execution-report.json"
        )
        report_artifact = next(
            item for item in artifacts if item["relative_path"] == report_name
        )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(candidate),
            "qualification_phase": phase,
            "evidence_layer": layer.value,
            "receipt_type": receipt_type.value,
            "receipt_id": receipt_id,
            "requirement_id": f"gate-f-{kind}-proof",
            "command_id": command_id,
            "scenario_id": f"scenario-{kind}-proof",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": sha("c") if postmerge else None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": report_artifact["artifact_id"],
            "executor": {
                "executor_id": "external-merge-authority",
                "host": "merge-authority",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": "merge-authority",
                "execution_mode": "executor-required",
                "argv_sha256": sha("d"),
                "working_directory_sha256": sha("e"),
                "environment_sha256": sha("f"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": command_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": None,
        }

    @staticmethod
    def _test_results(
        selector: str,
        *,
        result: str = "Passed",
    ) -> dict[str, object]:
        target, suite, method = selector.split("/", 2)
        return {
            "testNodes": [
                {
                    "children": [
                        {
                            "children": [
                                {
                                    "children": [],
                                    "name": method,
                                    "nodeIdentifier": selector,
                                    "nodeType": "Test Case",
                                    "result": result,
                                }
                            ],
                            "name": suite,
                            "nodeIdentifier": f"{target}/{suite}",
                            "nodeType": "Test Suite",
                        }
                    ],
                    "name": target,
                    "nodeIdentifier": target,
                    "nodeType": "Test Plan",
                }
            ]
        }

    @classmethod
    def _passing_test_results(cls, selector: str) -> dict[str, object]:
        return cls._test_results(selector)

    def _stress_request(self) -> dict[str, object]:
        layer = EvidenceLayer.STRESS_RECOVERY
        receipt_id = "receipt-stress-recovery"
        command_id = "stress.reconstruction-authority-races"
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        compiled = compile_authority_stress_plan(self.candidate, repetitions=1)
        plan = plan_mapping(compiled)
        plan["python_results"] = list(
            execute_python_adapters(
                compiled,
                candidate=self.candidate,
                qualification_run=QUALIFICATION_RUN,
            )
        )
        plan_path = self.root / "stress-plan.json"
        write_canonical_json(plan_path, plan)
        ledger_path = self.root / "stress-attempt-ledger.json"
        write_canonical_json(
            ledger_path,
            {
                "attempts": [
                    {
                        "iteration": invocation.iteration,
                        "observed_semantic_axes": list(invocation.semantic_axes),
                        "scenario_id": invocation.scenario_id,
                        "seed": invocation.seed,
                        "status": "passed",
                    }
                    for invocation in compiled.invocations
                    if invocation.adapter.value.startswith("swift-")
                ],
                "schema_version": 1,
            },
        )
        results_path = self.root / "stress-test-results.json"
        write_canonical_json(
            results_path,
            self._passing_test_results(SWIFT_TEST_SELECTOR),
        )
        prepared_xctestrun_path = self.root / "prepared.xctestrun"
        prepared_document = {
            "CoreTests": {
                "BlueprintName": "CoreTests",
                "EnvironmentVariables": {},
                "TestingEnvironmentVariables": {},
            },
            "__xctestrun_metadata__": {"ContainerInfo": {"SchemeName": "MacScopeApp"}},
        }

        with prepared_xctestrun_path.open("wb") as stream:
            plistlib.dump(prepared_document, stream, sort_keys=True)
        xctestrun_path = self.root / "stress.xctestrun"
        stress_document = plistlib.loads(prepared_xctestrun_path.read_bytes())
        for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            stress_document["CoreTests"][field].update(
                {
                    "MACSCOPE_RECONSTRUCTION_STRESS_LEDGER": str(ledger_path),
                    "MACSCOPE_RECONSTRUCTION_STRESS_PLAN": str(plan_path),
                }
            )
        with xctestrun_path.open("wb") as stream:
            plistlib.dump(stress_document, stream, sort_keys=True)
        preparation_receipt_path = self.root / "preparation-receipt.json"
        source = self.candidate.source
        write_canonical_json(
            preparation_receipt_path,
            {
                "schema_version": 1,
                "receipt_kind": "native-live-xpc-preparation",
                "source": {
                    "repository": source.repository,
                    "branch_label": source.branch_label,
                    "commit": source.commit,
                    "tree": source.tree,
                    "dirty": False,
                    "project_yml_sha256": source.project_yml_sha256,
                    "generated_project_sha256": source.generated_project_sha256,
                },
                "toolchain": {
                    "developer_dir": "/Applications/Xcode.app/Contents/Developer",
                    "xcodebuild_sha256": sha("1"),
                    "xcode_version": "27.0",
                    "xcode_build": "27A1",
                    "swiftc_sha256": sha("2"),
                    "swift_version": "Swift 6",
                    "sdk_path": "/Applications/Xcode.app/SDKs/MacOSX.sdk",
                    "sdk_settings_sha256": sha("3"),
                    "sdk_version": "27.0",
                    "sdk_build": "27A1",
                },
                "build": {
                    "scheme": "MacScopeApp",
                    "configuration": "Debug",
                    "destination": "platform=macOS,arch=arm64",
                    "live_test_condition": "MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING",
                },
                "artifacts": {
                    "xctestrun": {
                        "path": "/prepared/MacScopeApp.xctestrun",
                        "sha256": hashlib.sha256(prepared_xctestrun_path.read_bytes()).hexdigest(),
                    },
                    "core_tests": {
                        "path": "/prepared/MacScope.app/Contents/PlugIns/CoreTests.xctest",
                        "closed_tree_sha256": sha("c"),
                        "executable_sha256": sha("d"),
                    },
                    "app": {
                        "path": "/prepared/MacScope.app",
                        "closed_tree_sha256": sha("e"),
                        "executable_sha256": sha("f"),
                    },
                    "native_decompiler": {
                        "path": "/prepared/MacScope.app/Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService",
                        "sha256": sha("a"),
                    },
                },
            },
        )
        attempt_seeds = [item.seed for item in compiled.invocations]
        report_path = self.root / "stress-report.json"
        write_canonical_json(
            report_path,
            {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 10,
                "ended_at_unix_ms": 20,
                "result": "passed",
                "exit_code": 0,
                "stress": {
                    "expected_attempt_count": len(compiled.invocations),
                    "observed_attempt_count": len(compiled.invocations),
                    "attempt_seeds": attempt_seeds,
                    "failed_count": 0,
                },
            },
        )
        artifact_specs = (
            (
                plan_path,
                "artifact-stress-plan",
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_PLAN",
                "application/json",
            ),
            (
                ledger_path,
                "artifact-stress-ledger",
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER",
                "application/json",
            ),
            (
                results_path,
                "artifact-stress-test-results",
                ArtifactKind.TEST_RESULTS,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS",
                "application/json",
            ),
            (
                report_path,
                "artifact-stress-report",
                ArtifactKind.STRESS_REPORT,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                "application/json",
            ),
            (
                xctestrun_path,
                "artifact-stress-xctestrun",
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_XCTESTRUN",
                "application/x-plist",
            ),
            (
                preparation_receipt_path,
                "artifact-stress-preparation-receipt",
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT",
                "application/json",
            ),
            (
                prepared_xctestrun_path,
                "artifact-stress-prepared-xctestrun",
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARED_XCTESTRUN",
                "application/x-plist",
            ),
        )
        artifacts = [
            self._descriptor(
                path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id=artifact_id,
                kind=kind,
                command_output=command_output,
                media_type=media_type,
            )
            for path, artifact_id, kind, command_output, media_type in artifact_specs
        ]
        log_path = self.root / "stress.log"
        log_path.write_text("governed authority-stress fixture log\n", encoding="utf-8")
        artifacts.append(self._descriptor(
            log_path,
            candidate_digest=candidate_digest,
            layer=layer,
            receipt_id=receipt_id,
            command_id=command_id,
            artifact_id="artifact-stress-log",
            kind=ArtifactKind.JSON,
            command_output=f"log:{template.generated_logs[0]}",
            media_type="text/plain",
        ))
        artifact_ids = sorted(
            [item[1] for item in artifact_specs] + ["artifact-stress-log"]
        )
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.STRESS_RECOVERY.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-stress-recovery",
            "command_id": command_id,
            "scenario_id": "stress.reconstruction-authority-races",
            "command_plan_sha256": sha("1"),
            "command_record_sha256": sha("2"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": "artifact-stress-report",
            "executor": {
                "executor_id": "local-xcode27",
                "host": "macos-arm64-xcode27",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": "macos-arm64-xcode27",
                "execution_mode": "executor-required",
                "argv_sha256": sha("3"),
                "working_directory_sha256": sha("4"),
                "environment_sha256": sha("5"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": invocation.scenario_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
                for invocation in compiled.invocations
            ],
            "skips": [],
            "diagnostic": None,
            "authority": None,
        }
    def _hosted_governance_request(self) -> dict[str, object]:
        command_id = "source.hosted-governance"
        receipt_id = "receipt-hosted-governance"
        layer = EvidenceLayer.HOSTED_PURE
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        discovered = ["test_a.py", "test_macos.py"]
        denylisted = [
            {
                "module": "test_macos.py",
                "reason": "uses one exact unmocked macOS host boundary",
            }
        ]
        selected = ["test_a.py"]
        test_ids = ["test_a.HostedGovernanceTests.test_first", "test_a.HostedGovernanceTests.test_second"]
        report = {
            "schema_version": 2,
            "report_kind": "hosted-governance-test-results-v2",
            "command_id": command_id,
            "candidate_identity_sha256": candidate_digest,
            "source_authority": {
                "canonical_source_root": "/private/tmp/macscope-gate-f/sealed-source",
                "git_head_commit": self.candidate.source.commit,
                "git_head_tree": self.candidate.source.tree,
                "source_file_count": 100,
                "source_files_sha256": sha("a"),
                "source_provenance_sha256": sha("b"),
                "test_module_inventory_sha256": canonical_sha256(discovered),
            },
            "discovered_modules": discovered,
            "macos_only_modules": denylisted,
            "selected_modules": selected,
            "expected_test_ids": test_ids,
            "expected_test_ids_sha256": canonical_sha256(test_ids),
            "test_results": [
                {"status": "passed", "test_id": test_id} for test_id in test_ids
            ],
            "expected_test_count": 2,
            "executed_test_count": 2,
            "passed_test_count": 2,
            "failed_test_count": 0,
            "error_test_count": 0,
            "skipped_test_count": 0,
            "expected_failure_count": 0,
            "unexpected_success_count": 0,
            "result": "passed",
            "exit_code": 0,
        }
        execution = {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "predecessor_observations_sha256": canonical_sha256([]),
            "started_at_unix_ms": 1_000,
            "ended_at_unix_ms": 2_000,
            "result": "passed",
            "exit_code": 0,
            "stress": None,
        }
        artifacts: list[dict[str, object]] = []
        execution_artifact_id = "artifact-hosted-execution"
        for suffix, filename, kind, payload in (
            ("TEST_RESULTS", "hosted-test-results.json", ArtifactKind.TEST_RESULTS, report),
            ("EXECUTION_REPORT", "hosted-execution-report.json", ArtifactKind.JSON, execution),
        ):
            path = self.root / filename
            write_canonical_json(path, payload)
            output = next(
                item for item in template.generated_artifacts if item.endswith(suffix)
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=(
                        execution_artifact_id
                        if suffix == "EXECUTION_REPORT"
                        else "artifact-hosted-test-results"
                    ),
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type="application/json",
                )
            )
        log_path = self.root / "hosted-governance.log"
        log_path.write_text("sealed hosted-governance fixture\n", encoding="utf-8")
        artifacts.append(
            self._descriptor(
                log_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id="artifact-hosted-log",
                kind=ArtifactKind.JSON,
                command_output=f"log:{template.generated_logs[0]}",
                media_type="text/plain",
            )
        )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.TEST_RESULT.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-hosted-governance",
            "command_id": command_id,
            "scenario_id": command_id,
            "command_plan_sha256": sha("c"),
            "command_record_sha256": sha("d"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "host-independent",
                "host": template.host.value,
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("e"),
                "working_directory_sha256": sha("f"),
                "environment_sha256": sha("1"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": command_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "selector_catalog_sha256": self.candidate.selector_catalog_sha256,
                "expected_selector_count": 1,
                "executed_selector_count": 1,
                "passed_selector_count": 1,
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
            },
        }

    @staticmethod
    def _png(width: int, height: int, marker: int) -> bytes:
        def chunk(kind: bytes, payload: bytes) -> bytes:
            return (
                len(payload).to_bytes(4, "big")
                + kind
                + payload
                + zlib.crc32(kind + payload).to_bytes(4, "big")
            )

        pixel = bytes((marker % 256, (marker * 17) % 256, (marker * 31) % 256))
        rows = b"".join(
            b"\x00" + pixel + b"\x00\x00\x00" * (width - 1)
            for _ in range(height)
        )
        return (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )

    def _installed_accessibility_request(self) -> dict[str, object]:
        command_id = "installed.accessibility-semantics"
        receipt_id = "receipt-installed-accessibility"
        layer = EvidenceLayer.INSTALLED_ACCESSIBILITY
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        projection = installed_selector_projection(load_installed_selector_catalog())
        observed_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in projection
        ]
        matrix_receipt_sha256 = sha("a")
        screenshot_specs = tuple(
            (
                "SCREENSHOT_" + "_".join(
                    part.upper().replace("-", "_")
                    for part in (presentation_state, appearance, window_size)
                ),
                presentation_state,
                appearance,
                window_size,
                "InstalledAccessibility."
                f"{presentation_state}.{appearance}.{window_size}.png",
                width,
                height,
            )
            for presentation_state, appearance, window_size, width, height
            in PRESENTATION_VARIANTS
        )
        screenshot_rows: list[dict[str, object]] = []
        screenshot_payloads: list[tuple[str, str, bytes]] = []
        for index, (
            suffix,
            presentation_state,
            appearance,
            window_size,
            filename,
            width,
            height,
        ) in enumerate(
            screenshot_specs
        ):
            payload = self._png(width, height, index)
            digest = hashlib.sha256(payload).hexdigest()
            screenshot_rows.append(
                {
                    "appearance": appearance,
                    "byte_count": len(payload),
                    "pixel_height": height,
                    "pixel_width": width,
                    "presentation_state": presentation_state,
                    "relative_path": filename,
                    "sha256": digest,
                    "window_size": window_size,
                }
            )
            screenshot_payloads.append((suffix, filename, payload))
        presentation = {
            "candidate_identity_sha256": candidate_digest,
            "matrix_receipt_sha256": matrix_receipt_sha256,
            "report_kind": "installed-accessibility-presentation",
            "result": "passed",
            "schema_version": 2,
            "screenshots": screenshot_rows,
            "source_xcresult": {
                "bundle_sha256": sha("b"),
                "closed_tree_sha256": sha("c"),
            },
            "test_identifier": (
                "WS24InstalledAppUITests/"
                "testTask10CTaskEvidenceCountsAccessible()"
            ),
        }
        presentation_path = self.root / "InstalledAccessibility.presentation-manifest.json"
        write_canonical_json(presentation_path, presentation)
        accessibility = {
            "candidate_identity_sha256": candidate_digest,
            "counts": {
                "executed": 22,
                "expected": 22,
                "failed": 0,
                "passed": 22,
                "skipped": 0,
            },
            "matrix_receipt": {
                "schema_version": 7,
                "sha256": matrix_receipt_sha256,
            },
            "presentation_manifest_sha256": hashlib.sha256(
                presentation_path.read_bytes()
            ).hexdigest(),
            "report_kind": "installed-accessibility",
            "result": "passed",
            "schema_version": 2,
            "observed_selector_projection_sha256": canonical_sha256(
                observed_projection
            ),
            "selector_catalog_sha256": canonical_sha256(
                [item["test_identifier"] for item in projection]
            ),
            "selector_projection_sha256": canonical_sha256(projection),
            "selectors": [
                {
                    **item,
                    "observed_identifiers": sorted(item["required_identifiers"]),
                    "status": "passed",
                }
                for item in projection
            ],
            "xcresult_semantic_manifest_sha256": sha("d"),
        }
        execution = {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "predecessor_observations_sha256": canonical_sha256([]),
            "started_at_unix_ms": 1_000,
            "ended_at_unix_ms": 2_000,
            "result": "passed",
            "exit_code": 0,
            "stress": None,
        }
        artifacts: list[dict[str, object]] = []
        execution_artifact_id = "artifact-accessibility-execution"
        for suffix, path, kind, media_type, payload in (
            (
                "INSTALLED_ACCESSIBILITY_REPORT",
                self.root / "InstalledAccessibility.accessibility-report.json",
                ArtifactKind.ACCESSIBILITY_REPORT,
                "application/json",
                accessibility,
            ),
            (
                "PRESENTATION_MANIFEST",
                presentation_path,
                ArtifactKind.JSON,
                "application/json",
                presentation,
            ),
            (
                "EXECUTION_REPORT",
                self.root / "InstalledAccessibility.execution-report.json",
                ArtifactKind.JSON,
                "application/json",
                execution,
            ),
        ):
            write_canonical_json(path, payload)
            output = next(
                item for item in template.generated_artifacts if item.endswith(suffix)
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=(
                        execution_artifact_id
                        if suffix == "EXECUTION_REPORT"
                        else f"artifact-accessibility-{suffix.lower()}"
                    ),
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type=media_type,
                )
            )
        for suffix, filename, payload in screenshot_payloads:
            path = self.root / filename
            path.write_bytes(payload)
            output = next(
                item for item in template.generated_artifacts if item.endswith(suffix)
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=f"artifact-accessibility-{suffix.lower()}",
                    kind=ArtifactKind.ACCESSIBILITY_REPORT,
                    command_output=f"artifact:{output}",
                    media_type="image/png",
                )
            )
        log_path = self.root / "installed-accessibility.log"
        log_path.write_text("read-only accessibility projection fixture\n", encoding="utf-8")
        artifacts.append(
            self._descriptor(
                log_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id="artifact-accessibility-log",
                kind=ArtifactKind.JSON,
                command_output=f"log:{template.generated_logs[0]}",
                media_type="text/plain",
            )
        )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INSTALLED_ACCESSIBILITY.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-installed-accessibility",
            "command_id": command_id,
            "scenario_id": "installed.accessibility",
            "command_plan_sha256": sha("e"),
            "command_record_sha256": sha("f"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "local-xcode27-tcc",
                "host": template.host.value,
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("1"),
                "working_directory_sha256": sha("2"),
                "environment_sha256": sha("3"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": "installed.accessibility",
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "app_bundle_id": self.candidate.application.bundle_identifier,
                "app_executable_sha256": self.candidate.application.executable_sha256,
                "selector_count": 1,
                "failed_count": 0,
                "skipped_count": 0,
            },
        }

    def _install_release_request(self) -> dict[str, object]:
        command_id = "install.release-to-applications"
        receipt_id = "receipt-install-release"
        layer = EvidenceLayer.INSTALLED_SOURCE_EQUALITY
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        source_path = "/private/tmp/macscope-gate-f/release/MacScope.app"
        installed_path = "/Applications/MacScope.app"
        equality_authority = {
            "release_bundle_sha256": self.candidate.application.bundle_sha256,
            "release_closed_tree_sha256": self.candidate.application.closed_tree_sha256,
            "release_root_mode": self.candidate.application.root_mode,
            "release_executable_sha256": self.candidate.application.executable_sha256,
            "installed_bundle_sha256": self.candidate.application.bundle_sha256,
            "installed_closed_tree_sha256": self.candidate.application.closed_tree_sha256,
            "installed_root_mode": self.candidate.application.root_mode,
            "installed_executable_sha256": self.candidate.application.executable_sha256,
        }
        operation = {
            "schema_version": 2,
            "report_kind": "release-to-applications-operation",
            "candidate_identity_sha256": candidate_digest,
            "candidate_file_sha256": canonical_sha256(candidate_to_mapping(self.candidate)),
            "source_app_path": source_path,
            "installed_app_path": installed_path,
            "production_destination": installed_path,
            "source_identity": {
                "bundle_sha256": self.candidate.application.bundle_sha256,
                "closed_tree_sha256": self.candidate.application.closed_tree_sha256,
                "root_mode": self.candidate.application.root_mode,
            },
            "predecessor": {"present": False, "identity": None},
            "staging": {
                "fresh_sibling": True,
                "same_volume": True,
                "source_equality_validated": True,
            },
            "atomic_replacement": {
                "primitive": "renameatx_np",
                "mode": "exclusive-absent",
            },
            "rollback": {"attempted": False, "succeeded": None},
            "point_of_no_return_reached": True,
            "predecessor_clearance": {"started": False, "completed": True},
            "transaction_residue": {"present": False, "path": None},
            "result": "passed",
            "diagnostic": None,
        }
        equality = {
            "schema_version": 1,
            "report_kind": "installed-source-equality",
            "candidate_identity_sha256": candidate_digest,
            "source_app_path": source_path,
            "installed_app_path": installed_path,
            "stage_authority": equality_authority,
            "installed_authority": equality_authority,
            "result": "passed",
            "diagnostic": None,
        }
        execution = {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "predecessor_observations_sha256": canonical_sha256([]),
            "started_at_unix_ms": 1_000,
            "ended_at_unix_ms": 2_000,
            "result": "passed",
            "exit_code": 0,
            "stress": None,
        }
        output_specs = (
            (
                "OPERATION_REPORT",
                "InstallReleaseToApplications.operation-report.json",
                ArtifactKind.JSON,
                operation,
            ),
            (
                "SOURCE_EQUALITY_REPORT",
                "InstallReleaseToApplications.source-equality-report.json",
                ArtifactKind.SOURCE_EQUALITY_REPORT,
                equality,
            ),
            (
                "EXECUTION_REPORT",
                "InstallReleaseToApplications.execution-report.json",
                ArtifactKind.JSON,
                execution,
            ),
        )
        artifacts: list[dict[str, object]] = []
        execution_artifact_id = "artifact-install-execution"
        for index, (suffix, filename, kind, payload) in enumerate(output_specs):
            path = self.root / filename
            write_canonical_json(path, payload)
            output = next(
                item for item in template.generated_artifacts if item.endswith(suffix)
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=(
                        execution_artifact_id
                        if suffix == "EXECUTION_REPORT"
                        else f"artifact-install-{index}"
                    ),
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type="application/json",
                )
            )
        log_path = self.root / "install-release.log"
        log_path.write_text("atomic Release installation fixture\n", encoding="utf-8")
        artifacts.append(
            self._descriptor(
                log_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id="artifact-install-log",
                kind=ArtifactKind.JSON,
                command_output=f"log:{template.generated_logs[0]}",
                media_type="text/plain",
            )
        )
        artifact_ids = sorted(str(item["artifact_id"]) for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INSTALLED_SOURCE_EQUALITY.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-install-release",
            "command_id": command_id,
            "scenario_id": "installed.source-binary-equality",
            "command_plan_sha256": sha("a"),
            "command_record_sha256": sha("b"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "local-xcode27-tcc",
                "host": template.host.value,
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("c"),
                "working_directory_sha256": sha("d"),
                "environment_sha256": sha("e"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": "installed.source-binary-equality",
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": equality_authority,
        }

    def _installed_workflow_request(
        self,
        *,
        matrix_schema_version: int = 7,
        overlap: bool = True,
        omitted_role: str | None = None,
        matrix_result: str = "passed",
        skipped_selector_count: int = 0,
        tamper_csv_claims: bool = False,
        empty_csv: bool = False,
        duplicate_role_pid: bool = False,
        empty_process_role: str | None = None,
        semantic_manifest_failed: bool = False,
        presentation_image_count: int = 28,
        duplicate_presentation_content: bool = False,
    ) -> dict[str, object]:
        layer = EvidenceLayer.INSTALLED_WORKFLOW
        receipt_id = "receipt-installed-task10-workflow"
        command_id = "installed.task10-workflow"
        template = self.templates[command_id]
        candidate_digest = candidate_identity_sha256(self.candidate)
        expected_hashes = {"app": self.candidate.application.executable_sha256}
        expected_hashes.update(
            {item.identity_id: item.sha256 for item in self.candidate.application.embedded_executables}
        )
        roles = [role for role in sorted(expected_hashes) if role != omitted_role]
        selector_projection = installed_selector_projection(
            load_installed_selector_catalog()
        )
        selectors = [item["test_identifier"] for item in selector_projection]
        observed_projection = [
            {
                "observed_identifiers": sorted(item["required_identifiers"]),
                "test_identifier": item["test_identifier"],
                "vector_id": item["vector_id"],
            }
            for item in selector_projection
        ]
        if matrix_schema_version not in {2, 7}:
            raise ValueError("matrix_schema_version must be 2 or 7")
        snapshot_xctestrun_fields = (
            ("xctestrun",)
            if matrix_schema_version == 2
            else ("prepared_xctestrun", "execution_xctestrun")
        )
        snapshots = {
            key: {"fixture": key}
            for key in (
                "candidate_identity", "preparation_receipt", "installed_app",
                *snapshot_xctestrun_fields,
                "test_bundle", "ui_runner", "xcodebuild",
            )
        }
        xcresult_payload = {"tests": "passed"}
        xcresult_path = self.root / "installed-matrix.xcresult"
        write_canonical_json(xcresult_path, xcresult_payload)
        xcresult_digest = hashlib.sha256(xcresult_path.read_bytes()).hexdigest()
        xctestrun_products = (
            {"xctestrun": {"path": "/qualification/installed.xctestrun", "sha256": sha("a")}}
            if matrix_schema_version == 2
            else {
                "prepared_xctestrun": {
                    "path": "/qualification/installed.xctestrun",
                    "sha256": sha("a"),
                },
                "execution_xctestrun": {
                    "path": "/qualification/installed-task10-opt-in.xctestrun",
                    "sha256": sha("3"),
                },
            }
        )
        matrix_receipt = {
            "schema_version": matrix_schema_version,
            "receipt_kind": "installed-task10-matrix",
            "candidate": {
                "identity_path": "/qualification/candidate.json",
                "identity_sha256": candidate_digest,
                "source_commit": self.candidate.source.commit,
                "source_tree": self.candidate.source.tree,
                "preparation_receipt_path": "/qualification/preparation.json",
                "preparation_receipt_sha256": sha("6"),
            },
            "products": {
                "installed_app": {
                    "path": "/Applications/MacScope.app",
                    "bundle_identifier": self.candidate.application.bundle_identifier,
                    "content_sha256": self.candidate.application.bundle_sha256,
                    "closed_tree_sha256": self.candidate.application.bundle_sha256,
                    "executable_path": "/Applications/MacScope.app/Contents/MacOS/MacScope",
                    "executable_sha256": self.candidate.application.executable_sha256,
                },
                **xctestrun_products,
                "test_bundle": {
                    "path": "/qualification/Runner.app/Contents/PlugIns/MacScopeInstalledAppUITests.xctest",
                    "bundle_identifier": "org.macscope.app.tests",
                    "content_sha256": sha("b"), "closed_tree_sha256": sha("c"),
                    "executable_path": "/qualification/Runner.app/Contents/PlugIns/MacScopeInstalledAppUITests.xctest/Contents/MacOS/MacScopeInstalledAppUITests",
                    "executable_sha256": sha("d"),
                },
                "ui_runner": {
                    "path": "/qualification/Runner.app",
                    "bundle_identifier": "org.macscope.app.runner",
                    "content_sha256": sha("e"), "closed_tree_sha256": sha("f"),
                    "executable_path": "/qualification/Runner.app/Contents/MacOS/Runner",
                    "executable_sha256": sha("1"),
                },
                "xcresult": {
                    "path": "/qualification/installed-matrix.xcresult",
                    "closed_tree_sha256": sha("2"),
                },
            },
            "execution": {
                "argv": ["/usr/bin/xcodebuild"],
                "selectors": selectors,
                "environment": {
                    "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
                    "HOME": "/private/tmp/home", "LOGNAME": "tester",
                    "MACSCOPE_WS24_INSTALLED_APP": "/Applications/MacScope.app",
                    "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST": "1",
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "TMPDIR": "/private/tmp", "USER": "tester",
                },
                "started_at_unix_ms": 1_100, "ended_at_unix_ms": 1_900,
                "duration_ms": 800,
                "exit_code": 0 if matrix_result == "passed" else 1,
                "result": matrix_result,
                "failure": None,
                "input_snapshot_before": snapshots,
                "input_snapshot_after": snapshots,
            },
        }
        if matrix_schema_version == 7:
            presentation_root = (
                self.root / "installed-matrix.xcresult.presentation-screenshots"
            )
            presentation_root.mkdir(exist_ok=True)
            presentation_attachments = []
            physical_manifest_attachments = []
            png_by_format: dict[tuple[str, str], bytes] = {}
            for marker, (
                presentation_state,
                appearance,
                window_size,
                width,
                height,
            ) in enumerate(PRESENTATION_VARIANTS[:presentation_image_count], start=1):
                exported_name = (
                    f"{presentation_state}-{appearance}-{window_size}.png"
                )
                png = self._png(width, height, marker)
                format_key = (appearance, window_size)
                if duplicate_presentation_content and marker == presentation_image_count:
                    png = png_by_format[format_key]
                else:
                    png_by_format.setdefault(format_key, png)
                (presentation_root / exported_name).write_bytes(png)
                presentation_attachments.append({
                    "test_identifier": PRESENTATION_TEST_IDENTIFIER,
                    "scenario": PRESENTATION_SCENARIO,
                    "presentation_state": presentation_state,
                    "appearance": appearance,
                    "window_size": window_size,
                    "attachment_path": (
                        "/qualification/installed-matrix.xcresult.presentation-screenshots/"
                        + exported_name
                    ),
                    "sha256": hashlib.sha256(png).hexdigest(),
                    "pixel_width": width,
                    "pixel_height": height,
                })
                physical_manifest_attachments.append({
                    "exportedFileName": exported_name,
                    "suggestedHumanReadableName": expected_presentation_attachment_name(
                        self.candidate,
                        presentation_state,
                        appearance,
                        window_size,
                    ),
                    "isAssociatedWithFailure": False,
                })
            presentation_manifest = [{
                "testIdentifier": PRESENTATION_TEST_IDENTIFIER,
                "attachments": physical_manifest_attachments,
            }]
            presentation_manifest_bytes = canonical_bytes(presentation_manifest)
            (presentation_root / "manifest.json").write_bytes(
                presentation_manifest_bytes
            )
            matrix_receipt["presentation_screenshots"] = {
                "artifact_root_path": (
                    "/qualification/installed-matrix.xcresult.presentation-screenshots"
                ),
                "manifest_path": (
                    "/qualification/installed-matrix.xcresult.presentation-screenshots/"
                    "manifest.json"
                ),
                "manifest_sha256": hashlib.sha256(
                    presentation_manifest_bytes
                ).hexdigest(),
                "attachments": presentation_attachments,
            }
            matrix_receipt["accessibility_observations"] = {
                "artifact_root_path": "/qualification/installed-matrix.xcresult.accessibility-observations",
                "manifest_path": "/qualification/installed-matrix.xcresult.accessibility-observations/manifest.json",
                "manifest_sha256": sha("4"),
                "attachments": [
                    {
                        "attachment_path": (
                            "/qualification/installed-matrix.xcresult.accessibility-observations/"
                            f"observation-{index:02d}.json"
                        ),
                        "observed_identifiers": item["observed_identifiers"],
                        "sha256": hashlib.sha256(
                            item["test_identifier"].encode()
                        ).hexdigest(),
                        "test_identifier": item["test_identifier"],
                        "vector_id": item["vector_id"],
                    }
                    for index, item in enumerate(observed_projection)
                ],
                "observed_selector_projection": observed_projection,
                "observed_selector_projection_sha256": canonical_sha256(
                    observed_projection
                ),
            }
            matrix_receipt["execution"]["selector_projection"] = selector_projection
            matrix_receipt["execution"]["selector_projection_sha256"] = canonical_sha256(
                selector_projection
            )
        matrix_receipt_path = self.root / "installed-matrix-receipt.json"
        write_canonical_json(matrix_receipt_path, matrix_receipt)
        matrix_receipt_digest = hashlib.sha256(matrix_receipt_path.read_bytes()).hexdigest()
        semantic_selector_records = [
            {"test_identifier": identifier, "status": "passed"}
            for identifier in selectors
        ]
        if semantic_manifest_failed:
            semantic_selector_records[0]["status"] = "failed"
        semantic_manifest = {
            "schema_version": 3,
            "candidate_identity_sha256": candidate_digest,
            "source_xcresult": {
                "bundle_sha256": xcresult_digest,
                "closed_tree_sha256": sha("2"),
            },
            "selector_catalog_sha256": canonical_sha256(selectors),
            "selector_projection": selector_projection,
            "selector_projection_sha256": canonical_sha256(selector_projection),
            "observed_selector_projection": observed_projection,
            "observed_selector_projection_sha256": canonical_sha256(
                observed_projection
            ),
            "expected_selector_count": 22,
            "executed_selector_count": 22,
            "passed_selector_count": 21 if semantic_manifest_failed else 22,
            "failed_selector_count": 1 if semantic_manifest_failed else 0,
            "skipped_selector_count": 0,
            "selectors": semantic_selector_records,
            "result": "failed" if semantic_manifest_failed else "passed",
        }
        semantic_manifest_path = self.root / "installed-matrix.xcresult.semantic.json"
        write_canonical_json(semantic_manifest_path, semantic_manifest)
        semantic_manifest_digest = hashlib.sha256(
            semantic_manifest_path.read_bytes()
        ).hexdigest()
        csv_payload = "" if empty_csv else ",bytes_in,bytes_out,\n" * 5
        csv_digest = hashlib.sha256(csv_payload.encode()).hexdigest()
        network_report = {
            "schema_version": 4,
            "attribution": {
                "policy_id": "prearmed-kqueue-path-v1",
                "observer_spawn_ns": 10, "observer_eof_ns": 20, "queue_closed_ns": 30,
                "proofs": [],
                "drains": [{"drain_id": 1, "begin_monotonic_ns": 21,
                            "end_monotonic_ns": 22, "completed_to_empty": True, "events": []}],
            },
            "command_id": "installed.network-acquisition-audit",
            "evidence_layer": "installed-launch-log",
            "candidate": {
                "identity_sha256": candidate_digest,
                "document_sha256": sha("9"),
                "source_commit": self.candidate.source.commit,
                "source_tree": self.candidate.source.tree,
            },
            "workload": {
                "command_id": command_id,
                "started_at_unix_ms": 1_100,
                "ended_at_unix_ms": 1_900,
                "observation_contains_workload": overlap,
                "observer_ready_at_unix_ms": 1_050,
                "observer_readiness_precedes_workload": True,
                "matrix_receipt_sha256": matrix_receipt_digest,
                "xcresult_bundle_sha256": xcresult_digest,
                "xcresult_closed_tree_sha256": sha("2"),
                "xcresult_semantic_manifest_sha256": semantic_manifest_digest,
                "selector_catalog_sha256": canonical_sha256(selectors),
                "selector_projection_sha256": canonical_sha256(selector_projection),
                "expected_selector_count": 22,
                "executed_selector_count": 22 - skipped_selector_count,
                "passed_selector_count": 22 - skipped_selector_count,
                "failed_selector_count": 0 if matrix_result == "passed" else 1,
                "skipped_selector_count": skipped_selector_count,
                "matrix_result": matrix_result,
            },
            "executables": [
                {
                    "identity_id": role,
                    "executable_path": (
                        "/Applications/MacScope.app/Contents/MacOS/MacScope" if role == "app" else
                        "/Applications/MacScope.app/Contents/XPCServices/{0}.xpc/Contents/MacOS/{0}".format({
                            "ai-agent-worker": "AIAgentWorkerXPCService",
                            "analysis-worker": "AnalysisWorkerXPCService",
                            "native-decompiler": "NativeDecompilerXPCService",
                            "shell-broker": "ShellBrokerXPCService",
                        }[role])
                    ),
                    "executable_sha256": expected_hashes[role],
                    "processes": [] if role == empty_process_role else [{
                        "pid": 100 if duplicate_role_pid and index < 2 else index + 100,
                        "start_time_unix_us": 1_000 + index,
                    }],
                }
                for index, role in enumerate(roles)
            ],
            "observer": {
                "observer_id": "nettop-prearmed-foreign-exclusion-v4",
                "evidence_scope": "sampled-external-undefined-state-for-five-governed-executables",
                "limitations": ["not-packet-complete", "no-sub-sample-lifecycle-or-traffic-proof",
                                "excludes-shell-broker-children-and-delegated-services",
                                "not-universal-network-or-acquisition-absence"],
                "tool_path": "/usr/bin/nettop",
                "tool_sha256": sha("8"),
                "interface_scope": ["external", "undefined"],
                "loopback_excluded": True,
                "observed_sample_count": 5,
                "observed_process_row_count": 0,
                "observed_candidate_row_count": 0,
                "observed_foreign_row_count": 0,
                "observed_unresolved_row_count": 0,
                "availability": "available",
                "observer_invocation_count": 1,
                "continuous_interval_started_at_unix_ms": 1_000,
                "continuous_interval_ready_at_unix_ms": 1_050,
                "continuous_interval_ended_at_unix_ms": 2_000,
                "continuity_proven": True,
                "readiness_frame_sha256": hashlib.sha256(
                    b"readiness-frame"
                ).hexdigest(),
                "readiness_proven": True,
                "stopped_by_auditor": True,
                "observation_byte_count": len(csv_payload.encode()) + (1 if tamper_csv_claims else 0),
                "observation_sha256": sha("7") if tamper_csv_claims else csv_digest,
            },
            "artifacts": [],
            "started_at_unix_ms": 1_000,
            "ended_at_unix_ms": 2_000,
            "result": "passed",
            "exit_code": 0,
            "diagnostic": None,
        }
        output_specs = {
            "stdout-json:installed-task10-matrix-summary": (
                "installed-summary.json", ArtifactKind.JSON, "application/json", {"result": "passed"}
            ),
            next(item for item in template.generated_artifacts if item == "@installed_matrix_receipt@"): (
                "installed-matrix-receipt.json", ArtifactKind.JSON, "application/json", matrix_receipt
            ),
            next(
                item
                for item in template.generated_artifacts
                if item == "@installed_matrix_xcresult_semantic_manifest@"
            ): (
                "installed-matrix.xcresult.semantic.json",
                ArtifactKind.JSON,
                "application/json",
                semantic_manifest,
            ),
            next(item for item in template.generated_artifacts if item.endswith("/InstalledNetworkAcquisition.audit.json")): (
                "InstalledNetworkAcquisition.audit.json", ArtifactKind.WORKFLOW_REPORT, "application/json", network_report
            ),
            next(item for item in template.generated_artifacts if item.endswith("/InstalledNetworkAcquisition.execution-report.json")): (
                "InstalledNetworkAcquisition.execution-report.json", ArtifactKind.JSON, "application/json",
                {"schema_version": 2, "qualification_run": dict(QUALIFICATION_RUN_MAPPING), "predecessor_observations_sha256": canonical_sha256([]), "started_at_unix_ms": 1_000, "ended_at_unix_ms": 2_000, "result": "passed", "exit_code": 0, "stress": None},
            ),
            next(item for item in template.generated_artifacts if item.endswith("/InstalledNetworkAcquisition.nettop.csv")): (
                "InstalledNetworkAcquisition.nettop.csv", ArtifactKind.LAUNCH_LOG, "text/csv", csv_payload
            ),
        }
        artifacts: list[dict[str, object]] = []
        execution_artifact_id = "artifact-installed-network-execution"
        for index, output in enumerate(template.generated_artifacts):
            name, kind, media_type, payload = output_specs[output]
            path = self.root / name
            if isinstance(payload, dict):
                write_canonical_json(path, payload)
            else:
                path.write_text(payload, encoding="utf-8")
            artifact_id = (
                execution_artifact_id
                if output.endswith("/InstalledNetworkAcquisition.execution-report.json")
                else f"artifact-installed-{index}"
            )
            artifacts.append(
                self._descriptor(
                    path,
                    candidate_digest=candidate_digest,
                    layer=layer,
                    receipt_id=receipt_id,
                    command_id=command_id,
                    artifact_id=artifact_id,
                    kind=kind,
                    command_output=f"artifact:{output}",
                    media_type=media_type,
                )
            )
        log_path = self.root / "installed-task10.log"
        log_path.write_text("installed Task 10 workflow\n", encoding="utf-8")
        artifacts.append(
            self._descriptor(
                log_path,
                candidate_digest=candidate_digest,
                layer=layer,
                receipt_id=receipt_id,
                command_id=command_id,
                artifact_id="artifact-installed-log",
                kind=ArtifactKind.JSON,
                command_output=f"log:{template.generated_logs[0]}",
                media_type="text/plain",
            )
        )
        artifact_ids = sorted(item["artifact_id"] for item in artifacts)
        return {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "candidate_identity": candidate_to_mapping(self.candidate),
            "qualification_phase": "premerge",
            "evidence_layer": layer.value,
            "receipt_type": ReceiptType.INSTALLED_WORKFLOW.value,
            "receipt_id": receipt_id,
            "requirement_id": "gate-f-installed-task10-network",
            "command_id": command_id,
            "scenario_id": "installed.no-unauthorized-network-or-acquisition",
            "command_plan_sha256": sha("1"),
            "command_record_sha256": sha("2"),
            "qualified_premerge_authority_sha256": None,
            "attempt": 1,
            "artifact_root_id": "qualification-run",
            "execution_report_artifact_id": execution_artifact_id,
            "executor": {
                "executor_id": "local-xcode27-tcc",
                "host": "macos-arm64-xcode27-tcc",
                "platform": "macos",
                "architecture": "arm64",
                "os_version": "macos-27",
            },
            "command_authority": {
                "host": template.host.value,
                "execution_mode": template.execution_mode.value,
                "argv_sha256": sha("3"),
                "working_directory_sha256": sha("4"),
                "environment_sha256": sha("5"),
                "generated_artifacts": list(template.generated_artifacts),
                "generated_logs": list(template.generated_logs),
                "prerequisite_receipts": [],
            },
            "artifacts": artifacts,
            "constituents": [
                {
                    "selector_id": "installed.no-unauthorized-network-or-acquisition",
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": artifact_ids,
                }
            ],
            "skips": [],
            "diagnostic": None,
            "authority": {
                "app_bundle_id": self.candidate.application.bundle_identifier,
                "app_executable_sha256": self.candidate.application.executable_sha256,
                "selector_count": 1,
                "failed_count": 0,
                "skipped_count": 0,
            },
        }

    def _failed_stress_request(self) -> dict[str, object]:
        request = self._stress_request()
        plan_path = self.root / "stress-plan.json"
        ledger_path = self.root / "stress-attempt-ledger.json"
        results_path = self.root / "stress-test-results.json"
        report_path = self.root / "stress-report.json"
        plan = load_canonical_json(plan_path)
        ledger = load_canonical_json(ledger_path)
        swift_attempts = ledger["attempts"]
        failure_index = len(swift_attempts) // 2
        attempted = swift_attempts[: failure_index + 1]
        attempted[-1]["observed_semantic_axes"] = []
        attempted[-1]["status"] = "failed"
        write_canonical_json(
            ledger_path,
            {"attempts": attempted, "schema_version": 1},
        )
        write_canonical_json(
            results_path,
            self._test_results(SWIFT_TEST_SELECTOR, result="Failed"),
        )
        expected_attempts = plan["invocations"]
        python_attempt_count = len(plan["python_results"])
        observed_attempt_count = python_attempt_count + len(attempted)
        write_canonical_json(
            report_path,
            {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 10,
                "ended_at_unix_ms": 20,
                "result": "failed",
                "exit_code": 1,
                "stress": {
                    "expected_attempt_count": len(expected_attempts),
                    "observed_attempt_count": observed_attempt_count,
                    "attempt_seeds": [item["seed"] for item in expected_attempts],
                    "failed_count": 1,
                },
            },
        )
        status_by_scenario = {
            item["scenario_id"]: "passed" for item in plan["python_results"]
        }
        status_by_scenario.update(
            {
                item["scenario_id"]: item["status"]
                for item in attempted
            }
        )
        for constituent in request["constituents"]:
            constituent["status"] = status_by_scenario.get(
                constituent["selector_id"],
                "not-run",
            )
        replacements = {
            "artifact-stress-ledger": (
                ledger_path,
                ArtifactKind.JSON,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_ATTEMPT_LEDGER",
                "application/json",
            ),
            "artifact-stress-test-results": (
                results_path,
                ArtifactKind.TEST_RESULTS,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_TEST_RESULTS",
                "application/json",
            ),
            "artifact-stress-report": (
                report_path,
                ArtifactKind.STRESS_REPORT,
                "artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                "application/json",
            ),
        }
        candidate_digest = candidate_identity_sha256(self.candidate)
        for index, artifact in enumerate(request["artifacts"]):
            replacement = replacements.get(artifact["artifact_id"])
            if replacement is None:
                continue
            path, kind, command_output, media_type = replacement
            request["artifacts"][index] = self._descriptor(
                path,
                candidate_digest=candidate_digest,
                layer=EvidenceLayer.STRESS_RECOVERY,
                receipt_id="receipt-stress-recovery",
                command_id="stress.reconstruction-authority-races",
                artifact_id=artifact["artifact_id"],
                kind=kind,
                command_output=command_output,
                media_type=media_type,
            )
        return request

    def test_emits_a_sealed_receipt_valid_under_the_exact_context(self) -> None:
        receipt, context = emit_executor_receipt(
            self._signed_xpc_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")
        self.assertEqual(
            receipt["canonical_sha256"],
            canonical_sha256(
                {key: value for key, value in receipt.items() if key != "canonical_sha256"}
            ),
        )

    def test_request_schema_rejects_missing_and_unknown_fields(self) -> None:
        request = self._signed_xpc_request()
        request["unexpected"] = True
        with self.assertRaisesRegex(ReceiptEmissionError, "unknown-field"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._signed_xpc_request()
        del request["scenario_id"]
        with self.assertRaisesRegex(ReceiptEmissionError, "missing-field"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_physical_artifact_hash_and_ordinary_file_are_mandatory(self) -> None:
        request = self._signed_xpc_request()
        request["artifacts"][2]["sha256"] = sha("f")
        with self.assertRaisesRegex(ReceiptEmissionError, "artifact-sha256-mismatch"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._signed_xpc_request()
        signed_worker = self.root / "signed-worker"
        signed_worker.unlink()
        signed_worker.symlink_to(self.root / "execution-report.json")
        request["artifacts"][2]["byte_count"] = request["artifacts"][0]["byte_count"]
        request["artifacts"][2]["sha256"] = request["artifacts"][0]["sha256"]
        with self.assertRaisesRegex(ReceiptEmissionError, "artifact-symlink"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_signed_xpc_rejects_arbitrary_executable_even_when_descriptor_matches(self) -> None:
        request = self._signed_xpc_request()
        path = self.root / "signed-worker"
        path.write_bytes(b"arbitrary-labeled-executable\n")
        request["artifacts"][2] = self._descriptor(
            path,
            candidate_digest=candidate_identity_sha256(self.candidate),
            layer=EvidenceLayer.SIGNED_XPC,
            receipt_id="receipt-signed-xpc",
            command_id="task8.signed-worker-parity",
            artifact_id="artifact-signed-worker",
            kind=ArtifactKind.SIGNED_EXECUTABLE,
            command_output="artifact:stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTABLE",
            media_type="application/octet-stream",
        )

        with self.assertRaisesRegex(ReceiptEmissionError, "physical signed executable"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_signed_xpc_rejects_a_different_candidate_service_even_when_signed(self) -> None:
        request = self._signed_xpc_request()
        # Mutation check: native-decompiler is another valid qualification
        # executable, so accepting it would prove only "some candidate service"
        # rather than the Task 8 AI-agent worker contract.
        request["authority"]["service_identity_id"] = "native-decompiler"
        request["authority"]["service_bundle_id"] = "org.macscope.app.NativeDecompiler"
        request["authority"]["service_executable_sha256"] = sha("d")
        with self.assertRaisesRegex(ReceiptEmissionError, "governed command identity"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_all_signed_xpc_commands_bind_their_exact_candidate_service(self) -> None:
        self.assertEqual(
            SIGNED_XPC_SERVICE_IDENTITIES,
            {
                "signed-xpc.complete-truncated-content": "native-decompiler",
                "signed-xpc.error-cancellation": "native-decompiler",
                "signed-xpc.supervision": "native-decompiler",
                "task8.signed-worker-parity": "ai-agent-worker",
            },
        )
        original_candidate = self.candidate
        worker_digest = hashlib.sha256(self.signed_worker_payload).hexdigest()
        for command_id, identity_id in SIGNED_XPC_SERVICE_IDENTITIES.items():
            with self.subTest(command_id=command_id):
                self.candidate = replace(
                    original_candidate,
                    application=replace(
                        original_candidate.application,
                        qualification_executables=tuple(
                            replace(item, sha256=worker_digest)
                            if item.identity_id == identity_id
                            else item
                            for item in original_candidate.application.qualification_executables
                        ),
                    ),
                )
                receipt, context = emit_executor_receipt(
                    self._signed_xpc_request(command_id=command_id),
                    artifact_root=self.root,
                )
                self.assertEqual(validate_receipt(receipt, context=context), ())
        self.candidate = original_candidate

    def test_signed_xpc_command_mapping_missing_or_wrong_fails_closed(self) -> None:
        worker_digest = hashlib.sha256(self.signed_worker_payload).hexdigest()
        self.candidate = replace(
            self.candidate,
            application=replace(
                self.candidate.application,
                qualification_executables=tuple(
                    replace(item, sha256=worker_digest)
                    if item.identity_id == "native-decompiler"
                    else item
                    for item in self.candidate.application.qualification_executables
                ),
            ),
        )
        command_id = "signed-xpc.supervision"
        request = self._signed_xpc_request(command_id=command_id)
        with mock.patch.dict(SIGNED_XPC_SERVICE_IDENTITIES, {}, clear=True):
            with self.assertRaisesRegex(ReceiptEmissionError, "no declared service identity"):
                emit_executor_receipt(request, artifact_root=self.root)
        with mock.patch.dict(
            SIGNED_XPC_SERVICE_IDENTITIES,
            {command_id: "ai-agent-worker"},
            clear=True,
        ):
            with self.assertRaisesRegex(ReceiptEmissionError, "governed command identity"):
                emit_executor_receipt(request, artifact_root=self.root)

    def test_signed_xpc_rejects_arbitrary_test_result_bytes_with_matching_descriptor(self) -> None:
        request = self._signed_xpc_request()
        path = self.root / "test-results.json"
        write_canonical_json(path, {"arbitrary": "passed"})
        request["artifacts"][1] = self._descriptor(
            path,
            candidate_digest=candidate_identity_sha256(self.candidate),
            layer=EvidenceLayer.SIGNED_XPC,
            receipt_id="receipt-signed-xpc",
            command_id="task8.signed-worker-parity",
            artifact_id="artifact-test-results",
            kind=ArtifactKind.TEST_RESULTS,
            command_output="artifact:stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_TEST_RESULTS",
            media_type="application/json",
        )

        with self.assertRaisesRegex(ReceiptEmissionError, "testNodes"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_failed_signed_xpc_requires_the_exact_selected_physical_failure(self) -> None:
        request = self._signed_xpc_request(
            report={
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "failed",
                "exit_code": 1,
                "stress": None,
            }
        )
        request["authority"].update(
            {
                "failed_count": 1,
                "failure_stage": "selected-test",
                "failure_reason": "selected-test-failed",
            }
        )
        request["authority"].update(
            {
                "failed_count": 1,
            }
        )
        # The default passed result is just as misleading as arbitrary JSON for
        # a failed execution receipt; this must be a physical selected failure.
        with self.assertRaisesRegex(ReceiptEmissionError, "physical failure"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._signed_xpc_request(
            report={
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "failed",
                "exit_code": 1,
                "stress": None,
            }
        )
        request["authority"].update(
            {
                "failed_count": 1,
                "failure_stage": "selected-test",
                "failure_reason": "selected-test-failed",
            }
        )
        request["authority"].update(
            {
                "failed_count": 1,
            }
        )
        path = self.root / "test-results.json"
        write_canonical_json(path, {"unrelated": "failure"})
        request["artifacts"][1] = self._descriptor(
            path,
            candidate_digest=candidate_identity_sha256(self.candidate),
            layer=EvidenceLayer.SIGNED_XPC,
            receipt_id="receipt-signed-xpc",
            command_id="task8.signed-worker-parity",
            artifact_id="artifact-test-results",
            kind=ArtifactKind.TEST_RESULTS,
            command_output="artifact:stdout-path:MACSCOPE_SIGNED_RECONSTRUCTION_TEST_RESULTS",
            media_type="application/json",
        )
        with self.assertRaisesRegex(ReceiptEmissionError, "testNodes"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_failed_signed_xpc_rejects_unapproved_stage_and_reason(self) -> None:
        request = self._signed_xpc_request(
            report={
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "failed",
                "exit_code": 1,
                "stress": None,
            }
        )
        request["authority"].update(
            {
                "failed_count": 1,
                "failure_stage": "arbitrary-stage",
                "failure_reason": "arbitrary-reason",
            }
        )
        with self.assertRaisesRegex(ReceiptEmissionError, "closed failure classification"):
            emit_executor_receipt(request, artifact_root=self.root)


    def test_signed_xpc_rejects_candidate_and_physical_executable_drift(self) -> None:
        request = self._signed_xpc_request()
        alternate = sha("f")
        for item in request["candidate_identity"]["application"][
            "qualification_executables"
        ]:
            if item["identity_id"] == "ai-agent-worker":
                item["sha256"] = alternate
        request["authority"]["service_executable_sha256"] = alternate
        parsed, issues = parse_candidate_identity(request["candidate_identity"])
        self.assertEqual(issues, ())
        self.assertIsNotNone(parsed)
        candidate_digest = candidate_identity_sha256(parsed)
        for artifact in request["artifacts"]:
            artifact["candidate_identity_sha256"] = candidate_digest
        for constituent in request["constituents"]:
            constituent["candidate_identity_sha256"] = candidate_digest

        with self.assertRaisesRegex(ReceiptEmissionError, "physical signed executable"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_timing_result_and_report_shape_fail_closed(self) -> None:
        request = self._signed_xpc_request(
            report={
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 20,
                "ended_at_unix_ms": 10,
                "result": "passed",
                "exit_code": 0,
                "stress": None,
            }
        )
        with self.assertRaisesRegex(ReceiptEmissionError, "must not precede start"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._signed_xpc_request(
            report={
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 10,
                "ended_at_unix_ms": 20,
                "result": "passed",
                "exit_code": 1,
                "stress": None,
            }
        )
        with self.assertRaisesRegex(ReceiptEmissionError, "requires exit code 0"):
            emit_executor_receipt(request, artifact_root=self.root)

        report = {
            "schema_version": 2,
            "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
            "predecessor_observations_sha256": canonical_sha256([]),
            "started_at_unix_ms": 10,
            "ended_at_unix_ms": 20,
            "result": "passed",
            "exit_code": 0,
            "stress": None,
            "unexpected": True,
        }
        request = self._signed_xpc_request(report=report)
        with self.assertRaisesRegex(ReceiptEmissionError, "unknown-field"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_execution_report_is_decoded_from_descriptor_bytes_and_swap_fails_closed(self) -> None:
        request = self._signed_xpc_request()
        # A path loader is deliberately poisoned: receipt emission must consume
        # the exact descriptor-read bytes instead and still pass.
        with mock.patch.object(
            executor_receipt_module,
            "load_canonical_json",
            side_effect=AssertionError("path reread is forbidden"),
        ):
            receipt, _ = emit_executor_receipt(request, artifact_root=self.root)
        self.assertEqual(receipt["evidence_status"], "passed")

        request = self._signed_xpc_request()
        original_reader = executor_receipt_module.read_descriptor_relative_bytes
        swapped = False

        def swap_after_read(root, relative_path, **kwargs):
            nonlocal swapped
            value = original_reader(root, relative_path, **kwargs)
            if relative_path == "execution-report.json" and not swapped:
                swapped = True
                write_canonical_json(
                    self.root / relative_path,
                    {
                        "schema_version": 2,
                        "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                        "predecessor_observations_sha256": canonical_sha256([]),
                        "started_at_unix_ms": 1,
                        "ended_at_unix_ms": 2,
                        "result": "failed",
                        "exit_code": 1,
                        "stress": None,
                    },
                )
            return value

        with mock.patch.object(
            executor_receipt_module,
            "read_descriptor_relative_bytes",
            side_effect=swap_after_read,
        ):
            with self.assertRaisesRegex(ReceiptEmissionError, "artifact changed"):
                emit_executor_receipt(request, artifact_root=self.root)
        self.assertTrue(swapped)

    def test_hosted_governance_semantically_binds_sealed_source_and_test_closure(self) -> None:
        receipt, context = emit_executor_receipt(
            self._hosted_governance_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_hosted_governance_rejects_rehashed_source_and_leaf_mutations(self) -> None:
        cases = (
            (
                "source-tree",
                lambda report: report["source_authority"].update(
                    git_head_tree="f" * 40
                ),
                "exact sealed candidate source",
            ),
            (
                "module-closure",
                lambda report: report["selected_modules"].append("test_macos.py"),
                "module closure differs",
            ),
            (
                "leaf-status",
                lambda report: report["test_results"][0].update(status="skipped"),
                "non-passed leaf",
            ),
            (
                "leaf-omission",
                lambda report: report["test_results"].pop(),
                "does not close the exact expected test IDs",
            ),
        )
        for mutation, mutate, expected in cases:
            with self.subTest(mutation=mutation):
                request = self._hosted_governance_request()
                path = self.root / "hosted-test-results.json"
                report = load_canonical_json(path)
                mutate(report)
                write_canonical_json(path, report)
                self._refresh_descriptor(request, path)
                with self.assertRaisesRegex(ReceiptEmissionError, expected):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_installed_accessibility_binds_required_identifiers_and_28_pngs(self) -> None:
        receipt, context = emit_executor_receipt(
            self._installed_accessibility_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_installed_accessibility_rejects_rehashed_projection_and_screenshot_mutations(self) -> None:
        request = self._installed_accessibility_request()
        report_path = self.root / "InstalledAccessibility.accessibility-report.json"
        report = load_canonical_json(report_path)
        report["selectors"][0]["required_identifiers"] = ["reconstruction.nonexistent"]
        report["selector_projection_sha256"] = canonical_sha256(
            [
                {
                    key: value
                    for key, value in item.items()
                    if key not in {"observed_identifiers", "status"}
                }
                for item in report["selectors"]
            ]
        )
        write_canonical_json(report_path, report)
        self._refresh_descriptor(request, report_path)
        with self.assertRaisesRegex(ReceiptEmissionError, "exact passed 22-vector projection"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._installed_accessibility_request()
        report_path = self.root / "InstalledAccessibility.accessibility-report.json"
        report = load_canonical_json(report_path)
        report["selectors"][0]["observed_identifiers"].pop()
        report["observed_selector_projection_sha256"] = canonical_sha256(
            [
                {
                    "observed_identifiers": item["observed_identifiers"],
                    "test_identifier": item["test_identifier"],
                    "vector_id": item["vector_id"],
                }
                for item in report["selectors"]
            ]
        )
        write_canonical_json(report_path, report)
        self._refresh_descriptor(request, report_path)
        with self.assertRaisesRegex(
            ReceiptEmissionError, "exact passed 22-vector projection"
        ):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._installed_accessibility_request()
        presentation_path = self.root / "InstalledAccessibility.presentation-manifest.json"
        presentation = load_canonical_json(presentation_path)
        presentation["screenshots"][0]["sha256"] = presentation["screenshots"][1]["sha256"]
        write_canonical_json(presentation_path, presentation)
        self._refresh_descriptor(request, presentation_path)
        report_path = self.root / "InstalledAccessibility.accessibility-report.json"
        report = load_canonical_json(report_path)
        report["presentation_manifest_sha256"] = hashlib.sha256(
            presentation_path.read_bytes()
        ).hexdigest()
        write_canonical_json(report_path, report)
        self._refresh_descriptor(request, report_path)
        with self.assertRaisesRegex(ReceiptEmissionError, "screenshot manifest differs"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._installed_accessibility_request()
        screenshot = next(
            item
            for item in request["artifacts"]
            if item["media_type"] == "image/png"
        )
        screenshot_path = self.root / screenshot["relative_path"]
        screenshot_path.write_bytes(screenshot_path.read_bytes()[:-12])
        self._refresh_descriptor(request, screenshot_path)
        with self.assertRaisesRegex(
            ReceiptEmissionError, "complete decodable PNG"
        ):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._installed_accessibility_request()
        presentation_path = self.root / "InstalledAccessibility.presentation-manifest.json"
        presentation = load_canonical_json(presentation_path)
        presentation["screenshots"].pop()
        write_canonical_json(presentation_path, presentation)
        self._refresh_descriptor(request, presentation_path)
        report_path = self.root / "InstalledAccessibility.accessibility-report.json"
        report = load_canonical_json(report_path)
        report["presentation_manifest_sha256"] = hashlib.sha256(
            presentation_path.read_bytes()
        ).hexdigest()
        write_canonical_json(report_path, report)
        self._refresh_descriptor(request, report_path)
        with self.assertRaisesRegex(ReceiptEmissionError, "exact 28 screenshots"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_install_release_semantically_binds_atomic_candidate_equality(self) -> None:
        receipt, context = emit_executor_receipt(
            self._install_release_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_install_release_rejects_rehashed_atomic_and_identity_mutations(self) -> None:
        cases = (
            (
                "legacy-schema-one",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report.update(schema_version=1),
                "another exact candidate or path",
            ),
            (
                "source-root-mode",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report["source_identity"].update(root_mode=0o10000),
                "source identity is not exact and mode-complete",
            ),
            (
                "atomic-mode",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report["atomic_replacement"].update(mode="swap-existing"),
                "atomic primitive and predecessor flag",
            ),
            (
                "same-volume",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report["staging"].update(same_volume=False),
                "staging was not fresh, same-volume",
            ),
            (
                "rollback",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report["rollback"].update(
                    attempted=True, succeeded=True
                ),
                "rollback activity after its commit boundary",
            ),
            (
                "point-of-no-return",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report.update(point_of_no_return_reached=False),
                "commit boundary and residue",
            ),
            (
                "transaction-residue",
                "InstallReleaseToApplications.operation-report.json",
                lambda report: report["transaction_residue"].update(
                    present=True,
                    path="/Applications/.MacScope.app.install-stage-residue",
                ),
                "commit boundary and residue",
            ),
            (
                "stage-identity",
                "InstallReleaseToApplications.source-equality-report.json",
                lambda report: report["stage_authority"].update(
                    release_bundle_sha256=sha("f")
                ),
                "source, stage, and destination identities",
            ),
        )
        for mutation, filename, mutate, expected in cases:
            with self.subTest(mutation=mutation):
                request = self._install_release_request()
                path = self.root / filename
                report = load_canonical_json(path)
                mutate(report)
                write_canonical_json(path, report)
                self._refresh_descriptor(request, path)
                with self.assertRaisesRegex(ReceiptEmissionError, expected):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_installed_task10_workflow_semantically_binds_complete_network_observation(self) -> None:
        receipt, context = emit_executor_receipt(
            self._installed_workflow_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_installed_task10_workflow_allows_empty_demand_launched_role_processes(self) -> None:
        receipt, context = emit_executor_receipt(
            self._installed_workflow_request(empty_process_role="ai-agent-worker"),
            artifact_root=self.root,
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_installed_task10_workflow_rejects_unproven_or_late_observer_readiness(self) -> None:
        cases = (
            (
                "workload-claim-false",
                lambda report: report["workload"].update(
                    observer_readiness_precedes_workload=False
                ),
            ),
            (
                "observer-proof-false",
                lambda report: report["observer"].update(readiness_proven=False),
            ),
            (
                "observer-not-stopped-by-auditor",
                lambda report: report["observer"].update(stopped_by_auditor=False),
            ),
            (
                "readiness-after-workload",
                lambda report: (
                    report["workload"].update(observer_ready_at_unix_ms=1_200),
                    report["observer"].update(
                        continuous_interval_ready_at_unix_ms=1_200
                    ),
                ),
            ),
            (
                "readiness-before-continuous-interval",
                lambda report: (
                    report["workload"].update(observer_ready_at_unix_ms=900),
                    report["observer"].update(
                        continuous_interval_ready_at_unix_ms=900
                    ),
                ),
            ),
            (
                "readiness-records-disagree",
                lambda report: report["observer"].update(
                    continuous_interval_ready_at_unix_ms=1_049
                ),
            ),
            (
                "noncanonical-readiness-digest",
                lambda report: report["observer"].update(
                    readiness_frame_sha256="A" * 64
                ),
            ),
        )
        for mutation, mutate in cases:
            with self.subTest(mutation=mutation):
                request = self._installed_workflow_request()
                report_path = self.root / "InstalledNetworkAcquisition.audit.json"
                report = load_canonical_json(report_path)
                mutate(report)
                write_canonical_json(report_path, report)
                self._refresh_descriptor(request, report_path)
                with self.assertRaisesRegex(
                    ReceiptEmissionError, "readiness boundary|candidate-free sampled network state"
                ):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_installed_task10_workflow_rejects_receipt_without_observation_authority(self) -> None:
        with self.assertRaisesRegex(
            ReceiptEmissionError, "predates observed-identifier attachment authority"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(matrix_schema_version=2),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_27_physical_presentation_images(self) -> None:
        with self.assertRaisesRegex(
            ReceiptEmissionError, "exact 28-image Cartesian set"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(presentation_image_count=27),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_duplicate_physical_png_content(self) -> None:
        with self.assertRaisesRegex(
            ReceiptEmissionError, "content hashes are not all distinct"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(
                    duplicate_presentation_content=True
                ),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_failed_physical_semantic_manifest(self) -> None:
        # Mutation proof: the receipt, report, and every generic descriptor hash
        # are rebuilt around this regular file.  The gate must inspect its exact
        # selector semantics rather than trusting the favorable summary records.
        with self.assertRaisesRegex(
            ReceiptEmissionError,
            "semantic manifest did not exactly execute and pass all 22 selectors",
        ):
            emit_executor_receipt(
                self._installed_workflow_request(semantic_manifest_failed=True),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_false_overlap_and_omitted_role(self) -> None:
        # These requests rebuild every generic descriptor hash after each
        # semantic mutation.  Only the gate-specific meaning can reject them.
        with self.assertRaisesRegex(
            ReceiptEmissionError, "does not contain the exact installed Task 10 workload"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(overlap=False), artifact_root=self.root
            )
        with self.assertRaisesRegex(
            ReceiptEmissionError, "omitted a mandatory app/XPC role"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(omitted_role="shell-broker"),
                artifact_root=self.root,
            )
        with self.assertRaisesRegex(
            ReceiptEmissionError, "globally unique across roles"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(duplicate_role_pid=True),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_failed_or_skipped_matrix_when_network_passes(self) -> None:
        with self.assertRaisesRegex(
            ReceiptEmissionError, "did not exactly execute and pass all 22 selectors"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(matrix_result="failed"),
                artifact_root=self.root,
            )
        with self.assertRaisesRegex(
            ReceiptEmissionError, "did not exactly execute and pass all 22 selectors"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(skipped_selector_count=1),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_tampered_or_empty_network_csv(self) -> None:
        with self.assertRaisesRegex(
            ReceiptEmissionError, "counters are not bound to the exact CSV bytes"
        ):
            emit_executor_receipt(
                self._installed_workflow_request(tamper_csv_claims=True),
                artifact_root=self.root,
            )
        with self.assertRaisesRegex(ReceiptEmissionError, "CSV is invalid.*empty"):
            emit_executor_receipt(
                self._installed_workflow_request(empty_csv=True),
                artifact_root=self.root,
            )

    def test_installed_task10_workflow_rejects_rehashed_workload_selector_projection(self) -> None:
        """Mutate only the workload digest after rebuilding generic artifacts.

        This proves the Gate F workload consumer binds the matrix producer's
        selector projection rather than merely accepting an arbitrary sha256.
        """
        request = self._installed_workflow_request()
        report_path = self.root / "InstalledNetworkAcquisition.audit.json"
        report = load_canonical_json(report_path)
        report["workload"]["selector_projection_sha256"] = sha("projection-drift")
        write_canonical_json(report_path, report)
        self._refresh_descriptor(request, report_path)
        with self.assertRaisesRegex(
            ReceiptEmissionError, "installed xcresult semantic manifest"
        ):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_stress_metadata_derives_existing_closed_authority(self) -> None:
        receipt, context = emit_executor_receipt(
            self._stress_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        expected_seeds = [
            item.seed
            for item in compile_authority_stress_plan(
                self.candidate, repetitions=1
            ).invocations
        ]
        self.assertEqual(receipt["authority"]["attempt_seeds"], expected_seeds)
        self.assertEqual(
            receipt["authority"]["seed_catalog_sha256"],
            canonical_sha256(expected_seeds),
        )

        request = self._stress_request()
        expected_count = len(request["constituents"])
        request["authority"] = {
            "expected_attempt_count": expected_count,
            "observed_attempt_count": expected_count - 1,
            "attempt_seeds": expected_seeds,
            "seed_catalog_sha256": canonical_sha256(expected_seeds),
            "failed_count": 0,
        }
        with self.assertRaisesRegex(ReceiptEmissionError, "differs from exact"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_t10c_current_source_receipt_binds_exact_physical_authority(self) -> None:
        receipt, context = emit_executor_receipt(
            self._t10c_current_source_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "failed")
        self.assertEqual(
            receipt["authority"],
            {
                "review_commit": self.candidate.source.commit,
                "review_tree": self.candidate.source.tree,
                "p0_count": 0,
                "p1_count": 2,
                "p2_count": 1,
                "p3_count": 0,
                "unresolved_blocking_count": 3,
            },
        )

    def test_t10c_current_source_cannot_emit_a_favorable_receipt_with_open_gaps(
        self,
    ) -> None:
        request = self._t10c_current_source_request()
        execution_path = self.root / "current-source-review-execution-report.json"
        write_canonical_json(
            execution_path,
            {
                "schema_version": 2,
                "qualification_run": dict(QUALIFICATION_RUN_MAPPING),
                "predecessor_observations_sha256": canonical_sha256([]),
                "started_at_unix_ms": 1_000,
                "ended_at_unix_ms": 2_000,
                "result": "passed",
                "exit_code": 0,
                "stress": None,
            },
        )
        artifact = next(
            item
            for item in request["artifacts"]
            if item["relative_path"] == execution_path.name
        )
        artifact["byte_count"] = execution_path.stat().st_size
        artifact["sha256"] = hashlib.sha256(execution_path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ReceiptEmissionError, "fail closed"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_t10c_current_source_rejects_another_or_dirty_candidate(self) -> None:
        with self.assertRaisesRegex(ReceiptEmissionError, "another candidate|dirty"):
            emit_executor_receipt(
                self._t10c_current_source_request(source_commit="f" * 40),
                artifact_root=self.root,
            )
        with self.assertRaisesRegex(ReceiptEmissionError, "another candidate|dirty"):
            emit_executor_receipt(
                self._t10c_current_source_request(
                    dirty_input_paths=["MacScope/CurrentSource01.swift"]
                ),
                artifact_root=self.root,
            )

    def test_t10c_current_source_requires_exactly_one_trailing_lf(self) -> None:
        for mutation in ("missing-lf", "extra-lf", "space-before-lf"):
            with self.subTest(mutation=mutation):
                request = self._t10c_current_source_request()
                source_path = self.root / "SOURCE_DRIFT.json"
                original = source_path.read_bytes()
                if mutation == "missing-lf":
                    source_path.write_bytes(original[:-1])
                elif mutation == "extra-lf":
                    source_path.write_bytes(original + b"\n")
                else:
                    source_path.write_bytes(original[:-1] + b" \n")
                self._rebind_t10c_source_artifact(request)
                with self.assertRaisesRegex(
                    ReceiptEmissionError,
                    "exactly one trailing LF|not canonical before its trailing LF",
                ):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_t10c_current_source_rejects_duplicate_finding_or_row_order_drift(
        self,
    ) -> None:
        for mutation in ("duplicate-finding-id", "row-order"):
            with self.subTest(mutation=mutation):
                request = self._t10c_current_source_request()
                source_path = self.root / "SOURCE_DRIFT.json"
                source = decode_canonical_bytes(source_path.read_bytes()[:-1])
                if mutation == "duplicate-finding-id":
                    source["mappings"][1]["findingID"] = source["mappings"][0][
                        "findingID"
                    ]
                else:
                    source["mappings"][0], source["mappings"][1] = (
                        source["mappings"][1],
                        source["mappings"][0],
                    )
                source_path.write_bytes(canonical_bytes(source) + b"\n")
                self._rebind_t10c_source_artifact(request)
                with self.assertRaisesRegex(
                    ReceiptEmissionError,
                    "finding ledger is not exact and ordered",
                ):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_t10c_current_source_rejects_drifted_gap_ledger(self) -> None:
        with self.assertRaisesRegex(ReceiptEmissionError, "physical current-source authority"):
            emit_executor_receipt(
                self._t10c_current_source_request(
                    review_gap_ids=[
                        "T10A-P2-006",
                        "T10A-P2-008",
                        "T10A-P3-005",
                    ]
                ),
                artifact_root=self.root,
            )

    def test_t10c_current_source_rejects_uncaught_mutation(self) -> None:
        with self.assertRaisesRegex(ReceiptEmissionError, "uncaught mutation"):
            emit_executor_receipt(
                self._t10c_current_source_request(uncaught_mutation=24),
                artifact_root=self.root,
            )

    def test_t10c_current_source_uses_framed_bundle_manifest_not_json_digest(self) -> None:
        request = self._t10c_current_source_request()
        ledger = {}
        for line in (self.root / "bundle.sha256").read_text(encoding="utf-8").splitlines():
            digest, name = line.split("  ", 1)
            ledger[name] = digest
        wrong_json_digest = canonical_sha256(ledger)
        expected_framed_digest = self._t10c_manifest_sha256(ledger)
        self.assertNotEqual(wrong_json_digest, expected_framed_digest)
        request = self._t10c_current_source_request(
            bundle_manifest_sha256=wrong_json_digest
        )
        with self.assertRaisesRegex(ReceiptEmissionError, "physical current-source authority"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_t10c_current_source_rejects_review_authority_drift(self) -> None:
        with self.assertRaisesRegex(ReceiptEmissionError, "physical current-source authority"):
            emit_executor_receipt(
                self._t10c_current_source_request(
                    review_authority={
                        "review_commit": self.candidate.source.commit,
                        "review_tree": self.candidate.source.tree,
                        "p0_count": 0,
                        "p1_count": 2,
                        "p2_count": 1,
                        "p3_count": 1,
                        "unresolved_blocking_count": 3,
                    }
                ),
                artifact_root=self.root,
            )

    def test_independent_review_derives_authority_from_exact_four_physical_lenses(
        self,
    ) -> None:
        receipt, context = emit_executor_receipt(
            self._independent_review_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")
        self.assertEqual(
            [item["selector_id"] for item in receipt["constituents"]],
            list(INDEPENDENT_REVIEW_COMMAND_LENSES),
        )

    def test_executor_rejects_prerequisite_from_another_qualification_run(self) -> None:
        request = self._independent_review_request()
        request["command_authority"]["prerequisite_receipts"][0][
            "qualification_run_nonce"
        ] = sha("8")
        with self.assertRaisesRegex(
            ReceiptEmissionError,
            "prerequisite belongs to another coordinator-issued qualification run",
        ):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_independent_review_treats_reviewer_executor_labels_as_nonauthoritative(self) -> None:
        request = self._independent_review_request()
        first_artifact = request["artifacts"][0]
        second_artifact = request["artifacts"][1]
        first_path = self.root / first_artifact["relative_path"]
        second_path = self.root / second_artifact["relative_path"]
        first_receipt = load_canonical_json(first_path)
        second_receipt = load_canonical_json(second_path)
        duplicate_identity = second_receipt["executor"]["executor_id"]
        first_receipt["executor"]["executor_id"] = duplicate_identity
        first_receipt["canonical_sha256"] = canonical_sha256(
            {
                key: value
                for key, value in first_receipt.items()
                if key != "canonical_sha256"
            }
        )
        write_canonical_json(first_path, first_receipt)
        self._refresh_descriptor(request, first_path)
        for prerequisite in request["command_authority"]["prerequisite_receipts"]:
            if prerequisite["command_id"] == first_receipt["command_id"]:
                prerequisite["canonical_sha256"] = first_receipt["canonical_sha256"]
        execution_artifact = next(
            item
            for item in request["artifacts"]
            if item["artifact_id"] == request["execution_report_artifact_id"]
        )
        execution_path = self.root / execution_artifact["relative_path"]
        execution_report = load_canonical_json(execution_path)
        execution_report["predecessor_observations_sha256"] = canonical_sha256(
            request["command_authority"]["prerequisite_receipts"]
        )
        write_canonical_json(execution_path, execution_report)
        self._refresh_descriptor(request, execution_path)
        receipt, context = emit_executor_receipt(request, artifact_root=self.root)
        self.assertEqual(validate_receipt(receipt, context=context), ())

    def test_independent_review_rejects_duplicate_lens_approval_receipt_identity(self) -> None:
        request = self._independent_review_request()
        first_artifact = request["artifacts"][0]
        second_artifact = request["artifacts"][1]
        first_path = self.root / first_artifact["relative_path"]
        second_path = self.root / second_artifact["relative_path"]
        first_receipt = load_canonical_json(first_path)
        second_receipt = load_canonical_json(second_path)
        first_receipt["receipt_id"] = second_receipt["receipt_id"]
        first_receipt["canonical_sha256"] = canonical_sha256(
            {
                key: value
                for key, value in first_receipt.items()
                if key != "canonical_sha256"
            }
        )
        write_canonical_json(first_path, first_receipt)
        self._refresh_descriptor(request, first_path)
        for prerequisite in request["command_authority"]["prerequisite_receipts"]:
            if prerequisite["command_id"] == first_receipt["command_id"]:
                prerequisite["receipt_id"] = first_receipt["receipt_id"]
                prerequisite["canonical_sha256"] = first_receipt["canonical_sha256"]
        execution_artifact = next(
            item
            for item in request["artifacts"]
            if item["artifact_id"] == request["execution_report_artifact_id"]
        )
        execution_path = self.root / execution_artifact["relative_path"]
        execution_report = load_canonical_json(execution_path)
        execution_report["predecessor_observations_sha256"] = canonical_sha256(
            request["command_authority"]["prerequisite_receipts"]
        )
        write_canonical_json(execution_path, execution_report)
        self._refresh_descriptor(request, execution_path)
        with self.assertRaisesRegex(
            ReceiptEmissionError,
            "four separately sealed exact-candidate lens approval artifacts",
        ):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_independent_review_rejects_rehashed_forged_candidate_identity(self) -> None:
        request = self._independent_review_request()
        first_artifact = request["artifacts"][0]
        first_path = self.root / first_artifact["relative_path"]
        first_receipt = load_canonical_json(first_path)
        forged_candidate = decode_canonical_bytes(
            canonical_bytes(first_receipt["candidate_identity"])
        )
        forged_candidate["source"]["tree"] = "f" * 40
        first_receipt["candidate_identity"] = forged_candidate
        first_receipt["canonical_sha256"] = canonical_sha256(
            {
                key: value
                for key, value in first_receipt.items()
                if key != "canonical_sha256"
            }
        )
        write_canonical_json(first_path, first_receipt)
        self._refresh_descriptor(request, first_path)
        for prerequisite in request["command_authority"]["prerequisite_receipts"]:
            if prerequisite["command_id"] == first_receipt["command_id"]:
                prerequisite["canonical_sha256"] = first_receipt["canonical_sha256"]
        execution_artifact = next(
            item
            for item in request["artifacts"]
            if item["artifact_id"] == request["execution_report_artifact_id"]
        )
        execution_path = self.root / execution_artifact["relative_path"]
        execution_report = load_canonical_json(execution_path)
        execution_report["predecessor_observations_sha256"] = canonical_sha256(
            request["command_authority"]["prerequisite_receipts"]
        )
        write_canonical_json(execution_path, execution_report)
        self._refresh_descriptor(request, execution_path)
        with self.assertRaisesRegex(
            ReceiptEmissionError,
            "exact candidate authority",
        ):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_independent_review_mutation_protections_are_live(self) -> None:
        """Aggregate mutations rehash physical receipts; authority must go RED."""
        cases = (
            ("omitted", "physical artifact outputs|four receipt constituents"),
            ("substituted", "exact candidate authority"),
            ("wrong-lens", "exact candidate authority"),
        )
        for mutation, expected in cases:
            with self.subTest(mutation=mutation):
                request = self._independent_review_request()
                first = request["artifacts"][0]
                path = self.root / first["relative_path"]
                if mutation == "omitted":
                    request["artifacts"].pop(0)
                    request["constituents"].pop(0)
                else:
                    receipt = load_canonical_json(path)
                    receipt["command_id"] = (
                        list(INDEPENDENT_REVIEW_COMMAND_LENSES)[1]
                        if mutation == "wrong-lens" else "review.independent.substitute"
                    )
                    receipt["canonical_sha256"] = canonical_sha256(
                        {key: value for key, value in receipt.items() if key != "canonical_sha256"}
                    )
                    write_canonical_json(path, receipt)
                    self._refresh_descriptor(request, path)
                with self.assertRaisesRegex(ReceiptEmissionError, expected):
                    emit_executor_receipt(request, artifact_root=self.root)

    def test_independent_review_lens_rejects_packed_four_report_run(self) -> None:
        command_id = next(iter(INDEPENDENT_REVIEW_COMMAND_LENSES))
        request = self._independent_review_lens_request(command_id)
        request["constituents"] *= 4
        with self.assertRaisesRegex(ReceiptEmissionError, "exactly one frozen constituent"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_deterministic_evidence_derives_pass_from_physical_comparison(self) -> None:
        receipt, context = emit_executor_receipt(
            self._deterministic_evidence_request(), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())
        self.assertEqual(receipt["evidence_status"], "passed")

    def test_deterministic_semantic_failure_cannot_be_rehashed_into_a_pass(self) -> None:
        request = self._deterministic_evidence_request()
        path = self.root / "DeterministicEvidence.execution-report.json"
        report = load_canonical_json(path)
        report["result"] = "failed"
        report["exit_code"] = 1
        write_canonical_json(path, report)
        self._refresh_descriptor(request, path)
        with self.assertRaisesRegex(ReceiptEmissionError, "requires a passed terminal"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_deterministic_second_process_drift_cannot_be_rehashed_into_a_pass(self) -> None:
        request = self._deterministic_evidence_request()
        path = self.root / "fresh-process-2-corpus-manifest.json"
        write_canonical_json(path, {"artifact": "drifted-corpus", "schema_version": 1})
        self._refresh_descriptor(request, path)
        with self.assertRaisesRegex(
            ReceiptEmissionError, "either fresh process's exact physical artifacts"
        ):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_new_execution_command_without_semantic_validator_fails_closed(self) -> None:
        unhandled = replace(
            self.templates["source.hosted-governance"],
            command_id="source.unhandled-producer",
        )
        with (
            mock.patch.object(
                gate_validator_module,
                "command_templates",
                return_value=(*command_templates(), unhandled),
            ),
            self.assertRaisesRegex(
                GateSpecificArtifactError, "semantic-validator backlog differs"
            ),
        ):
            validate_gate_specific_artifacts(
                receipt_type=ReceiptType.TEST_RESULT,
                candidate=self.candidate,
                command_id="source.unhandled-producer",
                artifacts=(),
                artifact_root=self.root,
                execution_report_artifact_id="execution",
                result=EvidenceStatus.PASSED,
                stress=None,
                constituents=(),
                authority={},
                generated_artifacts=(),
                generated_logs=(),
                command_plan_sha256=sha("a"),
                command_record_sha256=sha("b"),
                prerequisite_receipts=(),
            )

    def test_merge_authority_receipts_derive_from_physical_executor_artifacts(self) -> None:
        prospective_receipt, prospective_context = emit_executor_receipt(
            self._merge_authority_request(postmerge=False), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(prospective_receipt, context=prospective_context), ())
        self.assertEqual(prospective_receipt["authority"]["governed_file_count"], 1)
        self.assertEqual(prospective_receipt["authority"]["successful_check_count"], 2)

        postmerge_receipt, postmerge_context = emit_executor_receipt(
            self._merge_authority_request(postmerge=True), artifact_root=self.root
        )
        self.assertEqual(validate_receipt(postmerge_receipt, context=postmerge_context), ())
        self.assertEqual(postmerge_receipt["authority"]["workflow_conclusion"], "success")
        self.assertEqual(
            postmerge_receipt["authority"]["workflow_commit"],
            postmerge_context.expected_candidate.accepted_postmerge_commit,
        )

    def test_prospective_receipt_rejects_rehashed_but_unobserved_governed_diff(self) -> None:
        request = self._merge_authority_request(postmerge=False)
        path = self.root / "prospective-merge-governed-diff.json"
        governed_diff = load_canonical_json(path)
        governed_diff["files"][0]["head_sha256"] = sha("9")
        write_canonical_json(path, governed_diff)
        artifact = next(
            item for item in request["artifacts"] if item["relative_path"] == path.name
        )
        artifact["byte_count"] = path.stat().st_size
        artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ReceiptEmissionError, "physical diff"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_postmerge_receipt_rejects_rehashed_workflow_for_wrong_commit(self) -> None:
        request = self._merge_authority_request(postmerge=True)
        workflow_path = self.root / "postmerge-workflow.json"
        workflow = load_canonical_json(workflow_path)
        workflow["commit"] = "a" * 40
        write_canonical_json(workflow_path, workflow)
        observation_path = self.root / "postmerge-observation.json"
        observation = load_canonical_json(observation_path)
        observation["workflow_observation_sha256"] = canonical_sha256(workflow)
        write_canonical_json(observation_path, observation)
        for path in (workflow_path, observation_path):
            artifact = next(
                item for item in request["artifacts"] if item["relative_path"] == path.name
            )
            artifact["byte_count"] = path.stat().st_size
            artifact["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ReceiptEmissionError, "another commit"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_stress_rejects_a_mutated_seed_with_unchanged_constituents_and_counts(self) -> None:
        request = self._stress_request()
        report_path = self.root / "stress-report.json"
        report_document = load_canonical_json(report_path)
        report_document["stress"]["attempt_seeds"][0] += 1
        write_canonical_json(report_path, report_document)
        for index, artifact in enumerate(request["artifacts"]):
            if artifact["artifact_id"] == "artifact-stress-report":
                request["artifacts"][index] = self._descriptor(
                    report_path,
                    candidate_digest=candidate_identity_sha256(self.candidate),
                    layer=EvidenceLayer.STRESS_RECOVERY,
                    receipt_id="receipt-stress-recovery",
                    command_id="stress.reconstruction-authority-races",
                    artifact_id="artifact-stress-report",
                    kind=ArtifactKind.STRESS_REPORT,
                    command_output="artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                    media_type="application/json",
                )
                break

        with self.assertRaisesRegex(ReceiptEmissionError, "compiled stress plan"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_stress_rejects_preparation_receipt_and_coretests_provenance_drift(self) -> None:
        request = self._stress_request()
        path = self.root / "preparation-receipt.json"
        preparation = load_canonical_json(path)
        preparation["source"]["commit"] = sha("f")[:40]
        write_canonical_json(path, preparation)
        for index, artifact in enumerate(request["artifacts"]):
            if artifact["artifact_id"] == "artifact-stress-preparation-receipt":
                request["artifacts"][index] = self._descriptor(
                    path,
                    candidate_digest=candidate_identity_sha256(self.candidate),
                    layer=EvidenceLayer.STRESS_RECOVERY,
                    receipt_id="receipt-stress-recovery",
                    command_id="stress.reconstruction-authority-races",
                    artifact_id="artifact-stress-preparation-receipt",
                    kind=ArtifactKind.JSON,
                    command_output="artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT",
                    media_type="application/json",
                )
                break
        with self.assertRaisesRegex(ReceiptEmissionError, "another candidate source"):
            emit_executor_receipt(request, artifact_root=self.root)

        request = self._stress_request()
        preparation = load_canonical_json(path)
        preparation["artifacts"]["core_tests"]["executable_sha256"] = "not-a-digest"
        write_canonical_json(path, preparation)
        for index, artifact in enumerate(request["artifacts"]):
            if artifact["artifact_id"] == "artifact-stress-preparation-receipt":
                request["artifacts"][index] = self._descriptor(
                    path,
                    candidate_digest=candidate_identity_sha256(self.candidate),
                    layer=EvidenceLayer.STRESS_RECOVERY,
                    receipt_id="receipt-stress-recovery",
                    command_id="stress.reconstruction-authority-races",
                    artifact_id="artifact-stress-preparation-receipt",
                    kind=ArtifactKind.JSON,
                    command_output="artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_PREPARATION_RECEIPT",
                    media_type="application/json",
                )
                break
        with self.assertRaisesRegex(ReceiptEmissionError, "core_tests.executable_sha256"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_failed_stress_derives_exact_physical_failure_count_and_rejects_report_drift(
        self,
    ) -> None:
        request = self._failed_stress_request()
        receipt, context = emit_executor_receipt(request, artifact_root=self.root)

        self.assertEqual(receipt["evidence_status"], "failed")
        self.assertEqual(receipt["authority"]["failed_count"], 1)
        self.assertLess(
            receipt["authority"]["observed_attempt_count"],
            receipt["authority"]["expected_attempt_count"],
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())

        request = self._failed_stress_request()
        report_path = self.root / "stress-report.json"
        report = load_canonical_json(report_path)
        report["stress"]["failed_count"] = 0
        write_canonical_json(report_path, report)
        for index, artifact in enumerate(request["artifacts"]):
            if artifact["artifact_id"] != "artifact-stress-report":
                continue
            request["artifacts"][index] = self._descriptor(
                report_path,
                candidate_digest=candidate_identity_sha256(self.candidate),
                layer=EvidenceLayer.STRESS_RECOVERY,
                receipt_id="receipt-stress-recovery",
                command_id="stress.reconstruction-authority-races",
                artifact_id="artifact-stress-report",
                kind=ArtifactKind.STRESS_REPORT,
                command_output="artifact:stdout-path:MACSCOPE_AUTHORITY_STRESS_REPORT",
                media_type="application/json",
            )
            break
        with self.assertRaisesRegex(ReceiptEmissionError, "physical stress attempts"):
            emit_executor_receipt(request, artifact_root=self.root)

    def test_request_only_cli_cannot_manufacture_capture_admission(self) -> None:
        request_path = self.root / "request.json"
        output_path = self.root / "receipt.json"
        write_canonical_json(request_path, self._signed_xpc_request())
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            result = main(
                [
                    "--request",
                    str(request_path),
                    "--artifact-root",
                    str(self.root),
                    "--output",
                    str(output_path),
                    "--qualification-run-id",
                    QUALIFICATION_RUN.run_id,
                    "--qualification-run-nonce",
                    QUALIFICATION_RUN.nonce,
                ]
            )
        self.assertNotEqual(result, 0)
        self.assertFalse(output_path.exists())
        self.assertIn("requires typed independent capture or external admission", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
