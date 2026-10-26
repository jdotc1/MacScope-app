"""Fail-closed validation for candidate-bound Gate F receipts."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .artifact_validator import validate_artifact_records
from .canonical_json import canonical_sha256
from .command_catalog import INDEPENDENT_REVIEW_COMMAND_LENSES
from .merge_authority_evidence import (
    EXPECTED_POSTMERGE_EVENT,
    EXPECTED_POSTMERGE_JOB_NAME,
    EXPECTED_POSTMERGE_WORKFLOW_NAME,
    EXPECTED_PR_CHECKS,
    NONBLOCKING_REVIEW_DECISIONS,
)
from .receipt_schema import (
    AUTHORITY_FIELDS,
    COMMAND_AUTHORITY_FIELDS,
    COMMAND_PREREQUISITE_FIELDS,
    CONSTITUENT_FIELDS,
    EXECUTION_INTERVAL_FIELDS,
    EXECUTOR_FIELDS,
    MAX_DIAGNOSTIC_UTF8_BYTES,
    QUALIFICATION_RUN_FIELDS,
    RECEIPT_FIELDS,
    RECEIPT_LAYER_BINDINGS,
    RECEIPT_SCHEMA_VERSION,
    REQUIRED_ARTIFACT_KINDS,
    SKIP_FIELDS,
    receipt_payload,
    skip_payload,
)
from .schema import (
    ArtifactKind,
    CandidateIdentity,
    CandidateSubjectKind,
    DecisionStatus,
    EvidenceLayer,
    EvidenceStatus,
    ExecutorArchitecture,
    ExecutorPlatform,
    QualificationPhase,
    ReceiptType,
    STABLE_ID_RE,
    SelectorStatus,
    ValidationIssue,
    candidate_identity_sha256,
    closed_record,
    enum_value,
    is_git_object,
    is_integer,
    is_sha256,
    parse_candidate_identity,
    same_candidate_authority,
)


_INDEPENDENT_REVIEW_COMMAND_ID = "review.independent"
_DETERMINISTIC_EVIDENCE_COMMAND_ID = "reconstruction.deterministic-evidence"


@dataclass(frozen=True)
class ArtifactExpectation:
    artifact_id: str
    relative_path: str
    kind: ArtifactKind
    media_type: str
    command_output: str


@dataclass(frozen=True, order=True)
class QualificationRunAuthority:
    """Coordinator-issued authority for exactly one Gate F qualification."""

    run_id: str
    nonce: str


@dataclass(frozen=True, order=True)
class CommandPrerequisiteExpectation:
    command_id: str
    receipt_id: str
    canonical_sha256: str
    qualification_run_id: str
    qualification_run_nonce: str


@dataclass(frozen=True)
class CommandAuthorityExpectation:
    host: str
    execution_mode: str
    argv_sha256: str
    working_directory_sha256: str
    environment_sha256: str
    generated_artifacts: tuple[str, ...]
    generated_logs: tuple[str, ...]
    prerequisite_receipts: tuple[CommandPrerequisiteExpectation, ...]


@dataclass(frozen=True, order=True)
class ExecutionIntervalExpectation:
    started_at_unix_ms: int
    ended_at_unix_ms: int


@dataclass(frozen=True)
class ReceiptValidationContext:
    expected_candidate: CandidateIdentity
    expected_qualification_run: QualificationRunAuthority
    qualification_phase: QualificationPhase
    expected_layer: EvidenceLayer
    expected_receipt_type: ReceiptType
    expected_receipt_id: str
    expected_requirement_id: str
    expected_command_id: str
    expected_scenario_id: str
    expected_command_plan_sha256: str
    expected_command_record_sha256: str
    expected_command_authority: CommandAuthorityExpectation
    expected_qualified_premerge_authority_sha256: str | None
    expected_attempt: int
    expected_execution_interval: ExecutionIntervalExpectation
    expected_artifact_root_id: str
    expected_artifacts: tuple[ArtifactExpectation, ...]
    artifact_root: Path | None
    expected_executor_id: str | None = None
    expected_skips: tuple[Mapping[str, Any], ...] = ()
    require_physical_artifacts_on_pass: bool = True
    # Retained orchestration context, never reconstructed from a receipt.
    capture_admission: object | None = None
    expected_runtime_resolution: object | None = None
    capture_derived_execution: bool = False
    external_admission: object | None = None


EXTERNAL_AUTHORITY_COMMANDS = frozenset({
    "evidence.t10c-current-source-adjudication",
    *INDEPENDENT_REVIEW_COMMAND_LENSES,
    "review.independent", "merge.prospective-tree", "postmerge.exact-tree-proof",
})


def _issue(code: str, path: str, message: str) -> ValidationIssue:
    return ValidationIssue(code, path, message)


def _stable_id(value: object, *, path: str) -> list[ValidationIssue]:
    if not isinstance(value, str) or STABLE_ID_RE.fullmatch(value) is None:
        return [_issue("stable-id", path, "must be a canonical lowercase stable ID")]
    return []


def _nonnegative(value: object, *, path: str) -> list[ValidationIssue]:
    if not is_integer(value) or value < 0:
        return [_issue("nonnegative-integer", path, "must be a nonnegative integer")]
    return []


def _sha(value: object, *, path: str) -> list[ValidationIssue]:
    if not is_sha256(value):
        return [_issue("sha256", path, "must be a lowercase 64-hex SHA-256")]
    return []


def qualification_run_mapping(value: QualificationRunAuthority) -> dict[str, str]:
    return {"run_id": value.run_id, "nonce": value.nonce}


def validate_qualification_run_authority(
    value: object,
    *,
    expected: QualificationRunAuthority,
    path: str,
) -> list[ValidationIssue]:
    record, issues = closed_record(value, QUALIFICATION_RUN_FIELDS, path=path)
    if record is None:
        return issues
    issues.extend(_stable_id(record.get("run_id"), path=f"{path}.run_id"))
    issues.extend(_sha(record.get("nonce"), path=f"{path}.nonce"))
    if dict(record) != qualification_run_mapping(expected):
        issues.append(
            _issue(
                "qualification-run-authority-mismatch",
                path,
                "receipt belongs to another coordinator-issued qualification run",
            )
        )
    return issues


def _canonical_digest(
    value: object,
    *,
    path: str,
    issues: list[ValidationIssue],
) -> str | None:
    try:
        return canonical_sha256(value)
    except (TypeError, ValueError):
        issues.append(_issue("canonicalization", path, "value is not canonically representable"))
        return None


def _validate_skip(
    value: object,
    *,
    candidate: CandidateIdentity,
    layer: EvidenceLayer,
    scenario_id: str,
    path: str,
) -> tuple[dict[str, Any] | None, list[ValidationIssue]]:
    record, issues = closed_record(value, SKIP_FIELDS, path=path)
    if record is None:
        return None, issues
    for field in ("skip_id", "selector_id", "reason_code"):
        issues.extend(_stable_id(record.get(field), path=f"{path}.{field}"))
    skip_layer, nested = enum_value(EvidenceLayer, record.get("evidence_layer"), path=f"{path}.evidence_layer")
    issues.extend(nested)
    if skip_layer is not None and skip_layer != layer:
        issues.append(_issue("skip-layer-drift", f"{path}.evidence_layer", "skip belongs to another evidence layer"))
    if record.get("scenario_id") != scenario_id:
        issues.append(_issue("skip-scenario-drift", f"{path}.scenario_id", "skip belongs to another scenario"))
    for field in ("source_commit", "source_tree"):
        if not is_git_object(record.get(field)):
            issues.append(_issue("git-object", f"{path}.{field}", "must be a lowercase 40-hex Git identity"))
    if record.get("source_commit") != candidate.source.commit or record.get("source_tree") != candidate.source.tree:
        issues.append(_issue("skip-source-drift", path, "skip authorization is not bound to the candidate source"))
    for field in ("reason_text_sha256", "source_contract_sha256", "selector_catalog_sha256"):
        issues.extend(_sha(record.get(field), path=f"{path}.{field}"))
    if record.get("selector_catalog_sha256") != candidate.selector_catalog_sha256:
        issues.append(_issue("skip-selector-catalog-drift", f"{path}.selector_catalog_sha256", "skip belongs to another selector catalog"))
    authorization = record.get("authorization_sha256")
    if not is_sha256(authorization):
        issues.append(_issue("sha256", f"{path}.authorization_sha256", "invalid skip authorization digest"))
    else:
        observed_authorization = _canonical_digest(
            skip_payload(record),
            path=path,
            issues=issues,
        )
        if observed_authorization is not None and authorization != observed_authorization:
            issues.append(_issue("skip-authorization-drift", f"{path}.authorization_sha256", "skip fields differ from their authorization"))
    return dict(record), issues


def _validate_executor(
    value: object,
    *,
    layer: EvidenceLayer,
    expected_executor_id: str | None,
    expected_host: str,
    path: str,
) -> list[ValidationIssue]:
    record, issues = closed_record(value, EXECUTOR_FIELDS, path=path)
    if record is None:
        return issues
    issues.extend(_stable_id(record.get("executor_id"), path=f"{path}.executor_id"))
    if expected_executor_id is not None and record.get("executor_id") != expected_executor_id:
        issues.append(_issue("executor-mismatch", f"{path}.executor_id", "receipt used another executor"))
    if record.get("host") != expected_host:
        issues.append(
            _issue(
                "executor-host-mismatch",
                f"{path}.host",
                "receipt executor host differs from the authenticated command record",
            )
        )
    platform, nested = enum_value(ExecutorPlatform, record.get("platform"), path=f"{path}.platform")
    issues.extend(nested)
    architecture, nested = enum_value(ExecutorArchitecture, record.get("architecture"), path=f"{path}.architecture")
    issues.extend(nested)
    os_version = record.get("os_version")
    try:
        os_version_size = len(os_version.encode("utf-8")) if isinstance(os_version, str) else 0
    except UnicodeEncodeError:
        os_version_size = 129
    if not isinstance(os_version, str) or not os_version or os_version_size > 128:
        issues.append(_issue("executor-os-version", f"{path}.os_version", "must be bounded nonempty text"))
    macos_layers = set(EvidenceLayer) - {
        EvidenceLayer.SOURCE_GOVERNANCE,
        EvidenceLayer.HOSTED_PURE,
    }
    if layer in macos_layers and (
        platform is not ExecutorPlatform.MACOS
        or architecture is not ExecutorArchitecture.ARM64
    ):
        issues.append(_issue("executor-platform", path, "this evidence layer requires macOS arm64"))
    return issues


def _validate_command_authority(
    value: object,
    *,
    expected: CommandAuthorityExpectation,
    expected_qualification_run: QualificationRunAuthority,
    path: str,
) -> list[ValidationIssue]:
    record, issues = closed_record(value, COMMAND_AUTHORITY_FIELDS, path=path)
    if record is None:
        return issues
    for field in ("host", "execution_mode"):
        issues.extend(_stable_id(record.get(field), path=f"{path}.{field}"))
    for field in (
        "argv_sha256",
        "working_directory_sha256",
        "environment_sha256",
    ):
        issues.extend(_sha(record.get(field), path=f"{path}.{field}"))
    for field in ("generated_artifacts", "generated_logs"):
        values = record.get(field)
        if (
            not isinstance(values, list)
            or not all(isinstance(item, str) and item for item in values)
            or values != sorted(set(values))
        ):
            issues.append(
                _issue(
                    "command-output-plan-shape",
                    f"{path}.{field}",
                    "command outputs must be unique sorted nonempty strings",
                )
            )
    prerequisite_values = record.get("prerequisite_receipts")
    observed_prerequisites: list[dict[str, object]] = []
    if not isinstance(prerequisite_values, list):
        issues.append(
            _issue(
                "command-prerequisite-plan-type",
                f"{path}.prerequisite_receipts",
                "command prerequisite receipts must be an array",
            )
        )
    else:
        for index, item in enumerate(prerequisite_values):
            item_path = f"{path}.prerequisite_receipts[{index}]"
            prerequisite, nested = closed_record(
                item,
                COMMAND_PREREQUISITE_FIELDS,
                path=item_path,
            )
            issues.extend(nested)
            if prerequisite is None:
                continue
            for field in ("command_id", "receipt_id"):
                issues.extend(
                    _stable_id(prerequisite.get(field), path=f"{item_path}.{field}")
                )
            issues.extend(
                _sha(
                    prerequisite.get("canonical_sha256"),
                    path=f"{item_path}.canonical_sha256",
                )
            )
            issues.extend(
                _stable_id(
                    prerequisite.get("qualification_run_id"),
                    path=f"{item_path}.qualification_run_id",
                )
            )
            issues.extend(
                _sha(
                    prerequisite.get("qualification_run_nonce"),
                    path=f"{item_path}.qualification_run_nonce",
                )
            )
            if (
                prerequisite.get("qualification_run_id")
                != expected_qualification_run.run_id
                or prerequisite.get("qualification_run_nonce")
                != expected_qualification_run.nonce
            ):
                issues.append(
                    _issue(
                        "command-prerequisite-qualification-run-mismatch",
                        item_path,
                        "prerequisite belongs to another coordinator-issued qualification run",
                    )
                )
            observed_prerequisites.append(dict(prerequisite))
        if observed_prerequisites != sorted(
            observed_prerequisites,
            key=lambda item: str(item.get("command_id")),
        ) or len(
            {item.get("command_id") for item in observed_prerequisites}
        ) != len(observed_prerequisites):
            issues.append(
                _issue(
                    "command-prerequisite-plan-shape",
                    f"{path}.prerequisite_receipts",
                    "command prerequisite receipts must have unique sorted command IDs",
                )
            )

    expected_mapping = {
        "host": expected.host,
        "execution_mode": expected.execution_mode,
        "argv_sha256": expected.argv_sha256,
        "working_directory_sha256": expected.working_directory_sha256,
        "environment_sha256": expected.environment_sha256,
        "generated_artifacts": list(expected.generated_artifacts),
        "generated_logs": list(expected.generated_logs),
        "prerequisite_receipts": [
            {
                "command_id": item.command_id,
                "receipt_id": item.receipt_id,
                "canonical_sha256": item.canonical_sha256,
                "qualification_run_id": item.qualification_run_id,
                "qualification_run_nonce": item.qualification_run_nonce,
            }
            for item in expected.prerequisite_receipts
        ],
    }
    if dict(record) != expected_mapping:
        issues.append(
            _issue(
                "command-authority-drift",
                path,
                "receipt command authority differs from the exact execution plan",
            )
        )
    return issues


def _validate_execution_interval(
    value: object,
    *,
    expected: ExecutionIntervalExpectation,
    path: str,
) -> list[ValidationIssue]:
    record, issues = closed_record(value, EXECUTION_INTERVAL_FIELDS, path=path)
    if record is None:
        return issues
    started = record.get("started_at_unix_ms")
    ended = record.get("ended_at_unix_ms")
    if not is_integer(started) or started < 0:
        issues.append(
            _issue(
                "execution-interval-start",
                f"{path}.started_at_unix_ms",
                "execution start must be a nonnegative integer",
            )
        )
    if not is_integer(ended) or (
        is_integer(started) and ended < started
    ):
        issues.append(
            _issue(
                "execution-interval-order",
                f"{path}.ended_at_unix_ms",
                "execution end must be an integer not preceding its start",
            )
        )
    expected_mapping = {
        "started_at_unix_ms": expected.started_at_unix_ms,
        "ended_at_unix_ms": expected.ended_at_unix_ms,
    }
    if dict(record) != expected_mapping:
        issues.append(
            _issue(
                "execution-interval-mismatch",
                path,
                "receipt execution interval differs from the descriptor-verified execution report",
            )
        )
    return issues


def _validate_constituents(
    value: object,
    *,
    candidate_digest: str,
    layer: EvidenceLayer,
    artifact_ids: set[str],
    path: str,
) -> tuple[list[dict[str, Any]], list[ValidationIssue]]:
    if not isinstance(value, list):
        return [], [_issue("array-type", path, "constituents must be an array")]
    records: list[dict[str, Any]] = []
    issues: list[ValidationIssue] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        item_path = f"{path}[{index}]"
        record, nested = closed_record(item, CONSTITUENT_FIELDS, path=item_path)
        issues.extend(nested)
        if record is None:
            continue
        selector_id = record.get("selector_id")
        issues.extend(_stable_id(selector_id, path=f"{item_path}.selector_id"))
        if isinstance(selector_id, str):
            if selector_id in seen:
                issues.append(_issue("duplicate-selector-id", f"{item_path}.selector_id", "selector is duplicated"))
            seen.add(selector_id)
        _, nested = enum_value(SelectorStatus, record.get("status"), path=f"{item_path}.status")
        issues.extend(nested)
        constituent_layer, nested = enum_value(EvidenceLayer, record.get("evidence_layer"), path=f"{item_path}.evidence_layer")
        issues.extend(nested)
        if constituent_layer is not None and constituent_layer != layer:
            issues.append(_issue("constituent-layer-mismatch", f"{item_path}.evidence_layer", "constituent belongs to another evidence layer"))
        if record.get("candidate_identity_sha256") != candidate_digest:
            issues.append(_issue("constituent-candidate-mismatch", f"{item_path}.candidate_identity_sha256", "constituent belongs to another candidate"))
        references = record.get("artifact_ids")
        if not isinstance(references, list) or not all(isinstance(item, str) for item in references):
            issues.append(_issue("artifact-reference-type", f"{item_path}.artifact_ids", "must be an array of artifact IDs"))
        elif len(references) != len(set(references)):
            issues.append(_issue("duplicate-artifact-reference", f"{item_path}.artifact_ids", "artifact reference is duplicated"))
        elif not set(references).issubset(artifact_ids):
            issues.append(_issue("unknown-artifact-reference", f"{item_path}.artifact_ids", "constituent references an unbound artifact"))
        records.append(dict(record))
    return records, issues


def _validate_authority(
    value: object,
    *,
    receipt_type: ReceiptType,
    layer: EvidenceLayer,
    candidate: CandidateIdentity,
    constituents: list[dict[str, Any]],
    artifacts: list[dict[str, Any]],
    skips: list[dict[str, Any]],
    aggregate_status: EvidenceStatus,
    path: str,
) -> list[ValidationIssue]:
    record, issues = closed_record(value, AUTHORITY_FIELDS[receipt_type], path=path)
    if record is None:
        return issues
    count_fields = [key for key in record if key.endswith("_count")]
    for field in count_fields:
        issues.extend(_nonnegative(record.get(field), path=f"{path}.{field}"))
    digest_fields = [key for key in record if key.endswith("_sha256")]
    for field in digest_fields:
        issues.extend(_sha(record.get(field), path=f"{path}.{field}"))

    if receipt_type is ReceiptType.COMMAND_EXECUTION:
        issues.extend(_stable_id(record.get("run_id"), path=f"{path}.run_id"))
        if not is_integer(record.get("exit_code")):
            issues.append(_issue("exit-code", f"{path}.exit_code", "must be an integer"))
        elif aggregate_status is EvidenceStatus.PASSED and record["exit_code"] != 0:
            issues.append(_issue("favorable-after-failure", path, "a nonzero command cannot pass"))

    if receipt_type is ReceiptType.TEST_RESULT:
        statuses = [item.get("status") for item in constituents]
        expected = len(constituents)
        executed = sum(status != SelectorStatus.NOT_RUN.value for status in statuses)
        observed = {
            "expected_selector_count": expected,
            "executed_selector_count": executed,
            "passed_selector_count": statuses.count(SelectorStatus.PASSED.value),
            "failed_selector_count": statuses.count(SelectorStatus.FAILED.value),
            "skipped_selector_count": statuses.count(SelectorStatus.SKIPPED.value),
        }
        for field, count in observed.items():
            if record.get(field) != count:
                issues.append(_issue("selector-count-drift", f"{path}.{field}", "count does not match exact constituents"))
        if record.get("selector_catalog_sha256") != candidate.selector_catalog_sha256:
            issues.append(_issue("selector-catalog-drift", f"{path}.selector_catalog_sha256", "receipt belongs to another selector catalog"))

    if receipt_type is ReceiptType.ALLOWED_SKIP:
        if record.get("skip_count") != len(skips):
            issues.append(_issue("skip-count-drift", f"{path}.skip_count", "count differs from exact skips"))
        observed_digest = _canonical_digest(sorted(skips, key=lambda item: str(item.get("skip_id"))), path=path, issues=issues)
        if observed_digest is not None and record.get("skip_catalog_sha256") != observed_digest:
            issues.append(_issue("skip-catalog-drift", f"{path}.skip_catalog_sha256", "digest differs from exact skips"))
    if receipt_type is ReceiptType.ARTIFACT_MANIFEST:
        if record.get("artifact_count") != len(artifacts) or not artifacts:
            issues.append(_issue("artifact-count-drift", f"{path}.artifact_count", "count differs from nonempty artifacts"))
        observed_digest = _canonical_digest(sorted(artifacts, key=lambda item: str(item.get("artifact_id"))), path=path, issues=issues)
        if observed_digest is not None and record.get("artifact_manifest_sha256") != observed_digest:
            issues.append(_issue("artifact-manifest-drift", f"{path}.artifact_manifest_sha256", "digest differs from exact artifacts"))
    if receipt_type is ReceiptType.NATIVE_SANITIZER:
        expected_sanitizer = "address" if layer is EvidenceLayer.NATIVE_ASAN else "undefined"
        if record.get("sanitizer") != expected_sanitizer:
            issues.append(_issue("sanitizer-layer-mismatch", f"{path}.sanitizer", "sanitizer does not match evidence layer"))
        if record.get("test_count") != len(constituents):
            issues.append(_issue("selector-count-drift", f"{path}.test_count", "count differs from exact constituents"))
        if record.get("failed_count") != sum(item.get("status") == SelectorStatus.FAILED.value for item in constituents):
            issues.append(_issue("selector-count-drift", f"{path}.failed_count", "count differs from exact constituents"))
    if receipt_type is ReceiptType.SIGNED_XPC:
        qualification = {
            item.identity_id: item
            for item in candidate.application.qualification_executables
        }
        identity_id = record.get("service_identity_id")
        executable = qualification.get(identity_id)
        if (
            executable is None
            or executable.sha256 != record.get("service_executable_sha256")
            or executable.bundle_identifier != record.get("service_bundle_id")
        ):
            issues.append(
                _issue(
                    "signed-xpc-candidate-mismatch",
                    path,
                    "service identity, bundle ID, and executable are not bound to the candidate qualification product",
                )
            )
        if record.get("selector_count") != len(constituents) or record.get("failed_count") != sum(item.get("status") == SelectorStatus.FAILED.value for item in constituents):
            issues.append(_issue("selector-count-drift", path, "signed-XPC counts differ from exact constituents"))
        expected_failure = (
            ("selected-test", "selected-test-failed")
            if aggregate_status is EvidenceStatus.FAILED
            else (None, None)
        )
        if (record.get("failure_stage"), record.get("failure_reason")) != expected_failure:
            issues.append(_issue("signed-xpc-failure-classification", path, "signed-XPC result lacks the closed stage/reason classification"))
    if receipt_type is ReceiptType.RELEASE_BUILD:
        expected = {
            "bundle_sha256": candidate.application.bundle_sha256,
            "closed_tree_sha256": candidate.application.closed_tree_sha256,
            "executable_sha256": candidate.application.executable_sha256,
        }
        if any(record.get(key) != value for key, value in expected.items()):
            issues.append(_issue("release-app-mismatch", path, "Release identity differs from candidate app"))
    if receipt_type is ReceiptType.STRICT_SIGNING:
        expected = {
            "signing_certificate_sha256": candidate.application.signing_certificate_sha256,
            "signing_subject_sha256": candidate.application.signing_subject_sha256,
            "team_identifier": candidate.application.team_identifier,
            "entitlements_sha256": candidate.application.entitlements_sha256,
            "designated_requirement_sha256": candidate.application.designated_requirement_sha256,
            "hardened_runtime": candidate.application.hardened_runtime,
        }
        if any(record.get(key) != value for key, value in expected.items()):
            issues.append(_issue("signing-candidate-mismatch", path, "signing identity differs from candidate app"))
    if receipt_type is ReceiptType.INSTALLED_SOURCE_EQUALITY:
        release_expected = (
            candidate.application.bundle_sha256,
            candidate.application.closed_tree_sha256,
            candidate.application.root_mode,
            candidate.application.executable_sha256,
        )
        release_observed = (
            record.get("release_bundle_sha256"),
            record.get("release_closed_tree_sha256"),
            record.get("release_root_mode"),
            record.get("release_executable_sha256"),
        )
        installed_observed = (
            record.get("installed_bundle_sha256"),
            record.get("installed_closed_tree_sha256"),
            record.get("installed_root_mode"),
            record.get("installed_executable_sha256"),
        )
        if release_observed != release_expected or installed_observed != release_observed:
            issues.append(_issue("installed-source-mismatch", path, "installed identity is not byte-equal to candidate Release"))
    if receipt_type is ReceiptType.INSTALLED_LAUNCH_LOG:
        if record.get("app_bundle_id") != candidate.application.bundle_identifier or record.get("app_executable_sha256") != candidate.application.executable_sha256:
            issues.append(_issue("installed-app-mismatch", path, "launch result belongs to another app"))
        if not is_integer(record.get("launch_exit_code")):
            issues.append(_issue("exit-code", f"{path}.launch_exit_code", "must be an integer"))
        elif aggregate_status is EvidenceStatus.PASSED and record["launch_exit_code"] != 0:
            issues.append(_issue("favorable-after-failure", path, "failed launch cannot pass"))
    if receipt_type in {ReceiptType.INSTALLED_WORKFLOW, ReceiptType.INSTALLED_ACCESSIBILITY}:
        if record.get("app_bundle_id") != candidate.application.bundle_identifier or record.get("app_executable_sha256") != candidate.application.executable_sha256:
            issues.append(_issue("installed-app-mismatch", path, "installed result belongs to another app candidate"))
        observed_failed = sum(item.get("status") == SelectorStatus.FAILED.value for item in constituents)
        observed_skipped = sum(item.get("status") == SelectorStatus.SKIPPED.value for item in constituents)
        if record.get("selector_count") != len(constituents) or record.get("failed_count") != observed_failed or record.get("skipped_count") != observed_skipped:
            issues.append(_issue("selector-count-drift", path, "installed selector counts differ from exact constituents"))
    if receipt_type is ReceiptType.STRESS_RECOVERY:
        seeds = record.get("attempt_seeds")
        statuses = [item.get("status") for item in constituents]
        observed_attempts = sum(
            status in {SelectorStatus.PASSED.value, SelectorStatus.FAILED.value}
            for status in statuses
        )
        if not isinstance(seeds, list) or not all(is_integer(seed) and seed >= 0 for seed in seeds) or len(seeds) != len(set(seeds)):
            issues.append(_issue("stress-seeds", f"{path}.attempt_seeds", "seeds must be unique nonnegative integers"))
        elif record.get("expected_attempt_count") != len(seeds) or len(seeds) != len(constituents) or record.get("observed_attempt_count") != observed_attempts:
            issues.append(_issue("stress-attempt-count", path, "stress expected attempts, observed attempts, seeds, and constituents do not pair exactly"))
        else:
            observed_seed_digest = _canonical_digest(seeds, path=f"{path}.attempt_seeds", issues=issues)
            if observed_seed_digest is not None and record.get("seed_catalog_sha256") != observed_seed_digest:
                issues.append(_issue("stress-seed-catalog", f"{path}.seed_catalog_sha256", "seed digest differs from exact seed sequence"))
        if record.get("failed_count") != sum(item.get("status") == SelectorStatus.FAILED.value for item in constituents):
            issues.append(_issue("selector-count-drift", f"{path}.failed_count", "count differs from exact constituents"))
    if receipt_type is ReceiptType.INDEPENDENT_REVIEW:
        if record.get("review_commit") != candidate.source.commit or record.get("review_tree") != candidate.source.tree:
            issues.append(_issue("review-candidate-mismatch", path, "review belongs to another source"))
        blocking_values = [record.get(key) for key in ("p0_count", "p1_count", "p2_count")]
        blocking = sum(value for value in blocking_values if is_integer(value) and value >= 0)
        if all(is_integer(value) and value >= 0 for value in blocking_values) and record.get("unresolved_blocking_count") != blocking:
            issues.append(_issue("review-blocking-count", f"{path}.unresolved_blocking_count", "must equal unresolved P0+P1+P2"))
        if aggregate_status is EvidenceStatus.PASSED and blocking:
            issues.append(_issue("review-blocker-hidden", path, "P0/P1/P2 blocks a passed review"))
    if receipt_type is ReceiptType.PROSPECTIVE_MERGE_TREE:
        candidate_fields = {
            "base_commit": candidate.source.base_commit,
            "base_tree": candidate.source.base_tree,
            "head_commit": candidate.source.commit,
            "head_tree": candidate.source.tree,
            "head_ref": candidate.source.branch_label,
            "merge_commit": candidate.prospective_merge_commit,
            "merge_tree": candidate.prospective_merge_tree,
        }
        if (
            candidate.subject_kind is not CandidateSubjectKind.PROSPECTIVE_MERGE
            or any(record.get(key) != expected for key, expected in candidate_fields.items())
        ):
            issues.append(_issue("prospective-merge-mismatch", path, "merge proof belongs to another prospective merge"))
        parents = record.get("parent_commits")
        if (
            not isinstance(parents, list)
            or len(parents) != 2
            or not all(is_git_object(item) for item in parents)
            or len(set(parents)) != 2
            or parents != [candidate.source.base_commit, candidate.source.commit]
        ):
            issues.append(_issue("merge-parents", f"{path}.parent_commits", "ordered base and head Git parents are required"))
        if (
            record.get("mergeable") is not True
            or record.get("merge_state") != "clean"
            or record.get("review_decision") not in NONBLOCKING_REVIEW_DECISIONS
            or not is_integer(record.get("approval_count"))
            or record.get("approval_count", 0) < 0
        ):
            issues.append(_issue("merge-authority-state", path, "prospective merge is not clean and mergeable or has blocking/invalid review observations"))
        required_count = len(EXPECTED_PR_CHECKS)
        if (
            record.get("required_check_count") != required_count
            or record.get("successful_check_count") != required_count
            or not is_integer(record.get("governed_file_count"))
            or record.get("governed_file_count", 0) < 1
        ):
            issues.append(_issue("merge-authority-count", path, "required checks and governed files are not completely proved"))
    if receipt_type is ReceiptType.POST_MERGE:
        if candidate.subject_kind is not CandidateSubjectKind.POST_MERGE or record.get("prospective_merge_commit") != candidate.prospective_merge_commit or record.get("prospective_merge_tree") != candidate.prospective_merge_tree:
            issues.append(_issue("prospective-merge-mismatch", path, "post-merge proof changed prospective identity"))
        if record.get("postmerge_commit") != candidate.accepted_postmerge_commit or record.get("postmerge_tree") != candidate.accepted_postmerge_tree:
            issues.append(_issue("postmerge-candidate-mismatch", path, "post-merge proof belongs to another accepted tree"))
        issues.extend(_stable_id(record.get("workflow_run_id"), path=f"{path}.workflow_run_id"))
        workflow_expected = {
            "workflow_commit": candidate.accepted_postmerge_commit,
            "workflow_tree": candidate.accepted_postmerge_tree,
            "workflow_name": EXPECTED_POSTMERGE_WORKFLOW_NAME,
            "workflow_job_name": EXPECTED_POSTMERGE_JOB_NAME,
            "workflow_event": EXPECTED_POSTMERGE_EVENT,
            "workflow_status": "completed",
            "workflow_conclusion": "success",
            "head_ref": candidate.source.branch_label,
        }
        if any(record.get(key) != expected for key, expected in workflow_expected.items()):
            issues.append(_issue("workflow-authority-mismatch", path, "workflow name, event, outcome, commit, or tree is not authoritative"))
        if not is_integer(record.get("workflow_run_attempt")) or record.get("workflow_run_attempt", 0) < 1:
            issues.append(_issue("workflow-run-attempt", f"{path}.workflow_run_attempt", "must be a positive integer"))
    if receipt_type is ReceiptType.FINAL_DECISION:
        decision, nested = enum_value(DecisionStatus, record.get("decision_status"), path=f"{path}.decision_status")
        issues.extend(nested)
        if decision is DecisionStatus.COMPLETE:
            blocker_values = [record.get(key) for key in ("unresolved_p0_count", "unresolved_p1_count", "unresolved_p2_count")]
            if any(is_integer(value) and value > 0 for value in blocker_values):
                issues.append(_issue("complete-with-blockers", path, "complete forbids unresolved P0/P1/P2"))
            if record.get("required_receipt_count") != record.get("valid_receipt_count"):
                issues.append(_issue("complete-with-missing-receipts", path, "complete requires every receipt"))
    return issues


def _validate_physical_receipt(
    value: object,
    *,
    context: ReceiptValidationContext,
    path: str = "$",
    admitted_external_semantics: Mapping[str, Any] | None = None,
) -> tuple[ValidationIssue, ...]:
    record, issues = closed_record(value, RECEIPT_FIELDS, path=path)
    if record is None:
        return tuple(issues)
    if record.get("runtime_resolution") != context.expected_runtime_resolution:
        issues.append(_issue("runtime-resolution-mismatch", path,
                             "receipt runtime resolution differs from independently admitted context"))
    if context.capture_derived_execution:
        from .executor_request_adapter import INSTALLED_PRODUCER_ROLES
        installed_role = INSTALLED_PRODUCER_ROLES.get(context.expected_command_id)
        if installed_role is not None and (context.expected_receipt_type is not installed_role
                or record.get("receipt_type") != installed_role.value):
            issues.append(_issue("installed-receipt-role", path,
                                 "installed receipt must retain its command-specific semantic role"))
        if (context.expected_command_id == "installed.xcuitest-preflight"
                and record.get("constituents") != []):
            issues.append(_issue("installed-preflight-constituents", path,
                                 "preflight readiness cannot discharge accessibility selectors"))
    if context.capture_admission is not None:
        from .executor_request_adapter import validate_capture_receipt
        try:
            validate_capture_receipt(record, context=context)
        except ValueError as error:
            issues.append(_issue("capture-admission", path, str(error)))
    issues.extend(
        validate_qualification_run_authority(
            record.get("qualification_run"),
            expected=context.expected_qualification_run,
            path=f"{path}.qualification_run",
        )
    )
    if not is_integer(record.get("schema_version")) or record.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        issues.append(_issue("receipt-schema-version", f"{path}.schema_version", "unsupported receipt schema"))
    issues.extend(_stable_id(record.get("receipt_id"), path=f"{path}.receipt_id"))
    if record.get("receipt_id") != context.expected_receipt_id:
        issues.append(_issue("receipt-id-mismatch", f"{path}.receipt_id", "receipt ID differs from the command plan"))
    issues.extend(_stable_id(record.get("requirement_id"), path=f"{path}.requirement_id"))
    issues.extend(_stable_id(record.get("command_id"), path=f"{path}.command_id"))
    issues.extend(_stable_id(record.get("scenario_id"), path=f"{path}.scenario_id"))
    if not is_sha256(record.get("command_plan_sha256")):
        issues.append(
            _issue(
                "command-plan-sha256",
                f"{path}.command_plan_sha256",
                "receipt must seal a lowercase command-plan SHA-256",
            )
        )
    if not is_sha256(record.get("command_record_sha256")):
        issues.append(
            _issue(
                "command-record-sha256",
                f"{path}.command_record_sha256",
                "receipt must seal a lowercase command-record SHA-256",
            )
        )
    if record.get("requirement_id") != context.expected_requirement_id:
        issues.append(_issue("receipt-requirement-mismatch", f"{path}.requirement_id", "receipt belongs to another requirement"))
    if record.get("command_id") != context.expected_command_id:
        issues.append(_issue("receipt-command-mismatch", f"{path}.command_id", "receipt belongs to another command"))
    if record.get("scenario_id") != context.expected_scenario_id:
        issues.append(_issue("receipt-scenario-mismatch", f"{path}.scenario_id", "receipt belongs to another scenario"))
    if record.get("command_plan_sha256") != context.expected_command_plan_sha256:
        issues.append(
            _issue(
                "receipt-command-plan-mismatch",
                f"{path}.command_plan_sha256",
                "receipt belongs to another command plan",
            )
        )
    if record.get("command_record_sha256") != context.expected_command_record_sha256:
        issues.append(
            _issue(
                "receipt-command-record-mismatch",
                f"{path}.command_record_sha256",
                "receipt belongs to another command record",
            )
        )
    qualified_premerge_digest = record.get("qualified_premerge_authority_sha256")
    if qualified_premerge_digest is not None and not is_sha256(
        qualified_premerge_digest
    ):
        issues.append(
            _issue(
                "qualified-premerge-authority-sha256",
                f"{path}.qualified_premerge_authority_sha256",
                "premerge authority must be null or lowercase SHA-256",
            )
        )
    if qualified_premerge_digest != context.expected_qualified_premerge_authority_sha256:
        issues.append(
            _issue(
                "receipt-qualified-premerge-authority-mismatch",
                f"{path}.qualified_premerge_authority_sha256",
                "receipt is not chained to the expected earlier premerge decision",
            )
        )
    attempt = record.get("attempt")
    if not is_integer(attempt) or attempt < 1:
        issues.append(_issue("receipt-attempt", f"{path}.attempt", "attempt must be a positive integer"))
    elif attempt != context.expected_attempt:
        issues.append(_issue("receipt-attempt-mismatch", f"{path}.attempt", "attempt differs from the command plan"))
    issues.extend(
        _validate_execution_interval(
            record.get("execution_interval"),
            expected=context.expected_execution_interval,
            path=f"{path}.execution_interval",
        )
    )
    receipt_type, nested = enum_value(ReceiptType, record.get("receipt_type"), path=f"{path}.receipt_type")
    issues.extend(nested)
    if receipt_type is not None and receipt_type != context.expected_receipt_type:
        issues.append(_issue("receipt-type-mismatch", f"{path}.receipt_type", "receipt type differs from the command plan"))
    layer, nested = enum_value(EvidenceLayer, record.get("evidence_layer"), path=f"{path}.evidence_layer")
    issues.extend(nested)
    evidence_status, nested = enum_value(EvidenceStatus, record.get("evidence_status"), path=f"{path}.evidence_status")
    issues.extend(nested)
    phase, nested = enum_value(QualificationPhase, record.get("qualification_phase"), path=f"{path}.qualification_phase")
    issues.extend(nested)
    if phase is not None and phase != context.qualification_phase:
        issues.append(_issue("qualification-phase-mismatch", f"{path}.qualification_phase", "receipt is from another phase"))
    if layer is not None and layer != context.expected_layer:
        issues.append(_issue("receipt-layer-mismatch", f"{path}.evidence_layer", "receipt is from another layer"))
    if receipt_type is not None and layer is not None and layer not in RECEIPT_LAYER_BINDINGS[receipt_type]:
        issues.append(_issue("receipt-type-layer-mismatch", path, "receipt type cannot satisfy this evidence layer"))

    candidate, nested = parse_candidate_identity(record.get("candidate_identity"), path=f"{path}.candidate_identity")
    issues.extend(nested)
    expected_digest = candidate_identity_sha256(context.expected_candidate)
    recorded_digest = record.get("candidate_identity_sha256")
    if not is_sha256(recorded_digest):
        issues.append(_issue("sha256", f"{path}.candidate_identity_sha256", "invalid candidate digest"))
    if candidate is not None:
        observed_digest = candidate_identity_sha256(candidate)
        if recorded_digest != observed_digest:
            issues.append(_issue("receipt-candidate-digest", f"{path}.candidate_identity_sha256", "candidate record and digest disagree"))
        if not same_candidate_authority(candidate, context.expected_candidate) or observed_digest != expected_digest:
            issues.append(_issue("receipt-candidate-mismatch", f"{path}.candidate_identity", "receipt belongs to another candidate"))

    if layer is not None:
        issues.extend(
            _validate_executor(
                record.get("executor"),
                layer=layer,
                expected_executor_id=context.expected_executor_id,
                expected_host=context.expected_command_authority.host,
                path=f"{path}.executor",
            )
        )
    issues.extend(
        _validate_command_authority(
            record.get("command_authority"),
            expected=context.expected_command_authority,
            expected_qualification_run=context.expected_qualification_run,
            path=f"{path}.command_authority",
        )
    )

    diagnostic = record.get("diagnostic")
    try:
        diagnostic_size = len(diagnostic.encode("utf-8")) if isinstance(diagnostic, str) else 0
    except UnicodeEncodeError:
        diagnostic_size = MAX_DIAGNOSTIC_UTF8_BYTES + 1
    if diagnostic is not None and (
        not isinstance(diagnostic, str)
        or diagnostic_size > MAX_DIAGNOSTIC_UTF8_BYTES
        or "\x00" in diagnostic
    ):
        issues.append(_issue("diagnostic-bounds", f"{path}.diagnostic", "diagnostic must be null or bounded UTF-8 text"))

    artifact_values = record.get("artifacts")
    if layer is not None:
        issues.extend(
            validate_artifact_records(
                artifact_values,
                expected_candidate_sha256=expected_digest,
                expected_layer=layer,
                expected_root_id=context.expected_artifact_root_id,
                expected_receipt_id=context.expected_receipt_id,
                expected_command_id=context.expected_command_id,
                root=context.artifact_root,
                path=f"{path}.artifacts",
            )
        )
    artifact_ids = {
        item.get("artifact_id")
        for item in artifact_values
        if isinstance(artifact_values, list) and isinstance(item, Mapping) and isinstance(item.get("artifact_id"), str)
    } if isinstance(artifact_values, list) else set()
    if isinstance(artifact_values, list):
        observed_artifacts = sorted(
            (
                item.get("artifact_id"),
                item.get("relative_path"),
                item.get("kind"),
                item.get("media_type"),
                item.get("command_output"),
            )
            for item in artifact_values
            if isinstance(item, Mapping)
        )
        expected_artifacts = sorted(
            (
                item.artifact_id,
                item.relative_path,
                item.kind.value,
                item.media_type,
                item.command_output,
            )
            for item in context.expected_artifacts
        )
        if observed_artifacts != expected_artifacts:
            issues.append(_issue("artifact-plan-drift", f"{path}.artifacts", "artifacts differ from the exact command plan"))
        expected_command_outputs = {
            *(f"artifact:{item}" for item in context.expected_command_authority.generated_artifacts),
            *(f"log:{item}" for item in context.expected_command_authority.generated_logs),
        }
        if context.capture_admission is not None:
            expected_command_outputs.add("log:gatef-command-capture")
        if context.capture_derived_execution:
            from .executor_request_adapter import CAPTURE_EXECUTION_REPORT_OUTPUT
            expected_command_outputs.add(CAPTURE_EXECUTION_REPORT_OUTPUT)
        observed_command_outputs = {
            item.get("command_output")
            for item in artifact_values
            if isinstance(item, Mapping)
            and isinstance(item.get("command_output"), str)
            and not str(item.get("command_output")).startswith("semantic:")
        }
        if observed_command_outputs != expected_command_outputs:
            issues.append(
                _issue(
                    "command-output-artifact-drift",
                    f"{path}.artifacts",
                    "physical artifacts do not account for every exact command output and log",
                )
            )
    constituents: list[dict[str, Any]] = []
    if layer is not None:
        constituents, nested_issues = _validate_constituents(
            record.get("constituents"),
            candidate_digest=expected_digest,
            layer=layer,
            artifact_ids=artifact_ids,
            path=f"{path}.constituents",
        )
        issues.extend(nested_issues)

    skips_value = record.get("skips")
    actual_skips: list[dict[str, Any]] = []
    if not isinstance(skips_value, list):
        issues.append(_issue("array-type", f"{path}.skips", "skips must be an array"))
    else:
        seen_skip_ids: set[str] = set()
        for index, skip in enumerate(skips_value):
            parsed, nested_issues = _validate_skip(
                skip,
                candidate=context.expected_candidate,
                layer=context.expected_layer,
                scenario_id=context.expected_scenario_id,
                path=f"{path}.skips[{index}]",
            )
            issues.extend(nested_issues)
            if parsed is not None:
                parsed_skip_id = parsed.get("skip_id")
                if isinstance(parsed_skip_id, str) and parsed_skip_id in seen_skip_ids:
                    issues.append(_issue("duplicate-skip-id", f"{path}.skips[{index}].skip_id", "skip ID is duplicated"))
                if isinstance(parsed_skip_id, str):
                    seen_skip_ids.add(parsed_skip_id)
                actual_skips.append(parsed)
    expected_skips = sorted((dict(item) for item in context.expected_skips), key=lambda item: str(item.get("skip_id")))
    if sorted(actual_skips, key=lambda item: str(item.get("skip_id"))) != expected_skips:
        issues.append(_issue("skip-drift", f"{path}.skips", "actual skips differ from the source-bound expected catalog"))
    skipped_selectors = {
        item.get("selector_id")
        for item in constituents
        if item.get("status") == SelectorStatus.SKIPPED.value
        and isinstance(item.get("selector_id"), str)
    }
    skip_selectors = {
        item.get("selector_id")
        for item in actual_skips
        if isinstance(item.get("selector_id"), str)
    }
    if skipped_selectors != skip_selectors:
        issues.append(_issue("skip-constituent-drift", f"{path}.skips", "skip records and skipped constituents differ"))

    if evidence_status is EvidenceStatus.PASSED:
        hidden = [
            item for item in constituents
            if item.get("status") in {
                SelectorStatus.FAILED.value,
                SelectorStatus.NOT_RUN.value,
                SelectorStatus.SKIPPED.value,
            }
        ]
        if hidden:
            issues.append(_issue("aggregate-hides-constituent-failure", f"{path}.constituents", "passed aggregate contains failed or not-run selector"))
        if context.require_physical_artifacts_on_pass and context.artifact_root is None:
            issues.append(_issue("artifact-root-required", f"{path}.artifacts", "passed receipt requires physical artifact verification"))
        if layer is not None and isinstance(artifact_values, list):
            kinds = {
                item.get("kind") for item in artifact_values if isinstance(item, Mapping)
            }
            required_kinds = REQUIRED_ARTIFACT_KINDS[layer]
            from .executor_request_adapter import CAPTURE_DERIVED_REPORT_COMMANDS
            if (receipt_type is ReceiptType.COMMAND_EXECUTION
                    and record.get("command_id") in CAPTURE_DERIVED_REPORT_COMMANDS | {"installed.xcuitest-preflight"}
                    and context.capture_derived_execution):
                # This receipt proves an observed invocation, not the semantic
                # test/build layer. Separate qualification receipts still need
                # their original xcresult/build-product artifact requirements.
                required_kinds = frozenset({ArtifactKind.JSON})
            if record.get("command_id") == _DETERMINISTIC_EVIDENCE_COMMAND_ID:
                # This runner intentionally preserves two descriptor-bound
                # xcresulttool JSON projections plus the physical comparison,
                # rather than copying either multi-file result bundle into the
                # artifact root.
                required_kinds = frozenset({ArtifactKind.TEST_RESULTS})
            missing = {kind.value for kind in required_kinds} - kinds
            if missing:
                issues.append(_issue("missing-required-artifact", f"{path}.artifacts", "passed receipt omits a required artifact kind"))
            if any(
                item.get("kind") in {kind.value for kind in required_kinds}
                and item.get("byte_count") == 0
                for item in artifact_values
                if isinstance(item, Mapping)
            ):
                issues.append(_issue("empty-required-artifact", f"{path}.artifacts", "required artifact must be nonempty"))

    if receipt_type in {
        ReceiptType.TEST_RESULT,
        ReceiptType.NATIVE_SANITIZER,
        ReceiptType.SIGNED_XPC,
        ReceiptType.INSTALLED_WORKFLOW,
        ReceiptType.INSTALLED_ACCESSIBILITY,
        ReceiptType.STRESS_RECOVERY,
    }:
        if evidence_status is EvidenceStatus.PASSED and not constituents:
            issues.append(_issue("empty-constituents", f"{path}.constituents", "passed execution receipt needs exact constituents"))
        referenced = {
            artifact_id
            for item in constituents
            for artifact_id in item.get("artifact_ids", [])
            if isinstance(artifact_id, str)
        }
        constituent_artifact_ids = artifact_ids
        if context.capture_admission is not None:
            # The producer capture is independently mandatory and validated above;
            # it must not change the original owner report's constituent closure.
            from .executor_request_adapter import capture_artifact_id
            constituent_artifact_ids = artifact_ids - {capture_artifact_id(context.expected_receipt_id)}
        if referenced != constituent_artifact_ids:
            issues.append(_issue("artifact-binding-drift", f"{path}.artifacts", "execution artifacts must be bound by constituents exactly"))

    if receipt_type is ReceiptType.INDEPENDENT_REVIEW and record.get(
        "command_id"
    ) in {*INDEPENDENT_REVIEW_COMMAND_LENSES, _INDEPENDENT_REVIEW_COMMAND_ID}:
        command_id = record.get("command_id")
        expected_lenses = (
            (INDEPENDENT_REVIEW_COMMAND_LENSES[command_id],)
            if command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
            else tuple(INDEPENDENT_REVIEW_COMMAND_LENSES)
        )
        observed_lenses = tuple(sorted(
            item.get("selector_id")
            for item in constituents
            if isinstance(item.get("selector_id"), str)
        ))
        if observed_lenses != expected_lenses:
            issues.append(
                _issue(
                    "independent-review-lens-coverage",
                    f"{path}.constituents",
                    "independent review constituents differ from the frozen command-to-lens authority",
                )
            )
        if len(constituents) != len(expected_lenses) or any(
            item.get("status") != SelectorStatus.PASSED.value for item in constituents
        ):
            issues.append(
                _issue(
                    "independent-review-constituent-status",
                    f"{path}.constituents",
                    "independent review requires every command-authorized lens to pass",
                )
            )
        if actual_skips:
            issues.append(
                _issue(
                    "independent-review-skips-forbidden",
                    f"{path}.skips",
                    "independent review cannot authorize skipped frozen lenses",
                )
            )
        review_artifact_ids = {
            item.get("artifact_id")
            for item in artifact_values
            if isinstance(item, Mapping)
            and item.get("kind") == ArtifactKind.REVIEW_REPORT.value
            and isinstance(item.get("artifact_id"), str)
        } if isinstance(artifact_values, list) else set()
        aggregate_receipt_artifact_ids = {
            item.get("artifact_id")
            for item in artifact_values
            if isinstance(item, Mapping)
            and item.get("kind") == ArtifactKind.REVIEW_REPORT.value
            and isinstance(item.get("artifact_id"), str)
            and str(item.get("command_output", "")).endswith(
                "-review-receipt.json"
            )
        } if isinstance(artifact_values, list) else set()
        expected_artifact_ids = (
            review_artifact_ids
            if command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
            else aggregate_receipt_artifact_ids
        )
        constituent_artifact_ids = [
            item.get("artifact_ids")
            for item in constituents
        ]
        if (
            len(expected_artifact_ids) != len(expected_lenses)
            or any(not isinstance(ids, list) or len(ids) != 1 for ids in constituent_artifact_ids)
            or {
                artifact_id
                for ids in constituent_artifact_ids
                if isinstance(ids, list)
                for artifact_id in ids
                if isinstance(artifact_id, str)
            } != expected_artifact_ids
        ):
            issues.append(
                _issue(
                    "independent-review-artifact-cross-binding",
                    f"{path}.constituents",
                    "each frozen lens must bind exactly one distinct lens report or aggregate predecessor receipt",
                )
            )

    if receipt_type is not None and layer is not None and candidate is not None and evidence_status is not None:
        issues.extend(
            _validate_authority(
                record.get("authority"),
                receipt_type=receipt_type,
                layer=layer,
                candidate=context.expected_candidate,
                constituents=constituents,
                artifacts=[dict(item) for item in artifact_values if isinstance(item, Mapping)] if isinstance(artifact_values, list) else [],
                skips=actual_skips,
                aggregate_status=evidence_status,
                path=f"{path}.authority",
            )
        )

    if phase is QualificationPhase.PREMERGE and (
        layer is EvidenceLayer.POST_MERGE
        or context.expected_candidate.subject_kind is CandidateSubjectKind.POST_MERGE
    ):
        issues.append(_issue("postmerge-claim-in-premerge", path, "premerge evidence cannot claim post-merge authority"))
    if phase is QualificationPhase.POSTMERGE and (
        layer is EvidenceLayer.PROSPECTIVE_MERGE_TREE
        or context.expected_candidate.subject_kind is not CandidateSubjectKind.POST_MERGE
    ):
        issues.append(_issue("premerge-claim-in-postmerge", path, "prospective proof cannot substitute for post-merge evidence"))
    if layer is EvidenceLayer.PROSPECTIVE_MERGE_TREE and context.expected_candidate.subject_kind is not CandidateSubjectKind.PROSPECTIVE_MERGE:
        issues.append(_issue("prospective-identity-unavailable", f"{path}.candidate_identity", "prospective layer requires prospective subject identity"))
    if phase is QualificationPhase.POSTMERGE and (
        context.expected_candidate.accepted_postmerge_commit is None
        or context.expected_candidate.accepted_postmerge_tree is None
    ):
        issues.append(_issue("postmerge-identity-unavailable", f"{path}.candidate_identity", "postmerge phase requires accepted commit and tree"))

    digest = record.get("canonical_sha256")
    if not is_sha256(digest):
        issues.append(_issue("receipt-sha256", f"{path}.canonical_sha256", "invalid receipt digest"))
    else:
        try:
            expected_receipt_digest = canonical_sha256(receipt_payload(record))
        except (TypeError, ValueError) as error:
            issues.append(_issue("receipt-canonicalization", path, f"receipt is not canonicalizable: {type(error).__name__}"))
        else:
            if digest != expected_receipt_digest:
                issues.append(_issue("receipt-sha256-mismatch", f"{path}.canonical_sha256", "receipt fields differ from sealed digest"))
    return tuple(sorted(set(issues)))


CAPTURE_REQUIRED_COMMANDS = frozenset({
    "installed.task10-workflow", "installed.accessibility-semantics",
    "reconstruction.deterministic-evidence", "signed-xpc.supervision",
    "signed-xpc.complete-truncated-content", "signed-xpc.error-cancellation",
    "stress.reconstruction-authority-races",
    "qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products",
})


def validate_receipt(value: object, *, context: ReceiptValidationContext,
                     path: str = "$") -> tuple[ValidationIssue, ...]:
    """Public acceptance never accepts the physical-only regression seam."""
    command_id = value.get("command_id") if isinstance(value, Mapping) else None
    external_required = any(isinstance(item, str) and item in EXTERNAL_AUTHORITY_COMMANDS
                            for item in (command_id, context.expected_command_id))
    if external_required or context.external_admission is not None:
        if context.external_admission is None:
            return (_issue("external-admission-required", path,
                           "external authority requires independently retained admission"),)
        if not external_required or context.capture_admission is not None:
            return (_issue("external-admission", path,
                           "external authority cannot replace runnable capture admission"),)
        from .external_authority_adapter import ExternalAuthorityAdmission, validate_external_receipt
        if not isinstance(context.external_admission, ExternalAuthorityAdmission):
            return (_issue("external-admission", path, "external admission has the wrong type"),)
        try:
            validate_external_receipt(value, context=context)
        except (ValueError, TypeError, AttributeError, KeyError, OSError, RuntimeError) as error:
            return (_issue("external-admission", path, str(error)),)
        return ()
    from .executor_request_adapter import (CAPTURE_DERIVED_REPORT_COMMANDS,
                                          NATIVE_PRODUCER_COMMANDS, INSTALLED_PRODUCER_COMMANDS)
    capture_required = CAPTURE_REQUIRED_COMMANDS | CAPTURE_DERIVED_REPORT_COMMANDS
    # Retained bootstrap-native contexts require capture; historical contexts
    # keep the original default closed set, never inferred from receipt claims.
    if context.capture_derived_execution:
        capture_required |= NATIVE_PRODUCER_COMMANDS | INSTALLED_PRODUCER_COMMANDS
    if context.capture_admission is None and (
        (isinstance(command_id, str) and command_id in capture_required)
        or (isinstance(context.expected_command_id, str)
            and context.expected_command_id in capture_required)
    ):
        return (_issue("capture-admission-required", path,
                       "physical owner receipt requires independent capture admission"),)
    return _validate_physical_receipt(value, context=context, path=path)


def validate_receipts(
    values: object,
    *,
    context: ReceiptValidationContext,
) -> tuple[ValidationIssue, ...]:
    if not isinstance(values, list):
        return (_issue("array-type", "$", "receipt collection must be an array"),)
    issues: list[ValidationIssue] = []
    seen: set[str] = set()
    seen_digests: set[str] = set()
    seen_coordinates: set[tuple[object, ...]] = set()
    for index, value in enumerate(values):
        issues.extend(validate_receipt(value, context=context, path=f"$[{index}]"))
        if isinstance(value, Mapping) and isinstance(value.get("receipt_id"), str):
            receipt_id = value["receipt_id"]
            if receipt_id in seen:
                issues.append(_issue("duplicate-receipt-id", f"$[{index}].receipt_id", "receipt ID is duplicated"))
            seen.add(receipt_id)
        if isinstance(value, Mapping) and is_sha256(value.get("canonical_sha256")):
            digest = value["canonical_sha256"]
            if digest in seen_digests:
                issues.append(_issue("duplicate-receipt-digest", f"$[{index}].canonical_sha256", "receipt digest is reused"))
            seen_digests.add(digest)
        if isinstance(value, Mapping):
            coordinate = (
                value.get("candidate_identity_sha256"),
                value.get("requirement_id"),
                value.get("scenario_id"),
                value.get("evidence_layer"),
                value.get("attempt"),
            )
            if all(isinstance(item, (str, int)) and not isinstance(item, bool) for item in coordinate):
                if coordinate in seen_coordinates:
                    issues.append(_issue("duplicate-receipt-coordinate", f"$[{index}]", "receipt coordinate is duplicated"))
                seen_coordinates.add(coordinate)
    return tuple(sorted(set(issues)))
