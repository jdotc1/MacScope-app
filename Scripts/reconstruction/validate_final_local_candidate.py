#!/usr/bin/env python3
"""Validate and seal one exact final local MacScope candidate.

This is an offline, create-only closure over the already-frozen qualification,
candidate, and two-phase installer contracts.  It deliberately emits only a
local-candidate receipt: it is not a public-release, online-delivery,
Reconstruction Gate F, or post-date proof authority.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Any, Callable, Mapping, NoReturn, Sequence


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import check_local_signing_policy as signing_policy  # noqa: E402
from Scripts import generate_release_build_provenance as provenance_contract  # noqa: E402
from Scripts import source_export_provenance  # noqa: E402
from Scripts import ws24_emit_installed_qualification_report as ws24  # noqa: E402
from Scripts.reconstruction import install_release_to_applications as installer  # noqa: E402
from Scripts.reconstruction import audit_installed_network_acquisition as network_audit  # noqa: E402
from Scripts.reconstruction import network_attribution  # noqa: E402
from Scripts.reconstruction import installed_matrix_receipt  # noqa: E402
from Scripts.reconstruction import native_live_preparation_receipt as native_preparation  # noqa: E402
from Scripts.reconstruction import validate_qualification_product_identity as qualification  # noqa: E402
from Scripts.reconstruction.integration_remote_authority import validate_integration_remote_url  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    CandidateSubjectKind,
    STABLE_ID_RE,
    candidate_identity_sha256,
    is_git_object,
    is_sha256,
    parse_candidate_identity,
)


SCHEMA_VERSION = 1
RECEIPT_KIND = "macscope-final-local-candidate"
AUTHORITY_SCOPE = "local-private-candidate-only"
LOCAL_REMOTE_REF_RE = re.compile(
    r"^refs/remotes/([A-Za-z0-9][A-Za-z0-9._-]{0,127})/(.+)$"
)
MAX_QUALIFICATION_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_CANDIDATE_IDENTITY_BYTES = 4 * 1024 * 1024
MAX_PROVENANCE_BYTES = 16 * 1024
MAX_COVERAGE_BYTES = 256 * 1024 * 1024
MAX_TRANSACTION_RESULT_BYTES = 4 * 1024 * 1024
MAX_GATE_PLAN_BYTES = 1024 * 1024
MAX_FINAL_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_GIT_OUTPUT_BYTES = 16 * 1024
MAX_TASK10_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_TASK10_SEMANTIC_BYTES = 4 * 1024 * 1024
MAX_TASK10_NETWORK_REPORT_BYTES = 4 * 1024 * 1024
MAX_TASK10_EXECUTION_REPORT_BYTES = 64 * 1024
MAX_TASK10_OBSERVATION_BYTES = network_audit.MAX_OBSERVER_STDOUT_BYTES
MAX_TASK10_INCREMENTAL_BYTES = 4 * 1024 * 1024

TRANSACTION_RESULT_KIND = "macscope-installed-acceptance-transaction"
TRANSACTION_RESULT_FIELDS = frozenset(
    {
        "acceptance_receipt",
        "candidate",
        "commit_authority",
        "gate_envelopes",
        "gate_plan",
        "installed_task10",
        "pending_state",
        "produced_at_unix_ns",
        "qualification_run",
        "result",
        "result_kind",
        "rolled_back",
        "schema_version",
        "terminal_committed_state",
        "transaction",
        "transaction_phase",
    }
)
TRANSACTION_RESULT_CANDIDATE_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root",
        "identity_file_sha256",
        "identity_path",
        "identity_sha256",
        "provenance_path",
        "provenance_sha256",
        "source_app_path",
        "source_commit",
        "source_tree",
    }
)
TRANSACTION_RESULT_RUN_FIELDS = frozenset({"nonce", "run_id"})
TRANSACTION_RESULT_TRANSACTION_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
TRANSACTION_RESULT_PENDING_FIELDS = frozenset(
    {"path_at_begin", "sha256", "terminal_path"}
)
TRANSACTION_RESULT_FILE_FIELDS = frozenset({"path", "sha256"})
TRANSACTION_RESULT_GATE_FIELDS = frozenset({"gate_id", "path", "sha256"})
TRANSACTION_RESULT_TASK10_FIELDS = frozenset(
    {
        "incremental_evidence",
        "matrix_receipt",
        "network_artifact_root",
        "xcresult",
        "xcresult_semantic_manifest",
    }
)
TRANSACTION_RESULT_TASK10_XCRESULT_FIELDS = frozenset(
    {"bundle_sha256", "closed_tree_sha256", "path"}
)
TRANSACTION_RESULT_TASK10_NETWORK_FIELDS = frozenset(
    {
        "audit_report_path",
        "audit_report_sha256",
        "execution_report_path",
        "execution_report_sha256",
        "observation_path",
        "observation_sha256",
        "path",
    }
)
TASK10_SEMANTIC_FIELDS = frozenset(
    {
        "candidate_identity_sha256",
        "executed_selector_count",
        "expected_selector_count",
        "failed_selector_count",
        "observed_selector_projection",
        "observed_selector_projection_sha256",
        "passed_selector_count",
        "result",
        "schema_version",
        "selector_catalog_sha256",
        "selector_projection",
        "selector_projection_sha256",
        "selectors",
        "skipped_selector_count",
        "source_xcresult",
    }
)
TASK10_NETWORK_REPORT_FIELDS = frozenset(
    {
        "attribution",
        "artifacts",
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
TASK10_NETWORK_CANDIDATE_FIELDS = frozenset(
    {"document_sha256", "identity_sha256", "source_commit", "source_tree"}
)
TASK10_NETWORK_WORKLOAD_FIELDS = frozenset(
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
TASK10_NETWORK_OBSERVER_FIELDS = frozenset(
    {
        "evidence_scope",
        "limitations",
        "observed_candidate_row_count",
        "observed_foreign_row_count",
        "observed_unresolved_row_count",
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
TASK10_EXECUTION_REPORT_FIELDS = frozenset(
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
TASK10_NETWORK_CHILDREN = frozenset(
    {
        "InstalledNetworkAcquisition.audit.json",
        "InstalledNetworkAcquisition.execution-report.json",
        "InstalledNetworkAcquisition.nettop.csv",
        "InstalledTask10.incremental-xcuitest.evidence.json",
    }
)
TASK10_SEMANTIC_ARTIFACT_KIND = "installed-task10-xcresult-semantic-manifest-v1"
TASK10_NETWORK_REPORT_ARTIFACT_KIND = "installed-task10-network-audit-report-v1"
TASK10_NETWORK_EXECUTION_ARTIFACT_KIND = (
    "installed-task10-network-audit-execution-report-v1"
)
TASK10_NETWORK_OBSERVATION_ARTIFACT_KIND = (
    "installed-task10-network-audit-observation-v1"
)

GATE_PLAN_FIELDS = frozenset(
    {
        "authority",
        "authority_sha256",
        "candidate_artifact_root",
        "evidence_root",
        "gates",
        "output_path",
        "plan_kind",
        "schema_version",
    }
)
GATE_PLAN_AUTHORITY_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root_identity_sha256",
        "artifact_root_path",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_path",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "installed_app_path",
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_preparation_receipt_sha256",
        "installed_ui_runner_closed_tree_sha256",
        "installed_ui_runner_executable_sha256",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_closed_tree_sha256",
        "installed_ui_test_bundle_executable_sha256",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "installed_ui_xctestrun_sha256",
        "native_preparation_receipt_path",
        "native_preparation_receipt_sha256",
        "native_xctestrun_path",
        "native_xctestrun_sha256",
        "pending_state_path",
        "pending_state_sha256",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "qualification_receipt_path",
        "qualification_receipt_sha256",
        "qualification_run_id",
        "qualification_run_nonce",
        "source_app_path",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
GATE_PLAN_GATE_FIELDS = frozenset(
    {
        "argv",
        "authority_sha256",
        "depends_on",
        "environment",
        "gate_id",
        "operation_id",
        "output",
        "timeout_seconds",
    }
)
GATE_PLAN_OUTPUT_FIELDS = frozenset(
    {"kind", "maximum_bytes", "path", "publication"}
)
GATE_PLAN_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "NO_PROXY": "*",
    "no_proxy": "*",
}
GATE_PLAN_TIMEOUTS = {
    "cli": 90,
    "forced-legacy-grid": 90,
    "full-surface": 90,
    "gui": 90,
    "mcp": 60,
    "native-xpc": 300,
    "shellbroker-launchagent": 1_860,
    "signing": 120,
}
GATE_PLAN_OUTPUTS = {
    "cli": ("command-file", "cli-gui-operability.report.json"),
    "forced-legacy-grid": ("command-file", "full-surface.legacy-grid.json"),
    "full-surface": ("command-file", "full-surface.json"),
    "gui": ("captured-stdout", "cli-gui-operability.status.txt"),
    "mcp": ("command-file", "mcp-operability.report.json"),
    "native-xpc": (
        "command-file",
        "native-xpc-artifacts/NativeDecompilerLiveXPC.execution-report.json",
    ),
    "shellbroker-launchagent": ("command-file", "live-evidence.json"),
    "signing": ("command-file", "WS24.installed-qualification.json"),
}
GATE_PLAN_MAXIMUM_BYTES = {
    "cli": 65_536,
    "forced-legacy-grid": 4_194_304,
    "full-surface": 4_194_304,
    "gui": 65_536,
    "mcp": 65_536,
    "native-xpc": 1_048_576,
    "shellbroker-launchagent": 8_388_608,
    "signing": 8_388_608,
}
GOVERNED_BASH_GATE_SCRIPTS = {
    "cli": REPOSITORY_ROOT / "Scripts/smoke/cli_gui_operability_smoke.sh",
    "gui": REPOSITORY_ROOT / "Scripts/smoke/cli_gui_operability_smoke.sh",
    "mcp": REPOSITORY_ROOT / "Scripts/smoke/mcp_operability_smoke.sh",
}
PLAN_EVIDENCE_DIRECTORY_NAME = "InstalledAcceptanceGate.evidence"
WS24_EVIDENCE_DIRECTORY_NAME = "InstalledAcceptanceQualification.evidence"
WS24_AGGREGATE_NAME = "WS24.installed-qualification.json"
INSTALLER_ARTIFACT_DIRECTORY_NAME = "MacScopeInstaller.acceptance-artifacts"
OPERABILITY_REPORT_FIELDS = frozenset(
    {"authority", "probeResults", "reportKind", "schemaVersion", "status"}
)
OPERABILITY_AUTHORITY_FIELDS = frozenset(
    {
        "applicationExecutableSHA256",
        "buildProvenanceSHA256",
        "candidateFileSHA256",
        "candidateIdentitySHA256",
        "destinationIdentitySHA256",
        "executionIdentitySHA256",
        "exposedAtUnixNanoseconds",
        "forcedLegacyGridReportSHA256",
        "fullSurfaceReportSHA256",
        "installedExecutableSHA256",
        "installationPendingStateSHA256",
        "nativeLiveXPCReportSHA256",
        "predecessorObservationsSHA256",
        "qualificationRunID",
        "shellBrokerExecutableSHA256",
        "shellBrokerInfoPlistSHA256",
        "sourceCommit",
        "sourceEqualitySHA256",
        "sourceTree",
        "transactionID",
    }
)
WS24_AGGREGATE_FIELDS = frozenset(
    {
        "accepted",
        "acceptedGates",
        "deficiencies",
        "evidence",
        "generatedAtUnixMilliseconds",
        "installedExecutableSHA256",
        "liveEvidenceSHA256",
        "operabilityAuthority",
        "operabilityReportSHA256",
        "performanceThresholds",
        "schemaVersion",
        "sourceCommit",
        "sourceTree",
    }
)

RELEASE_PROVENANCE_FIELDS = frozenset(
    {
        "ai_worker_bundle_identifier",
        "app_bundle_identifier",
        "architecture",
        "configuration",
        "dependency_root_authority",
        "deployment_target",
        "ghostty_source_dir_sha256",
        "ghostty_surface_archive_relative_path",
        "ghostty_surface_archive_sha256",
        "ghostty_surface_build_profile_sha256",
        "ghostty_surface_compilation_condition",
        "ghostty_surface_external_io_abi_version",
        "ghostty_surface_header_relative_path",
        "ghostty_surface_header_sha256",
        "ghostty_surface_module_map_relative_path",
        "ghostty_surface_module_map_sha256",
        "ghostty_surface_source_manifest_sha256",
        "ghostty_surface_source_revision",
        "ghostty_surface_source_sha256",
        "ghostty_surface_source_tree",
        "ghostty_surface_staged_descriptor_relative_path",
        "ghostty_surface_staged_descriptor_sha256",
        "ghostty_surface_staged_tree_sha256",
        "git_head_commit",
        "git_head_tree",
        "machokit_analysis_worker_compiled_identity",
        "machokit_analysis_worker_executable_sha256",
        "machokit_analysis_worker_executable_size",
        "machokit_governed_source_identity",
        "machokit_materialization_manifest_sha256",
        "machokit_materialization_root_sha256",
        "machokit_materialization_tree_sha256",
        "machokit_revision",
        "machokit_source_archive_sha256",
        "machokit_upstream_tree_sha256",
        "machokit_version",
        "native_decompiler_embedded_decompiler_archive_sha256",
        "native_decompiler_embedded_manifest_sha256",
        "native_decompiler_embedded_service_bundle_identifier",
        "native_decompiler_embedded_service_code_resources_sha256",
        "native_decompiler_embedded_service_executable_sha256",
        "native_decompiler_embedded_service_info_plist_sha256",
        "native_decompiler_embedded_sleigh_archive_sha256",
        "native_decompiler_embedded_tree_sha256",
        "native_decompiler_golden_result",
        "native_decompiler_golden_result_sha256",
        "project_yml_sha256",
        "qualification_eligible",
        "repository_clean",
        "schema_version",
        "sdk_build",
        "sdk_name",
        "sdk_version",
        "selected_build_inputs_sha256",
        "sleigh_materialization_component_id",
        "sleigh_materialization_manifest_sha256",
        "sleigh_materialization_root_sha256",
        "sleigh_materialization_schema_version",
        "sleigh_materialization_tree_sha256",
        "swift_compiler_version",
        "swift_language_version",
        "swift_target_triple",
        "third_party_component_count",
        "third_party_component_ids",
        "third_party_distribution_status",
        "third_party_manifest_sha256",
        "third_party_notices_sha256",
        "third_party_public_distribution_approved",
        "xcode_build",
        "xcode_version",
        "xcodegen_version",
    }
)


class FinalLocalCandidateError(RuntimeError):
    """The supplied artifacts cannot authorize a final local receipt."""


def fail(message: str) -> NoReturn:
    raise FinalLocalCandidateError(message)


@dataclass(frozen=True)
class StableFile:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    payload: bytes

    @property
    def sha256(self) -> str:
        return hashlib.sha256(self.payload).hexdigest()

    @property
    def mtime_ns(self) -> int:
        return self.metadata[5]

    @property
    def ctime_ns(self) -> int:
        return self.metadata[6]


@dataclass(frozen=True)
class StableTree:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    bundle_sha256: str
    closed_tree_sha256: str


@dataclass(frozen=True)
class InstalledTask10Authority:
    document: dict[str, Any]
    matrix_receipt: StableFile
    matrix_receipt_document: dict[str, Any]
    xcresult: StableTree
    semantic_manifest: StableFile
    semantic_document: dict[str, Any]
    network_root: Path
    network_root_metadata: tuple[int, int, int, int, int, int, int]
    audit_report: StableFile
    audit_document: dict[str, Any]
    execution_report: StableFile
    execution_document: dict[str, Any]
    observation: StableFile
    incremental_evidence: StableFile
    incremental_document: dict[str, Any]


@dataclass(frozen=True)
class LocalRefAuthority:
    repository_root: Path
    integration_ref: str
    remote_name: str
    branch_name: str
    remote_url: str
    commit: str
    tree: str


@dataclass(frozen=True)
class QualificationAuthority:
    document: dict[str, Any]
    receipt: StableFile
    validated: qualification.QualificationInputs
    source_provenance: dict[str, Any]
    source_provenance_sha256: str
    result_bundle: Path
    coverage: StableFile


@dataclass(frozen=True)
class CandidateAuthority:
    candidate: CandidateIdentity
    identity: StableFile
    provenance: StableFile
    provenance_document: dict[str, Any]
    source_app: Path
    source_authority: installer.SourceAuthority


@dataclass(frozen=True)
class InstallationAuthority:
    state: dict[str, Any]
    state_file: StableFile
    installer_state_file: installer.StableFile
    terminal_root: Path
    installed_app: Path
    installed_snapshot: installer.ExactBundleSnapshot
    acceptance_receipt: StableFile
    acceptance_document: dict[str, Any]
    commit_authority: StableFile
    commit_document: dict[str, Any]
    gate_files: tuple[tuple[str, StableFile], ...]
    gate_records: dict[str, dict[str, object]]


@dataclass(frozen=True)
class TransactionResultAuthority:
    document: dict[str, Any]
    result_file: StableFile
    candidate: dict[str, Any]
    qualification_run: QualificationRunAuthority
    transaction: dict[str, Any]
    pending_state: dict[str, Any]
    installed_task10: InstalledTask10Authority
    gate_plan: StableFile
    gate_plan_document: dict[str, Any]
    native_preparation_receipt: StableFile
    native_xctestrun: StableFile
    gate_output_files: tuple[tuple[str, StableFile], ...]
    gate_evidence_files: tuple[tuple[str, StableFile], ...]
    ws24_aggregate: StableFile
    gate_envelopes: tuple[tuple[str, StableFile], ...]
    acceptance_receipt: StableFile
    terminal_state: StableFile
    commit_authority: StableFile


@dataclass(frozen=True)
class Closure:
    local_ref: LocalRefAuthority
    qualification: QualificationAuthority
    candidate: CandidateAuthority
    installation: InstallationAuthority
    qualification_run: QualificationRunAuthority
    transaction_result: TransactionResultAuthority
    input_files: tuple[StableFile, ...]


def _metadata(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _canonical_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        fail(f"{label} must be an absolute canonical path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        fail(f"{label} must be a non-symlink directory")
    if resolved != path:
        fail(f"{label} must not traverse symbolic links or use a noncanonical path")
    return resolved


def _read_stable_file(path: Path, *, maximum_bytes: int, label: str) -> StableFile:
    if not path.is_absolute():
        fail(f"{label} must be an absolute canonical path")
    try:
        lexical = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if (
        not stat.S_ISREG(lexical.st_mode)
        or stat.S_ISLNK(lexical.st_mode)
        or lexical.st_nlink != 1
    ):
        fail(f"{label} must be an ordinary single-link non-symlink file")
    if resolved != path:
        fail(f"{label} must not traverse symbolic links or use a noncanonical path")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"{label} cannot be opened safely: {error}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or _metadata(before) != _metadata(lexical)
        ):
            fail(f"{label} physical identity changed before read")
        if before.st_size > maximum_bytes:
            fail(f"{label} exceeds its {maximum_bytes}-byte bound")
        chunks: list[bytes] = []
        observed = 0
        while True:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1))
            if not block:
                break
            observed += len(block)
            if observed > maximum_bytes:
                fail(f"{label} exceeds its {maximum_bytes}-byte bound")
            chunks.append(block)
        after = os.fstat(descriptor)
        if _metadata(before) != _metadata(after):
            fail(f"{label} changed while read")
        return StableFile(path=path, metadata=_metadata(before), payload=b"".join(chunks))
    except OSError as error:
        fail(f"{label} cannot be read safely: {error}")
    finally:
        os.close(descriptor)


def _require_unchanged(snapshot: StableFile, *, label: str) -> None:
    observed = _read_stable_file(
        snapshot.path,
        maximum_bytes=max(len(snapshot.payload), 1),
        label=label,
    )
    if observed.metadata != snapshot.metadata or observed.payload != snapshot.payload:
        fail(f"{label} changed during final closure")


def _capture_xcresult_tree(path: Path, *, label: str) -> StableTree:
    root = _canonical_directory(path, label=label)
    before = root.lstat()
    try:
        bundle_sha256 = ws24.result_bundle_sha256(root)
        tree_digests = installed_matrix_receipt._fenced_tree_digests(root)
    except (
        OSError,
        installed_matrix_receipt.InstalledMatrixReceiptError,
        ws24.ReportError,
    ) as error:
        fail(f"{label} is not one closed ordinary tree: {error}")
    after = root.lstat()
    if _metadata(before) != _metadata(after):
        fail(f"{label} changed while its tree digests were recomputed")
    return StableTree(
        path=root,
        metadata=_metadata(before),
        bundle_sha256=bundle_sha256,
        closed_tree_sha256=tree_digests.closed_tree_sha256,
    )


def _require_tree_unchanged(snapshot: StableTree, *, label: str) -> None:
    observed = _capture_xcresult_tree(snapshot.path, label=label)
    if observed != snapshot:
        fail(f"{label} changed during final closure")


def _directory_children(path: Path, *, label: str) -> frozenset[str]:
    try:
        with os.scandir(path) as entries:
            names = frozenset(entry.name for entry in entries)
    except OSError as error:
        fail(f"{label} cannot be enumerated safely: {error}")
    if any(name in {"", ".", ".."} for name in names):
        fail(f"{label} contains an invalid child name")
    return names


def _closed_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"JSON contains duplicate object key: {key}")
        result[key] = value
    return result


def _parse_integer(value: str) -> int:
    parsed = int(value, 10)
    if not -(2**63) <= parsed <= 2**63 - 1:
        fail("JSON integer is outside signed 64-bit bounds")
    return parsed


def _reject_float(value: str) -> NoReturn:
    fail(f"floating-point JSON value is forbidden: {value}")


def _decode_canonical_line(payload: bytes, *, label: str) -> Any:
    try:
        text = payload.decode("utf-8")
        value = json.loads(
            text,
            parse_float=_reject_float,
            parse_int=_parse_integer,
            parse_constant=_reject_float,
            object_pairs_hook=_closed_object,
        )
        expected = (
            json.dumps(
                value,
                ensure_ascii=True,
                allow_nan=False,
                sort_keys=True,
                separators=(",", ":"),
            )
            + "\n"
        ).encode("utf-8")
    except (UnicodeError, json.JSONDecodeError, TypeError, ValueError) as error:
        fail(f"{label} is malformed JSON: {error}")
    if payload != expected:
        fail(f"{label} is not exact canonical line-delimited JSON")
    return value


def _decode_canonical(payload: bytes, *, label: str) -> Any:
    try:
        return decode_canonical_bytes(payload)
    except CanonicalJSONError as error:
        fail(f"{label} is not canonical JSON: {error}")


def _closed_mapping(value: object, fields: frozenset[str], *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{label} does not satisfy its exact closed schema")
    return value


def _positive_integer(value: object, *, label: str) -> int:
    if type(value) is not int or value <= 0:
        fail(f"{label} must be a positive integer")
    return value


def _nonnegative_integer(value: object, *, label: str) -> int:
    if type(value) is not int or value < 0:
        fail(f"{label} must be a nonnegative integer")
    return value


def _sha256_string(value: object, *, label: str) -> str:
    if not isinstance(value, str) or not is_sha256(value):
        fail(f"{label} must be a lowercase SHA-256")
    return value


def _path_string(value: object, *, label: str) -> Path:
    if not isinstance(value, str) or not value or "\x00" in value:
        fail(f"{label} must be an absolute canonical path string")
    path = Path(value)
    if (
        not path.is_absolute()
        or os.path.normpath(value) != value
        or str(path) != value
        or "//" in value
    ):
        fail(f"{label} must be an absolute canonical path string")
    return path


def _require_descendant(path: Path, root: Path, *, label: str) -> None:
    try:
        path.relative_to(root)
    except ValueError:
        fail(f"{label} must be contained by the candidate artifact root")


def _require_disjoint(first: Path, second: Path, *, label: str) -> None:
    if first == second or first.is_relative_to(second) or second.is_relative_to(first):
        fail(f"{label} must be disjoint")


def _read_manifest_file(
    record: object,
    *,
    maximum_bytes: int,
    label: str,
) -> StableFile:
    mapping = _closed_mapping(record, TRANSACTION_RESULT_FILE_FIELDS, label=label)
    path = _path_string(mapping["path"], label=f"{label} path")
    expected_sha256 = _sha256_string(mapping["sha256"], label=f"{label} SHA-256")
    snapshot = _read_stable_file(path, maximum_bytes=maximum_bytes, label=label)
    if snapshot.sha256 != expected_sha256:
        fail(f"{label} bytes differ from the transaction result")
    return snapshot


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _git(
    repository_root: Path,
    arguments: Sequence[str],
    *,
    label: str,
    allow_empty: bool = False,
) -> str:
    environment = {
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    try:
        completed = subprocess.run(
            ["/usr/bin/git", "-C", str(repository_root), *arguments],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
    except OSError as error:
        fail(f"cannot resolve {label} locally: {error}")
    if (
        completed.returncode != 0
        or completed.stderr
        or len(completed.stdout) > MAX_GIT_OUTPUT_BYTES
    ):
        diagnostic = completed.stderr[:1024].decode("utf-8", "replace").strip()
        fail(f"cannot resolve {label} locally{': ' + diagnostic if diagnostic else ''}")
    try:
        value = completed.stdout.decode("utf-8").removesuffix("\n")
    except UnicodeDecodeError as error:
        fail(f"{label} is not UTF-8: {error}")
    if (not value and not allow_empty) or "\n" in value or "\r" in value or "\x00" in value:
        fail(f"{label} is malformed")
    return value


def _resolve_local_ref(repository_root: Path, integration_ref: str) -> LocalRefAuthority:
    root = _canonical_directory(repository_root, label="repository root")
    match = LOCAL_REMOTE_REF_RE.fullmatch(integration_ref)
    remote_name = match.group(1) if match is not None else ""
    branch_name = match.group(2) if match is not None else ""
    if (
        match is None
        or len(integration_ref) > 256
        or remote_name.endswith(".")
        or remote_name.lower().endswith(".lock")
        or branch_name == "HEAD"
        or any(
            part in {"", ".", ".."}
            or part.startswith(".")
            or part.endswith(".")
            or part.lower().endswith(".lock")
            for part in branch_name.split("/")
        )
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in integration_ref)
    ):
        fail(
            "integration ref must be an explicit canonical "
            "refs/remotes/<local-remote>/<branch>"
        )
    _git(root, ("check-ref-format", integration_ref), label="integration ref format", allow_empty=True)
    commit = _git(
        root,
        ("rev-parse", "--verify", f"{integration_ref}^{{commit}}"),
        label="local integration commit",
    )
    tree = _git(
        root,
        ("rev-parse", "--verify", f"{integration_ref}^{{tree}}"),
        label="local integration tree",
    )
    if not is_git_object(commit) or not is_git_object(tree):
        fail("local integration ref did not resolve to exact commit/tree identities")
    remote_url = _git(
        root,
        (
            "config",
            "--local",
            "--no-includes",
            "--get-all",
            f"remote.{remote_name}.url",
        ),
        label=f"local integration remote {remote_name} URL",
    )
    try:
        validate_integration_remote_url(remote_url)
    except ValueError as error:
        fail(f"remote {remote_name}: {error}")
    return LocalRefAuthority(
        repository_root=root,
        integration_ref=integration_ref,
        remote_name=remote_name,
        branch_name=branch_name,
        remote_url=remote_url,
        commit=commit,
        tree=tree,
    )


def _validate_qualification(
    path: Path,
    *,
    local_ref: LocalRefAuthority,
) -> QualificationAuthority:
    receipt = _read_stable_file(
        path,
        maximum_bytes=MAX_QUALIFICATION_RECEIPT_BYTES,
        label="full-test qualification receipt",
    )
    if receipt.path.name != "QUALIFICATION_INPUTS.json":
        fail("full-test qualification receipt must use the governed filename")
    document = _decode_canonical_line(receipt.payload, label="full-test qualification receipt")
    document = _closed_mapping(
        document,
        qualification.QUALIFICATION_V4_FIELDS,
        label="full-test qualification receipt",
    )
    if (
        document.get("schema_version") != 4
        or document.get("mode") != "full-test"
        or document.get("dependency_network_allowed") is not False
        or document.get("dependency_network_used") is not False
    ):
        fail("qualification receipt is not one canonical offline full-test run authority")
    run_root = _canonical_directory(receipt.path.parent, label="qualification run root")
    if not run_root.name.startswith("run.") or run_root.parent.name != "runs":
        fail("qualification receipt is not owned by one canonical run.* root")
    source_root = _canonical_directory(run_root / "source", label="sealed qualification source")
    try:
        source_provenance, _source_records = source_export_provenance.load_verified_export(
            source_root
        )
    except (OSError, source_export_provenance.SourceExportError) as error:
        fail(f"sealed qualification source export is invalid: {error}")
    if source_provenance != document.get("source_identity"):
        fail("qualification receipt and sealed source provenance differ")
    if (
        source_provenance.get("canonical_integration_ref") != local_ref.integration_ref
        or source_provenance.get("canonical_remote_url") != local_ref.remote_url
        or source_provenance.get("canonical_integration_commit") != local_ref.commit
        or source_provenance.get("git_head_commit") != local_ref.commit
        or source_provenance.get("git_head_tree") != local_ref.tree
    ):
        fail("qualification source authority differs from the exact local integration ref")

    namespace = argparse.Namespace(
        receipt=receipt.path,
        run_root=run_root,
        derived_data_root=run_root / "DerivedData",
        build_source_root=source_root,
        dependency_cache_root=Path(str(document["dependency_cache_root"])),
        expected_integration_ref=local_ref.integration_ref,
        expected_integration_commit=local_ref.commit,
        expected_integration_tree=local_ref.tree,
        expected_mode="full-test",
        dependency_network_authorized=document["dependency_network_allowed"],
    )
    try:
        validated = qualification.validate_qualification_inputs(namespace)
    except (OSError, qualification.ProductIdentityError) as error:
        fail(f"full-test qualification run authority is invalid: {error}")

    result_bundle = _canonical_directory(
        run_root / "TestResults.xcresult",
        label="canonical full-test result bundle",
    )
    coverage = _read_stable_file(
        run_root / "COVERAGE.json",
        maximum_bytes=MAX_COVERAGE_BYTES,
        label="canonical full-test coverage report",
    )
    try:
        coverage_value = json.loads(
            coverage.payload,
            object_pairs_hook=_closed_object,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as error:
        fail(f"canonical full-test coverage report is malformed JSON: {error}")
    if not isinstance(coverage_value, (dict, list)):
        fail("canonical full-test coverage report must be a JSON container")
    if coverage.mtime_ns < receipt.mtime_ns:
        fail("full-test coverage evidence predates its qualification receipt")
    source_provenance_bytes = (
        json.dumps(
            source_provenance,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")
    return QualificationAuthority(
        document=document,
        receipt=receipt,
        validated=validated,
        source_provenance=source_provenance,
        source_provenance_sha256=_sha256(source_provenance_bytes),
        result_bundle=result_bundle,
        coverage=coverage,
    )


def _validate_provenance_document(
    document: object,
    *,
    candidate: CandidateIdentity,
    local_ref: LocalRefAuthority,
) -> dict[str, Any]:
    value = _closed_mapping(
        document,
        RELEASE_PROVENANCE_FIELDS,
        label="candidate Release provenance",
    )
    for field, expected in signing_policy.EXPECTED_RELEASE_PROVENANCE_SCALARS.items():
        if type(value.get(field)) is not type(expected) or value.get(field) != expected:
            fail(f"candidate Release provenance {field} differs from the frozen contract")
    if (
        value.get("git_head_commit") != local_ref.commit
        or value.get("git_head_tree") != local_ref.tree
        or value.get("project_yml_sha256") != candidate.source.project_yml_sha256
        or value.get("third_party_public_distribution_approved") is not False
    ):
        fail("candidate Release provenance source or private-distribution authority differs")
    for key, item in value.items():
        if key.endswith("_sha256") and (not isinstance(item, str) or not is_sha256(item)):
            fail(f"candidate Release provenance {key} is not a lowercase SHA-256")
    golden = value.get("native_decompiler_golden_result")
    if not isinstance(golden, dict) or set(golden) != provenance_contract.NATIVE_DECOMPILER_GOLDEN_KEYS:
        fail("candidate Release provenance native golden result is not closed")
    component_ids = value.get("third_party_component_ids")
    if (
        not isinstance(component_ids, list)
        or any(not isinstance(item, str) or not item for item in component_ids)
        or component_ids != sorted(set(component_ids))
        or value.get("third_party_component_count") != len(component_ids)
    ):
        fail("candidate Release provenance third-party identity set is invalid")
    return value


def _candidate_matches_local_ref(
    candidate: CandidateIdentity,
    local_ref: LocalRefAuthority,
) -> bool:
    # Repository identity is independent of the local transport alias. Keep
    # historical exact alias labels readable while admitting the owner-declared
    # canonical identity; qualification still binds the exact configured URL,
    # tracking ref, commit and tree separately in _validate_qualification.
    repository_labels = {
        "https://github.com/jdotc1/MacScope-app",
        f"{local_ref.remote_name}:MacScope",
    }
    return not (
        candidate.subject_kind is not CandidateSubjectKind.CANDIDATE
        or candidate.source.dirty
        or candidate.source.repository not in repository_labels
        or candidate.source.commit != local_ref.commit
        or candidate.source.tree != local_ref.tree
        or candidate.source.branch_label != local_ref.branch_name
        or candidate.prospective_merge_commit is not None
        or candidate.prospective_merge_tree is not None
        or candidate.accepted_postmerge_commit is not None
        or candidate.accepted_postmerge_tree is not None
    )


def _validate_candidate(
    identity_path: Path,
    provenance_path: Path,
    *,
    local_ref: LocalRefAuthority,
) -> CandidateAuthority:
    identity = _read_stable_file(
        identity_path,
        maximum_bytes=MAX_CANDIDATE_IDENTITY_BYTES,
        label="candidate identity",
    )
    identity_document = _decode_canonical(identity.payload, label="candidate identity")
    candidate, issues = parse_candidate_identity(identity_document)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        fail(f"candidate identity is invalid{': ' + detail if detail else ''}")
    if not _candidate_matches_local_ref(candidate, local_ref):
        fail("candidate identity is not the exact unmerged local integration candidate")

    provenance = _read_stable_file(
        provenance_path,
        maximum_bytes=MAX_PROVENANCE_BYTES,
        label="candidate Release provenance",
    )
    if provenance.path.name != "MacScopeBuildProvenance.json":
        fail("candidate Release provenance must use its governed filename")
    try:
        source_app = provenance.path.parents[2]
    except IndexError:
        fail("candidate Release provenance is not inside MacScope.app")
    if (
        provenance.path
        != source_app / "Contents" / "Resources" / "MacScopeBuildProvenance.json"
        or source_app.name != "MacScope.app"
    ):
        fail("candidate Release provenance path is outside the exact app layout")
    source_app = _canonical_directory(source_app, label="candidate source MacScope.app")
    provenance_document = _decode_canonical_line(
        provenance.payload,
        label="candidate Release provenance",
    )
    provenance_document = _validate_provenance_document(
        provenance_document,
        candidate=candidate,
        local_ref=local_ref,
    )
    try:
        source_authority = installer._load_source_authority(identity.path, source_app)
    except (OSError, installer.InstallationError) as error:
        fail(f"candidate app/identity authority is invalid: {error}")
    if (
        source_authority.candidate_identity_sha256 != candidate_identity_sha256(candidate)
        or source_authority.candidate_file_sha256 != identity.sha256
        or source_authority.build_provenance_sha256 != provenance.sha256
    ):
        fail("candidate file, semantic identity, or provenance digest differs")
    observed_provenance, provenance_errors = signing_policy.validate_release_provenance(
        source_app,
        expected_source_commit=local_ref.commit,
        expected_source_tree=local_ref.tree,
    )
    if provenance_errors or observed_provenance != provenance_document:
        fail(
            "candidate Release provenance does not validate against its app"
            + (f": {'; '.join(provenance_errors)}" if provenance_errors else "")
        )
    return CandidateAuthority(
        candidate=candidate,
        identity=identity,
        provenance=provenance,
        provenance_document=provenance_document,
        source_app=source_app,
        source_authority=source_authority,
    )


def _parse_gate_arguments(arguments: Sequence[str]) -> tuple[tuple[str, Path], ...]:
    parsed: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for argument in arguments:
        gate_id, separator, raw_path = argument.partition("=")
        if not separator or not gate_id or not raw_path:
            fail("acceptance gate inputs must use GATE_ID=/absolute/canonical.json")
        if gate_id in seen:
            fail(f"duplicate acceptance gate input: {gate_id}")
        seen.add(gate_id)
        parsed.append((gate_id, Path(raw_path)))
    if tuple(sorted(seen)) != installer.REQUIRED_ACCEPTANCE_GATES:
        fail("exactly one input is required for each of the eight acceptance gates")
    return tuple(parsed)


def _validate_installation(
    state_path: Path,
    acceptance_path: Path,
    gate_arguments: Sequence[str],
    *,
    candidate: CandidateAuthority,
    qualification_authority: QualificationAuthority,
    qualification_run: QualificationRunAuthority,
    allow_test_destination: bool,
) -> InstallationAuthority:
    state_file = _read_stable_file(
        state_path,
        maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        label="installer terminal transaction state",
    )
    if state_file.path.name != "transaction.json":
        fail("installer terminal transaction state must be transaction.json")
    state_value = _decode_canonical(state_file.payload, label="installer terminal transaction state")
    state = _closed_mapping(
        state_value,
        installer.PENDING_TRANSACTION_FIELDS,
        label="installer terminal transaction state",
    )
    token = state.get("candidate_identity_sha256")
    transaction_id = state.get("transaction_id")
    if not is_sha256(token) or not is_sha256(transaction_id):
        fail("installer terminal transaction state has malformed candidate/transaction identity")
    terminal_root = _canonical_directory(state_file.path.parent, label="installer terminal root")
    expected_terminal_root = terminal_root.parent / (
        f".MacScope.committed-{token}-{transaction_id}"
    )
    if terminal_root != expected_terminal_root:
        fail("installer transaction is rolled back, active, ambiguous, or nonterminal")
    root_mode = stat.S_IMODE(terminal_root.lstat().st_mode)
    if root_mode != 0o700:
        fail("installer terminal root mode is not private")

    source_app = candidate.source_app
    installed_value = state.get("installed_app_path")
    artifact_value = state.get("artifact_root")
    if not isinstance(installed_value, str) or not isinstance(artifact_value, str):
        fail("installer transaction paths are malformed")
    installed_app = _canonical_directory(Path(installed_value), label="installed MacScope.app")
    if not allow_test_destination and installed_app != installer.PRODUCTION_DESTINATION:
        fail("final local candidate must be installed at /Applications/MacScope.app")
    if installed_app.name != "MacScope.app" or installed_app == source_app:
        fail("installer source and destination app paths are invalid")
    if terminal_root.parent != installed_app.parent:
        fail("installer terminal root is outside the installation boundary")
    artifact_root = _canonical_directory(Path(artifact_value), label="installer artifact root")
    acceptance = _read_stable_file(
        acceptance_path,
        maximum_bytes=installer.MAX_ACCEPTANCE_RECEIPT_BYTES,
        label="MacScopeInstaller acceptance receipt",
    )
    if (
        acceptance.path.name != installer.ACCEPTANCE_RECEIPT_NAME
        or acceptance.path != artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
        or state.get("acceptance_receipt_path") != str(acceptance.path)
    ):
        fail("MacScopeInstaller acceptance receipt path differs from the transaction")
    if (
        state.get("qualification_run_id") != qualification_run.run_id
        or state.get("qualification_run_nonce") != qualification_run.nonce
        or state.get("source_commit") != candidate.candidate.source.commit
        or state.get("source_tree") != candidate.candidate.source.tree
        or state.get("candidate_identity_sha256")
        != candidate.source_authority.candidate_identity_sha256
        or state.get("candidate_file_sha256")
        != candidate.source_authority.candidate_file_sha256
        or state.get("application_executable_sha256")
        != candidate.source_authority.executable_sha256
        or state.get("build_provenance_sha256")
        != candidate.source_authority.build_provenance_sha256
    ):
        fail("installer transaction candidate/source/run identity differs")
    if state.get("source_app_path") != str(source_app):
        fail("installer transaction source app path differs from candidate provenance")
    try:
        installer_state, installer_state_file = installer._pending_read_stable(terminal_root)
        installer._pending_validate_state(
            installer_state,
            authority=candidate.source_authority,
            token=token,
            installed_app=installed_app,
            source_app=source_app,
            artifact_root=artifact_root,
            qualification_run=qualification_run,
            predecessor_observations_sha256=str(
                state.get("predecessor_observations_sha256", "")
            ),
            allowed_phases=frozenset({"pending"}),
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"installer terminal transaction state is invalid: {error}")
    if installer_state != state or installer_state_file.payload != state_file.payload:
        fail("installer terminal transaction state changed across validation")

    siblings = (
        terminal_root.parent / f".MacScope.pending-{token}",
        terminal_root.parent / f".MacScope.committing-{token}",
        terminal_root.parent / f".MacScope.rolled-back-{token}-{transaction_id}",
    )
    if any(path.exists() or path.is_symlink() for path in siblings):
        fail("active or rolled-back installer authority coexists with the terminal commit")
    committed = tuple(terminal_root.parent.glob(f".MacScope.committed-{token}-*"))
    if committed != (terminal_root,):
        fail("installer terminal commit root is missing or ambiguous")

    try:
        installed_snapshot = installer._capture_exact_bundle(installed_app)
        if not installer._snapshot_matches_record(
            installed_snapshot, state["candidate_identity"]
        ):
            fail("installed app does not match the terminal candidate identity")
        installer._validate_destination_identity(
            state["destination_identity"],
            installed_app,
            snapshot=installed_snapshot,
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"installed destination identity is invalid: {error}")
    if (
        installed_snapshot.digests.content_sha256
        != candidate.candidate.application.bundle_sha256
        or installed_snapshot.digests.closed_tree_sha256
        != candidate.candidate.application.closed_tree_sha256
        or installed_snapshot.root_mode != candidate.candidate.application.root_mode
    ):
        fail("installed destination differs from the candidate application identity")

    try:
        source_equality = installer._collect_exact_equality(
            signing_policy.collect_installed_source_equality,
            source_app,
            installed_app,
            candidate.source_authority,
            phase="final candidate",
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"installed source equality is invalid: {error}")
    source_equality_sha256 = _sha256(canonical_bytes(source_equality))
    if source_equality_sha256 != state.get("source_equality_sha256"):
        fail("installed source-equality identity differs from the terminal transaction")
    if (
        source_equality.get("release_executable_sha256")
        != candidate.candidate.application.executable_sha256
        or source_equality.get("installed_executable_sha256")
        != candidate.candidate.application.executable_sha256
    ):
        fail("source/installed executable identity differs from the candidate")
    installed_provenance = _read_stable_file(
        installed_app / installer.BUILD_PROVENANCE_RELATIVE_PATH,
        maximum_bytes=MAX_PROVENANCE_BYTES,
        label="installed Release provenance",
    )
    if installed_provenance.payload != candidate.provenance.payload:
        fail("installed and candidate Release provenance bytes differ")

    parsed_gates = _parse_gate_arguments(gate_arguments)
    gate_files = tuple(
        (
            gate_id,
            _read_stable_file(
                path,
                maximum_bytes=installer.MAX_ACCEPTANCE_GATE_INPUT_BYTES,
                label=f"acceptance gate input {gate_id}",
            ),
        )
        for gate_id, path in parsed_gates
    )
    try:
        gate_records, latest_gate_end = installer._acceptance_gate_records(
            state=state,
            gate_arguments=tuple(
                f"{gate_id}={path}" for gate_id, path in parsed_gates
            ),
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"acceptance gate inputs are invalid: {error}")
    if len({record["input_sha256"] for record in gate_records.values()}) != 8:
        fail("acceptance gates do not have eight distinct input hashes")

    try:
        acceptance_installer_file = installer._validate_acceptance_receipt(
            state=state,
            state_file=installer_state_file,
            artifact_root=artifact_root,
            reader=installer._read_acceptance_receipt_file,
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"MacScopeInstaller acceptance receipt is invalid: {error}")
    if acceptance_installer_file.payload != acceptance.payload:
        fail("MacScopeInstaller acceptance receipt changed across validation")
    acceptance_document = _decode_canonical(
        acceptance.payload,
        label="MacScopeInstaller acceptance receipt",
    )
    acceptance_document = _closed_mapping(
        acceptance_document,
        installer.ACCEPTANCE_RECEIPT_FIELDS,
        label="MacScopeInstaller acceptance receipt",
    )
    if acceptance_document.get("gates") != gate_records:
        fail("acceptance receipt gate records differ from the exact eight envelopes")
    if (
        acceptance_document.get("result") != "passed"
        or acceptance_document.get("rolled_back") is not False
        or acceptance_document.get("transaction_phase") != "pending"
        or acceptance_document.get("produced_at_unix_ns", -1) < latest_gate_end
    ):
        fail("acceptance receipt result, rollback, phase, or timestamp is invalid")

    commit_path = terminal_root / installer.COMMIT_AUTHORITY_NAME
    commit_file = _read_stable_file(
        commit_path,
        maximum_bytes=installer.MAX_COMMIT_AUTHORITY_BYTES,
        label="installer terminal commit authority",
    )
    try:
        commit_document_value, installer_commit_file = installer._read_commit_authority(
            terminal_root,
            state=state,
            state_file=installer_state_file,
        )
    except (OSError, installer.InstallationError) as error:
        fail(f"installer terminal commit authority is invalid: {error}")
    commit_document = dict(commit_document_value)
    if installer_commit_file.payload != commit_file.payload:
        fail("installer terminal commit authority changed across validation")
    if (
        commit_document.get("pending_state_sha256") != state_file.sha256
        or commit_document.get("acceptance_receipt_sha256") != acceptance.sha256
        or commit_document.get("transaction_id") != state["transaction_id"]
        or commit_document.get("transaction_nonce") != state["transaction_nonce"]
    ):
        fail("installer receipt predecessor chain is broken")
    if commit_file.ctime_ns < acceptance.ctime_ns:
        fail("installer terminal commit authority predates its acceptance receipt")
    began = state.get("began_at_unix_ns")
    if (
        type(began) is not int
        or qualification_authority.receipt.mtime_ns > began
        or qualification_authority.coverage.mtime_ns > began
        or candidate.identity.mtime_ns > began
        or candidate.provenance.mtime_ns > began
    ):
        fail("qualification or candidate evidence is stale relative to installation begin")

    return InstallationAuthority(
        state=state,
        state_file=state_file,
        installer_state_file=installer_state_file,
        terminal_root=terminal_root,
        installed_app=installed_app,
        installed_snapshot=installed_snapshot,
        acceptance_receipt=acceptance,
        acceptance_document=acceptance_document,
        commit_authority=commit_file,
        commit_document=commit_document,
        gate_files=gate_files,
        gate_records=gate_records,
    )


def _validate_run_authority(run_id: str, nonce: str) -> QualificationRunAuthority:
    if STABLE_ID_RE.fullmatch(run_id) is None:
        fail("qualification run ID must be a canonical stable ID")
    if not is_sha256(nonce):
        fail("qualification run nonce must be a lowercase SHA-256")
    return QualificationRunAuthority(run_id=run_id, nonce=nonce)


def _validate_frozen_plan_contract(document: dict[str, Any]) -> None:
    try:
        compiler = importlib.import_module(
            "Scripts.reconstruction.compile_installed_acceptance_gate_plan"
        )
        validate_plan_document = getattr(compiler, "validate_plan_document")
    except (ImportError, AttributeError) as error:
        fail(f"frozen acceptance-plan validator is unavailable: {error}")
    try:
        validate_plan_document(document, require_outputs_absent=False)
    except Exception as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        fail(f"compiled acceptance gate plan violates its frozen contract: {error}")


def _validate_gate_executable(argv: list[str], *, gate_id: str) -> Path:
    executable = _path_string(
        argv[0], label=f"compiled plan gate {gate_id} executable"
    )
    if executable == Path("/bin/bash"):
        governed_script = GOVERNED_BASH_GATE_SCRIPTS.get(gate_id)
        if (
            governed_script is None
            or len(argv) < 2
            or argv[1] != str(governed_script)
            or "-c" in argv[1:]
        ):
            fail(
                f"compiled plan gate {gate_id} does not use its exact governed "
                "Bash script-file invocation"
            )
        return executable
    if executable in {Path("/bin/sh"), Path("/bin/zsh")}:
        fail(f"compiled plan gate {gate_id} may not execute shell text")
    return executable


def _validate_gate_plan_structure(
    plan_file: StableFile,
    *,
    candidate_artifact_root: Path,
    work_root: Path,
) -> tuple[
    dict[str, Any],
    StableFile,
    StableFile,
    tuple[tuple[str, StableFile], ...],
]:
    if plan_file.path.name != "InstalledAcceptanceGate.plan.json":
        fail("compiled acceptance gate plan has the wrong governed filename")
    if plan_file.metadata[2] != 0o600:
        fail("compiled acceptance gate plan mode is not private")
    value = _decode_canonical(plan_file.payload, label="compiled acceptance gate plan")
    plan = _closed_mapping(value, GATE_PLAN_FIELDS, label="compiled acceptance gate plan")
    if (
        plan.get("schema_version") != 1
        or plan.get("plan_kind") != "macscope-installed-acceptance-gate-plan"
    ):
        fail("compiled acceptance gate plan schema or kind is unsupported")
    _validate_frozen_plan_contract(plan)
    root_path = _path_string(
        plan.get("candidate_artifact_root"),
        label="compiled plan candidate artifact root",
    )
    if root_path != candidate_artifact_root:
        fail("compiled plan candidate artifact root differs")
    evidence_root = _path_string(
        plan.get("evidence_root"), label="compiled plan evidence root"
    )
    evidence_root = _canonical_directory(evidence_root, label="compiled plan evidence root")
    if evidence_root != work_root / PLAN_EVIDENCE_DIRECTORY_NAME:
        fail("compiled plan evidence root differs from its governed work-root subpath")
    output_path = _path_string(plan.get("output_path"), label="compiled plan output path")
    if output_path != plan_file.path or output_path != evidence_root / plan_file.path.name:
        fail("compiled plan does not bind its exact direct-child output path")

    authority = _closed_mapping(
        plan.get("authority"),
        GATE_PLAN_AUTHORITY_FIELDS,
        label="compiled plan authority",
    )
    authority_sha256 = _sha256_string(
        plan.get("authority_sha256"), label="compiled plan authority SHA-256"
    )
    if _sha256(canonical_bytes(authority)) != authority_sha256:
        fail("compiled plan authority hash differs from its canonical authority")
    for field in (
        "application_executable_sha256",
        "artifact_root_identity_sha256",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "execution_identity_sha256",
        "installed_ui_preparation_receipt_sha256",
        "installed_ui_runner_closed_tree_sha256",
        "installed_ui_runner_executable_sha256",
        "installed_ui_test_bundle_closed_tree_sha256",
        "installed_ui_test_bundle_executable_sha256",
        "installed_ui_xctestrun_sha256",
        "native_preparation_receipt_sha256",
        "native_xctestrun_sha256",
        "pending_state_sha256",
        "predecessor_observations_sha256",
        "qualification_receipt_sha256",
        "qualification_run_nonce",
        "source_equality_sha256",
        "transaction_id",
        "transaction_nonce",
    ):
        _sha256_string(authority.get(field), label=f"compiled plan authority {field}")
    for field in ("source_commit", "source_tree"):
        if not isinstance(authority.get(field), str) or not is_git_object(authority[field]):
            fail(f"compiled plan authority {field} is not a Git object identity")
    if not isinstance(authority.get("qualification_run_id"), str):
        fail("compiled plan qualification run ID must be a string")
    _validate_run_authority(
        authority["qualification_run_id"], authority["qualification_run_nonce"]
    )
    exposed_at = _positive_integer(
        authority.get("exposed_at_unix_ns"),
        label="compiled plan exposure time",
    )
    began_at = _positive_integer(
        authority.get("began_at_unix_ns"),
        label="compiled plan begin time",
    )
    if began_at > exposed_at:
        fail("compiled plan begin time follows candidate exposure")
    predecessor_digest = authority.get("predecessor_digest")
    if predecessor_digest is not None:
        _sha256_string(predecessor_digest, label="compiled plan predecessor digest")
    for field in (
        "artifact_root_path",
        "candidate_identity_path",
        "installed_app_path",
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "installed_ui_preparation_receipt_path",
        "installed_ui_runner_path",
        "installed_ui_test_bundle_path",
        "installed_ui_xctestrun_path",
        "native_preparation_receipt_path",
        "native_xctestrun_path",
        "pending_state_path",
        "qualification_receipt_path",
        "source_app_path",
    ):
        _path_string(authority.get(field), label=f"compiled plan authority {field}")

    native_preparation_path = _path_string(
        authority["native_preparation_receipt_path"],
        label="native preparation receipt path",
    )
    if native_preparation_path != (
        candidate_artifact_root / "NativeLivePreparation.receipt.json"
    ):
        fail("compiled plan native preparation receipt path differs")
    native_preparation_receipt = _read_stable_file(
        native_preparation_path,
        maximum_bytes=4 * 1024 * 1024,
        label="native preparation receipt",
    )
    if (
        native_preparation_receipt.sha256
        != authority["native_preparation_receipt_sha256"]
    ):
        fail("native preparation receipt differs from the compiled plan")
    _decode_canonical(
        native_preparation_receipt.payload,
        label="native preparation receipt",
    )
    native_xctestrun_path = _path_string(
        authority["native_xctestrun_path"],
        label="native xctestrun path",
    )
    _require_disjoint(
        native_xctestrun_path,
        work_root,
        label="native xctestrun and transaction work-root",
    )
    native_xctestrun = _read_stable_file(
        native_xctestrun_path,
        maximum_bytes=64 * 1024 * 1024,
        label="native xctestrun",
    )
    if native_xctestrun.sha256 != authority["native_xctestrun_sha256"]:
        fail("native xctestrun differs from the compiled plan")
    if (
        native_preparation_receipt.mtime_ns > began_at
        or native_xctestrun.mtime_ns > began_at
    ):
        fail("native preparation authority was not sealed before transaction begin")

    gates_value = plan.get("gates")
    if not isinstance(gates_value, list) or len(gates_value) != 8:
        fail("compiled plan must contain exactly eight gates")
    gate_documents: dict[str, dict[str, Any]] = {}
    output_files: list[tuple[str, StableFile]] = []
    operation_ids: list[str] = []
    for index, item in enumerate(gates_value):
        gate = _closed_mapping(
            item,
            GATE_PLAN_GATE_FIELDS,
            label=f"compiled plan gate {index}",
        )
        gate_id = gate.get("gate_id")
        if not isinstance(gate_id, str):
            fail("compiled plan gate ID must be a string")
        if gate_id in gate_documents:
            fail(f"compiled plan repeats gate {gate_id}")
        if gate.get("authority_sha256") != authority_sha256:
            fail(f"compiled plan gate {gate_id} authority differs")
        operation_id = gate.get("operation_id")
        if (
            not isinstance(operation_id, str)
            or STABLE_ID_RE.fullmatch(operation_id) is None
        ):
            fail(f"compiled plan gate {gate_id} operation ID is invalid")
        operation_ids.append(operation_id)
        depends_on = gate.get("depends_on")
        if (
            not isinstance(depends_on, list)
            or depends_on != sorted(set(depends_on))
            or gate_id in depends_on
            or any(item not in installer.REQUIRED_ACCEPTANCE_GATES for item in depends_on)
        ):
            fail(f"compiled plan gate {gate_id} dependency list is invalid")
        timeout_seconds = gate.get("timeout_seconds")
        if timeout_seconds != GATE_PLAN_TIMEOUTS.get(gate_id):
            fail(f"compiled plan gate {gate_id} timeout is outside the frozen bound")
        expected_environment = dict(GATE_PLAN_ENVIRONMENT)
        expected_environment["MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256"] = authority_sha256
        if gate.get("environment") != expected_environment:
            fail(f"compiled plan gate {gate_id} environment is not closed")
        argv = gate.get("argv")
        if (
            not isinstance(argv, list)
            or not argv
            or any(
                not isinstance(argument, str)
                or not argument
                or "\x00" in argument
                or "\n" in argument
                or "\r" in argument
                for argument in argv
            )
        ):
            fail(f"compiled plan gate {gate_id} argv is malformed")
        _validate_gate_executable(argv, gate_id=gate_id)
        output = _closed_mapping(
            gate.get("output"),
            GATE_PLAN_OUTPUT_FIELDS,
            label=f"compiled plan gate {gate_id} output",
        )
        if gate_id not in installer.REQUIRED_ACCEPTANCE_GATES:
            fail(f"compiled plan contains unknown gate {gate_id}")
        output_path = _path_string(
            output.get("path"), label=f"compiled plan gate {gate_id} output path"
        )
        expected_output = GATE_PLAN_OUTPUTS.get(gate_id)
        governed_output_root = (
            work_root / WS24_EVIDENCE_DIRECTORY_NAME
            if gate_id == "signing"
            else evidence_root
        )
        if (
            expected_output is None
            or output.get("kind") != expected_output[0]
            or output.get("maximum_bytes") != GATE_PLAN_MAXIMUM_BYTES.get(gate_id)
            or output.get("publication") != "create-only"
            or output_path != governed_output_root / expected_output[1]
        ):
            fail(f"compiled plan gate {gate_id} output binding differs")
        try:
            output_path.relative_to(governed_output_root)
        except ValueError:
            fail(f"compiled plan gate {gate_id} output is outside its governed root")
        output_snapshot = _read_stable_file(
            output_path,
            maximum_bytes=GATE_PLAN_MAXIMUM_BYTES[gate_id],
            label=f"compiled plan gate {gate_id} primary output",
        )
        output_files.append((gate_id, output_snapshot))
        gate_documents[gate_id] = gate

    if tuple(gate_documents) != installer.REQUIRED_ACCEPTANCE_GATES:
        fail("compiled plan gates are not in canonical gate-ID order")
    legacy = gate_documents["forced-legacy-grid"]
    surface = gate_documents["full-surface"]
    if (
        legacy["operation_id"] != "renderer-dual"
        or surface["operation_id"] != "renderer-dual"
        or legacy["argv"] != surface["argv"]
    ):
        fail("compiled plan renderer gates do not share the exact renderer-dual operation")
    cli = gate_documents["cli"]
    gui = gate_documents["gui"]
    if cli["operation_id"] != gui["operation_id"] or cli["argv"] != gui["argv"]:
        fail("compiled plan CLI/GUI gates do not share one exact operation")
    non_shared_operations = [
        gate_documents[gate_id]["operation_id"]
        for gate_id in installer.REQUIRED_ACCEPTANCE_GATES
        if gate_id not in {"cli", "gui", "forced-legacy-grid", "full-surface"}
    ]
    if (
        legacy["operation_id"] in non_shared_operations
        or cli["operation_id"] in non_shared_operations
        or legacy["operation_id"] == cli["operation_id"]
        or len(set(non_shared_operations)) != len(non_shared_operations)
    ):
        fail("compiled plan operation IDs do not encode the two shared operations")
    if gate_documents["forced-legacy-grid"]["timeout_seconds"] != gate_documents[
        "full-surface"
    ]["timeout_seconds"]:
        fail("compiled plan renderer operation has inconsistent timeouts")
    if len({snapshot.metadata[:2] for _gate_id, snapshot in output_files}) != 8:
        fail("compiled plan primary outputs must be eight physically distinct files")
    outputs = dict(output_files)
    for gate_id, snapshot in output_files:
        if gate_documents[gate_id]["output"]["kind"] == "command-file":
            _decode_canonical(
                snapshot.payload,
                label=f"compiled plan gate {gate_id} primary output",
            )
    expected_gui_status = (
        "PASS: installed CLI/GUI operability report sha256="
        f"{outputs['cli'].sha256}\n"
    ).encode("utf-8")
    if outputs["gui"].payload != expected_gui_status:
        fail("compiled plan GUI status output does not bind the CLI/GUI report")
    return (
        plan,
        native_preparation_receipt,
        native_xctestrun,
        tuple(output_files),
    )


def _validate_operability_report(
    snapshot: StableFile,
    *,
    label: str,
    report_kind: str,
    probe_fields: frozenset[str],
    transaction: Mapping[str, Any],
    pending_state_sha256: str,
    qualification_run_id: str,
    outputs_by_gate: Mapping[str, StableFile],
) -> dict[str, Any]:
    if len(snapshot.payload) > 64 * 1024:
        fail(f"{label} exceeds its frozen 64-KiB bound")
    value = _decode_canonical(snapshot.payload, label=label)
    report = _closed_mapping(value, OPERABILITY_REPORT_FIELDS, label=label)
    if (
        report.get("schemaVersion") != 1
        or report.get("reportKind") != report_kind
        or report.get("status") != "passed"
    ):
        fail(f"{label} is not one passing schema-1 report")
    probes = _closed_mapping(report.get("probeResults"), probe_fields, label=f"{label} probes")
    if any(value is not True for value in probes.values()):
        fail(f"{label} does not contain every passing probe")
    authority = _closed_mapping(
        report.get("authority"),
        OPERABILITY_AUTHORITY_FIELDS,
        label=f"{label} authority",
    )
    exact = {
        "applicationExecutableSHA256": transaction["application_executable_sha256"],
        "buildProvenanceSHA256": transaction["build_provenance_sha256"],
        "candidateFileSHA256": transaction["candidate_file_sha256"],
        "candidateIdentitySHA256": transaction["candidate_identity_sha256"],
        "destinationIdentitySHA256": transaction["destination_identity_sha256"],
        "executionIdentitySHA256": transaction["execution_identity_sha256"],
        "exposedAtUnixNanoseconds": transaction["exposed_at_unix_ns"],
        "forcedLegacyGridReportSHA256": outputs_by_gate[
            "forced-legacy-grid"
        ].sha256,
        "fullSurfaceReportSHA256": outputs_by_gate["full-surface"].sha256,
        "installedExecutableSHA256": transaction["application_executable_sha256"],
        "installationPendingStateSHA256": pending_state_sha256,
        "nativeLiveXPCReportSHA256": outputs_by_gate["native-xpc"].sha256,
        "predecessorObservationsSHA256": transaction[
            "predecessor_observations_sha256"
        ],
        "qualificationRunID": qualification_run_id,
        "sourceCommit": transaction["source_commit"],
        "sourceEqualitySHA256": transaction["source_equality_sha256"],
        "sourceTree": transaction["source_tree"],
        "transactionID": transaction["transaction_id"],
    }
    for field, expected in exact.items():
        if authority.get(field) != expected:
            fail(f"{label} authority {field} differs from the transaction")
    for field in ("shellBrokerExecutableSHA256", "shellBrokerInfoPlistSHA256"):
        _sha256_string(authority.get(field), label=f"{label} authority {field}")
    return report


def _validate_ws24_aggregate(
    value: object,
    *,
    transaction: Mapping[str, Any],
    cli_gui_report: StableFile,
    cli_gui_document: Mapping[str, Any],
    mcp_report: StableFile,
    mcp_document: Mapping[str, Any],
    live_evidence_manifest: StableFile,
) -> dict[str, Any]:
    aggregate = _closed_mapping(
        value,
        WS24_AGGREGATE_FIELDS,
        label="WS24 installed qualification aggregate",
    )
    if (
        aggregate.get("schemaVersion")
        != ws24.INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION
        or aggregate.get("accepted") is not True
        or aggregate.get("acceptedGates") != list(ws24.REQUIRED_GATES)
        or aggregate.get("deficiencies") != []
        or aggregate.get("performanceThresholds") != ws24.PERFORMANCE_THRESHOLDS
        or aggregate.get("installedExecutableSHA256")
        != transaction["application_executable_sha256"]
        or aggregate.get("sourceCommit") != transaction["source_commit"]
        or aggregate.get("sourceTree") != transaction["source_tree"]
    ):
        fail("WS24 installed qualification aggregate is not exact passing authority")
    if cli_gui_document["authority"] != mcp_document["authority"]:
        fail("CLI/GUI and MCP operability reports have different authorities")
    if aggregate.get("operabilityAuthority") != cli_gui_document["authority"]:
        fail("WS24 aggregate operability authority differs from its exact reports")
    if aggregate.get("operabilityReportSHA256") != {
        "cliGUI": cli_gui_report.sha256,
        "mcp": mcp_report.sha256,
    }:
        fail("WS24 aggregate operability report digests differ")
    if aggregate.get("liveEvidenceSHA256") != live_evidence_manifest.sha256:
        fail("WS24 aggregate live-evidence digest differs from its governed manifest")
    generated_at = aggregate.get("generatedAtUnixMilliseconds")
    if (
        type(generated_at) is not int
        or generated_at < transaction["exposed_at_unix_ns"] // 1_000_000
    ):
        fail("WS24 aggregate generation time predates candidate exposure")
    evidence = aggregate.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        fail("WS24 aggregate evidence is empty or malformed")
    return aggregate


def _validate_installed_task10(
    value: object,
    *,
    evidence_root: Path,
    candidate: Mapping[str, Any],
    transaction: Mapping[str, Any],
    qualification_run: QualificationRunAuthority,
    installed_app: Path,
) -> InstalledTask10Authority:
    record = _closed_mapping(
        value,
        TRANSACTION_RESULT_TASK10_FIELDS,
        label="transaction result installed Task10",
    )
    matrix_receipt = _read_manifest_file(
        record["matrix_receipt"],
        maximum_bytes=MAX_TASK10_RECEIPT_BYTES,
        label="installed Task10 matrix receipt",
    )
    semantic_manifest = _read_manifest_file(
        record["xcresult_semantic_manifest"],
        maximum_bytes=MAX_TASK10_SEMANTIC_BYTES,
        label="installed Task10 xcresult semantic manifest",
    )
    incremental_evidence = _read_manifest_file(
        record["incremental_evidence"],
        maximum_bytes=MAX_TASK10_INCREMENTAL_BYTES,
        label="installed Task10 incremental evidence",
    )
    expected_matrix = evidence_root / "InstalledTask10.matrix-receipt.json"
    expected_xcresult = evidence_root / "InstalledTask10.xcresult"
    expected_semantic = evidence_root / "InstalledTask10.xcresult-semantic.json"
    expected_network_root = evidence_root / "installed-task10-network"
    expected_incremental = (
        expected_network_root / "InstalledTask10.incremental-xcuitest.evidence.json"
    )
    if (
        matrix_receipt.path != expected_matrix
        or semantic_manifest.path != expected_semantic
        or incremental_evidence.path != expected_incremental
    ):
        fail("installed Task10 files differ from their exact governed evidence-root paths")

    xcresult_record = _closed_mapping(
        record["xcresult"],
        TRANSACTION_RESULT_TASK10_XCRESULT_FIELDS,
        label="installed Task10 xcresult",
    )
    xcresult_path = _path_string(
        xcresult_record["path"], label="installed Task10 xcresult path"
    )
    if xcresult_path != expected_xcresult:
        fail("installed Task10 xcresult differs from its exact governed path")
    xcresult = _capture_xcresult_tree(
        xcresult_path, label="installed Task10 xcresult"
    )
    if (
        _sha256_string(
            xcresult_record["bundle_sha256"],
            label="installed Task10 xcresult bundle SHA-256",
        )
        != xcresult.bundle_sha256
        or _sha256_string(
            xcresult_record["closed_tree_sha256"],
            label="installed Task10 xcresult closed-tree SHA-256",
        )
        != xcresult.closed_tree_sha256
    ):
        fail("installed Task10 xcresult bytes/tree differ from the transaction result")

    network_record = _closed_mapping(
        record["network_artifact_root"],
        TRANSACTION_RESULT_TASK10_NETWORK_FIELDS,
        label="installed Task10 network artifact root",
    )
    network_root_path = _path_string(
        network_record["path"], label="installed Task10 network artifact root path"
    )
    if network_root_path != expected_network_root:
        fail("installed Task10 network root differs from its exact lowercase governed path")
    network_root = _canonical_directory(
        network_root_path, label="installed Task10 network artifact root"
    )
    network_root_metadata = _metadata(network_root.lstat())
    if _directory_children(network_root, label="installed Task10 network artifact root") != TASK10_NETWORK_CHILDREN:
        fail("installed Task10 network root does not contain its exact closed child set")
    expected_network_files = {
        "audit_report": network_root / "InstalledNetworkAcquisition.audit.json",
        "execution_report": network_root
        / "InstalledNetworkAcquisition.execution-report.json",
        "observation": network_root / "InstalledNetworkAcquisition.nettop.csv",
    }
    for field, path in expected_network_files.items():
        if (
            _path_string(
                network_record[f"{field}_path"],
                label=f"installed Task10 network {field} path",
            )
            != path
        ):
            fail(f"installed Task10 network {field} differs from its exact governed path")
    audit_report = _read_stable_file(
        expected_network_files["audit_report"],
        maximum_bytes=MAX_TASK10_NETWORK_REPORT_BYTES,
        label="installed Task10 network audit report",
    )
    execution_report = _read_stable_file(
        expected_network_files["execution_report"],
        maximum_bytes=MAX_TASK10_EXECUTION_REPORT_BYTES,
        label="installed Task10 network execution report",
    )
    observation = _read_stable_file(
        expected_network_files["observation"],
        maximum_bytes=MAX_TASK10_OBSERVATION_BYTES,
        label="installed Task10 network observation",
    )
    for field, snapshot in (
        ("audit_report", audit_report),
        ("execution_report", execution_report),
        ("observation", observation),
    ):
        if (
            _sha256_string(
                network_record[f"{field}_sha256"],
                label=f"installed Task10 network {field} SHA-256",
            )
            != snapshot.sha256
        ):
            fail(f"installed Task10 network {field} bytes differ from the transaction result")

    private_files = (
        matrix_receipt,
        semantic_manifest,
        incremental_evidence,
        audit_report,
        execution_report,
        observation,
    )
    if any(snapshot.metadata[2] != 0o600 for snapshot in private_files):
        fail("installed Task10 file authorities must have mode 0600")
    if len({snapshot.metadata[:2] for snapshot in private_files}) != len(private_files):
        fail("installed Task10 file authorities must be physically distinct")
    if any(snapshot.mtime_ns < transaction["exposed_at_unix_ns"] for snapshot in private_files):
        fail("installed Task10 evidence predates candidate exposure")

    matrix_value = _decode_canonical(
        matrix_receipt.payload, label="installed Task10 matrix receipt"
    )
    try:
        matrix_document = installed_matrix_receipt.parse_document(matrix_value)
    except installed_matrix_receipt.InstalledMatrixReceiptError as error:
        fail(f"installed Task10 matrix receipt is invalid: {error}")
    expected_projection = ws24.installed_selector_projection()
    expected_selectors = [item["test_identifier"] for item in expected_projection]
    matrix_candidate = matrix_document["candidate"]
    matrix_execution = matrix_document["execution"]
    matrix_products = matrix_document["products"]
    if (
        matrix_document["schema_version"] != installed_matrix_receipt.SCHEMA_VERSION
        or matrix_document["receipt_kind"] != installed_matrix_receipt.RECEIPT_KIND
        or matrix_candidate["identity_path"] != candidate["identity_path"]
        or matrix_candidate["identity_sha256"] != candidate["identity_sha256"]
        or matrix_candidate["source_commit"] != candidate["source_commit"]
        or matrix_candidate["source_tree"] != candidate["source_tree"]
        or matrix_products["installed_app"]["executable_sha256"]
        != candidate["application_executable_sha256"]
        or matrix_products["xcresult"]
        != {"path": str(xcresult.path), "closed_tree_sha256": xcresult.closed_tree_sha256}
        or matrix_execution["result"] != "passed"
        or matrix_execution["exit_code"] != 0
        or matrix_execution["failure"] is not None
        or matrix_execution["selectors"] != expected_selectors
        or matrix_execution["selector_projection"] != expected_projection
        or matrix_execution["selector_projection_sha256"]
        != _sha256(canonical_bytes(expected_projection))
    ):
        fail("installed Task10 matrix receipt is not the exact passing candidate/xcresult authority")

    semantic_value = _decode_canonical(
        semantic_manifest.payload, label="installed Task10 xcresult semantic manifest"
    )
    semantic_document = _closed_mapping(
        semantic_value,
        TASK10_SEMANTIC_FIELDS,
        label="installed Task10 xcresult semantic manifest",
    )
    semantic_source = _closed_mapping(
        semantic_document["source_xcresult"],
        frozenset({"bundle_sha256", "closed_tree_sha256"}),
        label="installed Task10 semantic xcresult source",
    )
    expected_observed_projection = [
        {
            "observed_identifiers": sorted(item["required_identifiers"]),
            "test_identifier": item["test_identifier"],
            "vector_id": item["vector_id"],
        }
        for item in expected_projection
    ]
    expected_semantic_selectors = [
        {"test_identifier": identifier, "status": "passed"}
        for identifier in expected_selectors
    ]
    if (
        semantic_document["schema_version"] != 3
        or semantic_document["candidate_identity_sha256"] != candidate["identity_sha256"]
        or semantic_source
        != {
            "bundle_sha256": xcresult.bundle_sha256,
            "closed_tree_sha256": xcresult.closed_tree_sha256,
        }
        or semantic_document["selector_catalog_sha256"]
        != _sha256(canonical_bytes(expected_selectors))
        or semantic_document["selector_projection"] != expected_projection
        or semantic_document["selector_projection_sha256"]
        != _sha256(canonical_bytes(expected_projection))
        or semantic_document["observed_selector_projection"]
        != expected_observed_projection
        or semantic_document["observed_selector_projection_sha256"]
        != _sha256(canonical_bytes(expected_observed_projection))
        or semantic_document["expected_selector_count"] != 22
        or semantic_document["executed_selector_count"] != 22
        or semantic_document["passed_selector_count"] != 22
        or semantic_document["failed_selector_count"] != 0
        or semantic_document["skipped_selector_count"] != 0
        or semantic_document["selectors"] != expected_semantic_selectors
        or semantic_document["result"] != "passed"
    ):
        fail("installed Task10 semantic manifest does not bind one exact passing xcresult")

    audit_value = _decode_canonical(
        audit_report.payload, label="installed Task10 network audit report"
    )
    audit_document = _closed_mapping(
        audit_value,
        TASK10_NETWORK_REPORT_FIELDS,
        label="installed Task10 network audit report",
    )
    network_candidate = _closed_mapping(
        audit_document["candidate"],
        TASK10_NETWORK_CANDIDATE_FIELDS,
        label="installed Task10 network candidate",
    )
    workload = _closed_mapping(
        audit_document["workload"],
        TASK10_NETWORK_WORKLOAD_FIELDS,
        label="installed Task10 network workload",
    )
    workload_started = _nonnegative_integer(
        workload["started_at_unix_ms"], label="installed Task10 workload start"
    )
    workload_ended = _nonnegative_integer(
        workload["ended_at_unix_ms"], label="installed Task10 workload end"
    )
    observer_ready = _nonnegative_integer(
        workload["observer_ready_at_unix_ms"],
        label="installed Task10 observer readiness",
    )
    expected_workload_bindings = {
        "matrix_receipt_sha256": matrix_receipt.sha256,
        "xcresult_bundle_sha256": xcresult.bundle_sha256,
        "xcresult_closed_tree_sha256": xcresult.closed_tree_sha256,
        "xcresult_semantic_manifest_sha256": semantic_manifest.sha256,
        "selector_catalog_sha256": semantic_document["selector_catalog_sha256"],
        "selector_projection_sha256": semantic_document["selector_projection_sha256"],
        "expected_selector_count": 22,
        "executed_selector_count": 22,
        "passed_selector_count": 22,
        "failed_selector_count": 0,
        "skipped_selector_count": 0,
        "matrix_result": "passed",
    }
    if (
        audit_document["schema_version"] != network_audit.MATRIX_REPORT_SCHEMA_VERSION
        or audit_document["command_id"] != "installed.network-acquisition-audit"
        or audit_document["evidence_layer"] != "installed-launch-log"
        or network_candidate
        != {
            "document_sha256": candidate["identity_file_sha256"],
            "identity_sha256": candidate["identity_sha256"],
            "source_commit": candidate["source_commit"],
            "source_tree": candidate["source_tree"],
        }
        or workload["command_id"] != "installed.task10-workflow"
        or any(workload[field] != expected for field, expected in expected_workload_bindings.items())
        or workload["observation_contains_workload"] is not True
        or workload["observer_readiness_precedes_workload"] is not True
        or observer_ready > workload_started
        or workload_ended <= workload_started
        or audit_document["artifacts"] != []
        or audit_document["result"] != "passed"
        or audit_document["exit_code"] != 0
        or audit_document["diagnostic"] is not None
    ):
        fail("installed Task10 network report does not bind the exact passing workload")

    executables = audit_document["executables"]
    expected_roles = frozenset({"app", *network_audit.MANDATORY_EXECUTABLE_NAMES})
    if not isinstance(executables, list) or len(executables) != len(expected_roles):
        fail("installed Task10 network report lacks the exact app/four-XPC role set")
    observed_roles: set[str] = set()
    observed_pids: set[int] = set()
    expected_paths = {"app": str(installed_app / "Contents/MacOS/MacScope")}
    expected_paths.update({role: str(installed_app / "Contents/XPCServices" / f"{name}.xpc"
                                    / "Contents/MacOS" / name)
                           for role, name in network_audit.MANDATORY_EXECUTABLE_NAMES.items()})
    for index, executable_value in enumerate(executables):
        executable = _closed_mapping(
            executable_value,
            frozenset({"executable_path", "executable_sha256", "identity_id", "processes"}),
            label=f"installed Task10 executable {index}",
        )
        role = executable["identity_id"]
        if role not in expected_roles or role in observed_roles:
            fail("installed Task10 network executable roles are substituted or duplicated")
        observed_roles.add(role)
        _path_string(
            executable["executable_path"],
            label=f"installed Task10 executable {role} path",
        )
        if executable["executable_path"] != expected_paths[role]:
            fail("installed Task10 executable path differs from admitted installed bundle")
        digest = _sha256_string(
            executable["executable_sha256"],
            label=f"installed Task10 executable {role} SHA-256",
        )
        if role == "app" and digest != candidate["application_executable_sha256"]:
            fail("installed Task10 network app executable differs from the candidate")
        processes = executable["processes"]
        if not isinstance(processes, list):
            fail(f"installed Task10 executable {role} processes must be an array")
        for process_value in processes:
            process = _closed_mapping(
                process_value,
                frozenset({"pid", "start_time_unix_us"}),
                label=f"installed Task10 executable {role} process",
            )
            pid = _positive_integer(process["pid"], label=f"installed Task10 {role} PID")
            _nonnegative_integer(
                process["start_time_unix_us"],
                label=f"installed Task10 {role} process start",
            )
            if pid in observed_pids:
                fail("installed Task10 network process PIDs are not globally unique")
            observed_pids.add(pid)
    if observed_roles != expected_roles or not observed_pids:
        fail("installed Task10 network report omitted a role or process authority")

    observer = _closed_mapping(
        audit_document["observer"],
        TASK10_NETWORK_OBSERVER_FIELDS,
        label="installed Task10 network observer",
    )
    sample_count = _positive_integer(
        observer["observed_sample_count"],
        label="installed Task10 network sample count",
    )
    process_row_count = _nonnegative_integer(
        observer["observed_process_row_count"],
        label="installed Task10 network process-row count",
    )
    interval_started = _nonnegative_integer(
        observer["continuous_interval_started_at_unix_ms"],
        label="installed Task10 network interval start",
    )
    interval_ready = _nonnegative_integer(
        observer["continuous_interval_ready_at_unix_ms"],
        label="installed Task10 network interval readiness",
    )
    interval_ended = _nonnegative_integer(
        observer["continuous_interval_ended_at_unix_ms"],
        label="installed Task10 network interval end",
    )
    try:
        attribution = _closed_mapping(audit_document["attribution"], frozenset({
            "policy_id", "observer_spawn_ns", "observer_eof_ns", "queue_closed_ns", "proofs", "drains"
        }), label="installed Task10 network attribution")
        if attribution["policy_id"] != network_attribution.PROOF_KIND:
            fail("installed Task10 attribution policy differs")
        foreign_pids = network_attribution.validate_foreign_proofs(
            attribution["proofs"], attribution["drains"],
            observer_spawn_ns=attribution["observer_spawn_ns"],
            observer_eof_ns=attribution["observer_eof_ns"],
            queue_closed_ns=attribution["queue_closed_ns"],
            candidate_paths=tuple(expected_paths.values()),
        )
        summary = network_audit.classify_matrix_observation(
            observation.payload, candidate_pids=frozenset(observed_pids), foreign_pids=foreign_pids
        )
    except (network_audit.AuditInputError, network_attribution.NetworkAttributionError) as error:
        fail(f"installed Task10 network observation is invalid: {error}")
    if (
        observer["observer_id"] != network_audit.MATRIX_OBSERVER_ID
        or observer["evidence_scope"] != network_audit.MATRIX_EVIDENCE_SCOPE
        or observer["limitations"] != list(network_audit.MATRIX_LIMITATIONS)
        or observer["availability"] != "available"
        or observer["interface_scope"] != ["external", "undefined"]
        or observer["loopback_excluded"] is not True
        or observer["observer_invocation_count"] != 1
        or observer["continuity_proven"] is not True
        or observer["readiness_proven"] is not True
        or observer["stopped_by_auditor"] is not True
        or observer["observation_byte_count"] != len(observation.payload)
        or observer["observation_sha256"] != observation.sha256
        or summary.sample_count != sample_count
        or summary.process_row_count != process_row_count
        or any(type(observer[field]) is not int or observer[field] != expected
               for field, expected in (("observed_candidate_row_count", summary.candidate_row_count),
                                       ("observed_foreign_row_count", summary.foreign_row_count),
                                       ("observed_unresolved_row_count", summary.unresolved_row_count)))
        or summary.candidate_row_count != 0
        or summary.unresolved_row_count != 0
        or interval_ready != observer_ready
        or not (interval_started <= interval_ready <= workload_started)
        or interval_ended < workload_ended
        or not is_sha256(observer["tool_sha256"])
        or not is_sha256(observer["readiness_frame_sha256"])
    ):
        fail("installed Task10 network observer does not prove the declared sampled-state interval")
    report_started = _nonnegative_integer(
        audit_document["started_at_unix_ms"],
        label="installed Task10 network report start",
    )
    report_ended = _nonnegative_integer(
        audit_document["ended_at_unix_ms"],
        label="installed Task10 network report end",
    )
    if not (report_started <= workload_started < workload_ended <= report_ended):
        fail("installed Task10 network report does not enclose the matrix workload")

    execution_value = _decode_canonical(
        execution_report.payload, label="installed Task10 network execution report"
    )
    execution_document = _closed_mapping(
        execution_value,
        TASK10_EXECUTION_REPORT_FIELDS,
        label="installed Task10 network execution report",
    )
    execution_run = _closed_mapping(
        execution_document["qualification_run"],
        TRANSACTION_RESULT_RUN_FIELDS,
        label="installed Task10 network execution qualification run",
    )
    if (
        execution_document["schema_version"] != 2
        or execution_run
        != {"run_id": qualification_run.run_id, "nonce": qualification_run.nonce}
        or execution_document["predecessor_observations_sha256"]
        != transaction["predecessor_observations_sha256"]
        or execution_document["started_at_unix_ms"] != report_started
        or execution_document["ended_at_unix_ms"] != report_ended
        or execution_document["result"] != "passed"
        or execution_document["exit_code"] != 0
        or execution_document["stress"] is not None
    ):
        fail("installed Task10 network execution report is not the bound passing authority")

    incremental_value = _decode_canonical(
        incremental_evidence.payload, label="installed Task10 incremental evidence"
    )
    incremental_document = _closed_mapping(
        incremental_value,
        frozenset({"evidence"}),
        label="installed Task10 incremental evidence",
    )
    items = incremental_document["evidence"]
    if not isinstance(items, list) or len(items) != 1:
        fail("installed Task10 incremental evidence must contain exactly one item")
    entry = _closed_mapping(
        items[0],
        frozenset({"gate", "proofArtifacts"}),
        label="installed Task10 incremental evidence item",
    )
    expected_artifacts = (
        (
            installed_matrix_receipt.PROOF_ARTIFACT_KIND,
            matrix_receipt.path,
            matrix_receipt.sha256,
        ),
        (TASK10_NETWORK_EXECUTION_ARTIFACT_KIND, execution_report.path, execution_report.sha256),
        (TASK10_NETWORK_OBSERVATION_ARTIFACT_KIND, observation.path, observation.sha256),
        (TASK10_NETWORK_REPORT_ARTIFACT_KIND, audit_report.path, audit_report.sha256),
        (TASK10_SEMANTIC_ARTIFACT_KIND, semantic_manifest.path, semantic_manifest.sha256),
        ("xcresult", xcresult.path, None),
    )
    artifacts = entry["proofArtifacts"]
    if entry["gate"] != "incremental-xcuitest" or not isinstance(artifacts, list) or len(artifacts) != 6:
        fail("installed Task10 incremental descriptor is not the exact six-artifact gate record")
    for index, (artifact_value, expected) in enumerate(zip(artifacts, expected_artifacts)):
        kind, path, digest = expected
        fields = frozenset({"kind", "path"}) if digest is None else frozenset({"kind", "path", "sha256"})
        artifact = _closed_mapping(
            artifact_value,
            fields,
            label=f"installed Task10 incremental artifact {index}",
        )
        if (
            artifact["kind"] != kind
            or artifact["path"] != str(path)
            or (digest is not None and artifact["sha256"] != digest)
        ):
            fail(f"installed Task10 incremental artifact {index} is substituted")

    return InstalledTask10Authority(
        document=dict(record),
        matrix_receipt=matrix_receipt,
        matrix_receipt_document=matrix_document,
        xcresult=xcresult,
        semantic_manifest=semantic_manifest,
        semantic_document=semantic_document,
        network_root=network_root,
        network_root_metadata=network_root_metadata,
        audit_report=audit_report,
        audit_document=audit_document,
        execution_report=execution_report,
        execution_document=execution_document,
        observation=observation,
        incremental_evidence=incremental_evidence,
        incremental_document=incremental_document,
    )


def _validate_transaction_result(
    path: Path,
    *,
    candidate_artifact_root: Path,
    qualification_run_root: Path,
) -> TransactionResultAuthority:
    result_file = _read_stable_file(
        path,
        maximum_bytes=MAX_TRANSACTION_RESULT_BYTES,
        label="transaction result",
    )
    if (
        result_file.path.name != "InstalledAcceptanceTransaction.result.json"
        or result_file.metadata[2] != 0o600
    ):
        fail("transaction result filename or private mode differs from the frozen contract")
    work_root = _canonical_directory(result_file.path.parent, label="transaction work-root")
    _require_disjoint(
        work_root,
        candidate_artifact_root,
        label="transaction work-root and candidate artifact root",
    )
    _require_disjoint(
        work_root,
        REPOSITORY_ROOT,
        label="transaction work-root and repository root",
    )
    result_value = _decode_canonical(result_file.payload, label="transaction result")
    result = _closed_mapping(
        result_value,
        TRANSACTION_RESULT_FIELDS,
        label="transaction result",
    )
    if (
        result.get("schema_version") != 1
        or result.get("result_kind") != TRANSACTION_RESULT_KIND
        or result.get("result") != "passed"
        or result.get("rolled_back") is not False
        or result.get("transaction_phase") != "committed"
    ):
        fail("transaction result is not one passing committed schema-1 authority")
    produced_at = _positive_integer(
        result.get("produced_at_unix_ns"),
        label="transaction result production time",
    )

    candidate = _closed_mapping(
        result.get("candidate"),
        TRANSACTION_RESULT_CANDIDATE_FIELDS,
        label="transaction result candidate",
    )
    artifact_root = _path_string(
        candidate.get("artifact_root"),
        label="transaction result candidate artifact root",
    )
    if artifact_root != candidate_artifact_root:
        fail("transaction result candidate artifact root differs from --candidate-artifact-root")
    for field in (
        "identity_sha256",
        "identity_file_sha256",
        "provenance_sha256",
        "application_executable_sha256",
    ):
        _sha256_string(candidate.get(field), label=f"transaction result candidate {field}")
    for field in ("source_commit", "source_tree"):
        if not isinstance(candidate.get(field), str) or not is_git_object(candidate[field]):
            fail(f"transaction result candidate {field} is not a Git object identity")
    identity_path = _path_string(
        candidate.get("identity_path"), label="transaction result candidate identity path"
    )
    provenance_path = _path_string(
        candidate.get("provenance_path"),
        label="transaction result candidate provenance path",
    )
    source_app_path = _path_string(
        candidate.get("source_app_path"),
        label="transaction result candidate app path",
    )
    if identity_path != artifact_root / "candidate.json":
        fail("transaction result must bind the governed candidate.json")
    _require_descendant(identity_path, artifact_root, label="candidate identity")
    expected_source_app = (
        qualification_run_root
        / "DerivedData"
        / "Build"
        / "Products"
        / "Release"
        / "MacScope.app"
    )
    if source_app_path != expected_source_app:
        fail(
            "transaction result candidate source app differs from the "
            "qualified Release product"
        )
    _canonical_directory(source_app_path, label="transaction result candidate source app")
    if provenance_path != source_app_path / installer.BUILD_PROVENANCE_RELATIVE_PATH:
        fail("transaction result candidate provenance path differs from the source app")

    run_value = _closed_mapping(
        result.get("qualification_run"),
        TRANSACTION_RESULT_RUN_FIELDS,
        label="transaction result qualification run",
    )
    if not isinstance(run_value.get("run_id"), str) or not isinstance(
        run_value.get("nonce"), str
    ):
        fail("transaction result qualification run fields must be strings")
    qualification_run = _validate_run_authority(run_value["run_id"], run_value["nonce"])

    transaction = _closed_mapping(
        result.get("transaction"),
        TRANSACTION_RESULT_TRANSACTION_FIELDS,
        label="transaction result transaction",
    )
    for field in (
        "transaction_id",
        "transaction_nonce",
        "candidate_identity_sha256",
        "candidate_file_sha256",
        "application_executable_sha256",
        "build_provenance_sha256",
        "source_equality_sha256",
        "execution_identity_sha256",
        "destination_identity_sha256",
        "predecessor_digest",
        "predecessor_observations_sha256",
    ):
        _sha256_string(transaction.get(field), label=f"transaction result {field}")
    for field in ("source_commit", "source_tree"):
        if not isinstance(transaction.get(field), str) or not is_git_object(
            transaction[field]
        ):
            fail(f"transaction result {field} is not a Git object identity")
    began_at = _positive_integer(
        transaction.get("began_at_unix_ns"),
        label="transaction begin time",
    )
    exposed_at = _positive_integer(
        transaction.get("exposed_at_unix_ns"),
        label="transaction exposure time",
    )
    if began_at > exposed_at or exposed_at > produced_at:
        fail("transaction result timestamps are out of predecessor order")

    evidence_root = _canonical_directory(
        work_root / PLAN_EVIDENCE_DIRECTORY_NAME,
        label="installed acceptance evidence root",
    )

    pending_state = _closed_mapping(
        result.get("pending_state"),
        TRANSACTION_RESULT_PENDING_FIELDS,
        label="transaction result pending state",
    )
    begin_path = _path_string(
        pending_state.get("path_at_begin"),
        label="transaction result pending state begin path",
    )
    pending_terminal_path = _path_string(
        pending_state.get("terminal_path"),
        label="transaction result pending state terminal path",
    )
    pending_sha256 = _sha256_string(
        pending_state.get("sha256"),
        label="transaction result pending state SHA-256",
    )

    terminal_state = _read_manifest_file(
        result.get("terminal_committed_state"),
        maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        label="terminal committed transaction state",
    )
    terminal_record = result["terminal_committed_state"]
    if (
        pending_terminal_path != terminal_state.path
        or pending_sha256 != terminal_state.sha256
        or terminal_record["sha256"] != pending_sha256
    ):
        fail("pending-state rename seam does not bind one surviving file and digest")
    expected_begin = terminal_state.path.parent.parent / (
        f".MacScope.pending-{transaction['candidate_identity_sha256']}"
    ) / "transaction.json"
    expected_terminal_root = terminal_state.path.parent.parent / (
        ".MacScope.committed-"
        f"{transaction['candidate_identity_sha256']}-{transaction['transaction_id']}"
    )
    if begin_path != expected_begin or terminal_state.path.parent != expected_terminal_root:
        fail("pending/terminal transaction paths do not encode the bound identities")
    if os.path.lexists(begin_path):
        fail("historical pending-state path still exists after committed rename")

    gate_plan = _read_manifest_file(
        result.get("gate_plan"),
        maximum_bytes=MAX_GATE_PLAN_BYTES,
        label="compiled acceptance gate plan",
    )
    if gate_plan.path != (
        work_root / PLAN_EVIDENCE_DIRECTORY_NAME / "InstalledAcceptanceGate.plan.json"
    ):
        fail("compiled acceptance gate plan path differs from its governed work-root subpath")
    (
        gate_plan_document,
        native_preparation_receipt,
        native_xctestrun,
        gate_output_files,
    ) = _validate_gate_plan_structure(
        gate_plan,
        candidate_artifact_root=artifact_root,
        work_root=work_root,
    )
    installed_task10 = _validate_installed_task10(
        result.get("installed_task10"), evidence_root=evidence_root, candidate=candidate,
        transaction=transaction, qualification_run=qualification_run,
        installed_app=_path_string(gate_plan_document["authority"]["installed_app_path"],
                                   label="admitted installed app"),
    )

    envelope_values = result.get("gate_envelopes")
    if not isinstance(envelope_values, list) or len(envelope_values) != 8:
        fail("transaction result must reference exactly eight gate envelopes")
    envelope_rows: list[tuple[str, StableFile]] = []
    envelope_documents: dict[str, dict[str, Any]] = {}
    observed_gate_ids: list[str] = []
    for index, item in enumerate(envelope_values):
        record = _closed_mapping(
            item,
            TRANSACTION_RESULT_GATE_FIELDS,
            label=f"transaction result gate envelope {index}",
        )
        gate_id = record.get("gate_id")
        if not isinstance(gate_id, str):
            fail("transaction result gate envelope ID must be a string")
        expected_sha256 = _sha256_string(
            record.get("sha256"),
            label=f"transaction result gate envelope {gate_id} SHA-256",
        )
        envelope_path = _path_string(
            record.get("path"),
            label=f"transaction result gate envelope {gate_id} path",
        )
        expected_envelope_path = (
            work_root
            / WS24_EVIDENCE_DIRECTORY_NAME
            / f"{gate_id}.acceptance-gate.json"
        )
        if envelope_path != expected_envelope_path:
            fail(f"gate envelope {gate_id} path differs from its governed work-root subpath")
        envelope = _read_stable_file(
            envelope_path,
            maximum_bytes=installer.MAX_ACCEPTANCE_GATE_INPUT_BYTES,
            label=f"acceptance gate input {gate_id}",
        )
        if envelope.sha256 != expected_sha256:
            fail(f"acceptance gate input {gate_id} differs from the transaction result")
        envelope_value = _decode_canonical(
            envelope.payload,
            label=f"acceptance gate input {gate_id}",
        )
        envelope_document = _closed_mapping(
            envelope_value,
            installer.ACCEPTANCE_GATE_INPUT_FIELDS,
            label=f"acceptance gate input {gate_id}",
        )
        if (
            envelope_document.get("schema_version")
            != installer.ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION
            or envelope_document.get("input_kind")
            != installer.ACCEPTANCE_GATE_INPUT_KIND
            or envelope_document.get("gate_id") != gate_id
            or envelope_document.get("result") != "passed"
            or envelope_document.get("rolled_back") is not False
            or envelope_document.get("transaction_phase") != "pending"
        ):
            fail(f"acceptance gate input {gate_id} result or identity differs")
        envelope_bindings = {
            "application_executable_sha256": transaction[
                "application_executable_sha256"
            ],
            "build_provenance_sha256": transaction["build_provenance_sha256"],
            "candidate_file_sha256": transaction["candidate_file_sha256"],
            "candidate_identity_sha256": transaction["candidate_identity_sha256"],
            "destination_identity_sha256": transaction[
                "destination_identity_sha256"
            ],
            "execution_identity_sha256": transaction["execution_identity_sha256"],
            "qualification_run_id": qualification_run.run_id,
            "qualification_run_nonce": qualification_run.nonce,
            "source_commit": transaction["source_commit"],
            "source_equality_sha256": transaction["source_equality_sha256"],
            "source_tree": transaction["source_tree"],
            "transaction_id": transaction["transaction_id"],
            "transaction_nonce": transaction["transaction_nonce"],
        }
        for field, expected in envelope_bindings.items():
            if envelope_document.get(field) != expected:
                fail(f"acceptance gate input {gate_id} {field} differs")
        started_at = _positive_integer(
            envelope_document.get("started_at_unix_ns"),
            label=f"acceptance gate input {gate_id} start time",
        )
        ended_at = _positive_integer(
            envelope_document.get("ended_at_unix_ns"),
            label=f"acceptance gate input {gate_id} end time",
        )
        if started_at < exposed_at or ended_at < started_at:
            fail(f"acceptance gate input {gate_id} is stale")
        _sha256_string(
            envelope_document.get("evidence_sha256"),
            label=f"acceptance gate input {gate_id} evidence SHA-256",
        )
        observed_gate_ids.append(gate_id)
        envelope_documents[gate_id] = envelope_document
        envelope_rows.append((gate_id, envelope))
    if tuple(observed_gate_ids) != installer.REQUIRED_ACCEPTANCE_GATES:
        fail("gate envelopes must contain the eight distinct IDs in canonical order")
    if len({snapshot.sha256 for _gate_id, snapshot in envelope_rows}) != 8:
        fail("gate envelopes must have eight distinct canonical input hashes")

    acceptance_receipt = _read_manifest_file(
        result.get("acceptance_receipt"),
        maximum_bytes=installer.MAX_ACCEPTANCE_RECEIPT_BYTES,
        label="MacScopeInstaller acceptance receipt",
    )
    expected_acceptance = (
        work_root
        / INSTALLER_ARTIFACT_DIRECTORY_NAME
        / installer.ACCEPTANCE_RECEIPT_NAME
    )
    if acceptance_receipt.path != expected_acceptance:
        fail("MacScopeInstaller acceptance receipt path differs from its governed work-root subpath")
    commit_authority = _read_manifest_file(
        result.get("commit_authority"),
        maximum_bytes=installer.MAX_COMMIT_AUTHORITY_BYTES,
        label="installer commit authority",
    )
    if commit_authority.path != terminal_state.path.parent / installer.COMMIT_AUTHORITY_NAME:
        fail("installer commit authority is outside the committed terminal root")

    ws24_root = _canonical_directory(
        work_root / WS24_EVIDENCE_DIRECTORY_NAME,
        label="WS24 qualification evidence root",
    )
    ws24_aggregate = _read_stable_file(
        ws24_root / WS24_AGGREGATE_NAME,
        maximum_bytes=8 * 1024 * 1024,
        label="WS24 installed qualification aggregate",
    )
    ws24_value = _decode_canonical(
        ws24_aggregate.payload,
        label="WS24 installed qualification aggregate",
    )
    outputs_by_gate = dict(gate_output_files)
    cli_gui_report = outputs_by_gate["cli"]
    mcp_report = outputs_by_gate["mcp"]
    cli_gui_document = _validate_operability_report(
        cli_gui_report,
        label="CLI/GUI operability report",
        report_kind="macscope-cli-gui-operability-report-v1",
        probe_fields=frozenset({"cli", "gui"}),
        transaction=transaction,
        pending_state_sha256=pending_sha256,
        qualification_run_id=qualification_run.run_id,
        outputs_by_gate=outputs_by_gate,
    )
    mcp_document = _validate_operability_report(
        mcp_report,
        label="MCP operability report",
        report_kind="macscope-mcp-operability-report-v1",
        probe_fields=frozenset({"initialize", "readOnlyInfo", "toolsList"}),
        transaction=transaction,
        pending_state_sha256=pending_sha256,
        qualification_run_id=qualification_run.run_id,
        outputs_by_gate=outputs_by_gate,
    )
    ws24_document = _validate_ws24_aggregate(
        ws24_value,
        transaction=transaction,
        cli_gui_report=cli_gui_report,
        cli_gui_document=cli_gui_document,
        mcp_report=mcp_report,
        mcp_document=mcp_document,
        live_evidence_manifest=outputs_by_gate["shellbroker-launchagent"],
    )
    if (
        ws24_document["generatedAtUnixMilliseconds"] * 1_000_000
        > produced_at
    ):
        fail("transaction result predates WS24 aggregate generation")
    gate_evidence_files = (
        ("cli", cli_gui_report),
        ("forced-legacy-grid", outputs_by_gate["forced-legacy-grid"]),
        ("full-surface", outputs_by_gate["full-surface"]),
        ("gui", cli_gui_report),
        ("mcp", mcp_report),
        ("native-xpc", outputs_by_gate["native-xpc"]),
        ("shellbroker-launchagent", ws24_aggregate),
        ("signing", ws24_aggregate),
    )
    for gate_id, evidence_file in gate_evidence_files:
        if envelope_documents[gate_id]["evidence_sha256"] != evidence_file.sha256:
            fail(f"acceptance gate {gate_id} evidence digest differs from its governed evidence")

    output_by_gate = dict(gate_output_files)
    envelope_by_gate = dict(envelope_rows)
    if gate_plan.mtime_ns < exposed_at:
        fail("compiled gate plan predates candidate exposure")
    for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
        if (
            output_by_gate[gate_id].mtime_ns < gate_plan.mtime_ns
            or output_by_gate[gate_id].mtime_ns < exposed_at
        ):
            fail(f"gate output {gate_id} predates its compiled plan")
        if envelope_by_gate[gate_id].mtime_ns < output_by_gate[gate_id].mtime_ns:
            fail(f"acceptance gate envelope {gate_id} predates its primary output")
    for gate_id, evidence_file in gate_evidence_files:
        if envelope_by_gate[gate_id].mtime_ns < evidence_file.mtime_ns:
            fail(f"acceptance gate envelope {gate_id} predates its governed evidence")
    if acceptance_receipt.mtime_ns < max(
        envelope.mtime_ns for envelope in envelope_by_gate.values()
    ):
        fail("acceptance receipt predates its gate-envelope predecessor chain")
    if commit_authority.mtime_ns < acceptance_receipt.mtime_ns:
        fail("commit authority predates its acceptance predecessor")
    if result_file.mtime_ns < commit_authority.mtime_ns:
        fail("transaction result predates its terminal commit authority")
    if result_file.mtime_ns < max(
        snapshot.mtime_ns
        for snapshot in (
            installed_task10.matrix_receipt,
            installed_task10.semantic_manifest,
            installed_task10.audit_report,
            installed_task10.execution_report,
            installed_task10.observation,
            installed_task10.incremental_evidence,
        )
    ):
        fail("transaction result predates its installed Task10 prerequisite")

    live_files = (
        result_file,
        installed_task10.matrix_receipt,
        installed_task10.semantic_manifest,
        installed_task10.audit_report,
        installed_task10.execution_report,
        installed_task10.observation,
        installed_task10.incremental_evidence,
        gate_plan,
        native_preparation_receipt,
        native_xctestrun,
        *(
            snapshot
            for gate_id, snapshot in gate_output_files
            if gate_id != "signing"
        ),
        ws24_aggregate,
        *(snapshot for _gate_id, snapshot in envelope_rows),
        acceptance_receipt,
        terminal_state,
        commit_authority,
    )
    private_files = (
        result_file,
        installed_task10.matrix_receipt,
        installed_task10.semantic_manifest,
        installed_task10.audit_report,
        installed_task10.execution_report,
        installed_task10.observation,
        installed_task10.incremental_evidence,
        gate_plan,
        native_preparation_receipt,
        *(
            snapshot
            for gate_id, snapshot in gate_output_files
            if gate_id != "signing"
        ),
        ws24_aggregate,
        *(snapshot for _gate_id, snapshot in envelope_rows),
        acceptance_receipt,
        terminal_state,
        commit_authority,
    )
    if any(snapshot.metadata[2] != 0o600 for snapshot in private_files):
        fail("transaction-result JSON authorities and outputs must have mode 0600")
    if len({item.metadata[:2] for item in live_files}) != len(live_files):
        fail("transaction-result artifacts must be physically distinct files")

    return TransactionResultAuthority(
        document=result,
        result_file=result_file,
        candidate=candidate,
        qualification_run=qualification_run,
        transaction=transaction,
        pending_state=pending_state,
        installed_task10=installed_task10,
        gate_plan=gate_plan,
        gate_plan_document=gate_plan_document,
        native_preparation_receipt=native_preparation_receipt,
        native_xctestrun=native_xctestrun,
        gate_output_files=gate_output_files,
        gate_evidence_files=gate_evidence_files,
        ws24_aggregate=ws24_aggregate,
        gate_envelopes=tuple(envelope_rows),
        acceptance_receipt=acceptance_receipt,
        terminal_state=terminal_state,
        commit_authority=commit_authority,
    )


def _validate_result_bindings(
    result: TransactionResultAuthority,
    *,
    qualification_authority: QualificationAuthority,
    candidate: CandidateAuthority,
    installation: InstallationAuthority,
    candidate_artifact_root: Path,
) -> None:
    state = installation.state
    candidate_document = result.candidate
    semantic_candidate_sha256 = candidate_identity_sha256(candidate.candidate)
    expected_candidate = {
        "artifact_root": str(candidate_artifact_root),
        "identity_path": str(candidate.identity.path),
        "identity_sha256": semantic_candidate_sha256,
        "identity_file_sha256": candidate.identity.sha256,
        "provenance_path": str(candidate.provenance.path),
        "provenance_sha256": candidate.provenance.sha256,
        "source_app_path": str(candidate.source_app),
        "source_commit": candidate.candidate.source.commit,
        "source_tree": candidate.candidate.source.tree,
        "application_executable_sha256": candidate.candidate.application.executable_sha256,
    }
    if candidate_document != expected_candidate:
        fail("transaction result candidate identity/provenance binding differs")

    destination_identity_sha256 = _sha256(canonical_bytes(state["destination_identity"]))
    expected_transaction = {
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "application_executable_sha256": state["application_executable_sha256"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "source_commit": state["source_commit"],
        "source_tree": state["source_tree"],
        "source_equality_sha256": state["source_equality_sha256"],
        "execution_identity_sha256": state["execution_identity_sha256"],
        "destination_identity_sha256": destination_identity_sha256,
        "predecessor_digest": state["predecessor_digest"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "began_at_unix_ns": state["began_at_unix_ns"],
        "exposed_at_unix_ns": state["exposed_at_unix_ns"],
    }
    if result.transaction != expected_transaction:
        fail("transaction result does not exactly bind the terminal transaction state")
    state_artifact_value = state.get("artifact_root")
    if not isinstance(state_artifact_value, str):
        fail("terminal transaction artifact root is malformed")
    state_artifact_root = _canonical_directory(
        Path(state_artifact_value),
        label="installer artifact root",
    )
    work_root = result.result_file.path.parent
    try:
        state_artifact_root.relative_to(work_root)
    except ValueError:
        fail("installer artifact root must be contained by transaction work-root")
    if installation.acceptance_receipt.path != (
        state_artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
    ):
        fail("acceptance receipt is outside the governed installer artifact root")
    _require_disjoint(
        work_root,
        candidate.source_app,
        label="transaction work-root and candidate source app",
    )
    _require_disjoint(
        work_root,
        installation.installed_app,
        label="transaction work-root and installed destination",
    )
    _require_disjoint(
        work_root,
        qualification_authority.receipt.path,
        label="transaction work-root and qualification receipt",
    )
    try:
        preparation_document = native_preparation.load_receipt(
            result.native_preparation_receipt.path
        )
        preparation_sha256 = native_preparation.validate_prepared(
            preparation_document,
            result.native_xctestrun.path,
            candidate.source_app,
            candidate.identity.path,
        )
    except (OSError, native_preparation.PreparationReceiptError) as error:
        fail(f"native preparation authority is invalid: {error}")
    if preparation_sha256 != result.native_preparation_receipt.sha256:
        fail("native preparation semantic digest differs from its exact bytes")
    _require_unchanged(
        result.native_preparation_receipt,
        label="native preparation receipt",
    )
    _require_unchanged(result.native_xctestrun, label="native xctestrun")

    plan_authority = result.gate_plan_document["authority"]
    expected_plan_authority = {
        "application_executable_sha256": state["application_executable_sha256"],
        "artifact_root_identity_sha256": _sha256(
            canonical_bytes(state["artifact_root_identity"])
        ),
        "artifact_root_path": str(state_artifact_root),
        "began_at_unix_ns": state["began_at_unix_ns"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "candidate_identity_path": str(candidate.identity.path),
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity_sha256": destination_identity_sha256,
        "execution_identity_sha256": state["execution_identity_sha256"],
        "exposed_at_unix_ns": state["exposed_at_unix_ns"],
        "installed_app_path": state["installed_app_path"],
        "installed_task10_incremental_evidence_path": str(
            result.installed_task10.incremental_evidence.path
        ),
        "installed_task10_matrix_receipt_path": str(
            result.installed_task10.matrix_receipt.path
        ),
        "installed_task10_network_artifact_root": str(
            result.installed_task10.network_root
        ),
        "installed_task10_xcresult_path": str(result.installed_task10.xcresult.path),
        "installed_task10_xcresult_semantic_manifest_path": str(
            result.installed_task10.semantic_manifest.path
        ),
        "installed_ui_preparation_receipt_path": plan_authority[
            "installed_ui_preparation_receipt_path"
        ],
        "installed_ui_preparation_receipt_sha256": plan_authority[
            "installed_ui_preparation_receipt_sha256"
        ],
        "installed_ui_runner_closed_tree_sha256": plan_authority[
            "installed_ui_runner_closed_tree_sha256"
        ],
        "installed_ui_runner_executable_sha256": plan_authority[
            "installed_ui_runner_executable_sha256"
        ],
        "installed_ui_runner_path": plan_authority["installed_ui_runner_path"],
        "installed_ui_test_bundle_closed_tree_sha256": plan_authority[
            "installed_ui_test_bundle_closed_tree_sha256"
        ],
        "installed_ui_test_bundle_executable_sha256": plan_authority[
            "installed_ui_test_bundle_executable_sha256"
        ],
        "installed_ui_test_bundle_path": plan_authority[
            "installed_ui_test_bundle_path"
        ],
        "installed_ui_xctestrun_path": plan_authority[
            "installed_ui_xctestrun_path"
        ],
        "installed_ui_xctestrun_sha256": plan_authority[
            "installed_ui_xctestrun_sha256"
        ],
        "native_preparation_receipt_path": str(
            result.native_preparation_receipt.path
        ),
        "native_preparation_receipt_sha256": result.native_preparation_receipt.sha256,
        "native_xctestrun_path": str(result.native_xctestrun.path),
        "native_xctestrun_sha256": result.native_xctestrun.sha256,
        "pending_state_path": result.pending_state["path_at_begin"],
        "pending_state_sha256": result.pending_state["sha256"],
        "predecessor_digest": state["predecessor_digest"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "qualification_receipt_path": str(qualification_authority.receipt.path),
        "qualification_receipt_sha256": qualification_authority.receipt.sha256,
        "qualification_run_id": result.qualification_run.run_id,
        "qualification_run_nonce": result.qualification_run.nonce,
        "source_app_path": str(candidate.source_app),
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
    }
    if plan_authority != expected_plan_authority:
        fail("compiled gate plan authority differs from the reopened closure")

    if (
        result.terminal_state.metadata != installation.state_file.metadata
        or result.terminal_state.payload != installation.state_file.payload
        or result.acceptance_receipt.metadata != installation.acceptance_receipt.metadata
        or result.acceptance_receipt.payload != installation.acceptance_receipt.payload
        or result.commit_authority.metadata != installation.commit_authority.metadata
        or result.commit_authority.payload != installation.commit_authority.payload
    ):
        fail("transaction result paths changed across independent semantic validation")
    result_gates = dict(result.gate_envelopes)
    installation_gates = dict(installation.gate_files)
    if tuple(result_gates) != installer.REQUIRED_ACCEPTANCE_GATES:
        fail("transaction result gate-envelope order changed")
    for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
        if (
            result_gates[gate_id].metadata != installation_gates[gate_id].metadata
            or result_gates[gate_id].payload != installation_gates[gate_id].payload
        ):
            fail(f"acceptance gate input {gate_id} changed across validation")

    produced_at = int(result.document["produced_at_unix_ns"])
    acceptance_produced_at = installation.acceptance_document["produced_at_unix_ns"]
    if produced_at < acceptance_produced_at:
        fail("transaction result predates the acceptance receipt")
    if (
        result.result_file.ctime_ns < installation.commit_authority.ctime_ns
        or result.result_file.ctime_ns < installation.state_file.ctime_ns
    ):
        fail("transaction result file predates terminal commit authority")
    plan_outputs = dict(result.gate_output_files)
    gate_envelopes = dict(result.gate_envelopes)
    for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
        if plan_outputs[gate_id].ctime_ns < result.gate_plan.ctime_ns:
            fail(f"gate output {gate_id} predates its compiled plan")
        if gate_envelopes[gate_id].ctime_ns < plan_outputs[gate_id].ctime_ns:
            fail(f"acceptance gate envelope {gate_id} predates its primary output")


def validate_inputs(
    arguments: argparse.Namespace,
    *,
    allow_test_destination: bool = False,
) -> Closure:
    candidate_artifact_root = _canonical_directory(
        arguments.candidate_artifact_root,
        label="candidate artifact root",
    )
    if candidate_artifact_root.name != "candidate-artifacts":
        fail("candidate artifact root is not the governed qualification artifact root")
    transaction_result = _validate_transaction_result(
        arguments.transaction_result,
        candidate_artifact_root=candidate_artifact_root,
        qualification_run_root=candidate_artifact_root.parent,
    )
    local_ref = _resolve_local_ref(REPOSITORY_ROOT, arguments.integration_ref)
    if (
        transaction_result.candidate["source_commit"] != local_ref.commit
        or transaction_result.candidate["source_tree"] != local_ref.tree
        or transaction_result.transaction["source_commit"] != local_ref.commit
        or transaction_result.transaction["source_tree"] != local_ref.tree
    ):
        fail("transaction result source identity differs from the exact local integration ref")
    qualification_authority = _validate_qualification(
        arguments.qualification_receipt,
        local_ref=local_ref,
    )
    if (
        candidate_artifact_root
        != qualification_authority.validated.run_root / "candidate-artifacts"
    ):
        fail("candidate artifact root is not owned by the exact qualification run")
    candidate = _validate_candidate(
        Path(transaction_result.candidate["identity_path"]),
        Path(transaction_result.candidate["provenance_path"]),
        local_ref=local_ref,
    )
    installation = _validate_installation(
        transaction_result.terminal_state.path,
        transaction_result.acceptance_receipt.path,
        tuple(
            f"{gate_id}={snapshot.path}"
            for gate_id, snapshot in transaction_result.gate_envelopes
        ),
        candidate=candidate,
        qualification_authority=qualification_authority,
        qualification_run=transaction_result.qualification_run,
        allow_test_destination=allow_test_destination,
    )
    _validate_result_bindings(
        transaction_result,
        qualification_authority=qualification_authority,
        candidate=candidate,
        installation=installation,
        candidate_artifact_root=candidate_artifact_root,
    )
    input_files = (
        transaction_result.result_file,
        qualification_authority.receipt,
        qualification_authority.coverage,
        candidate.identity,
        candidate.provenance,
        installation.state_file,
        installation.acceptance_receipt,
        installation.commit_authority,
        transaction_result.gate_plan,
        transaction_result.native_preparation_receipt,
        transaction_result.native_xctestrun,
        transaction_result.installed_task10.matrix_receipt,
        transaction_result.installed_task10.semantic_manifest,
        transaction_result.installed_task10.audit_report,
        transaction_result.installed_task10.execution_report,
        transaction_result.installed_task10.observation,
        transaction_result.installed_task10.incremental_evidence,
        *(
            snapshot
            for gate_id, snapshot in transaction_result.gate_output_files
            if gate_id != "signing"
        ),
        transaction_result.ws24_aggregate,
        *(snapshot for _gate_id, snapshot in installation.gate_files),
    )
    if len({(item.metadata[0], item.metadata[1]) for item in input_files}) != len(input_files):
        fail("final candidate inputs must be physically distinct single-link files")
    return Closure(
        local_ref=local_ref,
        qualification=qualification_authority,
        candidate=candidate,
        installation=installation,
        qualification_run=transaction_result.qualification_run,
        transaction_result=transaction_result,
        input_files=input_files,
    )


def _receipt_document(closure: Closure, *, produced_at_unix_ns: int) -> dict[str, object]:
    state = closure.installation.state
    candidate = closure.candidate.candidate
    gates_by_id = dict(closure.installation.gate_files)
    outputs_by_id = dict(closure.transaction_result.gate_output_files)
    evidence_by_id = dict(closure.transaction_result.gate_evidence_files)
    gate_rows = []
    for gate_id in installer.REQUIRED_ACCEPTANCE_GATES:
        record = closure.installation.gate_records[gate_id]
        gate_rows.append(
            {
                "ended_at_unix_ns": record["ended_at_unix_ns"],
                "evidence_path": str(evidence_by_id[gate_id].path),
                "evidence_sha256": record["evidence_sha256"],
                "gate_id": gate_id,
                "input_path": str(gates_by_id[gate_id].path),
                "input_sha256": record["input_sha256"],
                "primary_output_path": str(outputs_by_id[gate_id].path),
                "primary_output_sha256": outputs_by_id[gate_id].sha256,
                "result": "passed",
                "started_at_unix_ns": record["started_at_unix_ns"],
            }
        )
    return {
        "acceptance_gates": gate_rows,
        "candidate": {
            "application_bundle_sha256": candidate.application.bundle_sha256,
            "application_closed_tree_sha256": candidate.application.closed_tree_sha256,
            "application_executable_sha256": candidate.application.executable_sha256,
            "application_root_mode": candidate.application.root_mode,
            "identity_file_sha256": closure.candidate.identity.sha256,
            "identity_path": str(closure.candidate.identity.path),
            "identity_sha256": candidate_identity_sha256(candidate),
            "provenance_path": str(closure.candidate.provenance.path),
            "provenance_sha256": closure.candidate.provenance.sha256,
            "source_app_path": str(closure.candidate.source_app),
        },
        "installation": {
            "acceptance_receipt_path": str(
                closure.installation.acceptance_receipt.path
            ),
            "acceptance_receipt_sha256": closure.installation.acceptance_receipt.sha256,
            "acceptance_produced_at_unix_ns": closure.installation.acceptance_document[
                "produced_at_unix_ns"
            ],
            "began_at_unix_ns": state["began_at_unix_ns"],
            "commit_authority_path": str(closure.installation.commit_authority.path),
            "commit_authority_sha256": closure.installation.commit_authority.sha256,
            "destination_identity_sha256": _sha256(
                canonical_bytes(state["destination_identity"])
            ),
            "execution_identity_sha256": state["execution_identity_sha256"],
            "exposed_at_unix_ns": state["exposed_at_unix_ns"],
            "installed_app_path": str(closure.installation.installed_app),
            "predecessor_digest": state["predecessor_digest"],
            "predecessor_observations_sha256": state[
                "predecessor_observations_sha256"
            ],
            "pending_state_path_at_begin": closure.transaction_result.pending_state[
                "path_at_begin"
            ],
            "rolled_back": False,
            "source_equality_sha256": state["source_equality_sha256"],
            "terminal_state_path": str(closure.installation.state_file.path),
            "terminal_state_sha256": closure.installation.state_file.sha256,
            "transaction_id": state["transaction_id"],
            "transaction_nonce": state["transaction_nonce"],
            "transaction_phase": "committed",
        },
        "integration": {
            "branch": closure.local_ref.branch_name,
            "commit": closure.local_ref.commit,
            "ref": closure.local_ref.integration_ref,
            "remote": closure.local_ref.remote_name,
            "remote_url": closure.local_ref.remote_url,
            "tree": closure.local_ref.tree,
        },
        "produced_at_unix_ns": produced_at_unix_ns,
        "qualification": {
            "coverage_path": str(closure.qualification.coverage.path),
            "coverage_sha256": closure.qualification.coverage.sha256,
            "dependency_network_allowed": closure.qualification.document[
                "dependency_network_allowed"
            ],
            "dependency_network_used": False,
            "mode": "full-test",
            "receipt_path": str(closure.qualification.receipt.path),
            "receipt_sha256": closure.qualification.receipt.sha256,
            "result_bundle_path": str(closure.qualification.result_bundle),
            "run_id": closure.qualification_run.run_id,
            "run_nonce": closure.qualification_run.nonce,
            "run_root": str(closure.qualification.validated.run_root),
            "source_provenance_sha256": closure.qualification.source_provenance_sha256,
        },
        "receipt_kind": RECEIPT_KIND,
        "result": "passed",
        "schema_version": SCHEMA_VERSION,
        "scope": {
            "authority": AUTHORITY_SCOPE,
            "gate_f_claimed": False,
            "online_delivery_claimed": False,
            "post_2026_09_11_proof_claimed": False,
            "public_release_claimed": False,
        },
        "transaction_result": {
            "candidate_artifact_root": closure.transaction_result.candidate[
                "artifact_root"
            ],
            "gate_plan_authority_sha256": closure.transaction_result.gate_plan_document[
                "authority_sha256"
            ],
            "gate_plan_path": str(closure.transaction_result.gate_plan.path),
            "gate_plan_sha256": closure.transaction_result.gate_plan.sha256,
            "native_preparation_receipt_path": str(
                closure.transaction_result.native_preparation_receipt.path
            ),
            "native_preparation_receipt_sha256": (
                closure.transaction_result.native_preparation_receipt.sha256
            ),
            "native_xctestrun_path": str(
                closure.transaction_result.native_xctestrun.path
            ),
            "native_xctestrun_sha256": closure.transaction_result.native_xctestrun.sha256,
            "installed_task10": closure.transaction_result.installed_task10.document,
            "path": str(closure.transaction_result.result_file.path),
            "produced_at_unix_ns": closure.transaction_result.document[
                "produced_at_unix_ns"
            ],
            "sha256": closure.transaction_result.result_file.sha256,
            "ws24_aggregate_path": str(
                closure.transaction_result.ws24_aggregate.path
            ),
            "ws24_aggregate_sha256": closure.transaction_result.ws24_aggregate.sha256,
        },
    }


def _revalidate_closure(closure: Closure) -> None:
    observed_ref = _resolve_local_ref(
        closure.local_ref.repository_root,
        closure.local_ref.integration_ref,
    )
    if observed_ref != closure.local_ref:
        fail("local integration ref changed during final closure")
    for snapshot in closure.input_files:
        _require_unchanged(snapshot, label=f"input {snapshot.path.name}")
    task10 = closure.transaction_result.installed_task10
    if (
        _metadata(task10.network_root.lstat()) != task10.network_root_metadata
        or _directory_children(
            task10.network_root,
            label="installed Task10 network artifact root",
        )
        != TASK10_NETWORK_CHILDREN
    ):
        fail("installed Task10 network artifact root changed during final closure")
    _require_tree_unchanged(task10.xcresult, label="installed Task10 xcresult")
    for snapshot in closure.qualification.validated.dependency_files:
        try:
            qualification._require_unchanged(
                snapshot,
                label="qualification dependency/source authority",
            )
        except qualification.ProductIdentityError as error:
            fail(str(error))
    try:
        installer._require_source_unchanged(
            closure.candidate.source_authority,
            phase="final local receipt publication",
        )
        installed = installer._capture_exact_bundle(closure.installation.installed_app)
    except (OSError, installer.InstallationError) as error:
        fail(f"candidate or installed app changed before receipt publication: {error}")
    expected = closure.installation.installed_snapshot
    if (
        not installer.bundle_snapshots_match(installed.tree, expected.tree)
        or installed.root_mode != expected.root_mode
        or installed.digests != expected.digests
    ):
        fail("installed app changed before receipt publication")


def _output_authority(
    path: Path,
    input_files: Sequence[StableFile],
    *,
    protected_roots: Sequence[Path],
) -> tuple[Path, tuple[int, int]]:
    if not path.is_absolute() or not path.name or path.name in {".", ".."}:
        fail("final receipt output must be an absolute canonical file path")
    parent = _canonical_directory(path.parent, label="final receipt output parent")
    canonical = parent / path.name
    if canonical != path:
        fail("final receipt output path is not canonical")
    if any(path == item.path for item in input_files):
        fail("final receipt output must be distinct from every input")
    for root in protected_roots:
        if path == root or path.is_relative_to(root):
            fail("final receipt output is inside a protected input authority")
    try:
        path.lstat()
    except FileNotFoundError:
        pass
    except OSError as error:
        fail(f"final receipt output cannot be inspected: {error}")
    else:
        fail("final receipt output already exists; create-only publication refused")
    metadata = parent.lstat()
    return canonical, (metadata.st_dev, metadata.st_ino)


def _write_create_only(
    path: Path,
    document: Mapping[str, object],
    *,
    parent_identity: tuple[int, int],
) -> StableFile:
    payload = canonical_bytes(document)
    if len(payload) > MAX_FINAL_RECEIPT_BYTES:
        fail("final local candidate receipt exceeds its size bound")
    parent = path.parent
    observed_parent = parent.lstat()
    if (observed_parent.st_dev, observed_parent.st_ino) != parent_identity:
        fail("final receipt output parent changed before publication")
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0)
    )
    created = False
    try:
        descriptor = os.open(path, flags, 0o600)
        created = True
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise OSError("receipt write made no progress")
                offset += written
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        directory_descriptor = os.open(
            parent,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_CLOEXEC", 0),
        )
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        receipt = _read_stable_file(
            path,
            maximum_bytes=MAX_FINAL_RECEIPT_BYTES,
            label="published final local candidate receipt",
        )
        if receipt.payload != payload or receipt.metadata[2] != 0o600:
            fail("published final local candidate receipt is not exact and private")
        return receipt
    except Exception:
        if created:
            try:
                path.unlink()
            except OSError:
                pass
        raise


def validate_and_write(
    arguments: argparse.Namespace,
    *,
    allow_test_destination: bool = False,
    clock_ns: Callable[[], int] = time.time_ns,
) -> Path:
    closure = validate_inputs(arguments, allow_test_destination=allow_test_destination)
    output, parent_identity = _output_authority(
        arguments.output,
        closure.input_files,
        protected_roots=(
            REPOSITORY_ROOT,
            Path(closure.transaction_result.candidate["artifact_root"]),
            closure.candidate.source_app,
            closure.installation.installed_app,
            closure.qualification.validated.run_root,
        ),
    )
    latest = max(
        int(closure.transaction_result.document["produced_at_unix_ns"]),
        int(closure.installation.acceptance_document["produced_at_unix_ns"]),
        *(int(record["ended_at_unix_ns"]) for record in closure.installation.gate_records.values()),
    )
    produced = clock_ns()
    if type(produced) is not int or produced <= 0 or produced < latest:
        fail("final receipt timestamp predates its acceptance predecessor chain")
    document = _receipt_document(closure, produced_at_unix_ns=produced)
    _revalidate_closure(closure)
    published = _write_create_only(
        output,
        document,
        parent_identity=parent_identity,
    )
    try:
        _revalidate_closure(closure)
        observed = _decode_canonical(
            published.payload,
            label="published final local candidate receipt",
        )
        if observed != document:
            fail("published final local candidate receipt changed after publication")
    except Exception:
        try:
            output.unlink()
        except OSError:
            pass
        raise
    return published.path


def parse_arguments(arguments: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and create one final local MacScope candidate receipt.",
        allow_abbrev=False,
    )
    parser.add_argument("--transaction-result", required=True, type=Path)
    parser.add_argument("--integration-ref", required=True)
    parser.add_argument("--qualification-receipt", required=True, type=Path)
    parser.add_argument("--candidate-artifact-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    values = list(sys.argv[1:] if arguments is None else arguments)
    if values not in (["-h"], ["--help"]):
        expected_flags = (
            "--transaction-result",
            "--integration-ref",
            "--qualification-receipt",
            "--candidate-artifact-root",
            "--output",
        )
        if len(values) != len(expected_flags) * 2 or tuple(values[::2]) != expected_flags:
            parser.error(
                "the five required flags must each appear exactly once in frozen order"
            )
    return parser.parse_args(values)


def main(
    arguments: Sequence[str] | None = None,
    *,
    _allow_test_destination: bool = False,
    _clock_ns: Callable[[], int] = time.time_ns,
) -> int:
    try:
        parsed = parse_arguments(arguments)
        path = validate_and_write(
            parsed,
            allow_test_destination=_allow_test_destination,
            clock_ns=_clock_ns,
        )
    except (
        CanonicalJSONError,
        FinalLocalCandidateError,
        OSError,
        ValueError,
    ) as error:
        print(f"ERROR: final local candidate receipt refused: {error}", file=sys.stderr)
        return 1
    print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
