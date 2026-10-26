#!/usr/bin/env python3
"""Project the sealed Task 10 matrix into WS24 incremental-XCUITest input.

This adapter never launches the application or XCUITest.  It accepts only the
artifacts produced by ``run_installed_task10_matrix.py``, authenticates their
physical and qualification authority, and emits the closed raw descriptor
consumed by ``ws24_emit_installed_qualification_report.py``.
"""

from __future__ import annotations

import argparse
import hashlib
import stat
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction import (  # noqa: E402
    audit_installed_network_acquisition as network,
    emit_installed_accessibility_report as accessibility,
    installed_matrix_receipt as matrix,
    network_attribution,
)
from Scripts.reconstruction.write_execution_report import (  # noqa: E402
    ExecutionReportError,
    MAXIMUM_EXECUTION_REPORT_BYTES,
    qualification_run_authority,
    read_stable_regular,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
    qualification_run_mapping,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    candidate_identity_sha256,
    is_sha256,
)
from Scripts import ws24_emit_installed_qualification_report as ws24  # noqa: E402


OUTPUT_NAME = "InstalledTask10.incremental-xcuitest.evidence.json"
MATRIX_RECEIPT_NAME = "InstalledTask10.matrix-receipt.json"
SEMANTIC_MANIFEST_NAME = "InstalledTask10.xcresult-semantic.json"
XCRESULT_NAME = "InstalledTask10.xcresult"
NETWORK_ROOT_NAME = "installed-task10-network"
SEMANTIC_MANIFEST_ARTIFACT_KIND = (
    "installed-task10-xcresult-semantic-manifest-v1"
)
NETWORK_REPORT_ARTIFACT_KIND = "installed-task10-network-audit-report-v1"
NETWORK_EXECUTION_ARTIFACT_KIND = (
    "installed-task10-network-audit-execution-report-v1"
)
NETWORK_OBSERVATION_ARTIFACT_KIND = (
    "installed-task10-network-audit-observation-v1"
)
MAXIMUM_SEMANTIC_MANIFEST_BYTES = 4 * 1024 * 1024
MAXIMUM_NETWORK_REPORT_BYTES = 4 * 1024 * 1024
MAXIMUM_OBSERVER_TOOL_BYTES = 64 * 1024 * 1024
MAXIMUM_OUTPUT_BYTES = 64 * 1024

NETWORK_REPORT_FIELDS = frozenset(
    {
        "artifacts",
        "attribution",
        "candidate",
        "command_id",
        "diagnostic",
        "ended_at_unix_ms",
        "evidence_layer",
        "executables",
        "exit_code",
        "observer",
        "result",
        "schema_version",
        "started_at_unix_ms",
        "workload",
    }
)
NETWORK_CANDIDATE_FIELDS = frozenset(
    {"document_sha256", "identity_sha256", "source_commit", "source_tree"}
)
NETWORK_WORKLOAD_FIELDS = frozenset(
    {
        "command_id",
        "ended_at_unix_ms",
        "executed_selector_count",
        "expected_selector_count",
        "failed_selector_count",
        "matrix_receipt_sha256",
        "matrix_result",
        "observation_contains_workload",
        "observer_readiness_precedes_workload",
        "observer_ready_at_unix_ms",
        "passed_selector_count",
        "selector_catalog_sha256",
        "selector_projection_sha256",
        "skipped_selector_count",
        "started_at_unix_ms",
        "xcresult_bundle_sha256",
        "xcresult_closed_tree_sha256",
        "xcresult_semantic_manifest_sha256",
    }
)
NETWORK_EXECUTABLE_FIELDS = frozenset(
    {"executable_path", "executable_sha256", "identity_id", "processes"}
)
NETWORK_PROCESS_FIELDS = frozenset({"pid", "start_time_unix_us"})
NETWORK_OBSERVER_FIELDS = frozenset(
    {
        "availability",
        "continuity_proven",
        "continuous_interval_ended_at_unix_ms",
        "continuous_interval_ready_at_unix_ms",
        "continuous_interval_started_at_unix_ms",
        "interface_scope",
        "loopback_excluded",
        "observation_byte_count",
        "observation_sha256",
        "observed_process_row_count",
        "observed_candidate_row_count",
        "observed_foreign_row_count",
        "observed_unresolved_row_count",
        "evidence_scope",
        "limitations",
        "observed_sample_count",
        "observer_id",
        "observer_invocation_count",
        "readiness_frame_sha256",
        "readiness_proven",
        "stopped_by_auditor",
        "tool_path",
        "tool_sha256",
    }
)
EXECUTION_REPORT_FIELDS = frozenset(
    {
        "ended_at_unix_ms",
        "exit_code",
        "predecessor_observations_sha256",
        "qualification_run",
        "result",
        "schema_version",
        "started_at_unix_ms",
        "stress",
    }
)


class InstalledIncrementalEvidenceError(ValueError):
    pass


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Authenticate the sealed Task 10 matrix and emit its canonical "
            "WS24 incremental-XCUITest evidence input."
        )
    )
    parser.add_argument("--matrix-receipt", type=Path, required=True)
    parser.add_argument("--xcresult-semantic-manifest", type=Path, required=True)
    parser.add_argument("--network-artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    return parser.parse_args(argv)


def _closed(value: object, fields: frozenset[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping) or set(value) != fields:
        observed = sorted(value) if isinstance(value, Mapping) else type(value).__name__
        raise InstalledIncrementalEvidenceError(
            f"{label} must be a closed object with fields {sorted(fields)}; "
            f"found {observed}"
        )
    return value


def _nonnegative_integer(value: object, label: str) -> int:
    if type(value) is not int or value < 0:
        raise InstalledIncrementalEvidenceError(
            f"{label} must be a nonnegative integer"
        )
    return value


def _canonical_directory(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise InstalledIncrementalEvidenceError(f"{label} must be an absolute path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InstalledIncrementalEvidenceError(f"{label} is unavailable: {error}") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or resolved != path
    ):
        raise InstalledIncrementalEvidenceError(
            f"{label} must be a canonical non-symlink directory"
        )
    return path


def _stable_file(path: Path, *, label: str, maximum_bytes: int):
    if not path.is_absolute():
        raise InstalledIncrementalEvidenceError(f"{label} must be an absolute path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InstalledIncrementalEvidenceError(f"{label} is unavailable: {error}") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or resolved != path
    ):
        raise InstalledIncrementalEvidenceError(
            f"{label} must be a canonical non-symlink regular file"
        )
    try:
        return read_stable_regular(
            path,
            label=label,
            maximum_bytes=maximum_bytes,
            retain_payload=True,
        )
    except ExecutionReportError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error


def _canonical_document(path: Path, *, label: str, maximum_bytes: int):
    source = _stable_file(path, label=label, maximum_bytes=maximum_bytes)
    if source.payload is None:
        raise InstalledIncrementalEvidenceError(
            f"{label} payload was not retained for semantic validation"
        )
    try:
        document = decode_canonical_bytes(source.payload)
    except CanonicalJSONError as error:
        raise InstalledIncrementalEvidenceError(
            f"{label} is not canonical JSON: {error}"
        ) from error
    return document, source


def _validate_execution_report(
    value: object,
    *,
    authority: QualificationRunAuthority,
    predecessor_observations_sha256: str,
) -> Mapping[str, Any]:
    report = _closed(value, EXECUTION_REPORT_FIELDS, "network execution report")
    started = _nonnegative_integer(
        report["started_at_unix_ms"], "network execution start"
    )
    ended = _nonnegative_integer(
        report["ended_at_unix_ms"], "network execution end"
    )
    if (
        report["schema_version"] != 2
        or report["qualification_run"] != qualification_run_mapping(authority)
        or report["predecessor_observations_sha256"]
        != predecessor_observations_sha256
        or report["result"] != "passed"
        or report["exit_code"] != 0
        or report["stress"] is not None
        or ended < started
    ):
        raise InstalledIncrementalEvidenceError(
            "network execution report does not carry the exact passing "
            "qualification-run authority"
        )
    return report


def _validate_network_report(
    value: object,
    *,
    receipt: Mapping[str, Any],
    receipt_sha256: str,
    semantic: Mapping[str, Any],
    semantic_sha256: str,
    xcresult_bundle_sha256: str,
    candidate_document_sha256: str,
    authorities: Sequence[object],
    observation_bytes: bytes,
    observer_tool_sha256: str,
    execution_report: Mapping[str, Any],
) -> None:
    report = _closed(value, NETWORK_REPORT_FIELDS, "installed network report")
    candidate = _closed(
        report["candidate"], NETWORK_CANDIDATE_FIELDS, "installed network candidate"
    )
    sealed_candidate = receipt["candidate"]
    if (
        type(report["schema_version"]) is not int
        or report["schema_version"] != network.MATRIX_REPORT_SCHEMA_VERSION
        or report["command_id"] != "installed.network-acquisition-audit"
        or report["evidence_layer"] != "installed-launch-log"
        or candidate["identity_sha256"] != sealed_candidate["identity_sha256"]
        or candidate["document_sha256"] != candidate_document_sha256
        or candidate["source_commit"] != sealed_candidate["source_commit"]
        or candidate["source_tree"] != sealed_candidate["source_tree"]
    ):
        raise InstalledIncrementalEvidenceError(
            "installed network report belongs to another candidate authority"
        )

    workload = _closed(
        report["workload"], NETWORK_WORKLOAD_FIELDS, "installed network workload"
    )
    workload_started = _nonnegative_integer(
        workload["started_at_unix_ms"], "installed workload start"
    )
    workload_ended = _nonnegative_integer(
        workload["ended_at_unix_ms"], "installed workload end"
    )
    observer_ready = _nonnegative_integer(
        workload["observer_ready_at_unix_ms"], "installed workload observer readiness"
    )
    matrix_execution = receipt["execution"]
    matrix_started = _nonnegative_integer(
        matrix_execution["started_at_unix_ms"], "installed matrix execution start"
    )
    matrix_ended = _nonnegative_integer(
        matrix_execution["ended_at_unix_ms"], "installed matrix execution end"
    )
    try:
        projection = ws24.installed_selector_projection(
            ws24.load_installed_selector_catalog()
        )
    except ws24.ReportError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    selectors = [item["test_identifier"] for item in projection]
    semantic_source = _closed(
        semantic["source_xcresult"],
        frozenset({"bundle_sha256", "closed_tree_sha256"}),
        "xcresult semantic source",
    )
    sealed_xcresult = receipt["products"]["xcresult"]
    if (
        workload["command_id"] != "installed.task10-workflow"
        or workload["observation_contains_workload"] is not True
        or workload["observer_readiness_precedes_workload"] is not True
        or observer_ready > workload_started
        or workload_ended <= workload_started
        or not (
            workload_started
            <= matrix_started
            <= matrix_ended
            <= workload_ended
        )
        or workload["matrix_receipt_sha256"] != receipt_sha256
        or workload["xcresult_semantic_manifest_sha256"] != semantic_sha256
        or workload["xcresult_bundle_sha256"] != xcresult_bundle_sha256
        or workload["xcresult_bundle_sha256"] != semantic_source["bundle_sha256"]
        or workload["xcresult_closed_tree_sha256"]
        != sealed_xcresult["closed_tree_sha256"]
        or workload["xcresult_closed_tree_sha256"]
        != semantic_source["closed_tree_sha256"]
        or workload["selector_catalog_sha256"] != canonical_sha256(selectors)
        or workload["selector_projection_sha256"] != canonical_sha256(projection)
        or workload["selector_projection_sha256"]
        != semantic["selector_projection_sha256"]
        or workload["expected_selector_count"] != 22
        or workload["executed_selector_count"] != 22
        or workload["passed_selector_count"] != 22
        or workload["failed_selector_count"] != 0
        or workload["skipped_selector_count"] != 0
        or workload["matrix_result"] != "passed"
    ):
        raise InstalledIncrementalEvidenceError(
            "installed network workload is not bound to the exact passing "
            "22-selector matrix"
        )

    expected_authorities = {
        getattr(authority, "identity_id"): (
            getattr(authority, "executable_path"),
            getattr(authority, "executable_sha256"),
        )
        for authority in authorities
    }
    raw_executables = report["executables"]
    if not isinstance(raw_executables, list):
        raise InstalledIncrementalEvidenceError(
            "installed network executable authority must be an array"
        )
    observed_authorities: dict[str, tuple[str, str]] = {}
    process_identities: set[tuple[int, int]] = set()
    observed_pids: set[int] = set()
    for index, raw_executable in enumerate(raw_executables):
        executable = _closed(
            raw_executable,
            NETWORK_EXECUTABLE_FIELDS,
            f"installed network executable {index}",
        )
        identity_id = executable["identity_id"]
        if not isinstance(identity_id, str) or identity_id in observed_authorities:
            raise InstalledIncrementalEvidenceError(
                "installed network executable roles must be unique strings"
            )
        observed_authorities[identity_id] = (
            executable["executable_path"],
            executable["executable_sha256"],
        )
        processes = executable["processes"]
        if not isinstance(processes, list):
            raise InstalledIncrementalEvidenceError(
                f"installed network processes for {identity_id} must be an array"
            )
        for process_index, raw_process in enumerate(processes):
            process = _closed(
                raw_process,
                NETWORK_PROCESS_FIELDS,
                f"installed network process {identity_id}[{process_index}]",
            )
            pid = _nonnegative_integer(process["pid"], f"PID for {identity_id}")
            started = _nonnegative_integer(
                process["start_time_unix_us"],
                f"process start for {identity_id}",
            )
            identity = (pid, started)
            if pid == 0 or started == 0 or pid in observed_pids or identity in process_identities:
                raise InstalledIncrementalEvidenceError(
                    "installed network process identities must be positive and globally unique"
                )
            observed_pids.add(pid)
            process_identities.add(identity)
    if observed_authorities != expected_authorities:
        raise InstalledIncrementalEvidenceError(
            "installed network executable authority differs from the installed candidate"
        )
    observer = _closed(
        report["observer"], NETWORK_OBSERVER_FIELDS, "installed network observer"
    )
    sample_count = _nonnegative_integer(
        observer["observed_sample_count"], "installed network sample count"
    )
    process_row_count = _nonnegative_integer(
        observer["observed_process_row_count"], "installed network process row count"
    )
    classified_counts = tuple(
        _nonnegative_integer(observer[key], key)
        for key in ("observed_candidate_row_count", "observed_foreign_row_count",
                    "observed_unresolved_row_count")
    )
    invocation_count = _nonnegative_integer(
        observer["observer_invocation_count"], "installed network observer invocation count"
    )
    interval_started = _nonnegative_integer(
        observer["continuous_interval_started_at_unix_ms"],
        "installed network observer start",
    )
    interval_ready = _nonnegative_integer(
        observer["continuous_interval_ready_at_unix_ms"],
        "installed network observer readiness",
    )
    interval_ended = _nonnegative_integer(
        observer["continuous_interval_ended_at_unix_ms"],
        "installed network observer end",
    )
    observation_byte_count = _nonnegative_integer(
        observer["observation_byte_count"], "installed network observation byte count"
    )
    attribution = _closed(
        report["attribution"],
        frozenset({"policy_id", "observer_spawn_ns", "observer_eof_ns",
                   "queue_closed_ns", "proofs", "drains"}),
        "installed network attribution",
    )
    if attribution["policy_id"] != "prearmed-kqueue-path-v1":
        raise InstalledIncrementalEvidenceError("unknown network attribution policy")
    try:
        foreign_pids = network_attribution.validate_foreign_proofs(
            attribution["proofs"], attribution["drains"],
            observer_spawn_ns=attribution["observer_spawn_ns"],
            observer_eof_ns=attribution["observer_eof_ns"],
            queue_closed_ns=attribution["queue_closed_ns"],
            candidate_paths=tuple(item[0] for item in expected_authorities.values()),
        )
        observed_summary = network.classify_matrix_observation(
            observation_bytes, candidate_pids=frozenset(observed_pids),
            foreign_pids=foreign_pids,
        )
        minimum_frames = network._minimum_continuous_frame_count(
            interval_ready, interval_ended
        )
    except (network.AuditInputError, network_attribution.NetworkAttributionError) as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    observation_sha256 = hashlib.sha256(observation_bytes).hexdigest()
    if (
        observer["observer_id"]
        != network.MATRIX_OBSERVER_ID
        or observer["evidence_scope"] != network.MATRIX_EVIDENCE_SCOPE
        or observer["limitations"] != list(network.MATRIX_LIMITATIONS)
        or observer["availability"] != "available"
        or observer["interface_scope"] != ["external", "undefined"]
        or observer["loopback_excluded"] is not True
        or observer["tool_path"] != str(network.NETTOP_PATH)
        or observer["tool_sha256"] != observer_tool_sha256
        or observer["readiness_frame_sha256"]
        != hashlib.sha256(network.MATRIX_OBSERVER_READY_FRAME).hexdigest()
        or observer["continuity_proven"] is not True
        or observer["readiness_proven"] is not True
        or observer["stopped_by_auditor"] is not True
        or invocation_count != 1
        or sample_count < minimum_frames
        or classified_counts != (
            observed_summary.candidate_row_count, observed_summary.foreign_row_count,
            observed_summary.unresolved_row_count,
        )
        or classified_counts[0] != 0
        or classified_counts[2] != 0
        or sum(classified_counts) != process_row_count
        or observed_summary.sample_count != sample_count
        or observed_summary.process_row_count != process_row_count
        or observation_byte_count != len(observation_bytes)
        or observer["observation_sha256"] != observation_sha256
        or interval_ready != observer_ready
        or not network.observation_contains_workload(
            interval_started, workload_started, workload_ended, interval_ended
        )
    ):
        raise InstalledIncrementalEvidenceError(
            "installed network observer did not prove the bounded sampled-state result"
        )

    report_started = _nonnegative_integer(
        report["started_at_unix_ms"], "installed network report start"
    )
    report_ended = _nonnegative_integer(
        report["ended_at_unix_ms"], "installed network report end"
    )
    if (
        report_started != interval_started
        or report_ended != interval_ended
        or not network.observation_contains_workload(
            report_started, workload_started, workload_ended, report_ended
        )
        or execution_report["started_at_unix_ms"] != report_started
        or execution_report["ended_at_unix_ms"] != report_ended
        or report["artifacts"] != []
        or report["result"] != "passed"
        or report["exit_code"] != 0
        or report["diagnostic"] is not None
    ):
        raise InstalledIncrementalEvidenceError(
            "installed Task 10 network audit is not a closed passing execution"
        )


def _artifact(kind: str, path: Path, sha256: str | None = None) -> dict[str, str]:
    artifact = {"kind": kind, "path": str(path)}
    if sha256 is not None:
        artifact["sha256"] = sha256
    return artifact


def _descriptor(
    *,
    receipt_path: Path,
    receipt_sha256: str,
    xcresult_path: Path,
    semantic_path: Path,
    semantic_sha256: str,
    network_report_path: Path,
    network_report_sha256: str,
    execution_report_path: Path,
    execution_report_sha256: str,
    observation_path: Path,
    observation_sha256: str,
) -> dict[str, object]:
    artifacts = [
        _artifact(matrix.PROOF_ARTIFACT_KIND, receipt_path, receipt_sha256),
        _artifact("xcresult", xcresult_path),
        _artifact(SEMANTIC_MANIFEST_ARTIFACT_KIND, semantic_path, semantic_sha256),
        _artifact(NETWORK_REPORT_ARTIFACT_KIND, network_report_path, network_report_sha256),
        _artifact(
            NETWORK_EXECUTION_ARTIFACT_KIND,
            execution_report_path,
            execution_report_sha256,
        ),
        _artifact(
            NETWORK_OBSERVATION_ARTIFACT_KIND,
            observation_path,
            observation_sha256,
        ),
    ]
    artifacts.sort(key=lambda item: (item["kind"], item["path"], item.get("sha256", "")))
    return {
        "evidence": [
            {
                "gate": "incremental-xcuitest",
                "proofArtifacts": artifacts,
            }
        ]
    }


def _validated_descriptor(
    arguments: argparse.Namespace,
    *,
    authority: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    network_root: Path,
) -> dict[str, object]:
    try:
        receipt, receipt_sha256 = matrix.load_receipt_with_sha256(
            arguments.matrix_receipt
        )
    except matrix.InstalledMatrixReceiptError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    receipt_path = Path(arguments.matrix_receipt)
    if receipt_path.name != MATRIX_RECEIPT_NAME:
        raise InstalledIncrementalEvidenceError(
            f"matrix receipt must use the frozen filename {MATRIX_RECEIPT_NAME}"
        )
    candidate_path = Path(receipt["candidate"]["identity_path"])
    installed_app = Path(receipt["products"]["installed_app"]["path"])
    try:
        projection = ws24.installed_selector_projection(
            ws24.load_installed_selector_catalog()
        )
    except ws24.ReportError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    try:
        validated_receipt_sha256 = matrix.validate_receipt(
            receipt,
            candidate_identity_path=candidate_path,
            installed_app=installed_app,
            expected_selector_projection=projection,
        )
    except matrix.InstalledMatrixReceiptError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    if validated_receipt_sha256 != receipt_sha256:
        raise InstalledIncrementalEvidenceError(
            "matrix receipt canonical and physical digests disagree"
        )
    xcresult_path = Path(receipt["products"]["xcresult"]["path"])
    if xcresult_path.name != XCRESULT_NAME:
        raise InstalledIncrementalEvidenceError(
            f"xcresult must use the frozen filename {XCRESULT_NAME}"
        )

    try:
        candidate, candidate_document_sha256 = network.load_candidate(candidate_path)
        authorities = network.inspect_candidate_executables(installed_app, candidate)
        xcresult_bundle_sha256 = ws24.result_bundle_sha256(xcresult_path)
    except (network.AuditInputError, ws24.ReportError) as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    if candidate_identity_sha256(candidate) != receipt["candidate"]["identity_sha256"]:
        raise InstalledIncrementalEvidenceError(
            "candidate semantic identity differs from the matrix receipt"
        )
    observer_tool_source = _stable_file(
        network.NETTOP_PATH,
        label="installed network observer tool",
        maximum_bytes=MAXIMUM_OBSERVER_TOOL_BYTES,
    )

    semantic_path = Path(arguments.xcresult_semantic_manifest)
    if semantic_path.name != SEMANTIC_MANIFEST_NAME:
        raise InstalledIncrementalEvidenceError(
            "xcresult semantic manifest must use the frozen filename "
            f"{SEMANTIC_MANIFEST_NAME}"
        )
    semantic_value, semantic_source = _canonical_document(
        semantic_path,
        label="xcresult semantic manifest",
        maximum_bytes=MAXIMUM_SEMANTIC_MANIFEST_BYTES,
    )
    try:
        semantic = accessibility.validate_semantic_manifest(
            semantic_value,
            candidate_identity_sha256=receipt["candidate"]["identity_sha256"],
            receipt=receipt,
            catalog=projection,
            xcresult_bundle_sha256=xcresult_bundle_sha256,
        )
    except accessibility.InstalledAccessibilityReportError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error

    network_report_path = network_root / network.REPORT_NAME
    execution_report_path = network_root / network.EXECUTION_REPORT_NAME
    observation_path = network_root / network.OBSERVATION_NAME
    network_report_value, network_report_source = _canonical_document(
        network_report_path,
        label="installed network audit report",
        maximum_bytes=MAXIMUM_NETWORK_REPORT_BYTES,
    )
    execution_value, execution_source = _canonical_document(
        execution_report_path,
        label="installed network execution report",
        maximum_bytes=MAXIMUM_EXECUTION_REPORT_BYTES,
    )
    observation_source = _stable_file(
        observation_path,
        label="installed network observation",
        maximum_bytes=network.MAX_OBSERVER_STDOUT_BYTES,
    )
    if observation_source.payload is None:
        raise InstalledIncrementalEvidenceError(
            "installed network observation payload was not retained"
        )
    execution_report = _validate_execution_report(
        execution_value,
        authority=authority,
        predecessor_observations_sha256=predecessor_observations_sha256,
    )
    _validate_network_report(
        network_report_value,
        receipt=receipt,
        receipt_sha256=receipt_sha256,
        semantic=semantic,
        semantic_sha256=semantic_source.sha256,
        xcresult_bundle_sha256=xcresult_bundle_sha256,
        candidate_document_sha256=candidate_document_sha256,
        authorities=authorities,
        observation_bytes=observation_source.payload,
        observer_tool_sha256=observer_tool_source.sha256,
        execution_report=execution_report,
    )

    descriptor = _descriptor(
        receipt_path=receipt_path,
        receipt_sha256=receipt_sha256,
        xcresult_path=xcresult_path,
        semantic_path=semantic_path,
        semantic_sha256=semantic_source.sha256,
        network_report_path=network_report_path,
        network_report_sha256=network_report_source.sha256,
        execution_report_path=execution_report_path,
        execution_report_sha256=execution_source.sha256,
        observation_path=observation_path,
        observation_sha256=observation_source.sha256,
    )
    try:
        item = descriptor["evidence"][0]
        proof_artifacts = item["proofArtifacts"]
        normalized_artifacts = ws24.normalize_proof_artifacts(
            proof_artifacts, 0
        )
    except ws24.ReportError as error:
        raise InstalledIncrementalEvidenceError(
            f"WS24 rejected the incremental-XCUITest proof artifacts: {error}"
        ) from error
    if normalized_artifacts != proof_artifacts:
        raise InstalledIncrementalEvidenceError(
            "WS24 proof-artifact normalization changed the canonical descriptor"
        )
    return descriptor


def emit(arguments: argparse.Namespace) -> tuple[Path, str]:
    try:
        authority = qualification_run_authority(arguments)
    except ExecutionReportError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    predecessor = arguments.predecessor_observations_sha256
    if not is_sha256(predecessor):
        raise InstalledIncrementalEvidenceError(
            "predecessor observations digest must be a lowercase SHA-256"
        )
    network_root = _canonical_directory(
        arguments.network_artifact_root, "network artifact root"
    )
    if network_root.name != NETWORK_ROOT_NAME:
        raise InstalledIncrementalEvidenceError(
            f"network artifact root must use the frozen name {NETWORK_ROOT_NAME}"
        )
    output = network_root / OUTPUT_NAME
    if output.exists() or output.is_symlink():
        raise InstalledIncrementalEvidenceError(
            "incremental-XCUITest evidence output must be absent"
        )

    descriptor = _validated_descriptor(
        arguments,
        authority=authority,
        predecessor_observations_sha256=predecessor,
        network_root=network_root,
    )
    output_payload = canonical_bytes(descriptor)
    if len(output_payload) > MAXIMUM_OUTPUT_BYTES or output_payload.endswith(b"\n"):
        raise InstalledIncrementalEvidenceError(
            "incremental-XCUITest evidence exceeds its canonical no-LF size contract"
        )

    try:
        output_sha256 = matrix.write_create_only(output, descriptor)
    except matrix.InstalledMatrixReceiptError as error:
        raise InstalledIncrementalEvidenceError(str(error)) from error
    postpublication_descriptor = _validated_descriptor(
        arguments,
        authority=authority,
        predecessor_observations_sha256=predecessor,
        network_root=network_root,
    )
    if postpublication_descriptor != descriptor:
        raise InstalledIncrementalEvidenceError(
            "installed Task 10 evidence changed during adapter publication"
        )
    published, published_source = _canonical_document(
        output,
        label="incremental-XCUITest evidence output",
        maximum_bytes=MAXIMUM_OUTPUT_BYTES,
    )
    published_metadata = output.lstat()
    if (
        published != descriptor
        or published_source.sha256 != output_sha256
        or published_source.payload != output_payload
        or stat.S_IMODE(published_metadata.st_mode) != 0o600
        or published_metadata.st_nlink != 1
        or published_metadata.st_size != len(output_payload)
    ):
        raise InstalledIncrementalEvidenceError(
            "incremental-XCUITest evidence publication changed canonical bytes"
        )
    return output, output_sha256


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        output, output_sha256 = emit(arguments)
    except (OSError, InstalledIncrementalEvidenceError) as error:
        diagnostic = str(error).replace("\n", " ").replace("\x00", "�")[:512]
        print(
            f"ERROR: installed incremental-XCUITest evidence failed: {diagnostic}",
            file=sys.stderr,
        )
        return 2
    print(f"MACSCOPE_INSTALLED_INCREMENTAL_XCUITEST_EVIDENCE={output}")
    print(
        "MACSCOPE_INSTALLED_INCREMENTAL_XCUITEST_EVIDENCE_SHA256="
        f"{output_sha256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
