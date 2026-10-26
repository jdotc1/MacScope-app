from __future__ import annotations

import hashlib
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from typing import Any

from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256
from Scripts.reconstruction_gate_f.receipt_schema import (
    RECEIPT_SCHEMA_VERSION,
    seal_receipt,
    seal_skip,
)
from Scripts.reconstruction_gate_f.receipt_validator import (
    ArtifactExpectation,
    CommandAuthorityExpectation,
    CommandPrerequisiteExpectation,
    ExecutionIntervalExpectation,
    QualificationRunAuthority,
    ReceiptValidationContext,
    validate_receipt,
    validate_receipts,
)
from Scripts.reconstruction_gate_f.schema import (
    ArtifactKind,
    CandidateIdentity,
    CandidateSubjectKind,
    EvidenceLayer,
    QualificationPhase,
    ReceiptType,
    candidate_identity_sha256,
    candidate_to_mapping,
    parse_candidate_identity,
)
from Scripts.reconstruction_gate_f.tests import clone, parsed_candidate, sha


class GateFReceiptValidatorTests(unittest.TestCase):
    qualification_run = QualificationRunAuthority(
        run_id="gate-f-qualification-20260828",
        nonce=sha("9"),
    )
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_bootstrap_verifiers_require_capture_and_original_layer_artifact_roles(self):
        from Scripts.reconstruction_gate_f.receipt_validator import CAPTURE_REQUIRED_COMMANDS, _validate_physical_receipt
        from Scripts.reconstruction_gate_f.receipt_schema import REQUIRED_ARTIFACT_KINDS
        for command, layer, role, artifact_kind in (
            ("qualification.verify-bootstrap-fullsuite", EvidenceLayer.XCODE_FULL_CORETESTS, ReceiptType.TEST_RESULT, "xcresult"),
            ("qualification.verify-bootstrap-products", EvidenceLayer.RELEASE_BUILD, ReceiptType.RELEASE_BUILD, "app-bundle")):
            self.assertIn(command, CAPTURE_REQUIRED_COMMANDS)
            self.assertIn(ArtifactKind(artifact_kind), REQUIRED_ARTIFACT_KINDS[layer])
            receipt = self._make_receipt(receipt_type=role, layer=layer, artifact_kind="json",
                                         platform="macos", architecture="arm64")
            receipt["command_id"] = command
            receipt = self._reseal(receipt)
            context = replace(self._context(artifact_kind="json"), expected_command_id=command,
                              expected_receipt_type=role, expected_layer=layer)
            self.assertEqual({issue.code for issue in validate_receipt(receipt, context=context)},
                             {"capture-admission-required"})
            self.assertIn("missing-required-artifact", {issue.code for issue in _validate_physical_receipt(receipt, context=context)})

    def _make_receipt(
        self,
        *,
        candidate: CandidateIdentity | None = None,
        receipt_type: ReceiptType = ReceiptType.TEST_RESULT,
        layer: EvidenceLayer = EvidenceLayer.HOSTED_PURE,
        artifact_kind: str = "test-results",
        authority: dict[str, Any] | None = None,
        statuses: tuple[str, ...] = ("passed",),
        phase: QualificationPhase = QualificationPhase.PREMERGE,
        platform: str = "linux",
        architecture: str = "x86_64",
        receipt_id: str = "receipt-hosted",
        skips: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        candidate = candidate or parsed_candidate()
        candidate_digest = candidate_identity_sha256(candidate)
        payload = f"{receipt_type.value}:{layer.value}".encode()
        relative_path = f"artifacts/{receipt_id}.json"
        artifact_path = self.root / relative_path
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_path.write_bytes(payload)
        artifact = {
            "schema_version": 1,
            "artifact_id": f"artifact-{receipt_id}",
            "candidate_identity_sha256": candidate_digest,
            "evidence_layer": layer.value,
            "root_id": "qualification-run",
            "relative_path": relative_path,
            "kind": artifact_kind,
            "media_type": "application/json",
            "byte_count": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "producer_receipt_id": receipt_id,
            "command_id": "hosted-tests",
            "command_output": f"semantic:{artifact_kind}",
        }
        constituents = [
            {
                "selector_id": f"selector-{index + 1}",
                "status": status,
                "evidence_layer": layer.value,
                "candidate_identity_sha256": candidate_digest,
                "artifact_ids": [artifact["artifact_id"]],
            }
            for index, status in enumerate(statuses)
        ]
        if authority is None:
            authority = {
                "selector_catalog_sha256": candidate.selector_catalog_sha256,
                "expected_selector_count": len(statuses),
                "executed_selector_count": sum(status != "not-run" for status in statuses),
                "passed_selector_count": statuses.count("passed"),
                "failed_selector_count": statuses.count("failed"),
                "skipped_selector_count": statuses.count("skipped"),
            }
        return seal_receipt(
            {
                "schema_version": RECEIPT_SCHEMA_VERSION,
                "receipt_id": receipt_id,
                "receipt_type": receipt_type.value,
                "evidence_layer": layer.value,
                "evidence_status": "passed",
                "qualification_phase": phase.value,
                "qualification_run": {
                    "run_id": self.qualification_run.run_id,
                    "nonce": self.qualification_run.nonce,
                },
                "candidate_identity": candidate_to_mapping(candidate),
                "candidate_identity_sha256": candidate_digest,
                "requirement_id": "gate-f-hosted",
                "command_id": "hosted-tests",
                "scenario_id": "scenario-hosted",
                "command_plan_sha256": sha("a"),
                "command_record_sha256": sha("b"),
                "runtime_resolution": None,
                "qualified_premerge_authority_sha256": None,
                "attempt": 1,
                "execution_interval": {
                    "started_at_unix_ms": 1_000,
                    "ended_at_unix_ms": 2_000,
                },
                "executor": {
                    "executor_id": "hosted-runner",
                    "host": "host-independent",
                    "platform": platform,
                    "architecture": architecture,
                    "os_version": "executor-os-1",
                },
                "command_authority": {
                    "host": "host-independent",
                    "execution_mode": "runnable",
                    "argv_sha256": sha("c"),
                    "working_directory_sha256": sha("d"),
                    "environment_sha256": sha("e"),
                    "generated_artifacts": [],
                    "generated_logs": [],
                    "prerequisite_receipts": [],
                },
                "artifacts": [artifact],
                "constituents": constituents,
                "skips": skips or [],
                "diagnostic": None,
                "authority": authority,
            }
        )

    def _context(
        self,
        *,
        candidate: CandidateIdentity | None = None,
        receipt_type: ReceiptType = ReceiptType.TEST_RESULT,
        layer: EvidenceLayer = EvidenceLayer.HOSTED_PURE,
        phase: QualificationPhase = QualificationPhase.PREMERGE,
        expected_skips: tuple[dict[str, Any], ...] = (),
        artifact_root: Path | None | object = ...,
        receipt_id: str = "receipt-hosted",
        artifact_kind: str | None = None,
    ) -> ReceiptValidationContext:
        if artifact_root is ...:
            artifact_root = self.root
        if artifact_kind is None:
            artifact_kind = {
                EvidenceLayer.HOSTED_PURE: "test-results",
                EvidenceLayer.XCODE_FOCUSED: "xcresult",
                EvidenceLayer.STRICT_SIGNING: "signing-report",
                EvidenceLayer.STRESS_RECOVERY: "stress-report",
            }[layer]
        return ReceiptValidationContext(
            expected_candidate=candidate or parsed_candidate(),
            expected_qualification_run=self.qualification_run,
            qualification_phase=phase,
            expected_layer=layer,
            expected_receipt_type=receipt_type,
            expected_receipt_id=receipt_id,
            expected_requirement_id="gate-f-hosted",
            expected_command_id="hosted-tests",
            expected_scenario_id="scenario-hosted",
            expected_command_plan_sha256=sha("a"),
            expected_command_record_sha256=sha("b"),
            expected_command_authority=CommandAuthorityExpectation(
                host="host-independent",
                execution_mode="runnable",
                argv_sha256=sha("c"),
                working_directory_sha256=sha("d"),
                environment_sha256=sha("e"),
                generated_artifacts=(),
                generated_logs=(),
                prerequisite_receipts=(),
            ),
            expected_qualified_premerge_authority_sha256=None,
            expected_attempt=1,
            expected_execution_interval=ExecutionIntervalExpectation(
                started_at_unix_ms=1_000,
                ended_at_unix_ms=2_000,
            ),
            expected_artifact_root_id="qualification-run",
            expected_artifacts=(
                ArtifactExpectation(
                    artifact_id=f"artifact-{receipt_id}",
                    relative_path=f"artifacts/{receipt_id}.json",
                    kind=ArtifactKind(artifact_kind),
                    media_type="application/json",
                    command_output=f"semantic:{artifact_kind}",
                ),
            ),
            artifact_root=artifact_root,
            expected_executor_id="hosted-runner",
            expected_skips=expected_skips,
        )

    @staticmethod
    def _reseal(receipt: dict[str, Any]) -> dict[str, Any]:
        receipt.pop("canonical_sha256", None)
        sealed = seal_receipt(receipt)
        receipt.clear()
        receipt.update(sealed)
        return receipt

    def test_valid_exact_candidate_receipt(self) -> None:
        receipt = self._make_receipt()
        self.assertEqual(validate_receipt(receipt, context=self._context()), ())

    def test_schema_three_and_unadmitted_runtime_resolution_are_rejected(self) -> None:
        receipt = self._make_receipt()
        receipt["schema_version"] = 3
        self._reseal(receipt)
        self.assertIn("receipt-schema-version", {
            issue.code for issue in validate_receipt(receipt, context=self._context())
        })
        for resolution in ({}, [], "caller-selected", {"schema_version": 1}):
            receipt = self._make_receipt()
            receipt["runtime_resolution"] = resolution
            self._reseal(receipt)
            self.assertIn("runtime-resolution-mismatch", {
                issue.code for issue in validate_receipt(receipt, context=self._context())
            })

    def test_resealed_receipt_from_another_qualification_run_is_rejected(self) -> None:
        receipt = self._make_receipt()
        receipt["qualification_run"] = {
            "run_id": "gate-f-qualification-replayed",
            "nonce": sha("8"),
        }
        self._reseal(receipt)
        self.assertIn(
            "qualification-run-authority-mismatch",
            {issue.code for issue in validate_receipt(receipt, context=self._context())},
        )

    def test_prerequisite_from_another_qualification_run_is_rejected(self) -> None:
        receipt = self._make_receipt()
        prerequisite = {
            "command_id": "predecessor-command",
            "receipt_id": "predecessor-receipt",
            "canonical_sha256": sha("7"),
            "qualification_run_id": self.qualification_run.run_id,
            "qualification_run_nonce": sha("8"),
        }
        receipt["command_authority"]["prerequisite_receipts"] = [prerequisite]
        self._reseal(receipt)
        context = replace(
            self._context(),
            expected_command_authority=replace(
                self._context().expected_command_authority,
                prerequisite_receipts=(
                    CommandPrerequisiteExpectation(
                        command_id=prerequisite["command_id"],
                        receipt_id=prerequisite["receipt_id"],
                        canonical_sha256=prerequisite["canonical_sha256"],
                        qualification_run_id=prerequisite["qualification_run_id"],
                        qualification_run_nonce=prerequisite[
                            "qualification_run_nonce"
                        ],
                    ),
                ),
            ),
        )
        self.assertIn(
            "command-prerequisite-qualification-run-mismatch",
            {issue.code for issue in validate_receipt(receipt, context=context)},
        )

    def test_execution_interval_is_closed_ordered_and_context_bound(self) -> None:
        receipt = self._make_receipt()
        receipt["execution_interval"]["ended_at_unix_ms"] = 999
        self._reseal(receipt)
        codes = {
            issue.code
            for issue in validate_receipt(receipt, context=self._context())
        }
        self.assertIn("execution-interval-order", codes)
        self.assertIn("execution-interval-mismatch", codes)

        receipt = self._make_receipt()
        receipt["execution_interval"]["unexpected"] = 1
        self._reseal(receipt)
        self.assertIn(
            "unknown-field",
            {
                issue.code
                for issue in validate_receipt(receipt, context=self._context())
            },
        )

        receipt = self._make_receipt()
        mismatched = replace(
            self._context(),
            expected_execution_interval=ExecutionIntervalExpectation(
                started_at_unix_ms=1_001,
                ended_at_unix_ms=2_000,
            ),
        )
        self.assertIn(
            "execution-interval-mismatch",
            {issue.code for issue in validate_receipt(receipt, context=mismatched)},
        )

    def test_historical_v1_receipt_is_ineligible_for_current_gate(self) -> None:
        receipt = self._make_receipt()
        receipt["schema_version"] = 1
        self._reseal(receipt)
        self.assertIn(
            "receipt-schema-version",
            {
                issue.code
                for issue in validate_receipt(receipt, context=self._context())
            },
        )

    def test_exact_subject_layer_and_artifact_bindings_are_required(self) -> None:
        mutations = (
            ("receipt-id-mismatch", lambda value: value.__setitem__("receipt_id", "other-receipt")),
            ("receipt-requirement-mismatch", lambda value: value.__setitem__("requirement_id", "other-requirement")),
            ("receipt-command-mismatch", lambda value: value.__setitem__("command_id", "other-command")),
            ("receipt-scenario-mismatch", lambda value: value.__setitem__("scenario_id", "other-scenario")),
            ("receipt-layer-mismatch", lambda value: value.__setitem__("evidence_layer", EvidenceLayer.SOURCE_GOVERNANCE.value)),
            ("artifact-binding-mismatch", lambda value: value["artifacts"][0].__setitem__("producer_receipt_id", "other-receipt")),
            ("artifact-binding-mismatch", lambda value: value["artifacts"][0].__setitem__("command_id", "other-command")),
            ("artifact-binding-mismatch", lambda value: value["artifacts"][0].__setitem__("root_id", "other-root")),
        )
        for expected, mutate in mutations:
            with self.subTest(expected=expected):
                receipt = self._make_receipt()
                mutate(receipt)
                self._reseal(receipt)
                self.assertIn(expected, {issue.code for issue in validate_receipt(receipt, context=self._context())})

    def test_receipt_seals_exact_command_plan_and_record_authority(self) -> None:
        receipt = self._make_receipt()
        receipt.pop("command_plan_sha256")
        self._reseal(receipt)
        self.assertIn(
            "missing-field",
            {issue.code for issue in validate_receipt(receipt, context=self._context())},
        )

        receipt = self._make_receipt()
        receipt["command_plan_sha256"] = "not-a-digest"
        self._reseal(receipt)
        self.assertIn(
            "command-plan-sha256",
            {issue.code for issue in validate_receipt(receipt, context=self._context())},
        )

        for field_name, expected in (
            ("command_plan_sha256", "receipt-command-plan-mismatch"),
            ("command_record_sha256", "receipt-command-record-mismatch"),
        ):
            with self.subTest(field_name):
                receipt = self._make_receipt()
                receipt[field_name] = sha("c")
                self._reseal(receipt)
                self.assertIn(
                    expected,
                    {
                        issue.code
                        for issue in validate_receipt(
                            receipt,
                            context=self._context(),
                        )
                    },
                )

        caller_rebound = replace(
            self._context(),
            expected_command_plan_sha256=sha("c"),
        )
        self.assertIn(
            "receipt-command-plan-mismatch",
            {
                issue.code
                for issue in validate_receipt(
                    self._make_receipt(),
                    context=caller_rebound,
                )
            },
        )

    def test_candidate_axis_drift_is_rejected_even_when_receipt_is_resealed(self) -> None:
        receipt = self._make_receipt()
        receipt["candidate_identity"]["tools"][0]["identity_sha256"] = "e" * 64
        changed, issues = parse_candidate_identity(receipt["candidate_identity"])
        self.assertEqual(issues, ())
        receipt["candidate_identity_sha256"] = candidate_identity_sha256(changed)
        receipt["artifacts"][0]["candidate_identity_sha256"] = receipt["candidate_identity_sha256"]
        receipt["constituents"][0]["candidate_identity_sha256"] = receipt["candidate_identity_sha256"]
        self._reseal(receipt)
        self.assertIn("receipt-candidate-mismatch", {issue.code for issue in validate_receipt(receipt, context=self._context())})

    def test_passed_aggregate_cannot_hide_failed_skipped_or_not_run(self) -> None:
        for status in ("failed", "skipped", "not-run"):
            with self.subTest(status=status):
                receipt = self._make_receipt(statuses=(status,))
                self.assertIn(
                    "aggregate-hides-constituent-failure",
                    {issue.code for issue in validate_receipt(receipt, context=self._context())},
                )

    def test_source_bound_skip_is_exact_and_reason_drift_is_rejected(self) -> None:
        candidate = parsed_candidate()
        skip = seal_skip(
            {
                "skip_id": "skip-golden-external",
                "selector_id": "selector-1",
                "evidence_layer": EvidenceLayer.HOSTED_PURE.value,
                "scenario_id": "scenario-hosted",
                "reason_code": "external-fixture-unavailable",
                "reason_text_sha256": sha("1"),
                "source_commit": candidate.source.commit,
                "source_tree": candidate.source.tree,
                "source_contract_sha256": sha("2"),
                "selector_catalog_sha256": candidate.selector_catalog_sha256,
            }
        )
        receipt = self._make_receipt(candidate=candidate, statuses=("skipped",), skips=[skip])
        receipt["evidence_status"] = "failed"
        self._reseal(receipt)
        context = self._context(candidate=candidate, expected_skips=(skip,))
        self.assertEqual(validate_receipt(receipt, context=context), ())
        receipt["skips"][0]["reason_code"] = "another-reason"
        receipt["skips"][0] = seal_skip({key: value for key, value in receipt["skips"][0].items() if key != "authorization_sha256"})
        self._reseal(receipt)
        self.assertIn("skip-drift", {issue.code for issue in validate_receipt(receipt, context=context)})

    def test_pass_requires_physical_nonempty_required_artifact(self) -> None:
        receipt = self._make_receipt()
        self.assertIn(
            "artifact-root-required",
            {issue.code for issue in validate_receipt(receipt, context=self._context(artifact_root=None))},
        )
        receipt["artifacts"][0]["byte_count"] = 0
        self._reseal(receipt)
        self.assertIn("empty-required-artifact", {issue.code for issue in validate_receipt(receipt, context=self._context())})

    def test_macos_layer_rejects_linux_x86_executor(self) -> None:
        receipt = self._make_receipt(layer=EvidenceLayer.XCODE_FOCUSED, artifact_kind="xcresult")
        context = self._context(layer=EvidenceLayer.XCODE_FOCUSED)
        self.assertIn("executor-platform", {issue.code for issue in validate_receipt(receipt, context=context)})

    def test_diagnostics_are_bounded_and_nested_wrong_types_never_crash(self) -> None:
        receipt = self._make_receipt()
        receipt["diagnostic"] = "x" * 1025
        self._reseal(receipt)
        self.assertIn("diagnostic-bounds", {issue.code for issue in validate_receipt(receipt, context=self._context())})
        receipt = self._make_receipt()
        receipt["authority"] = []
        self._reseal(receipt)
        self.assertIn("record-type", {issue.code for issue in validate_receipt(receipt, context=self._context())})

    def test_phase_and_subject_misuse_is_rejected(self) -> None:
        candidate = parsed_candidate()
        receipt = self._make_receipt(candidate=candidate, phase=QualificationPhase.POSTMERGE)
        context = self._context(candidate=candidate, phase=QualificationPhase.POSTMERGE)
        self.assertIn("premerge-claim-in-postmerge", {issue.code for issue in validate_receipt(receipt, context=context)})

    def test_strict_signing_is_bound_to_candidate_product(self) -> None:
        candidate = parsed_candidate()
        authority = {
            "signing_certificate_sha256": candidate.application.signing_certificate_sha256,
            "signing_subject_sha256": candidate.application.signing_subject_sha256,
            "team_identifier": candidate.application.team_identifier,
            "entitlements_sha256": candidate.application.entitlements_sha256,
            "designated_requirement_sha256": candidate.application.designated_requirement_sha256,
            "hardened_runtime": True,
        }
        receipt = self._make_receipt(
            candidate=candidate,
            receipt_type=ReceiptType.STRICT_SIGNING,
            layer=EvidenceLayer.STRICT_SIGNING,
            artifact_kind="signing-report",
            authority=authority,
            statuses=(),
            platform="macos",
            architecture="arm64",
        )
        context = self._context(candidate=candidate, receipt_type=ReceiptType.STRICT_SIGNING, layer=EvidenceLayer.STRICT_SIGNING)
        self.assertEqual(validate_receipt(receipt, context=context), ())
        receipt["authority"]["entitlements_sha256"] = "e" * 64
        self._reseal(receipt)
        self.assertIn("signing-candidate-mismatch", {issue.code for issue in validate_receipt(receipt, context=context)})

    def test_signed_xpc_bundle_and_executable_bind_the_qualification_product(self) -> None:
        candidate = parsed_candidate()
        service = next(
            item
            for item in candidate.application.qualification_executables
            if item.identity_id == "ai-agent-worker"
        )
        authority = {
            "service_identity_id": service.identity_id,
            "service_bundle_id": service.bundle_identifier,
            "service_executable_sha256": service.sha256,
            "selector_count": 1,
            "failed_count": 0,
            "failure_stage": None,
            "failure_reason": None,
        }
        receipt = self._make_receipt(
            candidate=candidate,
            receipt_type=ReceiptType.SIGNED_XPC,
            layer=EvidenceLayer.SIGNED_XPC,
            artifact_kind="test-results",
            authority=authority,
            platform="macos",
            architecture="arm64",
        )
        executable_payload = b"signed qualification worker"
        executable_relative_path = "artifacts/qualification-worker"
        executable_path = self.root / executable_relative_path
        executable_path.write_bytes(executable_payload)
        executable_artifact = {
            "schema_version": 1,
            "artifact_id": "artifact-qualification-worker",
            "candidate_identity_sha256": candidate_identity_sha256(candidate),
            "evidence_layer": EvidenceLayer.SIGNED_XPC.value,
            "root_id": "qualification-run",
            "relative_path": executable_relative_path,
            "kind": "signed-executable",
            "media_type": "application/octet-stream",
            "byte_count": len(executable_payload),
            "sha256": hashlib.sha256(executable_payload).hexdigest(),
            "producer_receipt_id": "receipt-hosted",
            "command_id": "hosted-tests",
            "command_output": "semantic:signed-executable",
        }
        receipt["artifacts"].append(executable_artifact)
        receipt["constituents"][0]["artifact_ids"].append(
            executable_artifact["artifact_id"]
        )
        self._reseal(receipt)
        base_context = self._context(
            candidate=candidate,
            receipt_type=ReceiptType.SIGNED_XPC,
            layer=EvidenceLayer.SIGNED_XPC,
            artifact_kind="test-results",
        )
        context = replace(
            base_context,
            expected_artifacts=base_context.expected_artifacts + (
                ArtifactExpectation(
                    artifact_id=executable_artifact["artifact_id"],
                    relative_path=executable_relative_path,
                    kind=ArtifactKind.SIGNED_EXECUTABLE,
                    media_type="application/octet-stream",
                    command_output="semantic:signed-executable",
                ),
            ),
        )
        self.assertEqual(validate_receipt(receipt, context=context), ())

        receipt["authority"]["service_bundle_id"] = "com.example.UnboundWorker"
        self._reseal(receipt)
        self.assertIn(
            "signed-xpc-candidate-mismatch",
            {issue.code for issue in validate_receipt(receipt, context=context)},
        )

    def test_stress_attempts_require_one_unique_seed_per_constituent(self) -> None:
        candidate = parsed_candidate()
        seeds = [11, 22]
        authority = {
            "expected_attempt_count": 2,
            "observed_attempt_count": 2,
            "attempt_seeds": seeds,
            "seed_catalog_sha256": canonical_sha256(seeds),
            "failed_count": 0,
        }
        receipt = self._make_receipt(
            candidate=candidate,
            receipt_type=ReceiptType.STRESS_RECOVERY,
            layer=EvidenceLayer.STRESS_RECOVERY,
            artifact_kind="stress-report",
            authority=authority,
            statuses=("passed", "passed"),
            platform="macos",
            architecture="arm64",
        )
        context = self._context(candidate=candidate, receipt_type=ReceiptType.STRESS_RECOVERY, layer=EvidenceLayer.STRESS_RECOVERY)
        self.assertEqual(validate_receipt(receipt, context=context), ())
        receipt["authority"]["attempt_seeds"] = [True, 22]
        self._reseal(receipt)
        self.assertIn("stress-seeds", {issue.code for issue in validate_receipt(receipt, context=context)})

    def test_collection_rejects_duplicate_ids_digests_and_coordinates(self) -> None:
        first = self._make_receipt()
        issues = validate_receipts([first, clone(first)], context=self._context())
        codes = {issue.code for issue in issues}
        self.assertIn("duplicate-receipt-id", codes)
        self.assertIn("duplicate-receipt-digest", codes)
        self.assertIn("duplicate-receipt-coordinate", codes)

        second = clone(first)
        second["receipt_id"] = "receipt-second"
        second["artifacts"][0]["producer_receipt_id"] = "receipt-second"
        self._reseal(second)
        self.assertIn(
            "duplicate-receipt-coordinate",
            {issue.code for issue in validate_receipts([first, second], context=self._context())},
        )


if __name__ == "__main__":
    unittest.main()
