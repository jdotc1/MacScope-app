#!/usr/bin/env python3
"""Run the fail-closed installed-acceptance transaction."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import math
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterator, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, NoReturn


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts import ws24_emit_installed_qualification_report as ws24  # noqa: E402
from Scripts.reconstruction import install_release_to_applications as installer  # noqa: E402
from Scripts.reconstruction.app_quiescence import require_app_quiescent  # noqa: E402
from Scripts.reconstruction import (  # noqa: E402
    emit_installed_incremental_xcuitest_evidence as task10_evidence,
)
from Scripts.reconstruction import installed_matrix_receipt as matrix  # noqa: E402
from Scripts.reconstruction import network_attribution  # noqa: E402
from Scripts.reconstruction import native_live_preparation_receipt as preparation  # noqa: E402
from Scripts.reconstruction.qualification_xctestrun import resolve_xctestrun  # noqa: E402
from Scripts.reconstruction import (  # noqa: E402
    validate_qualification_product_identity as qualification,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)


SYSTEM_PYTHON = Path("/usr/bin/python3")
INSTALLER_SCRIPT = REPOSITORY_ROOT / "Scripts/reconstruction/install_release_to_applications.py"
WS24_REPORT_SCRIPT = REPOSITORY_ROOT / "Scripts/ws24_emit_installed_qualification_report.py"
EXPECTED_GATE_PLAN_COMPILER = (
    REPOSITORY_ROOT / "Scripts/reconstruction/compile_installed_acceptance_gate_plan.py"
)
TASK10_MATRIX_SCRIPT = (
    REPOSITORY_ROOT / "Scripts/reconstruction/run_installed_task10_matrix.py"
)
INCREMENTAL_XCUITEST_SCRIPT = (
    REPOSITORY_ROOT
    / "Scripts/reconstruction/emit_installed_incremental_xcuitest_evidence.py"
)

CANDIDATE_IDENTITY_NAME = "candidate.json"
PREPARATION_RECEIPT_NAME = "NativeLivePreparation.receipt.json"
INSTALLED_UI_PREPARATION_RECEIPT_NAME = "InstalledUIPreparation.receipt.json"
RESULT_NAME = "InstalledAcceptanceTransaction.result.json"
INSTALLER_ARTIFACT_ROOT_NAME = "MacScopeInstaller.acceptance-artifacts"
GATE_EVIDENCE_ROOT_NAME = "InstalledAcceptanceGate.evidence"
QUALIFICATION_ROOT_NAME = "InstalledAcceptanceQualification.evidence"
GATE_PLAN_NAME = "InstalledAcceptanceGate.plan.json"
WS24_REPORT_NAME = "WS24.installed-qualification.json"
LIVE_EVIDENCE_NAME = "live-evidence.json"
CLI_GUI_REPORT_NAME = "cli-gui-operability.report.json"
MCP_REPORT_NAME = "mcp-operability.report.json"
TASK10_XCRESULT_NAME = "InstalledTask10.xcresult"
TASK10_SEMANTIC_MANIFEST_NAME = "InstalledTask10.xcresult-semantic.json"
TASK10_MATRIX_RECEIPT_NAME = "InstalledTask10.matrix-receipt.json"
TASK10_NETWORK_ROOT_NAME = "installed-task10-network"
TASK10_INCREMENTAL_EVIDENCE_NAME = (
    "InstalledTask10.incremental-xcuitest.evidence.json"
)
NETWORK_AUDIT_REPORT_NAME = "InstalledNetworkAcquisition.audit.json"
NETWORK_EXECUTION_REPORT_NAME = "InstalledNetworkAcquisition.execution-report.json"
NETWORK_OBSERVATION_NAME = "InstalledNetworkAcquisition.nettop.csv"

REQUIRED_ACCEPTANCE_GATES = installer.REQUIRED_ACCEPTANCE_GATES
MAX_COMMAND_STREAM_BYTES = 4 * 1024 * 1024
MAX_GATE_PLAN_BYTES = 1024 * 1024
MAX_RESULT_BYTES = 1024 * 1024
MAX_QUALIFICATION_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_PREPARATION_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_PLAN_OPERATION_TIMEOUT_SECONDS = 3_600
TASK10_INTERNAL_TIMEOUT_SECONDS = 1_800
TASK10_OUTER_TIMEOUT_SECONDS = 1_860
INCREMENTAL_XCUITEST_TIMEOUT_SECONDS = 300
MAX_TASK10_RECEIPT_BYTES = 16 * 1024 * 1024
MAX_TASK10_SEMANTIC_MANIFEST_BYTES = 16 * 1024 * 1024
MAX_INCREMENTAL_XCUITEST_EVIDENCE_BYTES = 1024 * 1024
PROCESS_POLL_SECONDS = 0.025
PROCESS_TERM_GRACE_SECONDS = 2.0
PROCESS_KILL_GRACE_SECONDS = 2.0

BASE_ENVIRONMENT = {
    "LANG": "C",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "NO_PROXY": "*",
    "no_proxy": "*",
}
TASK10_ENVIRONMENT = {
    **BASE_ENVIRONMENT,
    "HOME": "/var/empty",
    "LOGNAME": "nobody",
    "TMPDIR": "/private/tmp",
    "USER": "nobody",
}
PLAN_ENVIRONMENT_FIELDS = frozenset(
    {*BASE_ENVIRONMENT, "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256"}
)
PLAN_TOP_LEVEL_FIELDS = frozenset(
    {
        "schema_version",
        "plan_kind",
        "candidate_artifact_root",
        "evidence_root",
        "output_path",
        "authority",
        "authority_sha256",
        "gates",
    }
)
PLAN_AUTHORITY_FIELDS = frozenset(
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
        "installed_task10_incremental_evidence_path",
        "installed_task10_matrix_receipt_path",
        "installed_task10_network_artifact_root",
        "installed_task10_xcresult_path",
        "installed_task10_xcresult_semantic_manifest_path",
        "native_preparation_receipt_path",
        "native_preparation_receipt_sha256",
        "native_xctestrun_path",
        "native_xctestrun_sha256",
        "pending_state_path",
        "pending_state_sha256",
        "predecessor_observations_sha256",
        "predecessor_digest",
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
PLAN_GATE_FIELDS = frozenset(
    {
        "gate_id",
        "operation_id",
        "authority_sha256",
        "argv",
        "depends_on",
        "environment",
        "timeout_seconds",
        "output",
    }
)
PLAN_OUTPUT_FIELDS = frozenset(
    {"kind", "maximum_bytes", "path", "publication"}
)
GATE_OUTPUT_MAXIMUM_BYTES = {
    "cli": 65_536,
    "forced-legacy-grid": 4_194_304,
    "full-surface": 4_194_304,
    "gui": 65_536,
    "mcp": 65_536,
    "native-xpc": 1_048_576,
    "shellbroker-launchagent": 8_388_608,
    "signing": 8_388_608,
}
RESULT_TOP_LEVEL_FIELDS = frozenset(
    {
        "schema_version",
        "result_kind",
        "result",
        "rolled_back",
        "transaction_phase",
        "produced_at_unix_ns",
        "candidate",
        "qualification_run",
        "transaction",
        "pending_state",
        "gate_plan",
        "gate_envelopes",
        "installed_task10",
        "acceptance_receipt",
        "terminal_committed_state",
        "commit_authority",
    }
)
BEGIN_STDOUT_KEYS = (
    "MACSCOPE_INSTALL_RELEASE_PHASE",
    "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN",
    "MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID",
    "MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE",
    "MACSCOPE_INSTALL_RELEASE_PENDING_STATE",
    "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256",
    "MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT",
)
CLOSEOUT_STDOUT_KEYS = (
    "MACSCOPE_INSTALL_RELEASE_PHASE",
    "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN",
)


class TransactionError(RuntimeError):
    """The transaction cannot safely proceed."""


class TransactionInterrupted(TransactionError):
    def __init__(self, signal_number: int) -> None:
        self.signal_number = signal_number
        try:
            name = signal.Signals(signal_number).name
        except ValueError:
            name = str(signal_number)
        super().__init__(f"coordinator received {name}")


class TransactionFailed(TransactionError):
    def __init__(
        self,
        primary: str,
        *,
        rollback_attempted: bool,
        rollback_succeeded: bool | None,
        rollback_diagnostic: str | None,
    ) -> None:
        self.primary = primary
        self.rollback_attempted = rollback_attempted
        self.rollback_succeeded = rollback_succeeded
        self.rollback_diagnostic = rollback_diagnostic
        super().__init__(primary)


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: bytes
    stderr: bytes
    timed_out: bool = False
    stdout_overflow: bool = False
    stderr_overflow: bool = False
    descendant_cleanup_failed: bool = False

    @property
    def signal_number(self) -> int | None:
        return -self.returncode if self.returncode < 0 else None


CommandRunner = Callable[[tuple[str, ...], float, Mapping[str, str]], CommandResult]


@dataclass(frozen=True)
class PlannedFile:
    path: Path
    parent_device: int
    parent_inode: int
    maximum_bytes: int


@dataclass(frozen=True)
class FileSnapshot:
    path: Path
    metadata: tuple[int, int, int, int, int, int, int]
    payload: bytes
    sha256: str


@dataclass(frozen=True)
class Timeouts:
    begin: float
    compiler: float
    report: float
    commit: float
    rollback: float


@dataclass(frozen=True)
class BoundRequest:
    python_executable: Path
    installer_script: Path
    report_script: Path
    gate_plan_compiler: Path
    task10_matrix_script: Path
    incremental_xcuitest_script: Path
    qualification_receipt: FileSnapshot
    candidate_artifact_root: Path
    candidate_identity: Path
    preparation_receipt: FileSnapshot
    installed_ui_preparation_receipt: FileSnapshot
    installed_ui_preparation_document: Mapping[str, object]
    installed_ui_prepared_app: Path
    installed_ui_xctestrun: FileSnapshot
    installed_ui_test_bundle: Path
    installed_ui_runner: Path
    native_xctestrun: FileSnapshot
    source_app: Path
    installed_app: Path
    work_root: Path
    artifact_root: Path
    evidence_root: Path
    qualification_root: Path
    gate_plan_path: Path
    result_output: PlannedFile
    qualification_run: QualificationRunAuthority
    predecessor_observations_sha256: str
    xcode_developer_dir: Path
    source_authority: Any
    candidate_token: str
    candidate_identity_snapshot: FileSnapshot
    provenance_snapshot: FileSnapshot
    timeouts: Timeouts


@dataclass(frozen=True)
class PendingBinding:
    state: Mapping[str, object]
    state_file: installer.StableFile
    state_sha256: str
    transaction_id: str
    transaction_nonce: str
    acceptance_receipt: Path


@dataclass(frozen=True)
class GateOutput:
    kind: str
    maximum_bytes: int
    path: Path


@dataclass(frozen=True)
class GateSpec:
    gate_id: str
    operation_id: str
    argv: tuple[str, ...]
    depends_on: tuple[str, ...]
    environment: Mapping[str, str]
    timeout_seconds: int
    output: GateOutput


@dataclass(frozen=True)
class GatePlan:
    snapshot: FileSnapshot
    authority: Mapping[str, object]
    authority_sha256: str
    gates: tuple[GateSpec, ...]


@dataclass(frozen=True)
class Task10Paths:
    xcresult: Path
    semantic_manifest: PlannedFile
    matrix_receipt: PlannedFile
    network_root: Path
    incremental_evidence: Path


@dataclass(frozen=True)
class DirectoryIdentity:
    path: Path
    device: int
    inode: int
    mode: int


@dataclass(frozen=True)
class Task10Publication:
    paths: Task10Paths
    matrix_receipt: FileSnapshot
    semantic_manifest: FileSnapshot
    incremental_evidence: FileSnapshot
    xcresult: DirectoryIdentity
    network_root: DirectoryIdentity
    xcresult_bundle_sha256: str
    xcresult_closed_tree_sha256: str
    network_audit_report: FileSnapshot
    network_execution_report: FileSnapshot
    network_observation: FileSnapshot


@dataclass(frozen=True)
class WS24Inputs:
    live_evidence: FileSnapshot
    full_surface: FileSnapshot
    legacy_grid: FileSnapshot
    cli_gui: FileSnapshot
    mcp: FileSnapshot
    native_xpc: FileSnapshot


@dataclass(frozen=True)
class WS24Publication:
    report: FileSnapshot
    gate_envelopes: tuple[tuple[str, FileSnapshot], ...]


@dataclass(frozen=True)
class GateExecution:
    outputs: tuple[tuple[str, FileSnapshot], ...]
    publication: WS24Publication


@dataclass(frozen=True)
class TerminalBinding:
    committed_root: Path
    state: FileSnapshot
    acceptance_receipt: FileSnapshot
    commit_authority: FileSnapshot


@dataclass(frozen=True)
class TransactionOutcome:
    result_output: Path
    document: Mapping[str, object]


def _fail(message: str) -> NoReturn:
    raise TransactionError(message)


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


def _bounded_diagnostic(value: object, *, maximum_bytes: int = 2048) -> str:
    text = value.decode("utf-8", errors="replace") if isinstance(value, bytes) else str(value)
    text = " ".join(text.replace("\x00", "�").split())
    payload = text.encode("utf-8")
    if len(payload) <= maximum_bytes:
        return text or "unspecified failure"
    return payload[:maximum_bytes].decode("utf-8", errors="ignore") + "…"


def _canonical_existing(path: Path, *, directory: bool, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be an absolute canonical path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        _fail(f"{label} is unavailable: {error}")
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "regular file"
        _fail(f"{label} must be a non-symlink {kind}")
    if resolved != path:
        _fail(f"{label} must not traverse symbolic links")
    if not directory and metadata.st_nlink != 1:
        _fail(f"{label} must be a single-link regular file")
    return resolved


def _trusted_system_python(path: Path) -> Path:
    if path != SYSTEM_PYTHON:
        _fail(f"system Python must be exactly {SYSTEM_PYTHON}")
    if not path.is_absolute():
        _fail("system Python must be an absolute canonical path")
    try:
        before_path = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        _fail(f"system Python is unavailable: {error}")
    if (
        not stat.S_ISREG(before_path.st_mode)
        or stat.S_ISLNK(before_path.st_mode)
        or resolved != path
    ):
        _fail("system Python must be a canonical non-symlink regular file")

    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail(f"system Python is unavailable: {error}")
    try:
        before_descriptor = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before_descriptor.st_mode)
            or (before_descriptor.st_dev, before_descriptor.st_ino)
            != (before_path.st_dev, before_path.st_ino)
            or before_descriptor.st_size <= 0
        ):
            _fail("system Python physical identity is invalid")

        def read_exact_bytes() -> bytes:
            remaining = before_descriptor.st_size
            chunks: list[bytes] = []
            while remaining:
                block = os.read(descriptor, min(remaining, 1024 * 1024))
                if not block:
                    break
                chunks.append(block)
                remaining -= len(block)
            if remaining or os.read(descriptor, 1):
                _fail("system Python changed while it was read")
            return b"".join(chunks)

        first_payload = read_exact_bytes()
        os.lseek(descriptor, 0, os.SEEK_SET)
        second_payload = read_exact_bytes()
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
        executable = os.access(path, os.X_OK)
    except OSError as error:
        _fail(f"system Python could not be validated safely: {error}")
    finally:
        os.close(descriptor)
    if (
        first_payload != second_payload
        or _metadata(before_path) != _metadata(before_descriptor)
        or _metadata(before_path) != _metadata(after_descriptor)
        or _metadata(before_path) != _metadata(after_path)
    ):
        _fail("system Python changed while it was validated")
    if not executable:
        _fail("system Python is not executable")
    return resolved


def _require_absent_path(path: Path, *, parent: Path, label: str) -> Path:
    if not path.is_absolute() or path.parent != parent or not path.name:
        _fail(f"{label} must be an absent direct child of its governed root")
    try:
        path.lstat()
    except FileNotFoundError:
        return path
    except OSError as error:
        _fail(f"{label} cannot be inspected: {error}")
    _fail(f"{label} must be absent (create-only)")


def _plan_absent_file(path: Path, *, label: str, maximum_bytes: int) -> PlannedFile:
    if not path.is_absolute() or not path.name or path.name in {".", ".."}:
        _fail(f"{label} must be an absent absolute canonical path")
    parent = _canonical_existing(path.parent, directory=True, label=f"{label} parent")
    if parent / path.name != path:
        _fail(f"{label} must be canonical")
    _require_absent_path(path, parent=parent, label=label)
    metadata = parent.lstat()
    return PlannedFile(path, metadata.st_dev, metadata.st_ino, maximum_bytes)


def _read_stable_file(path: Path, *, label: str, maximum_bytes: int) -> FileSnapshot:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail(f"{label} is unavailable: {error}")
    try:
        before = os.fstat(descriptor)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size <= 0
            or before.st_size > maximum_bytes
        ):
            _fail(f"{label} is not one bounded ordinary file")
        chunks: list[bytes] = []
        remaining = before.st_size
        while remaining:
            block = os.read(descriptor, min(remaining, 1024 * 1024))
            if not block:
                break
            chunks.append(block)
            remaining -= len(block)
        after_descriptor = os.fstat(descriptor)
        after_path = path.lstat()
    except OSError as error:
        _fail(f"{label} could not be read safely: {error}")
    finally:
        os.close(descriptor)
    payload = b"".join(chunks)
    if (
        _metadata(before) != _metadata(after_descriptor)
        or _metadata(before) != _metadata(after_path)
        or len(payload) != before.st_size
    ):
        _fail(f"{label} changed while it was read")
    if path.resolve(strict=True) != path:
        _fail(f"{label} traverses a symbolic link")
    return FileSnapshot(path, _metadata(before), payload, hashlib.sha256(payload).hexdigest())


def _read_planned_file(plan: PlannedFile, *, label: str) -> FileSnapshot:
    parent = _canonical_existing(plan.path.parent, directory=True, label=f"{label} parent")
    metadata = parent.lstat()
    if (metadata.st_dev, metadata.st_ino) != (plan.parent_device, plan.parent_inode):
        _fail(f"{label} parent physical identity changed")
    return _read_stable_file(plan.path, label=label, maximum_bytes=plan.maximum_bytes)


def _assert_snapshot_unchanged(snapshot: FileSnapshot, *, label: str) -> None:
    observed = _read_stable_file(
        snapshot.path, label=label, maximum_bytes=max(len(snapshot.payload), 1)
    )
    if observed.metadata != snapshot.metadata or observed.payload != snapshot.payload:
        _fail(f"{label} changed after it was bound")


def _path_related(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def _is_sha256(value: object) -> bool:
    return isinstance(value, str) and installer.is_sha256(value)


def _closed_mapping(
    value: object, fields: frozenset[str], *, label: str
) -> Mapping[str, object]:
    if not isinstance(value, dict) or set(value) != fields:
        _fail(f"{label} does not have its exact closed field set")
    return value


def _positive_timeout(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("timeout must be a number") from error
    if not math.isfinite(parsed) or not (0.01 <= parsed <= 86_400.0):
        raise argparse.ArgumentTypeError(
            "timeout must be finite and between 0.01 and 86400 seconds"
        )
    return parsed


class _StoreOnce(argparse.Action):
    def __call__(
        self,
        parser: argparse.ArgumentParser,
        namespace: argparse.Namespace,
        values: object,
        option_string: str | None = None,
    ) -> None:
        if hasattr(namespace, self.dest):
            parser.error(f"{option_string} may be supplied exactly once")
        setattr(namespace, self.dest, values)


def _required(parser: argparse.ArgumentParser, name: str, **kwargs: object) -> None:
    parser.add_argument(
        name,
        action=_StoreOnce,
        required=True,
        default=argparse.SUPPRESS,
        **kwargs,
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    _required(parser, "--gate-plan-compiler", type=Path)
    _required(parser, "--qualification-receipt", type=Path)
    _required(parser, "--qualification-run-id")
    _required(parser, "--qualification-run-nonce")
    _required(parser, "--predecessor-observations-sha256")
    _required(parser, "--candidate-artifact-root", type=Path)
    _required(parser, "--work-root", type=Path)
    _required(parser, "--installed-app", type=Path)
    _required(parser, "--begin-timeout-seconds", type=_positive_timeout)
    _required(parser, "--compiler-timeout-seconds", type=_positive_timeout)
    _required(parser, "--report-timeout-seconds", type=_positive_timeout)
    _required(parser, "--commit-timeout-seconds", type=_positive_timeout)
    _required(parser, "--rollback-timeout-seconds", type=_positive_timeout)
    _required(parser, "--result-output", type=Path)
    return parser


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    return _parser().parse_args(argv)


def _prepared_xctestrun_paths(
    products_root: Path, native_document: Mapping[str, Any], ui_document: Mapping[str, Any]
) -> tuple[Path, Path]:
    """Resolve only the receipt-bound SDK; full preparation validation still follows."""
    try:
        sdk_version = native_document["toolchain"]["sdk_version"]
        if sdk_version != ui_document["toolchain"]["sdk_version"]:
            _fail("native and installed UI receipts bind different SDK versions")
        return (
            resolve_xctestrun(products_root, "MacScopeApp", sdk_version),
            resolve_xctestrun(products_root, "MacScopeInstalledAppUITests", sdk_version),
        )
    except (KeyError, TypeError, ValueError, OSError) as error:
        _fail(f"qualification prepared xctestrun SDK binding is invalid: {error}")


def _bind_request(arguments: argparse.Namespace, *, allow_test_destination: bool) -> BoundRequest:
    python_executable = _trusted_system_python(SYSTEM_PYTHON)
    installer_script = _canonical_existing(
        INSTALLER_SCRIPT, directory=False, label="canonical installer"
    )
    report_script = _canonical_existing(
        WS24_REPORT_SCRIPT, directory=False, label="canonical WS24 producer"
    )
    task10_matrix_script = _canonical_existing(
        TASK10_MATRIX_SCRIPT,
        directory=False,
        label="canonical installed Task10 matrix runner",
    )
    incremental_xcuitest_script = _canonical_existing(
        INCREMENTAL_XCUITEST_SCRIPT,
        directory=False,
        label="canonical incremental XCUITest evidence projector",
    )
    compiler = _canonical_existing(
        arguments.gate_plan_compiler, directory=False, label="gate-plan compiler"
    )
    if compiler != EXPECTED_GATE_PLAN_COMPILER.resolve(strict=True):
        _fail("gate-plan compiler must be the canonical repository compiler")

    qualification_receipt = _read_stable_file(
        _canonical_existing(
            arguments.qualification_receipt,
            directory=False,
            label="qualification receipt",
        ),
        label="qualification receipt",
        maximum_bytes=MAX_QUALIFICATION_RECEIPT_BYTES,
    )
    if qualification_receipt.path.name != "QUALIFICATION_INPUTS.json":
        _fail("qualification receipt must be named QUALIFICATION_INPUTS.json")
    try:
        qualification_document = qualification._decode_canonical_line(
            qualification_receipt.payload,
            label="qualification receipt",
        )
    except qualification.ProductIdentityError as error:
        _fail(f"qualification receipt is not canonical line JSON: {error}")
    if (
        not isinstance(qualification_document, dict)
        or qualification_document.get("schema_version") != 4
        or qualification_document.get("mode") != "full-test"
        or qualification_document.get("dependency_network_used") is not False
    ):
        _fail(
            "qualification receipt must be the canonical offline schema-4 "
            "full-test receipt"
        )

    candidate_root = _canonical_existing(
        arguments.candidate_artifact_root,
        directory=True,
        label="candidate artifact root",
    )
    qualification_run_root = _canonical_existing(
        candidate_root.parent,
        directory=True,
        label="qualification run root",
    )
    if (
        candidate_root.name != "candidate-artifacts"
        or qualification_receipt.path
        != qualification_run_root / "QUALIFICATION_INPUTS.json"
    ):
        _fail("candidate artifacts are not owned by the exact qualification run")
    candidate_identity = _canonical_existing(
        candidate_root / CANDIDATE_IDENTITY_NAME,
        directory=False,
        label="candidate identity",
    )
    candidate_snapshot = _read_stable_file(
        candidate_identity,
        label="candidate identity",
        maximum_bytes=installer.MAX_CANDIDATE_BYTES,
    )
    preparation_path = _canonical_existing(
        candidate_root / PREPARATION_RECEIPT_NAME,
        directory=False,
        label="native preparation receipt",
    )
    preparation_snapshot = _read_stable_file(
        preparation_path,
        label="native preparation receipt",
        maximum_bytes=MAX_PREPARATION_RECEIPT_BYTES,
    )
    try:
        preparation_document = preparation.parse_document(
            decode_canonical_bytes(preparation_snapshot.payload)
        )
    except (CanonicalJSONError, preparation.PreparationReceiptError) as error:
        _fail(f"native preparation receipt is invalid: {error}")
    mode = preparation_document["build"].get(
        "preparation_mode", preparation.NATIVE_LIVE_PREPARATION_MODE
    )
    if mode != preparation.NATIVE_LIVE_PREPARATION_MODE:
        _fail("candidate root must carry the native-live preparation receipt")
    installed_ui_preparation_path = _canonical_existing(
        candidate_root / INSTALLED_UI_PREPARATION_RECEIPT_NAME,
        directory=False,
        label="installed UI preparation receipt",
    )
    installed_ui_preparation_snapshot = _read_stable_file(
        installed_ui_preparation_path,
        label="installed UI preparation receipt",
        maximum_bytes=MAX_PREPARATION_RECEIPT_BYTES,
    )
    try:
        installed_ui_preparation_document = preparation.parse_document(
            decode_canonical_bytes(installed_ui_preparation_snapshot.payload)
        )
    except (CanonicalJSONError, preparation.PreparationReceiptError) as error:
        _fail(f"installed UI preparation receipt is invalid: {error}")
    if (
        installed_ui_preparation_document.get("schema_version")
        != preparation.SCHEMA_VERSION
        or installed_ui_preparation_document.get("receipt_kind")
        != preparation.RECEIPT_KIND
        or installed_ui_preparation_document["build"].get("preparation_mode")
        != preparation.INSTALLED_UI_PREPARATION_MODE
        or installed_ui_preparation_document["source"]
        != preparation_document["source"]
    ):
        _fail(
            "installed UI preparation receipt does not bind the exact schema-2 "
            "candidate source"
        )
    native_xctestrun = _read_stable_file(
        _canonical_existing(
            Path(str(preparation_document["artifacts"]["xctestrun"]["path"])),
            directory=False,
            label="native xctestrun",
        ),
        label="native xctestrun",
        maximum_bytes=MAX_PREPARATION_RECEIPT_BYTES,
    )
    source_app = _canonical_existing(
        Path(str(preparation_document["artifacts"]["app"]["path"])),
        directory=True,
        label="source app",
    )
    if source_app.name != "MacScope.app":
        _fail("source app must be named MacScope.app")
    xcode_developer_dir = _canonical_existing(
        Path(str(preparation_document["toolchain"]["developer_dir"])),
        directory=True,
        label="Xcode developer directory",
    )
    installed_ui_artifacts = installed_ui_preparation_document["artifacts"]
    installed_ui_xctestrun = _read_stable_file(
        _canonical_existing(
            Path(str(installed_ui_artifacts["xctestrun"]["path"])),
            directory=False,
            label="installed UI xctestrun",
        ),
        label="installed UI xctestrun",
        maximum_bytes=MAX_PREPARATION_RECEIPT_BYTES,
    )
    installed_ui_prepared_app = _canonical_existing(
        Path(str(installed_ui_artifacts["app"]["path"])),
        directory=True,
        label="installed UI prepared app",
    )
    installed_ui_test_bundle = _canonical_existing(
        Path(str(installed_ui_artifacts["ui_test_bundle"]["path"])),
        directory=True,
        label="installed UI test bundle",
    )
    installed_ui_runner = _canonical_existing(
        Path(str(installed_ui_artifacts["ui_runner"]["path"])),
        directory=True,
        label="installed UI runner",
    )
    installed_ui_developer_dir = _canonical_existing(
        Path(str(installed_ui_preparation_document["toolchain"]["developer_dir"])),
        directory=True,
        label="installed UI Xcode developer directory",
    )
    if installed_ui_developer_dir != xcode_developer_dir:
        _fail("native and installed UI receipts bind different Xcode directories")
    products_root = _canonical_existing(
        qualification_run_root / "DerivedData/Build/Products",
        directory=True,
        label="qualification products root",
    )
    expected_installed_ui_runner = (
        products_root / "Debug/MacScopeInstalledAppUITests-Runner.app"
    )
    expected_installed_ui_bundle = (
        expected_installed_ui_runner
        / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
    )
    expected_native_xctestrun, expected_ui_xctestrun = _prepared_xctestrun_paths(
        products_root, preparation_document, installed_ui_preparation_document
    )
    if (
        native_xctestrun.path
        != expected_native_xctestrun
        or installed_ui_xctestrun.path
        != expected_ui_xctestrun
        or source_app != products_root / "Release/MacScope.app"
        or installed_ui_prepared_app != source_app
        or installed_ui_runner != expected_installed_ui_runner
        or installed_ui_test_bundle != expected_installed_ui_bundle
    ):
        _fail("qualification prepared products differ from the exact full-test layout")
    try:
        preparation.validate_prepared(
            preparation_document,
            native_xctestrun.path,
            source_app,
            candidate_identity,
        )
        preparation.validate_prepared(
            installed_ui_preparation_document,
            installed_ui_xctestrun.path,
            installed_ui_prepared_app,
            candidate_identity,
            test_bundle=installed_ui_test_bundle,
            ui_runner=installed_ui_runner,
        )
        source_authority = installer._load_source_authority(
            candidate_identity, source_app
        )
    except (
        preparation.PreparationReceiptError,
        installer.InstallationError,
        OSError,
        CanonicalJSONError,
    ) as error:
        _fail(f"candidate/source authority is invalid: {error}")
    candidate_token = source_authority.candidate_identity_sha256

    try:
        installed_app = installer._canonical_destination(arguments.installed_app)
    except installer.InstallationError as error:
        _fail(str(error))
    if not allow_test_destination and installed_app != installer.PRODUCTION_DESTINATION:
        _fail(
            "production destination must be exactly "
            f"{installer.PRODUCTION_DESTINATION}"
        )
    if source_app == installed_app:
        _fail("source and installed apps must be distinct")

    work_root = _canonical_existing(
        arguments.work_root, directory=True, label="work root"
    )
    if stat.S_IMODE(work_root.lstat().st_mode) != 0o700:
        _fail("work root mode is not private")
    try:
        if any(work_root.iterdir()):
            _fail("work root must be empty at transaction admission")
    except OSError as error:
        _fail(f"work root cannot be enumerated: {error}")
    dependency_cache_root = _canonical_existing(
        Path(str(qualification_document.get("dependency_cache_root"))),
        directory=True,
        label="qualification dependency cache root",
    )
    ghostty_source_root = _canonical_existing(
        Path(str(qualification_document.get("ghostty_source_dir"))),
        directory=True,
        label="qualification Ghostty source root",
    )
    sleigh_materialization_root = _canonical_existing(
        Path(str(qualification_document.get("sleigh_materialization_root"))),
        directory=True,
        label="qualification SLEIGH materialization root",
    )
    protected = (
        REPOSITORY_ROOT,
        qualification_run_root,
        candidate_root,
        source_app,
        installed_app,
        dependency_cache_root,
        ghostty_source_root,
        sleigh_materialization_root,
    )
    if any(_path_related(work_root, path) for path in protected):
        _fail(
            "work root must be disjoint from repository, qualification, "
            "candidate, source, destination, and dependency authority"
        )

    artifact_root = _require_absent_path(
        work_root / INSTALLER_ARTIFACT_ROOT_NAME,
        parent=work_root,
        label="installer artifact root",
    )
    evidence_root = _require_absent_path(
        work_root / GATE_EVIDENCE_ROOT_NAME,
        parent=work_root,
        label="gate evidence root",
    )
    qualification_root = _require_absent_path(
        work_root / QUALIFICATION_ROOT_NAME,
        parent=work_root,
        label="qualification evidence root",
    )
    result_path = arguments.result_output
    if result_path != work_root / RESULT_NAME:
        _fail(f"result output must be exactly {work_root / RESULT_NAME}")
    result_output = _plan_absent_file(
        result_path, label="transaction result", maximum_bytes=MAX_RESULT_BYTES
    )

    try:
        qualification_run = QualificationRunAuthority(
            run_id=arguments.qualification_run_id,
            nonce=arguments.qualification_run_nonce,
        )
    except Exception as error:
        _fail(f"qualification run authority is invalid: {error}")
    if (
        installer.STABLE_ID_RE.fullmatch(qualification_run.run_id) is None
        or not installer.is_sha256(qualification_run.nonce)
    ):
        _fail("qualification run authority is not canonical")
    if not installer.is_sha256(arguments.predecessor_observations_sha256):
        _fail("predecessor observations digest must be lowercase SHA-256")

    provenance_snapshot = _read_stable_file(
        source_app / installer.BUILD_PROVENANCE_RELATIVE_PATH,
        label="source build provenance",
        maximum_bytes=installer.MAX_CANDIDATE_BYTES,
    )
    if provenance_snapshot.sha256 != source_authority.build_provenance_sha256:
        _fail("source provenance changed after source-authority validation")

    return BoundRequest(
        python_executable=python_executable,
        installer_script=installer_script,
        report_script=report_script,
        gate_plan_compiler=compiler,
        task10_matrix_script=task10_matrix_script,
        incremental_xcuitest_script=incremental_xcuitest_script,
        qualification_receipt=qualification_receipt,
        candidate_artifact_root=candidate_root,
        candidate_identity=candidate_identity,
        preparation_receipt=preparation_snapshot,
        installed_ui_preparation_receipt=(
            installed_ui_preparation_snapshot
        ),
        installed_ui_preparation_document=installed_ui_preparation_document,
        installed_ui_prepared_app=installed_ui_prepared_app,
        installed_ui_xctestrun=installed_ui_xctestrun,
        installed_ui_test_bundle=installed_ui_test_bundle,
        installed_ui_runner=installed_ui_runner,
        native_xctestrun=native_xctestrun,
        source_app=source_app,
        installed_app=installed_app,
        work_root=work_root,
        artifact_root=artifact_root,
        evidence_root=evidence_root,
        qualification_root=qualification_root,
        gate_plan_path=evidence_root / GATE_PLAN_NAME,
        result_output=result_output,
        qualification_run=qualification_run,
        predecessor_observations_sha256=arguments.predecessor_observations_sha256,
        xcode_developer_dir=xcode_developer_dir,
        source_authority=source_authority,
        candidate_token=candidate_token,
        candidate_identity_snapshot=candidate_snapshot,
        provenance_snapshot=provenance_snapshot,
        timeouts=Timeouts(
            begin=arguments.begin_timeout_seconds,
            compiler=arguments.compiler_timeout_seconds,
            report=arguments.report_timeout_seconds,
            commit=arguments.commit_timeout_seconds,
            rollback=arguments.rollback_timeout_seconds,
        ),
    )


def _create_private_directory(path: Path, *, parent: Path, label: str) -> Path:
    _require_absent_path(path, parent=parent, label=label)
    try:
        os.mkdir(path, 0o700)
    except OSError as error:
        _fail(f"cannot create {label}: {error}")
    canonical = _canonical_existing(path, directory=True, label=label)
    if stat.S_IMODE(canonical.lstat().st_mode) != 0o700:
        _fail(f"{label} mode is not private")
    return canonical


def _write_create_only_bytes(
    plan: PlannedFile, payload: bytes, *, label: str
) -> FileSnapshot:
    if not payload or len(payload) > plan.maximum_bytes:
        _fail(f"{label} payload violates its bounded contract")
    parent = _canonical_existing(
        plan.path.parent, directory=True, label=f"{label} parent"
    )
    metadata = parent.lstat()
    if (metadata.st_dev, metadata.st_ino) != (
        plan.parent_device,
        plan.parent_inode,
    ):
        _fail(f"{label} parent physical identity changed")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    created = False
    try:
        descriptor = os.open(plan.path, flags, 0o600)
        created = True
        try:
            offset = 0
            while offset < len(payload):
                offset += os.write(descriptor, payload[offset:])
            os.fsync(descriptor)
            observed = os.fstat(descriptor)
            if (
                not stat.S_ISREG(observed.st_mode)
                or observed.st_nlink != 1
                or stat.S_IMODE(observed.st_mode) != 0o600
                or observed.st_size != len(payload)
            ):
                _fail(f"{label} publication identity is invalid")
        finally:
            os.close(descriptor)
        directory_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
        snapshot = _read_planned_file(plan, label=label)
        if snapshot.payload != payload:
            _fail(f"{label} bytes differ after publication")
        return snapshot
    except BaseException as error:
        cleanup_error: OSError | None = None
        if created:
            try:
                plan.path.unlink()
                directory_descriptor = os.open(parent, os.O_RDONLY)
                try:
                    os.fsync(directory_descriptor)
                finally:
                    os.close(directory_descriptor)
            except OSError as observed:
                cleanup_error = observed
        if cleanup_error is not None:
            _fail(
                f"cannot publish {label}: {_bounded_diagnostic(error)}; "
                f"cannot remove its private partial output: {cleanup_error}"
            )
        if isinstance(error, TransactionError):
            raise
        _fail(f"cannot publish {label}: {error}")


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _wait_for_group_exit(
    process: subprocess.Popen[bytes], process_group_id: int, timeout: float
) -> bool:
    deadline = time.monotonic() + timeout
    while True:
        process.poll()
        if not _process_group_exists(process_group_id):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(PROCESS_POLL_SECONDS)


def _signal_owned_group(
    process: subprocess.Popen[bytes],
    process_group_id: int,
    process_signal: signal.Signals,
) -> None:
    if process_group_id != process.pid:
        _fail("refusing to signal a process group not owned by this transaction")
    try:
        os.killpg(process_group_id, process_signal)
    except ProcessLookupError:
        return
    except PermissionError:
        _fail("cannot signal the transaction-owned process group")


def _terminate_process_group(
    process: subprocess.Popen[bytes],
    process_group_id: int,
    *,
    term_grace: float = PROCESS_TERM_GRACE_SECONDS,
    kill_grace: float = PROCESS_KILL_GRACE_SECONDS,
) -> bool:
    _signal_owned_group(process, process_group_id, signal.SIGTERM)
    if _wait_for_group_exit(process, process_group_id, term_grace):
        return True
    _signal_owned_group(process, process_group_id, signal.SIGKILL)
    return _wait_for_group_exit(process, process_group_id, kill_grace)


def _run_command(
    argv: tuple[str, ...], timeout_seconds: float, environment: Mapping[str, str]
) -> CommandResult:
    """Run literal argv in one owned process group with closed environment/I/O."""
    if not argv or any(
        not isinstance(item, str) or not item or "\x00" in item for item in argv
    ):
        _fail("command argv is empty or unsafe")
    if (
        not math.isfinite(timeout_seconds)
        or timeout_seconds <= 0
        or any(
            not isinstance(key, str)
            or not key
            or "=" in key
            or "\x00" in key
            or not isinstance(value, str)
            or "\x00" in value
            for key, value in environment.items()
        )
    ):
        _fail("command timeout or environment is unsafe")
    timed_out = False
    stdout_overflow = False
    stderr_overflow = False
    descendant_cleanup_failed = False
    process: subprocess.Popen[bytes] | None = None
    process_group_id: int | None = None
    with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
        try:
            process = subprocess.Popen(
                list(argv),
                stdin=subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
                cwd=str(REPOSITORY_ROOT),
                env=dict(environment),
                shell=False,
                start_new_session=True,
                close_fds=True,
            )
            try:
                process_group_id = os.getpgid(process.pid)
            except ProcessLookupError:
                process_group_id = process.pid
            if process_group_id != process.pid:
                process.kill()
                process.wait()
                _fail("command did not enter its owned process group")
            deadline = time.monotonic() + timeout_seconds
            while process.poll() is None:
                stdout_overflow = (
                    os.fstat(stdout_file.fileno()).st_size > MAX_COMMAND_STREAM_BYTES
                )
                stderr_overflow = (
                    os.fstat(stderr_file.fileno()).st_size > MAX_COMMAND_STREAM_BYTES
                )
                if stdout_overflow or stderr_overflow:
                    descendant_cleanup_failed = not _terminate_process_group(
                        process, process_group_id
                    )
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    descendant_cleanup_failed = not _terminate_process_group(
                        process, process_group_id
                    )
                    break
                time.sleep(PROCESS_POLL_SECONDS)
            returncode = process.wait()
            if _process_group_exists(process_group_id):
                descendant_cleanup_failed = not _terminate_process_group(
                    process, process_group_id
                )
            stdout_file.seek(0)
            stderr_file.seek(0)
            stdout = stdout_file.read(MAX_COMMAND_STREAM_BYTES + 1)
            stderr = stderr_file.read(MAX_COMMAND_STREAM_BYTES + 1)
            stdout_overflow = stdout_overflow or len(stdout) > MAX_COMMAND_STREAM_BYTES
            stderr_overflow = stderr_overflow or len(stderr) > MAX_COMMAND_STREAM_BYTES
            return CommandResult(
                argv=argv,
                returncode=returncode,
                stdout=stdout[:MAX_COMMAND_STREAM_BYTES],
                stderr=stderr[:MAX_COMMAND_STREAM_BYTES],
                timed_out=timed_out,
                stdout_overflow=stdout_overflow,
                stderr_overflow=stderr_overflow,
                descendant_cleanup_failed=descendant_cleanup_failed,
            )
        except BaseException:
            if (
                process is not None
                and process_group_id is not None
                and _process_group_exists(process_group_id)
            ):
                with contextlib.suppress(Exception):
                    _terminate_process_group(process, process_group_id)
            raise


def _command_failure(
    result: CommandResult, *, label: str, require_empty_stderr: bool
) -> str | None:
    if result.timed_out:
        return f"{label} exceeded its bounded timeout"
    if result.stdout_overflow or result.stderr_overflow:
        streams = ", ".join(
            name
            for name, overflow in (
                ("stdout", result.stdout_overflow),
                ("stderr", result.stderr_overflow),
            )
            if overflow
        )
        return f"{label} exceeded bounded {streams}"
    if result.descendant_cleanup_failed:
        return f"{label} left a live process-group descendant"
    if result.signal_number is not None:
        return f"{label} terminated by signal {result.signal_number}"
    if result.returncode != 0:
        return (
            f"{label} exited {result.returncode}: "
            f"{_bounded_diagnostic(result.stderr or result.stdout)}"
        )
    if require_empty_stderr and result.stderr:
        return f"{label} emitted unexpected stderr: {_bounded_diagnostic(result.stderr)}"
    return None


def _require_successful_command(
    result: CommandResult, *, label: str, require_empty_stderr: bool
) -> None:
    failure = _command_failure(
        result, label=label, require_empty_stderr=require_empty_stderr
    )
    if failure is not None:
        _fail(failure)


def _decode_stdout(payload: bytes, *, label: str) -> str:
    try:
        value = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        _fail(f"{label} stdout is not UTF-8: {error}")
    if "\x00" in value:
        _fail(f"{label} stdout contains NUL")
    return value


def _strict_stdout_lines(payload: bytes, *, label: str) -> list[str]:
    value = _decode_stdout(payload, label=label)
    if not value or not value.endswith("\n") or "\r" in value:
        _fail(f"{label} stdout must use exact LF-terminated lines")
    lines = value[:-1].split("\n")
    if not lines or any(not line for line in lines):
        _fail(f"{label} stdout contains an empty or extra line")
    return lines


def _parse_key_value_stdout(
    payload: bytes, *, label: str, expected_keys: tuple[str, ...]
) -> dict[str, str]:
    lines = _strict_stdout_lines(payload, label=label)
    observed: dict[str, str] = {}
    order: list[str] = []
    for line in lines:
        key, separator, value = line.partition("=")
        if not separator or not key or not value or key in observed:
            _fail(f"{label} stdout is not its exact key-value contract")
        observed[key] = value
        order.append(key)
    if tuple(order) != expected_keys:
        _fail(f"{label} stdout fields differ from the exact contract")
    return observed


def _installer_argv(
    request: BoundRequest,
    phase: str,
    *,
    gate_inputs: Sequence[tuple[str, Path]] = (),
) -> tuple[str, ...]:
    argv = [
        str(request.python_executable),
        "-B",
        str(request.installer_script),
        "--phase",
        phase,
        "--transaction-token",
        request.candidate_token,
        "--candidate-identity",
        str(request.candidate_identity),
        "--source-app",
        str(request.source_app),
        "--installed-app",
        str(request.installed_app),
        "--artifact-root",
        str(request.artifact_root),
        "--qualification-run-id",
        request.qualification_run.run_id,
        "--qualification-run-nonce",
        request.qualification_run.nonce,
        "--predecessor-observations-sha256",
        request.predecessor_observations_sha256,
    ]
    for gate_id, path in gate_inputs:
        argv.extend(("--acceptance-gate-input", f"{gate_id}={path}"))
    return tuple(argv)


def _compiler_argv(request: BoundRequest, pending: PendingBinding) -> tuple[str, ...]:
    return (
        str(request.python_executable),
        "-B",
        str(request.gate_plan_compiler),
        "--qualification-receipt",
        str(request.qualification_receipt.path),
        "--candidate-artifact-root",
        str(request.candidate_artifact_root),
        "--installation-pending-state",
        str(pending.state_file.path),
        "--evidence-root",
        str(request.evidence_root),
        "--output",
        str(request.gate_plan_path),
    )


def _validate_current_pending_authority(
    request: BoundRequest,
    state: Mapping[str, object],
    state_file: installer.StableFile,
) -> None:
    try:
        installer._pending_validate_state(
            state,
            authority=request.source_authority,
            token=request.candidate_token,
            installed_app=request.installed_app,
            source_app=request.source_app,
            artifact_root=request.artifact_root,
            qualification_run=request.qualification_run,
            predecessor_observations_sha256=request.predecessor_observations_sha256,
        )
        installer._require_source_unchanged(
            request.source_authority, phase="installed acceptance orchestration"
        )
        installed = installer._capture_exact_bundle(request.installed_app)
        if not installer._snapshot_matches_record(
            installed, state["candidate_identity"]
        ):
            _fail("installed candidate differs from the pending transaction")
        installer._validate_destination_identity(
            state["destination_identity"], request.installed_app, snapshot=installed
        )
        predecessor_path = Path(str(state["predecessor_path"]))
        if state["predecessor_present"]:
            predecessor = installer._capture_exact_bundle(predecessor_path)
            if not installer._snapshot_matches_record(
                predecessor, state["predecessor_identity"]
            ):
                _fail("pending predecessor differs from its authority")
        elif installer._path_exists(predecessor_path):
            _fail("absent pending predecessor path became occupied")
        installer._require_same_file(
            state_file,
            phase="installed acceptance orchestration",
            maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
        )
    except (installer.InstallationError, OSError, KeyError) as error:
        _fail(f"pending transaction authority is invalid: {error}")


def _load_pending_binding(
    request: BoundRequest, begin_fields: Mapping[str, str]
) -> PendingBinding:
    expected_path = (
        request.installed_app.parent
        / f".MacScope.pending-{request.candidate_token}"
        / "transaction.json"
    )
    if begin_fields.get("MACSCOPE_INSTALL_RELEASE_PENDING_STATE") != str(
        expected_path
    ):
        _fail("installer begin substituted the canonical pending state path")
    if (
        begin_fields.get("MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN")
        != request.candidate_token
    ):
        _fail("installer begin candidate token differs")
    if begin_fields.get("MACSCOPE_INSTALL_RELEASE_PHASE") != "pending":
        _fail("installer begin did not expose pending phase")
    try:
        state, state_file = installer._pending_read_stable(expected_path.parent)
    except (installer.InstallationError, OSError) as error:
        _fail(f"installer pending state cannot be retained: {error}")
    if state_file.path != expected_path:
        _fail("installer pending state path is not canonical")
    _validate_current_pending_authority(request, state, state_file)
    digest = hashlib.sha256(state_file.payload).hexdigest()
    transaction_id = state.get("transaction_id")
    transaction_nonce = state.get("transaction_nonce")
    acceptance_receipt = Path(str(state.get("acceptance_receipt_path", "")))
    if (
        set(state) != installer.PENDING_TRANSACTION_FIELDS
        or state.get("schema_version") != installer.PENDING_TRANSACTION_SCHEMA_VERSION
        or state.get("phase") != "pending"
        or state.get("qualification_run_id") != request.qualification_run.run_id
        or state.get("qualification_run_nonce") != request.qualification_run.nonce
        or state.get("predecessor_observations_sha256")
        != request.predecessor_observations_sha256
        or not _is_sha256(transaction_id)
        or not _is_sha256(transaction_nonce)
        or acceptance_receipt
        != request.artifact_root / installer.ACCEPTANCE_RECEIPT_NAME
    ):
        _fail("installer pending state identity differs from this transaction")
    expected = {
        "MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID": transaction_id,
        "MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE": transaction_nonce,
        "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256": digest,
        "MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT": str(acceptance_receipt),
    }
    if any(begin_fields.get(key) != value for key, value in expected.items()):
        _fail("installer begin stdout does not bind the retained pending state")
    return PendingBinding(
        state=state,
        state_file=state_file,
        state_sha256=digest,
        transaction_id=str(transaction_id),
        transaction_nonce=str(transaction_nonce),
        acceptance_receipt=acceptance_receipt,
    )


def _assert_pending_unchanged(
    request: BoundRequest, expected: PendingBinding
) -> None:
    fields = {
        "MACSCOPE_INSTALL_RELEASE_PHASE": "pending",
        "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN": request.candidate_token,
        "MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID": expected.transaction_id,
        "MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE": expected.transaction_nonce,
        "MACSCOPE_INSTALL_RELEASE_PENDING_STATE": str(expected.state_file.path),
        "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256": expected.state_sha256,
        "MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT": str(
            expected.acceptance_receipt
        ),
    }
    observed = _load_pending_binding(request, fields)
    if (
        observed.state_file.metadata != expected.state_file.metadata
        or observed.state_file.payload != expected.state_file.payload
        or observed.state != expected.state
        or observed.state_sha256 != expected.state_sha256
    ):
        _fail("pending transaction state changed after begin")


def _destination_identity_sha256(state: Mapping[str, object]) -> str:
    return hashlib.sha256(canonical_bytes(state["destination_identity"])).hexdigest()


def _artifact_root_identity_sha256(state: Mapping[str, object]) -> str:
    return hashlib.sha256(canonical_bytes(state["artifact_root_identity"])).hexdigest()


def _task10_authority_paths(request: BoundRequest) -> dict[str, str]:
    network_root = request.evidence_root / TASK10_NETWORK_ROOT_NAME
    return {
        "installed_task10_matrix_receipt_path": str(
            request.evidence_root / TASK10_MATRIX_RECEIPT_NAME
        ),
        "installed_task10_xcresult_path": str(
            request.evidence_root / TASK10_XCRESULT_NAME
        ),
        "installed_task10_xcresult_semantic_manifest_path": str(
            request.evidence_root / TASK10_SEMANTIC_MANIFEST_NAME
        ),
        "installed_task10_network_artifact_root": str(network_root),
        "installed_task10_incremental_evidence_path": str(
            network_root / TASK10_INCREMENTAL_EVIDENCE_NAME
        ),
    }


def _load_compiler_validated_plan(path: Path) -> tuple[Mapping[str, object], str]:
    """Delegate literal argv reconstruction to the canonical compiler module."""
    from Scripts.reconstruction import (  # type: ignore[attr-defined]
        compile_installed_acceptance_gate_plan as compiler,
    )

    try:
        document, digest = compiler.load_plan(path)
    except Exception as error:
        _fail(f"canonical compiler rejected its gate plan: {error}")
    if not isinstance(document, dict) or not _is_sha256(digest):
        _fail("canonical compiler returned an invalid plan authority")
    return document, digest


def _validate_plan_path(path: Path, *, governed_root: Path, label: str) -> Path:
    if not path.is_absolute():
        _fail(f"{label} must be absolute")
    try:
        relative = path.relative_to(governed_root)
    except ValueError:
        _fail(f"{label} must be beneath the exact evidence root")
    if not relative.parts or any(
        part in {"", ".", ".."} for part in relative.parts
    ):
        _fail(f"{label} has an unsafe relative path")
    current = governed_root
    for part in relative.parts[:-1]:
        current = current / part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            break
        except OSError as error:
            _fail(f"{label} parent cannot be inspected: {error}")
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            _fail(f"{label} traverses a non-directory or symbolic link")
    try:
        path.lstat()
    except FileNotFoundError:
        return path
    except OSError as error:
        _fail(f"{label} cannot be inspected: {error}")
    _fail(f"{label} must be absent when the plan is admitted")


def _load_gate_plan(request: BoundRequest, pending: PendingBinding) -> GatePlan:
    snapshot = _read_stable_file(
        request.gate_plan_path,
        label="installed acceptance gate plan",
        maximum_bytes=MAX_GATE_PLAN_BYTES,
    )
    if (
        snapshot.metadata[2] != 0o600
        or snapshot.metadata[5] < int(pending.state["exposed_at_unix_ns"])
    ):
        _fail("installed acceptance gate plan is not private fresh evidence")
    compiler_document, compiler_digest = _load_compiler_validated_plan(
        request.gate_plan_path
    )
    try:
        document = decode_canonical_bytes(snapshot.payload)
    except CanonicalJSONError as error:
        _fail(f"gate plan is not canonical JSON: {error}")
    if compiler_document != document or compiler_digest != snapshot.sha256:
        _fail("compiler plan validation did not bind the exact retained bytes")
    plan = _closed_mapping(document, PLAN_TOP_LEVEL_FIELDS, label="gate plan")
    authority = _closed_mapping(
        plan["authority"], PLAN_AUTHORITY_FIELDS, label="gate plan authority"
    )
    authority_sha256 = hashlib.sha256(canonical_bytes(authority)).hexdigest()
    expected_authority = {
        "application_executable_sha256": pending.state[
            "application_executable_sha256"
        ],
        "artifact_root_identity_sha256": _artifact_root_identity_sha256(
            pending.state
        ),
        "artifact_root_path": str(request.artifact_root),
        "began_at_unix_ns": pending.state["began_at_unix_ns"],
        "build_provenance_sha256": pending.state["build_provenance_sha256"],
        "candidate_file_sha256": pending.state["candidate_file_sha256"],
        "candidate_identity_path": str(request.candidate_identity),
        "candidate_identity_sha256": pending.state["candidate_identity_sha256"],
        "destination_identity_sha256": _destination_identity_sha256(
            pending.state
        ),
        "execution_identity_sha256": pending.state["execution_identity_sha256"],
        "exposed_at_unix_ns": pending.state["exposed_at_unix_ns"],
        "installed_app_path": str(request.installed_app),
        "installed_ui_preparation_receipt_path": str(
            request.installed_ui_preparation_receipt.path
        ),
        "installed_ui_preparation_receipt_sha256": (
            request.installed_ui_preparation_receipt.sha256
        ),
        "installed_ui_runner_closed_tree_sha256": (
            request.installed_ui_preparation_document["artifacts"]["ui_runner"][
                "closed_tree_sha256"
            ]
        ),
        "installed_ui_runner_executable_sha256": (
            request.installed_ui_preparation_document["artifacts"]["ui_runner"][
                "executable_sha256"
            ]
        ),
        "installed_ui_runner_path": str(request.installed_ui_runner),
        "installed_ui_test_bundle_closed_tree_sha256": (
            request.installed_ui_preparation_document["artifacts"][
                "ui_test_bundle"
            ]["closed_tree_sha256"]
        ),
        "installed_ui_test_bundle_executable_sha256": (
            request.installed_ui_preparation_document["artifacts"][
                "ui_test_bundle"
            ]["executable_sha256"]
        ),
        "installed_ui_test_bundle_path": str(request.installed_ui_test_bundle),
        "installed_ui_xctestrun_path": str(request.installed_ui_xctestrun.path),
        "installed_ui_xctestrun_sha256": request.installed_ui_xctestrun.sha256,
        "native_preparation_receipt_path": str(request.preparation_receipt.path),
        "native_preparation_receipt_sha256": request.preparation_receipt.sha256,
        "native_xctestrun_path": str(request.native_xctestrun.path),
        "native_xctestrun_sha256": request.native_xctestrun.sha256,
        "pending_state_path": str(pending.state_file.path),
        "pending_state_sha256": pending.state_sha256,
        "predecessor_observations_sha256": (
            request.predecessor_observations_sha256
        ),
        "predecessor_digest": pending.state["predecessor_digest"],
        "qualification_receipt_path": str(request.qualification_receipt.path),
        "qualification_receipt_sha256": request.qualification_receipt.sha256,
        "qualification_run_id": request.qualification_run.run_id,
        "qualification_run_nonce": request.qualification_run.nonce,
        "source_app_path": str(request.source_app),
        "source_commit": pending.state["source_commit"],
        "source_equality_sha256": pending.state["source_equality_sha256"],
        "source_tree": pending.state["source_tree"],
        "transaction_id": pending.transaction_id,
        "transaction_nonce": pending.transaction_nonce,
        **_task10_authority_paths(request),
    }
    if (
        plan["schema_version"] != 1
        or plan["plan_kind"] != "macscope-installed-acceptance-gate-plan"
        or plan["candidate_artifact_root"] != str(request.candidate_artifact_root)
        or plan["evidence_root"] != str(request.evidence_root)
        or plan["output_path"] != str(request.gate_plan_path)
        or authority != expected_authority
        or plan["authority_sha256"] != authority_sha256
    ):
        _fail("gate plan authority differs from this pending transaction")
    raw_gates = plan["gates"]
    if not isinstance(raw_gates, list) or len(raw_gates) != len(
        REQUIRED_ACCEPTANCE_GATES
    ):
        _fail("gate plan must contain exactly eight gates")
    gates: list[GateSpec] = []
    seen_paths: set[Path] = {request.gate_plan_path}
    for index, raw in enumerate(raw_gates):
        gate = _closed_mapping(
            raw, PLAN_GATE_FIELDS, label=f"gate plan gate {index}"
        )
        gate_id = gate["gate_id"]
        operation_id = gate["operation_id"]
        argv = gate["argv"]
        depends_on = gate["depends_on"]
        environment = gate["environment"]
        timeout_seconds = gate["timeout_seconds"]
        output = _closed_mapping(
            gate["output"], PLAN_OUTPUT_FIELDS, label=f"gate {gate_id} output"
        )
        maximum_bytes = output["maximum_bytes"]
        if (
            not isinstance(gate_id, str)
            or not isinstance(operation_id, str)
            or installer.STABLE_ID_RE.fullmatch(operation_id) is None
            or gate["authority_sha256"] != authority_sha256
            or not isinstance(argv, list)
            or not argv
            or any(
                not isinstance(item, str) or not item or "\x00" in item
                for item in argv
            )
            or not isinstance(depends_on, list)
            or any(not isinstance(item, str) for item in depends_on)
            or depends_on != sorted(set(depends_on))
            or not isinstance(environment, dict)
            or set(environment) != PLAN_ENVIRONMENT_FIELDS
            or environment
            != {
                **BASE_ENVIRONMENT,
                "MACSCOPE_ACCEPTANCE_AUTHORITY_SHA256": authority_sha256,
            }
            or type(timeout_seconds) is not int
            or not (1 <= timeout_seconds <= MAX_PLAN_OPERATION_TIMEOUT_SECONDS)
            or output["kind"] not in {"command-file", "captured-stdout"}
            or output["publication"] != "create-only"
            or maximum_bytes != GATE_OUTPUT_MAXIMUM_BYTES.get(str(gate_id))
        ):
            _fail(f"gate {gate_id!r} violates the closed execution contract")
        planned_executable = Path(argv[0])
        executable = (
            _trusted_system_python(planned_executable)
            if planned_executable == SYSTEM_PYTHON
            else _canonical_existing(
                planned_executable,
                directory=False,
                label=f"gate {gate_id} executable",
            )
        )
        if executable != planned_executable or not os.access(executable, os.X_OK):
            _fail(f"gate {gate_id} executable is not canonical and executable")
        governed_root = (
            request.qualification_root
            if gate_id == "signing"
            else request.evidence_root
        )
        output_path = _validate_plan_path(
            Path(str(output["path"])),
            governed_root=governed_root,
            label=f"gate {gate_id} output",
        )
        if output_path in seen_paths:
            _fail("gate plan output paths must be distinct")
        seen_paths.add(output_path)
        gates.append(
            GateSpec(
                gate_id=str(gate_id),
                operation_id=operation_id,
                argv=tuple(argv),
                depends_on=tuple(depends_on),
                environment=dict(environment),
                timeout_seconds=timeout_seconds,
                output=GateOutput(
                    kind=str(output["kind"]),
                    maximum_bytes=maximum_bytes,
                    path=output_path,
                ),
            )
        )
    if tuple(gate.gate_id for gate in gates) != REQUIRED_ACCEPTANCE_GATES:
        _fail("gate plan IDs are missing, duplicated, extra, or reordered")
    gate_ids = set(REQUIRED_ACCEPTANCE_GATES)
    if any(
        set(gate.depends_on) - gate_ids or gate.gate_id in gate.depends_on
        for gate in gates
    ):
        _fail("gate plan dependency graph references an invalid gate")
    signing = next(gate for gate in gates if gate.gate_id == "signing")
    if (
        signing.operation_id == ""
        or signing.output.kind != "command-file"
        or signing.output.path
        != request.qualification_root / WS24_REPORT_NAME
        or signing.timeout_seconds != 120
        or signing.depends_on
        != tuple(
            gate_id
            for gate_id in REQUIRED_ACCEPTANCE_GATES
            if gate_id != "signing"
        )
    ):
        _fail("signing gate is not the exact final WS24 aggregate operation")
    grouped: dict[str, list[GateSpec]] = {}
    for gate in gates:
        grouped.setdefault(gate.operation_id, []).append(gate)
    for operation_id, members in grouped.items():
        first = members[0]
        if any(
            item.argv != first.argv
            or item.environment != first.environment
            or item.timeout_seconds != first.timeout_seconds
            or item.depends_on != first.depends_on
            for item in members[1:]
        ):
            _fail(f"shared operation {operation_id} is not execution-identical")
    _operation_order(tuple(gates))
    return GatePlan(snapshot, authority, authority_sha256, tuple(gates))


def _operation_order(
    gates: tuple[GateSpec, ...]
) -> tuple[tuple[GateSpec, ...], ...]:
    by_id = {gate.gate_id: gate for gate in gates}
    grouped: dict[str, list[GateSpec]] = {}
    for gate in gates:
        grouped.setdefault(gate.operation_id, []).append(gate)
    dependencies: dict[str, set[str]] = {}
    for operation_id, members in grouped.items():
        dependencies[operation_id] = {
            by_id[dependency].operation_id
            for member in members
            for dependency in member.depends_on
            if by_id[dependency].operation_id != operation_id
        }
    remaining = set(grouped)
    completed: set[str] = set()
    result: list[tuple[GateSpec, ...]] = []
    while remaining:
        ready = sorted(
            (
                operation_id
                for operation_id in remaining
                if dependencies[operation_id] <= completed
            ),
            key=lambda operation_id: min(
                item.gate_id for item in grouped[operation_id]
            ),
        )
        if not ready:
            _fail("gate plan dependency graph contains a cycle")
        operation_id = ready[0]
        result.append(
            tuple(sorted(grouped[operation_id], key=lambda item: item.gate_id))
        )
        remaining.remove(operation_id)
        completed.add(operation_id)
    return tuple(result)


def _directory_identity(path: Path, *, label: str) -> DirectoryIdentity:
    canonical = _canonical_existing(path, directory=True, label=label)
    metadata = canonical.lstat()
    return DirectoryIdentity(
        path=canonical,
        device=metadata.st_dev,
        inode=metadata.st_ino,
        mode=stat.S_IMODE(metadata.st_mode),
    )


def _assert_directory_identity(
    expected: DirectoryIdentity, *, label: str
) -> None:
    observed = _directory_identity(expected.path, label=label)
    if observed != expected:
        _fail(f"{label} physical identity changed")


def _task10_paths(request: BoundRequest) -> Task10Paths:
    xcresult = _require_absent_path(
        request.evidence_root / TASK10_XCRESULT_NAME,
        parent=request.evidence_root,
        label="installed Task10 xcresult",
    )
    semantic_manifest = _plan_absent_file(
        request.evidence_root / TASK10_SEMANTIC_MANIFEST_NAME,
        label="installed Task10 semantic manifest",
        maximum_bytes=MAX_TASK10_SEMANTIC_MANIFEST_BYTES,
    )
    matrix_receipt = _plan_absent_file(
        request.evidence_root / TASK10_MATRIX_RECEIPT_NAME,
        label="installed Task10 matrix receipt",
        maximum_bytes=MAX_TASK10_RECEIPT_BYTES,
    )
    network_root = _require_absent_path(
        request.evidence_root / TASK10_NETWORK_ROOT_NAME,
        parent=request.evidence_root,
        label="installed Task10 network artifact root",
    )
    return Task10Paths(
        xcresult=xcresult,
        semantic_manifest=semantic_manifest,
        matrix_receipt=matrix_receipt,
        network_root=network_root,
        incremental_evidence=(
            network_root / TASK10_INCREMENTAL_EVIDENCE_NAME
        ),
    )


def _task10_argv(
    request: BoundRequest, paths: Task10Paths
) -> tuple[str, ...]:
    return (
        str(request.python_executable),
        "-B",
        str(request.task10_matrix_script),
        "--candidate-identity",
        str(request.candidate_identity),
        "--preparation-receipt",
        str(request.installed_ui_preparation_receipt.path),
        "--installed-app",
        str(request.installed_app),
        "--xctestrun",
        str(request.installed_ui_xctestrun.path),
        "--test-bundle",
        str(request.installed_ui_test_bundle),
        "--ui-runner",
        str(request.installed_ui_runner),
        "--xcresult",
        str(paths.xcresult),
        "--xcresult-semantic-manifest",
        str(paths.semantic_manifest.path),
        "--receipt-output",
        str(paths.matrix_receipt.path),
        "--network-artifact-root",
        str(paths.network_root),
        "--qualification-run-id",
        request.qualification_run.run_id,
        "--qualification-run-nonce",
        request.qualification_run.nonce,
        "--predecessor-observations-sha256",
        request.predecessor_observations_sha256,
        "--developer-dir",
        str(request.xcode_developer_dir),
        "--timeout-seconds",
        str(TASK10_INTERNAL_TIMEOUT_SECONDS),
    )


def _incremental_xcuitest_argv(
    request: BoundRequest, paths: Task10Paths
) -> tuple[str, ...]:
    return (
        str(request.python_executable),
        "-B",
        str(request.incremental_xcuitest_script),
        "--matrix-receipt",
        str(paths.matrix_receipt.path),
        "--xcresult-semantic-manifest",
        str(paths.semantic_manifest.path),
        "--network-artifact-root",
        str(paths.network_root),
        "--qualification-run-id",
        request.qualification_run.run_id,
        "--qualification-run-nonce",
        request.qualification_run.nonce,
        "--predecessor-observations-sha256",
        request.predecessor_observations_sha256,
    )


def _assert_installed_ui_preparation_unchanged(
    request: BoundRequest,
) -> None:
    _assert_snapshot_unchanged(
        request.installed_ui_preparation_receipt,
        label="installed UI preparation receipt",
    )
    _assert_snapshot_unchanged(
        request.installed_ui_xctestrun,
        label="installed UI xctestrun",
    )
    try:
        digest = preparation.validate_prepared(
            dict(request.installed_ui_preparation_document),
            request.installed_ui_xctestrun.path,
            request.installed_ui_prepared_app,
            request.candidate_identity,
            test_bundle=request.installed_ui_test_bundle,
            ui_runner=request.installed_ui_runner,
        )
    except (preparation.PreparationReceiptError, OSError) as error:
        _fail(f"installed UI preparation authority changed: {error}")
    if digest != request.installed_ui_preparation_receipt.sha256:
        _fail("installed UI preparation digest changed")


def _task10_evidence_file(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
    exposed_at: int,
) -> FileSnapshot:
    snapshot = _read_stable_file(
        path, label=label, maximum_bytes=maximum_bytes
    )
    if snapshot.metadata[2] != 0o600 or snapshot.metadata[5] < exposed_at:
        _fail(f"{label} is not private fresh evidence")
    return snapshot


def _network_child_names(root: Path) -> set[str]:
    try:
        return {item.name for item in root.iterdir()}
    except OSError as error:
        _fail(f"installed Task10 network artifact root cannot be enumerated: {error}")


def _validate_task10_publication(
    request: BoundRequest,
    pending: PendingBinding,
    paths: Task10Paths,
    incremental: FileSnapshot,
) -> Task10Publication:
    exposed_at = int(pending.state["exposed_at_unix_ns"])
    matrix_receipt = _read_planned_file(
        paths.matrix_receipt, label="installed Task10 matrix receipt"
    )
    semantic_manifest = _read_planned_file(
        paths.semantic_manifest, label="installed Task10 semantic manifest"
    )
    for label, snapshot in (
        ("installed Task10 matrix receipt", matrix_receipt),
        ("installed Task10 semantic manifest", semantic_manifest),
    ):
        if snapshot.metadata[2] != 0o600 or snapshot.metadata[5] < exposed_at:
            _fail(f"{label} is not private fresh evidence")
    xcresult = _directory_identity(
        paths.xcresult, label="installed Task10 xcresult"
    )
    network_root = _directory_identity(
        paths.network_root, label="installed Task10 network artifact root"
    )
    if network_root.mode != 0o700:
        _fail("installed Task10 network artifact root mode is not private")
    expected_children = {
        NETWORK_AUDIT_REPORT_NAME,
        NETWORK_EXECUTION_REPORT_NAME,
        NETWORK_OBSERVATION_NAME,
        TASK10_INCREMENTAL_EVIDENCE_NAME,
    }
    if _network_child_names(paths.network_root) != expected_children:
        _fail("installed Task10 network artifact root child set is not exact")
    network_audit = _task10_evidence_file(
        paths.network_root / NETWORK_AUDIT_REPORT_NAME,
        label="installed Task10 network audit report",
        maximum_bytes=4 * 1024 * 1024,
        exposed_at=exposed_at,
    )
    network_execution = _task10_evidence_file(
        paths.network_root / NETWORK_EXECUTION_REPORT_NAME,
        label="installed Task10 network execution report",
        maximum_bytes=1024 * 1024,
        exposed_at=exposed_at,
    )
    network_observation = _task10_evidence_file(
        paths.network_root / NETWORK_OBSERVATION_NAME,
        label="installed Task10 network observation",
        maximum_bytes=1024 * 1024,
        exposed_at=exposed_at,
    )
    try:
        receipt_document, receipt_sha256 = matrix.load_receipt_with_sha256(
            paths.matrix_receipt.path
        )
        projection = ws24.installed_selector_projection(
            ws24.load_installed_selector_catalog()
        )
        validated_receipt_sha256 = matrix.validate_receipt(
            receipt_document,
            candidate_identity_path=request.candidate_identity,
            installed_app=request.installed_app,
            expected_selector_projection=projection,
        )
        semantic_document = decode_canonical_bytes(semantic_manifest.payload)
        audit_document = decode_canonical_bytes(network_audit.payload)
        execution_document = decode_canonical_bytes(network_execution.payload)
        incremental_document = decode_canonical_bytes(incremental.payload)
        bundle_sha256 = ws24.result_bundle_sha256(paths.xcresult)
        validated_incremental_document = task10_evidence._validated_descriptor(
            argparse.Namespace(
                matrix_receipt=paths.matrix_receipt.path,
                xcresult_semantic_manifest=paths.semantic_manifest.path,
            ),
            authority=request.qualification_run,
            predecessor_observations_sha256=(
                request.predecessor_observations_sha256
            ),
            network_root=paths.network_root,
        )
        expected_incremental_document = task10_evidence._descriptor(
            receipt_path=paths.matrix_receipt.path,
            receipt_sha256=matrix_receipt.sha256,
            xcresult_path=paths.xcresult,
            semantic_path=paths.semantic_manifest.path,
            semantic_sha256=semantic_manifest.sha256,
            network_report_path=network_audit.path,
            network_report_sha256=network_audit.sha256,
            execution_report_path=network_execution.path,
            execution_report_sha256=network_execution.sha256,
            observation_path=network_observation.path,
            observation_sha256=network_observation.sha256,
        )
    except (
        task10_evidence.InstalledIncrementalEvidenceError,
        matrix.InstalledMatrixReceiptError,
        ws24.ReportError,
        CanonicalJSONError,
        OSError,
        KeyError,
        TypeError,
    ) as error:
        _fail(f"installed Task10 publication is invalid: {error}")
    products = receipt_document["products"]
    sealed_xcresult = products["xcresult"]
    semantic_fields = {
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
    source_xcresult = (
        semantic_document.get("source_xcresult")
        if isinstance(semantic_document, dict)
        else None
    )
    if (
        receipt_sha256 != matrix_receipt.sha256
        or validated_receipt_sha256 != matrix_receipt.sha256
        or receipt_document.get("schema_version") != matrix.SCHEMA_VERSION
        or receipt_document["candidate"].get("preparation_receipt_path")
        != str(request.installed_ui_preparation_receipt.path)
        or sealed_xcresult.get("path") != str(paths.xcresult)
        or not isinstance(semantic_document, dict)
        or set(semantic_document) != semantic_fields
        or semantic_document.get("schema_version") != 3
        or semantic_document.get("result") != "passed"
        or not isinstance(source_xcresult, dict)
        or set(source_xcresult) != {"bundle_sha256", "closed_tree_sha256"}
        or source_xcresult.get("bundle_sha256") != bundle_sha256
        or source_xcresult.get("closed_tree_sha256")
        != sealed_xcresult.get("closed_tree_sha256")
        or not isinstance(audit_document, dict)
        or audit_document.get("schema_version") != task10_evidence.network.MATRIX_REPORT_SCHEMA_VERSION
        or audit_document.get("result") != "passed"
        or audit_document.get("command_id")
        != "installed.network-acquisition-audit"
        or not isinstance(execution_document, dict)
        or execution_document.get("schema_version") != 2
        or execution_document.get("result") != "passed"
        or execution_document.get("exit_code") != 0
        or execution_document.get("qualification_run")
        != {
            "run_id": request.qualification_run.run_id,
            "nonce": request.qualification_run.nonce,
        }
        or execution_document.get("predecessor_observations_sha256")
        != request.predecessor_observations_sha256
        or validated_incremental_document != expected_incremental_document
        or incremental_document != expected_incremental_document
    ):
        _fail("installed Task10 outputs do not cross-bind their exact authority")
    # Independently replay retained observations before publishing the transaction.
    # The candidate path inventory is derived from the bound request, never a ledger.
    network = task10_evidence.network
    expected_paths = {"app": str(request.installed_app / "Contents/MacOS/MacScope")}
    expected_paths.update({role: str(request.installed_app / "Contents/XPCServices" / f"{name}.xpc"
                                    / "Contents/MacOS" / name)
                           for role, name in network.MANDATORY_EXECUTABLE_NAMES.items()})
    try:
        attribution = audit_document["attribution"]
        if type(attribution) is not dict or set(attribution) != {
            "policy_id", "observer_spawn_ns", "observer_eof_ns", "queue_closed_ns", "proofs", "drains"
        } or attribution["policy_id"] != network_attribution.PROOF_KIND:
            _fail("installed Task10 attribution schema differs")
        foreign = network_attribution.validate_foreign_proofs(
            attribution["proofs"], attribution["drains"],
            observer_spawn_ns=attribution["observer_spawn_ns"], observer_eof_ns=attribution["observer_eof_ns"],
            queue_closed_ns=attribution["queue_closed_ns"], candidate_paths=tuple(expected_paths.values()))
        executables = audit_document["executables"]
        if type(executables) is not list or len(executables) != len(expected_paths):
            _fail("installed Task10 executable inventory differs")
        roles, pids = set(), set()
        for executable in executables:
            if type(executable) is not dict or set(executable) != {
                "identity_id", "executable_path", "executable_sha256", "processes"
            }:
                _fail("installed Task10 executable schema differs")
            role = executable["identity_id"]
            if role not in expected_paths or role in roles or executable["executable_path"] != expected_paths[role]:
                _fail("installed Task10 executable path/role differs")
            roles.add(role)
            if not _is_sha256(executable["executable_sha256"]) or type(executable["processes"]) is not list:
                _fail("installed Task10 executable identity differs")
            if role == "app" and executable["executable_sha256"] != pending.state["application_executable_sha256"]:
                _fail("installed Task10 application digest differs from transaction")
            for process in executable["processes"]:
                if (type(process) is not dict or set(process) != {"pid", "start_time_unix_us"}
                    or type(process["pid"]) is not int or process["pid"] <= 0 or process["pid"] in pids
                    or type(process["start_time_unix_us"]) is not int or process["start_time_unix_us"] < 0):
                    _fail("installed Task10 candidate process identity differs")
                pids.add(process["pid"])
        summary = network.classify_matrix_observation(network_observation.payload,
            candidate_pids=frozenset(pids), foreign_pids=foreign)
        observer = audit_document["observer"]
        if (observer["observer_id"] != network.MATRIX_OBSERVER_ID
            or type(observer["observation_byte_count"]) is not int
            or observer["observation_byte_count"] != len(network_observation.payload)
            or observer["observation_sha256"] != network_observation.sha256
            or observer["evidence_scope"] != network.MATRIX_EVIDENCE_SCOPE
            or observer["limitations"] != list(network.MATRIX_LIMITATIONS)
            or any(type(observer[field]) is not int or observer[field] != expected for field, expected in (
                ("observed_sample_count", summary.sample_count), ("observed_process_row_count", summary.process_row_count),
                ("observed_candidate_row_count", summary.candidate_row_count), ("observed_foreign_row_count", summary.foreign_row_count),
                ("observed_unresolved_row_count", summary.unresolved_row_count)))
            or summary.candidate_row_count or summary.unresolved_row_count):
            _fail("installed Task10 network sampled-state evidence differs")
    except (KeyError, TypeError, network.AuditInputError, network_attribution.NetworkAttributionError) as error:
        _fail(f"installed Task10 network attribution unavailable: {error}")
    closed_tree_sha256 = sealed_xcresult.get("closed_tree_sha256")
    if not _is_sha256(bundle_sha256) or not _is_sha256(closed_tree_sha256):
        _fail("installed Task10 xcresult digests are invalid")
    return Task10Publication(
        paths=paths,
        matrix_receipt=matrix_receipt,
        semantic_manifest=semantic_manifest,
        incremental_evidence=incremental,
        xcresult=xcresult,
        network_root=network_root,
        xcresult_bundle_sha256=bundle_sha256,
        xcresult_closed_tree_sha256=str(closed_tree_sha256),
        network_audit_report=network_audit,
        network_execution_report=network_execution,
        network_observation=network_observation,
    )


def _run_task10_prerequisite(
    request: BoundRequest,
    pending: PendingBinding,
    plan: GatePlan,
    runner: CommandRunner,
) -> Task10Publication:
    paths = _task10_paths(request)
    _assert_pending_unchanged(request, pending)
    _assert_snapshot_unchanged(
        plan.snapshot, label="installed acceptance gate plan"
    )
    _assert_installed_ui_preparation_unchanged(request)
    task10_result = runner(
        _task10_argv(request, paths),
        float(TASK10_OUTER_TIMEOUT_SECONDS),
        TASK10_ENVIRONMENT,
    )
    _require_successful_command(
        task10_result,
        label="installed Task10 prerequisite",
        require_empty_stderr=True,
    )
    _assert_pending_unchanged(request, pending)
    _assert_snapshot_unchanged(
        plan.snapshot, label="installed acceptance gate plan"
    )
    _assert_installed_ui_preparation_unchanged(request)
    incremental_plan = _plan_absent_file(
        paths.incremental_evidence,
        label="installed Task10 incremental XCUITest evidence",
        maximum_bytes=MAX_INCREMENTAL_XCUITEST_EVIDENCE_BYTES,
    )
    incremental_result = runner(
        _incremental_xcuitest_argv(request, paths),
        float(INCREMENTAL_XCUITEST_TIMEOUT_SECONDS),
        BASE_ENVIRONMENT,
    )
    _require_successful_command(
        incremental_result,
        label="installed Task10 incremental XCUITest projector",
        require_empty_stderr=True,
    )
    incremental = _read_planned_file(
        incremental_plan,
        label="installed Task10 incremental XCUITest evidence",
    )
    if (
        incremental.metadata[2] != 0o600
        or incremental.metadata[5] < int(pending.state["exposed_at_unix_ns"])
    ):
        _fail("installed Task10 incremental evidence is not private and fresh")
    publication = _validate_task10_publication(
        request, pending, paths, incremental
    )
    _assert_pending_unchanged(request, pending)
    _assert_snapshot_unchanged(
        plan.snapshot, label="installed acceptance gate plan"
    )
    _assert_installed_ui_preparation_unchanged(request)
    return publication


def _read_gate_output(gate: GateSpec, *, exposed_at: int) -> FileSnapshot:
    snapshot = _read_stable_file(
        gate.output.path,
        label=f"gate output {gate.gate_id}",
        maximum_bytes=gate.output.maximum_bytes,
    )
    if snapshot.metadata[2] != 0o600 or snapshot.metadata[5] < exposed_at:
        _fail(f"gate output {gate.gate_id} is not private fresh evidence")
    return snapshot


def _prepare_operation_output_parents(
    request: BoundRequest, members: tuple[GateSpec, ...]
) -> None:
    native_members = [member for member in members if member.gate_id == "native-xpc"]
    if not native_members:
        return
    if len(native_members) != 1:
        _fail("native-XPC operation must have one exact primary output")
    native = native_members[0]
    expected_parent = request.evidence_root / "native-xpc-artifacts"
    expected_output = expected_parent / ws24.NATIVE_XPC_EXECUTION_REPORT_NAME
    if native.output.kind != "command-file" or native.output.path != expected_output:
        _fail("native-XPC output path differs from its governed artifact root")
    _create_private_directory(
        expected_parent,
        parent=request.evidence_root,
        label="native-XPC artifact root",
    )
    try:
        if any(expected_parent.iterdir()):
            _fail("native-XPC artifact root must be empty before execution")
    except OSError as error:
        _fail(f"native-XPC artifact root cannot be enumerated: {error}")


def _execute_gate_plan(
    request: BoundRequest,
    pending: PendingBinding,
    plan: GatePlan,
    report_plan: PlannedFile,
    gate_plans: Sequence[tuple[str, PlannedFile]],
    runner: CommandRunner,
) -> GateExecution:
    snapshots: dict[str, FileSnapshot] = {}
    publication: WS24Publication | None = None
    for members in _operation_order(plan.gates):
        _assert_pending_unchanged(request, pending)
        _assert_snapshot_unchanged(
            plan.snapshot, label="installed acceptance gate plan"
        )
        for member in members:
            _validate_plan_path(
                member.output.path,
                governed_root=(
                    request.qualification_root
                    if member.gate_id == "signing"
                    else request.evidence_root
                ),
                label=f"gate output {member.gate_id}",
            )
        _prepare_operation_output_parents(request, members)
        first = members[0]
        signing_operation = any(member.gate_id == "signing" for member in members)
        if signing_operation:
            if len(members) != 1 or first.output.path != report_plan.path:
                _fail("final WS24 operation is not one exact signing gate")
            inputs = _ws24_inputs(
                tuple(
                    (gate_id, snapshots[gate_id])
                    for gate_id in REQUIRED_ACCEPTANCE_GATES
                    if gate_id in snapshots
                )
            )
            expected_argv = _report_argv(
                request, pending, inputs, report_plan, gate_plans
            )
            if first.argv != expected_argv:
                _fail("signing gate argv differs from the exact WS24 invocation")
            timeout_seconds = min(
                float(first.timeout_seconds), request.timeouts.report
            )
        else:
            timeout_seconds = float(first.timeout_seconds)
        result = runner(
            first.argv, timeout_seconds, first.environment
        )
        _require_successful_command(
            result,
            label=f"gate operation {first.operation_id}",
            require_empty_stderr=signing_operation,
        )
        if signing_operation:
            _parse_report_stdout(result.stdout, gate_plans)
            publication = _validate_ws24_publication(
                request, pending, report_plan, gate_plans
            )
        captured = [
            member for member in members if member.output.kind == "captured-stdout"
        ]
        if captured:
            if len(captured) != 1:
                _fail(
                    "one operation cannot publish stdout into multiple evidence files"
                )
            member = captured[0]
            output_plan = _plan_absent_file(
                member.output.path,
                label=f"captured stdout {member.gate_id}",
                maximum_bytes=member.output.maximum_bytes,
            )
            _write_create_only_bytes(
                output_plan,
                result.stdout,
                label=f"captured stdout {member.gate_id}",
            )
        for member in members:
            snapshots[member.gate_id] = _read_gate_output(
                member, exposed_at=int(pending.state["exposed_at_unix_ns"])
            )
        if (
            signing_operation
            and publication is not None
            and snapshots["signing"] != publication.report
        ):
            _fail("signing gate primary output differs from the WS24 aggregate")
        _assert_pending_unchanged(request, pending)
        _assert_snapshot_unchanged(
            plan.snapshot, label="installed acceptance gate plan"
        )
    if (
        tuple(sorted(snapshots)) != REQUIRED_ACCEPTANCE_GATES
        or publication is None
    ):
        _fail("executed gate evidence set is not the exact canonical eight")
    return GateExecution(
        outputs=tuple(
            (gate_id, snapshots[gate_id])
            for gate_id in REQUIRED_ACCEPTANCE_GATES
        ),
        publication=publication,
    )


def _ws24_inputs(
    gate_snapshots: Sequence[tuple[str, FileSnapshot]],
) -> WS24Inputs:
    by_name: dict[str, FileSnapshot] = {}
    for _gate_id, snapshot in gate_snapshots:
        if snapshot.path.name in by_name:
            _fail("gate outputs duplicate one governed WS24 input filename")
        by_name[snapshot.path.name] = snapshot
    required = (
        LIVE_EVIDENCE_NAME,
        "full-surface.json",
        "full-surface.legacy-grid.json",
        CLI_GUI_REPORT_NAME,
        MCP_REPORT_NAME,
        ws24.NATIVE_XPC_EXECUTION_REPORT_NAME,
    )
    if any(name not in by_name for name in required):
        _fail("gate plan did not publish every exact WS24 input artifact")
    return WS24Inputs(
        live_evidence=by_name[LIVE_EVIDENCE_NAME],
        full_surface=by_name["full-surface.json"],
        legacy_grid=by_name["full-surface.legacy-grid.json"],
        cli_gui=by_name[CLI_GUI_REPORT_NAME],
        mcp=by_name[MCP_REPORT_NAME],
        native_xpc=by_name[ws24.NATIVE_XPC_EXECUTION_REPORT_NAME],
    )


def _qualification_plans(
    request: BoundRequest,
) -> tuple[PlannedFile, tuple[tuple[str, PlannedFile], ...]]:
    report = _plan_absent_file(
        request.qualification_root / WS24_REPORT_NAME,
        label="WS24 aggregate report",
        maximum_bytes=ws24.MAXIMUM_INSTALLED_QUALIFICATION_OUTPUT_BYTES,
    )
    gates = tuple(
        (
            gate_id,
            _plan_absent_file(
                request.qualification_root / f"{gate_id}.acceptance-gate.json",
                label=f"acceptance gate envelope {gate_id}",
                maximum_bytes=ws24.MAXIMUM_ACCEPTANCE_GATE_OUTPUT_BYTES,
            ),
        )
        for gate_id in REQUIRED_ACCEPTANCE_GATES
    )
    return report, gates


def _report_argv(
    request: BoundRequest,
    pending: PendingBinding,
    inputs: WS24Inputs,
    report: PlannedFile,
    gates: Sequence[tuple[str, PlannedFile]],
) -> tuple[str, ...]:
    argv = [
        str(request.python_executable),
        "-B",
        str(request.report_script),
        "--source-app",
        str(request.source_app),
        "--installed-app",
        str(request.installed_app),
        "--evidence-json",
        str(inputs.live_evidence.path),
        "--candidate-identity",
        str(request.candidate_identity),
        "--expected-source-commit",
        str(pending.state["source_commit"]),
        "--qualification-run-id",
        request.qualification_run.run_id,
        "--qualification-run-nonce",
        request.qualification_run.nonce,
        "--installation-pending-state",
        str(pending.state_file.path),
        "--full-surface-report",
        str(inputs.full_surface.path),
        "--legacy-grid-report",
        str(inputs.legacy_grid.path),
        "--cli-gui-operability-report",
        str(inputs.cli_gui.path),
        "--mcp-operability-report",
        str(inputs.mcp.path),
        "--native-xpc-execution-report",
        str(inputs.native_xpc.path),
        "--output",
        str(report.path),
    ]
    for gate_id, output in gates:
        argv.extend(("--acceptance-gate-output", f"{gate_id}={output.path}"))
    argv.extend(("--xcode-developer-dir", str(request.xcode_developer_dir)))
    return tuple(argv)


def _parse_report_stdout(
    payload: bytes,
    gates: Sequence[tuple[str, PlannedFile]],
) -> None:
    lines = _strict_stdout_lines(payload, label="WS24 report producer")
    if len(lines) != len(REQUIRED_ACCEPTANCE_GATES):
        _fail("WS24 stdout must contain exactly eight envelope paths")
    expected_paths = {gate_id: plan.path for gate_id, plan in gates}
    observed: dict[str, Path] = {}
    order: list[str] = []
    for line in lines:
        gate_id, separator, raw_path = line.partition("=")
        if not separator or not gate_id or not raw_path or gate_id in observed:
            _fail("WS24 envelope stdout is missing, duplicate, or malformed")
        order.append(gate_id)
        observed[gate_id] = Path(raw_path)
    if tuple(order) != REQUIRED_ACCEPTANCE_GATES or observed != expected_paths:
        _fail(
            "WS24 stdout substituted, omitted, duplicated, or reordered an envelope"
        )


def _validate_ws24_publication(
    request: BoundRequest,
    pending: PendingBinding,
    report_plan: PlannedFile,
    gate_plans: Sequence[tuple[str, PlannedFile]],
) -> WS24Publication:
    report = _read_planned_file(report_plan, label="WS24 aggregate report")
    if report.metadata[2] != 0o600:
        _fail("WS24 aggregate report mode is not private")
    try:
        document = decode_canonical_bytes(report.payload)
    except CanonicalJSONError as error:
        _fail(f"WS24 aggregate is not canonical JSON: {error}")
    if (
        not isinstance(document, dict)
        or document.get("schemaVersion")
        != ws24.INSTALLED_QUALIFICATION_REPORT_SCHEMA_VERSION
        or document.get("accepted") is not True
        or document.get("sourceCommit") != pending.state["source_commit"]
        or document.get("sourceTree") != pending.state["source_tree"]
        or document.get("installedExecutableSHA256")
        != pending.state["application_executable_sha256"]
        or report.metadata[5] < int(pending.state["exposed_at_unix_ns"])
    ):
        _fail("WS24 aggregate is not accepted transaction-bound schema 5")
    gate_arguments = tuple(
        f"{gate_id}={plan.path}" for gate_id, plan in gate_plans
    )
    try:
        records, _ = installer._acceptance_gate_records(
            state=pending.state, gate_arguments=gate_arguments
        )
    except (installer.InstallationError, OSError, CanonicalJSONError) as error:
        _fail(f"WS24 acceptance envelopes are invalid: {error}")
    if tuple(records) != REQUIRED_ACCEPTANCE_GATES:
        _fail("WS24 envelope record set is not exact")
    snapshots_list: list[tuple[str, FileSnapshot]] = []
    for gate_id, plan in gate_plans:
        snapshot = _read_planned_file(
            plan, label=f"acceptance envelope {gate_id}"
        )
        if (
            snapshot.metadata[2] != 0o600
            or snapshot.metadata[5]
            < int(pending.state["exposed_at_unix_ns"])
        ):
            _fail(f"acceptance envelope {gate_id} is not private fresh evidence")
        snapshots_list.append((gate_id, snapshot))
    snapshots = tuple(snapshots_list)
    return WS24Publication(report=report, gate_envelopes=snapshots)


def _validate_terminal_commit(
    request: BoundRequest, pending: PendingBinding
) -> TerminalBinding:
    pending_root = pending.state_file.path.parent
    committing_root = (
        request.installed_app.parent
        / f".MacScope.committing-{request.candidate_token}"
    )
    committed_root = installer._committed_root(
        request.installed_app, request.candidate_token, pending.transaction_id
    )
    if (
        installer._path_exists(pending_root)
        or installer._path_exists(committing_root)
        or installer._committed_roots(
            request.installed_app, request.candidate_token
        )
        != (committed_root,)
    ):
        _fail("installer commit did not reach its one exact durable root")
    try:
        terminal_state, terminal_file = installer._pending_read_stable(
            committed_root
        )
        if (
            terminal_state != pending.state
            or terminal_file.payload != pending.state_file.payload
        ):
            _fail("terminal transaction state differs from retained pending bytes")
        _marker, marker_file = installer._read_commit_authority(
            committed_root, state=terminal_state, state_file=terminal_file
        )
        receipt_file = installer._validate_acceptance_receipt(
            state=terminal_state,
            state_file=terminal_file,
            artifact_root=request.artifact_root,
            reader=installer._read_acceptance_receipt_file,
        )
        installed = installer._capture_exact_bundle(request.installed_app)
        if not installer._snapshot_matches_record(
            installed, terminal_state["candidate_identity"]
        ):
            _fail("terminal installed candidate differs from committed authority")
        installer._validate_destination_identity(
            terminal_state["destination_identity"],
            request.installed_app,
            snapshot=installed,
        )
        installer._require_source_unchanged(
            request.source_authority,
            phase="installed acceptance terminal validation",
        )
    except (installer.InstallationError, OSError, KeyError) as error:
        _fail(f"terminal commit validation failed: {error}")
    terminal_snapshot = _read_stable_file(
        terminal_file.path,
        label="terminal committed transaction state",
        maximum_bytes=installer.MAX_PENDING_TRANSACTION_BYTES,
    )
    marker_snapshot = _read_stable_file(
        marker_file.path,
        label="commit authority",
        maximum_bytes=installer.MAX_COMMIT_AUTHORITY_BYTES,
    )
    receipt_snapshot = _read_stable_file(
        receipt_file.path,
        label="acceptance receipt",
        maximum_bytes=installer.MAX_ACCEPTANCE_RECEIPT_BYTES,
    )
    if terminal_snapshot.sha256 != pending.state_sha256:
        _fail("terminal state digest differs from the pending-state digest")
    return TerminalBinding(
        committed_root=committed_root,
        state=terminal_snapshot,
        acceptance_receipt=receipt_snapshot,
        commit_authority=marker_snapshot,
    )


def _result_document(
    request: BoundRequest,
    pending: PendingBinding,
    task10: Task10Publication,
    plan: GatePlan,
    publication: WS24Publication,
    terminal: TerminalBinding,
    *,
    produced_at_unix_ns: int,
) -> Mapping[str, object]:
    state = pending.state
    document: dict[str, object] = {
        "schema_version": 1,
        "result_kind": "macscope-installed-acceptance-transaction",
        "result": "passed",
        "rolled_back": False,
        "transaction_phase": "committed",
        "produced_at_unix_ns": produced_at_unix_ns,
        "candidate": {
            "artifact_root": str(request.candidate_artifact_root),
            "identity_path": str(request.candidate_identity),
            "identity_sha256": request.candidate_token,
            "identity_file_sha256": request.candidate_identity_snapshot.sha256,
            "provenance_path": str(request.provenance_snapshot.path),
            "provenance_sha256": request.provenance_snapshot.sha256,
            "source_app_path": str(request.source_app),
            "source_commit": state["source_commit"],
            "source_tree": state["source_tree"],
            "application_executable_sha256": state[
                "application_executable_sha256"
            ],
        },
        "qualification_run": {
            "run_id": request.qualification_run.run_id,
            "nonce": request.qualification_run.nonce,
        },
        "transaction": {
            "transaction_id": pending.transaction_id,
            "transaction_nonce": pending.transaction_nonce,
            "candidate_identity_sha256": state["candidate_identity_sha256"],
            "candidate_file_sha256": state["candidate_file_sha256"],
            "application_executable_sha256": state[
                "application_executable_sha256"
            ],
            "build_provenance_sha256": state["build_provenance_sha256"],
            "source_commit": state["source_commit"],
            "source_tree": state["source_tree"],
            "source_equality_sha256": state["source_equality_sha256"],
            "execution_identity_sha256": state["execution_identity_sha256"],
            "destination_identity_sha256": _destination_identity_sha256(state),
            "predecessor_digest": state["predecessor_digest"],
            "predecessor_observations_sha256": state[
                "predecessor_observations_sha256"
            ],
            "began_at_unix_ns": state["began_at_unix_ns"],
            "exposed_at_unix_ns": state["exposed_at_unix_ns"],
        },
        "pending_state": {
            "path_at_begin": str(pending.state_file.path),
            "terminal_path": str(terminal.state.path),
            "sha256": pending.state_sha256,
        },
        "gate_plan": {
            "path": str(plan.snapshot.path),
            "sha256": plan.snapshot.sha256,
        },
        "gate_envelopes": [
            {
                "gate_id": gate_id,
                "path": str(snapshot.path),
                "sha256": snapshot.sha256,
            }
            for gate_id, snapshot in publication.gate_envelopes
        ],
        "installed_task10": {
            "matrix_receipt": {
                "path": str(task10.matrix_receipt.path),
                "sha256": task10.matrix_receipt.sha256,
            },
            "xcresult": {
                "path": str(task10.xcresult.path),
                "bundle_sha256": task10.xcresult_bundle_sha256,
                "closed_tree_sha256": task10.xcresult_closed_tree_sha256,
            },
            "xcresult_semantic_manifest": {
                "path": str(task10.semantic_manifest.path),
                "sha256": task10.semantic_manifest.sha256,
            },
            "network_artifact_root": {
                "path": str(task10.network_root.path),
                "audit_report_path": str(task10.network_audit_report.path),
                "audit_report_sha256": task10.network_audit_report.sha256,
                "execution_report_path": str(
                    task10.network_execution_report.path
                ),
                "execution_report_sha256": (
                    task10.network_execution_report.sha256
                ),
                "observation_path": str(task10.network_observation.path),
                "observation_sha256": task10.network_observation.sha256,
            },
            "incremental_evidence": {
                "path": str(task10.incremental_evidence.path),
                "sha256": task10.incremental_evidence.sha256,
            },
        },
        "acceptance_receipt": {
            "path": str(terminal.acceptance_receipt.path),
            "sha256": terminal.acceptance_receipt.sha256,
        },
        "terminal_committed_state": {
            "path": str(terminal.state.path),
            "sha256": terminal.state.sha256,
        },
        "commit_authority": {
            "path": str(terminal.commit_authority.path),
            "sha256": terminal.commit_authority.sha256,
        },
    }
    if set(document) != RESULT_TOP_LEVEL_FIELDS:
        _fail("transaction result does not have its exact closed schema")
    return document


def _assert_all_unchanged(
    request: BoundRequest,
    pending: PendingBinding,
    task10: Task10Publication,
    plan: GatePlan,
    gate_outputs: Sequence[tuple[str, FileSnapshot]],
    publication: WS24Publication,
    terminal: TerminalBinding,
) -> None:
    for label, snapshot in (
        ("qualification receipt", request.qualification_receipt),
        ("native preparation receipt", request.preparation_receipt),
        (
            "installed UI preparation receipt",
            request.installed_ui_preparation_receipt,
        ),
        ("native xctestrun", request.native_xctestrun),
        ("candidate identity", request.candidate_identity_snapshot),
        ("source build provenance", request.provenance_snapshot),
        ("installed acceptance gate plan", plan.snapshot),
        ("WS24 aggregate report", publication.report),
        ("acceptance receipt", terminal.acceptance_receipt),
        ("terminal committed transaction state", terminal.state),
        ("commit authority", terminal.commit_authority),
    ):
        _assert_snapshot_unchanged(snapshot, label=label)
    for gate_id, snapshot in gate_outputs:
        _assert_snapshot_unchanged(snapshot, label=f"gate output {gate_id}")
    for gate_id, snapshot in publication.gate_envelopes:
        _assert_snapshot_unchanged(
            snapshot, label=f"acceptance envelope {gate_id}"
        )
    for label, snapshot in (
        ("installed Task10 matrix receipt", task10.matrix_receipt),
        ("installed Task10 semantic manifest", task10.semantic_manifest),
        ("installed Task10 incremental evidence", task10.incremental_evidence),
        ("installed Task10 network audit report", task10.network_audit_report),
        (
            "installed Task10 network execution report",
            task10.network_execution_report,
        ),
        ("installed Task10 network observation", task10.network_observation),
    ):
        _assert_snapshot_unchanged(snapshot, label=label)
    _assert_directory_identity(task10.xcresult, label="installed Task10 xcresult")
    _assert_directory_identity(
        task10.network_root, label="installed Task10 network artifact root"
    )
    if _network_child_names(task10.network_root.path) != {
        NETWORK_AUDIT_REPORT_NAME,
        NETWORK_EXECUTION_REPORT_NAME,
        NETWORK_OBSERVATION_NAME,
        TASK10_INCREMENTAL_EVIDENCE_NAME,
    }:
        _fail("installed Task10 network artifact child set changed")
    observed_task10 = _validate_task10_publication(
        request, pending, task10.paths, task10.incremental_evidence
    )
    if observed_task10 != task10:
        _fail("installed Task10 publication changed after validation")


def _publish_result(
    request: BoundRequest,
    pending: PendingBinding,
    task10: Task10Publication,
    plan: GatePlan,
    gate_outputs: Sequence[tuple[str, FileSnapshot]],
    publication: WS24Publication,
    terminal: TerminalBinding,
    *,
    clock_ns: Callable[[], int],
) -> TransactionOutcome:
    _assert_all_unchanged(
        request, pending, task10, plan, gate_outputs, publication, terminal
    )
    produced_at = clock_ns()
    if (
        type(produced_at) is not int
        or produced_at < int(pending.state["exposed_at_unix_ns"])
    ):
        _fail("transaction result clock is invalid")
    document = _result_document(
        request,
        pending,
        task10,
        plan,
        publication,
        terminal,
        produced_at_unix_ns=produced_at,
    )
    payload = canonical_bytes(document)
    if len(payload) > MAX_RESULT_BYTES:
        _fail("transaction result exceeds its bounded schema")
    snapshot = _write_create_only_bytes(
        request.result_output, payload, label="transaction result"
    )
    if snapshot.path != request.result_output.path or snapshot.payload != payload:
        _fail("transaction result publication is not exact")
    return TransactionOutcome(
        result_output=request.result_output.path, document=document
    )


def _rollback(request: BoundRequest, runner: CommandRunner) -> tuple[bool, bool | None, str]:
    try:
        require_app_quiescent(request.source_app, request.installed_app)
    except BaseException as error:
        return False, None, "rollback not attempted: " + _bounded_diagnostic(error)
    try:
        result = runner(
            _installer_argv(request, "rollback"),
            request.timeouts.rollback,
            BASE_ENVIRONMENT,
        )
        _require_successful_command(
            result, label="installer rollback", require_empty_stderr=True
        )
        fields = _parse_key_value_stdout(
            result.stdout,
            label="installer rollback",
            expected_keys=CLOSEOUT_STDOUT_KEYS,
        )
        if (
            fields["MACSCOPE_INSTALL_RELEASE_PHASE"] != "rolled-back"
            or fields["MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN"]
            != request.candidate_token
        ):
            _fail("installer rollback stdout does not bind the exact candidate")
        return True, True, "rolled-back"
    except BaseException as error:
        return True, False, _bounded_diagnostic(error)


def execute_transaction(
    request: BoundRequest,
    *,
    runner: CommandRunner = _run_command,
    clock_ns: Callable[[], int] = time.time_ns,
) -> TransactionOutcome:
    begin_invoked = False
    try:
        require_app_quiescent(request.source_app, request.installed_app)
        begin_invoked = True
        begin_result = runner(
            _installer_argv(request, "begin"),
            request.timeouts.begin,
            BASE_ENVIRONMENT,
        )
        _require_successful_command(
            begin_result, label="installer begin", require_empty_stderr=True
        )
        begin_fields = _parse_key_value_stdout(
            begin_result.stdout,
            label="installer begin",
            expected_keys=BEGIN_STDOUT_KEYS,
        )
        pending = _load_pending_binding(request, begin_fields)

        _create_private_directory(
            request.evidence_root,
            parent=request.work_root,
            label="gate evidence root",
        )
        _create_private_directory(
            request.qualification_root,
            parent=request.work_root,
            label="qualification evidence root",
        )
        _assert_pending_unchanged(request, pending)
        compiler_result = runner(
            _compiler_argv(request, pending),
            request.timeouts.compiler,
            BASE_ENVIRONMENT,
        )
        _require_successful_command(
            compiler_result,
            label="gate-plan compiler",
            require_empty_stderr=True,
        )
        if compiler_result.stdout != f"{request.gate_plan_path}\n".encode(
            "utf-8"
        ):
            _fail(
                "gate-plan compiler stdout differs from its exact status contract"
            )
        plan = _load_gate_plan(request, pending)
        _assert_pending_unchanged(request, pending)

        report_plan, gate_plans = _qualification_plans(request)
        task10 = _run_task10_prerequisite(
            request, pending, plan, runner
        )
        execution = _execute_gate_plan(
            request,
            pending,
            plan,
            report_plan,
            gate_plans,
            runner,
        )
        gate_outputs = execution.outputs
        publication = execution.publication
        _assert_pending_unchanged(request, pending)
        _assert_snapshot_unchanged(
            plan.snapshot, label="installed acceptance gate plan"
        )

        commit_inputs = tuple(
            (gate_id, plan.path) for gate_id, plan in gate_plans
        )
        if (
            tuple(gate_id for gate_id, _ in commit_inputs)
            != REQUIRED_ACCEPTANCE_GATES
        ):
            _fail("commit gate input set is not the exact canonical eight")
        commit_result = runner(
            _installer_argv(request, "commit", gate_inputs=commit_inputs),
            request.timeouts.commit,
            BASE_ENVIRONMENT,
        )
        _require_successful_command(
            commit_result, label="installer commit", require_empty_stderr=True
        )
        commit_fields = _parse_key_value_stdout(
            commit_result.stdout,
            label="installer commit",
            expected_keys=CLOSEOUT_STDOUT_KEYS,
        )
        if (
            commit_fields["MACSCOPE_INSTALL_RELEASE_PHASE"] != "committed"
            or commit_fields["MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN"]
            != request.candidate_token
        ):
            _fail("installer commit stdout does not bind the exact candidate")
        terminal = _validate_terminal_commit(request, pending)
        return _publish_result(
            request,
            pending,
            task10,
            plan,
            gate_outputs,
            publication,
            terminal,
            clock_ns=clock_ns,
        )
    except BaseException as error:
        if isinstance(error, SystemExit):
            raise
        primary = _bounded_diagnostic(error)
        if not begin_invoked:
            raise TransactionFailed(
                primary,
                rollback_attempted=False,
                rollback_succeeded=None,
                rollback_diagnostic=None,
            ) from error
        rollback_attempted, rollback_succeeded, rollback_diagnostic = _rollback(request, runner)
        raise TransactionFailed(
            primary,
            rollback_attempted=rollback_attempted,
            rollback_succeeded=rollback_succeeded,
            rollback_diagnostic=rollback_diagnostic,
        ) from error


@contextlib.contextmanager
def _termination_signal_scope() -> Iterator[None]:
    originals: dict[signal.Signals, Any] = {}

    def interrupt(signal_number: int, _frame: object) -> NoReturn:
        raise TransactionInterrupted(signal_number)

    try:
        for value in (signal.SIGINT, signal.SIGTERM):
            originals[value] = signal.getsignal(value)
            signal.signal(value, interrupt)
        yield
    finally:
        for value, handler in originals.items():
            signal.signal(value, handler)


def main(
    argv: list[str] | None = None,
    *,
    _allow_test_destination: bool = False,
    _runner: CommandRunner | None = None,
    _install_signal_handlers: bool = True,
) -> int:
    arguments = parse_arguments(argv)
    try:
        request = _bind_request(
            arguments, allow_test_destination=_allow_test_destination
        )
    except (TransactionError, OSError, ValueError) as error:
        print(
            "ERROR: installed acceptance transaction refused: "
            f"{_bounded_diagnostic(error)}",
            file=sys.stderr,
        )
        return 2
    runner = _runner or _run_command
    scope = (
        _termination_signal_scope()
        if _install_signal_handlers
        else contextlib.nullcontext()
    )
    try:
        with scope:
            outcome = execute_transaction(request, runner=runner)
    except TransactionFailed as error:
        diagnostic = (
            "ERROR: installed acceptance transaction failed: "
            f"{error.primary}"
        )
        if error.rollback_attempted and error.rollback_succeeded:
            diagnostic += "; rollback=rolled-back"
        elif error.rollback_attempted:
            diagnostic += (
                "; ROLLBACK FAILED: "
                f"{error.rollback_diagnostic or 'unspecified rollback failure'}"
            )
        elif error.rollback_diagnostic:
            diagnostic += "; " + error.rollback_diagnostic
        print(diagnostic, file=sys.stderr)
        return 1
    print(outcome.result_output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
