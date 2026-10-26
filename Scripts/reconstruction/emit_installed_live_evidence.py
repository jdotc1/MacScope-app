#!/usr/bin/env python3
"""Run, validate, and publish the closed WS24 installed live-evidence manifest."""

from __future__ import annotations

import argparse
import importlib
import os
import stat
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import ws24_emit_installed_qualification_report as ws24  # noqa: E402
from Scripts.reconstruction import (  # noqa: E402
    install_release_to_applications as installer,
)
from Scripts.reconstruction import (  # noqa: E402
    audit_installed_network_acquisition as network_audit,
    installed_matrix_receipt,
    native_live_preparation_receipt,
)
from Scripts.reconstruction import write_execution_report as secure_file  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)

CANONICAL_INSTALLED_APP = Path("/Applications/MacScope.app")
CANDIDATE_IDENTITY_NAME = "candidate.json"
NATIVE_PREPARATION_RECEIPT_NAME = "NativeLivePreparation.receipt.json"
LIVE_REPORT_ROOT_NAME = "installed-live-gates"
MANIFEST_NAME = "live-evidence.json"
MATRIX_RECEIPT_NAME = "InstalledTask10.matrix-receipt.json"
MATRIX_SEMANTIC_MANIFEST_NAME = "InstalledTask10.xcresult-semantic.json"
MATRIX_XCRESULT_NAME = "InstalledTask10.xcresult"
MATRIX_NETWORK_ROOT_NAME = "installed-task10-network"
INCREMENTAL_DESCRIPTOR_NAME = "InstalledTask10.incremental-xcuitest.evidence.json"
SEMANTIC_MANIFEST_ARTIFACT_KIND = "installed-task10-xcresult-semantic-manifest-v1"
NETWORK_REPORT_ARTIFACT_KIND = "installed-task10-network-audit-report-v1"
NETWORK_EXECUTION_ARTIFACT_KIND = (
    "installed-task10-network-audit-execution-report-v1"
)
NETWORK_OBSERVATION_ARTIFACT_KIND = (
    "installed-task10-network-audit-observation-v1"
)

MAXIMUM_PREPARATION_RECEIPT_BYTES = 4 * 1024 * 1024
MAXIMUM_MATRIX_RECEIPT_BYTES = 4 * 1024 * 1024
MAXIMUM_MATRIX_SEMANTIC_MANIFEST_BYTES = 4 * 1024 * 1024
MAXIMUM_MANIFEST_BYTES = 64 * 1024
MAXIMUM_XCRESULT_ENTRIES = 200_000
MAXIMUM_XCRESULT_BYTES = 16 * 1024 * 1024 * 1024
MINIMUM_TIMEOUT_SECONDS = 1
MAXIMUM_TIMEOUT_SECONDS = 3_600
DEFAULT_TIMEOUT_SECONDS = 1_800

LIVE_REPORT_FILE_BY_GATE = {
    "installed-launch-smoke": "installed-launch-smoke.live-execution-report.json",
    "direct-debugger-transport-contracts": (
        "direct-debugger-transport-contracts.live-execution-report.json"
    ),
    "repeated-launch-detach-stress": (
        "repeated-launch-detach-stress.live-execution-report.json"
    ),
    "repeated-attach-detach-stress": (
        "repeated-attach-detach-stress.live-execution-report.json"
    ),
    "repeated-restart-stress": (
        "repeated-restart-stress.live-execution-report.json"
    ),
    "performance-gate": "performance-gate.live-execution-report.json",
}
LIVE_GATE_ORDER = tuple(sorted(LIVE_REPORT_FILE_BY_GATE))
MANIFEST_GATE_ORDER = tuple(sorted(ws24.SUPPLIED_LIVE_GATES))
if set(LIVE_REPORT_FILE_BY_GATE) != ws24.LIVE_EXECUTION_GATES:
    raise RuntimeError("live report filename contract differs from WS24")
if set(MANIFEST_GATE_ORDER) != ws24.SUPPLIED_LIVE_GATES:
    raise RuntimeError("manifest gate contract differs from WS24")


class LiveEvidenceError(RuntimeError):
    """A favorable live-evidence manifest cannot be published."""


@dataclass(frozen=True)
class Authority:
    candidate_identity: Path
    candidate_root: Path
    source_app: Path
    installed_app: Path
    evidence_root: Path
    source_authority: installer.SourceAuthority
    pending_state_path: Path
    pending_state: dict[str, Any]
    pending_snapshot: installer.StableFile
    qualification_run_id: str
    qualification_run_nonce: str
    exposed_at_unix_ns: int
    installed_executable_sha256: str


@dataclass(frozen=True)
class Preparation:
    path: Path
    snapshot: secure_file.StableRegularFile
    document: dict[str, Any]
    xctestrun: Path
    app: Path
    developer_dir: Path


@dataclass(frozen=True)
class TreeSnapshot:
    path: Path
    metadata: tuple[tuple[object, ...], ...]
    total_bytes: int
    result_bundle_sha256: str


@dataclass(frozen=True)
class IncrementalEvidence:
    entry: dict[str, Any]
    descriptor: dict[str, Any]
    descriptor_snapshot: secure_file.StableRegularFile
    receipt: dict[str, Any]
    receipt_snapshot: secure_file.StableRegularFile
    semantic_snapshot: secure_file.StableRegularFile
    network_snapshots: tuple[secure_file.StableRegularFile, ...]
    xcresult_snapshot: TreeSnapshot


def fail(message: str) -> NoReturn:
    raise LiveEvidenceError(message)


def _timeout(value: str) -> int:
    try:
        parsed = int(value, 10)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout must be an integer") from error
    if not MINIMUM_TIMEOUT_SECONDS <= parsed <= MAXIMUM_TIMEOUT_SECONDS:
        raise argparse.ArgumentTypeError(
            f"timeout must be in {MINIMUM_TIMEOUT_SECONDS}..{MAXIMUM_TIMEOUT_SECONDS}"
        )
    return parsed


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Run the real installed WS24 live gates and publish their one closed "
            "canonical evidence manifest."
        )
    )
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--source-app", type=Path, required=True)
    parser.add_argument("--installed-app", type=Path, required=True)
    parser.add_argument("--installation-pending-state", type=Path, required=True)
    parser.add_argument("--native-preparation-receipt", type=Path, required=True)
    parser.add_argument("--matrix-receipt", type=Path, required=True)
    parser.add_argument("--xcresult-semantic-manifest", type=Path, required=True)
    parser.add_argument("--network-artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument(
        "--live-gates-timeout-seconds",
        type=_timeout,
        default=DEFAULT_TIMEOUT_SECONDS,
    )
    return parser.parse_args(argv)


def _canonical_directory(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if (
        resolved != path
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
    ):
        fail(f"{label} must be a canonical non-symlink directory")
    return resolved


def _canonical_regular(path: Path, *, label: str) -> Path:
    if not path.is_absolute():
        fail(f"{label} must be absolute")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        fail(f"{label} is unavailable: {error}")
    if (
        resolved != path
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
    ):
        fail(f"{label} must be a canonical singly linked regular file")
    return resolved


def _paths_overlap(left: Path, right: Path) -> bool:
    try:
        left.relative_to(right)
        return True
    except ValueError:
        pass
    try:
        right.relative_to(left)
        return True
    except ValueError:
        return False


def _require_absent(path: Path, *, label: str) -> None:
    if not path.is_absolute() or not path.name or path.exists() or path.is_symlink():
        fail(f"{label} must be an absent absolute path")
    parent = _canonical_directory(path.parent, label=f"{label} parent")
    if path != parent / path.name:
        fail(f"{label} must traverse no symbolic links")


def _stable_canonical_object(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
    require_private_mode: bool,
) -> tuple[secure_file.StableRegularFile, dict[str, Any]]:
    try:
        snapshot = secure_file.read_stable_regular(
            path,
            label=label,
            maximum_bytes=maximum_bytes,
            retain_payload=True,
        )
    except secure_file.ExecutionReportError as error:
        fail(str(error))
    if snapshot.payload is None or not snapshot.payload:
        fail(f"{label} must not be empty")
    if require_private_mode and stat.S_IMODE(snapshot.metadata[2]) != 0o600:
        fail(f"{label} mode must be exactly 0600")
    try:
        value = decode_canonical_bytes(snapshot.payload)
    except CanonicalJSONError as error:
        fail(f"{label} is not canonical JSON: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return snapshot, value


def _require_fresh_file(
    snapshot: secure_file.StableRegularFile,
    *,
    exposed_at_unix_ns: int,
    label: str,
) -> None:
    if snapshot.metadata[5] < exposed_at_unix_ns:
        fail(f"{label} modification time predates pending candidate exposure")
    if snapshot.metadata[6] < exposed_at_unix_ns:
        fail(f"{label} physical creation/change time predates pending candidate exposure")


def _require_unchanged(
    snapshot: secure_file.StableRegularFile,
    *,
    label: str,
) -> None:
    try:
        secure_file.require_unchanged_regular(snapshot, label=label)
    except secure_file.ExecutionReportError as error:
        fail(str(error))


def _load_authority(arguments: argparse.Namespace) -> Authority:
    candidate = _canonical_regular(arguments.candidate_identity, label="candidate identity")
    if candidate.name != CANDIDATE_IDENTITY_NAME:
        fail(f"candidate identity must use the exact filename {CANDIDATE_IDENTITY_NAME}")
    candidate_root = _canonical_directory(candidate.parent, label="candidate artifact root")
    source_app = _canonical_directory(arguments.source_app, label="sealed source app")
    installed_app = _canonical_directory(arguments.installed_app, label="installed app")
    if installed_app != CANONICAL_INSTALLED_APP:
        fail(f"installed app must be exactly {CANONICAL_INSTALLED_APP}")
    evidence_root = _canonical_directory(arguments.evidence_root, label="evidence root")
    pending_state_path = _canonical_regular(
        arguments.installation_pending_state,
        label="installation pending state",
    )
    if pending_state_path.name != "transaction.json":
        fail("installation pending state must use the exact transaction.json filename")
    for protected, label in (
        (candidate_root, "candidate artifact root"),
        (source_app, "sealed source app"),
        (installed_app, "installed app"),
        (pending_state_path.parent, "pending transaction root"),
    ):
        if _paths_overlap(evidence_root, protected):
            fail(f"evidence root must be disjoint from {label}")
    try:
        source_authority = installer._load_source_authority(candidate, source_app)
        pending_state, pending_snapshot = ws24._load_pending_transaction(
            pending_state=pending_state_path,
            installed_app=installed_app,
            source_app=source_app,
            candidate_identity=candidate,
            expected_source_commit=source_authority.candidate.source.commit,
            qualification_run_id=arguments.qualification_run_id,
            qualification_run_nonce=arguments.qualification_run_nonce,
        )
    except (OSError, ValueError, installer.InstallationError, ws24.ReportError) as error:
        fail(f"installed candidate authority is invalid: {error}")
    exposed_at = pending_state.get("exposed_at_unix_ns")
    if not isinstance(exposed_at, int) or isinstance(exposed_at, bool) or exposed_at <= 0:
        fail("pending candidate exposure timestamp is invalid")
    installed_executable = ws24.validate_app_bundle(installed_app, "installed")
    installed_digest = ws24.sha256_file(installed_executable)
    if installed_digest != source_authority.executable_sha256:
        fail("installed executable differs from the exact candidate")
    if pending_state.get("application_executable_sha256") != installed_digest:
        fail("pending transaction executable digest differs from installed bytes")
    if time.time_ns() < exposed_at:
        fail("wall clock precedes pending candidate exposure")
    return Authority(
        candidate_identity=candidate,
        candidate_root=candidate_root,
        source_app=source_app,
        installed_app=installed_app,
        evidence_root=evidence_root,
        source_authority=source_authority,
        pending_state_path=pending_state_path,
        pending_state=pending_state,
        pending_snapshot=pending_snapshot,
        qualification_run_id=arguments.qualification_run_id,
        qualification_run_nonce=arguments.qualification_run_nonce,
        exposed_at_unix_ns=exposed_at,
        installed_executable_sha256=installed_digest,
    )


def _load_native_preparation(
    path: Path,
    *,
    authority: Authority,
) -> Preparation:
    exact_name = NATIVE_PREPARATION_RECEIPT_NAME
    expected_path = authority.candidate_root / exact_name
    if path != expected_path:
        fail(f"{exact_name} must be the exact candidate-root preparation receipt")
    path = _canonical_regular(path, label=exact_name)
    snapshot, value = _stable_canonical_object(
        path,
        label=exact_name,
        maximum_bytes=MAXIMUM_PREPARATION_RECEIPT_BYTES,
        require_private_mode=True,
    )
    try:
        document = native_live_preparation_receipt.parse_document(value)
    except native_live_preparation_receipt.PreparationReceiptError as error:
        fail(f"{exact_name} is invalid: {error}")
    if (
        document.get("schema_version") != native_live_preparation_receipt.SCHEMA_VERSION
        or document.get("receipt_kind")
        != native_live_preparation_receipt.RECEIPT_KIND
        or document.get("build", {}).get("preparation_mode")
        != native_live_preparation_receipt.NATIVE_LIVE_PREPARATION_MODE
    ):
        fail(f"{exact_name} has the wrong schema, kind, or preparation mode")
    artifacts = document["artifacts"]
    app = _canonical_directory(Path(artifacts["app"]["path"]), label="prepared app")
    if app != authority.source_app:
        fail(f"{exact_name} must bind the exact sealed source app")
    xctestrun = _canonical_regular(
        Path(artifacts["xctestrun"]["path"]), label="prepared xctestrun"
    )
    for product, label in ((xctestrun, "prepared xctestrun"),):
        if _paths_overlap(product, authority.evidence_root):
            fail(f"{label} must be external to the mutable evidence root")
        if _paths_overlap(product, authority.pending_state_path.parent):
            fail(f"{label} must be external to the pending transaction root")
        if _paths_overlap(product, authority.installed_app):
            fail(f"{label} must not be sourced from the installed app")
    developer_dir = _canonical_directory(
        Path(document["toolchain"]["developer_dir"]), label="prepared developer directory"
    )
    try:
        observed_digest = native_live_preparation_receipt.validate_prepared(
            document,
            xctestrun,
            app,
            authority.candidate_identity,
        )
    except (
        OSError,
        ValueError,
        native_live_preparation_receipt.PreparationReceiptError,
    ) as error:
        fail(f"{exact_name} physical products are invalid: {error}")
    if observed_digest != snapshot.sha256:
        fail(f"{exact_name} canonical identity differs from its physical bytes")
    return Preparation(
        path=path,
        snapshot=snapshot,
        document=document,
        xctestrun=xctestrun,
        app=app,
        developer_dir=developer_dir,
    )


def _revalidate_preparation(preparation: Preparation, authority: Authority) -> None:
    _require_unchanged(preparation.snapshot, label=preparation.path.name)
    try:
        digest = native_live_preparation_receipt.validate_prepared(
            preparation.document,
            preparation.xctestrun,
            preparation.app,
            authority.candidate_identity,
        )
    except (
        OSError,
        ValueError,
        native_live_preparation_receipt.PreparationReceiptError,
    ) as error:
        fail(f"{preparation.path.name} changed after validation: {error}")
    if digest != preparation.snapshot.sha256:
        fail(f"{preparation.path.name} identity changed after validation")


def _preflight_outputs(
    authority: Authority,
    *,
    matrix_receipt: Path,
    semantic_manifest: Path,
    network_root: Path,
) -> Path:
    expected_receipt = authority.evidence_root / MATRIX_RECEIPT_NAME
    expected_semantic = authority.evidence_root / MATRIX_SEMANTIC_MANIFEST_NAME
    expected_network = authority.evidence_root / MATRIX_NETWORK_ROOT_NAME
    if matrix_receipt != expected_receipt:
        fail("matrix receipt must use its exact governed evidence-root path")
    if semantic_manifest != expected_semantic:
        fail("xcresult semantic manifest must use its exact governed evidence-root path")
    if network_root != expected_network:
        fail("network artifact root must use its exact governed evidence-root path")
    _canonical_regular(matrix_receipt, label="installed Task10 matrix receipt")
    _canonical_regular(semantic_manifest, label="installed Task10 semantic manifest")
    network_root = _canonical_directory(
        network_root, label="installed Task10 network artifact root"
    )
    for path in (
        authority.evidence_root / LIVE_REPORT_ROOT_NAME,
        authority.evidence_root / MANIFEST_NAME,
    ):
        _require_absent(path, label=f"output {path.name}")
    _canonical_regular(
        network_root / INCREMENTAL_DESCRIPTOR_NAME,
        label="installed incremental-XCUITest evidence descriptor",
    )
    return network_root


def _invoke_live_runner(
    authority: Authority,
    native_preparation: Preparation,
    *,
    timeout_seconds: int,
) -> None:
    try:
        module = importlib.import_module(
            "Scripts.reconstruction.run_ws24_installed_live_gates"
        )
        entrypoint = module.main
    except (ImportError, AttributeError) as error:
        fail(f"canonical six-gate runner is unavailable: {error}")
    argv = [
        "--candidate-identity",
        str(authority.candidate_identity),
        "--source-app",
        str(authority.source_app),
        "--installed-app",
        str(authority.installed_app),
        "--installation-pending-state",
        str(authority.pending_state_path),
        "--preparation-receipt",
        str(native_preparation.path),
        "--qualification-run-id",
        authority.qualification_run_id,
        "--qualification-run-nonce",
        authority.qualification_run_nonce,
        "--output-root",
        str(authority.evidence_root / LIVE_REPORT_ROOT_NAME),
        "--timeout-seconds",
        str(timeout_seconds),
    ]
    wall_before = time.time_ns()
    try:
        result = entrypoint(argv)
    except SystemExit as error:
        fail(f"canonical six-gate runner exited unexpectedly: {error.code}")
    wall_after = time.time_ns()
    if wall_after < wall_before:
        fail("wall clock reversed during six-gate execution")
    if result != 0:
        fail(f"canonical six-gate runner failed with exit status {result!r}")


def _report_entry(
    gate: str,
    path: Path,
    *,
    authority: Authority,
) -> tuple[dict[str, Any], secure_file.StableRegularFile]:
    snapshot, document = _stable_canonical_object(
        path,
        label=f"{gate} live execution report",
        maximum_bytes=ws24.MAXIMUM_LIVE_EXECUTION_REPORT_BYTES,
        require_private_mode=True,
    )
    _require_fresh_file(
        snapshot,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
        label=f"{gate} live execution report",
    )
    if set(document) != ws24.LIVE_EXECUTION_REPORT_FIELDS:
        fail(f"{gate} live execution report is not a closed schema-1 record")
    if document.get("gate") != gate or document.get("schemaVersion") != 1:
        fail(f"{gate} live execution report gate or schema differs")
    attempts = document.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        fail(f"{gate} live execution report has no physical attempts")
    exposure_ms = (authority.exposed_at_unix_ns + 999_999) // 1_000_000
    for index, attempt in enumerate(attempts):
        if not isinstance(attempt, dict) or set(attempt) != ws24.LIVE_EXECUTION_ATTEMPT_FIELDS:
            fail(f"{gate} attempt {index} is not a closed physical attempt record")
        started = attempt.get("startedAtUnixMilliseconds")
        if not isinstance(started, int) or isinstance(started, bool) or started < exposure_ms:
            fail(f"{gate} attempt {index} predates pending candidate exposure")
    entry = {
        "gate": gate,
        "proofArtifacts": [
            {
                "kind": ws24.LIVE_EXECUTION_REPORT_KIND,
                "path": str(path),
                "sha256": snapshot.sha256,
            }
        ],
    }
    try:
        normalized = ws24.normalize_input_evidence(
            [entry],
            expected_source_commit=authority.source_authority.candidate.source.commit,
            expected_source_tree=authority.source_authority.candidate.source.tree,
            expected_installed_executable_sha256=(
                authority.installed_executable_sha256
            ),
        )
    except ws24.ReportError as error:
        fail(f"{gate} live execution report is invalid: {error}")
    if len(normalized) != 1 or normalized[0].get("status") != "passed":
        fail(f"{gate} live execution report is not favorable physical evidence")
    minimum = (
        30
        if gate == "performance-gate"
        else ws24.MINIMUM_ACCEPTED_ATTEMPTS.get(gate, 1)
    )
    accepted = normalized[0].get("acceptedAttempts")
    if not isinstance(accepted, int) or isinstance(accepted, bool) or accepted < minimum:
        fail(f"{gate} live execution report has too few accepted real attempts")
    return entry, snapshot


def _load_live_reports(
    authority: Authority,
) -> tuple[dict[str, dict[str, Any]], dict[str, secure_file.StableRegularFile]]:
    root = _canonical_directory(
        authority.evidence_root / LIVE_REPORT_ROOT_NAME,
        label="installed live-gate report root",
    )
    root_mode = stat.S_IMODE(root.lstat().st_mode)
    if root_mode != 0o700:
        fail("installed live-gate report root mode must be exactly 0700")
    expected_names = set(LIVE_REPORT_FILE_BY_GATE.values())
    observed_names = {entry.name for entry in os.scandir(root)}
    if observed_names != expected_names:
        fail(
            "installed live-gate report root is not closed; "
            f"missing={sorted(expected_names - observed_names)}, "
            f"unknown={sorted(observed_names - expected_names)}"
        )
    entries: dict[str, dict[str, Any]] = {}
    snapshots: dict[str, secure_file.StableRegularFile] = {}
    inodes: set[tuple[int, int]] = set()
    for gate in LIVE_GATE_ORDER:
        path = root / LIVE_REPORT_FILE_BY_GATE[gate]
        entry, snapshot = _report_entry(gate, path, authority=authority)
        inode = (snapshot.metadata[0], snapshot.metadata[1])
        if inode in inodes:
            fail("live execution reports must be physically distinct files")
        inodes.add(inode)
        entries[gate] = entry
        snapshots[gate] = snapshot
    return entries, snapshots


def _capture_xcresult(path: Path, *, exposed_at_unix_ns: int) -> TreeSnapshot:
    root = _canonical_directory(path, label="installed Task10 xcresult")
    root_metadata = root.lstat()
    if (
        root_metadata.st_mtime_ns < exposed_at_unix_ns
        or root_metadata.st_ctime_ns < exposed_at_unix_ns
    ):
        fail("installed Task10 xcresult root predates pending candidate exposure")
    rows: list[tuple[object, ...]] = [
        (
            ".",
            root_metadata.st_dev,
            root_metadata.st_ino,
            root_metadata.st_mode,
            root_metadata.st_nlink,
            root_metadata.st_size,
            root_metadata.st_mtime_ns,
            root_metadata.st_ctime_ns,
        )
    ]
    total_bytes = 0
    entry_count = 0
    file_count = 0
    for current_root, directories, files in os.walk(root, topdown=True, followlinks=False):
        directories.sort()
        files.sort()
        current = Path(current_root)
        for name in [*directories, *files]:
            path_entry = current / name
            metadata = path_entry.lstat()
            relative = path_entry.relative_to(root).as_posix()
            entry_count += 1
            if entry_count > MAXIMUM_XCRESULT_ENTRIES:
                fail("installed Task10 xcresult exceeds its entry-count bound")
            if stat.S_ISLNK(metadata.st_mode):
                fail(f"installed Task10 xcresult contains a symlink: {relative}")
            if name in directories:
                if not stat.S_ISDIR(metadata.st_mode):
                    fail(f"installed Task10 xcresult has a non-directory entry: {relative}")
            else:
                if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                    fail(f"installed Task10 xcresult has a non-ordinary file: {relative}")
                file_count += 1
                total_bytes += metadata.st_size
                if total_bytes > MAXIMUM_XCRESULT_BYTES:
                    fail("installed Task10 xcresult exceeds its byte bound")
            if (
                metadata.st_mtime_ns < exposed_at_unix_ns
                or metadata.st_ctime_ns < exposed_at_unix_ns
            ):
                fail(f"installed Task10 xcresult entry predates exposure: {relative}")
            rows.append(
                (
                    relative,
                    metadata.st_dev,
                    metadata.st_ino,
                    metadata.st_mode,
                    metadata.st_nlink,
                    metadata.st_size,
                    metadata.st_mtime_ns,
                    metadata.st_ctime_ns,
                )
            )
    if file_count == 0:
        fail("installed Task10 xcresult contains no physical files")
    try:
        digest = ws24.result_bundle_sha256(root)
    except ws24.ReportError as error:
        fail(f"installed Task10 xcresult is invalid: {error}")
    return TreeSnapshot(
        path=root,
        metadata=tuple(rows),
        total_bytes=total_bytes,
        result_bundle_sha256=digest,
    )


def _load_incremental_evidence(
    authority: Authority,
    *,
    descriptor_path: Path,
    receipt_path: Path,
    semantic_manifest_path: Path,
    network_root: Path,
) -> IncrementalEvidence:
    descriptor_snapshot, descriptor = _stable_canonical_object(
        descriptor_path,
        label="installed incremental-XCUITest evidence descriptor",
        maximum_bytes=MAXIMUM_MANIFEST_BYTES,
        require_private_mode=True,
    )
    _require_fresh_file(
        descriptor_snapshot,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
        label="installed incremental-XCUITest evidence descriptor",
    )
    if set(descriptor) != {"evidence"}:
        fail("incremental-XCUITest descriptor root must be exactly {'evidence'}")
    evidence_items = descriptor.get("evidence")
    if not isinstance(evidence_items, list) or len(evidence_items) != 1:
        fail("incremental-XCUITest descriptor must contain exactly one evidence item")
    entry = evidence_items[0]
    if (
        not isinstance(entry, dict)
        or set(entry) != {"gate", "proofArtifacts"}
        or entry.get("gate") != "incremental-xcuitest"
    ):
        fail("incremental-XCUITest descriptor is not the closed canonical gate record")
    artifacts = entry.get("proofArtifacts")
    expected_artifacts = (
        (installed_matrix_receipt.PROOF_ARTIFACT_KIND, receipt_path, True),
        (
            NETWORK_EXECUTION_ARTIFACT_KIND,
            network_root / network_audit.EXECUTION_REPORT_NAME,
            True,
        ),
        (
            NETWORK_OBSERVATION_ARTIFACT_KIND,
            network_root / network_audit.OBSERVATION_NAME,
            True,
        ),
        (
            NETWORK_REPORT_ARTIFACT_KIND,
            network_root / network_audit.REPORT_NAME,
            True,
        ),
        (SEMANTIC_MANIFEST_ARTIFACT_KIND, semantic_manifest_path, True),
        ("xcresult", authority.evidence_root / MATRIX_XCRESULT_NAME, False),
    )
    if not isinstance(artifacts, list) or len(artifacts) != len(expected_artifacts):
        fail("incremental-XCUITest descriptor must contain exactly six proof artifacts")
    for index, (artifact, expected) in enumerate(zip(artifacts, expected_artifacts)):
        kind, path, carries_sha256 = expected
        fields = {"kind", "path", "sha256"} if carries_sha256 else {"kind", "path"}
        if (
            not isinstance(artifact, dict)
            or set(artifact) != fields
            or artifact.get("kind") != kind
            or Path(str(artifact.get("path", ""))) != path
        ):
            fail(f"incremental-XCUITest proof artifact {index} differs from its frozen row")
        if carries_sha256 and not ws24.is_lowercase_sha256(artifact.get("sha256")):
            fail(f"incremental-XCUITest proof artifact {index} is not SHA-bound")
    receipt_snapshot, receipt_value = _stable_canonical_object(
        receipt_path,
        label="installed Task10 matrix receipt",
        maximum_bytes=MAXIMUM_MATRIX_RECEIPT_BYTES,
        require_private_mode=True,
    )
    _require_fresh_file(
        receipt_snapshot,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
        label="installed Task10 matrix receipt",
    )
    semantic_snapshot, semantic_value = _stable_canonical_object(
        semantic_manifest_path,
        label="installed Task10 semantic manifest",
        maximum_bytes=MAXIMUM_MATRIX_SEMANTIC_MANIFEST_BYTES,
        require_private_mode=True,
    )
    _require_fresh_file(
        semantic_snapshot,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
        label="installed Task10 semantic manifest",
    )
    if semantic_value.get("schema_version") != 3 or semantic_value.get("result") != "passed":
        fail("installed Task10 semantic manifest is not a passing schema-3 record")
    try:
        receipt = installed_matrix_receipt.parse_document(receipt_value)
        if receipt.get("schema_version") != installed_matrix_receipt.SCHEMA_VERSION:
            fail("installed Task10 matrix receipt is not the current schema")
        observed_receipt, digest = installed_matrix_receipt.load_receipt_with_sha256(
            receipt_path
        )
        if observed_receipt != receipt or digest != receipt_snapshot.sha256:
            fail("installed Task10 matrix receipt changed during canonical validation")
        installed_matrix_receipt.validate_receipt(
            receipt,
            candidate_identity_path=authority.candidate_identity,
            installed_app=authority.installed_app,
            expected_selector_projection=ws24.installed_selector_projection(),
        )
    except installed_matrix_receipt.InstalledMatrixReceiptError as error:
        fail(f"installed Task10 matrix receipt is invalid: {error}")
    execution = receipt["execution"]
    exposure_ms = (authority.exposed_at_unix_ns + 999_999) // 1_000_000
    if execution.get("started_at_unix_ms", -1) < exposure_ms:
        fail("installed Task10 execution predates pending candidate exposure")
    xcresult_path = authority.evidence_root / MATRIX_XCRESULT_NAME
    if Path(receipt["products"]["xcresult"]["path"]) != xcresult_path:
        fail("installed Task10 receipt names a substituted xcresult")
    if artifacts[0].get("sha256") != receipt_snapshot.sha256:
        fail("incremental-XCUITest descriptor matrix receipt SHA-256 differs")
    if artifacts[4].get("sha256") != semantic_snapshot.sha256:
        fail("incremental-XCUITest descriptor semantic manifest SHA-256 differs")
    network_snapshots: list[secure_file.StableRegularFile] = []
    network_limits = (
        secure_file.MAXIMUM_EXECUTION_REPORT_BYTES,
        network_audit.MAX_OBSERVER_STDOUT_BYTES,
        MAXIMUM_MATRIX_SEMANTIC_MANIFEST_BYTES,
    )
    for offset, maximum_bytes in zip(range(1, 4), network_limits):
        try:
            snapshot = secure_file.read_stable_regular(
                Path(artifacts[offset]["path"]),
                label=f"incremental-XCUITest proof artifact {offset}",
                maximum_bytes=maximum_bytes,
                retain_payload=False,
            )
        except secure_file.ExecutionReportError as error:
            fail(str(error))
        if stat.S_IMODE(snapshot.metadata[2]) != 0o600:
            fail(f"incremental-XCUITest proof artifact {offset} mode must be 0600")
        _require_fresh_file(
            snapshot,
            exposed_at_unix_ns=authority.exposed_at_unix_ns,
            label=f"incremental-XCUITest proof artifact {offset}",
        )
        if artifacts[offset].get("sha256") != snapshot.sha256:
            fail(f"incremental-XCUITest proof artifact {offset} SHA-256 differs")
        network_snapshots.append(snapshot)
    xcresult_snapshot = _capture_xcresult(
        xcresult_path,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
    )
    source_xcresult = semantic_value.get("source_xcresult")
    if not isinstance(source_xcresult, dict) or source_xcresult != {
        "bundle_sha256": xcresult_snapshot.result_bundle_sha256,
        "closed_tree_sha256": receipt["products"]["xcresult"][
            "closed_tree_sha256"
        ],
    }:
        fail("installed Task10 semantic manifest does not bind the exact xcresult")
    if (
        semantic_value.get("candidate_identity_sha256")
        != receipt["candidate"]["identity_sha256"]
        or semantic_value.get("selector_projection")
        != receipt["execution"]["selector_projection"]
        or semantic_value.get("selector_projection_sha256")
        != receipt["execution"]["selector_projection_sha256"]
    ):
        fail("installed Task10 semantic manifest differs from the sealed matrix receipt")
    return IncrementalEvidence(
        entry=entry,
        descriptor=descriptor,
        descriptor_snapshot=descriptor_snapshot,
        receipt=receipt,
        receipt_snapshot=receipt_snapshot,
        semantic_snapshot=semantic_snapshot,
        network_snapshots=tuple(network_snapshots),
        xcresult_snapshot=xcresult_snapshot,
    )


def _normalize_manifest(document: dict[str, Any], authority: Authority) -> list[dict[str, Any]]:
    if set(document) != {"evidence"}:
        fail("live-evidence manifest root must be exactly {'evidence'}")
    raw_items = document.get("evidence")
    if not isinstance(raw_items, list):
        fail("live-evidence manifest evidence must be an array")
    gates = [item.get("gate") if isinstance(item, dict) else None for item in raw_items]
    if tuple(gates) != MANIFEST_GATE_ORDER or len(set(gates)) != len(gates):
        fail("live-evidence manifest must contain every supplied gate exactly once in order")
    try:
        normalized = ws24.normalize_input_evidence(
            document,
            expected_source_commit=authority.source_authority.candidate.source.commit,
            expected_source_tree=authority.source_authority.candidate.source.tree,
            expected_installed_executable_sha256=(
                authority.installed_executable_sha256
            ),
            candidate_identity_path=authority.candidate_identity,
            installed_app=authority.installed_app,
        )
    except ws24.ReportError as error:
        fail(f"live-evidence manifest is rejected by WS24: {error}")
    if len(normalized) != len(MANIFEST_GATE_ORDER):
        fail("WS24 did not normalize exactly seven live gates")
    normalized_by_gate = {item.get("gate"): item for item in normalized}
    if set(normalized_by_gate) != set(MANIFEST_GATE_ORDER):
        fail("WS24 normalized a different live-gate set")
    for gate in MANIFEST_GATE_ORDER:
        if normalized_by_gate[gate].get("status") != "passed":
            fail(f"WS24 normalized {gate} as non-passing")
    return normalized


def _revalidate_authority(authority: Authority) -> None:
    try:
        installer._require_source_unchanged(
            authority.source_authority,
            phase="live-evidence manifest publication",
        )
        state, snapshot = ws24._load_pending_transaction(
            pending_state=authority.pending_state_path,
            installed_app=authority.installed_app,
            source_app=authority.source_app,
            candidate_identity=authority.candidate_identity,
            expected_source_commit=authority.source_authority.candidate.source.commit,
            qualification_run_id=authority.qualification_run_id,
            qualification_run_nonce=authority.qualification_run_nonce,
        )
    except (OSError, ValueError, installer.InstallationError, ws24.ReportError) as error:
        fail(f"installed candidate authority changed after execution: {error}")
    if state != authority.pending_state or snapshot != authority.pending_snapshot:
        fail("pending transaction authority changed during live evidence execution")
    installed = ws24.validate_app_bundle(authority.installed_app, "installed")
    if ws24.sha256_file(installed) != authority.installed_executable_sha256:
        fail("installed executable changed during live evidence execution")


def _manifest_document(
    live_entries: dict[str, dict[str, Any]], incremental_entry: dict[str, Any]
) -> dict[str, Any]:
    by_gate = {**live_entries, "incremental-xcuitest": incremental_entry}
    if set(by_gate) != set(MANIFEST_GATE_ORDER):
        fail("manifest producer does not own the exact supplied gate set")
    return {"evidence": [by_gate[gate] for gate in MANIFEST_GATE_ORDER]}


def _validate_published_manifest(
    publication: secure_file.PublishedFile,
    *,
    expected_document: dict[str, Any],
    authority: Authority,
) -> secure_file.StableRegularFile:
    snapshot, observed = _stable_canonical_object(
        publication.path,
        label="published live-evidence manifest",
        maximum_bytes=MAXIMUM_MANIFEST_BYTES,
        require_private_mode=True,
    )
    if snapshot.sha256 != publication.sha256 or observed != expected_document:
        fail("published live-evidence manifest differs from canonical source bytes")
    _require_fresh_file(
        snapshot,
        exposed_at_unix_ns=authority.exposed_at_unix_ns,
        label="published live-evidence manifest",
    )
    if snapshot.payload is None or snapshot.payload.endswith(b"\n"):
        fail("published live-evidence manifest must have no trailing line feed")
    return snapshot


def _run(arguments: argparse.Namespace) -> tuple[Path, str]:
    authority = _load_authority(arguments)
    native_preparation = _load_native_preparation(
        arguments.native_preparation_receipt,
        authority=authority,
    )
    matrix_receipt = arguments.matrix_receipt
    semantic_manifest = arguments.xcresult_semantic_manifest
    network_root = _preflight_outputs(
        authority,
        matrix_receipt=matrix_receipt,
        semantic_manifest=semantic_manifest,
        network_root=arguments.network_artifact_root,
    )
    _invoke_live_runner(
        authority,
        native_preparation,
        timeout_seconds=arguments.live_gates_timeout_seconds,
    )
    live_entries, live_snapshots = _load_live_reports(authority)
    _revalidate_authority(authority)
    _revalidate_preparation(native_preparation, authority)
    descriptor_path = network_root / INCREMENTAL_DESCRIPTOR_NAME
    incremental = _load_incremental_evidence(
        authority,
        descriptor_path=descriptor_path,
        receipt_path=matrix_receipt,
        semantic_manifest_path=semantic_manifest,
        network_root=network_root,
    )
    _revalidate_authority(authority)
    _revalidate_preparation(native_preparation, authority)
    document = _manifest_document(live_entries, incremental.entry)
    payload = canonical_bytes(document)
    if not payload or len(payload) > MAXIMUM_MANIFEST_BYTES or payload.endswith(b"\n"):
        fail("canonical live-evidence manifest exceeds its bounded no-LF contract")
    _normalize_manifest(document, authority)
    output = authority.evidence_root / MANIFEST_NAME
    try:
        publication = secure_file.write_create_only(output, document)
    except secure_file.ExecutionReportError as error:
        fail(f"live-evidence manifest publication failed: {error}")
    try:
        _validate_published_manifest(
            publication,
            expected_document=document,
            authority=authority,
        )
        _revalidate_authority(authority)
        _revalidate_preparation(native_preparation, authority)
        observed_entries, observed_snapshots = _load_live_reports(authority)
        if observed_entries != live_entries or observed_snapshots != live_snapshots:
            fail("live execution reports changed after manifest publication")
        observed_incremental = _load_incremental_evidence(
            authority,
            descriptor_path=descriptor_path,
            receipt_path=matrix_receipt,
            semantic_manifest_path=semantic_manifest,
            network_root=network_root,
        )
        if observed_incremental != incremental:
            fail("installed incremental-XCUITest evidence changed after publication")
        _normalize_manifest(document, authority)
        _require_unchanged(
            _validate_published_manifest(
                publication,
                expected_document=document,
                authority=authority,
            ),
            label="published live-evidence manifest",
        )
    except BaseException:
        try:
            secure_file.remove_published_file(publication)
        except secure_file.ExecutionReportError as cleanup_error:
            raise LiveEvidenceError(
                "post-publication validation failed and the manifest could not be "
                f"removed safely: {cleanup_error}"
            ) from cleanup_error
        raise
    return output, publication.sha256


def main(argv: list[str] | None = None) -> int:
    try:
        arguments = parse_arguments(argv)
        output, digest = _run(arguments)
    except (
        CanonicalJSONError,
        LiveEvidenceError,
        OSError,
        ValueError,
        installer.InstallationError,
        installed_matrix_receipt.InstalledMatrixReceiptError,
        native_live_preparation_receipt.PreparationReceiptError,
        secure_file.ExecutionReportError,
        ws24.ReportError,
    ) as error:
        print(f"ERROR: installed live-evidence production failed: {error}", file=sys.stderr)
        return 2
    print(
        canonical_bytes(
            {
                "manifestPath": str(output),
                "manifestSHA256": digest,
            }
        ).decode("utf-8")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
