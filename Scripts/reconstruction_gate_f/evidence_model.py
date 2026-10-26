"""Formal evidence partial order and exact-layer evidence claims for Gate F.

An edge authorizes progression only.  It never authorizes substitution: a
receipt at one layer satisfies exactly that layer and no lower, higher, or
horizontal obligation.
"""

from __future__ import annotations

import heapq
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any

from .canonical_json import canonical_sha256, to_primitive
from .receipt_schema import REQUIRED_ARTIFACT_KINDS
from .receipt_validator import (
    ArtifactExpectation,
    CommandAuthorityExpectation,
    CommandPrerequisiteExpectation,
    ExecutionIntervalExpectation,
    QualificationRunAuthority,
    ReceiptValidationContext,
    validate_receipt,
)
from .schema import (
    ArtifactKind,
    CandidateIdentity,
    EvidenceLayer,
    EvidenceStatus,
    QualificationPhase,
    ReceiptType,
    STABLE_ID_RE,
    ValidationIssue,
    candidate_identity_sha256,
    candidate_to_mapping,
    enum_value,
    is_integer,
    is_sha256,
    parse_candidate_identity,
    same_candidate_authority,
)

EVIDENCE_PARTIAL_ORDER_SCHEMA_VERSION = 1


@dataclass(frozen=True)
class EvidencePartialOrder:
    layers: tuple[EvidenceLayer, ...]
    edges: tuple[tuple[EvidenceLayer, EvidenceLayer], ...]
    topological_order: tuple[EvidenceLayer, ...]
    transitive_predecessors: Mapping[EvidenceLayer, frozenset[EvidenceLayer]]

    def precedes(self, lower: EvidenceLayer, higher: EvidenceLayer) -> bool:
        return lower in self.transitive_predecessors[higher]

    def can_satisfy(self, provided: EvidenceLayer, required: EvidenceLayer) -> bool:
        """Return true only for the exact layer.

        The order determines which earlier evidence must exist before a later
        claim is coherent.  It deliberately does *not* implement a lattice in
        which a higher or lower element can be relabelled as another layer.
        """

        return provided is required


@dataclass(frozen=True)
class EvidenceReceiptInput:
    """One raw receipt plus the exact Lane A validation plan for that run."""

    receipt: object
    context: object


@dataclass(frozen=True)
class EvidenceReceiptOutput:
    """Internal projection created only after Lane A validation succeeds."""

    receipt_id: str
    canonical_sha256: str
    qualification_run: QualificationRunAuthority
    receipt_type: ReceiptType
    command_id: str
    requirement_id: str
    scenario_id: str
    command_plan_sha256: str
    command_record_sha256: str
    command_authority: CommandAuthorityExpectation
    execution_interval: ExecutionIntervalExpectation
    qualified_premerge_authority_sha256: str | None
    constituent_selector_ids: tuple[str, ...]
    runtime_resolution: object | None


@dataclass(frozen=True)
class EvidenceArtifactOutput:
    """Internal projection of one descriptor-verified physical artifact."""

    artifact_id: str
    sha256: str
    producer_receipt_id: str
    command_output: str


@dataclass(frozen=True)
class EvidenceClaim:
    """Untrusted evidence input; no success or artifact Boolean is accepted."""

    layer: EvidenceLayer
    receipt_inputs: tuple[EvidenceReceiptInput, ...]


@dataclass(frozen=True)
class ValidatedEvidenceClaim:
    """Immutable projection emitted only from valid raw Lane A receipts."""

    layer: EvidenceLayer
    status: EvidenceStatus
    candidate_identity_sha256: str | None
    receipt_outputs: tuple[EvidenceReceiptOutput, ...]
    artifact_outputs: tuple[EvidenceArtifactOutput, ...]
    artifact_kinds: tuple[ArtifactKind, ...]
    authorized_skip_ids: tuple[str, ...]
    failed_constituent_count: int

    @property
    def receipt_ids(self) -> tuple[str, ...]:
        return tuple(output.receipt_id for output in self.receipt_outputs)

    @property
    def artifact_ids(self) -> tuple[str, ...]:
        return tuple(output.artifact_id for output in self.artifact_outputs)


DEFAULT_EVIDENCE_EDGES: tuple[tuple[EvidenceLayer, EvidenceLayer], ...] = (
    (EvidenceLayer.SOURCE_GOVERNANCE, EvidenceLayer.HOSTED_PURE),
    (EvidenceLayer.SOURCE_GOVERNANCE, EvidenceLayer.NATIVE_NORMAL),
    (EvidenceLayer.HOSTED_PURE, EvidenceLayer.XCODE_FOCUSED),
    (EvidenceLayer.NATIVE_NORMAL, EvidenceLayer.NATIVE_ASAN),
    (EvidenceLayer.NATIVE_NORMAL, EvidenceLayer.NATIVE_UBSAN),
    (EvidenceLayer.XCODE_FOCUSED, EvidenceLayer.XCODE_FULL_CORETESTS),
    (EvidenceLayer.NATIVE_NORMAL, EvidenceLayer.SIGNED_XPC),
    (EvidenceLayer.NATIVE_ASAN, EvidenceLayer.SIGNED_XPC),
    (EvidenceLayer.NATIVE_UBSAN, EvidenceLayer.SIGNED_XPC),
    (EvidenceLayer.XCODE_FULL_CORETESTS, EvidenceLayer.SIGNED_XPC),
    (EvidenceLayer.SIGNED_XPC, EvidenceLayer.RELEASE_BUILD),
    (EvidenceLayer.XCODE_FULL_CORETESTS, EvidenceLayer.RELEASE_BUILD),
    (EvidenceLayer.RELEASE_BUILD, EvidenceLayer.STRICT_SIGNING),
    (EvidenceLayer.SIGNED_XPC, EvidenceLayer.STRICT_SIGNING),
    (EvidenceLayer.RELEASE_BUILD, EvidenceLayer.INSTALLED_SOURCE_EQUALITY),
    (EvidenceLayer.STRICT_SIGNING, EvidenceLayer.INSTALLED_SOURCE_EQUALITY),
    (EvidenceLayer.INSTALLED_SOURCE_EQUALITY, EvidenceLayer.INSTALLED_LAUNCH_LOG),
    (EvidenceLayer.INSTALLED_LAUNCH_LOG, EvidenceLayer.INSTALLED_WORKFLOW),
    (EvidenceLayer.INSTALLED_LAUNCH_LOG, EvidenceLayer.INSTALLED_ACCESSIBILITY),
    (EvidenceLayer.INSTALLED_WORKFLOW, EvidenceLayer.STRESS_RECOVERY),
    (EvidenceLayer.INSTALLED_ACCESSIBILITY, EvidenceLayer.STRESS_RECOVERY),
    (EvidenceLayer.STRESS_RECOVERY, EvidenceLayer.INDEPENDENT_REVIEW),
    (EvidenceLayer.INDEPENDENT_REVIEW, EvidenceLayer.PROSPECTIVE_MERGE_TREE),
    (EvidenceLayer.PROSPECTIVE_MERGE_TREE, EvidenceLayer.POST_MERGE),
)

MANDATORY_EVIDENCE_EDGES = frozenset(DEFAULT_EVIDENCE_EDGES)


# A generic command, skip, or artifact wrapper is not semantic proof that an
# evidence layer's specialized authority held.  A passed layer must contain at
# least one Lane-A-validated receipt of the exact primary type below.  Source
# governance has no dedicated Lane A receipt type, so its least-generic closed
# authority is the descriptor-bound artifact manifest.
REQUIRED_RECEIPT_TYPES_BY_LAYER: Mapping[EvidenceLayer, frozenset[ReceiptType]] = (
    MappingProxyType(
        {
            EvidenceLayer.SOURCE_GOVERNANCE: frozenset(
                {ReceiptType.ARTIFACT_MANIFEST}
            ),
            EvidenceLayer.HOSTED_PURE: frozenset({ReceiptType.TEST_RESULT}),
            EvidenceLayer.NATIVE_NORMAL: frozenset({ReceiptType.TEST_RESULT}),
            EvidenceLayer.NATIVE_ASAN: frozenset({ReceiptType.NATIVE_SANITIZER}),
            EvidenceLayer.NATIVE_UBSAN: frozenset({ReceiptType.NATIVE_SANITIZER}),
            EvidenceLayer.XCODE_FOCUSED: frozenset({ReceiptType.TEST_RESULT}),
            EvidenceLayer.XCODE_FULL_CORETESTS: frozenset(
                {ReceiptType.TEST_RESULT}
            ),
            EvidenceLayer.SIGNED_XPC: frozenset({ReceiptType.SIGNED_XPC}),
            EvidenceLayer.RELEASE_BUILD: frozenset({ReceiptType.RELEASE_BUILD}),
            EvidenceLayer.STRICT_SIGNING: frozenset({ReceiptType.STRICT_SIGNING}),
            EvidenceLayer.INSTALLED_SOURCE_EQUALITY: frozenset(
                {ReceiptType.INSTALLED_SOURCE_EQUALITY}
            ),
            EvidenceLayer.INSTALLED_LAUNCH_LOG: frozenset(
                {ReceiptType.INSTALLED_LAUNCH_LOG}
            ),
            EvidenceLayer.INSTALLED_WORKFLOW: frozenset(
                {ReceiptType.INSTALLED_WORKFLOW}
            ),
            EvidenceLayer.INSTALLED_ACCESSIBILITY: frozenset(
                {ReceiptType.INSTALLED_ACCESSIBILITY}
            ),
            EvidenceLayer.STRESS_RECOVERY: frozenset({ReceiptType.STRESS_RECOVERY}),
            EvidenceLayer.INDEPENDENT_REVIEW: frozenset(
                {ReceiptType.INDEPENDENT_REVIEW}
            ),
            EvidenceLayer.PROSPECTIVE_MERGE_TREE: frozenset(
                {ReceiptType.PROSPECTIVE_MERGE_TREE}
            ),
            EvidenceLayer.POST_MERGE: frozenset({ReceiptType.POST_MERGE}),
        }
    )
)


def compile_evidence_partial_order(
    layers: Sequence[EvidenceLayer] = tuple(EvidenceLayer),
    edges: Sequence[tuple[EvidenceLayer, EvidenceLayer]] = DEFAULT_EVIDENCE_EDGES,
) -> tuple[EvidencePartialOrder | None, tuple[ValidationIssue, ...]]:
    issues: list[ValidationIssue] = []
    if not isinstance(layers, (tuple, list)):
        return None, (
            ValidationIssue(
                "evidence-layers-type",
                "$.evidence_partial_order.layers",
                "layers must be a tuple or list",
            ),
        )
    if not isinstance(edges, (tuple, list)):
        return None, (
            ValidationIssue(
                "evidence-edges-type",
                "$.evidence_partial_order.edges",
                "edges must be a tuple or list",
            ),
        )
    layer_tuple = tuple(layers)
    valid_layers = tuple(
        layer for layer in layer_tuple if isinstance(layer, EvidenceLayer)
    )
    layer_set = set(valid_layers)
    frozen_set = set(EvidenceLayer)
    if any(not isinstance(layer, EvidenceLayer) for layer in layer_tuple):
        issues.append(
            ValidationIssue(
                "unknown-evidence-layer",
                "$.evidence_partial_order.layers",
                "layer is outside the frozen EvidenceLayer enum",
            )
        )
    if len(valid_layers) != len(layer_set):
        issues.append(
            ValidationIssue(
                "duplicate-evidence-layer",
                "$.evidence_partial_order.layers",
                "evidence layers must be unique",
            )
        )
    missing = frozen_set - layer_set
    extra = layer_set - frozen_set
    if missing or extra or len(layer_tuple) != len(EvidenceLayer):
        issues.append(
            ValidationIssue(
                "evidence-layer-vocabulary",
                "$.evidence_partial_order.layers",
                "partial order must contain exactly the frozen 18 evidence layers",
            )
        )

    normalized_edges: list[tuple[EvidenceLayer, EvidenceLayer]] = []
    seen_edges: set[tuple[EvidenceLayer, EvidenceLayer]] = set()
    for index, edge in enumerate(edges):
        path = f"$.evidence_partial_order.edges[{index}]"
        if not isinstance(edge, tuple) or len(edge) != 2:
            issues.append(ValidationIssue("edge-shape", path, "edge must be a two-layer tuple"))
            continue
        lower, higher = edge
        if (
            not isinstance(lower, EvidenceLayer)
            or not isinstance(higher, EvidenceLayer)
            or lower not in layer_set
            or higher not in layer_set
        ):
            issues.append(
                ValidationIssue(
                    "unknown-evidence-edge",
                    path,
                    "edge references a layer outside the frozen vocabulary",
                )
            )
            continue
        if lower is higher:
            issues.append(ValidationIssue("evidence-cycle", path, "self-edge creates a cycle"))
        if edge in seen_edges:
            issues.append(ValidationIssue("duplicate-evidence-edge", path, "edge must be unique"))
        seen_edges.add(edge)
        normalized_edges.append(edge)

    missing_mandatory_edges = MANDATORY_EVIDENCE_EDGES - set(normalized_edges)
    if missing_mandatory_edges:
        issues.append(
            ValidationIssue(
                "missing-mandatory-evidence-edge",
                "$.evidence_partial_order.edges",
                "required progression edges are absent: "
                + ", ".join(
                    f"{lower.value}->{higher.value}"
                    for lower, higher in sorted(
                        missing_mandatory_edges,
                        key=lambda item: (item[0].value, item[1].value),
                    )
                ),
            )
        )

    if any(
        issue.code
        in {
            "unknown-evidence-layer",
            "evidence-layer-vocabulary",
            "duplicate-evidence-layer",
        }
        for issue in issues
    ):
        return None, tuple(sorted(set(issues)))

    indegree = {layer: 0 for layer in layer_tuple}
    dependents: dict[EvidenceLayer, set[EvidenceLayer]] = {layer: set() for layer in layer_tuple}
    direct_predecessors: dict[EvidenceLayer, set[EvidenceLayer]] = {
        layer: set() for layer in layer_tuple
    }
    for lower, higher in normalized_edges:
        if lower not in indegree or higher not in indegree or lower is higher:
            continue
        if higher not in dependents[lower]:
            dependents[lower].add(higher)
            direct_predecessors[higher].add(lower)
            indegree[higher] += 1

    ready = [(layer.value, layer) for layer, degree in indegree.items() if degree == 0]
    heapq.heapify(ready)
    ordered: list[EvidenceLayer] = []
    while ready:
        _, layer = heapq.heappop(ready)
        ordered.append(layer)
        for dependent in sorted(dependents[layer], key=lambda item: item.value):
            indegree[dependent] -= 1
            if indegree[dependent] == 0:
                heapq.heappush(ready, (dependent.value, dependent))
    if len(ordered) != len(layer_tuple):
        cyclic = sorted((layer.value for layer, degree in indegree.items() if degree > 0))
        issues.append(
            ValidationIssue(
                "evidence-cycle",
                "$.evidence_partial_order.edges",
                f"cycle involves: {', '.join(cyclic)}",
            )
        )

    predecessors: dict[EvidenceLayer, frozenset[EvidenceLayer]] = {}
    for layer in ordered:
        closure: set[EvidenceLayer] = set()
        for direct in direct_predecessors[layer]:
            closure.add(direct)
            closure.update(predecessors.get(direct, frozenset()))
        predecessors[layer] = frozenset(closure)

    if issues:
        return None, tuple(sorted(set(issues)))
    return (
        EvidencePartialOrder(
            layers=tuple(EvidenceLayer),
            edges=tuple(sorted(normalized_edges, key=lambda edge: (edge[0].value, edge[1].value))),
            topological_order=tuple(ordered),
            transitive_predecessors=MappingProxyType(predecessors),
        ),
        (),
    )


def default_evidence_partial_order() -> EvidencePartialOrder:
    order, issues = compile_evidence_partial_order()
    if issues or order is None:
        raise AssertionError(issues)
    return order


def evidence_partial_order_to_mapping(order: EvidencePartialOrder) -> dict[str, Any]:
    """Return Lane E's canonical, closed serialization of the formal order."""

    canonical, issues = _canonical_order(order)
    if issues or canonical is None:
        raise ValueError(
            "invalid evidence partial order: "
            + "; ".join(f"{issue.code}:{issue.path}" for issue in issues)
        )
    order = canonical
    return {
        "schema_version": EVIDENCE_PARTIAL_ORDER_SCHEMA_VERSION,
        "layers": [layer.value for layer in order.layers],
        "edges": [
            {"lower": lower.value, "higher": higher.value}
            for lower, higher in order.edges
        ],
        "topological_order": [layer.value for layer in order.topological_order],
        "transitive_predecessors": [
            {
                "layer": layer.value,
                "predecessors": [
                    predecessor.value
                    for predecessor in sorted(
                        order.transitive_predecessors[layer],
                        key=lambda item: item.value,
                    )
                ],
            }
            for layer in sorted(order.layers, key=lambda item: item.value)
        ],
    }


def evidence_partial_order_sha256(order: EvidencePartialOrder) -> str:
    return canonical_sha256(evidence_partial_order_to_mapping(order))


def _canonical_candidate(
    value: object,
    *,
    path: str,
    issues: list[ValidationIssue],
) -> CandidateIdentity | None:
    if not isinstance(value, CandidateIdentity):
        issues.append(
            ValidationIssue(
                "candidate-type",
                path,
                "candidate must be a Lane A CandidateIdentity",
            )
        )
        return None
    try:
        mapping = candidate_to_mapping(value)
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        issues.append(
            ValidationIssue(
                "candidate-canonicalization",
                path,
                "candidate contains malformed public DTO values",
            )
        )
        return None
    candidate, nested = parse_candidate_identity(mapping, path=path)
    issues.extend(nested)
    return candidate


def _canonical_order(
    value: object,
) -> tuple[EvidencePartialOrder | None, tuple[ValidationIssue, ...]]:
    if not isinstance(value, EvidencePartialOrder):
        return None, (
            ValidationIssue(
                "evidence-partial-order-type",
                "$.evidence_partial_order",
                "order must be an EvidencePartialOrder",
            ),
        )
    try:
        compiled, issues = compile_evidence_partial_order(value.layers, value.edges)
    except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
        return None, (
            ValidationIssue(
                "evidence-partial-order-shape",
                "$.evidence_partial_order",
                "order contains malformed public DTO values",
            ),
        )
    if issues or compiled is None:
        return None, issues
    if compiled != value:
        return None, (
            ValidationIssue(
                "evidence-partial-order-not-canonical",
                "$.evidence_partial_order",
                "order differs from the authoritative compiler output",
            ),
        )
    return compiled, ()


def _snapshot_receipt(
    value: object,
    *,
    path: str,
    issues: list[ValidationIssue],
) -> dict[str, Any] | None:
    try:
        snapshot = to_primitive(value, path=path)
    except (AttributeError, RecursionError, TypeError, ValueError):
        issues.append(
            ValidationIssue(
                "receipt-input-canonicalization",
                path,
                "raw receipt is not a closed canonical JSON value",
            )
        )
        return None
    if not isinstance(snapshot, dict):
        issues.append(
            ValidationIssue(
                "receipt-input-type",
                path,
                "raw receipt must be a JSON object",
            )
        )
        return None
    return snapshot


def _receipt_context_issues(
    value: object,
    *,
    expected_candidate: CandidateIdentity,
    expected_qualification_run: QualificationRunAuthority,
    expected_layer: EvidenceLayer,
    expected_phase: QualificationPhase,
    path: str,
) -> tuple[ValidationIssue, ...]:
    issues: list[ValidationIssue] = []
    if not isinstance(value, ReceiptValidationContext):
        return (
            ValidationIssue(
                "receipt-context-type",
                path,
                "context must be Lane A ReceiptValidationContext",
            ),
        )
    context_candidate = _canonical_candidate(
        value.expected_candidate,
        path=f"{path}.expected_candidate",
        issues=issues,
    )
    if context_candidate is not None and (
        not same_candidate_authority(context_candidate, expected_candidate)
        or candidate_identity_sha256(context_candidate)
        != candidate_identity_sha256(expected_candidate)
    ):
        issues.append(
            ValidationIssue(
                "evidence-candidate-mismatch",
                f"{path}.expected_candidate",
                "receipt validation context belongs to another candidate",
            )
        )
    if value.expected_qualification_run != expected_qualification_run:
        issues.append(
            ValidationIssue(
                "receipt-context-qualification-run-mismatch",
                f"{path}.expected_qualification_run",
                "receipt context belongs to another coordinator-issued qualification run",
            )
        )
    if value.expected_layer is not expected_layer:
        issues.append(
            ValidationIssue(
                "receipt-context-layer-mismatch",
                f"{path}.expected_layer",
                "receipt context belongs to another evidence layer",
            )
        )
    if value.qualification_phase is not expected_phase:
        issues.append(
            ValidationIssue(
                "receipt-context-phase-mismatch",
                f"{path}.qualification_phase",
                "receipt context belongs to another qualification phase",
            )
        )
    if not isinstance(value.expected_receipt_type, ReceiptType):
        issues.append(
            ValidationIssue(
                "receipt-context-receipt-type",
                f"{path}.expected_receipt_type",
                "expected receipt type is outside Lane A's closed enum",
            )
        )
    if value.capture_derived_execution:
        from .executor_request_adapter import INSTALLED_PRODUCER_ROLES
        role = INSTALLED_PRODUCER_ROLES.get(value.expected_command_id)
        if role is not None and value.expected_receipt_type is not role:
            issues.append(ValidationIssue("receipt-context-installed-role", path,
                "installed command context cannot substitute another evidence role"))
    for field in (
        "expected_receipt_id",
        "expected_requirement_id",
        "expected_command_id",
        "expected_scenario_id",
        "expected_artifact_root_id",
    ):
        item = getattr(value, field)
        if not isinstance(item, str) or STABLE_ID_RE.fullmatch(item) is None:
            issues.append(
                ValidationIssue(
                    "receipt-context-stable-id",
                    f"{path}.{field}",
                    "expected command-plan ID is malformed",
                )
            )
    if value.expected_qualified_premerge_authority_sha256 is not None and not is_sha256(
        value.expected_qualified_premerge_authority_sha256
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-qualified-premerge-authority",
                f"{path}.expected_qualified_premerge_authority_sha256",
                "expected premerge authority must be null or lowercase SHA-256",
            )
        )
    for field in (
        "expected_command_plan_sha256",
        "expected_command_record_sha256",
    ):
        if not is_sha256(getattr(value, field)):
            issues.append(
                ValidationIssue(
                    "receipt-context-sha256",
                    f"{path}.{field}",
                    "expected command-plan authority must be lowercase SHA-256",
                )
            )
    if not isinstance(value.expected_command_authority, CommandAuthorityExpectation):
        issues.append(
            ValidationIssue(
                "receipt-context-command-authority",
                f"{path}.expected_command_authority",
                "expected command authority must be the closed Lane A DTO",
            )
        )
    else:
        authority = value.expected_command_authority
        if (
            not isinstance(authority.host, str)
            or STABLE_ID_RE.fullmatch(authority.host) is None
            or not isinstance(authority.execution_mode, str)
            or STABLE_ID_RE.fullmatch(authority.execution_mode) is None
            or not all(
                is_sha256(item)
                for item in (
                    authority.argv_sha256,
                    authority.working_directory_sha256,
                    authority.environment_sha256,
                )
            )
            or authority.generated_artifacts
            != tuple(sorted(set(authority.generated_artifacts)))
            or authority.generated_logs != tuple(sorted(set(authority.generated_logs)))
            or not isinstance(authority.prerequisite_receipts, tuple)
            or any(
                not isinstance(item, CommandPrerequisiteExpectation)
                or not isinstance(item.command_id, str)
                or STABLE_ID_RE.fullmatch(item.command_id) is None
                or not isinstance(item.receipt_id, str)
                or STABLE_ID_RE.fullmatch(item.receipt_id) is None
                or not is_sha256(item.canonical_sha256)
                or item.qualification_run_id != expected_qualification_run.run_id
                or item.qualification_run_nonce != expected_qualification_run.nonce
                for item in authority.prerequisite_receipts
            )
            or authority.prerequisite_receipts
            != tuple(sorted(set(authority.prerequisite_receipts)))
        ):
            issues.append(
                ValidationIssue(
                    "receipt-context-command-authority",
                    f"{path}.expected_command_authority",
                    "expected command authority axes are malformed or noncanonical",
                )
            )
    if (
        not isinstance(value.expected_attempt, int)
        or isinstance(value.expected_attempt, bool)
        or value.expected_attempt < 1
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-attempt",
                f"{path}.expected_attempt",
                "expected attempt must be a positive integer",
            )
        )
    if (
        not isinstance(
            value.expected_execution_interval,
            ExecutionIntervalExpectation,
        )
        or not is_integer(value.expected_execution_interval.started_at_unix_ms)
        or value.expected_execution_interval.started_at_unix_ms < 0
        or not is_integer(value.expected_execution_interval.ended_at_unix_ms)
        or value.expected_execution_interval.ended_at_unix_ms
        < value.expected_execution_interval.started_at_unix_ms
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-execution-interval",
                f"{path}.expected_execution_interval",
                "expected descriptor-verified execution interval is malformed",
            )
        )
    if value.expected_executor_id is not None and (
        not isinstance(value.expected_executor_id, str)
        or STABLE_ID_RE.fullmatch(value.expected_executor_id) is None
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-executor-id",
                f"{path}.expected_executor_id",
                "expected executor ID is malformed",
            )
        )
    if not isinstance(value.expected_artifacts, tuple) or any(
        not isinstance(item, ArtifactExpectation)
        or not isinstance(item.artifact_id, str)
        or STABLE_ID_RE.fullmatch(item.artifact_id) is None
        or not isinstance(item.relative_path, str)
        or not isinstance(item.kind, ArtifactKind)
        or not isinstance(item.media_type, str)
        or not isinstance(item.command_output, str)
        or not item.command_output
        for item in value.expected_artifacts
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-artifact-plan",
                f"{path}.expected_artifacts",
                "expected artifacts must be immutable Lane A artifact expectations",
            )
        )
    if not isinstance(value.expected_skips, tuple) or any(
        not isinstance(item, Mapping) for item in value.expected_skips
    ):
        issues.append(
            ValidationIssue(
                "receipt-context-skip-plan",
                f"{path}.expected_skips",
                "expected skips must be an immutable tuple of closed mappings",
            )
        )
    if value.require_physical_artifacts_on_pass is not True:
        issues.append(
            ValidationIssue(
                "physical-artifact-validation-required",
                f"{path}.require_physical_artifacts_on_pass",
                "Lane B never accepts a context that disables physical validation",
            )
        )
    if not isinstance(value.artifact_root, Path) or not value.artifact_root.is_absolute():
        issues.append(
            ValidationIssue(
                "physical-artifact-root-required",
                f"{path}.artifact_root",
                "every submitted receipt requires an absolute physical artifact root",
            )
        )
    return tuple(sorted(set(issues)))


def compile_evidence_claims(
    order: EvidencePartialOrder,
    *,
    expected_candidate: CandidateIdentity,
    expected_qualification_run: QualificationRunAuthority,
    expected_premerge_candidate: CandidateIdentity | None = None,
    claims: Sequence[EvidenceClaim],
) -> tuple[tuple[ValidatedEvidenceClaim, ...] | None, tuple[ValidationIssue, ...]]:
    """Validate raw Lane A receipts and project only verified evidence.

    No caller-authored success, identity, skip, constituent, or artifact
    Boolean enters the projection.  Receipt and artifact fields are copied to
    plain canonical values, checked through Lane A, and only then aggregated.
    """

    issues: list[ValidationIssue] = []
    if (
        not isinstance(expected_qualification_run, QualificationRunAuthority)
        or STABLE_ID_RE.fullmatch(expected_qualification_run.run_id) is None
        or not is_sha256(expected_qualification_run.nonce)
    ):
        return None, (
            ValidationIssue(
                "qualification-run-authority",
                "$.expected_qualification_run",
                "an exact coordinator-issued run ID and nonce are required",
            ),
        )
    canonical_order, order_issues = _canonical_order(order)
    issues.extend(order_issues)
    if canonical_order is None:
        return None, tuple(sorted(set(issues)))
    order = canonical_order
    if not isinstance(claims, (tuple, list)):
        return None, (
            ValidationIssue(
                "array-type",
                "$.evidence_claims",
                "claims must be a tuple or list of EvidenceClaim values",
            ),
        )
    expected_candidate = _canonical_candidate(
        expected_candidate,
        path="$.expected_candidate",
        issues=issues,
    )
    if expected_candidate is None:
        return None, tuple(sorted(set(issues)))
    if expected_premerge_candidate is None:
        expected_premerge_candidate = expected_candidate
    expected_premerge_candidate = _canonical_candidate(
        expected_premerge_candidate,
        path="$.expected_premerge_candidate",
        issues=issues,
    )
    if expected_premerge_candidate is None:
        return None, tuple(sorted(set(issues)))

    validated: list[ValidatedEvidenceClaim] = []
    seen_layers: set[EvidenceLayer] = set()
    seen_receipt_ids: set[str] = set()
    seen_receipt_digests: set[str] = set()
    seen_artifact_ids: set[str] = set()
    receipt_coordinates: set[tuple[object, ...]] = set()

    for index, claim in enumerate(claims):
        path = f"$.evidence_claims[{index}]"
        if not isinstance(claim, EvidenceClaim):
            issues.append(
                ValidationIssue(
                    "evidence-claim-type",
                    path,
                    "claim must be an EvidenceClaim",
                )
            )
            continue
        if not isinstance(claim.layer, EvidenceLayer) or claim.layer not in order.layers:
            issues.append(
                ValidationIssue(
                    "unknown-evidence-layer",
                    f"{path}.layer",
                    "layer is not in the compiled partial order",
                )
            )
            continue
        if claim.layer in seen_layers:
            issues.append(
                ValidationIssue(
                    "duplicate-evidence-claim",
                    f"{path}.layer",
                    "one claim per exact evidence layer is allowed",
                )
            )
        seen_layers.add(claim.layer)
        if not isinstance(claim.receipt_inputs, tuple):
            issues.append(
                ValidationIssue(
                    "tuple-type",
                    f"{path}.receipt_inputs",
                    "raw receipt inputs must be an immutable tuple",
                )
            )
            continue

        expected_claim_candidate = (
            expected_candidate
            if claim.layer is EvidenceLayer.POST_MERGE
            else expected_premerge_candidate
        )
        expected_phase = (
            QualificationPhase.POSTMERGE
            if claim.layer is EvidenceLayer.POST_MERGE
            else QualificationPhase.PREMERGE
        )
        statuses: list[EvidenceStatus] = []
        receipt_outputs: list[EvidenceReceiptOutput] = []
        artifact_outputs: list[EvidenceArtifactOutput] = []
        artifact_kinds: set[ArtifactKind] = set()
        skip_ids: set[str] = set()
        failed_constituent_count = 0

        for input_index, receipt_input in enumerate(claim.receipt_inputs):
            input_path = f"{path}.receipt_inputs[{input_index}]"
            if not isinstance(receipt_input, EvidenceReceiptInput):
                issues.append(
                    ValidationIssue(
                        "receipt-input-type",
                        input_path,
                        "entry must be an EvidenceReceiptInput",
                    )
                )
                continue
            context = receipt_input.context
            context_issues = _receipt_context_issues(
                context,
                expected_candidate=expected_claim_candidate,
                expected_qualification_run=expected_qualification_run,
                expected_layer=claim.layer,
                expected_phase=expected_phase,
                path=f"{input_path}.context",
            )
            issues.extend(context_issues)
            if context_issues or not isinstance(context, ReceiptValidationContext):
                continue

            snapshot = _snapshot_receipt(
                receipt_input.receipt,
                path=f"{input_path}.receipt",
                issues=issues,
            )
            if snapshot is None:
                continue
            try:
                lane_a_issues = validate_receipt(
                    snapshot,
                    context=context,
                    path=f"{input_path}.receipt",
                )
            except (AttributeError, KeyError, RecursionError, TypeError, ValueError):
                issues.append(
                    ValidationIssue(
                        "receipt-validator-exception",
                        f"{input_path}.receipt",
                        "Lane A receipt validation rejected a malformed public DTO",
                    )
                )
                continue
            issues.extend(lane_a_issues)
            if lane_a_issues:
                continue
            if snapshot.get("candidate_identity") != candidate_to_mapping(
                expected_claim_candidate
            ):
                issues.append(
                    ValidationIssue(
                        "receipt-candidate-not-canonical",
                        f"{input_path}.receipt.candidate_identity",
                        "receipt must encode the canonical Lane A candidate mapping",
                    )
                )
                continue

            status, nested = enum_value(
                EvidenceStatus,
                snapshot.get("evidence_status"),
                path=f"{input_path}.receipt.evidence_status",
            )
            issues.extend(nested)
            if isinstance(status, EvidenceStatus):
                statuses.append(status)

            receipt_id = snapshot.get("receipt_id")
            receipt_digest = snapshot.get("canonical_sha256")
            command_id = snapshot.get("command_id")
            requirement_id = snapshot.get("requirement_id")
            scenario_id = snapshot.get("scenario_id")
            command_plan_digest = snapshot.get("command_plan_sha256")
            command_record_digest = snapshot.get("command_record_sha256")
            if (
                isinstance(receipt_id, str)
                and STABLE_ID_RE.fullmatch(receipt_id) is not None
                and is_sha256(receipt_digest)
                and isinstance(command_id, str)
                and STABLE_ID_RE.fullmatch(command_id) is not None
                and isinstance(requirement_id, str)
                and STABLE_ID_RE.fullmatch(requirement_id) is not None
                and isinstance(scenario_id, str)
                and STABLE_ID_RE.fullmatch(scenario_id) is not None
                and is_sha256(command_plan_digest)
                and is_sha256(command_record_digest)
            ):
                receipt_outputs.append(
                    EvidenceReceiptOutput(
                        receipt_id=receipt_id,
                        canonical_sha256=receipt_digest,
                        qualification_run=expected_qualification_run,
                        receipt_type=context.expected_receipt_type,
                        command_id=command_id,
                        requirement_id=requirement_id,
                        scenario_id=scenario_id,
                        command_plan_sha256=command_plan_digest,
                        command_record_sha256=command_record_digest,
                        command_authority=context.expected_command_authority,
                        runtime_resolution=context.expected_runtime_resolution,
                        execution_interval=context.expected_execution_interval,
                        qualified_premerge_authority_sha256=snapshot.get(
                            "qualified_premerge_authority_sha256"
                        ),
                        constituent_selector_ids=tuple(
                            sorted(
                                item["selector_id"]
                                for item in snapshot.get("constituents", [])
                                if isinstance(item, Mapping)
                                and isinstance(item.get("selector_id"), str)
                            )
                        ),
                    )
                )
                if receipt_id in seen_receipt_ids:
                    issues.append(
                        ValidationIssue(
                            "duplicate-receipt-id",
                            f"{input_path}.receipt.receipt_id",
                            "receipt ID is already present in another raw input",
                        )
                    )
                seen_receipt_ids.add(receipt_id)
                if receipt_digest in seen_receipt_digests:
                    issues.append(
                        ValidationIssue(
                            "duplicate-receipt-digest",
                            f"{input_path}.receipt.canonical_sha256",
                            "canonical digest is already present in another raw input",
                        )
                    )
                seen_receipt_digests.add(receipt_digest)

            coordinate = (
                snapshot.get("candidate_identity_sha256"),
                snapshot.get("requirement_id"),
                snapshot.get("scenario_id"),
                snapshot.get("evidence_layer"),
                snapshot.get("attempt"),
            )
            if all(
                isinstance(value, (str, int)) and not isinstance(value, bool)
                for value in coordinate
            ):
                if coordinate in receipt_coordinates:
                    issues.append(
                        ValidationIssue(
                            "duplicate-receipt-coordinate",
                            f"{input_path}.receipt",
                            "receipt execution coordinate is duplicated",
                        )
                    )
                receipt_coordinates.add(coordinate)

            artifact_values = snapshot.get("artifacts")
            if isinstance(artifact_values, list):
                for artifact_index, artifact in enumerate(artifact_values):
                    if not isinstance(artifact, Mapping):
                        continue
                    artifact_id = artifact.get("artifact_id")
                    artifact_sha256 = artifact.get("sha256")
                    producer_receipt_id = artifact.get("producer_receipt_id")
                    command_output = artifact.get("command_output")
                    kind, nested = enum_value(
                        ArtifactKind,
                        artifact.get("kind"),
                        path=(
                            f"{input_path}.receipt.artifacts[{artifact_index}].kind"
                        ),
                    )
                    issues.extend(nested)
                    if isinstance(kind, ArtifactKind):
                        artifact_kinds.add(kind)
                    if (
                        isinstance(artifact_id, str)
                        and STABLE_ID_RE.fullmatch(artifact_id) is not None
                        and is_sha256(artifact_sha256)
                        and isinstance(producer_receipt_id, str)
                        and STABLE_ID_RE.fullmatch(producer_receipt_id) is not None
                        and isinstance(command_output, str)
                        and command_output
                    ):
                        artifact_outputs.append(
                            EvidenceArtifactOutput(
                                artifact_id=artifact_id,
                                sha256=artifact_sha256,
                                producer_receipt_id=producer_receipt_id,
                                command_output=command_output,
                            )
                        )
                        if artifact_id in seen_artifact_ids:
                            issues.append(
                                ValidationIssue(
                                    "duplicate-artifact-id",
                                    (
                                        f"{input_path}.receipt.artifacts"
                                        f"[{artifact_index}].artifact_id"
                                    ),
                                    "artifact ID is already present in another raw input",
                                )
                            )
                        seen_artifact_ids.add(artifact_id)

            skips = snapshot.get("skips")
            if isinstance(skips, list):
                skip_ids.update(
                    skip["skip_id"]
                    for skip in skips
                    if isinstance(skip, Mapping)
                    and isinstance(skip.get("skip_id"), str)
                )
            constituents = snapshot.get("constituents")
            if isinstance(constituents, list):
                failed_constituent_count += sum(
                    isinstance(constituent, Mapping)
                    and constituent.get("status")
                    in {"failed", "not-run", "skipped"}
                    for constituent in constituents
                )

        if not statuses:
            aggregate_status = EvidenceStatus.NOT_RUN
        elif len(set(statuses)) == 1 and len(statuses) == len(claim.receipt_inputs):
            aggregate_status = statuses[0]
        else:
            aggregate_status = EvidenceStatus.INVALID
            issues.append(
                ValidationIssue(
                    "contradictory-evidence-status",
                    f"{path}.receipt_inputs",
                    "one evidence layer cannot aggregate different receipt statuses",
                )
            )
        if aggregate_status is EvidenceStatus.PASSED:
            observed_receipt_types = {
                output.receipt_type for output in receipt_outputs
            }
            missing_receipt_types = (
                REQUIRED_RECEIPT_TYPES_BY_LAYER[claim.layer]
                - observed_receipt_types
            )
            if missing_receipt_types:
                issues.append(
                    ValidationIssue(
                        "missing-required-receipt-type",
                        f"{path}.receipt_inputs",
                        "passed evidence omits its specialized Lane A authority: "
                        + ", ".join(
                            receipt_type.value
                            for receipt_type in sorted(
                                missing_receipt_types,
                                key=lambda item: item.value,
                            )
                        ),
                    )
                )

        validated.append(
            ValidatedEvidenceClaim(
                layer=claim.layer,
                status=aggregate_status,
                candidate_identity_sha256=(
                    candidate_identity_sha256(expected_claim_candidate)
                    if claim.receipt_inputs
                    else None
                ),
                receipt_outputs=tuple(
                    sorted(receipt_outputs, key=lambda output: output.receipt_id)
                ),
                artifact_outputs=tuple(
                    sorted(artifact_outputs, key=lambda output: output.artifact_id)
                ),
                artifact_kinds=tuple(sorted(artifact_kinds, key=lambda kind: kind.value)),
                authorized_skip_ids=tuple(sorted(skip_ids)),
                failed_constituent_count=failed_constituent_count,
            )
        )

    by_layer = claims_by_layer(validated)
    for layer, claim in by_layer.items():
        if claim.status is not EvidenceStatus.PASSED:
            continue
        for predecessor in order.transitive_predecessors[layer]:
            predecessor_claim = by_layer.get(predecessor)
            if (
                predecessor_claim is None
                or predecessor_claim.status is not EvidenceStatus.PASSED
            ):
                issues.append(
                    ValidationIssue(
                        "evidence-order-bypass",
                        f"$.evidence_claims.{layer.value}",
                        f"passed layer requires passed predecessor {predecessor.value}",
                    )
                )
    if issues:
        return None, tuple(sorted(set(issues)))
    return tuple(sorted(validated, key=lambda claim: claim.layer.value)), ()


def validate_evidence_claims(
    order: EvidencePartialOrder,
    *,
    expected_candidate: CandidateIdentity,
    expected_qualification_run: QualificationRunAuthority,
    expected_premerge_candidate: CandidateIdentity | None = None,
    claims: Sequence[EvidenceClaim],
) -> tuple[ValidationIssue, ...]:
    _, issues = compile_evidence_claims(
        order,
        expected_candidate=expected_candidate,
        expected_qualification_run=expected_qualification_run,
        expected_premerge_candidate=expected_premerge_candidate,
        claims=claims,
    )
    return issues


def claims_by_layer(
    claims: Sequence[ValidatedEvidenceClaim],
) -> Mapping[EvidenceLayer, ValidatedEvidenceClaim]:
    return {
        claim.layer: claim
        for claim in claims
        if isinstance(claim, ValidatedEvidenceClaim)
        and isinstance(claim.layer, EvidenceLayer)
    }


__all__ = [
    "DEFAULT_EVIDENCE_EDGES",
    "EVIDENCE_PARTIAL_ORDER_SCHEMA_VERSION",
    "MANDATORY_EVIDENCE_EDGES",
    "EvidenceArtifactOutput",
    "EvidenceClaim",
    "EvidencePartialOrder",
    "EvidenceReceiptInput",
    "EvidenceReceiptOutput",
    "ValidatedEvidenceClaim",
    "claims_by_layer",
    "compile_evidence_claims",
    "compile_evidence_partial_order",
    "default_evidence_partial_order",
    "evidence_partial_order_sha256",
    "evidence_partial_order_to_mapping",
    "validate_evidence_claims",
]
