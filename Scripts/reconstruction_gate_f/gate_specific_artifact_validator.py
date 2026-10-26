"""Authenticate executor artifacts whose meaning is gate-specific.

Generic artifact validation proves that an ordinary file matches its declared
size and digest.  Favorable signed-XPC and authority-stress receipts need a
stronger property: the bytes must be the exact outputs of the governed command
and must carry the command's closed semantic result.  This module derives every
command output and stress scenario from the existing Lane C catalogs; it does
not maintain a parallel selector or scenario vocabulary.
"""

from __future__ import annotations

import json
import hashlib
import plistlib
import re
from dataclasses import dataclass
from collections.abc import Mapping, Sequence
from pathlib import Path, PurePosixPath
from typing import Any

from Scripts.reconstruction.run_authority_stress import (
    SWIFT_TEST_SELECTOR,
    SWIFT_EXECUTABLE_ADAPTERS,
    StressHarnessError,
    compile_authority_stress_plan,
    plan_mapping,
    validate_python_results,
    validate_swift_attempt_ledger,
)
from Scripts.reconstruction.native_live_preparation_receipt import (
    PreparationReceiptError,
    canonical_bytes as preparation_canonical_bytes,
    parse_document as parse_preparation_document,
)
from Scripts.reconstruction.audit_installed_network_acquisition import (
    AuditInputError as InstalledNetworkAuditError,
    classify_matrix_observation,
    MANDATORY_EXECUTABLE_NAMES,
    MATRIX_REPORT_SCHEMA_VERSION,
    MATRIX_OBSERVER_ID,
    MATRIX_EVIDENCE_SCOPE,
    MATRIX_LIMITATIONS,
    MatrixObservationSummary,
)
from Scripts.reconstruction.network_attribution import (
    NetworkAttributionError,
    validate_foreign_proofs,
)
from Scripts.reconstruction.installed_matrix_receipt import (
    InstalledMatrixReceiptError,
    PRESENTATION_SCENARIO,
    PRESENTATION_TEST_IDENTIFIER,
    PRESENTATION_VARIANTS,
    SCHEMA_VERSION as INSTALLED_MATRIX_SCHEMA_VERSION,
    decode_png_dimensions,
    expected_presentation_attachment_name,
    parse_document as parse_installed_matrix_receipt,
    presentation_artifact_handoff_name,
)
from Scripts.ws24_emit_installed_qualification_report import (
    installed_selector_projection,
    load_installed_selector_catalog,
)

from .artifact_validator import read_descriptor_relative_bytes, safe_relative_artifact_path
from .canonical_json import (
    CanonicalJSONError,
    canonical_sha256,
    decode_canonical_bytes,
)
from .command_catalog import (
    COMMAND_PREREQUISITES,
    INDEPENDENT_REVIEW_COMMAND_LENSES,
    SIGNED_XPC_SERVICE_IDENTITIES,
    CommandExecutionMode,
    CommandTemplate,
    campaign_profile_for_inputs,
    command_templates,
)
from .command_compiler import CommandRecord, _resolve, _validate_input_mapping
from .receipt_schema import RECEIPT_FIELDS, RECEIPT_SCHEMA_VERSION, receipt_payload
from .merge_authority_evidence import (
    MergeAuthorityEvidenceError,
    validate_postmerge_evidence,
    validate_prospective_evidence,
)
from .schema import (
    ArtifactKind,
    CandidateIdentity,
    EvidenceLayer,
    EvidenceStatus,
    ReceiptType,
    SelectorStatus,
    candidate_identity_sha256,
    candidate_to_mapping,
    is_git_object,
    is_integer,
    is_sha256,
)


_INDEPENDENT_REVIEW_COMMAND_ID = "review.independent"
_DETERMINISTIC_EVIDENCE_COMMAND_ID = "reconstruction.deterministic-evidence"
_DETERMINISTIC_EVIDENCE_ARTIFACTS: tuple[tuple[str, str, str, str], ...] = (
    ("corpus", "corpus-manifest.json", "CORPUS", "CORPUS_TWO"),
    ("evidence-frontier", "evidence-frontier.json", "FRONTIER", "FRONTIER_TWO"),
    (
        "retrieval-packet",
        "retrieval-packet.json",
        "RETRIEVAL_PACKET",
        "RETRIEVAL_PACKET_TWO",
    ),
    ("receipt", "tool-receipt.json", "RECEIPT", "RECEIPT_TWO"),
    ("checkpoint", "checkpoint.json", "CHECKPOINT", "CHECKPOINT_TWO"),
)
_DETERMINISTIC_COMPARISON_FIELDS = frozenset(
    {
        "artifacts",
        "candidate_identity_sha256",
        "command_id",
        "fresh_process_count",
        "schema_version",
    }
)
_DETERMINISTIC_COMPARISON_ROW_FIELDS = frozenset(
    {"artifact_id", "byte_count", "relative_path", "sha256"}
)
# Every execution-bearing catalog command has one bounded semantic parser.
# This explicit empty set keeps additions fail-closed until their validator is
# added to the handled closure below.
_UNVALIDATED_EXECUTION_COMMAND_IDS: frozenset[str] = frozenset()
_INDEPENDENT_REVIEW_LENSES: tuple[tuple[str, tuple[str, ...]], ...] = (
    (
        "ai-protocol-signed-xpc",
        (
            "ai-registry-protocol-xpc-identity",
            "handle-authority",
            "multi-round-receipts-crash-recovery",
        ),
    ),
    (
        "corpus-package-persistence",
        (
            "corpus-package-persistence-identity",
            "tamper-resistance",
            "migration-atomicity",
        ),
    ),
    (
        "evidence-retrieval-scheduling",
        (
            "evidence-provenance-freshness",
            "deterministic-retrieval",
            "scheduler-concurrency-cancellation",
        ),
    ),
    (
        "scope-installed-ui-governance",
        (
            "scope-containment-ui-product-behavior",
            "signing-build-governance",
            "false-green-test-audit",
        ),
    ),
)
_INDEPENDENT_REVIEW_REPORT_FIELDS = frozenset(
    {
        "schema_version",
        "report_kind",
        "lens_id",
        "reviewer_id",
        "observed_at_unix_ms",
        "candidate_commit",
        "candidate_tree",
        "candidate_identity_sha256",
        "command_id",
        "command_plan_sha256",
        "command_record_sha256",
        "governed_diff_sha256",
        "prerequisite_receipts",
        "prerequisite_receipts_sha256",
        "scope_topics",
        "findings",
        "p0_count",
        "p1_count",
        "p2_count",
        "p3_count",
        "unresolved_blocking_count",
        "result",
        "exit_code",
        "diagnostic",
    }
)
# ``reviewer_id`` remains a required legacy envelope member so existing reports
# retain their closed shape. It is intentionally not an identity authority:
# Gate F has no coordinator-issued reviewer-assignment artifact to authenticate
# it. The aggregate instead proves four distinct command-bound approval artifacts.
_INDEPENDENT_REVIEW_PREREQUISITE_FIELDS = frozenset(
    {
        "command_id",
        "receipt_id",
        "canonical_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
    }
)
_EXECUTION_REPORT_V2_FIELDS = frozenset(
    {
        "schema_version",
        "qualification_run",
        "predecessor_observations_sha256",
        "started_at_unix_ms",
        "ended_at_unix_ms",
        "result",
        "exit_code",
        "stress",
    }
)
_INDEPENDENT_REVIEW_FINDING_FIELDS = frozenset(
    {"finding_id", "severity", "state"}
)
_INDEPENDENT_REVIEW_RECEIPT_AUTHORITY_FIELDS = frozenset(
    {
        "review_commit",
        "review_tree",
        "p0_count",
        "p1_count",
        "p2_count",
        "p3_count",
        "unresolved_blocking_count",
    }
)
_INDEPENDENT_REVIEW_SEVERITIES = frozenset({"P0", "P1", "P2", "P3"})
_INDEPENDENT_REVIEW_STATES = frozenset({"open", "closed"})

MAX_SEMANTIC_ARTIFACT_BYTES = 64 * 1024 * 1024
_SIGNED_XPC_AUTHORITY_FIELDS = frozenset(
    {
        "service_identity_id",
        "service_bundle_id",
        "service_executable_sha256",
        "selector_count",
        "failed_count",
        "failure_stage",
        "failure_reason",
    }
)
_REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
_TEST_SELECTOR_DECLARATION = re.compile(
    r"^readonly TEST_SELECTOR='([^'\n]+)'$", re.MULTILINE
)
_INSTALLED_NETWORK_ROLES = frozenset(
    {"app", "ai-agent-worker", "analysis-worker", "native-decompiler", "shell-broker"}
)
_T10C_COMMAND_ID = "evidence.t10c-current-source-adjudication"
_T10C_HISTORICAL_FINDING_IDS = tuple(
    [f"T10A-P1-{index:03d}" for index in range(1, 7)]
    + [f"T10A-P2-{index:03d}" for index in range(1, 9)]
    + [f"T10A-P3-{index:03d}" for index in range(1, 6)]
)
_T10C_FINDING_IDS = tuple(value for value in _T10C_HISTORICAL_FINDING_IDS if value != "T10A-P3-004")
_T10C_EVIDENCE_GAP_IDS = (
    "T10A-P2-006",
    "T10A-P2-008",
    "T10A-P3-003",
)
_T10C_OBSOLETE_IDS = ("T10A-P3-004",)
_T10C_BUNDLE_FILES = frozenset(
    {
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
    }
)
_T10C_SOURCE_DRIFT_FIELDS = frozenset(
    {
        "allSymbolsResolved",
        "currentSource",
        "mappingCount",
        "mappings",
        "originalSource",
        "schemaVersion",
        "taskID",
    }
)
_T10C_CURRENT_SOURCE_FIELDS = frozenset(
    {
        "dirtyInputPaths",
        "headCommit",
        "headTree",
        "identityInterpretation",
        "inputPathCount",
        "worktreeInputManifestSHA256",
    }
)
_T10C_SOURCE_MAPPING_FIELDS = frozenset(
    {
        "classification",
        "currentAnchor",
        "currentAnchorLineDiagnosticOnly",
        "currentBlobSHA256",
        "currentPath",
        "currentSymbol",
        "directlyEvaluable",
        "findingID",
        "requiredTokens",
        "semanticFingerprintSHA256",
    }
)
_T10C_ADJUDICATION_FIELDS = frozenset(
    {
        "confirmedCurrentDefectCount",
        "findingCount",
        "findings",
        "openSeverityCounts",
        "outcomeCounts",
        "productSourceChangeRequired",
        "schemaVersion",
        "sourceIdentity",
        "taskID",
    }
)
_T10C_FINDING_FIELDS = frozenset(
    {
        "blocks",
        "closestTestSuite",
        "confidence",
        "currentBlobSHA256",
        "currentPath",
        "currentSeverity",
        "currentSymbol",
        "evidenceClass",
        "expectedProductionBehavior",
        "findingID",
        "installedExecutionRequired",
        "minimalVectorIDs",
        "originalSeverity",
        "outcome",
        "productChangeRequired",
        "semanticFingerprintSHA256",
        "unresolvedAssumptions",
    }
)
_T10C_REVIEW_FIELDS = frozenset(
    {
        "schema_version",
        "report_kind",
        "reviewer_id",
        "observed_at_unix_ms",
        "candidate_commit",
        "candidate_tree",
        "dirty_input_paths",
        "source_drift_sha256",
        "finding_adjudication_sha256",
        "bundle_ledger_sha256",
        "bundle_manifest_sha256",
        "bundle_file_count",
        "finding_count",
        "fixed_count",
        "evidence_gap_count",
        "obsolete_count",
        "gap_ids",
        "mutation_count",
        "mutation_caught_count",
        "mutations",
        "authority",
        "result",
        "exit_code",
        "diagnostic",
    }
)
_T10C_MUTATION_FIELDS = frozenset({"mutation_id", "caught"})
_T10C_REVIEW_AUTHORITY_FIELDS = frozenset(
    {
        "review_commit",
        "review_tree",
        "p0_count",
        "p1_count",
        "p2_count",
        "p3_count",
        "unresolved_blocking_count",
    }
)


class GateSpecificArtifactError(ValueError):
    """Physical executor artifacts do not prove the claimed gate result."""


def _fail(message: str) -> None:
    raise GateSpecificArtifactError(message)


@dataclass(frozen=True)
class _ResolvedOutputTemplate:
    """Catalog logical outputs paired with an independently admitted record.

    Resolve logical declarations with compiler semantics before canonical sorting.
    This object does not independently authenticate a caller-created record.
    """
    catalog: CommandTemplate
    record: CommandRecord
    logical_artifacts: tuple[str, ...]

    def __getattr__(self, name: str):
        return getattr(self.record, name)


def _template(
    command_id: str,
    layer: EvidenceLayer,
    *,
    execution_mode: CommandExecutionMode = CommandExecutionMode.RUNNABLE,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
) -> CommandTemplate | _ResolvedOutputTemplate:
    try:
        profile = campaign_profile_for_inputs(admitted_command_inputs or {})
    except (TypeError, ValueError) as error:
        _fail(f"invalid independently admitted compiler profile: {error}")
    matches = [item for item in command_templates(profile=profile) if item.command_id == command_id]
    if len(matches) != 1:
        _fail(f"command {command_id!r} is absent from the governed command catalog")
    template = matches[0]
    if template.evidence_layer is not layer:
        _fail("receipt layer differs from the governed command")
    if template.execution_mode is not execution_mode:
        _fail("gate-specific physical evidence has the wrong governed execution mode")
    if (admitted_command_record is None) != (admitted_command_inputs is None):
        _fail("resolved output validation requires both admitted record and compiler inputs")
    if admitted_command_record is not None:
        record = admitted_command_record
        if (not isinstance(record, CommandRecord) or record.command_id != command_id
                or record.evidence_layer is not layer or record.execution_mode is not execution_mode
                or len(record.generated_artifacts) != len(template.generated_artifacts)
                or len(record.generated_logs) != len(template.generated_logs)):
            _fail("admitted command record differs from the governed output schema")
        try:
            logical_artifacts = tuple(_resolve(item, admitted_command_inputs, allow_embedded=True)
                                      for item in template.generated_artifacts)
            logical_logs = tuple(_resolve(item, admitted_command_inputs, allow_embedded=True)
                                 for item in template.generated_logs)
        except (KeyError, TypeError, ValueError) as error:
            _fail(f"admitted output inputs cannot resolve the catalog: {error}")
        if (tuple(sorted(logical_artifacts)) != record.generated_artifacts
                or tuple(sorted(logical_logs)) != record.generated_logs):
            _fail("resolved catalog output closure differs from independently admitted record")
        return _ResolvedOutputTemplate(template, record, logical_artifacts)
    # Private legacy physical-fixture validation only; public emission supplies
    # the independently recompiled record through its admission adapter.
    return template


def _validate_command_outputs(
    template: CommandTemplate,
    *,
    artifacts: Sequence[Mapping[str, Any]],
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    if tuple(generated_artifacts) != template.generated_artifacts:
        _fail("request artifact outputs differ from the governed command catalog")
    if tuple(generated_logs) != template.generated_logs:
        _fail("request log outputs differ from the governed command catalog")
    expected = {
        *(f"artifact:{item}" for item in template.generated_artifacts),
        *(f"log:{item}" for item in template.generated_logs),
    }
    observed = {
        item.get("command_output")
        for item in artifacts
        if isinstance(item.get("command_output"), str)
    }
    if observed != expected:
        _fail("physical artifact outputs differ from the governed command catalog")


def _generated_output(template: CommandTemplate, suffix: str) -> str:
    logical = template.catalog.generated_artifacts if isinstance(template, _ResolvedOutputTemplate) else template.generated_artifacts
    matches = [index for index, item in enumerate(logical) if item.endswith(suffix)]
    if len(matches) != 1:
        _fail(
            f"governed command {template.command_id!r} does not expose one {suffix} output"
        )
    resolved = template.logical_artifacts if isinstance(template, _ResolvedOutputTemplate) else template.generated_artifacts
    return f"artifact:{resolved[matches[0]]}"


def _artifact_for_output(
    artifacts: Sequence[Mapping[str, Any]],
    command_output: str,
    *,
    kind: ArtifactKind | None = None,
    media_type: str | None = None,
) -> Mapping[str, Any]:
    matches = [item for item in artifacts if item.get("command_output") == command_output]
    if len(matches) != 1:
        _fail(f"governed output {command_output!r} does not select exactly one artifact")
    artifact = matches[0]
    if kind is not None and artifact.get("kind") != kind.value:
        _fail(f"governed output {command_output!r} has the wrong artifact kind")
    if media_type is not None and artifact.get("media_type") != media_type:
        _fail(f"governed output {command_output!r} has the wrong media type")
    return artifact


def _artifact_path(root: Path, artifact: Mapping[str, Any]) -> Path:
    relative_path = artifact.get("relative_path")
    if not safe_relative_artifact_path(relative_path):
        _fail("gate-specific artifact path is not a safe relative path")
    path = root / str(relative_path)
    try:
        resolved = path.resolve(strict=True)
    except OSError as error:
        _fail(f"gate-specific artifact cannot be resolved: {error}")
    if resolved != path or not path.is_file() or path.is_symlink():
        _fail("gate-specific artifact is not an ordinary descriptor-relative file")
    return path


def _artifact_bytes(
    root: Path, artifact: Mapping[str, Any], *,
    maximum_bytes: int = MAX_SEMANTIC_ARTIFACT_BYTES,
) -> bytes:
    relative_path = artifact.get("relative_path")
    if not safe_relative_artifact_path(relative_path):
        _fail("gate-specific artifact path is not a safe relative path")
    try:
        payload, size, digest = read_descriptor_relative_bytes(
            root,
            str(relative_path),
            maximum_bytes=maximum_bytes,
        )
    except OSError as error:
        _fail(f"gate-specific artifact cannot be opened descriptor-relatively: {error}")
    if size != artifact.get("byte_count") or digest != artifact.get("sha256"):
        _fail("gate-specific artifact bytes differ from the validated descriptor")
    return payload


def _closed_json_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail(f"gate-specific JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _decode_json_artifact(
    root: Path, artifact: Mapping[str, Any], *,
    maximum_bytes: int = MAX_SEMANTIC_ARTIFACT_BYTES,
) -> Any:
    payload = _artifact_bytes(root, artifact, maximum_bytes=maximum_bytes)
    try:
        return json.loads(
            payload,
            object_pairs_hook=_closed_json_pairs,
            parse_constant=lambda value: _fail(
                f"gate-specific JSON contains non-finite value {value!r}"
            ),
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail(f"gate-specific artifact is not valid UTF-8 JSON: {error}")


def _decode_canonical_json_artifact(root: Path, artifact: Mapping[str, Any]) -> Any:
    payload = _artifact_bytes(root, artifact)
    try:
        return decode_canonical_bytes(payload)
    except CanonicalJSONError as error:
        _fail(f"gate-specific artifact is not canonical JSON: {error}")


def _decode_t10c_newline_canonical_json_artifact(
    root: Path,
    artifact: Mapping[str, Any],
) -> Any:
    """Decode the frozen Task 10 generator dialect: canonical JSON plus one LF."""

    payload = _artifact_bytes(root, artifact)
    if not payload.endswith(b"\n"):
        _fail("T10C generator JSON must carry exactly one trailing LF")
    canonical_payload = payload[:-1]
    try:
        return decode_canonical_bytes(canonical_payload)
    except CanonicalJSONError as error:
        _fail(f"T10C generator JSON is not canonical before its trailing LF: {error}")


def _parse_t10c_bundle_ledger(payload: bytes) -> dict[str, str]:
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        _fail(f"T10C bundle ledger is not UTF-8: {error}")
    if not text.endswith("\n") or "\r" in text:
        _fail("T10C bundle ledger must use canonical newline-terminated records")
    records: dict[str, str] = {}
    order: list[str] = []
    for line_number, line in enumerate(text.splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        if match is None:
            _fail(f"T10C bundle ledger line {line_number} is malformed")
        digest, name = match.groups()
        if name in records:
            _fail("T10C bundle ledger contains a duplicate path")
        records[name] = digest
        order.append(name)
    if order != sorted(order) or set(records) != _T10C_BUNDLE_FILES:
        _fail("T10C bundle ledger is not the exact sorted output closure")
    return records


def _t10c_bundle_manifest_sha256(records: Mapping[str, str]) -> str:
    """Match the frozen Task 10 adjudication manifest framing exactly."""

    framed = b"".join(
        path.encode("utf-8")
        + b"\0"
        + records[path].encode("ascii")
        + b"\n"
        for path in sorted(records)
    )
    return hashlib.sha256(framed).hexdigest()


def _validate_t10c_source_drift(
    value: object,
    *,
    candidate: CandidateIdentity,
    historical: bool = False,
) -> Mapping[str, Any]:
    expected_ids = _T10C_HISTORICAL_FINDING_IDS if historical else _T10C_FINDING_IDS
    source = _closed_mapping(value, _T10C_SOURCE_DRIFT_FIELDS, label="T10C source drift")
    if (
        source.get("schemaVersion") != 1
        or source.get("taskID") != "RECON-R1-T10C"
        or source.get("mappingCount") != len(expected_ids)
        or source.get("allSymbolsResolved") is not True
    ):
        _fail("T10C source drift does not identify the exact resolved finding inventory")
    original = _closed_mapping(
        source.get("originalSource"),
        frozenset({"commit", "tree"}),
        label="T10C original source",
    )
    if not is_git_object(original.get("commit")) or not is_git_object(original.get("tree")):
        _fail("T10C original source does not carry exact Git identity")
    current = _closed_mapping(
        source.get("currentSource"),
        _T10C_CURRENT_SOURCE_FIELDS,
        label="T10C current source",
    )
    if (
        current.get("headCommit") != candidate.source.commit
        or current.get("headTree") != candidate.source.tree
        or current.get("dirtyInputPaths") != []
        or not is_integer(current.get("inputPathCount"))
        or current.get("inputPathCount", 0) < 1
        or not is_sha256(current.get("worktreeInputManifestSHA256"))
        or not isinstance(current.get("identityInterpretation"), str)
        or not current.get("identityInterpretation")
    ):
        _fail("T10C current-source audit is dirty or belongs to another candidate")
    mappings = source.get("mappings")
    if not isinstance(mappings, list) or len(mappings) != len(expected_ids):
        _fail("T10C source drift must carry the exact expected mapping inventory")
    observed_ids: list[str] = []
    for index, item in enumerate(mappings):
        row = _closed_mapping(
            item, _T10C_SOURCE_MAPPING_FIELDS, label=f"T10C source mapping[{index}]"
        )
        finding_id = row.get("findingID")
        observed_ids.append(str(finding_id))
        tokens = row.get("requiredTokens")
        if (
            finding_id not in expected_ids
            or row.get("classification") != "materially-changed"
            or row.get("directlyEvaluable") is not True
            or not safe_relative_artifact_path(row.get("currentPath"))
            or not isinstance(row.get("currentSymbol"), str)
            or not row.get("currentSymbol")
            or not isinstance(row.get("currentAnchor"), str)
            or not row.get("currentAnchor")
            or not is_integer(row.get("currentAnchorLineDiagnosticOnly"))
            or row.get("currentAnchorLineDiagnosticOnly", 0) < 1
            or not is_sha256(row.get("currentBlobSHA256"))
            or not is_sha256(row.get("semanticFingerprintSHA256"))
            or not isinstance(tokens, list)
            or not tokens
            or not all(isinstance(token, str) and token for token in tokens)
            or len(tokens) != len(set(tokens))
        ):
            _fail("T10C source drift contains a malformed finding mapping")
    if observed_ids != list(expected_ids):
        _fail("T10C source drift finding ledger is not exact and ordered")
    return source


def _validate_t10c_adjudication(
    value: object,
    *,
    source_drift: Mapping[str, Any],
    historical: bool = False,
) -> Mapping[str, Any]:
    expected_ids = _T10C_HISTORICAL_FINDING_IDS if historical else _T10C_FINDING_IDS
    adjudication = _closed_mapping(
        value, _T10C_ADJUDICATION_FIELDS, label="T10C finding adjudication"
    )
    if (
        adjudication.get("schemaVersion") != 1
        or adjudication.get("taskID") != "RECON-R1-T10C"
        or adjudication.get("sourceIdentity") != source_drift.get("currentSource")
        or adjudication.get("findingCount") != len(expected_ids)
        or adjudication.get("confirmedCurrentDefectCount") != 0
        or adjudication.get("productSourceChangeRequired") is not False
        or adjudication.get("outcomeCounts")
        != {
            "already-fixed-on-current-source": 15,
            "confirmed-current-evidence-gap": 3,
            "obsolete-after-source-change": 1 if historical else 0,
        }
        or adjudication.get("openSeverityCounts") != {"P1": 2, "P2": 1}
    ):
        _fail("T10C adjudication counts or current-source identity are not exact")
    mappings = {
        row["findingID"]: row for row in source_drift["mappings"] if isinstance(row, Mapping)
    }
    findings = adjudication.get("findings")
    if not isinstance(findings, list) or len(findings) != len(expected_ids):
        _fail("T10C adjudication must carry the exact expected finding rows")
    observed_ids: list[str] = []
    for index, item in enumerate(findings):
        row = _closed_mapping(
            item, _T10C_FINDING_FIELDS, label=f"T10C adjudication finding[{index}]"
        )
        finding_id = str(row.get("findingID"))
        observed_ids.append(finding_id)
        source_row = mappings.get(finding_id)
        vectors = row.get("minimalVectorIDs")
        if (
            source_row is None
            or row.get("currentPath") != source_row.get("currentPath")
            or row.get("currentSymbol") != source_row.get("currentSymbol")
            or row.get("currentBlobSHA256") != source_row.get("currentBlobSHA256")
            or row.get("semanticFingerprintSHA256")
            != source_row.get("semanticFingerprintSHA256")
            or row.get("evidenceClass") != "exact-current-worktree-source"
            or row.get("confidence") != "high"
            or row.get("productChangeRequired") is not False
            or row.get("unresolvedAssumptions") != []
            or not isinstance(vectors, list)
            or not vectors
            or not all(isinstance(vector, str) and vector for vector in vectors)
            or len(vectors) != len(set(vectors))
        ):
            _fail("T10C adjudication finding is not bound to its exact source mapping")
        if finding_id in _T10C_EVIDENCE_GAP_IDS:
            expected_severity = "P2" if finding_id == "T10A-P3-003" else "P1"
            if (
                row.get("outcome") != "confirmed-current-evidence-gap"
                or row.get("currentSeverity") != expected_severity
                or row.get("installedExecutionRequired") is not True
                or row.get("blocks") != "GateF"
            ):
                _fail("T10C evidence-gap finding classification is not exact")
        elif finding_id in _T10C_OBSOLETE_IDS:
            if (
                row.get("outcome") != "obsolete-after-source-change"
                or row.get("currentSeverity") != "none"
                or row.get("blocks") != "neither"
            ):
                _fail("T10C obsolete finding classification is not exact")
        elif (
            row.get("outcome") != "already-fixed-on-current-source"
            or row.get("currentSeverity") != "none"
        ):
            _fail("T10C fixed finding classification is not exact")
    if observed_ids != list(expected_ids):
        _fail("T10C adjudication finding ledger is not exact and ordered")
    return adjudication


def _closed_mapping(
    value: object,
    fields: frozenset[str],
    *,
    label: str,
) -> Mapping[str, Any]:
    if not isinstance(value, Mapping) or set(value) != fields:
        _fail(f"{label} must carry the exact closed field set")
    return value


def _nonnegative_integer(value: object, *, label: str) -> int:
    if type(value) is not int or value < 0:
        _fail(f"{label} must be a nonnegative integer")
    return value


def _selector_from_governed_command(template: CommandTemplate) -> str:
    indices = [
        index for index, item in enumerate(template.argv) if item == "--only-testing"
    ]
    if len(indices) == 1 and indices[0] + 1 < len(template.argv):
        selector = template.argv[indices[0] + 1]
    elif not indices and template.argv:
        script = template.argv[0]
        if not script.startswith("./") or not safe_relative_artifact_path(script[2:]):
            _fail("governed signed-XPC runner has no exact test selector")
        script_path = _REPOSITORY_ROOT / script[2:]
        try:
            resolved = script_path.resolve(strict=True)
            source = script_path.read_text(encoding="utf-8")
        except (OSError, UnicodeError) as error:
            _fail(f"governed signed-XPC runner cannot be inspected: {error}")
        if resolved != script_path or script_path.is_symlink():
            _fail("governed signed-XPC runner is not an ordinary source file")
        matches = _TEST_SELECTOR_DECLARATION.findall(source)
        if len(matches) != 1:
            _fail("governed signed-XPC runner must declare exactly one TEST_SELECTOR")
        selector = matches[0]
    else:
        _fail("governed signed-XPC command has an ambiguous test selector")
    if len(selector.split("/", 2)) != 3:
        _fail("governed signed-XPC selector is not TARGET/SUITE/METHOD")
    return selector


def _exact_test_result(document: Any, selector: str) -> tuple[list[str], list[str]]:
    if not isinstance(document, Mapping) or not isinstance(document.get("testNodes"), list):
        _fail("governed test-results JSON lacks a testNodes array")
    target, suite, method = selector.split("/", 2)
    matches: list[Mapping[str, Any]] = []

    def visit(node: Any, ancestors: list[str]) -> None:
        if not isinstance(node, Mapping):
            _fail("governed test-results JSON contains a non-object test node")
        node_type = node.get("nodeType")
        name = node.get("name")
        identifier = node.get("nodeIdentifier")
        if not isinstance(node_type, str) or not isinstance(name, str):
            _fail("governed test-results JSON contains an unidentifiable test node")
        texts = [name]
        if isinstance(identifier, str):
            texts.append(identifier)
        lineage = ancestors + texts
        joined = "/".join(lineage)
        method_names = {method, f"{method}()", f"{suite}.{method}", f"{suite}/{method}"}
        if (
            node_type == "Test Case"
            and (name in method_names or selector in joined)
            and suite in joined
            and target in joined
        ):
            matches.append(node)
        children = node.get("children", [])
        if not isinstance(children, list):
            _fail("governed test-results JSON contains malformed children")
        for child in children:
            visit(child, lineage)

    for root in document["testNodes"]:
        visit(root, [])
    if len(matches) != 1:
        _fail(
            "governed test-results JSON does not contain exactly one exact selected test case"
        )

    results: list[str] = []
    skips: list[str] = []

    def collect(node: Mapping[str, Any]) -> None:
        if node.get("nodeType") in {"Test Case", "Test Case Run"} and isinstance(
            node.get("result"), str
        ):
            results.append(str(node["result"]))
        if node.get("nodeType") == "Skip Message":
            skips.append(str(node.get("name", "skip")))
        for child in node.get("children", []):
            if not isinstance(child, Mapping):
                _fail("governed selected test contains a malformed child")
            collect(child)

    collect(matches[0])
    return results, skips


def _validate_exact_passed_test_result(document: Any, selector: str) -> None:
    results, skips = _exact_test_result(document, selector)
    if skips or not results or any(item != "Passed" for item in results):
        _fail("governed exact selected test was not exclusively executed and passed")


def _validate_exact_failed_test_result(document: Any, selector: str) -> None:
    results, skips = _exact_test_result(document, selector)
    if (
        skips
        or not results
        or "Failed" not in results
        or any(item not in {"Passed", "Failed"} for item in results)
    ):
        _fail("governed exact selected test did not carry one physical failure")


def _validate_failed_swift_attempt_ledger(
    plan: Mapping[str, Any],
    ledger: Mapping[str, Any],
) -> tuple[dict[str, Any], ...]:
    if set(ledger) != {"attempts", "schema_version"} or ledger.get("schema_version") != 1:
        _fail("failed stress ledger is unsupported or open")
    invocations = plan.get("invocations")
    attempts = ledger.get("attempts")
    if not isinstance(invocations, list) or not isinstance(attempts, list) or not attempts:
        _fail("failed stress plan and ledger require nonempty attempt arrays")
    swift_adapters = {item.value for item in SWIFT_EXECUTABLE_ADAPTERS}
    expected: list[tuple[tuple[str, int, int], tuple[str, ...]]] = []
    for invocation in invocations:
        if not isinstance(invocation, Mapping):
            _fail("failed stress plan contains a malformed invocation")
        if invocation.get("adapter") not in swift_adapters:
            continue
        scenario_id = invocation.get("scenario_id")
        iteration = invocation.get("iteration")
        seed = invocation.get("seed")
        axes = invocation.get("semantic_axes")
        if (
            not isinstance(scenario_id, str)
            or isinstance(iteration, bool)
            or not isinstance(iteration, int)
            or isinstance(seed, bool)
            or not isinstance(seed, int)
            or not isinstance(axes, list)
            or not axes
            or not all(isinstance(axis, str) for axis in axes)
            or axes != sorted(set(axes))
            or invocation.get("semantic_gaps") != []
            or invocation.get("semantic_status") != "fully-executable"
        ):
            _fail("failed stress Swift invocation is not fully executable")
        expected.append(((scenario_id, iteration, seed), tuple(axes)))
    if len(attempts) > len(expected):
        _fail("failed stress ledger has more attempts than the compiled plan")
    fields = {
        "iteration", "observed_semantic_axes", "scenario_id", "seed", "status"
    }
    observed: list[dict[str, Any]] = []
    for index, attempt in enumerate(attempts):
        if not isinstance(attempt, dict) or set(attempt) != fields:
            _fail("failed stress ledger contains a malformed or open attempt")
        key = (attempt.get("scenario_id"), attempt.get("iteration"), attempt.get("seed"))
        expected_key, expected_axes = expected[index]
        status = attempt.get("status")
        axes = attempt.get("observed_semantic_axes")
        if key != expected_key or status not in {"passed", "failed"}:
            _fail("failed stress ledger differs from exact compiled attempt order")
        if status == "passed" and tuple(axes) != expected_axes:
            _fail("passed prefix attempt reports the wrong production seams")
        if status == "failed" and (axes != [] or index != len(attempts) - 1):
            _fail("failed stress attempt must be the exact terminal prefix attempt")
        observed.append(attempt)
    if sum(item["status"] == "failed" for item in observed) != 1:
        _fail("failed stress ledger must carry exactly one physical failed attempt")
    return tuple(observed)


def _validate_xctestrun_binding(
    root: Path,
    artifact: Mapping[str, Any],
    *,
    plan_path: Path,
    ledger_path: Path,
    preparation_receipt: Mapping[str, Any],
    prepared_xctestrun: Mapping[str, Any],
    candidate: CandidateIdentity,
) -> None:
    try:
        document = plistlib.loads(_artifact_bytes(root, artifact))
    except plistlib.InvalidFileException as error:
        _fail(f"governed stress xctestrun is invalid: {error}")
    if not isinstance(document, Mapping):
        _fail("governed stress xctestrun is not a dictionary")
    metadata = document.get("__xctestrun_metadata__")
    suite = document.get("CoreTests")
    if (
        not isinstance(metadata, Mapping)
        or not isinstance(metadata.get("ContainerInfo"), Mapping)
        or metadata["ContainerInfo"].get("SchemeName") != "MacScopeApp"
        or not isinstance(suite, Mapping)
        or suite.get("BlueprintName") != "CoreTests"
    ):
        _fail("governed stress xctestrun is not the MacScopeApp CoreTests product")
    expected = {
        "MACSCOPE_RECONSTRUCTION_STRESS_LEDGER": str(ledger_path),
        "MACSCOPE_RECONSTRUCTION_STRESS_PLAN": str(plan_path),
    }
    for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
        environment = suite.get(field)
        if not isinstance(environment, Mapping) or any(
            environment.get(key) != value for key, value in expected.items()
        ):
            _fail(f"governed stress xctestrun {field} is not bound to the exact plan and ledger")
    try:
        preparation_bytes = _artifact_bytes(root, preparation_receipt)
        preparation = decode_canonical_bytes(preparation_bytes)
        source_bytes = _artifact_bytes(root, prepared_xctestrun)
        source_document = plistlib.loads(source_bytes)
    except (CanonicalJSONError, plistlib.InvalidFileException) as error:
        _fail(f"governed stress preparation provenance is malformed: {error}")
    try:
        preparation = parse_preparation_document(preparation)
    except PreparationReceiptError as error:
        _fail(f"governed stress preparation receipt is not an exact native-live receipt: {error}")
    if preparation_bytes != preparation_canonical_bytes(preparation):
        _fail("governed stress preparation receipt is not canonical exact bytes")
    artifacts = preparation.get("artifacts")
    source = preparation.get("source")
    if not isinstance(artifacts, Mapping) or not isinstance(source, Mapping):
        _fail("governed stress preparation receipt lacks product provenance")
    expected_source = {
        "repository": candidate.source.repository,
        "branch_label": candidate.source.branch_label,
        "commit": candidate.source.commit,
        "tree": candidate.source.tree,
        "dirty": False,
        "project_yml_sha256": candidate.source.project_yml_sha256,
        "generated_project_sha256": candidate.source.generated_project_sha256,
    }
    if source != expected_source:
        _fail("governed stress preparation receipt belongs to another candidate source")
    xctestrun_record = artifacts.get("xctestrun")
    core_tests_record = artifacts.get("core_tests")
    if (
        not isinstance(xctestrun_record, Mapping)
        or xctestrun_record.get("sha256") != hashlib.sha256(source_bytes).hexdigest()
        or not isinstance(core_tests_record, Mapping)
        or not is_sha256(core_tests_record.get("closed_tree_sha256"))
        or not is_sha256(core_tests_record.get("executable_sha256"))
    ):
        _fail("governed stress preparation receipt does not bind its exact xctestrun and CoreTests product")
    if not isinstance(source_document, Mapping):
        _fail("governed stress prepared xctestrun is not a dictionary")
    expected_document = plistlib.loads(plistlib.dumps(source_document, sort_keys=True))
    expected_suite = expected_document.get("CoreTests")
    if not isinstance(expected_suite, dict):
        _fail("governed stress prepared xctestrun lacks CoreTests")
    for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
        environment = expected_suite.get(field)
        if not isinstance(environment, dict) or set(environment).intersection(expected):
            _fail("governed stress prepared xctestrun has an unsafe preexisting stress environment")
        environment.update(expected)
    if plistlib.dumps(document, sort_keys=True) != plistlib.dumps(expected_document, sort_keys=True):
        _fail("governed stress xctestrun differs from the prepared product beyond the allowed environment overlay")


def validate_signed_xpc_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    template = _template(command_id, EvidenceLayer.SIGNED_XPC, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    report = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if report.get("artifact_id") != execution_report_artifact_id:
        _fail("execution-report artifact ID differs from the governed runner output")
    executable = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTABLE"),
        kind=ArtifactKind.SIGNED_EXECUTABLE,
        media_type="application/octet-stream",
    )
    test_results = _artifact_for_output(
        artifacts,
        _generated_output(template, "TEST_RESULTS"),
        kind=ArtifactKind.TEST_RESULTS,
        media_type="application/json",
    )
    if not isinstance(authority, Mapping) or set(authority) != _SIGNED_XPC_AUTHORITY_FIELDS:
        _fail("signed-XPC authority must be a closed object")
    expected_identity_id = SIGNED_XPC_SERVICE_IDENTITIES.get(command_id)
    if expected_identity_id is None:
        _fail("governed signed-XPC command has no declared service identity")
    identity_id = authority.get("service_identity_id")
    if identity_id != expected_identity_id:
        _fail("signed-XPC authority service differs from the governed command identity")
    matches = [
        item
        for item in candidate.application.qualification_executables
        if item.identity_id == identity_id
    ]
    if len(matches) != 1:
        _fail("signed-XPC service is absent from the candidate qualification product")
    expected = matches[0]
    if (
        authority.get("service_bundle_id") != expected.bundle_identifier
        or authority.get("service_executable_sha256") != expected.sha256
        or executable.get("sha256") != expected.sha256
    ):
        _fail("physical signed executable differs from the exact candidate service executable")
    selector = _selector_from_governed_command(template)
    # Receipt selectors name semantic scenarios, not physical XCTest cases.
    # One governed error/cancellation test proves two scenario constituents;
    # its physical result must still contain exactly the one selected case.
    semantic_count = (
        len(admitted_command_record.scenario_ids) or 1
        if admitted_command_record is not None else 1
    )
    if (
        type(authority.get("selector_count")) is not int
        or authority.get("selector_count") != semantic_count
        or type(authority.get("failed_count")) is not int
    ):
        _fail("signed-XPC authority counts differ from the admitted semantic scenario closure")
    if result is EvidenceStatus.PASSED:
        if (
            authority.get("failed_count") != 0
            or authority.get("failure_stage") is not None
            or authority.get("failure_reason") is not None
        ):
            _fail("passed signed-XPC authority carries an invalid failure classification")
        _validate_exact_passed_test_result(
            _decode_json_artifact(artifact_root, test_results), selector
        )
    elif result is EvidenceStatus.FAILED:
        # A failed receipt is not an unstructured diagnostic bucket.  This
        # runner publishes exact selected-test evidence, so a physical selected
        # failure is mandatory before it can describe a failed execution.
        if (
            not 1 <= authority.get("failed_count") <= semantic_count
            or authority.get("failure_stage") != "selected-test"
            or authority.get("failure_reason") != "selected-test-failed"
        ):
            _fail("failed signed-XPC authority has an invalid closed failure classification")
        _validate_exact_failed_test_result(
            _decode_json_artifact(artifact_root, test_results), selector
        )


def validate_stress_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    stress: Mapping[str, Any],
    constituents: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> dict[str, Any]:
    template = _template(command_id, EvidenceLayer.STRESS_RECOVERY, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    roles = {
        "plan": _artifact_for_output(
            artifacts,
            _generated_output(template, "_PLAN"),
            kind=ArtifactKind.JSON,
            media_type="application/json",
        ),
        "ledger": _artifact_for_output(
            artifacts,
            _generated_output(template, "ATTEMPT_LEDGER"),
            kind=ArtifactKind.JSON,
            media_type="application/json",
        ),
        "test_results": _artifact_for_output(
            artifacts,
            _generated_output(template, "TEST_RESULTS"),
            kind=ArtifactKind.TEST_RESULTS,
            media_type="application/json",
        ),
        "report": _artifact_for_output(
            artifacts,
            _generated_output(template, "_REPORT"),
            kind=ArtifactKind.STRESS_REPORT,
            media_type="application/json",
        ),
        "xctestrun": _artifact_for_output(
            artifacts,
            _generated_output(template, ":MACSCOPE_AUTHORITY_STRESS_XCTESTRUN"),
            media_type="application/x-plist",
        ),
        "preparation_receipt": _artifact_for_output(
            artifacts,
            _generated_output(template, "PREPARATION_RECEIPT"),
            kind=ArtifactKind.JSON,
            media_type="application/json",
        ),
        "prepared_xctestrun": _artifact_for_output(
            artifacts,
            _generated_output(template, "PREPARED_XCTESTRUN"),
            kind=ArtifactKind.JSON,
            media_type="application/x-plist",
        ),
    }
    if roles["report"].get("artifact_id") != execution_report_artifact_id:
        _fail("stress execution-report artifact differs from the governed runner output")
    plan_path = _artifact_path(artifact_root, roles["plan"])
    ledger_path = _artifact_path(artifact_root, roles["ledger"])
    try:
        plan = decode_canonical_bytes(_artifact_bytes(artifact_root, roles["plan"]))
        ledger = decode_canonical_bytes(_artifact_bytes(artifact_root, roles["ledger"]))
    except CanonicalJSONError as error:
        _fail(f"governed stress plan or ledger is not canonical JSON: {error}")
    if not isinstance(plan, Mapping) or plan.get("repetitions") != 1:
        _fail("governed stress plan must use the command catalog's single repetition")
    expected_plan = plan_mapping(compile_authority_stress_plan(candidate, repetitions=1))
    if set(plan) != set(expected_plan) | {"python_results"} or any(
        plan.get(key) != value for key, value in expected_plan.items()
    ):
        _fail("physical stress plan differs from the exact compiled stress plan")
    try:
        python_attempts = validate_python_results(plan, plan.get("python_results"))
        if result in {EvidenceStatus.PASSED, EvidenceStatus.UNAVAILABLE}:
            swift_attempts = validate_swift_attempt_ledger(plan, ledger)
        else:
            swift_attempts = _validate_failed_swift_attempt_ledger(plan, ledger)
    except (StressHarnessError, ValueError) as error:
        _fail(f"physical stress plan and attempt ledger do not pair exactly: {error}")
    invocations = plan["invocations"]
    expected_tuples = [
        (item["scenario_id"], item["iteration"], item["seed"])
        for item in invocations
    ]
    expected_seeds = [item[2] for item in expected_tuples]
    if stress.get("attempt_seeds") != expected_seeds:
        _fail("execution report seeds differ from the exact compiled stress plan")
    physical_status_by_tuple = {
        (item["scenario_id"], item["iteration"], item["seed"]): "passed"
        for item in python_attempts
    }
    physical_status_by_tuple.update(
        {
            (item["scenario_id"], item["iteration"], item["seed"]): item["status"]
            for item in swift_attempts
        }
    )
    expected_status_by_scenario = {
        scenario_id: physical_status_by_tuple.get(
            (scenario_id, iteration, seed),
            SelectorStatus.NOT_RUN.value,
        )
        for scenario_id, iteration, seed in expected_tuples
    }
    observed_count = sum(
        status in {SelectorStatus.PASSED.value, SelectorStatus.FAILED.value}
        for status in expected_status_by_scenario.values()
    )
    failed_count = sum(
        status == SelectorStatus.FAILED.value
        for status in expected_status_by_scenario.values()
    )
    if (
        stress.get("expected_attempt_count") != len(expected_tuples)
        or stress.get("observed_attempt_count") != observed_count
        or stress.get("failed_count") != failed_count
    ):
        _fail("execution report counts differ from the exact physical stress attempts")
    if not isinstance(constituents, list):
        _fail("stress constituents must be an array")
    constituent_by_scenario = {
        item.get("selector_id"): item
        for item in constituents
        if isinstance(item, Mapping) and isinstance(item.get("selector_id"), str)
    }
    expected_scenarios = set(expected_status_by_scenario)
    if (
        len(constituent_by_scenario) != len(constituents)
        or set(constituent_by_scenario) != expected_scenarios
    ):
        _fail("stress constituents differ from the exact compiled scenario attempts")
    if any(
        constituent_by_scenario[scenario_id].get("status") != expected_status
        for scenario_id, expected_status in expected_status_by_scenario.items()
    ):
        _fail("stress constituent statuses differ from the exact physical stress attempts")
    if result is EvidenceStatus.PASSED:
        if failed_count != 0 or observed_count != len(expected_tuples):
            _fail("passed stress evidence contains a non-passed exact constituent")
        _validate_exact_passed_test_result(
            _decode_json_artifact(artifact_root, roles["test_results"]),
            SWIFT_TEST_SELECTOR,
        )
    elif result is EvidenceStatus.FAILED:
        if failed_count == 0:
            _fail("failed stress evidence contains no exact physical failed attempt")
        _validate_exact_failed_test_result(
            _decode_json_artifact(artifact_root, roles["test_results"]),
            SWIFT_TEST_SELECTOR,
        )
    _validate_xctestrun_binding(
        artifact_root,
        roles["xctestrun"],
        plan_path=plan_path,
        ledger_path=ledger_path,
        preparation_receipt=roles["preparation_receipt"],
        prepared_xctestrun=roles["prepared_xctestrun"],
        candidate=candidate,
    )
    return {
        "expected_attempt_count": len(expected_tuples),
        "observed_attempt_count": observed_count,
        "attempt_seeds": expected_seeds,
        "seed_catalog_sha256": canonical_sha256(expected_seeds),
        "failed_count": failed_count,
    }


def validate_hosted_governance_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    """Bind hosted-pure results to one sealed source and exact test closure."""

    if command_id != "source.hosted-governance":
        _fail("hosted-governance physical validation used another command")
    template = _template(command_id, EvidenceLayer.HOSTED_PURE, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    test_results_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "TEST_RESULTS"),
        kind=ArtifactKind.TEST_RESULTS,
        media_type="application/json",
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("hosted-governance execution report differs from the governed output")
    if result is not EvidenceStatus.PASSED:
        return

    report = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, test_results_artifact),
        frozenset(
            {
                "schema_version",
                "report_kind",
                "command_id",
                "candidate_identity_sha256",
                "source_authority",
                "discovered_modules",
                "macos_only_modules",
                "selected_modules",
                "expected_test_ids",
                "expected_test_ids_sha256",
                "test_results",
                "expected_test_count",
                "executed_test_count",
                "passed_test_count",
                "failed_test_count",
                "error_test_count",
                "skipped_test_count",
                "expected_failure_count",
                "unexpected_success_count",
                "result",
                "exit_code",
            }
        ),
        label="hosted-governance test-results report",
    )
    candidate_digest = candidate_identity_sha256(candidate)
    source = _closed_mapping(
        report.get("source_authority"),
        frozenset(
            {
                "canonical_source_root",
                "git_head_commit",
                "git_head_tree",
                "source_file_count",
                "source_files_sha256",
                "source_provenance_sha256",
                "test_module_inventory_sha256",
            }
        ),
        label="hosted-governance source authority",
    )
    source_root = source.get("canonical_source_root")
    if (
        report.get("schema_version") != 2
        or report.get("report_kind") != "hosted-governance-test-results-v2"
        or report.get("command_id") != command_id
        or report.get("candidate_identity_sha256") != candidate_digest
        or not isinstance(source_root, str)
        or not Path(source_root).is_absolute()
        or source.get("git_head_commit") != candidate.source.commit
        or source.get("git_head_tree") != candidate.source.tree
        or not is_integer(source.get("source_file_count"))
        or source.get("source_file_count", 0) < 1
        or not is_sha256(source.get("source_files_sha256"))
        or not is_sha256(source.get("source_provenance_sha256"))
        or report.get("result") != EvidenceStatus.PASSED.value
        or report.get("exit_code") != 0
    ):
        _fail("hosted-governance report is not bound to the exact sealed candidate source")

    discovered = report.get("discovered_modules")
    selected = report.get("selected_modules")
    denylisted = report.get("macos_only_modules")
    if (
        not isinstance(discovered, list)
        or not discovered
        or any(not isinstance(item, str) or not item for item in discovered)
        or discovered != sorted(set(discovered))
        or not isinstance(selected, list)
        or not selected
        or any(not isinstance(item, str) or not item for item in selected)
        or selected != sorted(set(selected))
        or not isinstance(denylisted, list)
    ):
        _fail("hosted-governance module closure is empty, duplicated, or unsorted")
    denylisted_rows: list[dict[str, str]] = []
    for index, item in enumerate(denylisted):
        row = _closed_mapping(
            item,
            frozenset({"module", "reason"}),
            label=f"hosted-governance denylist[{index}]",
        )
        module = row.get("module")
        reason = row.get("reason")
        if not isinstance(module, str) or not module or not isinstance(reason, str) or not reason:
            _fail("hosted-governance denylist row is malformed")
        denylisted_rows.append({"module": module, "reason": reason})
    if denylisted_rows != sorted(denylisted_rows, key=lambda item: item["module"]):
        _fail("hosted-governance denylist is not uniquely sorted")
    denied_modules = [item["module"] for item in denylisted_rows]
    if (
        len(denied_modules) != len(set(denied_modules))
        or not set(denied_modules).issubset(discovered)
        or selected != [item for item in discovered if item not in set(denied_modules)]
        or source.get("test_module_inventory_sha256")
        != canonical_sha256(discovered)
    ):
        _fail("hosted-governance discovered, denylisted, and selected module closure differs")

    expected_ids = report.get("expected_test_ids")
    rows = report.get("test_results")
    if (
        not isinstance(expected_ids, list)
        or not expected_ids
        or any(not isinstance(item, str) or not item for item in expected_ids)
        or expected_ids != sorted(set(expected_ids))
        or report.get("expected_test_ids_sha256") != canonical_sha256(expected_ids)
        or not isinstance(rows, list)
    ):
        _fail("hosted-governance expected test closure is empty, open, or unordered")
    normalized_rows: list[dict[str, str]] = []
    for index, item in enumerate(rows):
        row = _closed_mapping(
            item,
            frozenset({"status", "test_id"}),
            label=f"hosted-governance test result[{index}]",
        )
        if not isinstance(row.get("test_id"), str) or row.get("status") != "passed":
            _fail("hosted-governance test closure contains a non-passed leaf")
        normalized_rows.append(dict(row))
    if [item["test_id"] for item in normalized_rows] != expected_ids:
        _fail("hosted-governance execution does not close the exact expected test IDs")
    count = len(expected_ids)
    if (
        report.get("expected_test_count") != count
        or report.get("executed_test_count") != count
        or report.get("passed_test_count") != count
        or report.get("failed_test_count") != 0
        or report.get("error_test_count") != 0
        or report.get("skipped_test_count") != 0
        or report.get("expected_failure_count") != 0
        or report.get("unexpected_success_count") != 0
    ):
        _fail("hosted-governance favorable counts differ from the exact passed leaf closure")


_ACCESSIBILITY_SCREENSHOT_OUTPUTS: tuple[tuple[str, str, str, str, str], ...] = tuple(
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
    )
    for presentation_state, appearance, window_size, _width, _height
    in PRESENTATION_VARIANTS
)


def _png_dimensions(payload: bytes) -> tuple[int, int]:
    try:
        return decode_png_dimensions(payload)
    except InstalledMatrixReceiptError as error:
        _fail(f"installed accessibility screenshot is not a complete decodable PNG: {error}")


def validate_installed_accessibility_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    """Authenticate the frozen 22-vector accessibility and presentation proof."""

    if command_id != "installed.accessibility-semantics":
        _fail("installed-accessibility physical validation used another command")
    template = _template(command_id, EvidenceLayer.INSTALLED_ACCESSIBILITY, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    report_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "INSTALLED_ACCESSIBILITY_REPORT"),
        kind=ArtifactKind.ACCESSIBILITY_REPORT,
        media_type="application/json",
    )
    presentation_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "PRESENTATION_MANIFEST"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("installed-accessibility execution report differs from governed output")
    screenshot_artifacts = {
        (presentation_state, appearance, window_size): _artifact_for_output(
            artifacts,
            _generated_output(template, output_suffix),
            kind=ArtifactKind.ACCESSIBILITY_REPORT,
            media_type="image/png",
        )
        for output_suffix, presentation_state, appearance, window_size, _
        in _ACCESSIBILITY_SCREENSHOT_OUTPUTS
    }
    if result is not EvidenceStatus.PASSED:
        return

    candidate_digest = candidate_identity_sha256(candidate)
    projection = installed_selector_projection(load_installed_selector_catalog())
    observed_projection = [
        {
            "observed_identifiers": sorted(item["required_identifiers"]),
            "test_identifier": item["test_identifier"],
            "vector_id": item["vector_id"],
        }
        for item in projection
    ]
    expected_selectors = [
        {
            **item,
            "observed_identifiers": sorted(item["required_identifiers"]),
            "status": "passed",
        }
        for item in projection
    ]
    selector_ids = [item["test_identifier"] for item in projection]
    if len(projection) != 22:
        _fail("installed accessibility catalog is not the frozen 22-vector projection")
    report = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, report_artifact),
        frozenset(
            {
                "candidate_identity_sha256",
                "counts",
                "matrix_receipt",
                "observed_selector_projection_sha256",
                "presentation_manifest_sha256",
                "report_kind",
                "result",
                "schema_version",
                "selector_catalog_sha256",
                "selector_projection_sha256",
                "selectors",
                "xcresult_semantic_manifest_sha256",
            }
        ),
        label="installed accessibility report",
    )
    counts = _closed_mapping(
        report.get("counts"),
        frozenset({"executed", "expected", "failed", "passed", "skipped"}),
        label="installed accessibility counts",
    )
    matrix_receipt = _closed_mapping(
        report.get("matrix_receipt"),
        frozenset({"schema_version", "sha256"}),
        label="installed accessibility matrix receipt",
    )
    if (
        report.get("candidate_identity_sha256") != candidate_digest
        or report.get("report_kind") != "installed-accessibility"
        or report.get("result") != EvidenceStatus.PASSED.value
        or report.get("schema_version") != 2
        or counts != {"executed": 22, "expected": 22, "failed": 0, "passed": 22, "skipped": 0}
        or matrix_receipt.get("schema_version") != INSTALLED_MATRIX_SCHEMA_VERSION
        or not is_sha256(matrix_receipt.get("sha256"))
        or report.get("selector_catalog_sha256") != canonical_sha256(selector_ids)
        or report.get("selector_projection_sha256") != canonical_sha256(projection)
        or report.get("observed_selector_projection_sha256")
        != canonical_sha256(observed_projection)
        or report.get("selectors") != expected_selectors
        or not is_sha256(report.get("xcresult_semantic_manifest_sha256"))
    ):
        _fail("installed accessibility report does not prove the exact passed 22-vector projection")

    presentation = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, presentation_artifact),
        frozenset(
            {
                "candidate_identity_sha256",
                "matrix_receipt_sha256",
                "report_kind",
                "result",
                "schema_version",
                "screenshots",
                "source_xcresult",
                "test_identifier",
            }
        ),
        label="installed accessibility presentation manifest",
    )
    source_xcresult = _closed_mapping(
        presentation.get("source_xcresult"),
        frozenset({"bundle_sha256", "closed_tree_sha256"}),
        label="installed accessibility source xcresult",
    )
    if (
        report.get("presentation_manifest_sha256") != presentation_artifact.get("sha256")
        or presentation.get("candidate_identity_sha256") != candidate_digest
        or presentation.get("matrix_receipt_sha256") != matrix_receipt.get("sha256")
        or presentation.get("report_kind") != "installed-accessibility-presentation"
        or presentation.get("result") != EvidenceStatus.PASSED.value
        or presentation.get("schema_version") != 2
        or presentation.get("test_identifier") != PRESENTATION_TEST_IDENTIFIER
        or not all(is_sha256(value) for value in source_xcresult.values())
    ):
        _fail("installed accessibility presentation manifest is not exact and candidate-bound")
    screenshots = presentation.get("screenshots")
    if not isinstance(screenshots, list) or len(screenshots) != len(PRESENTATION_VARIANTS):
        _fail("installed accessibility presentation manifest lacks the exact 28 screenshots")
    screenshot_by_variant: dict[tuple[str, str, str], Mapping[str, Any]] = {}
    observed_hashes: set[str] = set()
    expected_variants = {
        (presentation_state, appearance, window_size): filename
        for _, presentation_state, appearance, window_size, filename
        in _ACCESSIBILITY_SCREENSHOT_OUTPUTS
    }
    for index, item in enumerate(screenshots):
        row = _closed_mapping(
            item,
            frozenset(
                {
                    "appearance",
                    "byte_count",
                    "pixel_height",
                    "pixel_width",
                    "presentation_state",
                    "relative_path",
                    "sha256",
                    "window_size",
                }
            ),
            label=f"installed accessibility screenshot[{index}]",
        )
        variant = (
            row.get("presentation_state"),
            row.get("appearance"),
            row.get("window_size"),
        )
        if variant in screenshot_by_variant:
            _fail("installed accessibility presentation duplicates a screenshot variant")
        screenshot_by_variant[variant] = row
    if set(screenshot_by_variant) != set(expected_variants):
        _fail("installed accessibility presentation variants are not exact")
    for variant, filename in expected_variants.items():
        row = screenshot_by_variant[variant]
        artifact = screenshot_artifacts[variant]
        payload = _artifact_bytes(artifact_root, artifact)
        width, height = _png_dimensions(payload)
        if (
            row.get("relative_path") != filename
            or Path(str(artifact.get("relative_path"))).name != filename
            or row.get("byte_count") != artifact.get("byte_count")
            or row.get("sha256") != artifact.get("sha256")
            or row.get("pixel_width") != width
            or row.get("pixel_height") != height
        ):
            _fail("installed accessibility screenshot manifest differs from exact PNG bytes")
        observed_hashes.add(str(row.get("sha256")))
    if len(observed_hashes) != len(PRESENTATION_VARIANTS):
        _fail("installed accessibility screenshots do not carry 28 distinct contents")


def validate_install_release_to_applications_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    """Authenticate the exact atomic Release-to-/Applications transaction."""

    if command_id != "install.release-to-applications":
        _fail("installed-source physical validation requires the governed installer")
    template = _template(command_id, EvidenceLayer.INSTALLED_SOURCE_EQUALITY, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    operation_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "OPERATION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    equality_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "SOURCE_EQUALITY_REPORT"),
        kind=ArtifactKind.SOURCE_EQUALITY_REPORT,
        media_type="application/json",
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("installer execution-report artifact differs from the governed output")
    if result is not EvidenceStatus.PASSED:
        return

    candidate_digest = candidate_identity_sha256(candidate)
    expected_bundle_identity = {
        "bundle_sha256": candidate.application.bundle_sha256,
        "closed_tree_sha256": candidate.application.closed_tree_sha256,
        "root_mode": candidate.application.root_mode,
    }
    expected_equality = {
        "release_bundle_sha256": candidate.application.bundle_sha256,
        "release_closed_tree_sha256": candidate.application.closed_tree_sha256,
        "release_root_mode": candidate.application.root_mode,
        "release_executable_sha256": candidate.application.executable_sha256,
        "installed_bundle_sha256": candidate.application.bundle_sha256,
        "installed_closed_tree_sha256": candidate.application.closed_tree_sha256,
        "installed_root_mode": candidate.application.root_mode,
        "installed_executable_sha256": candidate.application.executable_sha256,
    }
    operation = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, operation_artifact),
        frozenset(
            {
                "schema_version",
                "report_kind",
                "candidate_identity_sha256",
                "candidate_file_sha256",
                "source_app_path",
                "installed_app_path",
                "production_destination",
                "source_identity",
                "predecessor",
                "staging",
                "atomic_replacement",
                "rollback",
                "point_of_no_return_reached",
                "predecessor_clearance",
                "transaction_residue",
                "result",
                "diagnostic",
            }
        ),
        label="installer operation report",
    )
    source_path = operation.get("source_app_path")
    installed_path = operation.get("installed_app_path")
    if (
        operation.get("schema_version") != 2
        or operation.get("report_kind") != "release-to-applications-operation"
        or operation.get("candidate_identity_sha256") != candidate_digest
        or operation.get("candidate_file_sha256")
        != canonical_sha256(candidate_to_mapping(candidate))
        or not isinstance(source_path, str)
        or not Path(source_path).is_absolute()
        or Path(source_path).name != "MacScope.app"
        or source_path == "/Applications/MacScope.app"
        or installed_path != "/Applications/MacScope.app"
        or operation.get("production_destination") != "/Applications/MacScope.app"
        or operation.get("result") != EvidenceStatus.PASSED.value
        or operation.get("diagnostic") is not None
    ):
        _fail("installer operation report belongs to another exact candidate or path")
    source_identity = _closed_mapping(
        operation.get("source_identity"),
        frozenset({"bundle_sha256", "closed_tree_sha256", "root_mode"}),
        label="installer source identity",
    )
    source_root_mode = _nonnegative_integer(
        source_identity["root_mode"], label="installer source root mode"
    )
    if (
        source_identity["bundle_sha256"] != expected_bundle_identity["bundle_sha256"]
        or source_identity["closed_tree_sha256"]
        != expected_bundle_identity["closed_tree_sha256"]
        or source_root_mode != expected_bundle_identity["root_mode"]
    ):
        _fail("installer source identity is not exact and mode-complete")
    predecessor = _closed_mapping(
        operation.get("predecessor"),
        frozenset({"present", "identity"}),
        label="installer predecessor",
    )
    predecessor_present = predecessor.get("present")
    predecessor_identity = predecessor.get("identity")
    if type(predecessor_present) is not bool:
        _fail("installer predecessor presence must be Boolean")
    if predecessor_present:
        predecessor_record = _closed_mapping(
            predecessor_identity,
            frozenset({"bundle_sha256", "closed_tree_sha256", "root_mode"}),
            label="installer predecessor identity",
        )
        if (
            not is_sha256(predecessor_record["bundle_sha256"])
            or not is_sha256(predecessor_record["closed_tree_sha256"])
            or _nonnegative_integer(
                predecessor_record["root_mode"],
                label="installer predecessor root mode",
            ) > 0o7777
        ):
            _fail("installer predecessor identity is malformed")
    elif predecessor_identity is not None:
        _fail("absent installer predecessor cannot carry an identity")
    staging = _closed_mapping(
        operation.get("staging"),
        frozenset({"fresh_sibling", "same_volume", "source_equality_validated"}),
        label="installer staging authority",
    )
    if any(staging.get(field) is not True for field in staging):
        _fail("installer staging was not fresh, same-volume, and source-equal")
    atomic = _closed_mapping(
        operation.get("atomic_replacement"),
        frozenset({"primitive", "mode"}),
        label="installer atomic replacement",
    )
    expected_mode = "swap-existing" if predecessor_present else "exclusive-absent"
    if atomic != {"primitive": "renameatx_np", "mode": expected_mode}:
        _fail("installer did not use the exact atomic primitive and predecessor flag")
    rollback = _closed_mapping(
        operation.get("rollback"),
        frozenset({"attempted", "succeeded"}),
        label="installer rollback",
    )
    if rollback != {"attempted": False, "succeeded": None}:
        _fail("passed installer reports rollback activity after its commit boundary")
    clearance = _closed_mapping(
        operation.get("predecessor_clearance"),
        frozenset({"started", "completed"}),
        label="installer predecessor clearance",
    )
    expected_clearance = {
        "started": predecessor_present,
        "completed": True,
    }
    residue = _closed_mapping(
        operation.get("transaction_residue"),
        frozenset({"present", "path"}),
        label="installer transaction residue",
    )
    if (
        operation.get("point_of_no_return_reached") is not True
        or clearance != expected_clearance
        or residue != {"present": False, "path": None}
    ):
        _fail("passed installer does not truthfully close its commit boundary and residue")

    equality = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, equality_artifact),
        frozenset(
            {
                "schema_version",
                "report_kind",
                "candidate_identity_sha256",
                "source_app_path",
                "installed_app_path",
                "stage_authority",
                "installed_authority",
                "result",
                "diagnostic",
            }
        ),
        label="installer source-equality report",
    )
    if (
        equality.get("schema_version") != 1
        or equality.get("report_kind") != "installed-source-equality"
        or equality.get("candidate_identity_sha256") != candidate_digest
        or equality.get("source_app_path") != source_path
        or equality.get("installed_app_path") != installed_path
        or equality.get("stage_authority") != expected_equality
        or equality.get("installed_authority") != expected_equality
        or equality.get("result") != EvidenceStatus.PASSED.value
        or equality.get("diagnostic") is not None
    ):
        _fail("installer source, stage, and destination identities are not exact")
    if authority != expected_equality:
        _fail("installed-source receipt authority differs from physical equality reports")


def _validate_installed_matrix_presentation_bundle(
    *,
    artifact_root: Path,
    matrix_receipt_artifact: Mapping[str, Any],
    matrix_receipt: Mapping[str, Any],
    candidate: CandidateIdentity,
) -> None:
    """Authenticate the descriptor-relative 28-PNG handoff, not receipt path claims."""
    receipt_relative = matrix_receipt_artifact.get("relative_path")
    if not safe_relative_artifact_path(receipt_relative):
        _fail("installed matrix receipt artifact has no safe descriptor-relative path")
    receipt_parent = PurePosixPath(str(receipt_relative)).parent
    xcresult = matrix_receipt.get("products", {}).get("xcresult", {})
    xcresult_path = xcresult.get("path") if isinstance(xcresult, Mapping) else None
    if not isinstance(xcresult_path, str):
        _fail("installed matrix receipt has no xcresult handoff identity")
    try:
        bundle_name = presentation_artifact_handoff_name(Path(xcresult_path))
    except InstalledMatrixReceiptError as error:
        _fail(f"installed matrix xcresult cannot define a physical handoff: {error}")
    presentation = matrix_receipt.get("presentation_screenshots")
    if not isinstance(presentation, Mapping):
        _fail("installed matrix receipt omits physical presentation authority")
    claimed_root = presentation.get("artifact_root_path")
    claimed_manifest = presentation.get("manifest_path")
    if (
        not isinstance(claimed_root, str)
        or Path(claimed_root).name != bundle_name
        or not isinstance(claimed_manifest, str)
        or Path(claimed_manifest).name != "manifest.json"
        or Path(claimed_manifest).parent.name != bundle_name
    ):
        _fail("installed matrix presentation handoff names are not closed")
    bundle_relative = receipt_parent / bundle_name
    manifest_relative = str(bundle_relative / "manifest.json")
    if not safe_relative_artifact_path(manifest_relative):
        _fail("installed matrix presentation manifest handoff is unsafe")
    try:
        manifest_bytes, _, manifest_digest = read_descriptor_relative_bytes(
            artifact_root, manifest_relative, maximum_bytes=4 * 1024 * 1024
        )
        manifest = json.loads(manifest_bytes.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        _fail(f"installed matrix presentation manifest cannot be authenticated: {error}")
    if manifest_digest != presentation.get("manifest_sha256"):
        _fail("installed matrix presentation manifest digest differs from physical bytes")
    if not isinstance(manifest, list):
        _fail("installed matrix presentation manifest must be an array")

    expected_by_name = {
        expected_presentation_attachment_name(
            candidate, state, appearance, window_size
        ): (state, appearance, window_size, width, height)
        for state, appearance, window_size, width, height in PRESENTATION_VARIANTS
    }
    receipt_rows = presentation.get("attachments")
    if not isinstance(receipt_rows, list):
        _fail("installed matrix presentation receipt rows must be an array")
    receipt_by_variant: dict[tuple[str, str, str], Mapping[str, Any]] = {}
    for row in receipt_rows:
        if not isinstance(row, Mapping):
            _fail("installed matrix presentation receipt row is not an object")
        variant = (
            row.get("presentation_state"),
            row.get("appearance"),
            row.get("window_size"),
        )
        if variant in receipt_by_variant:
            _fail("installed matrix presentation receipt duplicates a variant")
        receipt_by_variant[variant] = row

    observed_variants: set[tuple[str, str, str]] = set()
    observed_names: set[str] = set()
    observed_exported_names: set[str] = set()
    observed_hashes: set[str] = set()
    observed_scales: set[int] = set()
    for entry in manifest:
        if not isinstance(entry, Mapping) or set(entry) - {
            "testIdentifier", "testIdentifierURL", "attachments"
        }:
            _fail("installed matrix presentation manifest entry is open or malformed")
        if entry.get("testIdentifier") != PRESENTATION_TEST_IDENTIFIER:
            continue
        attachments = entry.get("attachments")
        if not isinstance(attachments, list):
            _fail("installed matrix presentation attachment list is malformed")
        for attachment in attachments:
            if not isinstance(attachment, Mapping):
                _fail("installed matrix presentation attachment is malformed")
            human_name = attachment.get("suggestedHumanReadableName")
            if not isinstance(human_name, str) or not human_name.startswith(
                f"{PRESENTATION_SCENARIO}-"
            ):
                continue
            if human_name not in expected_by_name or human_name in observed_names:
                _fail("installed matrix presentation attachment label is unknown or duplicated")
            exported_name = attachment.get("exportedFileName")
            if (
                not isinstance(exported_name, str)
                or PurePosixPath(exported_name).name != exported_name
                or not safe_relative_artifact_path(exported_name)
                or exported_name in observed_exported_names
                or attachment.get("isAssociatedWithFailure") is not False
            ):
                _fail("installed matrix presentation attachment name or status is invalid")
            state, appearance, window_size, width, height = expected_by_name[human_name]
            variant = (state, appearance, window_size)
            row = receipt_by_variant.get(variant)
            if (
                row is None
                or row.get("test_identifier") != PRESENTATION_TEST_IDENTIFIER
                or row.get("scenario") != PRESENTATION_SCENARIO
                or Path(str(row.get("attachment_path", ""))).name != exported_name
            ):
                _fail("installed matrix presentation receipt label differs from physical manifest")
            image_relative = str(bundle_relative / exported_name)
            if not safe_relative_artifact_path(image_relative):
                _fail("installed matrix presentation image handoff is unsafe")
            try:
                image_bytes, _, image_digest = read_descriptor_relative_bytes(
                    artifact_root, image_relative, maximum_bytes=512 * 1024 * 1024
                )
                pixel_width, pixel_height = decode_png_dimensions(image_bytes)
            except (OSError, InstalledMatrixReceiptError) as error:
                _fail(f"installed matrix presentation PNG cannot be authenticated: {error}")
            if (
                image_digest != row.get("sha256")
                or pixel_width != row.get("pixel_width")
                or pixel_height != row.get("pixel_height")
                or pixel_width % width != 0
                or pixel_height % height != 0
                or pixel_width // width != pixel_height // height
                or pixel_width // width not in {1, 2}
            ):
                _fail("installed matrix presentation PNG geometry or digest is not exact")
            observed_variants.add(variant)
            observed_names.add(human_name)
            observed_exported_names.add(exported_name)
            observed_hashes.add(image_digest)
            observed_scales.add(pixel_width // width)

    expected_variants = {
        (state, appearance, window_size)
        for state, appearance, window_size, _width, _height in PRESENTATION_VARIANTS
    }
    if (
        len(receipt_rows) != 28
        or len(observed_names) != 28
        or observed_variants != expected_variants
        or set(receipt_by_variant) != expected_variants
    ):
        _fail("installed matrix presentation does not close the exact 28-image Cartesian set")
    if len(observed_hashes) != 28:
        _fail("installed matrix presentation PNG content hashes are not all distinct")
    if len(observed_scales) != 1:
        _fail("installed matrix presentation PNGs do not share one backing scale")


def _replay_installed_network_attribution(
    attribution: object, payload: bytes, *,
    candidate_paths: frozenset[str], candidate_pids: frozenset[int],
) -> MatrixObservationSummary:
    """Replay retained evidence; this does not authenticate its execution origin."""
    ledger = _closed_mapping(attribution, frozenset({
        "policy_id", "observer_spawn_ns", "observer_eof_ns", "queue_closed_ns",
        "proofs", "drains",
    }), label="installed network attribution")
    if ledger["policy_id"] != "prearmed-kqueue-path-v1":
        _fail("installed network attribution policy is not admitted")
    try:
        foreign_pids = validate_foreign_proofs(
            ledger["proofs"], ledger["drains"],
            observer_spawn_ns=ledger["observer_spawn_ns"],
            observer_eof_ns=ledger["observer_eof_ns"],
            queue_closed_ns=ledger["queue_closed_ns"],
            candidate_paths=candidate_paths,
        )
        return classify_matrix_observation(payload, candidate_pids=candidate_pids, foreign_pids=foreign_pids)
    except InstalledNetworkAuditError as error:
        _fail(f"installed network CSV is invalid: {error}")
    except NetworkAttributionError as error:
        _fail(f"installed network retained attribution is invalid: {error}")


def validate_installed_task10_workflow_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    """Bind one installed matrix execution to its complete network observation."""
    if command_id != "installed.task10-workflow":
        _fail("installed-workflow physical validation requires the governed Task 10 command")
    template = _template(command_id, EvidenceLayer.INSTALLED_WORKFLOW, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    execution_output = _generated_output(
        template, "/InstalledNetworkAcquisition.execution-report.json"
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        execution_output,
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("installed workflow execution report is not the governed network execution report")
    report_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "/InstalledNetworkAcquisition.audit.json"),
        kind=ArtifactKind.WORKFLOW_REPORT,
        media_type="application/json",
    )
    report = _closed_mapping(
        _decode_json_artifact(artifact_root, report_artifact, maximum_bytes=4 * 1024 * 1024),
        frozenset(
            {
                "schema_version", "command_id", "evidence_layer", "candidate",
                "workload", "executables", "observer", "artifacts",
                "started_at_unix_ms", "ended_at_unix_ms", "result", "exit_code",
                "diagnostic", "attribution",
            }
        ),
        label="installed network report",
    )
    if type(report["schema_version"]) is not int or report["schema_version"] != MATRIX_REPORT_SCHEMA_VERSION:
        _fail("installed network report must use schema 4")
    if report["command_id"] != "installed.network-acquisition-audit":
        _fail("installed network report has the wrong closed subcommand identity")
    if report["evidence_layer"] != EvidenceLayer.INSTALLED_LAUNCH_LOG.value:
        _fail("installed network report has the wrong evidence-layer identity")
    candidate_record = _closed_mapping(
        report["candidate"],
        frozenset({"identity_sha256", "document_sha256", "source_commit", "source_tree"}),
        label="installed network candidate",
    )
    if (
        candidate_record["identity_sha256"] != candidate_identity_sha256(candidate)
        or not is_sha256(candidate_record["document_sha256"])
        or candidate_record["source_commit"] != candidate.source.commit
        or candidate_record["source_tree"] != candidate.source.tree
    ):
        _fail("installed network report belongs to another exact candidate")
    workload = _closed_mapping(
        report["workload"],
        frozenset(
            {
                "command_id", "started_at_unix_ms", "ended_at_unix_ms",
                "observation_contains_workload", "matrix_receipt_sha256",
                "observer_ready_at_unix_ms", "observer_readiness_precedes_workload",
                "xcresult_bundle_sha256", "xcresult_closed_tree_sha256",
                "xcresult_semantic_manifest_sha256", "selector_catalog_sha256",
                "selector_projection_sha256",
                "expected_selector_count",
                "executed_selector_count", "passed_selector_count",
                "failed_selector_count", "skipped_selector_count", "matrix_result",
            }
        ),
        label="installed network workload",
    )
    workload_started = _nonnegative_integer(
        workload["started_at_unix_ms"], label="installed workload start"
    )
    workload_ended = _nonnegative_integer(
        workload["ended_at_unix_ms"], label="installed workload end"
    )
    observer_ready = _nonnegative_integer(
        workload["observer_ready_at_unix_ms"],
        label="installed workload observer readiness",
    )
    if (
        workload["command_id"] != command_id
        or workload["observation_contains_workload"] is not True
    ):
        _fail("network observation does not contain the exact installed Task 10 workload")
    if (
        workload["observer_readiness_precedes_workload"] is not True
        or observer_ready > workload_started
    ):
        _fail("installed network readiness boundary does not precede the workload")
    if workload_ended <= workload_started:
        _fail("installed workload interval must be positive")

    matrix_receipt_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "@installed_matrix_receipt@"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    semantic_manifest_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "@installed_matrix_xcresult_semantic_manifest@"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if workload["matrix_receipt_sha256"] != matrix_receipt_artifact.get("sha256"):
        _fail("installed network report is not bound to the exact matrix receipt bytes")
    if (
        workload["xcresult_semantic_manifest_sha256"]
        != semantic_manifest_artifact.get("sha256")
    ):
        _fail(
            "installed network report is not bound to the exact xcresult semantic manifest bytes"
        )
    try:
        matrix_receipt = parse_installed_matrix_receipt(
            _decode_json_artifact(artifact_root, matrix_receipt_artifact)
        )
    except InstalledMatrixReceiptError as error:
        _fail(f"installed matrix receipt is invalid: {error}")
    installed_projection = installed_selector_projection(
        load_installed_selector_catalog()
    )
    expected_selectors = [item["test_identifier"] for item in installed_projection]
    expected_observed_projection = [
        {
            "observed_identifiers": sorted(item["required_identifiers"]),
            "test_identifier": item["test_identifier"],
            "vector_id": item["vector_id"],
        }
        for item in installed_projection
    ]
    semantic_manifest = _closed_mapping(
        _decode_json_artifact(artifact_root, semantic_manifest_artifact),
        frozenset(
            {
                "schema_version", "candidate_identity_sha256", "source_xcresult",
                "selector_catalog_sha256", "selector_projection",
                "selector_projection_sha256", "observed_selector_projection",
                "observed_selector_projection_sha256", "expected_selector_count",
                "executed_selector_count", "passed_selector_count",
                "failed_selector_count", "skipped_selector_count", "selectors",
                "result",
            }
        ),
        label="installed xcresult semantic manifest",
    )
    semantic_source = _closed_mapping(
        semantic_manifest["source_xcresult"],
        frozenset({"bundle_sha256", "closed_tree_sha256"}),
        label="installed xcresult semantic source",
    )
    semantic_selectors = semantic_manifest["selectors"]
    if not isinstance(semantic_selectors, list):
        _fail("installed xcresult semantic manifest selectors must be an array")
    expected_semantic_selectors = [
        {"test_identifier": identifier, "status": "passed"}
        for identifier in expected_selectors
    ]
    normalized_semantic_selectors: list[dict[str, object]] = []
    for index, item in enumerate(semantic_selectors):
        normalized_semantic_selectors.append(
            dict(
                _closed_mapping(
                    item,
                    frozenset({"test_identifier", "status"}),
                    label=f"installed xcresult semantic selector {index}",
                )
            )
        )
    if (
        semantic_manifest["schema_version"] != 3
        or semantic_manifest["candidate_identity_sha256"]
        != candidate_identity_sha256(candidate)
        or not is_sha256(semantic_source["bundle_sha256"])
        or not is_sha256(semantic_source["closed_tree_sha256"])
        or semantic_source["bundle_sha256"] != workload["xcresult_bundle_sha256"]
        or semantic_source["closed_tree_sha256"]
        != workload["xcresult_closed_tree_sha256"]
        or semantic_manifest["selector_catalog_sha256"]
        != canonical_sha256(expected_selectors)
        or semantic_manifest["selector_catalog_sha256"]
        != workload["selector_catalog_sha256"]
        or workload["selector_projection_sha256"]
        != canonical_sha256(installed_projection)
        or workload["selector_projection_sha256"]
        != semantic_manifest["selector_projection_sha256"]
        or semantic_manifest["selector_projection"] != installed_projection
        or semantic_manifest["selector_projection_sha256"]
        != canonical_sha256(installed_projection)
        or semantic_manifest["observed_selector_projection"]
        != expected_observed_projection
        or semantic_manifest["observed_selector_projection_sha256"]
        != canonical_sha256(expected_observed_projection)
        or semantic_manifest["expected_selector_count"] != 22
        or semantic_manifest["executed_selector_count"] != 22
        or semantic_manifest["passed_selector_count"] != 22
        or semantic_manifest["failed_selector_count"] != 0
        or semantic_manifest["skipped_selector_count"] != 0
        or semantic_manifest["result"] != "passed"
        or normalized_semantic_selectors != expected_semantic_selectors
    ):
        _fail(
            "installed xcresult semantic manifest did not exactly execute and pass all 22 selectors"
        )
    execution = matrix_receipt["execution"]
    matrix_observations = matrix_receipt.get("accessibility_observations")
    sealed_candidate = matrix_receipt["candidate"]
    installed_product = matrix_receipt["products"]["installed_app"]
    xcresult_product = matrix_receipt["products"]["xcresult"]
    if matrix_receipt.get("schema_version") != INSTALLED_MATRIX_SCHEMA_VERSION:
        _fail("installed matrix receipt predates observed-identifier attachment authority")
    if (
        sealed_candidate["identity_sha256"] != candidate_identity_sha256(candidate)
        or sealed_candidate["source_commit"] != candidate.source.commit
        or sealed_candidate["source_tree"] != candidate.source.tree
        or installed_product["bundle_identifier"] != candidate.application.bundle_identifier
        or installed_product["executable_sha256"] != candidate.application.executable_sha256
    ):
        _fail("installed matrix receipt belongs to another exact candidate")
    _validate_installed_matrix_presentation_bundle(
        artifact_root=artifact_root,
        matrix_receipt_artifact=matrix_receipt_artifact,
        matrix_receipt=matrix_receipt,
        candidate=candidate,
    )
    if (
        execution["result"] != "passed"
        or execution["exit_code"] != 0
        or execution["failure"] is not None
        or execution["selectors"] != expected_selectors
        or execution.get("selector_projection") != installed_projection
        or execution.get("selector_projection_sha256")
        != canonical_sha256(installed_projection)
        or workload["selector_projection_sha256"]
        != execution.get("selector_projection_sha256")
        or not isinstance(matrix_observations, Mapping)
        or matrix_observations.get("observed_selector_projection")
        != expected_observed_projection
        or matrix_observations.get("observed_selector_projection_sha256")
        != canonical_sha256(expected_observed_projection)
        or len(expected_selectors) != 22
        or workload["selector_catalog_sha256"] != canonical_sha256(expected_selectors)
        or workload["expected_selector_count"] != 22
        or workload["executed_selector_count"] != 22
        or workload["passed_selector_count"] != 22
        or workload["failed_selector_count"] != 0
        or workload["skipped_selector_count"] != 0
        or workload["matrix_result"] != "passed"
        or workload["xcresult_semantic_manifest_sha256"]
        != semantic_manifest_artifact.get("sha256")
    ):
        _fail("installed matrix did not exactly execute and pass all 22 selectors")
    if (
        not isinstance(xcresult_product, Mapping)
        or xcresult_product.get("closed_tree_sha256")
        != workload["xcresult_closed_tree_sha256"]
        or semantic_source["closed_tree_sha256"]
        != xcresult_product.get("closed_tree_sha256")
        or not is_sha256(workload["xcresult_closed_tree_sha256"])
    ):
        _fail("installed matrix receipt is not bound to the exact xcresult tree")

    executables = report["executables"]
    if not isinstance(executables, list):
        _fail("installed network executable authority must be an array")
    expected_hashes = {"app": candidate.application.executable_sha256}
    expected_hashes.update(
        {item.identity_id: item.sha256 for item in candidate.application.embedded_executables}
    )
    if set(expected_hashes) != _INSTALLED_NETWORK_ROLES:
        _fail("candidate does not carry the closed app/four-XPC executable vocabulary")
    observed_roles: set[str] = set()
    globally_seen_processes: set[tuple[int, int]] = set()
    globally_seen_pids: set[int] = set()
    expected_paths = {"app": "/Applications/MacScope.app/Contents/MacOS/MacScope"}
    expected_paths.update({
        role: f"/Applications/MacScope.app/Contents/XPCServices/{name}.xpc/Contents/MacOS/{name}"
        for role, name in MANDATORY_EXECUTABLE_NAMES.items()
    })
    for item in executables:
        executable = _closed_mapping(
            item,
            frozenset({"identity_id", "executable_path", "executable_sha256", "processes"}),
            label="installed network executable",
        )
        role = executable["identity_id"]
        if role not in _INSTALLED_NETWORK_ROLES or role in observed_roles:
            _fail("installed network executable roles must be exact and unique")
        observed_roles.add(role)
        if executable["executable_sha256"] != expected_hashes[role]:
            _fail(f"installed network executable hash differs for role {role}")
        if executable["executable_path"] != expected_paths[role]:
            _fail(f"installed network executable path differs from governed installed role {role}")
        processes = executable["processes"]
        if not isinstance(processes, list):
            _fail(f"installed network processes must be an array for role {role}")
        seen_processes: set[tuple[int, int]] = set()
        for process in processes:
            process_record = _closed_mapping(
                process,
                frozenset({"pid", "start_time_unix_us"}),
                label=f"installed network process for {role}",
            )
            pid = _nonnegative_integer(process_record["pid"], label=f"PID for {role}")
            started = _nonnegative_integer(
                process_record["start_time_unix_us"], label=f"process start for {role}"
            )
            if pid == 0 or (pid, started) in seen_processes:
                _fail(f"installed network process identity is invalid or duplicated for {role}")
            if (pid, started) in globally_seen_processes or pid in globally_seen_pids:
                _fail("installed network process identities must be globally unique across roles")
            seen_processes.add((pid, started))
            globally_seen_processes.add((pid, started))
            globally_seen_pids.add(pid)
    if observed_roles != _INSTALLED_NETWORK_ROLES:
        _fail("installed network observation omitted a mandatory app/XPC role")

    observer = _closed_mapping(
        report["observer"],
        frozenset(
            {
                "observer_id", "tool_path", "tool_sha256", "interface_scope",
                "loopback_excluded", "observed_sample_count",
                "observed_process_row_count", "availability", "observer_invocation_count",
                "continuous_interval_started_at_unix_ms",
                "continuous_interval_ready_at_unix_ms",
                "continuous_interval_ended_at_unix_ms", "continuity_proven",
                "readiness_frame_sha256", "readiness_proven",
                "stopped_by_auditor",
                "observation_byte_count",
                "observation_sha256",
                "observed_candidate_row_count", "observed_foreign_row_count",
                "observed_unresolved_row_count", "evidence_scope", "limitations",
            }
        ),
        label="installed network observer",
    )
    sample_count = _nonnegative_integer(
        observer["observed_sample_count"], label="installed network sample count"
    )
    process_row_count = _nonnegative_integer(
        observer["observed_process_row_count"], label="installed network process row count"
    )
    candidate_row_count = _nonnegative_integer(observer["observed_candidate_row_count"], label="candidate row count")
    foreign_row_count = _nonnegative_integer(observer["observed_foreign_row_count"], label="foreign row count")
    unresolved_row_count = _nonnegative_integer(observer["observed_unresolved_row_count"], label="unresolved row count")
    observer_invocation_count = _nonnegative_integer(
        observer["observer_invocation_count"],
        label="installed network observer invocation count",
    )
    interval_started = _nonnegative_integer(
        observer["continuous_interval_started_at_unix_ms"],
        label="installed network continuous interval start",
    )
    interval_ended = _nonnegative_integer(
        observer["continuous_interval_ended_at_unix_ms"],
        label="installed network continuous interval end",
    )
    interval_ready = _nonnegative_integer(
        observer["continuous_interval_ready_at_unix_ms"],
        label="installed network continuous interval readiness",
    )
    observation_byte_count = _nonnegative_integer(
        observer["observation_byte_count"],
        label="installed network observation byte count",
    )
    observation_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "/InstalledNetworkAcquisition.nettop.csv"),
        kind=ArtifactKind.LAUNCH_LOG,
        media_type="text/csv",
    )
    observation_bytes = _artifact_bytes(artifact_root, observation_artifact)
    if (
        observation_byte_count != len(observation_bytes)
        or observer["observation_sha256"] != hashlib.sha256(observation_bytes).hexdigest()
        or observer["observation_sha256"] != observation_artifact.get("sha256")
    ):
        _fail("installed network report counters are not bound to the exact CSV bytes")
    observed_summary = _replay_installed_network_attribution(
        report["attribution"], observation_bytes,
        candidate_paths=frozenset(expected_paths.values()),
        candidate_pids=frozenset(globally_seen_pids),
    )
    if (
        observed_summary.sample_count != sample_count
        or observed_summary.process_row_count != process_row_count
        or observed_summary.candidate_row_count != candidate_row_count
        or observed_summary.foreign_row_count != foreign_row_count
        or observed_summary.unresolved_row_count != unresolved_row_count
    ):
        _fail("installed network report counters differ from the exact CSV rows")
    if (
        observer["observer_id"] != MATRIX_OBSERVER_ID
        or observer["evidence_scope"] != MATRIX_EVIDENCE_SCOPE
        or observer["limitations"] != list(MATRIX_LIMITATIONS)
        or observer["availability"] != "available"
        or observer["interface_scope"] != ["external", "undefined"]
        or observer["loopback_excluded"] is not True
        or not isinstance(observer["tool_path"], str)
        or not observer["tool_path"].startswith("/")
        or not is_sha256(observer["tool_sha256"])
        or sample_count <= 0
        or candidate_row_count != 0
        or unresolved_row_count != 0
        or process_row_count != candidate_row_count + foreign_row_count + unresolved_row_count
        or observer_invocation_count != 1
        or observer["continuity_proven"] is not True
        or observer["readiness_proven"] is not True
        or observer["stopped_by_auditor"] is not True
        or not is_sha256(observer["readiness_frame_sha256"])
        or interval_ready != observer_ready
        or not (interval_started <= interval_ready <= interval_ended)
        or interval_ready > workload_started
        or interval_started > workload_started
        or interval_ended < workload_ended
    ):
        _fail("installed network observer did not prove available candidate-free sampled network state")
    report_started = _nonnegative_integer(
        report["started_at_unix_ms"], label="installed network report start"
    )
    report_ended = _nonnegative_integer(
        report["ended_at_unix_ms"], label="installed network report end"
    )
    if not (report_started <= workload_started < workload_ended <= report_ended):
        _fail("installed network report timing does not enclose the matrix workload")
    if report["artifacts"] != []:
        _fail("installed network report artifact field must remain closed and empty")
    if (
        result is not EvidenceStatus.PASSED
        or report["result"] != EvidenceStatus.PASSED.value
        or report["exit_code"] != 0
        or report["diagnostic"] is not None
    ):
        _fail("installed Task 10/network workflow did not produce a closed passed result")


def validate_t10c_current_source_artifacts(
    *,
    admitted_external_semantics: Mapping[str, Any] | None = None,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    template = _template(
        command_id,
        EvidenceLayer.INDEPENDENT_REVIEW,
        execution_mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
    )
    if command_id != _T10C_COMMAND_ID:
        _fail("T10C current-source evidence used another governed command")
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    source_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "SOURCE_DRIFT.json"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    adjudication_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "FINDING_ADJUDICATION.json"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    ledger_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "bundle.sha256"),
        kind=ArtifactKind.JSON,
        media_type="text/plain",
    )
    review_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "current-source-independent-review.json"),
        kind=ArtifactKind.REVIEW_REPORT,
        media_type="application/json",
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "current-source-review-execution-report.json"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("T10C execution-report artifact ID differs from the governed output")

    raw_adjudication = _decode_t10c_newline_canonical_json_artifact(artifact_root, adjudication_artifact)
    if isinstance(raw_adjudication, Mapping) and raw_adjudication.get("schemaVersion") == 2:
        if (not isinstance(admitted_external_semantics, Mapping)
                or set(admitted_external_semantics) != {"t10c_closure_admission", "t10c_closure_semantics"}):
            _fail("T10C v2 requires independently retained closure admission")
        from .t10c_closure_adapter import T10CClosureAdmission, T10CClosureSemantics, validate_t10c_closure
        admission = admitted_external_semantics["t10c_closure_admission"]
        semantics = admitted_external_semantics["t10c_closure_semantics"]
        if (not isinstance(admission, T10CClosureAdmission)
                or not isinstance(semantics, T10CClosureSemantics)
                or admission.execution.candidate != candidate
                or admitted_command_record is None or admitted_command_inputs is None
                or admission.execution.integrated_plan_input.inputs != admitted_command_inputs
                or admission.profile is not campaign_profile_for_inputs(admitted_command_inputs)):
            _fail("T10C v2 closure context differs from independently admitted source/profile")
        expected_files = ((source_artifact, "SOURCE_DRIFT.json"),
                          (adjudication_artifact, "FINDING_ADJUDICATION.json"),
                          (ledger_artifact, "bundle.sha256"),
                          (review_artifact, "current-source-independent-review.json"),
                          (execution_artifact, "current-source-review-execution-report.json"))
        for artifact, filename in expected_files:
            if artifact_root / artifact["relative_path"] != admission.current_bundle_root / filename:
                _fail("T10C v2 physical output differs from independently admitted bundle")
            _artifact_bytes(artifact_root, artifact)
        try:
            fresh = validate_t10c_closure(admission)
        except (ValueError, TypeError, AttributeError, KeyError, OSError, RuntimeError) as error:
            _fail(f"T10C v2 physical closure is invalid: {error}")
        if (fresh != semantics or raw_adjudication != fresh.adjudication
                or _decode_t10c_newline_canonical_json_artifact(artifact_root, source_artifact) != fresh.source_drift
                or _decode_canonical_json_artifact(artifact_root, review_artifact) != fresh.review
                or _decode_canonical_json_artifact(artifact_root, execution_artifact) != fresh.execution_report
                or authority != fresh.authority or result is not EvidenceStatus.PASSED):
            _fail("T10C v2 receipt differs from freshly validated installed closure")
        return
    if admitted_external_semantics is not None:
        _fail("T10C closure semantics cannot reinterpret historical or unknown schema")

    source_drift = _validate_t10c_source_drift(
        _decode_t10c_newline_canonical_json_artifact(
            artifact_root, source_artifact
        ),
        candidate=candidate,
    )
    adjudication = _validate_t10c_adjudication(
        _decode_t10c_newline_canonical_json_artifact(
            artifact_root, adjudication_artifact
        ),
        source_drift=source_drift,
    )
    ledger_bytes = _artifact_bytes(artifact_root, ledger_artifact)
    ledger = _parse_t10c_bundle_ledger(ledger_bytes)
    if (
        ledger["SOURCE_DRIFT.json"] != source_artifact.get("sha256")
        or ledger["FINDING_ADJUDICATION.json"] != adjudication_artifact.get("sha256")
    ):
        _fail("T10C bundle ledger does not bind the exact physical source and adjudication")

    review = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, review_artifact),
        _T10C_REVIEW_FIELDS,
        label="T10C independent current-source review",
    )
    reviewer_id = review.get("reviewer_id")
    mutations = review.get("mutations")
    expected_mutation_ids = [f"T10C-M{index:02d}" for index in range(1, 25)]
    if not isinstance(mutations, list) or len(mutations) != 24:
        _fail("T10C independent review must carry the exact 24-mutation ledger")
    observed_mutation_ids: list[str] = []
    for index, item in enumerate(mutations):
        mutation = _closed_mapping(
            item, _T10C_MUTATION_FIELDS, label=f"T10C review mutation[{index}]"
        )
        observed_mutation_ids.append(str(mutation.get("mutation_id")))
        if mutation.get("caught") is not True:
            _fail("T10C independent review contains an uncaught mutation")
    expected_authority = {
        "review_commit": candidate.source.commit,
        "review_tree": candidate.source.tree,
        "p0_count": 0,
        "p1_count": 2,
        "p2_count": 1,
        "p3_count": 0,
        "unresolved_blocking_count": 3,
    }
    review_authority = _closed_mapping(
        review.get("authority"),
        _T10C_REVIEW_AUTHORITY_FIELDS,
        label="T10C independent review authority",
    )
    if (
        review.get("schema_version") != 1
        or review.get("report_kind") != "t10c-current-source-independent-review"
        or not isinstance(reviewer_id, str)
        or re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", reviewer_id) is None
        or not is_integer(review.get("observed_at_unix_ms"))
        or review.get("observed_at_unix_ms", -1) < 0
        or review.get("candidate_commit") != candidate.source.commit
        or review.get("candidate_tree") != candidate.source.tree
        or review.get("dirty_input_paths") != []
        or review.get("source_drift_sha256") != source_artifact.get("sha256")
        or review.get("finding_adjudication_sha256")
        != adjudication_artifact.get("sha256")
        or review.get("bundle_ledger_sha256") != ledger_artifact.get("sha256")
        or review.get("bundle_manifest_sha256")
        != _t10c_bundle_manifest_sha256(ledger)
        or review.get("bundle_file_count") != len(_T10C_BUNDLE_FILES)
        or review.get("finding_count") != len(_T10C_FINDING_IDS)
        or review.get("fixed_count") != 15
        or review.get("evidence_gap_count") != 3
        or review.get("obsolete_count") != 0
        or review.get("gap_ids") != list(_T10C_EVIDENCE_GAP_IDS)
        or review.get("mutation_count") != 24
        or review.get("mutation_caught_count") != 24
        or observed_mutation_ids != expected_mutation_ids
        or review_authority != expected_authority
        or authority != expected_authority
        or review.get("result") != EvidenceStatus.PASSED.value
        or review.get("exit_code") != 0
        or review.get("diagnostic") is not None
    ):
        _fail("T10C independent review is not exactly bound to physical current-source authority")

    execution = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, execution_artifact),
        _EXECUTION_REPORT_V2_FIELDS,
        label="T10C execution report",
    )
    if (
        execution.get("schema_version") != 2
        or not is_integer(execution.get("started_at_unix_ms"))
        or not is_integer(execution.get("ended_at_unix_ms"))
        or execution.get("started_at_unix_ms", -1) < 0
        or execution.get("ended_at_unix_ms", -1)
        < execution.get("started_at_unix_ms", 0)
        or execution.get("result") != EvidenceStatus.FAILED.value
        or execution.get("exit_code") != 1
        or execution.get("stress") is not None
        # The executor itself passed, but the exact current-source review found
        # three still-open Gate F evidence blockers.  The receipt must remain
        # failed until the installed evidence closes them.
        or result is not EvidenceStatus.FAILED
    ):
        _fail("T10C execution report must fail closed around the three review blockers")

    # Keep the physical documents independently closed even when an executor
    # attempts to rebind favorable summary counts around different bytes.
    if (
        adjudication["outcomeCounts"]["already-fixed-on-current-source"] != 15
        or adjudication["outcomeCounts"]["confirmed-current-evidence-gap"] != 3
        or adjudication["outcomeCounts"]["obsolete-after-source-change"] != 0
    ):
        _fail("T10C physical adjudication counts drifted during validation")


def validate_independent_review_lens_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    constituents: object,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
    command_plan_sha256: str,
    command_record_sha256: str,
    prerequisite_receipts: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Authenticate one frozen review lens under its own executor command."""

    template = _template(
        command_id,
        EvidenceLayer.INDEPENDENT_REVIEW,
        execution_mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
    )
    lens_id = INDEPENDENT_REVIEW_COMMAND_LENSES.get(command_id)
    if lens_id is None:
        _fail("independent-review lens evidence used another governed command")
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    if not isinstance(constituents, list) or len(constituents) != 1:
        _fail("independent review lens must carry exactly one frozen constituent")

    candidate_digest = candidate_identity_sha256(candidate)
    expected_topics = dict(_INDEPENDENT_REVIEW_LENSES)
    report_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, f"{lens_id}-review-report.json"),
        kind=ArtifactKind.REVIEW_REPORT,
        media_type="application/json",
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, f"{lens_id}-review-execution-report.json"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("independent-review execution report differs from governed output")
    execution = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, execution_artifact),
        _EXECUTION_REPORT_V2_FIELDS,
        label="independent-review execution report",
    )
    if (
        execution.get("schema_version") != 2
        or not is_integer(execution.get("started_at_unix_ms"))
        or not is_integer(execution.get("ended_at_unix_ms"))
        or execution.get("started_at_unix_ms", -1) < 0
        or execution.get("ended_at_unix_ms", -1)
        < execution.get("started_at_unix_ms", 0)
        or execution.get("result") != EvidenceStatus.PASSED.value
        or execution.get("exit_code") != 0
        or execution.get("stress") is not None
        or result is not EvidenceStatus.PASSED
    ):
        _fail("independent-review execution report is not a closed passed terminal result")

    counts = {severity: 0 for severity in _INDEPENDENT_REVIEW_SEVERITIES}
    constituent = constituents[0]
    if not isinstance(constituent, Mapping) or constituent.get("selector_id") != lens_id:
        _fail("independent-review constituent does not select its frozen lens")

    for artifact in (report_artifact,):
        report = _closed_mapping(
            _decode_canonical_json_artifact(artifact_root, artifact),
            _INDEPENDENT_REVIEW_REPORT_FIELDS,
            label=f"independent-review report {lens_id}",
        )
        if (
            report.get("schema_version") != 1
            or report.get("report_kind") != "independent-review-lens-report"
            or report.get("lens_id") != lens_id
            or not is_integer(report.get("observed_at_unix_ms"))
            or report.get("observed_at_unix_ms", -1) < 0
            or report.get("candidate_commit") != candidate.source.commit
            or report.get("candidate_tree") != candidate.source.tree
            or report.get("candidate_identity_sha256") != candidate_digest
            or report.get("command_id") != command_id
            or report.get("command_plan_sha256") != command_plan_sha256
            or report.get("command_record_sha256") != command_record_sha256
            or not is_sha256(report.get("governed_diff_sha256"))
            or report.get("scope_topics") != list(expected_topics[lens_id])
            or report.get("result") != EvidenceStatus.PASSED.value
            or report.get("exit_code") != 0
            or report.get("diagnostic") is not None
        ):
            _fail("independent-review report is not exactly bound to its frozen lens and candidate")
        prerequisites = report.get("prerequisite_receipts")
        if not isinstance(prerequisites, list):
            _fail("independent-review report prerequisite receipt list is invalid")
        parsed_prerequisites: list[dict[str, Any]] = []
        for index, item in enumerate(prerequisites):
            prerequisite = _closed_mapping(
                item,
                _INDEPENDENT_REVIEW_PREREQUISITE_FIELDS,
                label=f"independent-review {lens_id} prerequisite[{index}]",
            )
            if (
                not isinstance(prerequisite.get("command_id"), str)
                or not isinstance(prerequisite.get("receipt_id"), str)
                or not is_sha256(prerequisite.get("canonical_sha256"))
            ):
                _fail("independent-review report prerequisite receipt is malformed")
            parsed_prerequisites.append(dict(prerequisite))
        if parsed_prerequisites != sorted(
            parsed_prerequisites, key=lambda item: item["command_id"]
        ) or len({item["command_id"] for item in parsed_prerequisites}) != len(
            parsed_prerequisites
        ):
            _fail("independent-review prerequisite receipt list is not unique and sorted")
        if tuple(item["command_id"] for item in parsed_prerequisites) != tuple(
            sorted(COMMAND_PREREQUISITES[command_id])
        ):
            _fail("independent-review prerequisite receipt list does not cover the governed command closure")
        if parsed_prerequisites != [dict(item) for item in prerequisite_receipts]:
            _fail("independent-review prerequisite receipts differ from enclosing command authority")
        if report.get("prerequisite_receipts_sha256") != canonical_sha256(
            parsed_prerequisites
        ):
            _fail("independent-review prerequisite receipt digest differs from its exact list")
        findings = report.get("findings")
        if not isinstance(findings, list):
            _fail("independent-review findings must be an array")
        report_counts = {severity: 0 for severity in _INDEPENDENT_REVIEW_SEVERITIES}
        finding_ids: set[str] = set()
        for index, item in enumerate(findings):
            finding = _closed_mapping(
                item,
                _INDEPENDENT_REVIEW_FINDING_FIELDS,
                label=f"independent-review {lens_id} finding[{index}]",
            )
            finding_id = finding.get("finding_id")
            severity = finding.get("severity")
            state = finding.get("state")
            if (
                not isinstance(finding_id, str)
                or re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", finding_id) is None
                or finding_id in finding_ids
                or severity not in _INDEPENDENT_REVIEW_SEVERITIES
                or state not in _INDEPENDENT_REVIEW_STATES
            ):
                _fail("independent-review finding is not a closed unique severity record")
            finding_ids.add(finding_id)
            if state == "open":
                report_counts[severity] += 1
        if (
            any(report.get(f"{severity.lower()}_count") != report_counts[severity]
                for severity in _INDEPENDENT_REVIEW_SEVERITIES)
            or report.get("unresolved_blocking_count")
            != report_counts["P0"] + report_counts["P1"] + report_counts["P2"]
            or any(report_counts[severity] for severity in ("P0", "P1", "P2"))
        ):
            _fail("passed independent-review lens hides or miscounts an open P0/P1/P2 finding")
        for severity, count in report_counts.items():
            counts[severity] += count
        if (
            constituent.get("status") != "passed"
            or constituent.get("candidate_identity_sha256") != candidate_digest
            or constituent.get("evidence_layer") != EvidenceLayer.INDEPENDENT_REVIEW.value
            or constituent.get("artifact_ids") != [artifact.get("artifact_id")]
        ):
            _fail("independent-review constituent is not exactly cross-bound to its report artifact")

    derived_authority = {
        "review_commit": candidate.source.commit,
        "review_tree": candidate.source.tree,
        "p0_count": counts["P0"],
        "p1_count": counts["P1"],
        "p2_count": counts["P2"],
        "p3_count": counts["P3"],
        "unresolved_blocking_count": counts["P0"] + counts["P1"] + counts["P2"],
    }
    if authority != derived_authority:
        _fail("independent-review lens authority differs from its physical report")
    return derived_authority


def validate_independent_review_aggregate_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    constituents: object,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
    prerequisite_receipts: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    """Aggregate four separately sealed, exact-candidate-bound lens approvals.

    ``reviewer_id`` is retained in the legacy lens-report envelope but is a
    caller-authored label, not an authenticated principal.  The independence
    claim is instead the four immutable lens commands and their separate,
    candidate-bound approval receipts.
    """

    template = _template(
        command_id,
        EvidenceLayer.INDEPENDENT_REVIEW,
        execution_mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
    )
    if command_id != _INDEPENDENT_REVIEW_COMMAND_ID:
        _fail("independent-review aggregate used another governed command")
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    execution_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "independent-review-execution-report.json"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("independent-review aggregate execution report differs from governed output")
    execution = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, execution_artifact),
        _EXECUTION_REPORT_V2_FIELDS,
        label="independent-review aggregate execution report",
    )
    if (
        execution.get("schema_version") != 2
        or not is_integer(execution.get("started_at_unix_ms"))
        or not is_integer(execution.get("ended_at_unix_ms"))
        or execution.get("started_at_unix_ms", -1) < 0
        or execution.get("ended_at_unix_ms", -1)
        < execution.get("started_at_unix_ms", 0)
        or execution.get("result") != EvidenceStatus.PASSED.value
        or execution.get("exit_code") != 0
        or execution.get("stress") is not None
        or result is not EvidenceStatus.PASSED
    ):
        _fail("independent-review aggregate is not a closed passed terminal result")

    expected_commands = tuple(INDEPENDENT_REVIEW_COMMAND_LENSES)
    prerequisite_by_command = {
        item.get("command_id"): item
        for item in prerequisite_receipts
        if isinstance(item, Mapping)
    }
    if (
        tuple(sorted(prerequisite_by_command)) != expected_commands
        or len(prerequisite_by_command) != len(prerequisite_receipts)
    ):
        _fail("independent-review aggregate prerequisites do not cover four lens commands")
    if not isinstance(constituents, list) or len(constituents) != len(expected_commands):
        _fail("independent-review aggregate must carry four receipt constituents")
    constituent_by_command = {
        item.get("selector_id"): item
        for item in constituents
        if isinstance(item, Mapping)
    }
    if (
        tuple(sorted(constituent_by_command)) != expected_commands
        or len(constituent_by_command) != len(constituents)
    ):
        _fail("independent-review aggregate constituents do not cover four lens commands")

    candidate_digest = candidate_identity_sha256(candidate)
    counts = {severity: 0 for severity in _INDEPENDENT_REVIEW_SEVERITIES}
    approval_receipt_ids: set[str] = set()
    approval_receipt_sha256s: set[str] = set()
    approval_artifact_sha256s: set[str] = set()
    for lens_command_id, lens_id in INDEPENDENT_REVIEW_COMMAND_LENSES.items():
        artifact = _artifact_for_output(
            artifacts,
            _generated_output(template, f"{lens_id}-review-receipt.json"),
            kind=ArtifactKind.REVIEW_REPORT,
            media_type="application/json",
        )
        receipt = _closed_mapping(
            _decode_canonical_json_artifact(artifact_root, artifact),
            RECEIPT_FIELDS,
            label=f"independent-review lens receipt {lens_id}",
        )
        prerequisite = prerequisite_by_command[lens_command_id]
        receipt_authority = _closed_mapping(
            receipt.get("authority"),
            _INDEPENDENT_REVIEW_RECEIPT_AUTHORITY_FIELDS,
            label=f"independent-review lens receipt authority {lens_id}",
        )
        if (
            receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION
            or receipt.get("receipt_type") != ReceiptType.INDEPENDENT_REVIEW.value
            or receipt.get("evidence_layer") != EvidenceLayer.INDEPENDENT_REVIEW.value
            or receipt.get("evidence_status") != EvidenceStatus.PASSED.value
            or receipt.get("candidate_identity") != candidate_to_mapping(candidate)
            or receipt.get("candidate_identity_sha256") != candidate_digest
            or receipt.get("command_id") != lens_command_id
            or receipt.get("receipt_id") != prerequisite.get("receipt_id")
            or receipt.get("canonical_sha256") != prerequisite.get("canonical_sha256")
            or receipt.get("qualification_run")
            != {
                "run_id": prerequisite.get("qualification_run_id"),
                "nonce": prerequisite.get("qualification_run_nonce"),
            }
            or receipt.get("canonical_sha256") != canonical_sha256(receipt_payload(receipt))
            or receipt_authority.get("review_commit") != candidate.source.commit
            or receipt_authority.get("review_tree") != candidate.source.tree
        ):
            _fail("independent-review aggregate lens receipt is not exact candidate authority")
        approval_receipt_ids.add(receipt["receipt_id"])
        approval_receipt_sha256s.add(receipt["canonical_sha256"])
        artifact_sha256 = artifact.get("sha256")
        if not is_sha256(artifact_sha256):
            _fail("independent-review aggregate approval artifact has no canonical digest")
        approval_artifact_sha256s.add(artifact_sha256)
        for severity in _INDEPENDENT_REVIEW_SEVERITIES:
            value = receipt_authority.get(f"{severity.lower()}_count")
            if not is_integer(value) or value < 0:
                _fail("independent-review aggregate lens receipt count is invalid")
            counts[severity] += value
        if (
            receipt_authority.get("unresolved_blocking_count")
            != receipt_authority.get("p0_count")
            + receipt_authority.get("p1_count")
            + receipt_authority.get("p2_count")
            or receipt_authority.get("unresolved_blocking_count") != 0
        ):
            _fail("independent-review aggregate lens receipt carries blocking findings")
        constituent = constituent_by_command[lens_command_id]
        if (
            constituent.get("status") != SelectorStatus.PASSED.value
            or constituent.get("candidate_identity_sha256") != candidate_digest
            or constituent.get("evidence_layer") != EvidenceLayer.INDEPENDENT_REVIEW.value
            or constituent.get("artifact_ids") != [artifact.get("artifact_id")]
        ):
            _fail("independent-review aggregate constituent differs from its exact lens receipt")

    if (
        len(approval_receipt_ids) != len(INDEPENDENT_REVIEW_COMMAND_LENSES)
        or len(approval_receipt_sha256s) != len(INDEPENDENT_REVIEW_COMMAND_LENSES)
        or len(approval_artifact_sha256s) != len(INDEPENDENT_REVIEW_COMMAND_LENSES)
    ):
        _fail(
            "independent-review aggregate requires four separately sealed exact-candidate lens approval artifacts"
        )

    derived_authority = {
        "review_commit": candidate.source.commit,
        "review_tree": candidate.source.tree,
        "p0_count": counts["P0"],
        "p1_count": counts["P1"],
        "p2_count": counts["P2"],
        "p3_count": counts["P3"],
        "unresolved_blocking_count": counts["P0"] + counts["P1"] + counts["P2"],
    }
    if authority != derived_authority:
        _fail("independent-review aggregate authority differs from exact lens receipts")
    return derived_authority


def validate_deterministic_evidence_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    constituents: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> None:
    """Derive the deterministic-evidence pass from its physical comparison."""

    template = _template(command_id, EvidenceLayer.XCODE_FOCUSED, admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
    if command_id != _DETERMINISTIC_EVIDENCE_COMMAND_ID:
        _fail("deterministic evidence used another governed command")
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    execution = _artifact_for_output(
        artifacts,
        _generated_output(template, "EXECUTION_REPORT"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if execution.get("artifact_id") != execution_report_artifact_id:
        _fail("deterministic execution report differs from the governed output")
    if result is not EvidenceStatus.PASSED:
        _fail("deterministic evidence requires a passed terminal execution report")

    selector = _selector_from_governed_command(template)
    for suffix in ("TEST_RESULTS_ONE", "TEST_RESULTS_TWO"):
        test_results = _artifact_for_output(
            artifacts,
            _generated_output(template, suffix),
            kind=ArtifactKind.TEST_RESULTS,
            media_type="application/json",
        )
        _validate_exact_passed_test_result(
            _decode_json_artifact(artifact_root, test_results), selector
        )

    comparison_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "COMPARISON"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    comparison = _closed_mapping(
        _decode_canonical_json_artifact(artifact_root, comparison_artifact),
        _DETERMINISTIC_COMPARISON_FIELDS,
        label="deterministic evidence comparison",
    )
    candidate_digest = candidate_identity_sha256(candidate)
    if (
        comparison.get("schema_version") != 1
        or comparison.get("command_id") != command_id
        or comparison.get("candidate_identity_sha256") != candidate_digest
        or comparison.get("fresh_process_count") != 2
    ):
        _fail("deterministic comparison does not prove two fresh processes for this candidate")
    rows = comparison.get("artifacts")
    if not isinstance(rows, list) or len(rows) != len(
        _DETERMINISTIC_EVIDENCE_ARTIFACTS
    ):
        _fail("deterministic comparison must carry the exact artifact closure")
    for index, (artifact_id, relative_path, first_suffix, second_suffix) in enumerate(
        _DETERMINISTIC_EVIDENCE_ARTIFACTS
    ):
        row = _closed_mapping(
            rows[index],
            _DETERMINISTIC_COMPARISON_ROW_FIELDS,
            label=f"deterministic comparison artifact[{index}]",
        )
        first_physical = _artifact_for_output(
            artifacts,
            _generated_output(template, first_suffix),
            kind=ArtifactKind.JSON,
            media_type="application/json",
        )
        second_physical = _artifact_for_output(
            artifacts,
            _generated_output(template, second_suffix),
            kind=ArtifactKind.JSON,
            media_type="application/json",
        )
        if (
            row.get("artifact_id") != artifact_id
            or row.get("relative_path") != relative_path
            or first_physical.get("artifact_id") == second_physical.get("artifact_id")
            or first_physical.get("relative_path") == second_physical.get("relative_path")
            or row.get("byte_count") != first_physical.get("byte_count")
            or row.get("byte_count") != second_physical.get("byte_count")
            or row.get("sha256") != first_physical.get("sha256")
            or row.get("sha256") != second_physical.get("sha256")
        ):
            _fail(
                "deterministic comparison differs from either fresh process's exact physical artifacts"
            )
    # The governed two-run physical proof covers the catalogued semantic
    # requirements; scenario multiplicity does not imply additional runs.
    expected_scenarios = (
        admitted_command_record.scenario_ids or (command_id,)
        if admitted_command_record is not None else (command_id,)
    )
    if not isinstance(constituents, list) or len(constituents) != len(expected_scenarios):
        _fail("deterministic evidence constituent is not bound to the complete physical proof")
    if (
        any(not isinstance(item, Mapping) for item in constituents)
        or {item.get("selector_id") for item in constituents} != set(expected_scenarios)
        or any(
            item.get("status") != SelectorStatus.PASSED.value
            or item.get("candidate_identity_sha256") != candidate_digest
            or set(item.get("artifact_ids", ())) != {artifact.get("artifact_id") for artifact in artifacts}
            for item in constituents
        )
    ):
        _fail("deterministic evidence constituent is not bound to the complete physical proof")


def validate_prospective_merge_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> dict[str, Any]:
    template = _template(
        command_id,
        EvidenceLayer.PROSPECTIVE_MERGE_TREE,
        execution_mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
    )
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    observation_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "prospective-merge-observation"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    diff_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "prospective-governed-diff"),
        kind=ArtifactKind.MERGE_PROOF,
        media_type="application/json",
    )
    authority_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "prospective-merge-authority"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    report_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "prospective-merge-execution-report"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if report_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("prospective execution-report artifact ID differs from the governed output")
    report = _decode_canonical_json_artifact(artifact_root, report_artifact)
    if not isinstance(report, Mapping) or report.get("result") != EvidenceStatus.PASSED.value:
        _fail("prospective merge execution report is not passed")
    try:
        derived = validate_prospective_evidence(
            candidate,
            _decode_canonical_json_artifact(artifact_root, observation_artifact),
            _decode_canonical_json_artifact(artifact_root, diff_artifact),
        )
    except MergeAuthorityEvidenceError as error:
        _fail(f"prospective merge physical evidence is invalid: {error}")
    recorded = _decode_canonical_json_artifact(artifact_root, authority_artifact)
    if recorded != derived:
        _fail("prospective merge authority differs from its physical evidence")
    if authority is not None and authority != derived:
        _fail("supplied prospective merge authority differs from physical evidence")
    if result is not EvidenceStatus.PASSED:
        _fail("prospective merge physical evidence cannot support a non-passed result")
    return derived


def validate_postmerge_artifacts(
    *,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
) -> dict[str, Any]:
    template = _template(
        command_id,
        EvidenceLayer.POST_MERGE,
        execution_mode=CommandExecutionMode.EXECUTOR_REQUIRED,
        admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
    )
    _validate_command_outputs(
        template,
        artifacts=artifacts,
        generated_artifacts=generated_artifacts,
        generated_logs=generated_logs,
    )
    observation_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "postmerge-observation"),
        kind=ArtifactKind.MERGE_PROOF,
        media_type="application/json",
    )
    workflow_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "postmerge-workflow"),
        kind=ArtifactKind.TEST_RESULTS,
        media_type="application/json",
    )
    authority_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "postmerge-authority"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    report_artifact = _artifact_for_output(
        artifacts,
        _generated_output(template, "postmerge-execution-report"),
        kind=ArtifactKind.JSON,
        media_type="application/json",
    )
    if report_artifact.get("artifact_id") != execution_report_artifact_id:
        _fail("postmerge execution-report artifact ID differs from the governed output")
    report = _decode_canonical_json_artifact(artifact_root, report_artifact)
    if not isinstance(report, Mapping) or report.get("result") != EvidenceStatus.PASSED.value:
        _fail("postmerge execution report is not passed")
    try:
        derived = validate_postmerge_evidence(
            candidate,
            _decode_canonical_json_artifact(artifact_root, observation_artifact),
            _decode_canonical_json_artifact(artifact_root, workflow_artifact),
        )
    except MergeAuthorityEvidenceError as error:
        _fail(f"postmerge physical evidence is invalid: {error}")
    recorded = _decode_canonical_json_artifact(artifact_root, authority_artifact)
    if recorded != derived:
        _fail("postmerge authority differs from its physical evidence")
    if authority is not None and authority != derived:
        _fail("supplied postmerge authority differs from physical evidence")
    if result is not EvidenceStatus.PASSED:
        _fail("postmerge physical evidence cannot support a non-passed result")
    return derived


def validate_gate_specific_artifacts(
    *,
    admitted_capture_semantics: Mapping[str, Any] | None = None,
    admitted_external_semantics: Mapping[str, Any] | None = None,
    admitted_command_record: CommandRecord | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    receipt_type: ReceiptType,
    candidate: CandidateIdentity,
    command_id: str,
    artifacts: Sequence[Mapping[str, Any]],
    artifact_root: Path,
    execution_report_artifact_id: str,
    result: EvidenceStatus,
    stress: Mapping[str, Any] | None,
    constituents: object,
    authority: object,
    generated_artifacts: Sequence[str],
    generated_logs: Sequence[str],
    command_plan_sha256: str,
    command_record_sha256: str,
    prerequisite_receipts: Sequence[Mapping[str, Any]],
) -> dict[str, Any] | None:
    if admitted_command_record is not None and (
        not isinstance(admitted_command_record, CommandRecord)
        or admitted_command_record.command_id != command_id
        or admitted_command_record.candidate_identity_sha256 != candidate_identity_sha256(candidate)
    ):
        _fail("admitted command record belongs to another command or candidate")
    try:
        selected_profile = campaign_profile_for_inputs(admitted_command_inputs or {})
        templates = command_templates(profile=selected_profile)
    except (TypeError, ValueError) as error:
        _fail(f"invalid independently admitted compiler profile: {error}")
    from .executor_request_adapter import (
        CAPTURE_DERIVED_REPORT_COMMANDS, CAPTURE_EXECUTION_REPORT_OUTPUT,
        capture_derived_report_policy,
    )
    if (admitted_command_record is None) != (admitted_command_inputs is None):
        _fail("resolved output admission requires record and independently admitted inputs")
    if admitted_command_inputs is not None:
        try:
            admitted_command_inputs = _validate_input_mapping(admitted_command_inputs, templates, candidate,
                profile=campaign_profile_for_inputs(admitted_command_inputs))
        except (KeyError, TypeError, ValueError) as error:
            _fail(f"invalid independently admitted compiler inputs: {error}")
    signed_xpc_command_ids = {
        item.command_id
        for item in templates
        if item.evidence_layer is EvidenceLayer.SIGNED_XPC
    }
    handled_execution_commands = {
        _T10C_COMMAND_ID,
        _INDEPENDENT_REVIEW_COMMAND_ID,
        _DETERMINISTIC_EVIDENCE_COMMAND_ID,
        "install.release-to-applications",
        "installed.accessibility-semantics",
        "installed.task10-workflow",
        "merge.prospective-tree",
        "postmerge.exact-tree-proof",
        "stress.reconstruction-authority-races",
        "source.hosted-governance",
        *INDEPENDENT_REVIEW_COMMAND_LENSES,
        *signed_xpc_command_ids,
        *CAPTURE_DERIVED_REPORT_COMMANDS,
        *(item.command_id for item in templates if capture_derived_report_policy(item.command_id, profile=selected_profile)),
        "qualification.verify-bootstrap-fullsuite",
        "qualification.verify-bootstrap-products",
    }
    catalog_execution_commands = {
        item.command_id
        for item in templates
        if item.execution_mode is not CommandExecutionMode.VECTOR_ONLY
    }
    if (
        catalog_execution_commands - handled_execution_commands
        != _UNVALIDATED_EXECUTION_COMMAND_IDS
    ):
        _fail("gate-specific semantic-validator backlog differs from the command catalog")
    if command_id in {"qualification.verify-bootstrap-fullsuite", "qualification.verify-bootstrap-products"}:
        from .bootstrap_verifier_adapter import validate_bootstrap_verifier_outputs
        from .executor_request_adapter import ExecutorReceiptAdmission
        from .command_execution import AdmittedCommand
        if admitted_command_record is None or admitted_command_inputs is None or admitted_capture_semantics is None:
            _fail("bootstrap verifier requires independently admitted command and physical capture context")
        admission = admitted_capture_semantics.get("bootstrap_verifier_admission")
        admitted = admitted_capture_semantics.get("bootstrap_verifier_admitted_command")
        streams = admitted_capture_semantics.get("bootstrap_verifier_streams")
        if (not isinstance(admission, ExecutorReceiptAdmission) or not isinstance(admitted, AdmittedCommand)
                or admitted.resolved_command.record != admitted_command_record or admission.artifact_root != artifact_root
                or admission.execution_report_artifact_id != execution_report_artifact_id
                or admission.receipt_type is not receipt_type
                or admission.capture.admission.candidate != candidate
                or _validate_input_mapping(admission.capture.admission.integrated_plan_input.inputs, templates, candidate,
                    profile=campaign_profile_for_inputs(admission.capture.admission.integrated_plan_input.inputs)) != dict(admitted_command_inputs)
                or not isinstance(streams, Mapping)):
            _fail("bootstrap verifier physical context differs from admitted receipt authority")
        template = _template(command_id, admitted_command_record.evidence_layer,
                             admitted_command_record=admitted_command_record,
                             admitted_command_inputs=admitted_command_inputs)
        _validate_command_outputs(template,
            artifacts=[item for item in artifacts if item.get("command_output") != "log:gatef-command-capture"],
            generated_artifacts=generated_artifacts, generated_logs=generated_logs)
        for source in admission.owner_artifacts:
            artifact = _artifact_for_output(artifacts, source.command_output,
                                            kind=source.kind, media_type=source.media_type)
            if artifact.get("artifact_id") != source.artifact_id or artifact.get("relative_path") != source.relative_path:
                _fail("bootstrap verifier artifact differs from its admitted owner record")
            _artifact_bytes(artifact_root, artifact)
        try:
            derived_authority, derived_constituents = validate_bootstrap_verifier_outputs(admission, admitted, streams)
        except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
            _fail(f"bootstrap verifier physical evidence is invalid: {error}")
        if (canonical_sha256(authority) != canonical_sha256(derived_authority)
                or canonical_sha256(constituents) != canonical_sha256(derived_constituents)
                or result is not EvidenceStatus.PASSED or stress is not None):
            _fail("bootstrap verifier receipt differs from fresh physical authority and constituents")
        return derived_authority
    from .executor_request_adapter import native_producer_policy, installed_producer_policy
    if (native_producer_policy(command_id, profile=selected_profile)
            or installed_producer_policy(command_id, profile=selected_profile)):
        installed = installed_producer_policy(command_id, profile=selected_profile)
        if installed:
            from .installed_capture_adapter import validate_installed_outputs, installed_semantic_kind
            validate_outputs = validate_installed_outputs
            semantic_kind = lambda cid, source: installed_semantic_kind(cid, source, inputs=admitted_command_inputs)
            context_prefix = "installed_producer"
        else:
            from .native_receipt_adapter import validate_native_outputs, native_semantic_kind
            validate_outputs = validate_native_outputs
            semantic_kind = native_semantic_kind
            context_prefix = "native_producer"
        from .executor_request_adapter import ExecutorReceiptAdmission
        from .command_execution import AdmittedCommand
        if admitted_command_record is None or admitted_command_inputs is None or admitted_capture_semantics is None:
            _fail("native owner requires independent command and physical capture context")
        admission = admitted_capture_semantics.get(context_prefix + "_admission")
        admitted = admitted_capture_semantics.get(context_prefix + "_admitted_command")
        if (not isinstance(admission, ExecutorReceiptAdmission) or not isinstance(admitted, AdmittedCommand)
                or admitted.resolved_command.record != admitted_command_record
                or admission.artifact_root != artifact_root
                or admission.execution_report_artifact_id != execution_report_artifact_id
                or admission.receipt_type is not receipt_type
                or admission.capture.admission.candidate != candidate
                or _validate_input_mapping(admission.capture.admission.integrated_plan_input.inputs, templates, candidate,
                    profile=campaign_profile_for_inputs(admission.capture.admission.integrated_plan_input.inputs))
                    != dict(admitted_command_inputs)):
            _fail("native physical context differs from admitted receipt authority")
        template = _template(command_id, admitted_command_record.evidence_layer,
            admitted_command_record=admitted_command_record, admitted_command_inputs=admitted_command_inputs)
        reports = [a for a in artifacts if a.get("command_output") == CAPTURE_EXECUTION_REPORT_OUTPUT]
        if len(reports) != 1 or reports[0].get("artifact_id") != execution_report_artifact_id:
            _fail("native owner requires its one capture-derived execution report")
        _validate_command_outputs(template,
            artifacts=[a for a in artifacts if a.get("command_output") not in
                {CAPTURE_EXECUTION_REPORT_OUTPUT, "log:gatef-command-capture"}],
            generated_artifacts=generated_artifacts, generated_logs=generated_logs)
        for source in admission.owner_artifacts:
            artifact = _artifact_for_output(artifacts, source.command_output,
                kind=semantic_kind(command_id, source), media_type=source.media_type)
            if artifact.get("artifact_id") != source.artifact_id or artifact.get("relative_path") != source.relative_path:
                _fail("native artifact differs from independently retained owner identity")
            _artifact_bytes(artifact_root, artifact)
        try:
            semantics = validate_outputs(admission)
        except (AttributeError, KeyError, TypeError, ValueError, OSError, RuntimeError) as error:
            _fail(f"native physical evidence is invalid: {error}")
        if (canonical_sha256(authority) != canonical_sha256(semantics["authority"])
                or canonical_sha256(constituents) != canonical_sha256(semantics["constituents"])
                or result is not EvidenceStatus.PASSED or stress is not None):
            _fail("native receipt differs from fresh physical outcomes")
        return semantics["authority"]
    if capture_derived_report_policy(command_id, profile=selected_profile):
        from .executor_request_adapter import capture_derived_report_receipt_type
        if receipt_type not in {ReceiptType.COMMAND_EXECUTION, capture_derived_report_receipt_type(command_id, profile=selected_profile)}:
            _fail("capture-derived execution cannot substitute for semantic qualification")
        if admitted_command_record is None or admitted_command_inputs is None:
            _fail("capture-derived execution requires independently admitted command authority")
        template = _template(command_id, admitted_command_record.evidence_layer,
                             admitted_command_record=admitted_command_record,
                             admitted_command_inputs=admitted_command_inputs)
        reports = [item for item in artifacts if item.get("command_output") == CAPTURE_EXECUTION_REPORT_OUTPUT]
        if len(reports) != 1 or reports[0].get("artifact_id") != execution_report_artifact_id:
            _fail("capture-derived execution requires exactly its reserved report")
        _validate_command_outputs(template,
            artifacts=[item for item in artifacts if item.get("command_output") != CAPTURE_EXECUTION_REPORT_OUTPUT],
            generated_artifacts=generated_artifacts, generated_logs=generated_logs)
        if receipt_type is ReceiptType.ARTIFACT_MANIFEST:
            from .qualification_artifact_validator import validate_source_export
            validate_source_export(candidate, Path(admitted_command_inputs["source_export_root"]),
                                   admitted_command_inputs["integration_ref"])
        elif receipt_type is not ReceiptType.COMMAND_EXECUTION:
            # Only the capture adapter supplies this after physically verifying
            # the source-bound qualifier and original result/app directory.
            # Public repeated admission regenerates this proof, never reads it
            # from the request or receipt being validated.
            if (admitted_capture_semantics is None
                    or admitted_capture_semantics.get("authority") != authority
                    or admitted_capture_semantics.get("constituents") != constituents):
                _fail("semantic qualification receipt requires its independent physical proof adapter")
        return None
    if (
        receipt_type is ReceiptType.INDEPENDENT_REVIEW
        and command_id == _T10C_COMMAND_ID
    ):
        validate_t10c_current_source_artifacts(
            admitted_external_semantics=admitted_external_semantics,
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if (
        receipt_type is ReceiptType.TEST_RESULT
        and command_id == _DETERMINISTIC_EVIDENCE_COMMAND_ID
    ):
        validate_deterministic_evidence_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            constituents=constituents,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if (
        receipt_type is ReceiptType.TEST_RESULT
        and command_id == "source.hosted-governance"
    ):
        validate_hosted_governance_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if (
        receipt_type is ReceiptType.INDEPENDENT_REVIEW
        and command_id == _INDEPENDENT_REVIEW_COMMAND_ID
    ):
        return validate_independent_review_aggregate_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            constituents=constituents,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
            prerequisite_receipts=prerequisite_receipts,
        )
    if (
        receipt_type is ReceiptType.INDEPENDENT_REVIEW
        and command_id in INDEPENDENT_REVIEW_COMMAND_LENSES
    ):
        return validate_independent_review_lens_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            constituents=constituents,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
            command_plan_sha256=command_plan_sha256,
            command_record_sha256=command_record_sha256,
            prerequisite_receipts=prerequisite_receipts,
        )
    if receipt_type is ReceiptType.SIGNED_XPC:
        validate_signed_xpc_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if receipt_type is ReceiptType.STRESS_RECOVERY:
        if stress is None:
            _fail("stress-recovery receipt omitted its execution stress record")
        return validate_stress_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            stress=stress,
            constituents=constituents,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
    if (
        receipt_type is ReceiptType.INSTALLED_SOURCE_EQUALITY
        and command_id == "install.release-to-applications"
    ):
        validate_install_release_to_applications_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if (
        receipt_type is ReceiptType.INSTALLED_ACCESSIBILITY
        and command_id == "installed.accessibility-semantics"
    ):
        validate_installed_accessibility_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if receipt_type is ReceiptType.INSTALLED_WORKFLOW:
        validate_installed_task10_workflow_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
        return None
    if receipt_type is ReceiptType.PROSPECTIVE_MERGE_TREE:
        return validate_prospective_merge_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
    if receipt_type is ReceiptType.POST_MERGE:
        return validate_postmerge_artifacts(
            candidate=candidate,
            admitted_command_record=admitted_command_record,
        admitted_command_inputs=admitted_command_inputs,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_report_artifact_id,
            result=result,
            authority=authority,
            generated_artifacts=generated_artifacts,
            generated_logs=generated_logs,
        )
    if (
        result is EvidenceStatus.PASSED
        and command_id in _UNVALIDATED_EXECUTION_COMMAND_IDS
    ):
        _fail(
            f"passed execution-bearing command {command_id!r} has no gate-specific semantic validator"
        )
    return None
