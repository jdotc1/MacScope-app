from __future__ import annotations

import tempfile
import unittest
from contextlib import contextmanager
from dataclasses import replace
from hashlib import sha256
from pathlib import Path
from unittest import mock

from Scripts.reconstruction_gate_f import evidence_model
from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256
from Scripts.reconstruction_gate_f.command_catalog import (
    INDEPENDENT_REVIEW_COMMAND_LENSES,
)
from Scripts.reconstruction_gate_f.evidence_model import (
    DEFAULT_EVIDENCE_EDGES,
    EVIDENCE_PARTIAL_ORDER_SCHEMA_VERSION,
    EvidenceClaim,
    EvidenceReceiptInput,
    EvidenceReceiptOutput,
    REQUIRED_RECEIPT_TYPES_BY_LAYER,
    compile_evidence_claims as _compile_evidence_claims,
    compile_evidence_partial_order,
    default_evidence_partial_order,
    evidence_partial_order_sha256,
    evidence_partial_order_to_mapping,
)
from Scripts.reconstruction_gate_f.receipt_schema import (
    ARTIFACT_SCHEMA_VERSION,
    RECEIPT_SCHEMA_VERSION,
    REQUIRED_ARTIFACT_KINDS,
    seal_receipt,
)
from Scripts.reconstruction_gate_f.receipt_validator import (
    ArtifactExpectation,
    CommandAuthorityExpectation,
    CommandPrerequisiteExpectation,
    ExecutionIntervalExpectation,
    EXTERNAL_AUTHORITY_COMMANDS,
    QualificationRunAuthority,
    ReceiptValidationContext,
    _validate_physical_receipt,
    validate_receipt,
)
from Scripts.reconstruction_gate_f.schema import (
    ArtifactKind,
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceLayer,
    EvidenceStatus,
    ExecutorArchitecture,
    ExecutorPlatform,
    QualificationPhase,
    ReceiptType,
    candidate_identity_sha256,
    candidate_to_mapping,
)
from Scripts.reconstruction_gate_f.tests import sha
from Scripts.reconstruction_gate_f.tests.test_prerequisite_dag import (
    candidate_for_subject,
)

QUALIFICATION_RUN = QualificationRunAuthority(
    run_id="gate-f-qualification-20260828",
    nonce=sha("9"),
)


@contextmanager
def historical_physical_fixture_validation():
    """Isolate physical/order fixtures, never claim public external admission.

    These historical synthetic receipts deliberately have no retained external
    authority. Only this compiler consumer uses the existing private physical
    parser; the public validator and capture-backed admission stay unchanged.
    """
    def validate_fixture(value, *, context, path="$"):
        if (
            isinstance(context, HistoricalPhysicalReceiptContext)
            and context.capture_admission is None
            and context.external_admission is None
            and context.expected_command_id in EXTERNAL_AUTHORITY_COMMANDS
            and value.get("command_id") == context.expected_command_id
        ):
            return _validate_physical_receipt(value, context=context, path=path)
        return validate_receipt(value, context=context, path=path)

    with mock.patch.object(evidence_model, "validate_receipt", validate_fixture):
        yield


def compile_physical_fixture_claims(*args, **kwargs):
    kwargs["expected_qualification_run"] = QUALIFICATION_RUN
    with historical_physical_fixture_validation():
        return _compile_evidence_claims(*args, **kwargs)


compile_evidence_claims = compile_physical_fixture_claims


class HistoricalPhysicalReceiptContext(ReceiptValidationContext):
    """Marker for synthetic physical/parser fixtures, not production authority."""


EXPECTED_RECEIPT_TYPE_BY_LAYER = {
    EvidenceLayer.SOURCE_GOVERNANCE: ReceiptType.ARTIFACT_MANIFEST,
    EvidenceLayer.HOSTED_PURE: ReceiptType.TEST_RESULT,
    EvidenceLayer.NATIVE_NORMAL: ReceiptType.TEST_RESULT,
    EvidenceLayer.NATIVE_ASAN: ReceiptType.NATIVE_SANITIZER,
    EvidenceLayer.NATIVE_UBSAN: ReceiptType.NATIVE_SANITIZER,
    EvidenceLayer.XCODE_FOCUSED: ReceiptType.TEST_RESULT,
    EvidenceLayer.XCODE_FULL_CORETESTS: ReceiptType.TEST_RESULT,
    EvidenceLayer.SIGNED_XPC: ReceiptType.SIGNED_XPC,
    EvidenceLayer.RELEASE_BUILD: ReceiptType.RELEASE_BUILD,
    EvidenceLayer.STRICT_SIGNING: ReceiptType.STRICT_SIGNING,
    EvidenceLayer.INSTALLED_SOURCE_EQUALITY: ReceiptType.INSTALLED_SOURCE_EQUALITY,
    EvidenceLayer.INSTALLED_LAUNCH_LOG: ReceiptType.INSTALLED_LAUNCH_LOG,
    EvidenceLayer.INSTALLED_WORKFLOW: ReceiptType.INSTALLED_WORKFLOW,
    EvidenceLayer.INSTALLED_ACCESSIBILITY: ReceiptType.INSTALLED_ACCESSIBILITY,
    EvidenceLayer.STRESS_RECOVERY: ReceiptType.STRESS_RECOVERY,
    EvidenceLayer.INDEPENDENT_REVIEW: ReceiptType.INDEPENDENT_REVIEW,
    EvidenceLayer.PROSPECTIVE_MERGE_TREE: ReceiptType.PROSPECTIVE_MERGE_TREE,
    EvidenceLayer.POST_MERGE: ReceiptType.POST_MERGE,
}

CONSTITUENT_RECEIPT_TYPES = frozenset(
    {
        ReceiptType.TEST_RESULT,
        ReceiptType.NATIVE_SANITIZER,
        ReceiptType.SIGNED_XPC,
        ReceiptType.INSTALLED_WORKFLOW,
        ReceiptType.INSTALLED_ACCESSIBILITY,
        ReceiptType.STRESS_RECOVERY,
        ReceiptType.INDEPENDENT_REVIEW,
    }
)


def fixture_command_plan_sha256(candidate: CandidateIdentity) -> str:
    return sha("2") if candidate.subject_kind is CandidateSubjectKind.POST_MERGE else sha("1")


def fixture_command_record_sha256(
    candidate: CandidateIdentity,
    command_id: str,
) -> str:
    return canonical_sha256(
        {
            "candidate_identity_sha256": candidate_identity_sha256(candidate),
            "command_id": command_id,
        }
    )


class PhysicalReceiptFactory:
    """Create exact Lane A receipts over descriptor-verified temp artifacts."""

    def __init__(self, root: Path) -> None:
        self.root = root.resolve(strict=True)
        self.counter = 0

    def make(
        self,
        candidate: CandidateIdentity,
        layer: EvidenceLayer,
        *,
        receipt_id: str | None = None,
        requirement_id: str | None = None,
        command_id: str | None = None,
        artifact_id: str | None = None,
        receipt_type: ReceiptType | None = None,
        status: EvidenceStatus = EvidenceStatus.PASSED,
        scenario_id: str | None = None,
        command_plan_sha256: str | None = None,
        command_record_sha256: str | None = None,
        command_authority: CommandAuthorityExpectation | None = None,
        qualified_premerge_authority_sha256: str | None = None,
        selector_ids: tuple[str, ...] | None = None,
        service_identity_id: str | None = None,
        started_at_unix_ms: int | None = None,
        ended_at_unix_ms: int | None = None,
        runtime_resolution: dict[str, object] | None = None,
    ) -> EvidenceReceiptInput:
        self.counter += 1
        token = self.counter
        started_at_unix_ms = (
            token * 1_000
            if started_at_unix_ms is None
            else started_at_unix_ms
        )
        ended_at_unix_ms = (
            started_at_unix_ms + 500
            if ended_at_unix_ms is None
            else ended_at_unix_ms
        )
        receipt_id = receipt_id or f"receipt-{layer.value}-{token}"
        requirement_id = requirement_id or f"requirement-{layer.value}-{token}"
        command_id = command_id or f"command-{layer.value}-{token}"
        scenario_id = scenario_id or f"scenario-{layer.value}-{token}"
        command_plan_sha256 = command_plan_sha256 or fixture_command_plan_sha256(
            candidate
        )
        command_record_sha256 = (
            command_record_sha256
            or fixture_command_record_sha256(candidate, command_id)
        )
        receipt_type = receipt_type or (
            EXPECTED_RECEIPT_TYPE_BY_LAYER[layer]
            if status is EvidenceStatus.PASSED
            else ReceiptType.COMMAND_EXECUTION
        )
        root_id = f"root-{token}"
        candidate_digest = candidate_identity_sha256(candidate)
        macos = layer not in {
            EvidenceLayer.SOURCE_GOVERNANCE,
            EvidenceLayer.HOSTED_PURE,
        }
        command_authority = command_authority or CommandAuthorityExpectation(
            host=("macos-arm64-xcode27" if macos else "host-independent"),
            execution_mode="vector-only",
            argv_sha256=sha("3"),
            working_directory_sha256=sha("4"),
            environment_sha256=sha("5"),
            generated_artifacts=(),
            generated_logs=(),
            prerequisite_receipts=(),
        )
        expected_artifacts: list[ArtifactExpectation] = []
        artifacts: list[dict[str, object]] = []
        required_kinds = (
            frozenset({ArtifactKind.TEST_RESULTS})
            if command_id == "reconstruction.deterministic-evidence"
            else REQUIRED_ARTIFACT_KINDS[layer]
        )
        kinds = (
            tuple(sorted(required_kinds, key=lambda item: item.value))
            if status is EvidenceStatus.PASSED
            else ()
        )
        output_markers = (
            *(f"artifact:{item}" for item in command_authority.generated_artifacts),
            *(f"log:{item}" for item in command_authority.generated_logs),
            *(
                ()
                if receipt_type is ReceiptType.INDEPENDENT_REVIEW
                else tuple(f"semantic:{kind.value}" for kind in kinds)
            ),
        )
        for index, command_output in enumerate(output_markers):
            if receipt_type is ReceiptType.INDEPENDENT_REVIEW:
                semantic_kind = (
                    ArtifactKind.JSON
                    if command_output.endswith("execution-report.json")
                    else ArtifactKind.REVIEW_REPORT
                )
            else:
                semantic_kind = next(
                    (
                        kind
                        for kind in kinds
                        if command_output == f"semantic:{kind.value}"
                    ),
                    kinds[0] if kinds else ArtifactKind.JSON,
                )
            current_artifact_id = (
                artifact_id
                if artifact_id is not None and index == 0
                else f"{artifact_id}-{index}"
                if artifact_id is not None
                else f"artifact-{layer.value}-{token}-{index}"
            )
            relative_path = f"payload-{token}-{index}.bin"
            payload = f"{receipt_id}:{command_output}:{token}\n".encode("utf-8")
            (self.root / relative_path).write_bytes(payload)
            digest = sha256(payload).hexdigest()
            artifacts.append(
                {
                    "schema_version": ARTIFACT_SCHEMA_VERSION,
                    "artifact_id": current_artifact_id,
                    "candidate_identity_sha256": candidate_digest,
                    "evidence_layer": layer.value,
                    "root_id": root_id,
                    "relative_path": relative_path,
                    "kind": semantic_kind.value,
                    "media_type": "application/octet-stream",
                    "byte_count": len(payload),
                    "sha256": digest,
                    "producer_receipt_id": receipt_id,
                    "command_id": command_id,
                    "command_output": command_output,
                }
            )
            expected_artifacts.append(
                ArtifactExpectation(
                    artifact_id=current_artifact_id,
                    relative_path=relative_path,
                    kind=semantic_kind,
                    media_type="application/octet-stream",
                    command_output=command_output,
                )
            )

        phase = (
            QualificationPhase.POSTMERGE
            if layer is EvidenceLayer.POST_MERGE
            else QualificationPhase.PREMERGE
        )
        selected_selector_ids = (
            selector_ids
            if selector_ids is not None
            else (f"selector-{layer.value}-{token}",)
        )
        def constituent_artifact_ids(selector_id: str) -> list[object]:
            if receipt_type is not ReceiptType.INDEPENDENT_REVIEW:
                return [artifact["artifact_id"] for artifact in artifacts]
            lens_id = (
                INDEPENDENT_REVIEW_COMMAND_LENSES.get(command_id)
                if command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
                else INDEPENDENT_REVIEW_COMMAND_LENSES.get(selector_id)
            )
            if lens_id is None:
                return []
            suffix = (
                f"{lens_id}-review-report.json"
                if command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
                else f"{lens_id}-review-receipt.json"
            )
            return [
                artifact["artifact_id"]
                for artifact in artifacts
                if str(artifact["command_output"]).endswith(suffix)
            ]

        constituents = (
            [
                {
                    "selector_id": selector_id,
                    "status": "passed",
                    "evidence_layer": layer.value,
                    "candidate_identity_sha256": candidate_digest,
                    "artifact_ids": constituent_artifact_ids(selector_id),
                }
                for selector_id in selected_selector_ids
            ]
            if status is EvidenceStatus.PASSED
            and receipt_type in CONSTITUENT_RECEIPT_TYPES
            else []
        )
        authority: dict[str, object]
        if receipt_type is ReceiptType.COMMAND_EXECUTION:
            authority = {
                "run_id": f"run-{token}",
                "argv_sha256": sha(f"{token:x}"[-1]),
                "exit_code": 0 if status is EvidenceStatus.PASSED else 1,
            }
        elif receipt_type is ReceiptType.ARTIFACT_MANIFEST:
            authority = {
                "artifact_count": len(artifacts),
                "artifact_manifest_sha256": canonical_sha256(
                    sorted(artifacts, key=lambda item: str(item["artifact_id"]))
                ),
            }
        elif receipt_type is ReceiptType.TEST_RESULT:
            authority = {
                "selector_catalog_sha256": candidate.selector_catalog_sha256,
                "expected_selector_count": len(constituents),
                "executed_selector_count": len(constituents),
                "passed_selector_count": len(constituents),
                "failed_selector_count": 0,
                "skipped_selector_count": 0,
            }
        elif receipt_type is ReceiptType.NATIVE_SANITIZER:
            authority = {
                "sanitizer": (
                    "address"
                    if layer is EvidenceLayer.NATIVE_ASAN
                    else "undefined"
                ),
                "test_count": len(constituents),
                "failed_count": 0,
            }
        elif receipt_type is ReceiptType.SIGNED_XPC:
            service = next(
                (
                    item
                    for item in candidate.application.qualification_executables
                    if service_identity_id is None
                    or item.identity_id == service_identity_id
                ),
                None,
            )
            if service is None:
                raise AssertionError(
                    f"candidate lacks qualification executable {service_identity_id!r}"
                )
            authority = {
                "service_identity_id": service.identity_id,
                "service_bundle_id": service.bundle_identifier,
                "service_executable_sha256": service.sha256,
                "selector_count": len(constituents),
                "failed_count": 0,
                "failure_stage": None,
                "failure_reason": None,
            }
        elif receipt_type is ReceiptType.RELEASE_BUILD:
            authority = {
                "bundle_sha256": candidate.application.bundle_sha256,
                "closed_tree_sha256": candidate.application.closed_tree_sha256,
                "executable_sha256": candidate.application.executable_sha256,
            }
        elif receipt_type is ReceiptType.STRICT_SIGNING:
            authority = {
                "signing_certificate_sha256": candidate.application.signing_certificate_sha256,
                "signing_subject_sha256": candidate.application.signing_subject_sha256,
                "team_identifier": candidate.application.team_identifier,
                "entitlements_sha256": candidate.application.entitlements_sha256,
                "designated_requirement_sha256": candidate.application.designated_requirement_sha256,
                "hardened_runtime": candidate.application.hardened_runtime,
            }
        elif receipt_type is ReceiptType.INSTALLED_SOURCE_EQUALITY:
            authority = {
                "release_bundle_sha256": candidate.application.bundle_sha256,
                "release_closed_tree_sha256": candidate.application.closed_tree_sha256,
                "release_root_mode": candidate.application.root_mode,
                "release_executable_sha256": candidate.application.executable_sha256,
                "installed_bundle_sha256": candidate.application.bundle_sha256,
                "installed_closed_tree_sha256": candidate.application.closed_tree_sha256,
                "installed_root_mode": candidate.application.root_mode,
                "installed_executable_sha256": candidate.application.executable_sha256,
            }
        elif receipt_type is ReceiptType.INSTALLED_LAUNCH_LOG:
            authority = {
                "app_bundle_id": candidate.application.bundle_identifier,
                "app_executable_sha256": candidate.application.executable_sha256,
                "launch_exit_code": 0,
                "launch_log_sha256": sha(f"{token:x}"[-1]),
            }
        elif receipt_type in {
            ReceiptType.INSTALLED_WORKFLOW,
            ReceiptType.INSTALLED_ACCESSIBILITY,
        }:
            authority = {
                "app_bundle_id": candidate.application.bundle_identifier,
                "app_executable_sha256": candidate.application.executable_sha256,
                "selector_count": len(constituents),
                "failed_count": 0,
                "skipped_count": 0,
            }
        elif receipt_type is ReceiptType.STRESS_RECOVERY:
            seeds = [token * 1_000 + index for index in range(len(constituents))]
            authority = {
                "expected_attempt_count": len(seeds),
                "observed_attempt_count": len(constituents),
                "attempt_seeds": seeds,
                "seed_catalog_sha256": canonical_sha256(seeds),
                "failed_count": 0,
            }
        elif receipt_type is ReceiptType.INDEPENDENT_REVIEW:
            authority = {
                "review_commit": candidate.source.commit,
                "review_tree": candidate.source.tree,
                "p0_count": 0,
                "p1_count": 0,
                "p2_count": 0,
                "p3_count": 0,
                "unresolved_blocking_count": 0,
            }
        elif receipt_type is ReceiptType.PROSPECTIVE_MERGE_TREE:
            authority = {
                "repository_id": "jdotc1/MacScope-app",
                "pull_request_number": 233,
                "base_ref": "main",
                "base_commit": candidate.source.base_commit,
                "base_tree": candidate.source.base_tree,
                "head_ref": candidate.source.branch_label,
                "head_commit": candidate.source.commit,
                "head_tree": candidate.source.tree,
                "merge_commit": candidate.prospective_merge_commit,
                "merge_tree": candidate.prospective_merge_tree,
                "parent_commits": [
                    candidate.source.base_commit,
                    candidate.source.commit,
                ],
                "mergeable": True,
                "merge_state": "clean",
                "review_decision": "approved",
                "approval_count": 1,
                "reviews_sha256": sha("1"),
                "required_check_count": 2,
                "successful_check_count": 2,
                "checks_sha256": sha("2"),
                "governed_diff_sha256": sha("3"),
                "governed_file_count": 1,
                "observation_sha256": sha("4"),
            }
        elif receipt_type is ReceiptType.POST_MERGE:
            authority = {
                "prospective_merge_commit": candidate.prospective_merge_commit,
                "prospective_merge_tree": candidate.prospective_merge_tree,
                "postmerge_commit": candidate.accepted_postmerge_commit,
                "postmerge_tree": candidate.accepted_postmerge_tree,
                "workflow_run_id": f"workflow-{token}",
                "workflow_commit": candidate.accepted_postmerge_commit,
                "workflow_tree": candidate.accepted_postmerge_tree,
                "workflow_name": "CI",
                "workflow_job_name": "Build + CoreTests (Xcode 27, arm64)",
                "workflow_event": "push",
                "workflow_status": "completed",
                "workflow_conclusion": "success",
                "workflow_run_attempt": 1,
                "workflow_observation_sha256": sha("5"),
                "repository_id": "jdotc1/MacScope-app",
                "pull_request_number": 233,
                "base_ref": "main",
                "head_ref": candidate.source.branch_label,
                "observation_sha256": sha("6"),
            }
        else:
            raise AssertionError(f"unsupported physical fixture receipt type: {receipt_type}")
        raw = seal_receipt(
            {
                "schema_version": RECEIPT_SCHEMA_VERSION,
                "receipt_id": receipt_id,
                "receipt_type": receipt_type.value,
                "evidence_layer": layer.value,
                "evidence_status": status.value,
                "qualification_phase": phase.value,
                "qualification_run": {
                    "run_id": QUALIFICATION_RUN.run_id,
                    "nonce": QUALIFICATION_RUN.nonce,
                },
                "candidate_identity": candidate_to_mapping(candidate),
                "candidate_identity_sha256": candidate_digest,
                "requirement_id": requirement_id,
                "command_id": command_id,
                "scenario_id": scenario_id,
                "command_plan_sha256": command_plan_sha256,
                "command_record_sha256": command_record_sha256,
                "runtime_resolution": runtime_resolution,
                "qualified_premerge_authority_sha256": qualified_premerge_authority_sha256,
                "attempt": 1,
                "execution_interval": {
                    "started_at_unix_ms": started_at_unix_ms,
                    "ended_at_unix_ms": ended_at_unix_ms,
                },
                "executor": {
                    "executor_id": f"executor-{token}",
                    "host": command_authority.host,
                    "platform": (
                        ExecutorPlatform.MACOS.value
                        if macos
                        else ExecutorPlatform.LINUX.value
                    ),
                    "architecture": (
                        ExecutorArchitecture.ARM64.value
                        if macos
                        else ExecutorArchitecture.X86_64.value
                    ),
                    "os_version": "27.0" if macos else "ubuntu-24.04",
                },
                "command_authority": {
                    "host": command_authority.host,
                    "execution_mode": command_authority.execution_mode,
                    "argv_sha256": command_authority.argv_sha256,
                    "working_directory_sha256": command_authority.working_directory_sha256,
                    "environment_sha256": command_authority.environment_sha256,
                    "generated_artifacts": list(command_authority.generated_artifacts),
                    "generated_logs": list(command_authority.generated_logs),
                    "prerequisite_receipts": [
                        {
                            "command_id": item.command_id,
                            "receipt_id": item.receipt_id,
                            "canonical_sha256": item.canonical_sha256,
                            "qualification_run_id": item.qualification_run_id,
                            "qualification_run_nonce": item.qualification_run_nonce,
                        }
                        for item in command_authority.prerequisite_receipts
                    ],
                },
                "artifacts": artifacts,
                "constituents": constituents,
                "skips": [],
                "diagnostic": None if status is EvidenceStatus.PASSED else status.value,
                "authority": authority,
            }
        )
        context = HistoricalPhysicalReceiptContext(
            expected_candidate=candidate,
            expected_qualification_run=QUALIFICATION_RUN,
            qualification_phase=phase,
            expected_layer=layer,
            expected_receipt_type=receipt_type,
            expected_receipt_id=receipt_id,
            expected_requirement_id=requirement_id,
            expected_command_id=command_id,
            expected_scenario_id=scenario_id,
            expected_command_plan_sha256=command_plan_sha256,
            expected_command_record_sha256=command_record_sha256,
            expected_runtime_resolution=runtime_resolution,
            expected_command_authority=command_authority,
            expected_qualified_premerge_authority_sha256=(
                qualified_premerge_authority_sha256
            ),
            expected_attempt=1,
            expected_execution_interval=ExecutionIntervalExpectation(
                started_at_unix_ms=started_at_unix_ms,
                ended_at_unix_ms=ended_at_unix_ms,
            ),
            expected_artifact_root_id=root_id,
            expected_artifacts=tuple(expected_artifacts),
            artifact_root=self.root,
            expected_executor_id=f"executor-{token}",
            require_physical_artifacts_on_pass=True,
        )
        return EvidenceReceiptInput(receipt=raw, context=context)


class EvidencePartialOrderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.factory = PhysicalReceiptFactory(Path(self.temporary.name))
        self.prospective = candidate_for_subject(
            CandidateSubjectKind.PROSPECTIVE_MERGE
        )
        self.postmerge = candidate_for_subject(CandidateSubjectKind.POST_MERGE)

    def _all_passed_claims(self) -> tuple[EvidenceClaim, ...]:
        claims: list[EvidenceClaim] = []
        review_command_id, review_lens_id = next(
            iter(INDEPENDENT_REVIEW_COMMAND_LENSES.items())
        )
        for layer in EvidenceLayer:
            kwargs: dict[str, object] = {}
            if layer is EvidenceLayer.INDEPENDENT_REVIEW:
                kwargs = {
                    "command_id": review_command_id,
                    "selector_ids": (review_lens_id,),
                    "command_authority": CommandAuthorityExpectation(
                        host="independent-reviewer",
                        execution_mode="executor-required",
                        argv_sha256=sha("3"),
                        working_directory_sha256=sha("4"),
                        environment_sha256=sha("5"),
                        generated_artifacts=tuple(
                            sorted(
                                (
                                    f"{review_lens_id}-review-report.json",
                                    f"{review_lens_id}-execution-report.json",
                                )
                            )
                        ),
                        generated_logs=(),
                        prerequisite_receipts=(),
                    ),
                }
            claims.append(
                EvidenceClaim(
                    layer=layer,
                    receipt_inputs=(
                        self.factory.make(
                            self.postmerge
                            if layer is EvidenceLayer.POST_MERGE
                            else self.prospective,
                            layer,
                            **kwargs,
                        ),
                    ),
                )
            )
        return tuple(claims)

    def test_default_order_contains_exactly_the_frozen_eighteen_layers(self) -> None:
        order = default_evidence_partial_order()
        self.assertEqual(len(order.layers), 18)
        self.assertEqual(set(order.layers), set(EvidenceLayer))
        self.assertEqual(set(order.edges), set(DEFAULT_EVIDENCE_EDGES))
        self.assertEqual(
            REQUIRED_RECEIPT_TYPES_BY_LAYER,
            {
                layer: frozenset({receipt_type})
                for layer, receipt_type in EXPECTED_RECEIPT_TYPE_BY_LAYER.items()
            },
        )

    def test_generic_command_cannot_substitute_for_specialized_layer_authority(self) -> None:
        order = default_evidence_partial_order()
        for layer in EvidenceLayer:
            with self.subTest(layer.value):
                candidate = (
                    self.postmerge
                    if layer is EvidenceLayer.POST_MERGE
                    else self.prospective
                )
                generic = self.factory.make(
                    candidate,
                    layer,
                    receipt_type=ReceiptType.COMMAND_EXECUTION,
                )
                compiled, issues = compile_evidence_claims(
                    order,
                    expected_candidate=candidate,
                    expected_premerge_candidate=(
                        self.prospective
                        if layer is EvidenceLayer.POST_MERGE
                        else None
                    ),
                    claims=(EvidenceClaim(layer=layer, receipt_inputs=(generic,)),),
                )
                self.assertIsNone(compiled)
                self.assertIn(
                    "missing-required-receipt-type",
                    {issue.code for issue in issues},
                )

    def test_order_freezes_progression_without_flattening_branches(self) -> None:
        order = default_evidence_partial_order()
        for lower, higher in (
            (EvidenceLayer.SOURCE_GOVERNANCE, EvidenceLayer.HOSTED_PURE),
            (EvidenceLayer.NATIVE_NORMAL, EvidenceLayer.NATIVE_ASAN),
            (EvidenceLayer.NATIVE_NORMAL, EvidenceLayer.NATIVE_UBSAN),
            (EvidenceLayer.INSTALLED_WORKFLOW, EvidenceLayer.STRESS_RECOVERY),
            (EvidenceLayer.INDEPENDENT_REVIEW, EvidenceLayer.PROSPECTIVE_MERGE_TREE),
        ):
            self.assertTrue(order.precedes(lower, higher))
        self.assertFalse(
            order.precedes(EvidenceLayer.NATIVE_ASAN, EvidenceLayer.NATIVE_UBSAN)
        )
        self.assertFalse(
            order.precedes(
                EvidenceLayer.INSTALLED_WORKFLOW,
                EvidenceLayer.INSTALLED_ACCESSIBILITY,
            )
        )

    def test_no_distinct_layer_can_substitute_for_another(self) -> None:
        order = default_evidence_partial_order()
        for provided in EvidenceLayer:
            for required in EvidenceLayer:
                self.assertEqual(
                    order.can_satisfy(provided, required),
                    provided is required,
                )

    def test_canonical_serialization_is_stable_and_lane_e_safe(self) -> None:
        order = default_evidence_partial_order()
        mapping = evidence_partial_order_to_mapping(order)
        self.assertEqual(
            mapping["schema_version"],
            EVIDENCE_PARTIAL_ORDER_SCHEMA_VERSION,
        )
        self.assertEqual(len(mapping["layers"]), 18)
        self.assertEqual(len(mapping["transitive_predecessors"]), 18)
        self.assertEqual(
            evidence_partial_order_sha256(order),
            evidence_partial_order_sha256(default_evidence_partial_order()),
        )
        forged = replace(order, transitive_predecessors={})
        with self.assertRaisesRegex(ValueError, "invalid evidence partial order"):
            evidence_partial_order_to_mapping(forged)

    def test_all_passed_raw_receipts_and_physical_artifacts_compile(self) -> None:
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.postmerge,
            expected_premerge_candidate=self.prospective,
            claims=self._all_passed_claims(),
        )
        self.assertEqual(issues, ())
        self.assertIsNotNone(compiled)
        assert compiled is not None
        self.assertEqual({claim.layer for claim in compiled}, set(EvidenceLayer))
        self.assertTrue(all(claim.status is EvidenceStatus.PASSED for claim in compiled))

    def test_physical_fixture_compilation_does_not_admit_public_external_receipts(self) -> None:
        claims = self._all_passed_claims()
        external = next(
            item for claim in claims for item in claim.receipt_inputs
            if item.context.expected_command_id in EXTERNAL_AUTHORITY_COMMANDS
        )
        with historical_physical_fixture_validation():
            # Even inside fixture compilation isolation, the public entry point
            # rejects these same physical bytes without retained authority.
            issues = validate_receipt(external.receipt, context=external.context)
        self.assertEqual([issue.code for issue in issues], ["external-admission-required"])
        compiled, issues = _compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.postmerge,
            expected_premerge_candidate=self.prospective,
            expected_qualification_run=QUALIFICATION_RUN,
            claims=claims,
        )
        self.assertIsNone(compiled)
        self.assertIn("external-admission-required", {issue.code for issue in issues})
        unmarked_claims = tuple(
            replace(claim, receipt_inputs=tuple(
                replace(item, context=ReceiptValidationContext(**vars(item.context)))
                if item is external else item
                for item in claim.receipt_inputs
            )) for claim in claims
        )
        compiled, issues = compile_physical_fixture_claims(
            default_evidence_partial_order(),
            expected_candidate=self.postmerge,
            expected_premerge_candidate=self.prospective,
            claims=unmarked_claims,
        )
        self.assertIsNone(compiled)
        self.assertIn("external-admission-required", {issue.code for issue in issues})

    def test_passed_higher_layer_cannot_bypass_missing_predecessor(self) -> None:
        claim = EvidenceClaim(
            layer=EvidenceLayer.HOSTED_PURE,
            receipt_inputs=(
                self.factory.make(self.prospective, EvidenceLayer.HOSTED_PURE),
            ),
        )
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(claim,),
        )
        self.assertIsNone(compiled)
        self.assertIn("evidence-order-bypass", {issue.code for issue in issues})

    def test_rejects_cycle_and_removed_mandatory_progression(self) -> None:
        order, issues = compile_evidence_partial_order(
            edges=(
                *DEFAULT_EVIDENCE_EDGES,
                (EvidenceLayer.POST_MERGE, EvidenceLayer.SOURCE_GOVERNANCE),
            )
        )
        self.assertIsNone(order)
        self.assertIn("evidence-cycle", {issue.code for issue in issues})
        order, issues = compile_evidence_partial_order(
            edges=DEFAULT_EVIDENCE_EDGES[1:]
        )
        self.assertIsNone(order)
        self.assertIn(
            "missing-mandatory-evidence-edge",
            {issue.code for issue in issues},
        )

    def test_rejects_unknown_duplicate_or_missing_layer(self) -> None:
        cases = (
            (
                tuple(EvidenceLayer),
                (*DEFAULT_EVIDENCE_EDGES, ("unknown", EvidenceLayer.POST_MERGE)),
                "unknown-evidence-edge",
            ),
            (
                (*tuple(EvidenceLayer), EvidenceLayer.POST_MERGE),
                DEFAULT_EVIDENCE_EDGES,
                "duplicate-evidence-layer",
            ),
            (
                tuple(
                    layer
                    for layer in EvidenceLayer
                    if layer is not EvidenceLayer.POST_MERGE
                ),
                DEFAULT_EVIDENCE_EDGES,
                "evidence-layer-vocabulary",
            ),
        )
        for layers, edges, expected in cases:
            with self.subTest(expected):
                order, issues = compile_evidence_partial_order(  # type: ignore[arg-type]
                    layers=layers,
                    edges=edges,
                )
                self.assertIsNone(order)
                self.assertIn(expected, {issue.code for issue in issues})

    def test_malformed_partial_order_inputs_fail_closed_without_hashing_them(self) -> None:
        order, issues = compile_evidence_partial_order(  # type: ignore[arg-type]
            layers=(*tuple(EvidenceLayer)[:-1], []),
        )
        self.assertIsNone(order)
        self.assertIn("unknown-evidence-layer", {issue.code for issue in issues})
        order, issues = compile_evidence_partial_order(  # type: ignore[arg-type]
            edges=object(),
        )
        self.assertIsNone(order)
        self.assertIn("evidence-edges-type", {issue.code for issue in issues})

    def test_physical_validation_cannot_be_disabled(self) -> None:
        receipt_input = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
        )
        forged = replace(
            receipt_input,
            context=replace(
                receipt_input.context,
                require_physical_artifacts_on_pass=False,
                artifact_root=None,
            ),
        )
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(forged,),
                ),
            ),
        )
        self.assertIsNone(compiled)
        codes = {issue.code for issue in issues}
        self.assertIn("physical-artifact-validation-required", codes)
        self.assertIn("physical-artifact-root-required", codes)

    def test_physical_artifact_tamper_fails_closed(self) -> None:
        receipt_input = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
        )
        relative = receipt_input.receipt["artifacts"][0]["relative_path"]
        (self.factory.root / relative).write_bytes(b"tampered\n")
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(receipt_input,),
                ),
            ),
        )
        self.assertIsNone(compiled)
        self.assertTrue(
            {"artifact-byte-count-mismatch", "artifact-sha256-mismatch"}
            & {issue.code for issue in issues}
        )

    def test_duplicate_same_layer_receipt_and_artifact_ids_fail_closed(self) -> None:
        first = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
            receipt_id="receipt-duplicate",
            artifact_id="artifact-duplicate",
        )
        second = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
            receipt_id="receipt-duplicate",
            artifact_id="artifact-duplicate",
        )
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(first, second),
                ),
            ),
        )
        self.assertIsNone(compiled)
        codes = {issue.code for issue in issues}
        self.assertIn("duplicate-receipt-id", codes)
        self.assertIn("duplicate-artifact-id", codes)

    def test_malformed_public_dtos_return_issues_instead_of_raising(self) -> None:
        valid = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
        )
        malformed_receipt = dict(valid.receipt)
        malformed_receipt["receipt_id"] = []
        preprojected = EvidenceReceiptOutput(  # type: ignore[arg-type]
            receipt_id=[],
            canonical_sha256=sha("a"),
            qualification_run=QUALIFICATION_RUN,
            receipt_type=ReceiptType.COMMAND_EXECUTION,
            command_id="command-invalid",
            requirement_id="requirement-invalid",
            scenario_id="scenario-invalid",
            command_plan_sha256=sha("b"),
            command_record_sha256=sha("c"),
            runtime_resolution=None,
            command_authority=object(),
            execution_interval=object(),
            qualified_premerge_authority_sha256=None,
            constituent_selector_ids=(),
        )
        malformed_candidate = replace(self.prospective, source=object())  # type: ignore[arg-type]
        for candidate, receipt_inputs, expected in (
            (
                self.prospective,
                (replace(valid, receipt=malformed_receipt),),
                "stable-id",
            ),
            (
                self.prospective,
                (preprojected,),
                "receipt-input-type",
            ),
            (malformed_candidate, (valid,), "candidate-canonicalization"),
        ):
            with self.subTest(expected):
                compiled, issues = compile_evidence_claims(
                    default_evidence_partial_order(),
                    expected_candidate=candidate,
                    claims=(
                        EvidenceClaim(
                            layer=EvidenceLayer.SOURCE_GOVERNANCE,
                            receipt_inputs=receipt_inputs,  # type: ignore[arg-type]
                        ),
                    ),
                )
                self.assertIsNone(compiled)
                self.assertIn(expected, {issue.code for issue in issues})

        cyclic: dict[str, object] = {}
        cyclic["self"] = cyclic
        compiled, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(replace(valid, receipt=cyclic),),
                ),
            ),
        )
        self.assertIsNone(compiled)
        self.assertIn(
            "receipt-input-canonicalization",
            {issue.code for issue in issues},
        )

    def test_forged_partial_order_and_noncanonical_candidate_receipt_fail(self) -> None:
        order = default_evidence_partial_order()
        forged_order = replace(order, transitive_predecessors={})
        compiled, issues = compile_evidence_claims(
            forged_order,
            expected_candidate=self.prospective,
            claims=(),
        )
        self.assertIsNone(compiled)
        self.assertIn(
            "evidence-partial-order-not-canonical",
            {issue.code for issue in issues},
        )

        receipt_input = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
        )
        raw = dict(receipt_input.receipt)
        candidate_mapping = dict(raw["candidate_identity"])
        candidate_mapping["tools"] = list(reversed(candidate_mapping["tools"]))
        raw["candidate_identity"] = candidate_mapping
        raw = seal_receipt(raw)
        compiled, issues = compile_evidence_claims(
            order,
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(replace(receipt_input, receipt=raw),),
                ),
            ),
        )
        self.assertIsNone(compiled)
        self.assertIn(
            "receipt-candidate-not-canonical",
            {issue.code for issue in issues},
        )

    def test_empty_and_failed_claims_have_closed_derived_statuses(self) -> None:
        empty, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(),
                ),
            ),
        )
        self.assertEqual(issues, ())
        assert empty is not None
        self.assertEqual(empty[0].status, EvidenceStatus.NOT_RUN)

        failed_input = self.factory.make(
            self.prospective,
            EvidenceLayer.SOURCE_GOVERNANCE,
            status=EvidenceStatus.FAILED,
        )
        failed, issues = compile_evidence_claims(
            default_evidence_partial_order(),
            expected_candidate=self.prospective,
            claims=(
                EvidenceClaim(
                    layer=EvidenceLayer.SOURCE_GOVERNANCE,
                    receipt_inputs=(failed_input,),
                ),
            ),
        )
        self.assertEqual(issues, ())
        assert failed is not None
        self.assertEqual(failed[0].status, EvidenceStatus.FAILED)


if __name__ == "__main__":
    unittest.main()
