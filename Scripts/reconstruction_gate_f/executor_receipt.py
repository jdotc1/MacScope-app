"""Emit validated Gate F receipts from executor-owned physical evidence.

Terminal timing and result data originate in one canonical JSON artifact.
This module descriptor-validates those bytes, carries their exact interval into
the universal receipt, and then repeats artifact validation before sealing.  It
never accepts caller-authored timing or an aggregate success Boolean that is
not checked against the exact constituents and physical artifacts.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .artifact_validator import (
    read_descriptor_relative_bytes,
    safe_relative_artifact_path,
    validate_artifact_records,
)
from .canonical_json import (
    CanonicalJSONError,
    canonical_sha256,
    decode_canonical_bytes,
    load_canonical_json,
    write_canonical_json,
)
from .gate_specific_artifact_validator import (
    GateSpecificArtifactError,
    validate_gate_specific_artifacts,
)
from .receipt_schema import (
    ARTIFACT_FIELDS,
    COMMAND_AUTHORITY_FIELDS,
    COMMAND_PREREQUISITE_FIELDS,
    EXECUTOR_FIELDS,
    MAX_DIAGNOSTIC_UTF8_BYTES,
    QUALIFICATION_RUN_FIELDS,
    RECEIPT_SCHEMA_VERSION,
    seal_receipt,
)
from .receipt_validator import (
    ArtifactExpectation,
    CommandAuthorityExpectation,
    CommandPrerequisiteExpectation,
    ExecutionIntervalExpectation,
    ReceiptValidationContext,
    QualificationRunAuthority,
    qualification_run_mapping,
    _validate_physical_receipt,
)
from .schema import (
    ArtifactKind,
    EvidenceLayer,
    EvidenceStatus,
    QualificationPhase,
    ReceiptType,
    STABLE_ID_RE,
    candidate_identity_sha256,
    candidate_to_mapping,
    closed_record,
    enum_value,
    is_integer,
    is_sha256,
    parse_candidate_identity,
)

EXECUTOR_RECEIPT_REQUEST_SCHEMA_VERSION = 4
LEGACY_PHYSICAL_REQUEST_SCHEMA_VERSION = 2
EXECUTION_REPORT_SCHEMA_VERSION = 2

LEGACY_PHYSICAL_REQUEST_FIELDS = frozenset(
    {
        "schema_version",
        "candidate_identity",
        "qualification_run",
        "qualification_phase",
        "evidence_layer",
        "receipt_type",
        "receipt_id",
        "requirement_id",
        "command_id",
        "scenario_id",
        "command_plan_sha256",
        "command_record_sha256",
        "qualified_premerge_authority_sha256",
        "attempt",
        "artifact_root_id",
        "execution_report_artifact_id",
        "executor",
        "command_authority",
        "artifacts",
        "constituents",
        "skips",
        "diagnostic",
        "authority",
    }
)
REQUEST_FIELDS = LEGACY_PHYSICAL_REQUEST_FIELDS | {"runtime_resolution"}
EXECUTION_REPORT_FIELDS = frozenset(
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
STRESS_FIELDS = frozenset(
    {
        "expected_attempt_count",
        "observed_attempt_count",
        "attempt_seeds",
        "failed_count",
    }
)
TERMINAL_RESULTS = frozenset(
    {EvidenceStatus.PASSED, EvidenceStatus.FAILED, EvidenceStatus.UNAVAILABLE}
)


class ReceiptEmissionError(ValueError):
    """A bounded executor input cannot produce an authoritative receipt."""


def _fail(message: str) -> None:
    raise ReceiptEmissionError(message)


def _require_closed(value: object, fields: frozenset[str], *, path: str) -> Mapping[str, Any]:
    record, issues = closed_record(value, fields, path=path)
    if record is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        _fail(detail or f"{path}: invalid closed record")
    return record


def _require_stable_id(value: object, *, path: str) -> str:
    if not isinstance(value, str) or STABLE_ID_RE.fullmatch(value) is None:
        _fail(f"{path}: must be a canonical lowercase stable ID")
    return value


def _require_sha256(value: object, *, path: str) -> str:
    if not is_sha256(value):
        _fail(f"{path}: must be a lowercase 64-hex SHA-256")
    return value


def _parse_qualification_run(value: object, *, path: str) -> QualificationRunAuthority:
    record = _require_closed(value, QUALIFICATION_RUN_FIELDS, path=path)
    return QualificationRunAuthority(
        run_id=_require_stable_id(record["run_id"], path=f"{path}.run_id"),
        nonce=_require_sha256(record["nonce"], path=f"{path}.nonce"),
    )


def _parse_enum(enum_type: type, value: object, *, path: str) -> Any:
    parsed, issues = enum_value(enum_type, value, path=path)
    if parsed is None or issues:
        _fail(f"{path}: value is outside the closed {enum_type.__name__} vocabulary")
    return parsed


def _parse_command_authority(
    value: object,
    *,
    expected_qualification_run: QualificationRunAuthority,
) -> CommandAuthorityExpectation:
    record = _require_closed(value, COMMAND_AUTHORITY_FIELDS, path="$.command_authority")
    host = _require_stable_id(record["host"], path="$.command_authority.host")
    execution_mode = _require_stable_id(
        record["execution_mode"], path="$.command_authority.execution_mode"
    )
    argv_sha256 = _require_sha256(
        record["argv_sha256"], path="$.command_authority.argv_sha256"
    )
    working_directory_sha256 = _require_sha256(
        record["working_directory_sha256"],
        path="$.command_authority.working_directory_sha256",
    )
    environment_sha256 = _require_sha256(
        record["environment_sha256"], path="$.command_authority.environment_sha256"
    )

    outputs: dict[str, tuple[str, ...]] = {}
    for field in ("generated_artifacts", "generated_logs"):
        values = record[field]
        if (
            not isinstance(values, list)
            or not all(isinstance(item, str) and item for item in values)
            or values != sorted(set(values))
        ):
            _fail(
                f"$.command_authority.{field}: must be unique sorted nonempty strings"
            )
        outputs[field] = tuple(values)

    prerequisite_values = record["prerequisite_receipts"]
    if not isinstance(prerequisite_values, list):
        _fail("$.command_authority.prerequisite_receipts: must be an array")
    prerequisites: list[CommandPrerequisiteExpectation] = []
    for index, item in enumerate(prerequisite_values):
        path = f"$.command_authority.prerequisite_receipts[{index}]"
        prerequisite = _require_closed(item, COMMAND_PREREQUISITE_FIELDS, path=path)
        qualification_run_id = _require_stable_id(
            prerequisite["qualification_run_id"],
            path=f"{path}.qualification_run_id",
        )
        qualification_run_nonce = _require_sha256(
            prerequisite["qualification_run_nonce"],
            path=f"{path}.qualification_run_nonce",
        )
        if (
            qualification_run_id != expected_qualification_run.run_id
            or qualification_run_nonce != expected_qualification_run.nonce
        ):
            _fail(
                f"{path}: prerequisite belongs to another coordinator-issued qualification run"
            )
        prerequisites.append(
            CommandPrerequisiteExpectation(
                command_id=_require_stable_id(
                    prerequisite["command_id"], path=f"{path}.command_id"
                ),
                receipt_id=_require_stable_id(
                    prerequisite["receipt_id"], path=f"{path}.receipt_id"
                ),
                canonical_sha256=_require_sha256(
                    prerequisite["canonical_sha256"], path=f"{path}.canonical_sha256"
                ),
                qualification_run_id=qualification_run_id,
                qualification_run_nonce=qualification_run_nonce,
            )
        )
    if prerequisites != sorted(prerequisites) or len(
        {item.command_id for item in prerequisites}
    ) != len(prerequisites):
        _fail(
            "$.command_authority.prerequisite_receipts: command IDs must be unique and sorted"
        )
    return CommandAuthorityExpectation(
        host=host,
        execution_mode=execution_mode,
        argv_sha256=argv_sha256,
        working_directory_sha256=working_directory_sha256,
        environment_sha256=environment_sha256,
        generated_artifacts=outputs["generated_artifacts"],
        generated_logs=outputs["generated_logs"],
        prerequisite_receipts=tuple(prerequisites),
    )


def _command_authority_mapping(value: CommandAuthorityExpectation) -> dict[str, Any]:
    return {
        "host": value.host,
        "execution_mode": value.execution_mode,
        "argv_sha256": value.argv_sha256,
        "working_directory_sha256": value.working_directory_sha256,
        "environment_sha256": value.environment_sha256,
        "generated_artifacts": list(value.generated_artifacts),
        "generated_logs": list(value.generated_logs),
        "prerequisite_receipts": [
            {
                "command_id": item.command_id,
                "receipt_id": item.receipt_id,
                "canonical_sha256": item.canonical_sha256,
                "qualification_run_id": item.qualification_run_id,
                "qualification_run_nonce": item.qualification_run_nonce,
            }
            for item in value.prerequisite_receipts
        ],
    }


def _parse_artifact_expectations(value: object) -> tuple[ArtifactExpectation, ...]:
    if not isinstance(value, list) or not value:
        _fail("$.artifacts: must be a nonempty artifact descriptor array")
    expectations: list[ArtifactExpectation] = []
    for index, item in enumerate(value):
        path = f"$.artifacts[{index}]"
        record = _require_closed(item, ARTIFACT_FIELDS, path=path)
        if not safe_relative_artifact_path(record["relative_path"]):
            _fail(f"{path}.relative_path: must be a safe relative POSIX path")
        expectations.append(
            ArtifactExpectation(
                artifact_id=_require_stable_id(
                    record["artifact_id"], path=f"{path}.artifact_id"
                ),
                relative_path=record["relative_path"],
                kind=_parse_enum(ArtifactKind, record["kind"], path=f"{path}.kind"),
                media_type=record["media_type"],
                command_output=record["command_output"],
            )
        )
    return tuple(expectations)


def _parse_execution_report(
    value: object,
    *,
    receipt_type: ReceiptType,
    expected_qualification_run: QualificationRunAuthority,
    expected_predecessor_observations_sha256: str,
) -> tuple[EvidenceStatus, dict[str, Any] | None, ExecutionIntervalExpectation]:
    report = _require_closed(value, EXECUTION_REPORT_FIELDS, path="$.execution_report")
    if report["schema_version"] != EXECUTION_REPORT_SCHEMA_VERSION:
        _fail("$.execution_report.schema_version: unsupported execution report schema")
    observed_run = _parse_qualification_run(
        report["qualification_run"], path="$.execution_report.qualification_run"
    )
    if observed_run != expected_qualification_run:
        _fail("$.execution_report.qualification_run: differs from coordinator authority")
    observed_predecessors = _require_sha256(
        report["predecessor_observations_sha256"],
        path="$.execution_report.predecessor_observations_sha256",
    )
    if observed_predecessors != expected_predecessor_observations_sha256:
        _fail(
            "$.execution_report.predecessor_observations_sha256: differs from the pre-launch descriptor"
        )
    started = report["started_at_unix_ms"]
    ended = report["ended_at_unix_ms"]
    if not is_integer(started) or started < 0:
        _fail("$.execution_report.started_at_unix_ms: must be a nonnegative integer")
    if not is_integer(ended) or ended < started:
        _fail("$.execution_report.ended_at_unix_ms: must not precede start")
    result = _parse_enum(EvidenceStatus, report["result"], path="$.execution_report.result")
    if result not in TERMINAL_RESULTS:
        _fail("$.execution_report.result: executor result must be terminal")
    exit_code = report["exit_code"]
    if result is EvidenceStatus.UNAVAILABLE:
        if exit_code is not None:
            _fail("$.execution_report.exit_code: unavailable result requires null")
    elif not is_integer(exit_code):
        _fail("$.execution_report.exit_code: terminal execution requires an integer")
    elif result is EvidenceStatus.PASSED and exit_code != 0:
        _fail("$.execution_report.exit_code: a passed execution requires exit code 0")
    elif result is EvidenceStatus.FAILED and exit_code == 0:
        _fail("$.execution_report.exit_code: a failed execution requires a nonzero exit code")

    stress_value = report["stress"]
    interval = ExecutionIntervalExpectation(
        started_at_unix_ms=started,
        ended_at_unix_ms=ended,
    )
    if receipt_type is not ReceiptType.STRESS_RECOVERY:
        if stress_value is not None:
            _fail("$.execution_report.stress: only stress-recovery receipts carry stress metadata")
        return result, None, interval
    stress = _require_closed(stress_value, STRESS_FIELDS, path="$.execution_report.stress")
    seeds = stress["attempt_seeds"]
    if (
        not isinstance(seeds, list)
        or not all(is_integer(seed) and seed >= 0 for seed in seeds)
        or len(seeds) != len(set(seeds))
    ):
        _fail("$.execution_report.stress.attempt_seeds: must be unique nonnegative integers")
    for field in ("expected_attempt_count", "observed_attempt_count", "failed_count"):
        if not is_integer(stress[field]) or stress[field] < 0:
            _fail(f"$.execution_report.stress.{field}: must be a nonnegative integer")
    if stress["expected_attempt_count"] != len(seeds):
        _fail("$.execution_report.stress.expected_attempt_count: differs from exact seeds")
    return result, dict(stress), interval


def _load_execution_report(
    artifact_root: Path,
    artifacts: list[Mapping[str, Any]],
    execution_report_artifact_id: str,
    *,
    receipt_type: ReceiptType,
    expected_qualification_run: QualificationRunAuthority,
    expected_predecessor_observations_sha256: str,
) -> tuple[EvidenceStatus, dict[str, Any] | None, ExecutionIntervalExpectation]:
    matches = [
        item for item in artifacts if item.get("artifact_id") == execution_report_artifact_id
    ]
    if len(matches) != 1:
        _fail(
            "$.execution_report_artifact_id: must select exactly one declared artifact"
        )
    artifact = matches[0]
    relative_path = artifact.get("relative_path")
    if not safe_relative_artifact_path(relative_path):
        _fail("$.execution_report_artifact_id: selected artifact path is unsafe")
    try:
        payload, size, digest = read_descriptor_relative_bytes(
            artifact_root,
            str(relative_path),
        )
    except OSError as error:
        _fail(f"$.execution_report: descriptor-relative read failed: {error}")
    if size != artifact.get("byte_count") or digest != artifact.get("sha256"):
        _fail("$.execution_report: descriptor bytes differ from declared artifact identity")
    try:
        report = decode_canonical_bytes(payload)
    except CanonicalJSONError as error:
        _fail(f"$.execution_report: {error}")
    result = _parse_execution_report(
        report,
        receipt_type=receipt_type,
        expected_qualification_run=expected_qualification_run,
        expected_predecessor_observations_sha256=(
            expected_predecessor_observations_sha256
        ),
    )
    return result


def _validate_legacy_physical_evidence(
    request: object,
    *,
    artifact_root: Path,
    qualification_run_authority: QualificationRunAuthority,
    admitted_command_record: object | None = None,
    admitted_command_inputs: Mapping[str, str] | None = None,
    capture_derived_execution: bool = False,
    admitted_capture_semantics: Mapping[str, Any] | None = None,
    admitted_external_semantics: Mapping[str, Any] | None = None,
) -> tuple[dict[str, Any], ReceiptValidationContext]:
    """Private physical report implementation, not public receipt acceptance.

    ``artifact_root`` must already exist as a canonical absolute directory.  No
    artifact is created, followed through a symlink, or accepted by filename
    alone. Public acceptance additionally requires independent capture admission.
    The absent command context is retained only for physical regression fixtures.
    """

    record = _require_closed(request, LEGACY_PHYSICAL_REQUEST_FIELDS, path="$")
    if record["schema_version"] != LEGACY_PHYSICAL_REQUEST_SCHEMA_VERSION:
        _fail("$.schema_version: unsupported executor receipt request schema")
    if not isinstance(qualification_run_authority, QualificationRunAuthority):
        _fail("qualification run authority must be supplied by the coordinator")
    request_run = _parse_qualification_run(
        record["qualification_run"], path="$.qualification_run"
    )
    if request_run != qualification_run_authority:
        _fail("$.qualification_run: differs from coordinator authority")
    if not artifact_root.is_absolute() or artifact_root.resolve(strict=True) != artifact_root:
        _fail("artifact root must be an existing canonical absolute path")
    if not artifact_root.is_dir() or artifact_root.is_symlink():
        _fail("artifact root must be an ordinary directory, not a symlink")

    candidate, candidate_issues = parse_candidate_identity(
        record["candidate_identity"], path="$.candidate_identity"
    )
    if candidate is None or candidate_issues:
        _fail(
            "; ".join(
                f"{issue.code} {issue.path}: {issue.message}"
                for issue in candidate_issues
            )
        )
    phase = _parse_enum(
        QualificationPhase, record["qualification_phase"], path="$.qualification_phase"
    )
    layer = _parse_enum(EvidenceLayer, record["evidence_layer"], path="$.evidence_layer")
    receipt_type = _parse_enum(
        ReceiptType, record["receipt_type"], path="$.receipt_type"
    )
    receipt_id = _require_stable_id(record["receipt_id"], path="$.receipt_id")
    requirement_id = _require_stable_id(
        record["requirement_id"], path="$.requirement_id"
    )
    command_id = _require_stable_id(record["command_id"], path="$.command_id")
    scenario_id = _require_stable_id(record["scenario_id"], path="$.scenario_id")
    command_plan_sha256 = _require_sha256(
        record["command_plan_sha256"], path="$.command_plan_sha256"
    )
    command_record_sha256 = _require_sha256(
        record["command_record_sha256"], path="$.command_record_sha256"
    )
    qualified_premerge = record["qualified_premerge_authority_sha256"]
    if qualified_premerge is not None:
        qualified_premerge = _require_sha256(
            qualified_premerge, path="$.qualified_premerge_authority_sha256"
        )
    attempt = record["attempt"]
    if not is_integer(attempt) or attempt < 1:
        _fail("$.attempt: must be a positive integer")
    artifact_root_id = _require_stable_id(
        record["artifact_root_id"], path="$.artifact_root_id"
    )
    execution_artifact_id = _require_stable_id(
        record["execution_report_artifact_id"],
        path="$.execution_report_artifact_id",
    )
    executor = _require_closed(record["executor"], EXECUTOR_FIELDS, path="$.executor")
    expected_executor_id = _require_stable_id(
        executor["executor_id"], path="$.executor.executor_id"
    )
    command_authority = _parse_command_authority(
        record["command_authority"],
        expected_qualification_run=qualification_run_authority,
    )
    predecessor_observations_sha256 = canonical_sha256(
        _command_authority_mapping(command_authority)["prerequisite_receipts"]
    )
    expectations = _parse_artifact_expectations(record["artifacts"])
    artifacts = [dict(item) for item in record["artifacts"]]

    candidate_digest = candidate_identity_sha256(candidate)
    artifact_issues = validate_artifact_records(
        artifacts,
        expected_candidate_sha256=candidate_digest,
        expected_layer=layer,
        expected_root_id=artifact_root_id,
        expected_receipt_id=receipt_id,
        expected_command_id=command_id,
        root=artifact_root,
    )
    if artifact_issues:
        _fail(
            "; ".join(
                f"{issue.code} {issue.path}: {issue.message}"
                for issue in artifact_issues
            )
        )
    result, stress, execution_interval = _load_execution_report(
        artifact_root,
        artifacts,
        execution_artifact_id,
        receipt_type=receipt_type,
        expected_qualification_run=qualification_run_authority,
        expected_predecessor_observations_sha256=predecessor_observations_sha256,
    )
    try:
        derived_gate_authority = validate_gate_specific_artifacts(
            admitted_capture_semantics=admitted_capture_semantics,
            admitted_external_semantics=admitted_external_semantics,
            admitted_command_record=admitted_command_record,
            admitted_command_inputs=admitted_command_inputs,
            receipt_type=receipt_type,
            candidate=candidate,
            command_id=command_id,
            artifacts=artifacts,
            artifact_root=artifact_root,
            execution_report_artifact_id=execution_artifact_id,
            result=result,
            stress=stress,
            constituents=record["constituents"],
            authority=record["authority"],
            generated_artifacts=command_authority.generated_artifacts,
            generated_logs=command_authority.generated_logs,
            command_plan_sha256=command_plan_sha256,
            command_record_sha256=command_record_sha256,
            prerequisite_receipts=tuple(
                {
                    "command_id": item.command_id,
                    "receipt_id": item.receipt_id,
                    "canonical_sha256": item.canonical_sha256,
                    "qualification_run_id": item.qualification_run_id,
                    "qualification_run_nonce": item.qualification_run_nonce,
                }
                for item in command_authority.prerequisite_receipts
            ),
        )
    except GateSpecificArtifactError as error:
        _fail(str(error))
    # Close the check/use interval for the execution report and every other
    # artifact before any favorable receipt can be sealed.
    repeated_artifact_issues = validate_artifact_records(
        artifacts,
        expected_candidate_sha256=candidate_digest,
        expected_layer=layer,
        expected_root_id=artifact_root_id,
        expected_receipt_id=receipt_id,
        expected_command_id=command_id,
        root=artifact_root,
    )
    if repeated_artifact_issues:
        _fail("artifact changed while execution authority was being loaded")

    authority = record["authority"]
    physically_derived_receipts = {
        ReceiptType.STRESS_RECOVERY,
        ReceiptType.PROSPECTIVE_MERGE_TREE,
        ReceiptType.POST_MERGE,
    }
    if receipt_type in physically_derived_receipts:
        if derived_gate_authority is None:
            _fail(f"{receipt_type.value} receipt omitted derived physical authority")
        if authority is not None and authority != derived_gate_authority:
            _fail(
                "$.authority: supplied authority differs from exact physical execution metadata"
            )
        authority = derived_gate_authority
    elif stress is not None:
        _fail("non-stress receipt cannot carry stress metadata")
    elif not isinstance(authority, Mapping):
        _fail("$.authority: specialized receipt authority must be an object")

    diagnostic = record["diagnostic"]
    try:
        diagnostic_size = len(diagnostic.encode("utf-8")) if isinstance(diagnostic, str) else 0
    except UnicodeEncodeError:
        diagnostic_size = MAX_DIAGNOSTIC_UTF8_BYTES + 1
    if diagnostic is not None and (
        not isinstance(diagnostic, str)
        or "\x00" in diagnostic
        or diagnostic_size > MAX_DIAGNOSTIC_UTF8_BYTES
    ):
        _fail("$.diagnostic: must be null or bounded UTF-8 text")

    context = ReceiptValidationContext(
        expected_candidate=candidate,
        expected_qualification_run=qualification_run_authority,
        qualification_phase=phase,
        expected_layer=layer,
        expected_receipt_type=receipt_type,
        expected_receipt_id=receipt_id,
        expected_requirement_id=requirement_id,
        expected_command_id=command_id,
        expected_scenario_id=scenario_id,
        expected_command_plan_sha256=command_plan_sha256,
        expected_command_record_sha256=command_record_sha256,
        expected_command_authority=command_authority,
        expected_qualified_premerge_authority_sha256=qualified_premerge,
        expected_attempt=attempt,
        expected_execution_interval=execution_interval,
        expected_artifact_root_id=artifact_root_id,
        expected_artifacts=expectations,
        artifact_root=artifact_root,
        expected_executor_id=expected_executor_id,
        expected_skips=tuple(record["skips"]) if isinstance(record["skips"], list) else (),
        capture_derived_execution=capture_derived_execution,
    )
    receipt = seal_receipt(
        {
            "schema_version": RECEIPT_SCHEMA_VERSION,
            "receipt_id": receipt_id,
            "receipt_type": receipt_type.value,
            "evidence_layer": layer.value,
            "evidence_status": result.value,
            "qualification_phase": phase.value,
            "qualification_run": qualification_run_mapping(qualification_run_authority),
            "candidate_identity": candidate_to_mapping(candidate),
            "candidate_identity_sha256": candidate_digest,
            "requirement_id": requirement_id,
            "command_id": command_id,
            "scenario_id": scenario_id,
            "command_plan_sha256": command_plan_sha256,
            "command_record_sha256": command_record_sha256,
            "runtime_resolution": None,
            "qualified_premerge_authority_sha256": qualified_premerge,
            "attempt": attempt,
            "execution_interval": {
                "started_at_unix_ms": execution_interval.started_at_unix_ms,
                "ended_at_unix_ms": execution_interval.ended_at_unix_ms,
            },
            "executor": dict(executor),
            "command_authority": _command_authority_mapping(command_authority),
            "artifacts": artifacts,
            "constituents": record["constituents"],
            "skips": record["skips"],
            "diagnostic": diagnostic,
            "authority": dict(authority),
        }
    )
    issues = _validate_physical_receipt(receipt, context=context)
    if issues:
        _fail(
            "; ".join(
                f"{issue.code} {issue.path}: {issue.message}" for issue in issues
            )
        )
    return receipt, context


def emit_executor_receipt(
    request: object,
    *,
    artifact_root: Path,
    qualification_run_authority: QualificationRunAuthority,
    admission: object = None,
) -> tuple[dict[str, Any], ReceiptValidationContext]:
    """Public acceptance requires independently retained producer admission."""
    from .executor_request_adapter import ExecutorReceiptAdmission, emit_captured_receipt

    if not isinstance(admission, ExecutorReceiptAdmission):
        from .external_authority_adapter import ExternalAuthorityAdmission, emit_external_receipt
        if not isinstance(admission, ExternalAuthorityAdmission):
            _fail("receipt emission requires typed independent capture or external admission")
        if (artifact_root != admission.artifact_root
                or qualification_run_authority != admission.execution.qualification_run):
            _fail("receipt root/run differs from independent external admission")
        return emit_external_receipt(request, admission=admission)

    return emit_captured_receipt(
        request, artifact_root=artifact_root,
        qualification_run_authority=qualification_run_authority, admission=admission,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Emit one physically verified, candidate-bound Gate F receipt."
    )
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        request = load_canonical_json(arguments.request)
        receipt, _ = emit_executor_receipt(
            request,
            artifact_root=arguments.artifact_root,
            qualification_run_authority=QualificationRunAuthority(
                run_id=_require_stable_id(
                    arguments.qualification_run_id,
                    path="--qualification-run-id",
                ),
                nonce=_require_sha256(
                    arguments.qualification_run_nonce,
                    path="--qualification-run-nonce",
                ),
            ),
        )
        write_canonical_json(arguments.output, receipt)
    except (CanonicalJSONError, OSError, ReceiptEmissionError) as error:
        print(f"Gate F receipt emission failed: {error}", file=sys.stderr)
        return 1
    print(f"Gate F receipt emitted: {arguments.output}")
    print(f"Gate F receipt SHA-256: {receipt['canonical_sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
