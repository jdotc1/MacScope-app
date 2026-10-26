from __future__ import annotations

import tempfile
import copy
import unittest
import base64
import hashlib
import re
import json
import plistlib
import shutil
from unittest import mock
from dataclasses import asdict, replace
from pathlib import Path
from types import SimpleNamespace

from Scripts.reconstruction_gate_f.canonical_json import canonical_sha256, load_canonical_json, write_canonical_json
from Scripts.reconstruction_gate_f import command_capture, command_execution, prerequisite_dag
from Scripts.reconstruction_gate_f.executor_request_adapter import (
    ExecutorReceiptAdmission, OwnerArtifactSource, build_executor_request,
    CAPTURE_DERIVED_REPORT_COMMANDS, capture_derived_report_receipt_type,
    capture_execution_report_artifact_id, publish_capture_execution_report,
)
from Scripts.reconstruction_gate_f.qualification_receipt_adapter import publish_qualification_artifact_projections
from Scripts.reconstruction_gate_f.executor_receipt import emit_executor_receipt
from Scripts.reconstruction_gate_f.runtime_resolution import resolve_command_record
from Scripts.reconstruction_gate_f.tests import test_executor_receipt as owner_fixture
from Scripts.tests import test_source_export_provenance as source_fixture
from Scripts.source_export_provenance import create_export
from Scripts.reconstruction.installed_matrix_receipt import _bundle_identity
from Scripts.reconstruction_gate_f.evidence_model import (
    EvidenceClaim,
    EvidenceReceiptInput,
    default_evidence_partial_order,
)
from Scripts.reconstruction_gate_f.gate_evaluator import (
    FindingSeverity,
    PREMERGE_EVIDENCE_LAYERS,
    QualificationFinding,
    _make_qualified_premerge_authority as _production_make_qualified_premerge_authority,
    _receipt_command_issues,
    _evaluate_gate_with_validated_command_plans as _production_evaluate_validated,
    evaluate_gate as _production_evaluate_gate,
    evaluate_gate_issues as _production_evaluate_gate_issues,
)
from Scripts.reconstruction_gate_f.schema import to_primitive
from Scripts.reconstruction_gate_f.prerequisite_dag import (
    DEFAULT_PREREQUISITE_SPECS,
    EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS,
    LANE_C_COMMAND_AUTHORITIES,
    LANE_C_COMMAND_AUTHORITIES_BY_ID,
    LANE_C_SCENARIO_BINDINGS,
    LaneCIntegratedCommandPlanInput,
    LaneCScenarioPlanAuthority,
    PrerequisiteDAG,
    PrerequisiteNodeSpec,
    PrerequisiteStage,
    compile_prerequisite_dag,
    lane_c_command_records,
    lane_c_receipt_scenario_ids,
    prerequisite_identity_sha256,
    validate_lane_c_command_plan,
    ValidatedLaneCCommandRecord,
    ValidatedLaneCCommandPlan,
)
from Scripts.reconstruction_gate_f.command_catalog import (
    INDEPENDENT_REVIEW_COMMAND_LENSES,
    command_templates,
)
from Scripts.reconstruction_gate_f.command_compiler import (
    command_plan_sha256,
    compile_command_plan,
)
from Scripts.reconstruction_gate_f.scenario_compiler import compile_scenario_catalog
from Scripts.reconstruction_gate_f.scenario_model import scenario_catalog_sha256
from Scripts.reconstruction_gate_f.receipt_validator import (
    CommandAuthorityExpectation,
    CommandPrerequisiteExpectation,
)
from Scripts.reconstruction_gate_f.receipt_schema import seal_receipt
from Scripts.reconstruction_gate_f.schema import (
    CandidateSubjectKind,
    ArtifactKind,
    QualificationPhase,
    DecisionStatus,
    EvidenceLayer,
    EvidenceStatus,
    ReceiptType,
    candidate_identity_sha256,
)
from Scripts.reconstruction_gate_f.source_contract import (
    PrerequisiteAuthority,
    PrerequisiteStatus,
    SourceContract,
    make_source_contract,
    source_contract_sha256,
)
from Scripts.reconstruction_gate_f.tests import sha
from Scripts.reconstruction_gate_f.tests.test_evidence_partial_order import (
    QUALIFICATION_RUN,
    PhysicalReceiptFactory,
    compile_physical_fixture_claims as compile_evidence_claims,
    fixture_command_plan_sha256,
    fixture_command_record_sha256,
    historical_physical_fixture_validation,
)


def evaluate_gate(*args, **kwargs):
    kwargs["qualification_run_authority"] = QUALIFICATION_RUN
    return _production_evaluate_gate(*args, **kwargs)


def evaluate_gate_issues(*args, **kwargs):
    kwargs["qualification_run_authority"] = QUALIFICATION_RUN
    return _production_evaluate_gate_issues(*args, **kwargs)


def _evaluate_gate_with_validated_command_plans(*args, **kwargs):
    kwargs["qualification_run_authority"] = QUALIFICATION_RUN
    # This private evaluator fixture tests physical evidence and the state
    # machine; it does not establish production external-authority admission.
    with historical_physical_fixture_validation():
        return _production_evaluate_validated(*args, **kwargs)


def _make_qualified_premerge_authority(*args, **kwargs):
    return _production_make_qualified_premerge_authority(
        *args, QUALIFICATION_RUN, **kwargs
    )
from Scripts.reconstruction_gate_f.tests.test_prerequisite_dag import (
    candidate_for_subject,
)
from Scripts.reconstruction_gate_f.tests.test_command_compiler import ROOT, command_inputs


class BootstrapEvaluatorProfileTests(unittest.TestCase):
    def test_semantic_catalog_rejects_rebound_scenario_after_receipt_admission(self):
        claim = SimpleNamespace(layer=EvidenceLayer.XCODE_FOCUSED, artifact_outputs=(),
            receipt_outputs=(SimpleNamespace(command_id="xcode.focused.provider-pool", receipt_id="forged",
                                            scenario_id="scenario.caller-repeated"),))
        issues = _receipt_command_issues((claim,), LANE_C_COMMAND_AUTHORITIES_BY_ID,
                                       premerge_plan=None, postmerge_plan=None)
        self.assertEqual({issue.code for issue in issues}, {"evidence-receipt-scenario-mismatch"})

    def test_semantic_catalog_rejects_unknown_command_after_receipt_admission(self):
        # This pure semantic-stage fixture complements the public captured
        # source-command mutation, which is rejected at capture admission first.
        claim = SimpleNamespace(layer=EvidenceLayer.SOURCE_GOVERNANCE, artifact_outputs=(),
            receipt_outputs=(SimpleNamespace(command_id="fabricated.source-command", receipt_id="forged"),))
        issues = _receipt_command_issues((claim,), LANE_C_COMMAND_AUTHORITIES_BY_ID,
                                       premerge_plan=None, postmerge_plan=None)
        self.assertEqual({issue.code for issue in issues}, {"evidence-receipt-command-unknown"})

    def test_bootstrap_alone_never_closes_gate_f(self):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
        from Scripts.reconstruction_gate_f.prerequisite_dag import lane_c_command_authorities
        from Scripts.reconstruction_gate_f.gate_evaluator import _command_coverage_issues
        catalog = {c.command_id: c for c in lane_c_command_authorities(profile=CampaignProfile.BOOTSTRAP_VERIFIER)}
        claims = tuple(SimpleNamespace(layer=layer, receipt_outputs=(SimpleNamespace(
            command_id=command, receipt_type=role),)) for command, layer, role in (
                ("qualification.verify-bootstrap-fullsuite", EvidenceLayer.XCODE_FULL_CORETESTS, ReceiptType.TEST_RESULT),
                ("qualification.verify-bootstrap-products", EvidenceLayer.RELEASE_BUILD, ReceiptType.RELEASE_BUILD)))
        issues = _command_coverage_issues(claims, catalog, tuple(EvidenceLayer))
        self.assertEqual([i.code for i in issues], ["missing-required-command-receipt"])
        message = issues[0].message
        for required in ("xcode.focused.batch-scheduler", "native.normal", "signed-xpc.supervision",
                         "installed.task10-workflow", "evidence.t10c-current-source-adjudication",
                         "review.independent", "merge.prospective-tree", "postmerge.exact-tree-proof"):
            self.assertIn(required, message)
        self.assertNotIn("xcode.full-coretests", message)
        self.assertNotIn("release.build", message)
        # Removing one actual verifier names that missing execution precisely.
        missing = _command_coverage_issues(claims[:1], catalog, tuple(EvidenceLayer))[0].message
        self.assertIn("qualification.verify-bootstrap-products", missing)

    def test_public_evaluator_admits_profile_only_from_complete_compiler_inputs(self):
        from Scripts.reconstruction_gate_f.command_catalog import CampaignProfile
        from Scripts.reconstruction_gate_f.tests.test_prerequisite_dag import contract_for_specs
        contract = contract_for_specs(subject_kind=CandidateSubjectKind.PROSPECTIVE_MERGE,
            status_by_id={spec.node_id: PrerequisiteStatus.NOT_RUN for spec in DEFAULT_PREREQUISITE_SPECS
                          if spec.stage is not PrerequisiteStage.PREMERGE})
        inputs = command_inputs(profile=CampaignProfile.BOOTSTRAP_VERIFIER)
        inputs.update(bootstrap_artifact_root="/tmp/bootstrap", bootstrap_admission_path="/tmp/bootstrap/admission.json",
                      bootstrap_fullsuite_artifact_root="/tmp/campaign/fullsuite", bootstrap_products_artifact_root="/tmp/campaign/products")
        profile = CampaignProfile.BOOTSTRAP_VERIFIER
        scenarios = compile_scenario_catalog(contract.candidate)
        plan = compile_command_plan(contract.candidate, scenarios, repository_root=ROOT, inputs=inputs, profile=profile)
        integrated = LaneCIntegratedCommandPlanInput(plan, scenarios, ROOT, inputs,
            {t.command_id: t for t in command_templates(profile=profile)})
        dag, issues = compile_prerequisite_dag(contract)
        self.assertEqual(issues, ())
        with mock.patch("Scripts.reconstruction_gate_f.prerequisite_dag._repository_source_issues", return_value=()):
            decision = evaluate_gate(contract, dag, default_evidence_partial_order(), (), premerge_command_plan=integrated)
        self.assertNotIn("campaign-profile-mismatch", decision.issue_codes)
        self.assertNotIn("lane-c-command-plan-validation", decision.issue_codes)
        self.assertNotIn(decision.status, {DecisionStatus.COMPLETE, DecisionStatus.QUALIFIED_PREMERGE})
        for selected in (CampaignProfile.EXISTING, "bootstrap-verifier-campaign-v1"):
            rejected = evaluate_gate(contract, dag, default_evidence_partial_order(), (),
                                    premerge_command_plan=integrated, campaign_profile=selected)
            self.assertEqual(rejected.status, DecisionStatus.INVALID_EVIDENCE)
            self.assertIn("campaign-profile-mismatch", rejected.issue_codes)
        partial = dict(inputs); partial.pop("bootstrap_admission_path")
        rejected = evaluate_gate(contract, dag, default_evidence_partial_order(), (),
                                premerge_command_plan=replace(integrated, inputs=partial))
        self.assertIn("campaign-profile-mismatch", rejected.issue_codes)


def _eligible_command(spec: PrerequisiteNodeSpec):
    return next(
        command
        for command in LANE_C_COMMAND_AUTHORITIES
        if command.evidence_layer in spec.required_evidence_layers
        and set(command.command_groups) & set(spec.command_group_ids)
    )


def _command_for_layer(layer: EvidenceLayer):
    return next(
        command
        for command in LANE_C_COMMAND_AUTHORITIES
        if command.evidence_layer is layer
    )


def _default_status(
    subject_kind: CandidateSubjectKind,
    spec: PrerequisiteNodeSpec,
) -> PrerequisiteStatus:
    if subject_kind is CandidateSubjectKind.POST_MERGE:
        return PrerequisiteStatus.ACCEPTED
    return (
        PrerequisiteStatus.ACCEPTED
        if spec.stage is PrerequisiteStage.PREMERGE
        else PrerequisiteStatus.NOT_RUN
    )


class GateFixture:
    """Build a coherent source contract and its actual Lane A receipt inputs."""

    def __init__(
        self,
        root: Path,
        subject_kind: CandidateSubjectKind,
        *,
        status_by_id: dict[str, PrerequisiteStatus] | None = None,
    ) -> None:
        root.mkdir(parents=True, exist_ok=True)
        self.factory = PhysicalReceiptFactory(root)
        self._prepare_synthetic_source_and_product()
        self.candidate = self._owner_candidate(candidate_for_subject(subject_kind))
        self.prospective = (
            self._owner_candidate(candidate_for_subject(CandidateSubjectKind.PROSPECTIVE_MERGE))
            if subject_kind is CandidateSubjectKind.POST_MERGE
            else self.candidate
        )
        prospective_for_contract = (
            self.prospective
            if subject_kind is CandidateSubjectKind.POST_MERGE
            else None
        )
        self.compiler_identity_sha256 = sha("e")
        self._plans = {}
        self._owner_reports = {}
        self._derived_reports = {}
        self._owner_admissions = {}
        self._catalog_inputs_by_candidate: dict[str, dict[str, EvidenceReceiptInput]] = {}
        self.node_supplemental_inputs: dict[str, tuple[EvidenceReceiptInput, ...]] = {}
        self.premerge_validated_plan = self._compiled_plan(self.prospective)
        self.postmerge_validated_plan = (
            self._compiled_plan(self.candidate)
            if subject_kind is CandidateSubjectKind.POST_MERGE
            else None
        )
        self.premerge_scenario_plan = self.premerge_validated_plan.projection
        self.postmerge_scenario_plan = (
            None if self.postmerge_validated_plan is None
            else self.postmerge_validated_plan.projection
        )
        self._catalog_inputs_by_candidate[
            self.premerge_validated_plan.candidate_identity_sha256
        ] = self._catalog_receipts(self.prospective, self.premerge_validated_plan)
        if self.postmerge_validated_plan is not None:
            self._catalog_inputs_by_candidate[
                self.postmerge_validated_plan.candidate_identity_sha256
            ] = self._catalog_receipts(self.candidate, self.postmerge_validated_plan)
        subjects: list[PrerequisiteAuthority] = []
        self.node_inputs: dict[str, EvidenceReceiptInput] = {}
        status_by_id = status_by_id or {}
        for index, spec in enumerate(DEFAULT_PREREQUISITE_SPECS):
            status = status_by_id.get(
                spec.node_id,
                _default_status(subject_kind, spec),
            )
            claims_identity = status in {
                PrerequisiteStatus.RUNNING,
                PrerequisiteStatus.FAILED,
                PrerequisiteStatus.INVALID,
                PrerequisiteStatus.ACCEPTED,
            }
            basis = SourceContract(
                schema_version=1,
                candidate=self.candidate,
                prospective_candidate=prospective_for_contract,
                compiler_identity_sha256=self.compiler_identity_sha256,
                subjects=tuple(subjects),
            )
            identity = (
                prerequisite_identity_sha256(basis, spec)
                if claims_identity
                else None
            )
            if claims_identity and identity is None:
                raise AssertionError(f"missing identity authority for {spec.node_id}")
            receipt_sha256: str | None = None
            reason_code: str | None = None
            if status is PrerequisiteStatus.ACCEPTED:
                assert identity is not None
                command = _eligible_command(spec)
                candidate = (
                    self.candidate
                    if command.evidence_layer is EvidenceLayer.POST_MERGE
                    else self.prospective
                )
                receipt_input = self._make_receipt(
                    candidate,
                    command.evidence_layer,
                    receipt_id=spec.receipt_output_ids[0],
                    requirement_id=identity,
                    command_id=command.command_id,
                    artifact_id=spec.artifact_output_ids[0],
                    scenario_id=lane_c_receipt_scenario_ids(command)[0],
                )
                self.node_inputs[spec.node_id] = receipt_input
                supplemental: list[EvidenceReceiptInput] = []
                for required_layer in spec.required_evidence_layers:
                    if required_layer is command.evidence_layer:
                        continue
                    layer_command = next(
                        item
                        for item in LANE_C_COMMAND_AUTHORITIES
                        if item.evidence_layer is required_layer
                        and set(item.command_groups)
                        & set(spec.command_group_ids)
                    )
                    layer_candidate = (
                        self.candidate
                        if required_layer is EvidenceLayer.POST_MERGE
                        else self.prospective
                    )
                    supplemental.append(
                        self._make_receipt(
                            layer_candidate,
                            required_layer,
                            receipt_id=(
                                f"{spec.receipt_output_ids[0]}-{required_layer.value}"
                            ),
                            requirement_id=identity,
                            command_id=layer_command.command_id,
                            artifact_id=(
                                f"{spec.artifact_output_ids[0]}-{required_layer.value}"
                            ),
                            scenario_id=lane_c_receipt_scenario_ids(layer_command)[0],
                        )
                    )
                self.node_supplemental_inputs[spec.node_id] = tuple(supplemental)
                receipt_sha256 = receipt_input.receipt["canonical_sha256"]
            elif status in {PrerequisiteStatus.FAILED, PrerequisiteStatus.INVALID}:
                receipt_sha256 = sha(f"{index + 1:x}"[-1])
                reason_code = "terminal-rejection"
            elif status is PrerequisiteStatus.UNAVAILABLE:
                reason_code = "unavailable-authority"
            subjects.append(
                PrerequisiteAuthority(
                    subject_id=spec.node_id,
                    owner_id=spec.owner_id,
                    status=status,
                    identity_sha256=identity,
                    receipt_sha256=receipt_sha256,
                    reason_code=reason_code,
                )
            )
        contract, issues = make_source_contract(
            self.candidate,
            prospective_candidate=prospective_for_contract,
            compiler_identity_sha256=self.compiler_identity_sha256,
            subjects=subjects,
        )
        if issues or contract is None:
            raise AssertionError(issues)
        self.contract = contract
        self.dag = self.compile(contract)
        self.baseline_inputs = {
            layer: self._catalog_input(
                self.candidate if layer is EvidenceLayer.POST_MERGE else self.prospective,
                _command_for_layer(layer).command_id,
            )
            for layer in EvidenceLayer
        }
        baseline_command_ids = {
            receipt.context.expected_command_id
            for receipt in self.baseline_inputs.values()
        }
        catalog_plans = [(self.prospective, self.premerge_validated_plan)]
        if self.postmerge_validated_plan is not None:
            catalog_plans.append((self.candidate, self.postmerge_validated_plan))
        self.catalog_inputs = tuple(
            receipt
            for _, plan in catalog_plans
            for command_id, receipt in self._catalog_inputs_by_candidate[
                plan.candidate_identity_sha256
            ].items()
            if command_id not in baseline_command_ids
            and (plan is self.premerge_validated_plan
                 or receipt.context.expected_layer is EvidenceLayer.POST_MERGE)
        )
        self._persisted_premerge_authority = None
        if subject_kind is CandidateSubjectKind.POST_MERGE:
            validated, issues = compile_evidence_claims(
                default_evidence_partial_order(),
                expected_candidate=self.candidate,
                expected_qualification_run=QUALIFICATION_RUN,
                expected_premerge_candidate=self.prospective,
                claims=self.premerge_claims(),
            )
            if issues or validated is None:
                raise AssertionError(issues)
            self._persisted_premerge_authority = _make_qualified_premerge_authority(
                self.contract,
                self.dag,
                default_evidence_partial_order(),
                validated,
                self.premerge_validated_plan,
            )
        self._pristine_contract = self.contract
        self._pristine_dag = self.dag
        self._pristine_node_inputs = dict(self.node_inputs)
        self._pristine_node_supplemental_inputs = dict(
            self.node_supplemental_inputs
        )

    def _prepare_synthetic_source_and_product(self):
        """Real closed export/product bytes; no native execution is claimed."""
        repository = source_fixture.SourceRepository(self.factory.root / "synthetic-source-repository")
        repository.write("MacScope/project.yml", "name: SyntheticGateFixture\n")
        repository.write("MacScope/Tests/CoreTests/FixtureTests.swift",
                         "import XCTest\nfinal class FixtureTests: XCTestCase { func testFixture() {} }\n")
        # The empty reviewed skip list is still independently checked against
        # the real exported Swift fixture before full-suite projection.
        repository.write("docs/qualification/skip-allowlist.json", json.dumps({
            "schemaVersion": 2, "countingRule": "direct-and-file-local-transitive-swift-test-methods",
            "knownGap": "synthetic fixture, no cross-file skip assumptions", "entries": []}) + "\n")
        repository.git("add", ".")
        repository.git("commit", "-m", "Bind synthetic qualification fixture inputs")
        self._source_commit = repository.git("rev-parse", "HEAD")
        self._source_tree = repository.git("rev-parse", "HEAD^{tree}")
        self._integration_ref = "refs/remotes/gitfox-local/feature/task11-local-premerge-current"
        repository.git("update-ref", self._integration_ref, self._source_commit)
        self._source_export = self.factory.root / "synthetic-source-export"
        create_export(repository.root, self._source_export, self._integration_ref)
        self._product = self.factory.root / "synthetic-product/MacScope.app"
        executable = self._product / "Contents/MacOS/MacScope"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"synthetic non-executable MacScope fixture\n")
        executable.chmod(0o755)
        resources = self._product / "Contents/Resources"
        resources.mkdir()
        (resources / "MacScopeBuildProvenance.json").write_bytes(b'{"synthetic":true}\n')
        (self._product / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.macscope.MacScope", "CFBundleExecutable": "MacScope"}))
        self._product_identity = _bundle_identity(self._product, executable)

    def _owner_candidate(self, candidate):
        digest = hashlib.sha256(b"candidate-ai-agent-worker-v1\n").hexdigest()
        def bind(items):
            return tuple(replace(item, sha256=digest)
                         if item.identity_id in {"ai-agent-worker", "native-decompiler"}
                         else item for item in items)
        return replace(candidate, source=replace(candidate.source, commit=self._source_commit,
            tree=self._source_tree, dirty=False,
            project_yml_sha256=hashlib.sha256((self._source_export / "MacScope/project.yml").read_bytes()).hexdigest()),
            application=replace(candidate.application,
            bundle_identifier=self._product_identity["bundle_identifier"],
            bundle_sha256=self._product_identity["content_sha256"],
            closed_tree_sha256=self._product_identity["closed_tree_sha256"],
            executable_sha256=self._product_identity["executable_sha256"],
            embedded_executables=bind(candidate.application.embedded_executables),
            qualification_executables=bind(candidate.application.qualification_executables)))

    def _prepare_owner_reports(self, candidate, inputs):
        """Materialize each owner's synthetic reports once, before freezing P.

        Node receipts reuse these bytes and their retained capture. Re-emission
        must not rewrite a shared report and invalidate an earlier receipt.
        """
        specifications = (
            ("installed.task10-workflow", "_installed_workflow_request", {}),
            ("installed.accessibility-semantics", "_installed_accessibility_request", {}),
            ("reconstruction.deterministic-evidence", "_deterministic_evidence_request", {}),
            *((key, "_signed_xpc_request", {"command_id": key}) for key in (
                "signed-xpc.complete-truncated-content", "signed-xpc.error-cancellation", "signed-xpc.supervision")),
            ("stress.reconstruction-authority-races", "_stress_request", {}),
        )
        digest = candidate_identity_sha256(candidate)
        for command_id, method, arguments in specifications:
            fixture = owner_fixture.GateFExecutorReceiptTests(methodName="runTest")
            fixture.setUp()
            fixture.temporary.cleanup()
            fixture.root = self.factory.root / digest / command_id
            fixture.root.mkdir(parents=True)
            fixture.candidate = candidate
            request = getattr(fixture, method)(**arguments)
            self._owner_reports[digest, command_id] = (fixture, request)
            for artifact in request["artifacts"]:
                declaration = artifact["command_output"].split(":", 1)[1]
                match = re.match(r"^@([a-z0-9_]+)@(.*)$", declaration)
                if match:
                    actual = str(fixture.root / artifact["relative_path"])
                    suffix = match[2]
                    assert actual.endswith(suffix)
                    inputs[match[1]] = actual[:-len(suffix)] if suffix else actual
        inputs["authority_stress_predecessor_observations"] = str(
            self.factory.root / digest / "predecessors.json")
        inputs.update(source_export_root=str(self._source_export), integration_ref=self._integration_ref,
                      hosted_governance_runner=str(self._source_export / "Scripts/ci/run_hosted_governance.py"))

    def _compiled_plan(self, candidate):
        scenarios = compile_scenario_catalog(candidate)
        inputs = command_inputs()
        inputs.update(qualification_run_id=QUALIFICATION_RUN.run_id,
                      qualification_run_nonce=QUALIFICATION_RUN.nonce)
        if candidate is self.prospective:
            self._prepare_owner_reports(candidate, inputs)
        else:
            inputs = dict(self._plans[candidate_identity_sha256(self.prospective)].inputs)
        plan = compile_command_plan(
            candidate,
            scenarios,
            repository_root=ROOT,
            inputs=inputs,
            templates=command_templates(),
        )
        projection, issues = validate_lane_c_command_plan(
            plan,
            expected_candidate_identity_sha256=candidate_identity_sha256(candidate),
        )
        if issues or projection is None:
            raise AssertionError(issues)
        self._plans[candidate_identity_sha256(candidate)] = LaneCIntegratedCommandPlanInput(
            plan, scenarios, ROOT, inputs, {item.command_id: item for item in command_templates()})
        if candidate is self.prospective:
            self._prepare_derived_outputs(candidate, plan)
        records = {
            record.command_id: ValidatedLaneCCommandRecord(
                command_id=record.command_id,
                evidence_layer=record.evidence_layer,
                host=record.host.value,
                execution_mode=record.execution_mode.value,
                argv_sha256=canonical_sha256(list(record.argv)),
                working_directory_sha256=canonical_sha256(record.working_directory),
                environment_sha256=canonical_sha256(
                    [list(item) for item in record.environment]
                ),
                generated_artifacts=record.generated_artifacts,
                generated_logs=record.generated_logs,
                prerequisite_ids=record.prerequisite_ids,
                receipt_fields=record.receipt_fields,
            )
            for record in plan.commands
        }
        return ValidatedLaneCCommandPlan(
            candidate_identity_sha256=candidate_identity_sha256(candidate),
            command_plan_sha256=command_plan_sha256(plan),
            scenario_catalog_sha256=scenario_catalog_sha256(scenarios),
            command_record_sha256_by_id={
                record.command_id: canonical_sha256(record) for record in plan.commands
            },
            command_records_by_id=records,
            raw_command_records_by_id={record.command_id: record for record in plan.commands},
            projection=projection,
        )

    def _catalog_receipts(self, candidate, plan):
        receipts: dict[str, EvidenceReceiptInput] = {}

        def build(command_id: str) -> EvidenceReceiptInput:
            existing = receipts.get(command_id)
            if existing is not None:
                return existing
            record = plan.command_records_by_id[command_id]
            if plan is self.postmerge_validated_plan and record.evidence_layer is not EvidenceLayer.POST_MERGE:
                receipts[command_id] = self._catalog_input(self.prospective, command_id)
                return receipts[command_id]
            def dependency_receipt(dependency_id: str) -> EvidenceReceiptInput:
                dependency = plan.command_records_by_id[dependency_id]
                if (
                    plan is self.postmerge_validated_plan
                    and dependency.evidence_layer is not EvidenceLayer.POST_MERGE
                ):
                    return self._catalog_input(self.prospective, dependency_id)
                return build(dependency_id)
            prerequisites = tuple(
                CommandPrerequisiteExpectation(
                    command_id=dependency_id,
                    receipt_id=dependency_receipt(
                        dependency_id
                    ).context.expected_receipt_id,
                    canonical_sha256=dependency_receipt(
                        dependency_id
                    ).receipt["canonical_sha256"],
                    qualification_run_id=QUALIFICATION_RUN.run_id,
                    qualification_run_nonce=QUALIFICATION_RUN.nonce,
                )
                for dependency_id in record.prerequisite_ids
                if dependency_id != "candidate-identity-accepted"
            )
            receipts[command_id] = self._make_receipt(
                candidate,
                record.evidence_layer,
                receipt_id=f"receipt-catalog-{command_id}",
                requirement_id=f"requirement-catalog-{command_id}",
                command_id=command_id,
                scenario_id=lane_c_receipt_scenario_ids(
                    LANE_C_COMMAND_AUTHORITIES_BY_ID[command_id]
                )[0],
                plan=plan,
                prerequisites=prerequisites,
                selector_ids=(
                    lane_c_receipt_scenario_ids(
                        LANE_C_COMMAND_AUTHORITIES_BY_ID[command_id]
                    )
                    if len(
                        lane_c_receipt_scenario_ids(
                            LANE_C_COMMAND_AUTHORITIES_BY_ID[command_id]
                        )
                    )
                    > 1
                    or command_id in EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS
                    else None
                ),
            )
            return receipts[command_id]

        for command_id in plan.command_records_by_id:
            build(command_id)
        return receipts

    def _catalog_input(self, candidate, command_id: str) -> EvidenceReceiptInput:
        return self._catalog_inputs_by_candidate[
            candidate_identity_sha256(candidate)
        ][command_id]

    def _prepare_derived_outputs(self, candidate, plan):
        for record in plan.commands:
            if record.command_id not in CAPTURE_DERIVED_REPORT_COMMANDS:
                continue
            directory = self.factory.root / candidate_identity_sha256(candidate) / record.command_id
            directory.mkdir(parents=True, exist_ok=True)
            role = capture_derived_report_receipt_type(record.command_id)
            source_owner = role is ReceiptType.ARTIFACT_MANIFEST
            if not source_owner:
                mode = record.argv[record.argv.index("--mode") + 1]
                write_canonical_json(directory / "qualification-receipt.json", {
                    "synthetic_native_build_observation": True, "source_commit": candidate.source.commit,
                    "source_tree": candidate.source.tree, "mode": mode})
                shutil.copytree(self._source_export, directory / "source")
                configuration = "Release" if mode in {"release", "full-test"} else "Debug"
                shutil.copytree(self._product,
                    directory / "DerivedData/Build/Products" / configuration / "MacScope.app")
                if role is ReceiptType.TEST_RESULT:
                    result = directory / ("FocusedTestResults.xcresult" if mode == "focused-test" else "TestResults.xcresult")
                    result.mkdir()
                    scope = record.argv[record.argv.index("--only-testing") + 1] if mode == "focused-test" else "CoreTests"
                    pieces = scope.split("/")
                    suite = pieces[1] if len(pieces) >= 2 else "FixtureTests"
                    method = pieces[2] if len(pieces) == 3 else "testFixture"
                    write_canonical_json(result / "SyntheticSummary.json", dict(result="Passed", totalTestCount=1,
                        passedTests=1, failedTests=0, skippedTests=0, expectedFailures=0))
                    write_canonical_json(result / "SyntheticTestNodes.json", {"testNodes": [{
                        "nodeType": "Unit test bundle", "name": "CoreTests", "children": [{
                            "nodeType": "Test Suite", "name": suite, "children": [{
                                "nodeType": "Test Case", "name": method, "nodeIdentifier": f"{suite}/{method}()",
                                "result": "Passed", "children": []}]}]}]})
            sources, stdout = [], b""
            for index, declaration in enumerate(record.generated_artifacts):
                kind = ArtifactKind.JSON
                if declaration.startswith("/"):
                    path = Path(declaration)
                elif declaration.startswith("receipt-derived-path:"):
                    path = directory / declaration.removeprefix("receipt-derived-path:")
                    if path.is_dir():
                        kind = ArtifactKind.APP_BUNDLE
                else:
                    marker = declaration.removeprefix("stdout-path:")
                    if marker == "MACSCOPE_QUALIFICATION_RECEIPT":
                        path = directory / "qualification-receipt.json"
                    elif marker == "MACSCOPE_TEST_RESULTS":
                        path = result
                        kind = ArtifactKind.XCRESULT
                    elif marker == "MACSCOPE_COVERAGE_JSON":
                        path = directory / "coverage.json"
                        write_canonical_json(path, {"synthetic_coverage": True})
                    else:
                        raise AssertionError(declaration)
                    stdout += (marker + "=" + str(path) + "\n").encode()
                sources.append(OwnerArtifactSource("original-" + str(index), str(path.relative_to(self.factory.root)),
                    kind, "application/json", "artifact:" + declaration))
            for index, declaration in enumerate(record.generated_logs):
                path = directory / ("captured-owner-log-" + str(index))
                path.write_bytes(stdout)
                sources.append(OwnerArtifactSource("original-log-" + str(index), str(path.relative_to(self.factory.root)),
                    ArtifactKind.LAUNCH_LOG, "text/plain", "log:" + declaration))
            self._derived_reports[candidate_identity_sha256(candidate), record.command_id] = (directory, tuple(sources), stdout)

    def _captured_derived_receipt(self, candidate, command_id, prerequisites, **kwargs):
        key = candidate_identity_sha256(candidate), command_id
        directory, sources, stdout = self._derived_reports[key]
        integrated = self._plans[key[0]]
        record = next(item for item in integrated.plan.commands if item.command_id == command_id)
        resolved = resolve_command_record(record, prerequisite_receipts=prerequisites, qualification_run=QUALIFICATION_RUN)
        retained = self._owner_admissions.get(key)
        if retained is None:
            execution = command_execution.ExecutionAdmission(candidate, integrated, QUALIFICATION_RUN,
                candidate.source.commit, candidate.source.tree, prerequisites)
            capture_id = "synthetic-" + command_id
            intent = dict(capture_id=capture_id, run_id=QUALIFICATION_RUN.run_id, nonce=QUALIFICATION_RUN.nonce,
                candidate_identity_sha256=record.candidate_identity_sha256,
                command_plan_sha256=command_plan_sha256(integrated.plan), command_record_sha256=canonical_sha256(record),
                command_id=command_id, scenario_id=record.scenario_ids[0] if record.scenario_ids else command_id,
                producer_source_commit=candidate.source.commit, producer_source_tree=candidate.source.tree,
                argv=list(resolved.record.argv), working_directory=record.working_directory,
                environment=[list(item) for item in record.environment], effective_environment=[list(item) for item in record.environment],
                environment_policy_id="gatef-host-environment-v1", started_at_unix_ms=0,
                prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in prerequisites]))
            frames = [dict(sequence=0, stream="stdout", data_base64=base64.b64encode(stdout).decode(),
                raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest())]
            terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                ended_at_unix_ms=3000, termination_kind="exited", exit_code=0, signal=None,
                stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(), stderr_length=0,
                stderr_sha256=hashlib.sha256(b"").hexdigest())
            payload = command_capture.serialize_capture(dict(schema_version=2, intent=intent, output_frames=frames,
                terminal=terminal, runtime_resolution=to_primitive(resolved.runtime_resolution),
                process_observation=dict(state="launched", pid=123, spawn_observed_monotonic_ns=1,
                    os_start_time=dict(state="unavailable", reason="synthetic evaluator native-observation fixture"))))
            path = directory / "capture.json"
            path.write_bytes(payload)
            retained = command_execution.ExecutionCapture(execution, command_id, intent["scenario_id"], capture_id,
                record.environment, path, hashlib.sha256(payload).hexdigest())
        else:
            retained = retained.capture
        assert retained.admission.admitted_predecessors == prerequisites
        receipt_id = kwargs["receipt_id"]
        unique_sources = tuple(replace(source, artifact_id=(kwargs["artifact_id"]
            if index == 0 and kwargs.get("artifact_id") else f"{receipt_id}-{index}"))
            for index, source in enumerate(sources))
        admission = ExecutorReceiptAdmission(retained, self.factory.root, receipt_id, kwargs["requirement_id"],
            QualificationPhase.PREMERGE, capture_derived_report_receipt_type(command_id),
            kwargs.get("artifact_root_id", "synthetic-qualification-root"),
            capture_execution_report_artifact_id(receipt_id), unique_sources,
            dict(executor_id="synthetic-qualification-observer", host=record.host.value,
                 platform="linux" if command_id.startswith("source.") else "macos",
                 architecture="x86_64" if command_id.startswith("source.") else "arm64", os_version="synthetic"),
            qualified_premerge_authority_sha256=kwargs.get("qualified_premerge_authority_sha256"))
        report_path = self.factory.root / ("." + admission.execution_report_artifact_id + ".json")
        if not report_path.exists():
            publish_capture_execution_report(admission)
        # Each receipt gets its own descriptor identity; original directories
        # remain unchanged and are reobserved during every later validation.
        from Scripts.reconstruction_gate_f.qualification_receipt_adapter import qualification_artifact_projection_sources
        projected = qualification_artifact_projection_sources(admission)
        if any(source.kind in {ArtifactKind.APP_BUNDLE, ArtifactKind.XCRESULT}
               and not (self.factory.root / source.relative_path).exists() for source in projected):
            admission = publish_qualification_artifact_projections(admission)
        else:
            admission = replace(admission, owner_artifacts=projected)
        self._owner_admissions.setdefault(key, admission)
        receipt, context = emit_executor_receipt(build_executor_request(admission), artifact_root=self.factory.root,
            qualification_run_authority=QUALIFICATION_RUN, admission=admission)
        return EvidenceReceiptInput(receipt=receipt, context=context)

    def _captured_owner_receipt(self, candidate, command_id, prerequisites, **kwargs):
        key = candidate_identity_sha256(candidate), command_id
        admission = self._owner_admissions.get(key)
        if admission is None:
            fixture, old = self._owner_reports[key]
            integrated = self._plans[key[0]]
            record = next(item for item in integrated.plan.commands if item.command_id == command_id)
            resolved = resolve_command_record(record, prerequisite_receipts=prerequisites,
                                              qualification_run=QUALIFICATION_RUN)
            predecessor_mappings = [asdict(item) for item in prerequisites]
            report_source = next(item for item in old["artifacts"]
                                 if item["artifact_id"] == old["execution_report_artifact_id"])
            report_path = fixture.root / report_source["relative_path"]
            report = load_canonical_json(report_path)
            report["predecessor_observations_sha256"] = canonical_sha256(predecessor_mappings)
            write_canonical_json(report_path, report)
            if command_id == "stress.reconstruction-authority-races":
                write_canonical_json(Path(integrated.inputs["authority_stress_predecessor_observations"]),
                                     predecessor_mappings)
            def resolve(declaration):
                return re.sub(r"@([a-z0-9_]+)@", lambda match: integrated.inputs[match[1]], declaration)
            sources = tuple(OwnerArtifactSource(item["artifact_id"], item["relative_path"],
                ArtifactKind(item["kind"]), item["media_type"], resolve(item["command_output"]))
                for item in old["artifacts"])
            stdout_json = [source for source in sources if source.command_output.startswith("artifact:stdout-json:")]
            stdout = ((fixture.root / stdout_json[0].relative_path).read_bytes() if stdout_json else
                      b"".join((source.command_output.removeprefix("artifact:stdout-path:") + "=" +
                          str(fixture.root / source.relative_path) + "\n").encode()
                          for source in sources if source.command_output.startswith("artifact:stdout-path:")))
            for source in sources:
                if source.command_output.startswith("log:executor-captured:"):
                    (fixture.root / source.relative_path).write_bytes(stdout)
            execution = command_execution.ExecutionAdmission(candidate, integrated, QUALIFICATION_RUN,
                candidate.source.commit, candidate.source.tree, prerequisites)
            capture_id = "synthetic-" + command_id
            intent = dict(capture_id=capture_id, run_id=QUALIFICATION_RUN.run_id, nonce=QUALIFICATION_RUN.nonce,
                candidate_identity_sha256=record.candidate_identity_sha256,
                command_plan_sha256=command_plan_sha256(integrated.plan), command_record_sha256=canonical_sha256(record),
                command_id=command_id, scenario_id=record.scenario_ids[0] if record.scenario_ids else command_id,
                producer_source_commit=candidate.source.commit, producer_source_tree=candidate.source.tree,
                argv=list(resolved.record.argv), working_directory=record.working_directory,
                environment=[list(item) for item in record.environment], effective_environment=[list(item) for item in record.environment],
                environment_policy_id="gatef-host-environment-v1",
                prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in prerequisites]),
                started_at_unix_ms=0)
            frames = [dict(sequence=0, stream="stdout", data_base64=base64.b64encode(stdout).decode(),
                           raw_length=len(stdout), raw_sha256=hashlib.sha256(stdout).hexdigest())]
            terminal = dict(intent_sha256=canonical_sha256(intent), frames_sha256=canonical_sha256(frames),
                ended_at_unix_ms=max(3000, report["ended_at_unix_ms"]), termination_kind="exited", exit_code=0,
                signal=None, stdout_length=len(stdout), stdout_sha256=hashlib.sha256(stdout).hexdigest(),
                stderr_length=0, stderr_sha256=hashlib.sha256(b"").hexdigest())
            payload = command_capture.serialize_capture(dict(schema_version=2, intent=intent, output_frames=frames,
                terminal=terminal, runtime_resolution=to_primitive(resolved.runtime_resolution),
                process_observation=dict(state="launched", pid=123, spawn_observed_monotonic_ns=1,
                    os_start_time=dict(state="unavailable", reason="synthetic evaluator unit fixture"))))
            capture_path = fixture.root / "capture.json"
            capture_path.write_bytes(payload)
            captured = command_execution.ExecutionCapture(execution, command_id, intent["scenario_id"], capture_id,
                record.environment, capture_path, hashlib.sha256(payload).hexdigest())
            constituents = tuple(old["constituents"])
            authority = old["authority"]
            if old["receipt_type"] in {ReceiptType.SIGNED_XPC.value, ReceiptType.INSTALLED_WORKFLOW.value}:
                # Native selector counts remain in the unchanged physical
                # result; receipt constituents enumerate semantic scenarios.
                semantic_ids = record.scenario_ids or (record.command_id,)
                constituents = tuple(dict(constituents[0], selector_id=value) for value in semantic_ids)
                authority = dict(authority, selector_count=len(semantic_ids))
            elif command_id == "reconstruction.deterministic-evidence":
                semantic_ids = record.scenario_ids
                constituents = tuple(dict(constituents[0], selector_id=value) for value in semantic_ids)
                authority = dict(authority, expected_selector_count=len(semantic_ids),
                                 executed_selector_count=len(semantic_ids), passed_selector_count=len(semantic_ids))
            admission = ExecutorReceiptAdmission(captured, fixture.root, old["receipt_id"], old["requirement_id"],
                QualificationPhase(old["qualification_phase"]), ReceiptType(old["receipt_type"]), old["artifact_root_id"],
                old["execution_report_artifact_id"], sources, old["executor"], constituents, authority)
            self._owner_admissions[key] = admission
        assert admission.capture.admission.admitted_predecessors == prerequisites
        # Distinct receipt identities share immutable physical bytes, while all
        # artifact identities remain globally unique within an evidence claim.
        receipt_id = kwargs["receipt_id"]
        ids = {source.artifact_id: f"{receipt_id}-{index}" for index, source in enumerate(admission.owner_artifacts)}
        if kwargs.get("artifact_id") is not None:
            ids[admission.owner_artifacts[0].artifact_id] = kwargs["artifact_id"]
        constituents = tuple(dict(item, artifact_ids=[ids[value] for value in item["artifact_ids"]])
                             for item in admission.constituents)
        admission = replace(admission, receipt_id=receipt_id, requirement_id=kwargs["requirement_id"],
            artifact_root_id=kwargs.get("artifact_root_id", admission.artifact_root_id),
            execution_report_artifact_id=ids[admission.execution_report_artifact_id],
            owner_artifacts=tuple(replace(source, artifact_id=ids[source.artifact_id]) for source in admission.owner_artifacts),
            constituents=constituents)
        request = build_executor_request(admission)
        receipt, context = emit_executor_receipt(request, artifact_root=admission.artifact_root,
            qualification_run_authority=QUALIFICATION_RUN, admission=admission)
        return EvidenceReceiptInput(receipt=receipt, context=context)

    def _make_receipt(self, candidate, layer, *, command_id: str, plan=None,
                      prerequisites=None, **kwargs) -> EvidenceReceiptInput:
        plan = plan or (
            self.postmerge_validated_plan
            if layer is EvidenceLayer.POST_MERGE
            else self.premerge_validated_plan
        )
        record = plan.command_records_by_id[command_id]
        if prerequisites is None:
            def dependency_input(dependency_id: str) -> EvidenceReceiptInput:
                dependency = plan.command_records_by_id[dependency_id]
                dependency_candidate = (
                    self.candidate
                    if dependency.evidence_layer is EvidenceLayer.POST_MERGE
                    else self.prospective
                )
                return self._catalog_input(dependency_candidate, dependency_id)

            prerequisites = tuple(
                CommandPrerequisiteExpectation(
                    command_id=dependency_id,
                    receipt_id=dependency_input(
                        dependency_id
                    ).context.expected_receipt_id,
                    canonical_sha256=dependency_input(
                        dependency_id
                    ).receipt["canonical_sha256"],
                    qualification_run_id=QUALIFICATION_RUN.run_id,
                    qualification_run_nonce=QUALIFICATION_RUN.nonce,
                )
                for dependency_id in record.prerequisite_ids
                if dependency_id != "candidate-identity-accepted"
            )
        authority = CommandAuthorityExpectation(
            host=record.host,
            execution_mode=record.execution_mode,
            argv_sha256=record.argv_sha256,
            working_directory_sha256=record.working_directory_sha256,
            environment_sha256=record.environment_sha256,
            generated_artifacts=record.generated_artifacts,
            generated_logs=record.generated_logs,
            prerequisite_receipts=tuple(prerequisites),
        )
        integrated = self._plans[candidate_identity_sha256(candidate)]
        static_record = next(item for item in integrated.plan.commands if item.command_id == command_id)
        resolved = resolve_command_record(static_record, prerequisite_receipts=tuple(prerequisites),
                                          qualification_run=QUALIFICATION_RUN)
        authority = replace(authority, argv_sha256=canonical_sha256(list(resolved.record.argv)))
        if (candidate_identity_sha256(candidate), command_id) in self._derived_reports:
            return self._captured_derived_receipt(candidate, command_id, tuple(prerequisites), **kwargs)
        if (candidate_identity_sha256(candidate), command_id) in self._owner_reports:
            return self._captured_owner_receipt(candidate, command_id, tuple(prerequisites), **kwargs)
        command_scenarios = lane_c_receipt_scenario_ids(
            LANE_C_COMMAND_AUTHORITIES_BY_ID[command_id]
        )
        if (
            len(command_scenarios) > 1
            or command_id in EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS
        ):
            kwargs.setdefault(
                "selector_ids",
                command_scenarios,
            )
        if command_id == "task8.signed-worker-parity":
            kwargs.setdefault("service_identity_id", "ai-agent-worker")
        if command_id in INDEPENDENT_REVIEW_COMMAND_LENSES:
            kwargs["selector_ids"] = (
                INDEPENDENT_REVIEW_COMMAND_LENSES[command_id],
            )
        elif command_id == "review.independent":
            kwargs["selector_ids"] = tuple(INDEPENDENT_REVIEW_COMMAND_LENSES)
        return self.factory.make(
            candidate,
            layer,
            command_id=command_id,
            command_plan_sha256=plan.command_plan_sha256,
            command_record_sha256=plan.command_record_sha256_by_id[command_id],
            command_authority=authority,
            runtime_resolution=to_primitive(resolved.runtime_resolution),
            **kwargs,
        )

    @staticmethod
    def compile(contract: SourceContract) -> PrerequisiteDAG:
        dag, issues = compile_prerequisite_dag(contract)
        if issues or dag is None:
            raise AssertionError(issues)
        return dag

    def claims(
        self,
        *,
        layers: tuple[EvidenceLayer, ...],
        node_inputs: dict[str, EvidenceReceiptInput] | None = None,
    ) -> tuple[EvidenceClaim, ...]:
        node_inputs = self.node_inputs if node_inputs is None else node_inputs
        inputs_by_layer: dict[EvidenceLayer, list[EvidenceReceiptInput]] = {
            layer: [self.baseline_inputs[layer]] for layer in layers
        }
        def belongs_to_claim_candidate(
            layer: EvidenceLayer,
            receipt_input: EvidenceReceiptInput,
        ) -> bool:
            expected_candidate = (
                self.candidate
                if layer is EvidenceLayer.POST_MERGE
                else self.prospective
            )
            return receipt_input.context.expected_candidate == expected_candidate
        for receipt_input in node_inputs.values():
            layer = receipt_input.context.expected_layer
            if layer in inputs_by_layer and belongs_to_claim_candidate(
                layer, receipt_input
            ):
                inputs_by_layer[layer].append(receipt_input)
        for supplemental_inputs in self.node_supplemental_inputs.values():
            for receipt_input in supplemental_inputs:
                layer = receipt_input.context.expected_layer
                if layer in inputs_by_layer and belongs_to_claim_candidate(
                    layer, receipt_input
                ):
                    inputs_by_layer[layer].append(receipt_input)
        for receipt_input in self.catalog_inputs:
            layer = receipt_input.context.expected_layer
            if layer in inputs_by_layer and belongs_to_claim_candidate(
                layer, receipt_input
            ):
                inputs_by_layer[layer].append(receipt_input)
        return tuple(
            EvidenceClaim(layer=layer, receipt_inputs=tuple(inputs_by_layer[layer]))
            for layer in layers
        )

    def premerge_claims(self) -> tuple[EvidenceClaim, ...]:
        return self.claims(
            layers=tuple(
                layer for layer in EvidenceLayer if layer is not EvidenceLayer.POST_MERGE
            )
        )

    def all_claims(self) -> tuple[EvidenceClaim, ...]:
        return self.claims(layers=tuple(EvidenceLayer))

    def bind_persisted_premerge_authority(
        self,
        claims: tuple[EvidenceClaim, ...],
    ) -> tuple[tuple[EvidenceClaim, ...], object | None]:
        if self.candidate.subject_kind is not CandidateSubjectKind.POST_MERGE:
            return claims, None
        self.contract = self._pristine_contract
        self.dag = self._pristine_dag
        self.node_inputs = dict(self._pristine_node_inputs)
        self.node_supplemental_inputs = dict(
            self._pristine_node_supplemental_inputs
        )
        pristine_claims = self.all_claims()
        premerge_only_claims = self.premerge_claims()
        authority = self._persisted_premerge_authority
        if authority is None:
            raise AssertionError("postmerge fixture omitted persisted premerge authority")
        if claims != pristine_claims:
            # Negative tests intentionally mutate, omit, or cross-bind raw
            # evidence.  Never replace that caller-owned input with a freshly
            # synthesized graph: the evaluator must see the exact defect.
            return claims, authority
        previous_by_id = {
            subject.subject_id: subject for subject in self.contract.subjects
        }
        subjects: list[PrerequisiteAuthority] = []
        node_inputs: dict[str, EvidenceReceiptInput] = {}
        supplemental_inputs: dict[str, tuple[EvidenceReceiptInput, ...]] = {}
        for spec in DEFAULT_PREREQUISITE_SPECS:
            previous = previous_by_id[spec.node_id]
            basis = SourceContract(
                schema_version=1,
                candidate=self.candidate,
                prospective_candidate=self.prospective,
                compiler_identity_sha256=self.compiler_identity_sha256,
                subjects=tuple(subjects),
            )
            identity = (
                prerequisite_identity_sha256(basis, spec)
                if previous.identity_sha256 is not None
                else None
            )
            receipt_sha256 = previous.receipt_sha256
            if previous.status is PrerequisiteStatus.ACCEPTED:
                assert identity is not None
                if spec.stage is PrerequisiteStage.PREMERGE:
                    node_inputs[spec.node_id] = self.node_inputs[spec.node_id]
                    supplemental_inputs[spec.node_id] = (
                        self.node_supplemental_inputs[spec.node_id]
                    )
                    subjects.append(
                        replace(
                            previous,
                            identity_sha256=identity,
                            receipt_sha256=receipt_sha256,
                        )
                    )
                    continue
                command = _eligible_command(spec)
                candidate = (
                    self.candidate
                    if command.evidence_layer is EvidenceLayer.POST_MERGE
                    else self.prospective
                )
                sealed_authority = (
                    authority.canonical_sha256
                    if spec.stage in {
                        PrerequisiteStage.MERGE,
                        PrerequisiteStage.POSTMERGE,
                    }
                    else None
                )
                receipt_input = self._make_receipt(
                    candidate,
                    command.evidence_layer,
                    receipt_id=spec.receipt_output_ids[0],
                    requirement_id=identity,
                    command_id=command.command_id,
                    artifact_id=spec.artifact_output_ids[0],
                    scenario_id=lane_c_receipt_scenario_ids(command)[0],
                    qualified_premerge_authority_sha256=sealed_authority,
                )
                node_inputs[spec.node_id] = receipt_input
                receipt_sha256 = receipt_input.receipt["canonical_sha256"]
                supplements: list[EvidenceReceiptInput] = []
                for required_layer in spec.required_evidence_layers:
                    if required_layer is command.evidence_layer:
                        continue
                    layer_command = next(
                        item
                        for item in LANE_C_COMMAND_AUTHORITIES
                        if item.evidence_layer is required_layer
                        and set(item.command_groups)
                        & set(spec.command_group_ids)
                    )
                    layer_candidate = (
                        self.candidate
                        if required_layer is EvidenceLayer.POST_MERGE
                        else self.prospective
                    )
                    supplements.append(
                        self._make_receipt(
                            layer_candidate,
                            required_layer,
                            receipt_id=(
                                f"{spec.receipt_output_ids[0]}-{required_layer.value}"
                            ),
                            requirement_id=identity,
                            command_id=layer_command.command_id,
                            artifact_id=(
                                f"{spec.artifact_output_ids[0]}-{required_layer.value}"
                            ),
                            scenario_id=lane_c_receipt_scenario_ids(layer_command)[0],
                            qualified_premerge_authority_sha256=sealed_authority,
                        )
                    )
                supplemental_inputs[spec.node_id] = tuple(supplements)
            subjects.append(
                replace(
                    previous,
                    identity_sha256=identity,
                    receipt_sha256=receipt_sha256,
                )
            )
        contract, issues = make_source_contract(
            self.candidate,
            prospective_candidate=self.prospective,
            compiler_identity_sha256=self.compiler_identity_sha256,
            subjects=subjects,
        )
        if issues or contract is None:
            raise AssertionError(issues)
        self.contract = contract
        self.dag = self.compile(contract)
        self.node_inputs = node_inputs
        self.node_supplemental_inputs = supplemental_inputs
        rebound_claims = []
        for claim in self.claims(layers=tuple(claim.layer for claim in claims)):
            if claim.layer is not EvidenceLayer.POST_MERGE:
                rebound_claims.append(claim)
                continue
            rebound_inputs = []
            for receipt_input in claim.receipt_inputs:
                raw = dict(receipt_input.receipt)
                raw["qualified_premerge_authority_sha256"] = authority.canonical_sha256
                rebound_inputs.append(
                    replace(
                        receipt_input,
                        receipt=seal_receipt(raw),
                        context=replace(
                            receipt_input.context,
                            expected_qualified_premerge_authority_sha256=(
                                authority.canonical_sha256
                            ),
                        ),
                    )
                )
            rebound_claims.append(
                replace(claim, receipt_inputs=tuple(rebound_inputs))
            )
        return tuple(rebound_claims), authority

    def rebind_after_receipt_change(
        self,
        changed_node_id: str,
    ) -> tuple[SourceContract, PrerequisiteDAG, tuple[EvidenceClaim, ...]]:
        """Move one receipt and identities, deliberately retaining stale child seals."""

        old_by_id = {subject.subject_id: subject for subject in self.contract.subjects}
        node_inputs = dict(self.node_inputs)
        subjects: list[PrerequisiteAuthority] = []
        for spec in DEFAULT_PREREQUISITE_SPECS:
            old = old_by_id[spec.node_id]
            basis = replace(self.contract, subjects=tuple(subjects))
            identity = prerequisite_identity_sha256(basis, spec)
            if identity is None:
                raise AssertionError(f"missing rebound identity for {spec.node_id}")
            receipt_sha256 = old.receipt_sha256
            if spec.node_id == changed_node_id:
                command = _eligible_command(spec)
                candidate = (
                    self.candidate
                    if command.evidence_layer is EvidenceLayer.POST_MERGE
                    else self.prospective
                )
                # Reissue a captured receipt under a distinct artifact-root
                # identity without rewriting its immutable observation bytes.
                captured_rebinding = (
                    {"artifact_root_id": "rebound-qualification-root"}
                    if (candidate_identity_sha256(candidate), command.command_id) in self._owner_reports
                    else {}
                )
                receipt_input = self._make_receipt(
                    candidate,
                    command.evidence_layer,
                    receipt_id=spec.receipt_output_ids[0],
                    requirement_id=identity,
                    command_id=command.command_id,
                    artifact_id=spec.artifact_output_ids[0],
                    scenario_id=lane_c_receipt_scenario_ids(command)[0],
                    **captured_rebinding,
                )
                node_inputs[spec.node_id] = receipt_input
                receipt_sha256 = receipt_input.receipt["canonical_sha256"]
            subjects.append(
                replace(
                    old,
                    identity_sha256=identity,
                    receipt_sha256=receipt_sha256,
                )
            )
        contract, issues = make_source_contract(
            self.candidate,
            prospective_candidate=self.contract.prospective_candidate,
            compiler_identity_sha256=self.compiler_identity_sha256,
            subjects=subjects,
        )
        if issues or contract is None:
            raise AssertionError(issues)
        dag = self.compile(contract)
        claims = self.claims(
            layers=tuple(EvidenceLayer),
            node_inputs=node_inputs,
        )
        return contract, dag, claims


class GateEvaluatorTests(unittest.TestCase):
    def setUp(self) -> None:
        # These fixtures intentionally describe synthetic candidate identities;
        # repository identity admission is isolated. The private compiler and
        # evaluator wrappers additionally select the historical physical parser
        # for marked external fixtures, not production external admission.
        # Capture/report decoding, predecessor resolution, physical receipt
        # validation and the evaluator state machine remain real.
        patcher = mock.patch.object(prerequisite_dag, "_repository_source_issues", return_value=())
        patcher.start()
        self.addCleanup(patcher.stop)
        from Scripts.reconstruction_gate_f import qualification_artifact_validator as native_proof
        def synthetic_build_observation(arguments):
            observation = load_canonical_json(arguments.receipt)
            self.assertEqual(observation, {
                "synthetic_native_build_observation": True,
                "source_commit": arguments.expected_integration_commit,
                "source_tree": arguments.expected_integration_tree,
                "mode": arguments.expected_mode})
            self.assertEqual(arguments.receipt.parent, arguments.run_root)
            self.assertEqual(arguments.app_bundle.parent.parent.parent.parent, arguments.derived_data_root)
            physical = _bundle_identity(arguments.app_bundle, arguments.app_bundle / "Contents/MacOS/MacScope")
            return {"synthetic_native_build_observation": True,
                    "app_executable_sha256": physical["executable_sha256"]}
        # Isolate only expensive native build/signing/tool observations.
        # Source Git objects/export closure, physical bundle bytes, xcresult
        # copy/hash fences, semantic test projection and all receipts remain real.
        native_patches = (
            mock.patch.object(native_proof, "validate_qualification_build", side_effect=synthetic_build_observation),
            mock.patch.object(native_proof, "xcresult_test_summary",
                side_effect=lambda path, _: load_canonical_json(path / "SyntheticSummary.json")),
            mock.patch.object(native_proof, "xcresult_test_nodes",
                side_effect=lambda path, _: load_canonical_json(path / "SyntheticTestNodes.json")),
        )
        for patcher in native_patches:
            patcher.start()
            self.addCleanup(patcher.stop)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.order = default_evidence_partial_order()

    def evaluate(
        self,
        fixture: GateFixture,
        claims: tuple[EvidenceClaim, ...],
        *,
        findings: tuple[QualificationFinding, ...] = (),
    ):
        claims, qualified_premerge_authority = (
            fixture.bind_persisted_premerge_authority(claims)
        )
        return _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            fixture.dag,
            self.order,
            claims,
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=fixture.postmerge_validated_plan,
            qualified_premerge_authority=qualified_premerge_authority,
            findings=findings,
        )

    def test_seven_owner_captures_share_static_plan_and_reuse_immutable_reports(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.PROSPECTIVE_MERGE)
        admissions = tuple(fixture._owner_admissions.values())
        self.assertEqual(len(admissions), 7 + len(CAPTURE_DERIVED_REPORT_COMMANDS))
        self.assertEqual({command_plan_sha256(item.capture.admission.integrated_plan_input.plan)
                          for item in admissions}, {fixture.premerge_validated_plan.command_plan_sha256})
        for admission in admissions:
            with self.subTest(command=admission.capture.command_id):
                for predecessor in admission.capture.admission.admitted_predecessors:
                    physical = fixture._catalog_input(fixture.prospective, predecessor.command_id)
                    self.assertEqual(predecessor.canonical_sha256, physical.receipt["canonical_sha256"])
                    self.assertEqual(predecessor.qualification_run_id, QUALIFICATION_RUN.run_id)
                    self.assertEqual(predecessor.qualification_run_nonce, QUALIFICATION_RUN.nonce)
                paths = [admission.capture.capture_path,
                         *(admission.artifact_root / source.relative_path for source in admission.owner_artifacts)]
                before = {path: path.read_bytes() for path in paths}
                emitted = fixture._make_receipt(fixture.prospective,
                    LANE_C_COMMAND_AUTHORITIES_BY_ID[admission.capture.command_id].evidence_layer,
                    command_id=admission.capture.command_id, receipt_id="reuse-" + admission.capture.command_id,
                    requirement_id="immutable-reuse", scenario_id=admission.capture.scenario_id)
                self.assertEqual(before, {path: path.read_bytes() for path in paths})
                self.assertEqual(emitted.receipt["command_plan_sha256"], fixture.premerge_validated_plan.command_plan_sha256)
                self.assertIsNotNone(emitted.context.capture_admission)

    def test_returns_all_eight_exact_closed_states(self) -> None:
        prospective = GateFixture(
            self.root / "prospective", CandidateSubjectKind.PROSPECTIVE_MERGE
        )
        postmerge = GateFixture(
            self.root / "postmerge", CandidateSubjectKind.POST_MERGE
        )

        def state_view(base: GateFixture, not_run_ids: frozenset[str] = frozenset()):
            # Reuse the already-prepared physical evidence. Each state has
            # its own contract, DAG and receipt maps; physical and semantic
            # validation is still performed afresh for every evaluation below.
            # Plans/report/catalog caches are fully populated and read-only on
            # these paths. Keep the factory's monotonically increasing counter
            # shared: new generic receipts append unique payload paths rather
            # than overwriting another state's physical evidence.
            view = copy.copy(base)
            subjects = tuple(
                replace(
                    subject, status=PrerequisiteStatus.NOT_RUN,
                    identity_sha256=None, receipt_sha256=None, reason_code=None,
                )
                if subject.subject_id in not_run_ids else subject
                for subject in base._pristine_contract.subjects
            )
            contract, issues = make_source_contract(
                base.candidate,
                prospective_candidate=base._pristine_contract.prospective_candidate,
                compiler_identity_sha256=base.compiler_identity_sha256,
                subjects=subjects,
            )
            self.assertEqual(issues, ())
            self.assertIsNotNone(contract)
            view.contract = contract
            view.dag = view.compile(contract)
            view.node_inputs = {
                key: value for key, value in base._pristine_node_inputs.items()
                if key not in not_run_ids
            }
            view.node_supplemental_inputs = {
                key: value for key, value in base._pristine_node_supplemental_inputs.items()
                if key not in not_run_ids
            }
            # bind_persisted_premerge_authority resets from these snapshots.
            # They must describe this state, not the shared complete base.
            view._pristine_contract = view.contract
            view._pristine_dag = view.dag
            view._pristine_node_inputs = dict(view.node_inputs)
            view._pristine_node_supplemental_inputs = dict(view.node_supplemental_inputs)
            return view

        all_not_run = frozenset(
            spec.node_id
            for spec in DEFAULT_PREREQUISITE_SPECS
        )
        blocked = state_view(prospective, all_not_run)
        not_run = state_view(prospective)
        running = state_view(prospective)
        failed = state_view(prospective)
        invalid = state_view(prospective)
        qualified = state_view(prospective)
        pending_ids = frozenset(
            spec.node_id
            for spec in DEFAULT_PREREQUISITE_SPECS
            if spec.stage is PrerequisiteStage.POSTMERGE
        )
        pending = state_view(postmerge, pending_ids)
        complete = state_view(postmerge)

        failed_input = failed._make_receipt(
            failed.prospective,
            # Source commands now require successful captured export proof.
            # Exercise FAILED with a genuinely failed, non-capture-required
            # native command instead of claiming a failed source capture.
            EvidenceLayer.NATIVE_ASAN,
            status=EvidenceStatus.FAILED,
            command_id=_command_for_layer(
                EvidenceLayer.NATIVE_ASAN
            ).command_id,
            scenario_id=lane_c_receipt_scenario_ids(
                _command_for_layer(EvidenceLayer.NATIVE_ASAN)
            )[0],
        )
        # Failed evidence still seals actual successful predecessor receipts.
        # Submit only this command's ancestors: descendants would refer to the
        # separate passed ASan catalogue receipt, not this failed execution.
        failed_inputs = {failed_input.context.expected_command_id: failed_input}

        def include_predecessors(command_id: str) -> None:
            record = failed.premerge_validated_plan.command_records_by_id[command_id]
            for predecessor in record.prerequisite_ids:
                if predecessor == "candidate-identity-accepted" or predecessor in failed_inputs:
                    continue
                failed_inputs[predecessor] = failed._catalog_input(failed.prospective, predecessor)
                include_predecessors(predecessor)

        include_predecessors(failed_input.context.expected_command_id)
        failed_claims = tuple(
            EvidenceClaim(layer, tuple(item for item in failed_inputs.values()
                                       if item.context.expected_layer is layer))
            for layer in EvidenceLayer
            if any(item.context.expected_layer is layer for item in failed_inputs.values())
        )
        # Retain genuine source capture admission so the malformed ID reaches
        # receipt validation, rather than failing earlier for missing capture.
        malformed_input = invalid.baseline_inputs[EvidenceLayer.SOURCE_GOVERNANCE]
        malformed = dict(malformed_input.receipt)
        malformed["receipt_id"] = []
        cases = (
            (blocked, (), DecisionStatus.BLOCKED_PREREQUISITE),
            (not_run, (), DecisionStatus.NOT_RUN),
            (
                running,
                running.claims(layers=(EvidenceLayer.SOURCE_GOVERNANCE,)),
                DecisionStatus.RUNNING_RECEIPTS_INCOMPLETE,
            ),
            (
                failed,
                failed_claims,
                DecisionStatus.FAILED,
            ),
            (
                invalid,
                (
                    EvidenceClaim(
                        EvidenceLayer.SOURCE_GOVERNANCE,
                        (replace(malformed_input, receipt=malformed),),
                    ),
                ),
                DecisionStatus.INVALID_EVIDENCE,
            ),
            (qualified, qualified.premerge_claims(), DecisionStatus.QUALIFIED_PREMERGE),
            (pending, pending.premerge_claims(), DecisionStatus.MERGED_POSTMERGE_PENDING),
            (complete, complete.all_claims(), DecisionStatus.COMPLETE),
        )
        self.assertEqual({expected for _, _, expected in cases}, set(DecisionStatus))
        for fixture, claims, expected in cases:
            with self.subTest(expected.value):
                decision = self.evaluate(fixture, claims)
                self.assertEqual(decision.status, expected)
                if expected is DecisionStatus.INVALID_EVIDENCE:
                    self.assertIn("stable-id", decision.issue_codes)

    def test_complete_requires_valid_physical_artifacts(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        receipt_input = fixture.baseline_inputs[EvidenceLayer.SOURCE_GOVERNANCE]
        relative_path = receipt_input.receipt["artifacts"][0]["relative_path"]
        (fixture.factory.root / relative_path).write_bytes(b"tampered\n")
        decision = self.evaluate(fixture, fixture.all_claims())
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertTrue(
            {"artifact-byte-count-mismatch", "artifact-sha256-mismatch"}
            & set(decision.issue_codes)
        )

    def test_cross_candidate_receipt_cannot_be_rebound(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        foreign = replace(
            fixture.prospective,
            source=replace(fixture.prospective.source, commit="f" * 40),
        )
        receipt = fixture.factory.make(
            foreign,
            EvidenceLayer.SOURCE_GOVERNANCE,
            command_id=_command_for_layer(
                EvidenceLayer.SOURCE_GOVERNANCE
            ).command_id,
            scenario_id=lane_c_receipt_scenario_ids(
                _command_for_layer(EvidenceLayer.SOURCE_GOVERNANCE)
            )[0],
        )
        claims = list(fixture.all_claims())
        index = next(
            index
            for index, claim in enumerate(claims)
            if claim.layer is EvidenceLayer.SOURCE_GOVERNANCE
        )
        claims[index] = replace(
            claims[index],
            receipt_inputs=(receipt, *claims[index].receipt_inputs[1:]),
        )
        decision = self.evaluate(fixture, tuple(claims))
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn("evidence-candidate-mismatch", decision.issue_codes)

    def test_node_receipt_must_seal_exact_compiled_identity(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        node_id = "task6-remediation-accepted"
        original = fixture.node_inputs[node_id]
        raw = dict(original.receipt)
        raw["requirement_id"] = "f" * 64
        raw = seal_receipt(raw)
        forged = replace(
            original,
            receipt=raw,
            context=replace(original.context, expected_requirement_id="f" * 64,
                # Keep receipt admission internally coherent so this test
                # reaches the independently compiled node identity guard.
                capture_admission=(None if original.context.capture_admission is None
                    else replace(original.context.capture_admission, requirement_id="f" * 64))),
        )
        node_inputs = dict(fixture.node_inputs)
        node_inputs[node_id] = forged
        claims = fixture.claims(
            layers=tuple(EvidenceLayer),
            node_inputs=node_inputs,
        )
        decision = self.evaluate(fixture, claims)
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            "prerequisite-receipt-requirement-mismatch",
            decision.issue_codes,
        )

    def test_upstream_receipt_move_rebinds_dag_but_not_stale_child_receipts(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        contract, dag, claims = fixture.rebind_after_receipt_change(
            "task6-remediation-accepted"
        )
        self.assertNotEqual(
            source_contract_sha256(contract),
            source_contract_sha256(fixture.contract),
        )
        decision = _evaluate_gate_with_validated_command_plans(
            contract,
            dag,
            self.order,
            claims,
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=fixture.postmerge_validated_plan,
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            "prerequisite-receipt-requirement-mismatch",
            decision.issue_codes,
        )

    def test_wrong_lane_c_command_group_cannot_satisfy_node(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        node_id = "task6-remediation-accepted"
        original = fixture.node_inputs[node_id]
        wrong_command = LANE_C_COMMAND_AUTHORITIES_BY_ID[
            "xcode.focused.task10-projection"
        ]
        self.assertIs(wrong_command.evidence_layer, original.context.expected_layer)
        forged = fixture._make_receipt(
            original.context.expected_candidate,
            original.context.expected_layer,
            receipt_id=original.context.expected_receipt_id,
            requirement_id=original.context.expected_requirement_id,
            command_id=wrong_command.command_id,
            artifact_id=original.context.expected_artifacts[0].artifact_id,
            receipt_type=original.context.expected_receipt_type,
            scenario_id=lane_c_receipt_scenario_ids(wrong_command)[0],
        )
        node_inputs = dict(fixture.node_inputs)
        node_inputs[node_id] = forged
        decision = self.evaluate(
            fixture,
            fixture.claims(
                layers=tuple(EvidenceLayer),
                node_inputs=node_inputs,
            ),
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            "prerequisite-receipt-command-group-mismatch",
            decision.issue_codes,
        )

    def test_every_layer_receipt_requires_an_exact_lane_c_command(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        original = fixture.baseline_inputs[EvidenceLayer.SOURCE_GOVERNANCE]
        raw = dict(original.receipt)
        raw["command_id"] = "fabricated.source-command"
        raw["artifacts"] = [
            {**artifact, "command_id": "fabricated.source-command"}
            for artifact in raw["artifacts"]
        ]
        raw["authority"]["artifact_manifest_sha256"] = canonical_sha256(
            sorted(raw["artifacts"], key=lambda item: str(item["artifact_id"]))
        )
        forged = replace(
            original,
            receipt=seal_receipt(raw),
            context=replace(
                original.context,
                expected_command_id="fabricated.source-command",
            ),
        )
        claims = list(fixture.all_claims())
        index = next(
            index
            for index, claim in enumerate(claims)
            if claim.layer is EvidenceLayer.SOURCE_GOVERNANCE
        )
        claims[index] = replace(
            claims[index],
            receipt_inputs=(forged, *claims[index].receipt_inputs[1:]),
        )
        decision = self.evaluate(fixture, tuple(claims))
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        # The source owner now retains an independent process capture. A forged
        # command must fail that earlier boundary before semantic catalog lookup.
        self.assertIn("capture-admission", decision.issue_codes)

    def test_cross_host_clock_skew_does_not_override_sealed_predecessor_observation(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        target = fixture._catalog_input(
            fixture.candidate,
            "postmerge.exact-tree-proof",
        )
        prerequisite = target.context.expected_command_authority.prerequisite_receipts[0]
        predecessor = next(
            item
            for claim in fixture.all_claims()
            for item in claim.receipt_inputs
            if item.context.expected_receipt_id == prerequisite.receipt_id
        )
        predecessor_end = (
            predecessor.context.expected_execution_interval.ended_at_unix_ms
        )

        def claims_with_start(started_at_unix_ms: int):
            raw = dict(target.receipt)
            raw["execution_interval"] = {
                "started_at_unix_ms": started_at_unix_ms,
                "ended_at_unix_ms": max(
                    started_at_unix_ms,
                    target.context.expected_execution_interval.ended_at_unix_ms,
                ),
            }
            replacement = replace(
                target,
                receipt=seal_receipt(raw),
                context=replace(
                    target.context,
                    expected_execution_interval=replace(
                        target.context.expected_execution_interval,
                        started_at_unix_ms=started_at_unix_ms,
                        ended_at_unix_ms=raw["execution_interval"][
                            "ended_at_unix_ms"
                        ],
                    ),
                ),
            )
            return tuple(
                replace(
                    claim,
                    receipt_inputs=tuple(
                        replacement if item is target else item
                        for item in claim.receipt_inputs
                    ),
                )
                if claim.layer is target.context.expected_layer
                else claim
                for claim in fixture.all_claims()
            )

        def command_issue_codes(started_at_unix_ms: int) -> set[str]:
            compiled, compilation_issues = compile_evidence_claims(
                self.order,
                expected_candidate=fixture.candidate,
                expected_qualification_run=QUALIFICATION_RUN,
                expected_premerge_candidate=fixture.prospective,
                claims=claims_with_start(started_at_unix_ms),
            )
            self.assertEqual(compilation_issues, ())
            self.assertIsNotNone(compiled)
            return {
                issue.code
                for issue in _receipt_command_issues(
                    compiled or (),
                    LANE_C_COMMAND_AUTHORITIES_BY_ID,
                    premerge_plan=fixture.premerge_validated_plan,
                    postmerge_plan=fixture.postmerge_validated_plan,
                )
            }

        self.assertNotIn(
            "evidence-receipt-command-prerequisite-unbound",
            command_issue_codes(predecessor_end - 1),
        )
        self.assertNotIn(
            "evidence-receipt-command-prerequisite-unbound",
            command_issue_codes(predecessor_end),
        )

    def test_aggregate_receipt_requires_the_exact_compiled_scenario_closure(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        command_id = "signed-xpc.error-cancellation"
        target = next(
            receipt_input
            for receipt_input in fixture.catalog_inputs
            if receipt_input.context.expected_command_id == command_id
        )
        expected = lane_c_receipt_scenario_ids(
            LANE_C_COMMAND_AUTHORITIES_BY_ID[command_id]
        )
        self.assertEqual(len(expected), 2)
        raw = dict(target.receipt)
        raw["constituents"] = list(raw["constituents"][:-1])
        raw["authority"] = {
            **raw["authority"],
            "selector_count": len(raw["constituents"]),
        }
        partial = replace(target, receipt=seal_receipt(raw))
        claims = tuple(
            replace(
                claim,
                receipt_inputs=tuple(
                    partial if item is target else item
                    for item in claim.receipt_inputs
                ),
            )
            if claim.layer is target.context.expected_layer
            else claim
            for claim in fixture.all_claims()
        )
        decision = self.evaluate(fixture, claims)
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            # Physical capture admission now rejects a resealed constituent
            # mutation before the downstream scenario-coverage projection.
            "capture-admission",
            decision.issue_codes,
        )

    def test_complete_requires_receipts_for_all_forty_three_lane_c_commands(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        claims = fixture.all_claims()
        observed = {
            receipt_input.context.expected_command_id
            for claim in claims
            for receipt_input in claim.receipt_inputs
        }
        self.assertEqual(
            observed,
            {command.command_id for command in LANE_C_COMMAND_AUTHORITIES},
        )
        # This is the only terminal command in the frozen Lane C DAG.  Removing
        # it leaves every other command's prerequisite chain intact, which
        # reaches the aggregate all-command coverage guard directly.
        missing_command_id = "postmerge.exact-tree-proof"
        missing_claims = tuple(
            replace(
                claim,
                receipt_inputs=tuple(
                    receipt_input
                    for receipt_input in claim.receipt_inputs
                    if receipt_input.context.expected_command_id
                    != missing_command_id
                ),
            )
            for claim in claims
        )
        decision = self.evaluate(fixture, missing_claims)
        self.assertEqual(decision.status, DecisionStatus.MERGED_POSTMERGE_PENDING)
        self.assertIn("postmerge-proof-pending", decision.issue_codes)

        postmerge_claim = next(
            claim
            for claim in claims
            if claim.layer is EvidenceLayer.POST_MERGE
        )
        terminal_receipt = next(
            receipt_input
            for receipt_input in postmerge_claim.receipt_inputs
            if receipt_input.context.expected_command_id == missing_command_id
        )
        generic_terminal = fixture.factory.make(
            terminal_receipt.context.expected_candidate,
            EvidenceLayer.POST_MERGE,
            receipt_id=terminal_receipt.context.expected_receipt_id,
            requirement_id=terminal_receipt.context.expected_requirement_id,
            command_id=missing_command_id,
            artifact_id=terminal_receipt.context.expected_artifacts[0].artifact_id,
            receipt_type=ReceiptType.COMMAND_EXECUTION,
            scenario_id=terminal_receipt.context.expected_scenario_id,
        )
        generic_claims = tuple(
            replace(
                claim,
                receipt_inputs=tuple(
                    generic_terminal
                    if receipt_input is terminal_receipt
                    else receipt_input
                    for receipt_input in claim.receipt_inputs
                ),
            )
            if claim is postmerge_claim
            else claim
            for claim in claims
        )
        decision = self.evaluate(fixture, generic_claims)
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn("evidence-receipt-command-plan-mismatch", decision.issue_codes)

    def test_evaluator_rejects_caller_repeated_command_scenario_ids(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        target = LANE_C_COMMAND_AUTHORITIES_BY_ID["xcode.focused.model-rounds"]
        self.assertGreater(len(target.scenario_ids), 1)
        target_record = next(
            record
            for record in fixture.premerge_scenario_plan.commands
            if record.command_id == target.command_id
        )
        repeated = replace(
            target_record,
            scenario_ids=(target.scenario_ids[0], target.scenario_ids[0]),
        )
        command_plan = replace(
            fixture.premerge_scenario_plan,
            commands=tuple(
                repeated if record.command_id == target.command_id else record
                for record in fixture.premerge_scenario_plan.commands
            ),
        )
        _, issues = validate_lane_c_command_plan(
            command_plan,
            expected_candidate_identity_sha256=candidate_identity_sha256(
                fixture.prospective
            ),
        )
        self.assertIn(
            "command-catalog-entry-shape",
            {issue.code for issue in issues},
        )

    def test_receipt_scenario_and_phase_plan_candidate_are_not_rebindable(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        target = next(
            receipt_input
            for receipt_input in fixture.catalog_inputs
            if receipt_input.context.expected_command_id
            == "xcode.focused.provider-pool"
        )
        raw = dict(target.receipt)
        raw["scenario_id"] = "scenario.caller-repeated"
        forged = replace(
            target,
            receipt=seal_receipt(raw),
            context=replace(
                target.context,
                expected_scenario_id="scenario.caller-repeated",
            ),
        )
        claims = tuple(
            replace(
                claim,
                receipt_inputs=tuple(
                    forged if item is target else item
                    for item in claim.receipt_inputs
                ),
            )
            if claim.layer is target.context.expected_layer
            else claim
            for claim in fixture.all_claims()
        )
        decision = self.evaluate(fixture, claims)
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        # Changing the scenario of a captured focused owner is rejected before
        # the semantic lookup; its standalone semantic check is retained above.
        self.assertIn("capture-admission", decision.issue_codes)

        prospective_digest = candidate_identity_sha256(fixture.prospective)
        postmerge_digest = candidate_identity_sha256(fixture.candidate)
        self.assertNotEqual(prospective_digest, postmerge_digest)
        decision = _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            fixture.dag,
            self.order,
            fixture.all_claims(),
            premerge_command_plan=replace(
                fixture.premerge_validated_plan,
                candidate_identity_sha256=postmerge_digest,
            ),
            postmerge_command_plan=fixture.postmerge_validated_plan,
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn("validated-lane-c-plan-candidate-mismatch", decision.issue_codes)

        assert fixture.postmerge_validated_plan is not None
        decision = _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            fixture.dag,
            self.order,
            fixture.all_claims(),
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=replace(
                fixture.postmerge_validated_plan,
                scenario_catalog_sha256=(
                    fixture.premerge_validated_plan.scenario_catalog_sha256
                ),
            ),
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            "scenario-catalog-cross-candidate-reuse",
            decision.issue_codes,
        )

        rebound_record = replace(
            fixture.premerge_scenario_plan.commands[0],
            candidate_identity_sha256=postmerge_digest,
        )
        _, issues = validate_lane_c_command_plan(
            replace(
                fixture.premerge_scenario_plan,
                commands=(
                    rebound_record,
                    *fixture.premerge_scenario_plan.commands[1:],
                ),
            ),
            expected_candidate_identity_sha256=prospective_digest,
        )
        self.assertIn("command-candidate-mismatch", {issue.code for issue in issues})

        _, issues = validate_lane_c_command_plan(
            replace(
                fixture.premerge_scenario_plan,
                scenario_bindings=tuple(
                    reversed(fixture.premerge_scenario_plan.scenario_bindings)
                ),
            ),
            expected_candidate_identity_sha256=prospective_digest,
        )
        self.assertIn(
            "lane-c-scenario-plan-mismatch",
            {issue.code for issue in issues},
        )

        decision = _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            fixture.dag,
            self.order,
            fixture.all_claims(),
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=replace(
                fixture.postmerge_validated_plan,
                candidate_identity_sha256=prospective_digest,
            ),
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn("validated-lane-c-plan-candidate-mismatch", decision.issue_codes)

    def test_postmerge_rejects_self_consistent_subset_premerge_authority(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        claims, authority = fixture.bind_persisted_premerge_authority(
            fixture.all_claims()
        )
        self.assertIsNotNone(authority)
        assert authority is not None
        self.assertGreater(len(authority.receipt_digests), 1)

        kept_receipt_digests = authority.receipt_digests[:-1]
        kept_receipt_ids = {receipt_id for receipt_id, _ in kept_receipt_digests}
        compiled, compilation_issues = compile_evidence_claims(
            self.order,
            expected_candidate=fixture.contract.candidate,
            expected_qualification_run=QUALIFICATION_RUN,
            expected_premerge_candidate=fixture.contract.prospective_candidate,
            claims=claims,
        )
        self.assertEqual(compilation_issues, ())
        self.assertIsNotNone(compiled)
        assert compiled is not None
        premerge_claims = tuple(
            claim for claim in compiled if claim.layer in PREMERGE_EVIDENCE_LAYERS
        )
        kept_receipts = tuple(
            output
            for claim in premerge_claims
            for output in claim.receipt_outputs
            if output.receipt_id in kept_receipt_ids
        )
        kept_artifacts = tuple(
            artifact
            for claim in premerge_claims
            for artifact in claim.artifact_outputs
            if artifact.producer_receipt_id in kept_receipt_ids
        )
        forged = replace(
            authority,
            evidence_root_sha256=canonical_sha256(
                {
                    "receipts": to_primitive(kept_receipts),
                    "artifacts": to_primitive(kept_artifacts),
                }
            ),
            receipt_digests=kept_receipt_digests,
            canonical_sha256="",
        )
        forged_payload = asdict(forged)
        del forged_payload["canonical_sha256"]
        forged = replace(
            forged,
            canonical_sha256=canonical_sha256(forged_payload),
        )

        decision = _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            fixture.dag,
            self.order,
            claims,
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=fixture.postmerge_validated_plan,
            qualified_premerge_authority=forged,
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn(
            "qualified-premerge-authority-mismatch",
            decision.issue_codes,
        )

    def test_complete_rejects_generic_receipts_for_semantic_authority_layers(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        for layer in (
            EvidenceLayer.STRICT_SIGNING,
            EvidenceLayer.INSTALLED_SOURCE_EQUALITY,
            EvidenceLayer.INDEPENDENT_REVIEW,
            EvidenceLayer.PROSPECTIVE_MERGE_TREE,
            EvidenceLayer.POST_MERGE,
        ):
            with self.subTest(layer.value):
                mutated_claims: list[EvidenceClaim] = []
                for claim in fixture.all_claims():
                    if claim.layer is not layer:
                        mutated_claims.append(claim)
                        continue
                    generic_inputs = tuple(
                        fixture.factory.make(
                            receipt_input.context.expected_candidate,
                            layer,
                            receipt_id=receipt_input.context.expected_receipt_id,
                            requirement_id=receipt_input.context.expected_requirement_id,
                            command_id=receipt_input.context.expected_command_id,
                            artifact_id=(
                                receipt_input.context.expected_artifacts[0].artifact_id
                                if receipt_input.context.expected_artifacts
                                else None
                            ),
                            receipt_type=ReceiptType.COMMAND_EXECUTION,
                            scenario_id=receipt_input.context.expected_scenario_id,
                        )
                        for receipt_input in claim.receipt_inputs
                    )
                    mutated_claims.append(
                        replace(claim, receipt_inputs=generic_inputs)
                    )
                decision = self.evaluate(fixture, tuple(mutated_claims))
                self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
                self.assertIn(
                    "missing-required-receipt-type",
                    decision.issue_codes,
                )

    def test_missing_required_node_receipt_or_artifact_cannot_complete(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        node_id = "task6-remediation-accepted"
        claims = tuple(
            replace(
                claim,
                receipt_inputs=tuple(
                    receipt
                    for receipt in claim.receipt_inputs
                    if receipt is not fixture.node_inputs[node_id]
                ),
            )
            for claim in fixture.all_claims()
        )
        decision = self.evaluate(fixture, claims)
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        self.assertIn("missing-required-receipt-output", decision.issue_codes)
        self.assertIn("missing-required-artifact-output", decision.issue_codes)

    def test_unresolved_p0_p1_p2_block_complete_but_p3_does_not(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        claims = fixture.all_claims()
        for severity in (FindingSeverity.P0, FindingSeverity.P1, FindingSeverity.P2):
            with self.subTest(severity.value):
                decision = self.evaluate(
                    fixture,
                    claims,
                    findings=(
                        QualificationFinding(
                            f"unresolved-{severity.value}",
                            severity,
                            False,
                        ),
                    ),
                )
                self.assertEqual(decision.status, DecisionStatus.FAILED)
        decision = self.evaluate(
            fixture,
            claims,
            findings=(
                QualificationFinding("resolved-p0", FindingSeverity.P0, True),
                QualificationFinding("open-p3", FindingSeverity.P3, False),
            ),
        )
        self.assertEqual(decision.status, DecisionStatus.COMPLETE)

    def test_public_lane_d_adapter_fails_closed_without_lane_c_plan_dto(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        unavailable = LaneCIntegratedCommandPlanInput(
            plan=object(),
            scenario_catalog=object(),
            repository_root=self.root,
            inputs={},
            templates={},
        )
        issues = evaluate_gate_issues(
            fixture.contract,
            fixture.dag,
            self.order,
            fixture.all_claims(),
            premerge_command_plan=unavailable,
            postmerge_command_plan=unavailable,
        )
        self.assertEqual(
            {issue.code for issue in issues},
            {"lane-c-command-plan-type"},
        )

    def test_forged_dag_and_command_catalog_fail_closed(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        forged = replace(
            fixture.dag,
            topological_order=tuple(reversed(fixture.dag.topological_order)),
        )
        decision = _evaluate_gate_with_validated_command_plans(
            fixture.contract,
            forged,
            self.order,
            fixture.all_claims(),
            premerge_command_plan=fixture.premerge_validated_plan,
            postmerge_command_plan=fixture.postmerge_validated_plan,
        )
        self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
        first_record = fixture.premerge_scenario_plan.commands[0]
        drifted_plan = replace(
            fixture.premerge_scenario_plan,
            commands=(
                replace(first_record, command_groups=("source-governance",)),
                *fixture.premerge_scenario_plan.commands[1:],
            ),
        )
        _, issues = validate_lane_c_command_plan(
            drifted_plan,
            expected_candidate_identity_sha256=candidate_identity_sha256(
                fixture.prospective
            ),
        )
        self.assertIn(
            "lane-c-command-catalog-mismatch",
            {issue.code for issue in issues},
        )

    def test_malformed_dag_node_identity_fails_closed_without_raising(self) -> None:
        fixture = GateFixture(self.root, CandidateSubjectKind.POST_MERGE)
        for field_name in ("node_id", "owner_id"):
            with self.subTest(field_name):
                malformed_spec = replace(
                    fixture.dag.nodes[0].spec,
                    **{field_name: []},
                )
                malformed_node = replace(
                    fixture.dag.nodes[0],
                    spec=malformed_spec,
                )
                malformed_dag = replace(
                    fixture.dag,
                    nodes=(malformed_node, *fixture.dag.nodes[1:]),
                )
                decision = _evaluate_gate_with_validated_command_plans(
                    fixture.contract,
                    malformed_dag,
                    self.order,
                    fixture.all_claims(),
                    premerge_command_plan=fixture.premerge_validated_plan,
                    postmerge_command_plan=fixture.postmerge_validated_plan,
                )
                self.assertEqual(decision.status, DecisionStatus.INVALID_EVIDENCE)
                self.assertIn(
                    "prerequisite-node-identity-shape",
                    decision.issue_codes,
                )


if __name__ == "__main__":
    unittest.main()
