"""Closed-state evaluator for the Gate F prerequisite and evidence models."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import Enum

from .canonical_json import canonical_sha256, to_primitive
from .command_catalog import REQUIRED_RECEIPT_BINDING_FIELDS, CampaignProfile, campaign_profile_for_inputs
from .evidence_model import (
    EvidenceClaim,
    EvidencePartialOrder,
    REQUIRED_RECEIPT_TYPES_BY_LAYER,
    ValidatedEvidenceClaim,
    claims_by_layer,
    compile_evidence_claims,
    compile_evidence_partial_order,
    evidence_partial_order_sha256,
)
from .prerequisite_dag import (
    CompiledPrerequisiteNode,
    EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS,
    LANE_C_COMMAND_AUTHORITIES_BY_ID,
    LaneCCommandAuthority,
    LaneCIntegratedCommandPlanInput,
    lane_c_command_authorities,
    PrerequisiteDAG,
    PrerequisiteNodeSpec,
    PrerequisiteStage,
    compile_prerequisite_dag,
    lane_c_receipt_scenario_ids,
    validate_integrated_lane_c_command_plan,
    _ValidatedLaneCCommandPlan,
)
from .schema import (
    CandidateSubjectKind,
    DecisionStatus,
    EvidenceLayer,
    EvidenceStatus,
    STABLE_ID_RE,
    ValidationIssue,
    candidate_identity_sha256,
    candidate_to_mapping,
    is_sha256,
)
from .receipt_validator import QualificationRunAuthority, CAPTURE_REQUIRED_COMMANDS
from .source_contract import (
    PrerequisiteStatus,
    SourceContract,
    parse_source_contract,
    source_contract_to_mapping,
)


class FindingSeverity(str, Enum):
    P0 = "p0"
    P1 = "p1"
    P2 = "p2"
    P3 = "p3"


@dataclass(frozen=True)
class QualificationFinding:
    finding_id: str
    severity: FindingSeverity
    resolved: bool


@dataclass(frozen=True)
class QualifiedPremergeAuthority:
    """Immutable authorization emitted only by a qualified premerge decision."""

    schema_version: int
    qualification_run_id: str
    qualification_run_nonce: str
    prospective_candidate_identity_sha256: str
    source_contract_sha256: str
    prerequisite_dag_sha256: str
    evidence_partial_order_sha256: str
    evidence_root_sha256: str
    receipt_digests: tuple[tuple[str, str], ...]
    command_plan_sha256: str
    decision_status: str
    canonical_sha256: str


@dataclass(frozen=True)
class GateDecision:
    status: DecisionStatus
    issue_codes: tuple[str, ...]
    validation_issues: tuple[ValidationIssue, ...]
    missing_prerequisite_ids: tuple[str, ...]
    missing_evidence_layers: tuple[EvidenceLayer, ...]
    unavailable_evidence_layers: tuple[EvidenceLayer, ...]
    failed_evidence_layers: tuple[EvidenceLayer, ...]
    qualified_premerge_authority: QualifiedPremergeAuthority | None = None


# This is the authority emitted *before* the merge is accepted.  The
# prospective-merge-tree receipt is merge-stage evidence and is required to
# seal this authority, so including it here would create an impossible digest
# cycle (authority -> merge receipt -> authority).  It remains a mandatory
# Gate F layer, just not an input to the earlier premerge authority root.
PREMERGE_EVIDENCE_LAYERS = tuple(
    layer
    for layer in EvidenceLayer
    if layer not in {
        EvidenceLayer.PROSPECTIVE_MERGE_TREE,
        EvidenceLayer.POST_MERGE,
    }
)


def _qualified_premerge_authority_payload(
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[ValidatedEvidenceClaim],
    command_plan: _ValidatedLaneCCommandPlan,
    qualification_run: QualificationRunAuthority,
) -> dict[str, object]:
    premerge_candidate = (
        contract.prospective_candidate
        if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
        and contract.prospective_candidate is not None
        else contract.candidate
    )
    premerge_node_ids = {
        node.spec.node_id
        for node in dag.nodes
        if node.spec.stage is PrerequisiteStage.PREMERGE
    }
    premerge_subjects = tuple(
        subject
        for subject in contract.subjects
        if subject.subject_id in premerge_node_ids
    )
    source_root = canonical_sha256(
        {
            "schema_version": contract.schema_version,
            "candidate": candidate_to_mapping(premerge_candidate),
            "compiler_identity_sha256": contract.compiler_identity_sha256,
            "subjects": to_primitive(premerge_subjects),
        }
    )
    dag_root = canonical_sha256(
        {
            "source_contract_sha256": source_root,
            "nodes": to_primitive(
                tuple(
                    node
                    for node in dag.nodes
                    if node.spec.node_id in premerge_node_ids
                )
            ),
            "topological_order": [
                node_id
                for node_id in dag.topological_order
                if node_id in premerge_node_ids
            ],
        }
    )
    premerge_claims = tuple(
        claim for claim in claims if claim.layer in PREMERGE_EVIDENCE_LAYERS
    )
    selected_receipts = tuple(
        output
        for claim in premerge_claims
        for output in claim.receipt_outputs
    )
    selected_receipt_ids = {output.receipt_id for output in selected_receipts}
    selected_artifacts = tuple(
        artifact
        for claim in premerge_claims
        for artifact in claim.artifact_outputs
        if artifact.producer_receipt_id in selected_receipt_ids
    )
    receipt_digests = tuple(
        sorted(
            (output.receipt_id, output.canonical_sha256)
            for output in selected_receipts
        )
    )
    evidence_root = canonical_sha256(
        {
            "receipts": to_primitive(selected_receipts),
            "artifacts": to_primitive(selected_artifacts),
        }
    )
    return {
        "schema_version": 2,
        "qualification_run_id": qualification_run.run_id,
        "qualification_run_nonce": qualification_run.nonce,
        "prospective_candidate_identity_sha256": candidate_identity_sha256(
            premerge_candidate
        ),
        "source_contract_sha256": source_root,
        "prerequisite_dag_sha256": dag_root,
        "evidence_partial_order_sha256": evidence_partial_order_sha256(
            evidence_order
        ),
        "evidence_root_sha256": evidence_root,
        "receipt_digests": receipt_digests,
        "command_plan_sha256": command_plan.command_plan_sha256,
        "decision_status": DecisionStatus.QUALIFIED_PREMERGE.value,
    }


def _make_qualified_premerge_authority(
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[ValidatedEvidenceClaim],
    command_plan: _ValidatedLaneCCommandPlan,
    qualification_run: QualificationRunAuthority,
) -> QualifiedPremergeAuthority:
    payload = _qualified_premerge_authority_payload(
        contract,
        dag,
        evidence_order,
        claims,
        command_plan,
        qualification_run,
    )
    return QualifiedPremergeAuthority(
        **payload,
        canonical_sha256=canonical_sha256(payload),
    )


def _qualified_premerge_authority_issues(
    value: object,
    *,
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[ValidatedEvidenceClaim],
    command_plan: _ValidatedLaneCCommandPlan,
    qualification_run: QualificationRunAuthority,
) -> tuple[ValidationIssue, ...]:
    if not isinstance(value, QualifiedPremergeAuthority):
        return (
            ValidationIssue(
                "qualified-premerge-authority-type",
                "$.qualified_premerge_authority",
                "postmerge evaluation requires the persisted premerge decision authority",
            ),
        )
    try:
        expected_payload = _qualified_premerge_authority_payload(
            contract,
            dag,
            evidence_order,
            claims,
            command_plan,
            qualification_run,
        )
        expected = QualifiedPremergeAuthority(
            **expected_payload,
            canonical_sha256=canonical_sha256(expected_payload),
        )
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        return (
            ValidationIssue(
                "qualified-premerge-authority-shape",
                "$.qualified_premerge_authority",
                "premerge authority cannot be recomputed from current evidence",
            ),
        )
    if not is_sha256(value.canonical_sha256) or value != expected:
        return (
            ValidationIssue(
                "qualified-premerge-authority-mismatch",
                "$.qualified_premerge_authority",
                "postmerge evidence differs from the exact earlier qualified decision root",
            ),
        )
    return ()


def _canonical_source_contract(
    value: object,
) -> tuple[SourceContract | None, tuple[ValidationIssue, ...]]:
    if not isinstance(value, SourceContract):
        return None, (
            ValidationIssue(
                "source-contract-type",
                "$.source_contract",
                "contract must be a SourceContract",
            ),
        )
    try:
        mapping = source_contract_to_mapping(value)
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        return None, (
            ValidationIssue(
                "source-contract-canonicalization",
                "$.source_contract",
                "contract contains malformed public DTO values",
            ),
        )
    return parse_source_contract(mapping)


def _revalidate_compiler_outputs(
    contract: SourceContract,
    dag: object,
    evidence_order: object,
) -> tuple[
    PrerequisiteDAG | None,
    EvidencePartialOrder | None,
    tuple[ValidationIssue, ...],
]:
    """Recompile public DTOs before trusting them as compiler outputs.

    Frozen dataclasses prevent assignment but are not an authenticity boundary:
    callers can construct them directly.  The evaluator therefore accepts a
    supplied graph/order only when the authoritative compilers reproduce every
    field exactly from the supplied immutable source contract.
    """

    issues: list[ValidationIssue] = []
    canonical_dag: PrerequisiteDAG | None = None
    canonical_order: EvidencePartialOrder | None = None

    if not isinstance(dag, PrerequisiteDAG):
        issues.append(
            ValidationIssue(
                "prerequisite-dag-type",
                "$.prerequisite_dag",
                "DAG must be an authenticated PrerequisiteDAG compiler output",
            )
        )
    elif (
        not isinstance(dag.nodes, tuple)
        or not isinstance(dag.topological_order, tuple)
        or any(not isinstance(node, CompiledPrerequisiteNode) for node in dag.nodes)
        or any(not isinstance(node.spec, PrerequisiteNodeSpec) for node in dag.nodes)
    ):
        issues.append(
            ValidationIssue(
                "prerequisite-dag-shape",
                "$.prerequisite_dag",
                "DAG nodes and topological order must retain canonical immutable shapes",
            )
        )
    else:
        canonical_dag, dag_issues = compile_prerequisite_dag(
            contract,
            tuple(node.spec for node in dag.nodes),
        )
        issues.extend(dag_issues)
        if canonical_dag is not None and canonical_dag != dag:
            issues.append(
                ValidationIssue(
                    "prerequisite-dag-not-canonical",
                    "$.prerequisite_dag",
                    "supplied DAG differs from the authoritative compiler output",
                )
            )
        if (
            canonical_dag is not None
            and dag.source_contract_sha256 != canonical_dag.source_contract_sha256
        ):
            issues.append(
                ValidationIssue(
                    "dag-source-contract-mismatch",
                    "$.prerequisite_dag.source_contract_sha256",
                    "compiled DAG belongs to a different source contract",
                )
            )

    if not isinstance(evidence_order, EvidencePartialOrder):
        issues.append(
            ValidationIssue(
                "evidence-partial-order-type",
                "$.evidence_partial_order",
                "partial order must be an authenticated compiler output",
            )
        )
    elif (
        not isinstance(evidence_order.layers, tuple)
        or not isinstance(evidence_order.edges, tuple)
        or not isinstance(evidence_order.topological_order, tuple)
        or not isinstance(evidence_order.transitive_predecessors, Mapping)
    ):
        issues.append(
            ValidationIssue(
                "evidence-partial-order-shape",
                "$.evidence_partial_order",
                "partial-order fields must retain canonical immutable shapes",
            )
        )
    else:
        try:
            canonical_order, order_issues = compile_evidence_partial_order(
                evidence_order.layers,
                evidence_order.edges,
            )
        except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
            canonical_order, order_issues = None, (
                ValidationIssue(
                    "evidence-partial-order-shape",
                    "$.evidence_partial_order",
                    "partial order contains malformed public DTO values",
                ),
            )
        issues.extend(order_issues)
        if canonical_order is not None and canonical_order != evidence_order:
            issues.append(
                ValidationIssue(
                    "evidence-partial-order-not-canonical",
                    "$.evidence_partial_order",
                    "supplied partial order differs from the authoritative compiler output",
                )
            )

    if issues:
        return None, None, tuple(sorted(set(issues)))
    if canonical_dag is None or canonical_order is None:
        return None, None, (
            ValidationIssue(
                "compiler-output-unavailable",
                "$",
                "authoritative Gate F compiler did not produce both required outputs",
            ),
        )
    return canonical_dag, canonical_order, ()


def _decision(
    status: DecisionStatus,
    *,
    issues: Sequence[ValidationIssue] = (),
    issue_codes: Sequence[str] = (),
    missing_prerequisites: Sequence[str] = (),
    missing_layers: Sequence[EvidenceLayer] = (),
    unavailable_layers: Sequence[EvidenceLayer] = (),
    failed_layers: Sequence[EvidenceLayer] = (),
    qualified_premerge_authority: QualifiedPremergeAuthority | None = None,
) -> GateDecision:
    normalized_issues = tuple(sorted(set(issues)))
    return GateDecision(
        status=status,
        issue_codes=tuple(sorted(set(issue_codes) | {issue.code for issue in normalized_issues})),
        validation_issues=normalized_issues,
        missing_prerequisite_ids=tuple(sorted(set(missing_prerequisites))),
        missing_evidence_layers=tuple(sorted(set(missing_layers), key=lambda layer: layer.value)),
        unavailable_evidence_layers=tuple(
            sorted(set(unavailable_layers), key=lambda layer: layer.value)
        ),
        failed_evidence_layers=tuple(sorted(set(failed_layers), key=lambda layer: layer.value)),
        qualified_premerge_authority=qualified_premerge_authority,
    )


def _validate_findings(findings: Sequence[QualificationFinding]) -> tuple[ValidationIssue, ...]:
    issues: list[ValidationIssue] = []
    if not isinstance(findings, (tuple, list)):
        return (
            ValidationIssue(
                "findings-type",
                "$.findings",
                "findings must be a tuple or list",
            ),
        )
    seen: set[str] = set()
    for index, finding in enumerate(findings):
        path = f"$.findings[{index}]"
        if not isinstance(finding, QualificationFinding):
            issues.append(
                ValidationIssue(
                    "finding-type",
                    path,
                    "finding must be a QualificationFinding",
                )
            )
            continue
        if (
            not isinstance(finding.finding_id, str)
            or STABLE_ID_RE.fullmatch(finding.finding_id) is None
        ):
            issues.append(ValidationIssue("stable-id", f"{path}.finding_id", "invalid finding ID"))
        if isinstance(finding.finding_id, str):
            if finding.finding_id in seen:
                issues.append(ValidationIssue("duplicate-finding", f"{path}.finding_id", "finding ID must be unique"))
            seen.add(finding.finding_id)
        if not isinstance(finding.severity, FindingSeverity):
            issues.append(ValidationIssue("finding-severity", f"{path}.severity", "severity is outside the closed P0-P3 enum"))
        if not isinstance(finding.resolved, bool):
            issues.append(ValidationIssue("boolean-type", f"{path}.resolved", "must be Boolean"))
    return tuple(sorted(set(issues)))


def _stage_node_ids(dag: PrerequisiteDAG, stage: PrerequisiteStage) -> tuple[str, ...]:
    by_id = dag.by_id()
    return tuple(
        node_id
        for node_id in dag.topological_order
        if by_id[node_id].spec.stage is stage
    )


def _phase_issues(
    contract: SourceContract,
    claims: Sequence[ValidatedEvidenceClaim],
) -> tuple[ValidationIssue, ...]:
    issues: list[ValidationIssue] = []
    by_layer = claims_by_layer(claims)
    prospective = by_layer.get(EvidenceLayer.PROSPECTIVE_MERGE_TREE)
    postmerge = by_layer.get(EvidenceLayer.POST_MERGE)
    if (
        prospective is not None
        and prospective.status is EvidenceStatus.PASSED
        and contract.candidate.subject_kind is CandidateSubjectKind.CANDIDATE
    ):
        issues.append(
            ValidationIssue(
                "prospective-evidence-on-candidate-head",
                "$.evidence_claims.prospective-merge-tree",
                "branch-head candidate cannot carry prospective merge-tree evidence",
            )
        )
    if postmerge is not None and postmerge.status is EvidenceStatus.PASSED:
        candidate = contract.candidate
        if (
            candidate.subject_kind is not CandidateSubjectKind.POST_MERGE
            or candidate.prospective_merge_commit is None
            or candidate.prospective_merge_tree is None
            or candidate.accepted_postmerge_commit is None
            or candidate.accepted_postmerge_tree is None
        ):
            issues.append(
                ValidationIssue(
                    "postmerge-evidence-on-premerge-candidate",
                    "$.evidence_claims.post-merge",
                    "post-merge evidence requires both prospective and accepted merge identities",
                )
            )
        elif candidate.prospective_merge_tree != candidate.accepted_postmerge_tree:
            issues.append(
                ValidationIssue(
                    "merge-tree-drift",
                    "$.source_contract.candidate.accepted_postmerge_tree",
                    "accepted post-merge tree differs from the qualified prospective tree",
                )
            )
    return tuple(issues)


def _receipt_command_issues(
    claims: Sequence[ValidatedEvidenceClaim],
    command_catalog: Mapping[str, LaneCCommandAuthority],
    *,
    premerge_plan: _ValidatedLaneCCommandPlan,
    postmerge_plan: _ValidatedLaneCCommandPlan | None,
    campaign_profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[ValidationIssue, ...]:
    """Bind every accepted receipt, not only node outputs, to Lane C."""

    issues: list[ValidationIssue] = []
    outputs_by_command_id: dict[str, list[object]] = {}
    outputs_by_receipt_id: dict[str, object] = {}
    artifacts_by_receipt_id: dict[str, list[object]] = {}
    for claim in claims:
        for output in claim.receipt_outputs:
            outputs_by_command_id.setdefault(output.command_id, []).append(output)
            outputs_by_receipt_id[output.receipt_id] = output
        for artifact in claim.artifact_outputs:
            artifacts_by_receipt_id.setdefault(
                artifact.producer_receipt_id,
                [],
            ).append(artifact)
    for claim in claims:
        plan = (
            postmerge_plan
            if claim.layer is EvidenceLayer.POST_MERGE
            else premerge_plan
        )
        for output in claim.receipt_outputs:
            command = command_catalog.get(output.command_id)
            path = f"$.evidence_claims.{claim.layer.value}.{output.receipt_id}"
            if command is None:
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-command-unknown",
                        path,
                        f"receipt command is outside the exact Lane C catalog: {output.command_id}",
                    )
                )
            elif command.evidence_layer is not claim.layer:
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-command-layer-mismatch",
                        path,
                        "receipt relabels a Lane C command onto another evidence layer",
                    )
                )
            elif output.scenario_id not in lane_c_receipt_scenario_ids(command):
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-scenario-mismatch",
                        path,
                        "receipt scenario is not authorized by its Lane C command",
                    )
                )
            elif (
                output.command_id in EXACT_SCENARIO_CONSTITUENT_COMMAND_IDS | {"qualification.verify-bootstrap-fullsuite"}
                and output.constituent_selector_ids
                != tuple(sorted(lane_c_receipt_scenario_ids(command)))
            ):
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-scenario-coverage-mismatch",
                        path,
                        "aggregate receipt constituents differ from the exact Lane C scenario closure",
                    )
                )
            elif plan is None or output.command_plan_sha256 != plan.command_plan_sha256:
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-command-plan-mismatch",
                        path,
                        "raw receipt does not seal its phase's locally derived Lane C plan digest",
                    )
                )
            elif output.command_record_sha256 != plan.command_record_sha256_by_id.get(
                output.command_id
            ):
                issues.append(
                    ValidationIssue(
                        "evidence-receipt-command-record-mismatch",
                        path,
                        "raw receipt does not seal the exact validated Lane C command record",
                    )
                )
            else:
                expected_record = plan.command_records_by_id.get(output.command_id)
                if expected_record is None:
                    issues.append(
                        ValidationIssue(
                            "evidence-receipt-command-record-unavailable",
                            path,
                            "validated Lane C plan omitted the exact command record",
                        )
                    )
                    continue
                authority = output.command_authority
                from .runtime_resolution import resolve_command_record
                static_record = plan.raw_command_records_by_id.get(output.command_id)
                try:
                    resolved = resolve_command_record(
                        static_record,
                        prerequisite_receipts=authority.prerequisite_receipts,
                        qualification_run=output.qualification_run,
                        profile=campaign_profile,
                    )
                except (TypeError, ValueError) as error:
                    issues.append(ValidationIssue(
                        "evidence-runtime-resolution-invalid", path,
                        f"independent predecessor resolution failed: {error}",
                    ))
                    continue
                expected_runtime = to_primitive(resolved.runtime_resolution)
                if (static_record.runtime_argument_slots
                        or output.command_id in CAPTURE_REQUIRED_COMMANDS
                        or output.runtime_resolution is not None):
                    if output.runtime_resolution != expected_runtime:
                        issues.append(ValidationIssue(
                            "evidence-runtime-resolution-mismatch", path,
                            "receipt runtime resolution differs from the static plan and admitted predecessors",
                        ))
                if (
                    authority.host != expected_record.host
                    or authority.execution_mode != expected_record.execution_mode
                    or authority.argv_sha256 != canonical_sha256(list(resolved.record.argv))
                    or authority.working_directory_sha256
                    != expected_record.working_directory_sha256
                    or authority.environment_sha256
                    != expected_record.environment_sha256
                    or authority.generated_artifacts
                    != expected_record.generated_artifacts
                    or authority.generated_logs != expected_record.generated_logs
                ):
                    issues.append(
                        ValidationIssue(
                            "evidence-receipt-command-authority-mismatch",
                            path,
                            "receipt execution/host/output authority differs from the authenticated Lane C record",
                        )
                    )
                required_receipt_fields = set(REQUIRED_RECEIPT_BINDING_FIELDS)
                if set(expected_record.receipt_fields) != required_receipt_fields:
                    issues.append(
                        ValidationIssue(
                            "evidence-receipt-field-contract-mismatch",
                            path,
                            "Lane C command record does not require the universal receipt authority fields",
                        )
                    )
                expected_outputs = {
                    *(f"artifact:{item}" for item in expected_record.generated_artifacts),
                    *(f"log:{item}" for item in expected_record.generated_logs),
                }
                if output.command_id in CAPTURE_REQUIRED_COMMANDS:
                    expected_outputs.add("log:gatef-command-capture")
                from .executor_request_adapter import capture_derived_report_policy, CAPTURE_EXECUTION_REPORT_OUTPUT
                if capture_derived_report_policy(output.command_id, profile=campaign_profile):
                    expected_outputs.update({"log:gatef-command-capture", CAPTURE_EXECUTION_REPORT_OUTPUT})
                observed_outputs = {
                    artifact.command_output
                    for artifact in artifacts_by_receipt_id.get(output.receipt_id, [])
                    if not artifact.command_output.startswith("semantic:")
                }
                if observed_outputs != expected_outputs:
                    issues.append(
                        ValidationIssue(
                            "evidence-receipt-command-output-mismatch",
                            path,
                            "receipt physical artifacts do not bind every authenticated command output and log",
                        )
                    )
                expected_prerequisite_ids = tuple(
                    prerequisite_id
                    for prerequisite_id in expected_record.prerequisite_ids
                    if prerequisite_id != "candidate-identity-accepted"
                )
                observed_prerequisites = authority.prerequisite_receipts
                if tuple(
                    item.command_id for item in observed_prerequisites
                ) != expected_prerequisite_ids:
                    issues.append(
                        ValidationIssue(
                            "evidence-receipt-command-prerequisite-mismatch",
                            path,
                            "receipt prerequisite chain differs from the authenticated command DAG",
                        )
                    )
                for prerequisite in observed_prerequisites:
                    prerequisite_output = outputs_by_receipt_id.get(
                        prerequisite.receipt_id
                    )
                    if (
                        prerequisite_output is None
                        or prerequisite_output.command_id != prerequisite.command_id
                        or prerequisite_output.canonical_sha256
                        != prerequisite.canonical_sha256
                        or prerequisite.qualification_run_id
                        != output.qualification_run.run_id
                        or prerequisite.qualification_run_nonce
                        != output.qualification_run.nonce
                        or prerequisite_output.qualification_run
                        != output.qualification_run
                        or prerequisite_output
                        not in outputs_by_command_id.get(prerequisite.command_id, [])
                    ):
                        issues.append(
                            ValidationIssue(
                                "evidence-receipt-command-prerequisite-unbound",
                                path,
                                "receipt prerequisite does not resolve to the exact validated predecessor receipt",
                            )
                        )
    return tuple(sorted(set(issues)))


def _command_receipt_role_matches(command_id, layer, receipt_type, *, campaign_profile=CampaignProfile.EXISTING) -> bool:
    """Recognize command completion without promoting preparation to semantics."""
    from .executor_request_adapter import capture_derived_report_policy, capture_derived_report_receipt_type
    if capture_derived_report_policy(command_id, profile=campaign_profile):
        from .command_catalog import command_templates
        template = next(item for item in command_templates(profile=campaign_profile) if item.command_id == command_id)
        return layer is template.evidence_layer and receipt_type is capture_derived_report_receipt_type(command_id, profile=campaign_profile)
    return receipt_type in REQUIRED_RECEIPT_TYPES_BY_LAYER[layer]


def _receipt_role_matches(command_id, layer, receipt_type, *, campaign_profile=CampaignProfile.EXISTING) -> bool:
    """A readiness preflight cannot discharge a node's accessibility authority."""
    if (campaign_profile is CampaignProfile.BOOTSTRAP_VERIFIER
            and command_id == "installed.xcuitest-preflight"):
        return False
    return _command_receipt_role_matches(command_id, layer, receipt_type,
                                         campaign_profile=campaign_profile)


def _required_output_issues(
    dag: PrerequisiteDAG,
    claims: Sequence[ValidatedEvidenceClaim],
    node_ids: Sequence[str],
    command_catalog: Mapping[str, LaneCCommandAuthority],
    *, campaign_profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[ValidationIssue, ...]:
    by_id = dag.by_id()
    issues: list[ValidationIssue] = []
    for node_id in node_ids:
        node = by_id[node_id]
        eligible_claims = tuple(
            claim
            for claim in claims
            if claim.layer in node.spec.required_evidence_layers
        )
        for required_layer in node.spec.required_evidence_layers:
            layer_claim = next(
                (
                    claim
                    for claim in eligible_claims
                    if claim.layer is required_layer
                ),
                None,
            )
            node_bound_receipts = tuple(
                output
                for output in (() if layer_claim is None else layer_claim.receipt_outputs)
                if output.requirement_id == node.authority.identity_sha256
                and _receipt_role_matches(output.command_id, required_layer, output.receipt_type, campaign_profile=campaign_profile)
                and (
                    (command := command_catalog.get(output.command_id)) is not None
                    and command.evidence_layer is required_layer
                    and bool(
                        set(command.command_groups)
                        & set(node.spec.command_group_ids)
                    )
                )
            )
            if not node_bound_receipts:
                issues.append(
                    ValidationIssue(
                        "missing-node-required-layer-receipt",
                        f"$.prerequisite_nodes.{node_id}.required_evidence_layers",
                        "node has no exact identity-bound receipt for required layer: "
                        f"{required_layer.value}",
                    )
                )
                continue
            node_receipt_ids = {
                output.receipt_id for output in node_bound_receipts
            }
            if layer_claim is None or not any(
                artifact.producer_receipt_id in node_receipt_ids
                for artifact in layer_claim.artifact_outputs
            ):
                issues.append(
                    ValidationIssue(
                        "missing-node-required-layer-artifact",
                        f"$.prerequisite_nodes.{node_id}.required_evidence_layers",
                        "node required-layer receipt has no descriptor-verified artifact: "
                        f"{required_layer.value}",
                    )
                )
        receipts = {
            output.receipt_id: (claim.layer, output)
            for claim in eligible_claims
            for output in claim.receipt_outputs
        }
        artifacts = {
            output.artifact_id: (claim.layer, output)
            for claim in eligible_claims
            for output in claim.artifact_outputs
        }
        for claim in eligible_claims:
            unauthorized_skips = set(claim.authorized_skip_ids) - set(
                node.spec.allowed_skip_ids
            )
            if unauthorized_skips:
                issues.append(
                    ValidationIssue(
                        "unauthorized-prerequisite-skip",
                        f"$.prerequisite_nodes.{node_id}.allowed_skip_ids",
                        "validated evidence uses skips outside the node authority: "
                        + ", ".join(sorted(unauthorized_skips)),
                    )
                )
        for receipt_id in node.spec.receipt_output_ids:
            receipt_entry = receipts.get(receipt_id)
            if receipt_entry is None:
                issues.append(
                    ValidationIssue(
                        "missing-required-receipt-output",
                        f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                        f"validated output is absent from an exact required layer: {receipt_id}",
                    )
                )
                continue
            layer, output = receipt_entry
            if not _receipt_role_matches(output.command_id, layer, output.receipt_type, campaign_profile=campaign_profile):
                issues.append(
                    ValidationIssue(
                        "prerequisite-receipt-type-mismatch",
                        f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                        "node receipt does not carry the specialized authority for "
                        f"{layer.value}: {output.receipt_type.value}",
                    )
                )
            if output.canonical_sha256 != node.authority.receipt_sha256:
                issues.append(
                    ValidationIssue(
                        "prerequisite-receipt-digest-mismatch",
                        f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                        f"receipt digest does not equal source authority: {receipt_id}",
                    )
                )
            if output.requirement_id != node.authority.identity_sha256:
                issues.append(
                    ValidationIssue(
                        "prerequisite-receipt-requirement-mismatch",
                        f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                        "receipt does not seal the compiled prerequisite identity: "
                        f"{receipt_id}",
                    )
                )
            command = command_catalog.get(output.command_id)
            if command is None:
                issues.append(
                    ValidationIssue(
                        "prerequisite-receipt-command-unknown",
                        f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                        f"receipt command is outside Lane C: {output.command_id}",
                    )
                )
            else:
                if command.evidence_layer is not layer:
                    issues.append(
                        ValidationIssue(
                            "prerequisite-receipt-command-layer-mismatch",
                            f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                            "receipt relabels a Lane C command onto another evidence layer: "
                            f"{output.command_id}",
                        )
                    )
                if not set(command.command_groups) & set(node.spec.command_group_ids):
                    issues.append(
                        ValidationIssue(
                            "prerequisite-receipt-command-group-mismatch",
                            f"$.prerequisite_nodes.{node_id}.receipt_output_ids",
                            "receipt command does not belong to a node-owned Lane C group: "
                            f"{output.command_id}",
                        )
                    )
        for artifact_id in node.spec.artifact_output_ids:
            artifact_entry = artifacts.get(artifact_id)
            if artifact_entry is None:
                issues.append(
                    ValidationIssue(
                        "missing-required-artifact-output",
                        f"$.prerequisite_nodes.{node_id}.artifact_output_ids",
                        f"validated output is absent from an exact required layer: {artifact_id}",
                    )
                )
                continue
            _, output = artifact_entry
            if output.producer_receipt_id not in node.spec.receipt_output_ids:
                issues.append(
                    ValidationIssue(
                        "prerequisite-artifact-producer-mismatch",
                        f"$.prerequisite_nodes.{node_id}.artifact_output_ids",
                        f"artifact is not produced by the node receipt: {artifact_id}",
                    )
                )
    return tuple(sorted(set(issues)))


def _command_coverage_issues(
    claims: Sequence[ValidatedEvidenceClaim],
    command_catalog: Mapping[str, LaneCCommandAuthority],
    required_layers: Sequence[EvidenceLayer],
    *, campaign_profile: CampaignProfile = CampaignProfile.EXISTING,
) -> tuple[ValidationIssue, ...]:
    """Require a Lane-A-validated receipt for every command in the phase."""

    required_layer_set = set(required_layers)
    required_command_ids = {
        command_id
        for command_id, command in command_catalog.items()
        if command.evidence_layer in required_layer_set
    }
    observed_command_ids = {
        output.command_id
        for claim in claims
        if claim.layer in required_layer_set
        for output in claim.receipt_outputs
        if _command_receipt_role_matches(output.command_id, claim.layer, output.receipt_type, campaign_profile=campaign_profile)
    }
    missing = required_command_ids - observed_command_ids
    if not missing:
        return ()
    return (
        ValidationIssue(
            "missing-required-command-receipt",
            "$.evidence_claims",
            "validated receipts are absent for Lane C commands: "
            + ", ".join(sorted(missing)),
        ),
    )


def evaluate_gate(
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[EvidenceClaim],
    *,
    qualification_run_authority: QualificationRunAuthority,
    premerge_command_plan: object,
    postmerge_command_plan: object | None = None,
    qualified_premerge_authority: object | None = None,
    findings: Sequence[QualificationFinding] = (),
    campaign_profile: CampaignProfile | None = None,
) -> GateDecision:
    """Validate real Lane C plans before entering the closed Gate F evaluator."""

    canonical_contract, contract_issues = _canonical_source_contract(contract)
    if contract_issues or canonical_contract is None:
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=contract_issues)
    contract = canonical_contract
    premerge_candidate = (
        contract.prospective_candidate
        if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
        and contract.prospective_candidate is not None
        else contract.candidate
    )
    try:
        if not isinstance(premerge_command_plan, LaneCIntegratedCommandPlanInput):
            raise ValueError("profile selection requires independently supplied complete compiler inputs")
        selected_profile = campaign_profile_for_inputs(premerge_command_plan.inputs)
        if campaign_profile is not None and (type(campaign_profile) is not CampaignProfile or campaign_profile is not selected_profile):
            raise ValueError("explicit evaluator profile differs from admitted compiler inputs")
        if postmerge_command_plan is not None and (
                not isinstance(postmerge_command_plan, LaneCIntegratedCommandPlanInput)
                or campaign_profile_for_inputs(postmerge_command_plan.inputs) is not selected_profile):
            raise ValueError("premerge and postmerge compiler profiles differ")
    except (TypeError, ValueError) as error:
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=(ValidationIssue(
            "campaign-profile-mismatch", "$.premerge_command_plan", str(error)),))
    validated_premerge, premerge_issues = validate_integrated_lane_c_command_plan(
        premerge_command_plan,
        candidate=premerge_candidate,
        profile=selected_profile,
    )
    validated_postmerge: _ValidatedLaneCCommandPlan | None = None
    postmerge_issues: tuple[ValidationIssue, ...] = ()
    if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE:
        validated_postmerge, postmerge_issues = (
            validate_integrated_lane_c_command_plan(
                postmerge_command_plan,
                candidate=contract.candidate,
                profile=selected_profile,
            )
        )
    elif postmerge_command_plan is not None:
        postmerge_issues = (
            ValidationIssue(
                "unexpected-postmerge-command-plan",
                "$.postmerge_command_plan",
                "a premerge contract cannot carry post-merge command authority",
            ),
        )
    plan_issues = tuple((*premerge_issues, *postmerge_issues))
    if (
        plan_issues
        or validated_premerge is None
        or (
            contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
            and validated_postmerge is None
        )
    ):
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=plan_issues)
    return _evaluate_gate_with_validated_command_plans(
        contract,
        dag,
        evidence_order,
        claims,
        qualification_run_authority=qualification_run_authority,
        premerge_command_plan=validated_premerge,
        postmerge_command_plan=validated_postmerge,
        qualified_premerge_authority=qualified_premerge_authority,
        findings=findings,
        campaign_profile=selected_profile,
    )


def _evaluate_gate_with_validated_command_plans(
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[EvidenceClaim],
    *,
    qualification_run_authority: QualificationRunAuthority,
    premerge_command_plan: _ValidatedLaneCCommandPlan,
    postmerge_command_plan: _ValidatedLaneCCommandPlan | None = None,
    qualified_premerge_authority: object | None = None,
    findings: Sequence[QualificationFinding] = (),
    campaign_profile: CampaignProfile = CampaignProfile.EXISTING,
) -> GateDecision:
    """Return exactly one of Lane A's eight frozen decision states.

    This evaluator accepts evidence summaries only after Lane A receipt and
    artifact validation.  Structural contradictions remain independently
    fail-closed here so a caller cannot turn an invalid summary into a generic
    incomplete result.
    """

    canonical_contract, contract_issues = _canonical_source_contract(contract)
    if contract_issues or canonical_contract is None:
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=contract_issues)
    contract = canonical_contract
    premerge_candidate = (
        contract.prospective_candidate
        if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
        and contract.prospective_candidate is not None
        else contract.candidate
    )
    expected_premerge_digest = candidate_identity_sha256(premerge_candidate)
    premerge_plan_issues: tuple[ValidationIssue, ...] = ()
    canonical_premerge_plan: _ValidatedLaneCCommandPlan | None = None
    if not isinstance(premerge_command_plan, _ValidatedLaneCCommandPlan):
        premerge_plan_issues = (
            ValidationIssue(
                "validated-lane-c-plan-type",
                "$.premerge_command_plan",
                "core evaluator requires Lane C validated plan authority",
            ),
        )
    elif premerge_command_plan.candidate_identity_sha256 != expected_premerge_digest:
        premerge_plan_issues = (
            ValidationIssue(
                "validated-lane-c-plan-candidate-mismatch",
                "$.premerge_command_plan",
                "validated premerge plan belongs to another candidate",
            ),
        )
    else:
        canonical_premerge_plan = premerge_command_plan
    canonical_postmerge_plan: _ValidatedLaneCCommandPlan | None = None
    postmerge_plan_issues: tuple[ValidationIssue, ...] = ()
    if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE:
        expected_postmerge_digest = candidate_identity_sha256(contract.candidate)
        if not isinstance(postmerge_command_plan, _ValidatedLaneCCommandPlan):
            postmerge_plan_issues = (
                ValidationIssue(
                    "validated-lane-c-plan-type",
                    "$.postmerge_command_plan",
                    "postmerge evaluation requires Lane C validated plan authority",
                ),
            )
        elif postmerge_command_plan.candidate_identity_sha256 != expected_postmerge_digest:
            postmerge_plan_issues = (
                ValidationIssue(
                    "validated-lane-c-plan-candidate-mismatch",
                    "$.postmerge_command_plan",
                    "validated postmerge plan belongs to another candidate",
                ),
            )
        else:
            canonical_postmerge_plan = postmerge_command_plan
    elif postmerge_command_plan is not None:
        postmerge_plan_issues = (
            ValidationIssue(
                "unexpected-postmerge-command-plan",
                "$.postmerge_command_plan",
                "a premerge contract cannot carry post-merge command authority",
            ),
        )
    if (
        canonical_premerge_plan is not None
        and canonical_postmerge_plan is not None
        and canonical_premerge_plan.scenario_catalog_sha256
        == canonical_postmerge_plan.scenario_catalog_sha256
    ):
        postmerge_plan_issues = tuple(
            (
                *postmerge_plan_issues,
                ValidationIssue(
                    "scenario-catalog-cross-candidate-reuse",
                    "$.postmerge_command_plan.scenario_catalog_sha256",
                    "prospective and accepted candidates must carry independently candidate-bound scenario catalogs",
                ),
            )
        )
    canonical_dag, canonical_order, compiler_issues = _revalidate_compiler_outputs(
        contract,
        dag,
        evidence_order,
    )
    compiler_issues = tuple(
        (
            *compiler_issues,
            *premerge_plan_issues,
            *postmerge_plan_issues,
        )
    )
    if (
        compiler_issues
        or canonical_dag is None
        or canonical_order is None
        or canonical_premerge_plan is None
        or (
            contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE
            and canonical_postmerge_plan is None
        )
    ):
        return _decision(
            DecisionStatus.INVALID_EVIDENCE,
            issues=compiler_issues,
        )
    dag = canonical_dag
    evidence_order = canonical_order
    try:
        canonical_commands = {command.command_id: command
                              for command in lane_c_command_authorities(profile=campaign_profile)}
    except (TypeError, ValueError) as error:
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=(ValidationIssue(
            "campaign-profile-mismatch", "$.campaign_profile", str(error)),))

    validated_claims, evidence_issues = compile_evidence_claims(
        evidence_order,
        expected_candidate=contract.candidate,
        expected_qualification_run=qualification_run_authority,
        expected_premerge_candidate=premerge_candidate,
        claims=claims,
    )
    validation_issues = list(evidence_issues)
    postmerge_authority_issues: list[ValidationIssue] = []
    validation_issues.extend(_validate_findings(findings))
    if validated_claims is not None:
        validation_issues.extend(
            _receipt_command_issues(
                validated_claims,
                canonical_commands,
                premerge_plan=canonical_premerge_plan,
                postmerge_plan=canonical_postmerge_plan,
                campaign_profile=campaign_profile,
            )
        )
        validation_issues.extend(_phase_issues(contract, validated_claims))
    if validation_issues or validated_claims is None:
        return _decision(
            DecisionStatus.INVALID_EVIDENCE,
            issues=validation_issues,
        )

    claims = validated_claims
    by_layer = claims_by_layer(claims)
    by_node = dag.by_id()
    invalid_prerequisites = [
        node_id
        for node_id, node in by_node.items()
        if node.authority.status is PrerequisiteStatus.INVALID
    ]
    invalid_evidence_layers = [
        layer
        for layer, claim in by_layer.items()
        if claim.status in {
            EvidenceStatus.INVALID,
            EvidenceStatus.STALE,
            EvidenceStatus.SUPERSEDED,
        }
    ]
    if validation_issues or invalid_prerequisites or invalid_evidence_layers:
        return _decision(
            DecisionStatus.INVALID_EVIDENCE,
            issues=validation_issues,
            issue_codes=(
                *(("invalid-prerequisite-authority",) if invalid_prerequisites else ()),
                *(("invalid-evidence-state",) if invalid_evidence_layers else ()),
            ),
        )

    failed_prerequisites = [
        node_id
        for node_id, node in by_node.items()
        if node.authority.status is PrerequisiteStatus.FAILED
    ]
    failed_layers = [
        layer
        for layer, claim in by_layer.items()
        if claim.status is EvidenceStatus.FAILED
    ]
    unresolved_blocking = [
        finding
        for finding in findings
        if not finding.resolved
        and finding.severity in {FindingSeverity.P0, FindingSeverity.P1, FindingSeverity.P2}
    ]
    if failed_prerequisites or failed_layers or unresolved_blocking:
        return _decision(
            DecisionStatus.FAILED,
            issue_codes=(
                *(("failed-prerequisite",) if failed_prerequisites else ()),
                *(("failed-evidence",) if failed_layers else ()),
                *(("unresolved-blocking-finding",) if unresolved_blocking else ()),
            ),
            failed_layers=failed_layers,
        )

    premerge_ids = _stage_node_ids(dag, PrerequisiteStage.PREMERGE)
    merge_ids = _stage_node_ids(dag, PrerequisiteStage.MERGE)
    postmerge_ids = _stage_node_ids(dag, PrerequisiteStage.POSTMERGE)
    missing_premerge = [
        node_id
        for node_id in premerge_ids
        if by_node[node_id].authority.status is not PrerequisiteStatus.ACCEPTED
    ]
    if missing_premerge:
        return _decision(
            DecisionStatus.BLOCKED_PREREQUISITE,
            issue_codes=("unmet-premerge-prerequisite",),
            missing_prerequisites=missing_premerge,
        )

    if contract.candidate.subject_kind is CandidateSubjectKind.POST_MERGE:
        missing_merge = [
            node_id
            for node_id in merge_ids
            if by_node[node_id].authority.status is not PrerequisiteStatus.ACCEPTED
        ]
        if missing_merge:
            return _decision(
                DecisionStatus.BLOCKED_PREREQUISITE,
                issue_codes=("unmet-merge-prerequisite",),
                missing_prerequisites=missing_merge,
            )

    required_premerge = set(PREMERGE_EVIDENCE_LAYERS)
    missing_layers = [layer for layer in required_premerge if layer not in by_layer]
    unavailable_layers = [
        layer
        for layer in required_premerge
        if layer in by_layer and by_layer[layer].status is EvidenceStatus.UNAVAILABLE
    ]
    not_run_layers = [
        layer
        for layer in required_premerge
        if layer in by_layer and by_layer[layer].status is EvidenceStatus.NOT_RUN
    ]
    active_premerge = [
        claim
        for layer, claim in by_layer.items()
        if layer in required_premerge
        and claim.status not in {EvidenceStatus.NOT_RUN, EvidenceStatus.UNAVAILABLE}
    ]
    if not active_premerge and not unavailable_layers:
        return _decision(
            DecisionStatus.NOT_RUN,
            issue_codes=("qualification-not-run",),
            missing_layers=(*missing_layers, *not_run_layers),
        )

    nonpassed_premerge = [
        layer
        for layer in required_premerge
        if layer not in by_layer or by_layer[layer].status is not EvidenceStatus.PASSED
    ]
    if nonpassed_premerge:
        return _decision(
            DecisionStatus.RUNNING_RECEIPTS_INCOMPLETE,
            issue_codes=("premerge-receipts-incomplete",),
            missing_layers=nonpassed_premerge,
            unavailable_layers=unavailable_layers,
        )

    output_issues = tuple(
        (
            *_required_output_issues(
                dag,
                claims,
                premerge_ids,
                canonical_commands,
                campaign_profile=campaign_profile,
            ),
            *_command_coverage_issues(
                claims,
                canonical_commands,
                PREMERGE_EVIDENCE_LAYERS,
                campaign_profile=campaign_profile,
            ),
        )
    )
    if output_issues:
        return _decision(DecisionStatus.INVALID_EVIDENCE, issues=output_issues)

    if contract.candidate.subject_kind is CandidateSubjectKind.PROSPECTIVE_MERGE:
        return _decision(
            DecisionStatus.QUALIFIED_PREMERGE,
            qualified_premerge_authority=_make_qualified_premerge_authority(
                contract,
                dag,
                evidence_order,
                claims,
                canonical_premerge_plan,
                qualification_run_authority,
            ),
        )

    if contract.candidate.subject_kind is CandidateSubjectKind.CANDIDATE:
        # A clean branch head can run through ordinary evidence, but it cannot
        # claim the prospective merge-tree layer without changing subject kind.
        return _decision(
            DecisionStatus.RUNNING_RECEIPTS_INCOMPLETE,
            issue_codes=("prospective-merge-identity-not-frozen",),
            missing_layers=(EvidenceLayer.PROSPECTIVE_MERGE_TREE,),
        )

    postmerge_claim = by_layer.get(EvidenceLayer.POST_MERGE)
    if postmerge_claim is None or postmerge_claim.status in {
        EvidenceStatus.NOT_RUN,
        EvidenceStatus.UNAVAILABLE,
    }:
        return _decision(
            DecisionStatus.MERGED_POSTMERGE_PENDING,
            issue_codes=("postmerge-proof-pending",),
            missing_layers=(EvidenceLayer.POST_MERGE,),
            unavailable_layers=(
                (EvidenceLayer.POST_MERGE,)
                if postmerge_claim is not None
                and postmerge_claim.status is EvidenceStatus.UNAVAILABLE
                else ()
            ),
        )

    # A persisted premerge decision is consumed only by actual post-merge
    # evidence.  Checking it before the pending branch would make a merged
    # candidate invalid merely because its required later proof is absent.
    # Keep these issues separate until output validation so a malformed
    # authority cannot mask the concrete missing/wrong receipt it accompanies.
    postmerge_authority_issues.extend(
        _qualified_premerge_authority_issues(
            qualified_premerge_authority,
            contract=contract,
            dag=dag,
            evidence_order=evidence_order,
            claims=claims,
            command_plan=canonical_premerge_plan,
            qualification_run=qualification_run_authority,
        )
    )
    if (
        not postmerge_authority_issues
        and isinstance(qualified_premerge_authority, QualifiedPremergeAuthority)
    ):
        governed_node_identities = {
            node.authority.identity_sha256
            for node in dag.nodes
            if node.spec.stage in {PrerequisiteStage.MERGE, PrerequisiteStage.POSTMERGE}
        }
        governed_outputs = tuple(
            output
            for claim in claims
            for output in claim.receipt_outputs
            if output.requirement_id in governed_node_identities
            or claim.layer is EvidenceLayer.POST_MERGE
        )
        if not governed_outputs or any(
            output.qualified_premerge_authority_sha256
            != qualified_premerge_authority.canonical_sha256
            for output in governed_outputs
        ):
            postmerge_authority_issues.append(
                ValidationIssue(
                    "postmerge-premerge-authority-chain-mismatch",
                    "$.evidence_claims",
                    "merge/postmerge receipts do not seal the exact earlier qualified decision",
                )
            )
    if postmerge_claim.status is not EvidenceStatus.PASSED:
        return _decision(
            DecisionStatus.RUNNING_RECEIPTS_INCOMPLETE,
            issue_codes=("postmerge-receipts-incomplete",),
            missing_layers=(EvidenceLayer.POST_MERGE,),
        )

    missing_postmerge = [
        node_id
        for node_id in postmerge_ids
        if by_node[node_id].authority.status is not PrerequisiteStatus.ACCEPTED
    ]
    if missing_postmerge:
        # A passed post-merge receipt cannot outrun the source-contract proof
        # nodes that authorize it.
        return _decision(
            DecisionStatus.INVALID_EVIDENCE,
            issue_codes=("postmerge-evidence-before-authority",),
            missing_prerequisites=missing_postmerge,
        )

    output_issues = tuple(
        (
            *_required_output_issues(
                dag,
                claims,
                (*premerge_ids, *merge_ids, *postmerge_ids),
                canonical_commands,
                campaign_profile=campaign_profile,
            ),
            *_command_coverage_issues(
                claims,
                canonical_commands,
                tuple(EvidenceLayer),
                campaign_profile=campaign_profile,
            ),
        )
    )
    if output_issues or postmerge_authority_issues:
        return _decision(
            DecisionStatus.INVALID_EVIDENCE,
            issues=(*postmerge_authority_issues, *output_issues),
        )

    # All 18 exact layers are passed, every source/merge/postmerge prerequisite
    # is accepted, and earlier branches ruled out every missing receipt,
    # unauthorized skip, identity drift, failed constituent, and P0/P1/P2.
    return _decision(DecisionStatus.COMPLETE)


def evaluate_gate_issues(
    contract: SourceContract,
    dag: PrerequisiteDAG,
    evidence_order: EvidencePartialOrder,
    claims: Sequence[EvidenceClaim],
    *,
    qualification_run_authority: QualificationRunAuthority,
    premerge_command_plan: object,
    postmerge_command_plan: object | None = None,
    qualified_premerge_authority: object | None = None,
    findings: Sequence[QualificationFinding] = (),
) -> tuple[ValidationIssue, ...]:
    """Public Lane D adapter over the actual A/B/C decision authority.

    Mutation evaluation receives success only from the real closed evaluator.
    Every non-complete decision becomes a stable issue; this adapter contains
    no second structural oracle and accepts no prevalidated Boolean.
    """

    decision = evaluate_gate(
        contract,
        dag,
        evidence_order,
        claims,
        qualification_run_authority=qualification_run_authority,
        premerge_command_plan=premerge_command_plan,
        postmerge_command_plan=postmerge_command_plan,
        qualified_premerge_authority=qualified_premerge_authority,
        findings=findings,
    )
    if decision.status is DecisionStatus.COMPLETE:
        return ()
    issues = set(decision.validation_issues)
    existing_codes = {issue.code for issue in issues}
    for code in decision.issue_codes:
        if code not in existing_codes:
            issues.add(
                ValidationIssue(
                    code,
                    "$.gate_decision",
                    f"Gate F decision is {decision.status.value}",
                )
            )
    if not issues:
        issues.add(
            ValidationIssue(
                decision.status.value,
                "$.gate_decision",
                "Gate F did not reach complete",
            )
        )
    return tuple(sorted(issues))


__all__ = [
    "FindingSeverity",
    "GateDecision",
    "PREMERGE_EVIDENCE_LAYERS",
    "QualificationFinding",
    "QualifiedPremergeAuthority",
    "evaluate_gate",
    "evaluate_gate_issues",
]
