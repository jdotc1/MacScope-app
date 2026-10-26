#!/usr/bin/env python3
"""Atomically install one exact Gate F Release candidate in /Applications.

The public CLI has exactly one production destination:
``/Applications/MacScope.app``.  Tests call :func:`main` with the private
``_allow_test_destination`` seam so the same transaction can be exercised on a
temporary same-volume directory without mutating the production installation.

The transaction is deliberately process-agnostic.  It neither discovers nor
signals processes; lifecycle admission remains the caller's responsibility.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
import plistlib
import secrets
import shutil
import stat
import sys
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.check_local_signing_policy import (  # noqa: E402
    collect_installed_source_equality,
)
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    decode_canonical_bytes,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (  # noqa: E402
    BundleSnapshot,
    CandidateMaterializationError,
    bundle_snapshots_match,
    capture_bundle_snapshot,
    require_unchanged_bundle_snapshot,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    STABLE_ID_RE,
    candidate_identity_sha256,
    is_git_object,
    is_sha256,
    parse_candidate_identity,
)
from Scripts.reconstruction.write_execution_report import (  # noqa: E402
    ExecutionReportError,
    document as execution_report_document,
    qualification_run_authority,
)


PRODUCTION_DESTINATION = Path("/Applications/MacScope.app")
# Schema 2 closes the physical bundle identity as well as the tree digests.
# A tree digest does not retain the root directory mode, so schema 1 cannot be
# favorable *operation* evidence for the current transaction contract.  The
# separately-scoped source-equality receipt remains schema 1.
OPERATION_REPORT_SCHEMA_VERSION = 2
REPORT_SCHEMA_VERSION = 1
OPERATION_REPORT_NAME = "InstallReleaseToApplications.operation-report.json"
SOURCE_EQUALITY_REPORT_NAME = (
    "InstallReleaseToApplications.source-equality-report.json"
)
EXECUTION_REPORT_NAME = "InstallReleaseToApplications.execution-report.json"
STDOUT_KEYS = (
    ("MACSCOPE_INSTALL_RELEASE_OPERATION_REPORT", OPERATION_REPORT_NAME),
    (
        "MACSCOPE_INSTALL_RELEASE_SOURCE_EQUALITY_REPORT",
        SOURCE_EQUALITY_REPORT_NAME,
    ),
    ("MACSCOPE_INSTALL_RELEASE_EXECUTION_REPORT", EXECUTION_REPORT_NAME),
)
MAX_CANDIDATE_BYTES = 4 * 1024 * 1024
MAX_DIAGNOSTIC_BYTES = 16 * 1024
MAX_PENDING_TRANSACTION_BYTES = 256 * 1024
MAX_ACCEPTANCE_RECEIPT_BYTES = 4 * 1024 * 1024
MAX_ACCEPTANCE_GATE_INPUT_BYTES = 1024 * 1024
MAX_COMMIT_AUTHORITY_BYTES = 64 * 1024
MAX_INITIALIZATION_AUTHORITY_BYTES = 64 * 1024
PENDING_TRANSACTION_SCHEMA_VERSION = 3
ACCEPTANCE_RECEIPT_SCHEMA_VERSION = 2
ACCEPTANCE_RECEIPT_KIND = "macscope-installer-acceptance"
ACCEPTANCE_RECEIPT_NAME = "MacScopeInstaller.acceptance-receipt.json"
ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION = 1
ACCEPTANCE_GATE_INPUT_KIND = "macscope-installer-acceptance-gate"
COMMIT_AUTHORITY_SCHEMA_VERSION = 1
COMMIT_AUTHORITY_KIND = "macscope-installer-commit-authority"
COMMIT_AUTHORITY_NAME = "commit-authority.json"
INITIALIZATION_AUTHORITY_SCHEMA_VERSION = 1
INITIALIZATION_AUTHORITY_KIND = "macscope-installer-initialization-authority"
INITIALIZATION_AUTHORITY_NAME = "initialization-authority.json"
BUILD_PROVENANCE_RELATIVE_PATH = (
    "Contents/Resources/MacScopeBuildProvenance.json"
)
REQUIRED_ACCEPTANCE_GATES = (
    "cli",
    "forced-legacy-grid",
    "full-surface",
    "gui",
    "mcp",
    "native-xpc",
    "shellbroker-launchagent",
    "signing",
)
PENDING_TRANSACTION_FIELDS = frozenset(
    {
        "acceptance_receipt_path",
        "application_executable_sha256",
        "artifact_root",
        "artifact_root_identity",
        "began_at_unix_ns",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity",
        "candidate_identity_sha256",
        "candidate_token",
        "destination_identity",
        "execution_identity_sha256",
        "exposed_at_unix_ns",
        "installed_app_path",
        "phase",
        "predecessor_digest",
        "predecessor_identity",
        "predecessor_observations_sha256",
        "predecessor_path",
        "predecessor_present",
        "qualification_run_id",
        "qualification_run_nonce",
        "schema_version",
        "source_app_path",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
    }
)
SNAPSHOT_RECORD_FIELDS = frozenset(
    {"closed_tree_sha256", "content_sha256", "directory_identity", "root_mode"}
)
ARTIFACT_ROOT_IDENTITY_FIELDS = frozenset(
    {
        "directory_device",
        "directory_inode",
        "parent_device",
        "parent_inode",
        "path",
        "state_at_begin",
    }
)
DESTINATION_IDENTITY_FIELDS = frozenset(
    {
        "application_device",
        "application_inode",
        "application_mtime_ns",
        "closed_tree_sha256",
        "content_sha256",
        "parent_device",
        "parent_inode",
        "path",
        "root_mode",
    }
)
ACCEPTANCE_RECEIPT_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity",
        "execution_identity_sha256",
        "gates",
        "pending_state_sha256",
        "predecessor_digest",
        "predecessor_observations_sha256",
        "produced_at_unix_ns",
        "qualification_run_id",
        "qualification_run_nonce",
        "receipt_kind",
        "result",
        "rolled_back",
        "schema_version",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "transaction_id",
        "transaction_nonce",
        "transaction_phase",
    }
)
ACCEPTANCE_GATE_FIELDS = frozenset(
    {
        "ended_at_unix_ns",
        "evidence_sha256",
        "input_sha256",
        "result",
        "started_at_unix_ns",
    }
)
ACCEPTANCE_GATE_INPUT_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "destination_identity_sha256",
        "ended_at_unix_ns",
        "evidence_sha256",
        "execution_identity_sha256",
        "gate_id",
        "input_kind",
        "qualification_run_id",
        "qualification_run_nonce",
        "result",
        "rolled_back",
        "schema_version",
        "source_commit",
        "source_equality_sha256",
        "source_tree",
        "started_at_unix_ns",
        "transaction_id",
        "transaction_nonce",
        "transaction_phase",
    }
)
COMMIT_AUTHORITY_FIELDS = frozenset(
    {
        "acceptance_receipt_sha256",
        "authority_kind",
        "candidate_identity_sha256",
        "destination_identity",
        "pending_state_sha256",
        "schema_version",
        "transaction_id",
        "transaction_nonce",
    }
)
INITIALIZATION_AUTHORITY_FIELDS = frozenset(
    {
        "application_executable_sha256",
        "artifact_root",
        "artifact_root_identity",
        "build_provenance_sha256",
        "candidate_file_sha256",
        "candidate_identity_sha256",
        "initialization_kind",
        "installed_app_path",
        "pending_root",
        "predecessor_digest",
        "predecessor_identity",
        "predecessor_observations_sha256",
        "predecessor_present",
        "qualification_run_id",
        "qualification_run_nonce",
        "schema_version",
        "source_app_path",
        "source_commit",
        "source_tree",
    }
)

# Darwin's <stdio.h> renameatx_np(2) flags.
AT_FDCWD = -2
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004

EMBEDDED_EXECUTABLES = {
    "ai-agent-worker": (
        "AIAgentWorkerXPCService.xpc/Contents/MacOS/"
        "AIAgentWorkerXPCService"
    ),
    "analysis-worker": (
        "AnalysisWorkerXPCService.xpc/Contents/MacOS/"
        "AnalysisWorkerXPCService"
    ),
    "native-decompiler": (
        "NativeDecompilerXPCService.xpc/Contents/MacOS/"
        "NativeDecompilerXPCService"
    ),
    "shell-broker": (
        "ShellBrokerXPCService.xpc/Contents/MacOS/ShellBrokerXPCService"
    ),
}


class InstallationError(RuntimeError):
    """The installation cannot produce a favorable atomic result."""


class StageCopyError(InstallationError):
    """A copy failed after its one bounded partial-stage cleanup attempt."""


AtomicRename = Callable[[Path, Path, int], None]
EqualityCollector = Callable[
    [Path, Path], tuple[Optional[dict[str, str]], list[str]]
]
CopyTree = Callable[[Path, Path], None]
RemoveTree = Callable[[Path], None]
ReportWriter = Callable[[Path, object], None]
SyncRegularFile = Callable[[Path], None]
SyncDirectory = Callable[[Path], None]
ClockNS = Callable[[], int]
NonceFactory = Callable[[], str]


@dataclass(frozen=True)
class StableFile:
    path: Path
    metadata: tuple[int, int, int, int, int, int]
    payload: bytes


@dataclass(frozen=True)
class SourceAuthority:
    candidate: CandidateIdentity
    candidate_identity_sha256: str
    candidate_file_sha256: str
    candidate_file: StableFile
    source_snapshot: "ExactBundleSnapshot"
    bundle_identifier: str
    executable_sha256: str
    build_provenance_sha256: str
    embedded_executables: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class ExactBundleSnapshot:
    """Closed bundle tree plus the app-root mode omitted by tree digests."""

    tree: BundleSnapshot
    root_mode: int

    @property
    def root(self) -> Path:
        return self.tree.root

    @property
    def directory_identity(self) -> tuple[int, int, int, int]:
        return self.tree.directory_identity

    @property
    def digests(self):
        return self.tree.digests


@dataclass(frozen=True)
class PredecessorObservation:
    """Exact read-only authority for the destination before installation."""

    installed_app: Path
    snapshot: ExactBundleSnapshot | None
    document: Mapping[str, object]
    sha256: str


def _unix_ms() -> int:
    return time.time_ns() // 1_000_000


def _new_transaction_nonce() -> str:
    return secrets.token_hex(32)


def _bounded_diagnostic(value: object) -> str:
    text = str(value).replace("\x00", "�")
    payload = text.encode("utf-8", "replace")
    if len(payload) <= MAX_DIAGNOSTIC_BYTES:
        return text
    return payload[: MAX_DIAGNOSTIC_BYTES - 3].decode(
        "utf-8", "ignore"
    ) + "..."


def _metadata(value: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        stat.S_IMODE(value.st_mode),
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _capture_exact_bundle(path: Path) -> ExactBundleSnapshot:
    """Capture one tree and its root mode across a stable descriptor identity."""

    try:
        before = path.lstat()
    except OSError as error:
        raise InstallationError(f"cannot inspect bundle root {path}: {error}") from error
    if not stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise InstallationError(f"bundle root must be a non-symlink directory: {path}")
    try:
        tree = capture_bundle_snapshot(path, app_root=True)
        after = path.lstat()
    except (OSError, CandidateMaterializationError) as error:
        raise InstallationError(f"cannot capture exact bundle {path}: {error}") from error
    before_identity = (
        before.st_dev,
        before.st_ino,
        stat.S_IMODE(before.st_mode),
        before.st_nlink,
        before.st_size,
        before.st_mtime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        stat.S_IMODE(after.st_mode),
        after.st_nlink,
        after.st_size,
        after.st_mtime_ns,
    )
    if before_identity != after_identity or (
        tree.directory_identity[:3]
        != (before.st_dev, before.st_ino, before.st_mtime_ns)
    ):
        raise InstallationError(f"bundle root changed during exact capture: {path}")
    return ExactBundleSnapshot(tree=tree, root_mode=stat.S_IMODE(before.st_mode))


def _stable_file(path: Path, *, maximum_bytes: int | None = None) -> StableFile:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(
        os, "O_CLOEXEC", 0
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InstallationError(f"cannot safely open required file {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise InstallationError(
                f"required file must be an ordinary single-link file: {path}"
            )
        if maximum_bytes is not None and before.st_size > maximum_bytes:
            raise InstallationError(f"required file exceeds its size bound: {path}")
        chunks: list[bytes] = []
        observed_size = 0
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            observed_size += len(block)
            if maximum_bytes is not None and observed_size > maximum_bytes:
                raise InstallationError(f"required file exceeds its size bound: {path}")
            chunks.append(block)
        after = os.fstat(descriptor)
        if _metadata(before) != _metadata(after):
            raise InstallationError(f"required file changed while read: {path}")
        return StableFile(path=path, metadata=_metadata(before), payload=b"".join(chunks))
    except OSError as error:
        raise InstallationError(f"cannot safely read required file {path}: {error}") from error
    finally:
        os.close(descriptor)


def _require_same_file(
    snapshot: StableFile,
    *,
    phase: str,
    maximum_bytes: int = MAX_CANDIDATE_BYTES,
) -> None:
    observed = _stable_file(snapshot.path, maximum_bytes=maximum_bytes)
    if observed.metadata != snapshot.metadata or observed.payload != snapshot.payload:
        raise InstallationError(f"stable file changed before {phase}: {snapshot.path}")


def _canonical_existing(path: Path, *, directory: bool, label: str) -> Path:
    if not path.is_absolute():
        raise InstallationError(f"{label} must be an absolute canonical path")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InstallationError(f"{label} is unavailable: {path}: {error}") from error
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "regular file"
        raise InstallationError(f"{label} must be a non-symlink {kind}")
    if resolved != path:
        raise InstallationError(f"{label} must not traverse symbolic links")
    return resolved


def _canonical_destination(path: Path) -> Path:
    if not path.is_absolute() or path.name != "MacScope.app":
        raise InstallationError(
            "installed app must be an absolute path named MacScope.app"
        )
    parent = _canonical_existing(path.parent, directory=True, label="installed app parent")
    canonical = parent / path.name
    if canonical != path:
        raise InstallationError("installed app path must be canonical")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return canonical
    except OSError as error:
        raise InstallationError(f"installed app cannot be inspected: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise InstallationError(
            "installed app must be absent or a non-symlink directory"
        )
    if path.resolve(strict=True) != path:
        raise InstallationError("installed app must not traverse symbolic links")
    return canonical


def _canonical_destination_slot(path: Path) -> Path:
    """Bind the installation slot without requiring a safe current leaf.

    Rollback must remain available when an external actor replaces the exposed
    candidate with a symlink, regular file, or otherwise untrusted entry.  The
    canonical parent and exact lexical destination still remain mandatory.
    """

    if not path.is_absolute() or path.name != "MacScope.app":
        raise InstallationError(
            "installed app must be an absolute path named MacScope.app"
        )
    parent = _canonical_existing(
        path.parent, directory=True, label="installed app parent"
    )
    canonical = parent / path.name
    if canonical != path:
        raise InstallationError("installed app path must be canonical")
    return canonical


def _canonical_new_root(path: Path) -> Path:
    if not path.is_absolute():
        raise InstallationError("artifact root must be an absolute canonical path")
    parent = _canonical_existing(path.parent, directory=True, label="artifact root parent")
    canonical = parent / path.name
    if canonical != path:
        raise InstallationError("artifact root must be canonical")
    try:
        path.lstat()
    except FileNotFoundError:
        return canonical
    except OSError as error:
        raise InstallationError(f"artifact root cannot be inspected: {error}") from error
    raise InstallationError("refusing to overwrite the artifact root")


def _canonical_transaction_artifact_root(path: Path) -> Path:
    """Validate the authority path without following or accepting symlinks."""
    if not path.is_absolute() or not path.name or path.name in (".", ".."):
        raise InstallationError("artifact root must be an absolute canonical path")
    parent = _canonical_existing(path.parent, directory=True, label="artifact root parent")
    canonical = parent / path.name
    if canonical != path:
        raise InstallationError("artifact root must be canonical")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return canonical
    except OSError as error:
        raise InstallationError(f"artifact root cannot be inspected: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise InstallationError("artifact root must be absent or a non-symlink directory")
    if path.resolve(strict=True) != path:
        raise InstallationError("artifact root must not traverse symbolic links")
    return canonical


def _sha256_payload(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _sha256_file(path: Path) -> str:
    return _sha256_payload(_stable_file(path).payload)


def _contained_file(root: Path, relative: str, *, label: str) -> Path:
    current = root
    for part in Path(relative).parts:
        if part in {"", ".", ".."}:
            raise InstallationError(f"unsafe {label} relative path")
        current = current / part
        try:
            metadata = current.lstat()
        except OSError as error:
            raise InstallationError(f"{label} is unavailable: {current}: {error}") from error
        if stat.S_ISLNK(metadata.st_mode):
            raise InstallationError(f"{label} traverses a symbolic link: {current}")
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise InstallationError(f"{label} must be an ordinary single-link file")
    return current


def _bundle_identifier_and_executable(app: Path) -> tuple[str, Path]:
    info = _contained_file(app, "Contents/Info.plist", label="source app Info.plist")
    try:
        document = plistlib.loads(_stable_file(info, maximum_bytes=2 * 1024 * 1024).payload)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise InstallationError(f"source app Info.plist is invalid: {error}") from error
    if not isinstance(document, Mapping):
        raise InstallationError("source app Info.plist must be a dictionary")
    bundle_identifier = document.get("CFBundleIdentifier")
    executable_name = document.get("CFBundleExecutable")
    if not isinstance(bundle_identifier, str) or not bundle_identifier:
        raise InstallationError("source app Info.plist has no bundle identifier")
    if (
        not isinstance(executable_name, str)
        or not executable_name
        or executable_name in {".", ".."}
        or "/" in executable_name
        or "\x00" in executable_name
    ):
        raise InstallationError("source app Info.plist has no safe executable name")
    executable = _contained_file(
        app,
        f"Contents/MacOS/{executable_name}",
        label="source app executable",
    )
    return bundle_identifier, executable


def _load_source_authority(candidate_path: Path, source_app: Path) -> SourceAuthority:
    candidate_file = _stable_file(candidate_path, maximum_bytes=MAX_CANDIDATE_BYTES)
    try:
        document = decode_canonical_bytes(candidate_file.payload)
    except CanonicalJSONError as error:
        raise InstallationError(f"candidate identity is not canonical JSON: {error}") from error
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        raise InstallationError(f"candidate identity is invalid: {detail}")

    source_snapshot = _capture_exact_bundle(source_app)
    if source_snapshot.digests.content_sha256 != candidate.application.bundle_sha256:
        raise InstallationError("source app bundle SHA-256 differs from the candidate")
    if (
        source_snapshot.digests.closed_tree_sha256
        != candidate.application.closed_tree_sha256
    ):
        raise InstallationError("source app closed-tree SHA-256 differs from the candidate")
    if source_snapshot.root_mode != candidate.application.root_mode:
        raise InstallationError("source app root mode differs from the candidate")

    bundle_identifier, executable = _bundle_identifier_and_executable(source_app)
    executable_sha256 = _sha256_file(executable)
    build_provenance = _contained_file(
        source_app,
        BUILD_PROVENANCE_RELATIVE_PATH,
        label="source app build provenance",
    )
    build_provenance_sha256 = _sha256_file(build_provenance)
    if bundle_identifier != candidate.application.bundle_identifier:
        raise InstallationError("source app bundle identifier differs from the candidate")
    if executable_sha256 != candidate.application.executable_sha256:
        raise InstallationError("source app executable SHA-256 differs from the candidate")

    expected_embedded = {
        item.identity_id: item.sha256
        for item in candidate.application.embedded_executables
    }
    if set(expected_embedded) != set(EMBEDDED_EXECUTABLES):
        raise InstallationError(
            "candidate embedded executable identity set is not the closed production set"
        )
    observed_embedded: list[tuple[str, str]] = []
    for identity_id, relative in sorted(EMBEDDED_EXECUTABLES.items()):
        executable_path = _contained_file(
            source_app / "Contents/XPCServices",
            relative,
            label=f"source {identity_id} executable",
        )
        digest = _sha256_file(executable_path)
        if digest != expected_embedded[identity_id]:
            raise InstallationError(
                f"source {identity_id} executable SHA-256 differs from the candidate"
            )
        observed_embedded.append((identity_id, digest))

    return SourceAuthority(
        candidate=candidate,
        candidate_identity_sha256=candidate_identity_sha256(candidate),
        candidate_file_sha256=_sha256_payload(candidate_file.payload),
        candidate_file=candidate_file,
        source_snapshot=source_snapshot,
        bundle_identifier=bundle_identifier,
        executable_sha256=executable_sha256,
        build_provenance_sha256=build_provenance_sha256,
        embedded_executables=tuple(observed_embedded),
    )


def _require_source_unchanged(authority: SourceAuthority, *, phase: str) -> None:
    _require_same_file(authority.candidate_file, phase=phase)
    try:
        require_unchanged_bundle_snapshot(authority.source_snapshot.tree, phase=phase)
    except CandidateMaterializationError as error:
        raise InstallationError(str(error)) from error
    observed = _capture_exact_bundle(authority.source_snapshot.root)
    if observed.root_mode != authority.source_snapshot.root_mode:
        raise InstallationError(f"source app root mode changed before {phase}")


def _darwin_atomic_rename(source: Path, destination: Path, flags: int) -> None:
    if sys.platform != "darwin":
        raise InstallationError("renameatx_np atomic installation requires Darwin")
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameatx_np = libc.renameatx_np
    except AttributeError as error:
        raise InstallationError("Darwin renameatx_np is unavailable") from error
    renameatx_np.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameatx_np.restype = ctypes.c_int
    result = renameatx_np(
        AT_FDCWD,
        os.fsencode(source),
        AT_FDCWD,
        os.fsencode(destination),
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(
            error_number,
            os.strerror(error_number),
            f"{source} -> {destination}",
        )


def _create_artifact_root(path: Path) -> None:
    try:
        os.mkdir(path, 0o700)
    except OSError as error:
        raise InstallationError(f"cannot create artifact root {path}: {error}") from error


def _write_create_only(path: Path, value: object) -> None:
    payload = canonical_bytes(value)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise InstallationError(f"cannot create report {path}: {error}") from error
    try:
        offset = 0
        while offset < len(payload):
            offset += os.write(descriptor, payload[offset:])
    except OSError as error:
        raise InstallationError(f"cannot write report {path}: {error}") from error
    finally:
        os.close(descriptor)


def _fsync_regular_file(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(
        os, "O_CLOEXEC", 0
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InstallationError(f"cannot open file for durability: {path}: {error}") from error
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise InstallationError(f"durability target is not an ordinary file: {path}")
        os.fsync(descriptor)
        after = os.fstat(descriptor)
        if _metadata(before) != _metadata(after):
            raise InstallationError(f"file changed across durability barrier: {path}")
    except OSError as error:
        raise InstallationError(f"cannot durably commit file: {path}: {error}") from error
    finally:
        os.close(descriptor)


def _path_exists(path: Path) -> bool:
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError as error:
        raise InstallationError(f"cannot inspect transaction path {path}: {error}") from error


def _remove_tree(path: Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return
    except OSError as error:
        raise InstallationError(f"cannot inspect transaction stage {path}: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise InstallationError(f"refusing to remove unsafe transaction stage: {path}")
    shutil.rmtree(path)


def _fresh_sibling(anchor: Path, label: str) -> Path:
    path = anchor.parent / (
        f".{anchor.name}.{label}-{os.getpid()}-{secrets.token_hex(8)}"
    )
    if _path_exists(path):
        raise InstallationError(f"fresh {label} unexpectedly exists")
    return path


def _default_copy_tree(source: Path, stage: Path) -> None:
    shutil.copytree(source, stage, copy_function=shutil.copy2, symlinks=False)


def _copy_to_fresh_stage(
    source: Path,
    installed: Path,
    stage: Path,
    *,
    copy_tree: CopyTree,
    remove_tree: RemoveTree,
    sync_directory: SyncDirectory,
) -> None:
    if stage.parent != installed.parent or not stage.name.startswith(
        f".{installed.name}.install-stage-"
    ):
        raise InstallationError("installation stage is not the vetted destination sibling")
    if _path_exists(stage):
        raise InstallationError("fresh installation stage unexpectedly exists")
    try:
        copy_tree(source, stage)
    except Exception as copy_error:
        cleanup_error: Optional[Exception] = None
        if _path_exists(stage):
            try:
                remove_tree(stage)
                if not _path_exists(stage):
                    sync_directory(installed.parent)
            except Exception as error:
                cleanup_error = error
        residue = _path_exists(stage)
        diagnostic = f"cannot stage the source app: {copy_error}"
        if cleanup_error is not None:
            diagnostic += f"; partial-stage cleanup failed: {cleanup_error}"
        diagnostic += f"; partial-stage residue present: {str(residue).lower()}"
        raise StageCopyError(diagnostic) from copy_error
    if not _path_exists(stage):
        raise InstallationError("copy operation returned without creating the stage")
    if stage.stat().st_dev != installed.parent.stat().st_dev:
        raise InstallationError("installation stage is not on the destination volume")


def _identity_mapping(snapshot: ExactBundleSnapshot | None) -> dict[str, object] | None:
    if snapshot is None:
        return None
    return {
        "bundle_sha256": snapshot.digests.content_sha256,
        "closed_tree_sha256": snapshot.digests.closed_tree_sha256,
        "root_mode": snapshot.root_mode,
    }


def _collect_exact_equality(
    collector: EqualityCollector,
    source: Path,
    observed: Path,
    authority: SourceAuthority,
    *,
    phase: str,
) -> dict[str, str | int]:
    try:
        equality, errors = collector(source, observed)
    except Exception as error:
        raise InstallationError(
            f"{phase} signing-policy equality collector failed: {error}"
        ) from error
    if errors:
        raise InstallationError(f"{phase} equality failed: {'; '.join(errors)}")
    if equality is None:
        raise InstallationError(f"{phase} equality collector returned no authority")
    source_snapshot = _capture_exact_bundle(source)
    observed_snapshot = _capture_exact_bundle(observed)
    expected: dict[str, str | int] = {
        "release_bundle_sha256": authority.candidate.application.bundle_sha256,
        "release_closed_tree_sha256": authority.candidate.application.closed_tree_sha256,
        "release_root_mode": authority.candidate.application.root_mode,
        "release_executable_sha256": authority.candidate.application.executable_sha256,
        "installed_bundle_sha256": authority.candidate.application.bundle_sha256,
        "installed_closed_tree_sha256": authority.candidate.application.closed_tree_sha256,
        "installed_root_mode": authority.candidate.application.root_mode,
        "installed_executable_sha256": authority.candidate.application.executable_sha256,
    }
    equality = {
        **equality,
        "release_root_mode": source_snapshot.root_mode,
        "installed_root_mode": observed_snapshot.root_mode,
    }
    if equality != expected:
        raise InstallationError(
            f"{phase} signing-policy equality authority differs from the candidate"
        )
    return dict(equality)


def _same_digest(left: ExactBundleSnapshot, right: ExactBundleSnapshot) -> bool:
    return left.digests == right.digests


def _same_relocated_directory_identity(
    observed: ExactBundleSnapshot, expected: ExactBundleSnapshot
) -> bool:
    """Require the exact physical directory across one Darwin rename.

    Darwin updates directory ctime when ``renameatx_np`` relocates or swaps the
    entry; a bounded diagnostic against the real primitive confirms that dev,
    inode, and directory mtime remain exact while ctime advances.  Matching the
    relocation-stable identity and requiring a nondecreasing ctime rejects a
    digest-identical clone without falsely rejecting the genuine renamed inode.
    """

    observed_dev, observed_ino, observed_mtime, observed_ctime = (
        observed.directory_identity
    )
    expected_dev, expected_ino, expected_mtime, expected_ctime = (
        expected.directory_identity
    )
    return (
        (observed_dev, observed_ino, observed_mtime)
        == (expected_dev, expected_ino, expected_mtime)
        and observed_ctime >= expected_ctime
        and observed.root_mode == expected.root_mode
    )


def _rollback(
    *,
    installed: Path,
    stage: Path,
    predecessor: ExactBundleSnapshot | None,
    atomic_rename: AtomicRename,
    source_snapshot: ExactBundleSnapshot,
    remove_tree: RemoveTree,
    sync_directory: SyncDirectory,
) -> tuple[bool, str | None]:
    try:
        if predecessor is not None:
            atomic_rename(stage, installed, RENAME_SWAP)
            sync_directory(installed.parent)
            restored = _capture_exact_bundle(installed)
            if (
                not _same_relocated_directory_identity(restored, predecessor)
                or not _same_digest(restored, predecessor)
            ):
                raise InstallationError("restored predecessor identity is not exact")
            displaced = _capture_exact_bundle(stage)
            if (
                _same_relocated_directory_identity(displaced, source_snapshot)
                and _same_digest(displaced, source_snapshot)
            ):
                remove_tree(stage)
                sync_directory(installed.parent)
            # If another actor changed the exposed app, preserve that displaced
            # tree at the private stage rather than deleting unrelated bytes.
        else:
            if stage.exists() or stage.is_symlink():
                raise InstallationError("absent-destination rollback stage is occupied")
            atomic_rename(installed, stage, RENAME_EXCL)
            sync_directory(installed.parent)
            if installed.exists() or installed.is_symlink():
                raise InstallationError("absent predecessor was not restored")
            displaced = _capture_exact_bundle(stage)
            if (
                not _same_relocated_directory_identity(displaced, source_snapshot)
                or not _same_digest(displaced, source_snapshot)
            ):
                raise InstallationError("rolled-back candidate identity is not exact")
            if _same_digest(displaced, source_snapshot):
                remove_tree(stage)
                sync_directory(installed.parent)
        return True, None
    except Exception as error:
        return False, _bounded_diagnostic(error)


def _pending_root(installed_app: Path, token: str) -> Path:
    return installed_app.parent / f".MacScope.pending-{token}"


def _committing_root(installed_app: Path, token: str) -> Path:
    return installed_app.parent / f".MacScope.committing-{token}"


def _committed_root(
    installed_app: Path, token: str, transaction_id: str
) -> Path:
    return installed_app.parent / f".MacScope.committed-{token}-{transaction_id}"


def _committed_roots(installed_app: Path, token: str) -> tuple[Path, ...]:
    return tuple(
        sorted(installed_app.parent.glob(f".MacScope.committed-{token}-*"))
    )


def _rolled_back_root(
    installed_app: Path, token: str, transaction_id: str
) -> Path:
    return installed_app.parent / f".MacScope.rolled-back-{token}-{transaction_id}"


def _pending_state_path(root: Path) -> Path:
    return root / "transaction.json"


def _acceptance_receipt_path(artifact_root: Path) -> Path:
    return artifact_root / ACCEPTANCE_RECEIPT_NAME


def _nonnegative_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def _require_closed_mapping(
    value: object,
    fields: frozenset[str],
    *,
    label: str,
) -> Mapping[str, object]:
    if not isinstance(value, Mapping) or set(value) != fields:
        raise InstallationError(f"{label} does not have the exact closed schema")
    return value


def _snapshot_record(snapshot: ExactBundleSnapshot) -> dict[str, object]:
    return {
        "content_sha256": snapshot.digests.content_sha256,
        "closed_tree_sha256": snapshot.digests.closed_tree_sha256,
        "root_mode": snapshot.root_mode,
        "directory_identity": list(snapshot.directory_identity),
    }


def _validate_snapshot_record(record: object, *, label: str) -> Mapping[str, object]:
    value = _require_closed_mapping(record, SNAPSHOT_RECORD_FIELDS, label=label)
    if not is_sha256(value.get("content_sha256")) or not is_sha256(
        value.get("closed_tree_sha256")
    ):
        raise InstallationError(f"{label} has an invalid tree digest")
    if not _nonnegative_integer(value.get("root_mode")):
        raise InstallationError(f"{label} has an invalid root mode")
    directory_identity = value.get("directory_identity")
    if (
        not isinstance(directory_identity, list)
        or len(directory_identity) != 4
        or any(not _nonnegative_integer(item) for item in directory_identity)
    ):
        raise InstallationError(f"{label} has an invalid physical directory identity")
    return value


def _snapshot_matches_record(snapshot: ExactBundleSnapshot, record: object) -> bool:
    try:
        value = _validate_snapshot_record(record, label="bundle snapshot record")
    except InstallationError:
        return False
    observed_dev, observed_ino, observed_mtime, observed_ctime = (
        snapshot.directory_identity
    )
    expected_dev, expected_ino, expected_mtime, expected_ctime = value[
        "directory_identity"
    ]
    return (
        snapshot.digests.content_sha256 == value["content_sha256"]
        and snapshot.digests.closed_tree_sha256 == value["closed_tree_sha256"]
        and snapshot.root_mode == value["root_mode"]
        and (observed_dev, observed_ino, observed_mtime)
        == (expected_dev, expected_ino, expected_mtime)
        and observed_ctime >= expected_ctime
    )


def _predecessor_digest(present: bool, identity: object) -> str:
    return _sha256_payload(
        canonical_bytes({"identity": identity, "present": present})
    )


def capture_predecessor_observation(installed_app: Path) -> PredecessorObservation:
    """Capture the exact canonical predecessor bytes consumed by ``begin``.

    Keeping this operation in the installer module gives the read-only producer
    and the mutating transaction one identity implementation and one canonical
    byte representation.
    """

    installed_app = _canonical_destination(installed_app)
    snapshot = (
        _capture_exact_bundle(installed_app)
        if _path_exists(installed_app)
        else None
    )
    identity = _snapshot_record(snapshot) if snapshot is not None else None
    document: Mapping[str, object] = {
        "identity": identity,
        "present": snapshot is not None,
    }
    return PredecessorObservation(
        installed_app=installed_app,
        snapshot=snapshot,
        document=document,
        sha256=_sha256_payload(canonical_bytes(document)),
    )


def _directory_anchor(path: Path, *, label: str) -> os.stat_result:
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise InstallationError(f"{label} is unavailable: {path}: {error}") from error
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise InstallationError(f"{label} must be a non-symlink directory")
    if resolved != path:
        raise InstallationError(f"{label} must not traverse symbolic links")
    return metadata


def _artifact_root_identity(path: Path) -> dict[str, object]:
    parent = _directory_anchor(path.parent, label="artifact root parent")
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        state = "absent"
        device: int | None = None
        inode: int | None = None
    except OSError as error:
        raise InstallationError(f"artifact root cannot be inspected: {error}") from error
    else:
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise InstallationError("artifact root must be absent or a non-symlink directory")
        if path.resolve(strict=True) != path:
            raise InstallationError("artifact root must not traverse symbolic links")
        state = "present"
        device = metadata.st_dev
        inode = metadata.st_ino
    return {
        "path": str(path),
        "parent_device": parent.st_dev,
        "parent_inode": parent.st_ino,
        "state_at_begin": state,
        "directory_device": device,
        "directory_inode": inode,
    }


def _validate_artifact_root_identity(
    record: object,
    artifact_root: Path,
    *,
    require_root: bool,
    validate_current: bool = True,
) -> Mapping[str, object]:
    value = _require_closed_mapping(
        record, ARTIFACT_ROOT_IDENTITY_FIELDS, label="pending artifact root identity"
    )
    if value.get("path") != str(artifact_root):
        raise InstallationError("pending artifact root identity path differs")
    for field in ("parent_device", "parent_inode"):
        if not _nonnegative_integer(value.get(field)):
            raise InstallationError("pending artifact root parent identity is invalid")
    state_at_begin = value.get("state_at_begin")
    if state_at_begin not in {"absent", "present"}:
        raise InstallationError("pending artifact root initial state is invalid")
    if state_at_begin == "present":
        if not _nonnegative_integer(value.get("directory_device")) or not _nonnegative_integer(
            value.get("directory_inode")
        ):
            raise InstallationError("pending artifact root directory identity is invalid")
    elif value.get("directory_device") is not None or value.get("directory_inode") is not None:
        raise InstallationError("absent pending artifact root carries a directory identity")

    if not validate_current:
        return value

    parent = _directory_anchor(artifact_root.parent, label="artifact root parent")
    if (parent.st_dev, parent.st_ino) != (
        value["parent_device"],
        value["parent_inode"],
    ):
        raise InstallationError("artifact root parent physical identity changed")
    try:
        current = artifact_root.lstat()
    except FileNotFoundError:
        if require_root or state_at_begin == "present":
            label = "acceptance receipt artifact root" if require_root else "bound artifact root"
            raise InstallationError(f"{label} is missing")
        return value
    except OSError as error:
        raise InstallationError(f"bound artifact root cannot be inspected: {error}") from error
    if not stat.S_ISDIR(current.st_mode) or stat.S_ISLNK(current.st_mode):
        raise InstallationError("bound artifact root is not an ordinary directory")
    if artifact_root.resolve(strict=True) != artifact_root:
        raise InstallationError("bound artifact root traverses a symbolic link")
    if state_at_begin == "present" and (current.st_dev, current.st_ino) != (
        value["directory_device"],
        value["directory_inode"],
    ):
        raise InstallationError("bound artifact root physical identity changed")
    return value


def _require_directory_identity(
    path: Path,
    expected: tuple[int, int],
    *,
    label: str,
) -> None:
    metadata = _directory_anchor(path, label=label)
    if (metadata.st_dev, metadata.st_ino) != expected:
        raise InstallationError(f"{label} physical identity changed")


def _destination_identity(
    installed_app: Path,
    candidate_snapshot: ExactBundleSnapshot,
) -> dict[str, object]:
    parent = _directory_anchor(installed_app.parent, label="installed app parent")
    device, inode, mtime_ns, _ctime_ns = candidate_snapshot.directory_identity
    return {
        "path": str(installed_app),
        "parent_device": parent.st_dev,
        "parent_inode": parent.st_ino,
        "application_device": device,
        "application_inode": inode,
        "application_mtime_ns": mtime_ns,
        "content_sha256": candidate_snapshot.digests.content_sha256,
        "closed_tree_sha256": candidate_snapshot.digests.closed_tree_sha256,
        "root_mode": candidate_snapshot.root_mode,
    }


def _validate_destination_identity(
    record: object,
    installed_app: Path,
    *,
    snapshot: ExactBundleSnapshot | None = None,
) -> Mapping[str, object]:
    value = _require_closed_mapping(
        record, DESTINATION_IDENTITY_FIELDS, label="pending destination identity"
    )
    if value.get("path") != str(installed_app):
        raise InstallationError("pending destination identity path differs")
    for field in (
        "parent_device",
        "parent_inode",
        "application_device",
        "application_inode",
        "application_mtime_ns",
        "root_mode",
    ):
        if not _nonnegative_integer(value.get(field)):
            raise InstallationError("pending destination physical identity is invalid")
    if not is_sha256(value.get("content_sha256")) or not is_sha256(
        value.get("closed_tree_sha256")
    ):
        raise InstallationError("pending destination digest identity is invalid")
    parent = _directory_anchor(installed_app.parent, label="installed app parent")
    if (parent.st_dev, parent.st_ino) != (
        value["parent_device"],
        value["parent_inode"],
    ):
        raise InstallationError("installed app parent physical identity changed")
    if snapshot is not None:
        device, inode, mtime_ns, _ctime_ns = snapshot.directory_identity
        if (
            snapshot.digests.content_sha256 != value["content_sha256"]
            or snapshot.digests.closed_tree_sha256 != value["closed_tree_sha256"]
            or snapshot.root_mode != value["root_mode"]
            or (device, inode, mtime_ns)
            != (
                value["application_device"],
                value["application_inode"],
                value["application_mtime_ns"],
            )
        ):
            raise InstallationError("installed destination identity changed")
    return value


def _transaction_id(
    *,
    token: str,
    transaction_nonce: str,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    destination_identity: Mapping[str, object],
) -> str:
    return _sha256_payload(
        canonical_bytes(
            {
                "artifact_root": str(artifact_root),
                "candidate_identity_sha256": token,
                "destination_identity": destination_identity,
                "qualification_run_id": qualification_run.run_id,
                "qualification_run_nonce": qualification_run.nonce,
                "transaction_nonce": transaction_nonce,
            }
        )
    )


def _execution_identity_sha256(
    *,
    authority: SourceAuthority,
    token: str,
    transaction_id: str,
    transaction_nonce: str,
    qualification_run: QualificationRunAuthority,
    destination_identity: Mapping[str, object],
    source_equality_sha256: str,
) -> str:
    return _sha256_payload(
        canonical_bytes(
            {
                "identity_kind": "macscope-installer-pending-execution",
                "schema_version": 1,
                "application_executable_sha256": authority.executable_sha256,
                "build_provenance_sha256": authority.build_provenance_sha256,
                "candidate_file_sha256": authority.candidate_file_sha256,
                "candidate_identity_sha256": token,
                "destination_identity": destination_identity,
                "qualification_run_id": qualification_run.run_id,
                "qualification_run_nonce": qualification_run.nonce,
                "source_commit": authority.candidate.source.commit,
                "source_equality_sha256": source_equality_sha256,
                "source_tree": authority.candidate.source.tree,
                "transaction_id": transaction_id,
                "transaction_nonce": transaction_nonce,
            }
        )
    )


def _write_pending_payload(path: Path, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise InstallationError(f"cannot create pending transaction state: {error}") from error
    try:
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise OSError("pending transaction state write made no progress")
            offset += written
    except OSError as error:
        raise InstallationError(f"cannot write pending transaction state: {error}") from error
    finally:
        os.close(descriptor)


def _pending_write(
    root: Path,
    state: Mapping[str, object],
    *,
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> None:
    payload = canonical_bytes(state)
    if len(payload) > MAX_PENDING_TRANSACTION_BYTES:
        raise InstallationError("pending transaction state exceeds its size bound")
    path = _pending_state_path(root)
    temporary = root / f".transaction.initial-{os.getpid()}-{secrets.token_hex(8)}"
    try:
        _write_pending_payload(temporary, payload)
        sync_regular_file(temporary)
        atomic_rename(temporary, path, RENAME_EXCL)
        sync_regular_file(path)
        sync_directory(root)
        sync_directory(root.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise InstallationError(
                f"cannot clean unpublished pending state: {error}"
            ) from error


def _initialization_authority_path(root: Path) -> Path:
    return root / INITIALIZATION_AUTHORITY_NAME


def _initialization_authority_document(
    *,
    root: Path,
    authority: SourceAuthority,
    artifact_root: Path,
    artifact_root_identity: Mapping[str, object],
    installed_app: Path,
    source_app: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    predecessor: ExactBundleSnapshot | None,
) -> dict[str, object]:
    predecessor_identity = (
        _snapshot_record(predecessor) if predecessor is not None else None
    )
    return {
        "schema_version": INITIALIZATION_AUTHORITY_SCHEMA_VERSION,
        "initialization_kind": INITIALIZATION_AUTHORITY_KIND,
        "pending_root": str(root),
        "candidate_identity_sha256": authority.candidate_identity_sha256,
        "candidate_file_sha256": authority.candidate_file_sha256,
        "artifact_root": str(artifact_root),
        "artifact_root_identity": artifact_root_identity,
        "qualification_run_id": qualification_run.run_id,
        "qualification_run_nonce": qualification_run.nonce,
        "predecessor_observations_sha256": predecessor_observations_sha256,
        "source_app_path": str(source_app),
        "installed_app_path": str(installed_app),
        "predecessor_present": predecessor is not None,
        "predecessor_identity": predecessor_identity,
        "predecessor_digest": _predecessor_digest(
            predecessor is not None, predecessor_identity
        ),
        "source_commit": authority.candidate.source.commit,
        "source_tree": authority.candidate.source.tree,
        "application_executable_sha256": authority.executable_sha256,
        "build_provenance_sha256": authority.build_provenance_sha256,
    }


def _initialization_authority_from_state(
    root: Path, state: Mapping[str, object]
) -> dict[str, object]:
    return {
        "schema_version": INITIALIZATION_AUTHORITY_SCHEMA_VERSION,
        "initialization_kind": INITIALIZATION_AUTHORITY_KIND,
        "pending_root": str(root),
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "artifact_root": state["artifact_root"],
        "artifact_root_identity": state["artifact_root_identity"],
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "source_app_path": state["source_app_path"],
        "installed_app_path": state["installed_app_path"],
        "predecessor_present": state["predecessor_present"],
        "predecessor_identity": state["predecessor_identity"],
        "predecessor_digest": state["predecessor_digest"],
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "execution_identity_sha256": state["execution_identity_sha256"],
        "application_executable_sha256": state[
            "application_executable_sha256"
        ],
        "build_provenance_sha256": state["build_provenance_sha256"],
    }


def _read_initialization_authority(
    root: Path, expected: Mapping[str, object]
) -> StableFile:
    snapshot = _stable_file(
        _initialization_authority_path(root),
        maximum_bytes=MAX_INITIALIZATION_AUTHORITY_BYTES,
    )
    if snapshot.metadata[2] != 0o600:
        raise InstallationError("initialization authority mode is not private")
    try:
        document = decode_canonical_bytes(snapshot.payload)
    except CanonicalJSONError as error:
        raise InstallationError(
            f"initialization authority is not canonical JSON: {error}"
        ) from error
    authority = _require_closed_mapping(
        document,
        INITIALIZATION_AUTHORITY_FIELDS,
        label="initialization authority",
    )
    if authority != expected:
        raise InstallationError(
            "initialization authority does not bind the current request"
        )
    return snapshot


def _publish_initialization_authority(
    root: Path,
    document: Mapping[str, object],
    *,
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> StableFile:
    payload = canonical_bytes(document)
    if len(payload) > MAX_INITIALIZATION_AUTHORITY_BYTES:
        raise InstallationError("initialization authority exceeds its size bound")
    path = _initialization_authority_path(root)
    temporary = root / f".initialization.next-{os.getpid()}-{secrets.token_hex(8)}"
    try:
        _write_pending_payload(temporary, payload)
        sync_regular_file(temporary)
        atomic_rename(temporary, path, RENAME_EXCL)
        sync_regular_file(path)
        sync_directory(root)
        sync_directory(root.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise InstallationError(
                f"cannot clean initialization authority temporary: {error}"
            ) from error
    return _read_initialization_authority(root, document)


def _clear_initialization_authority(
    root: Path,
    expected: Mapping[str, object],
    *,
    sync_directory: SyncDirectory,
) -> None:
    snapshot = _read_initialization_authority(root, expected)
    _require_same_file(
        snapshot,
        phase="initialization authority clearance",
        maximum_bytes=MAX_INITIALIZATION_AUTHORITY_BYTES,
    )
    try:
        snapshot.path.unlink()
    except OSError as error:
        raise InstallationError(
            f"cannot clear initialization authority: {error}"
        ) from error
    sync_directory(root)
    sync_directory(root.parent)


def _remove_unpublished_pending_root(
    root: Path,
    *,
    remove_tree: RemoveTree,
    sync_directory: SyncDirectory,
) -> None:
    metadata = _directory_anchor(root, label="unpublished pending transaction root")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise InstallationError("unpublished pending transaction root mode is not private")
    if _path_exists(_pending_state_path(root)):
        raise InstallationError("refusing to remove published pending transaction state")
    try:
        entries = tuple(root.iterdir())
    except OSError as error:
        raise InstallationError(
            f"cannot inspect unpublished pending transaction root: {error}"
        ) from error
    for entry in entries:
        try:
            entry_metadata = entry.lstat()
        except OSError as error:
            raise InstallationError(
                f"cannot inspect unpublished transaction entry: {error}"
            ) from error
        if entry.name == "predecessor":
            if not stat.S_ISDIR(entry_metadata.st_mode) or stat.S_ISLNK(
                entry_metadata.st_mode
            ):
                raise InstallationError("unpublished predecessor stage is unsafe")
        elif entry.name.startswith(".transaction.initial-"):
            if (
                not stat.S_ISREG(entry_metadata.st_mode)
                or stat.S_ISLNK(entry_metadata.st_mode)
                or entry_metadata.st_nlink != 1
            ):
                raise InstallationError("unpublished transaction state is unsafe")
        elif entry.name == INITIALIZATION_AUTHORITY_NAME or entry.name.startswith(
            ".initialization.next-"
        ):
            if (
                not stat.S_ISREG(entry_metadata.st_mode)
                or stat.S_ISLNK(entry_metadata.st_mode)
                or entry_metadata.st_nlink != 1
            ):
                raise InstallationError("initialization authority entry is unsafe")
        else:
            raise InstallationError(
                "unpublished pending root contains an unexpected entry"
            )
    remove_tree(root)
    sync_directory(root.parent)


def _pending_replace(
    root: Path,
    state: Mapping[str, object],
    *,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> None:
    payload = canonical_bytes(state)
    if len(payload) > MAX_PENDING_TRANSACTION_BYTES:
        raise InstallationError("pending transaction state exceeds its size bound")
    path = _pending_state_path(root)
    temporary = root / f".transaction.next-{os.getpid()}-{secrets.token_hex(8)}"
    try:
        _write_pending_payload(temporary, payload)
        sync_regular_file(temporary)
        os.replace(temporary, path)
        sync_regular_file(path)
        sync_directory(root)
        sync_directory(root.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise InstallationError(
                f"cannot clean pending transaction state replacement: {error}"
            ) from error


def _pending_read_stable(root: Path) -> tuple[dict[str, object], StableFile]:
    metadata = _directory_anchor(root, label="pending transaction root")
    if stat.S_IMODE(metadata.st_mode) != 0o700:
        raise InstallationError("pending transaction root mode is not private")
    try:
        snapshot = _stable_file(
            _pending_state_path(root), maximum_bytes=MAX_PENDING_TRANSACTION_BYTES
        )
    except InstallationError as error:
        raise InstallationError(
            f"pending transaction state is unreadable: {error}"
        ) from error
    if snapshot.metadata[2] != 0o600:
        raise InstallationError("pending transaction state mode is not private")
    try:
        document = decode_canonical_bytes(snapshot.payload)
    except CanonicalJSONError as error:
        raise InstallationError(f"pending transaction state is unreadable: {error}") from error
    if not isinstance(document, dict):
        raise InstallationError("pending transaction state is not an object")
    return document, snapshot


def _pending_token(candidate: CandidateIdentity) -> str:
    return candidate_identity_sha256(candidate)


def _pending_validate_state(
    state: Mapping[str, object],
    *,
    authority: SourceAuthority | None,
    token: str,
    installed_app: Path,
    source_app: Path,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    allowed_phases: frozenset[str] = frozenset({"pending"}),
    validate_current_artifact_root: bool = True,
) -> Path:
    if set(state) != PENDING_TRANSACTION_FIELDS:
        raise InstallationError("pending transaction state does not have the exact schema")
    if state.get("schema_version") != PENDING_TRANSACTION_SCHEMA_VERSION:
        raise InstallationError("pending transaction state has an unsupported schema")
    if state.get("phase") not in allowed_phases:
        raise InstallationError("pending transaction phase is invalid for this operation")
    if not isinstance(state.get("candidate_token"), str) or state.get("candidate_token") != token:
        raise InstallationError("pending transaction belongs to a different candidate")
    if state.get("candidate_identity_sha256") != token or not is_sha256(state.get("candidate_identity_sha256")):
        raise InstallationError("pending transaction has an invalid candidate identity")
    if not is_sha256(state.get("candidate_file_sha256")):
        raise InstallationError("pending transaction candidate file identity is invalid")
    if (
        authority is not None
        and state.get("candidate_file_sha256") != authority.candidate_file_sha256
    ):
        raise InstallationError("pending transaction candidate file identity differs")
    stored_artifact_root = state.get("artifact_root")
    if not isinstance(stored_artifact_root, str):
        raise InstallationError("pending transaction has no artifact root")
    stored_artifact_path = Path(stored_artifact_root)
    if validate_current_artifact_root:
        if _canonical_transaction_artifact_root(stored_artifact_path) != stored_artifact_path:
            raise InstallationError("pending transaction artifact root is not canonical")
    elif (
        not stored_artifact_path.is_absolute()
        or not stored_artifact_path.name
        or stored_artifact_path.name in {".", ".."}
    ):
        raise InstallationError("pending transaction artifact root is not canonical")
    if stored_artifact_root != str(artifact_root):
        raise InstallationError("pending transaction artifact root does not match this request")
    _validate_artifact_root_identity(
        state.get("artifact_root_identity"),
        artifact_root,
        require_root=False,
        validate_current=validate_current_artifact_root,
    )
    stored_run_id = state.get("qualification_run_id")
    stored_nonce = state.get("qualification_run_nonce")
    if not isinstance(stored_run_id, str) or STABLE_ID_RE.fullmatch(stored_run_id) is None:
        raise InstallationError("pending transaction has an invalid qualification run ID")
    if not isinstance(stored_nonce, str) or not is_sha256(stored_nonce):
        raise InstallationError("pending transaction has an invalid qualification run nonce")
    if stored_run_id != qualification_run.run_id or stored_nonce != qualification_run.nonce:
        raise InstallationError("pending transaction qualification authority does not match this request")
    stored_predecessor_observations = state.get("predecessor_observations_sha256")
    if not isinstance(stored_predecessor_observations, str) or not is_sha256(stored_predecessor_observations):
        raise InstallationError("pending transaction has an invalid predecessor observations digest")
    if stored_predecessor_observations != predecessor_observations_sha256:
        raise InstallationError("pending transaction predecessor observations do not match this request")
    if state.get("installed_app_path") != str(installed_app) or state.get("source_app_path") != str(source_app):
        raise InstallationError("pending transaction paths do not match this request")
    if not is_git_object(state.get("source_commit")) or not is_git_object(
        state.get("source_tree")
    ):
        raise InstallationError("pending transaction source commit/tree is invalid")
    if authority is not None and (
        state.get("source_commit") != authority.candidate.source.commit
        or state.get("source_tree") != authority.candidate.source.tree
    ):
        raise InstallationError("pending transaction source commit/tree differs")
    if not is_sha256(state.get("application_executable_sha256")):
        raise InstallationError("pending transaction app executable digest is invalid")
    if (
        authority is not None
        and state.get("application_executable_sha256") != authority.executable_sha256
    ):
        raise InstallationError("pending transaction app executable digest differs")
    if not is_sha256(state.get("build_provenance_sha256")):
        raise InstallationError("pending transaction build-provenance digest is invalid")
    if (
        authority is not None
        and state.get("build_provenance_sha256") != authority.build_provenance_sha256
    ):
        raise InstallationError("pending transaction build-provenance digest differs")
    if not is_sha256(state.get("source_equality_sha256")):
        raise InstallationError("pending transaction source-equality identity is invalid")
    if not is_sha256(state.get("execution_identity_sha256")):
        raise InstallationError("pending transaction execution identity is invalid")

    began_at = state.get("began_at_unix_ns")
    exposed_at = state.get("exposed_at_unix_ns")
    if not _nonnegative_integer(began_at) or began_at == 0:
        raise InstallationError("pending transaction begin timestamp is invalid")
    if not _nonnegative_integer(exposed_at):
        raise InstallationError("pending transaction exposure timestamp is invalid")
    if state.get("phase") == "pending" and exposed_at < began_at:
        raise InstallationError("pending transaction predates its begin authority")
    if state.get("phase") == "prepared" and exposed_at != 0:
        raise InstallationError("prepared transaction has an exposure timestamp")

    transaction_nonce = state.get("transaction_nonce")
    transaction_id = state.get("transaction_id")
    if not is_sha256(transaction_nonce) or not is_sha256(transaction_id):
        raise InstallationError("pending transaction identity is invalid")

    candidate_identity = _validate_snapshot_record(
        state.get("candidate_identity"), label="pending candidate identity"
    )
    if authority is not None and (
        candidate_identity["content_sha256"]
        != authority.candidate.application.bundle_sha256
        or candidate_identity["closed_tree_sha256"]
        != authority.candidate.application.closed_tree_sha256
        or candidate_identity["root_mode"] != authority.candidate.application.root_mode
    ):
        raise InstallationError("pending candidate tree identity differs")
    destination = _validate_destination_identity(
        state.get("destination_identity"), installed_app
    )
    candidate_directory = candidate_identity["directory_identity"]
    if (
        destination["application_device"],
        destination["application_inode"],
        destination["application_mtime_ns"],
    ) != tuple(candidate_directory[:3]) or (
        destination["content_sha256"],
        destination["closed_tree_sha256"],
        destination["root_mode"],
    ) != (
        candidate_identity["content_sha256"],
        candidate_identity["closed_tree_sha256"],
        candidate_identity["root_mode"],
    ):
        raise InstallationError("pending destination does not bind the staged candidate")
    expected_transaction_id = _transaction_id(
        token=token,
        transaction_nonce=transaction_nonce,
        artifact_root=artifact_root,
        qualification_run=qualification_run,
        destination_identity=destination,
    )
    if transaction_id != expected_transaction_id:
        raise InstallationError("pending transaction ID is not canonical")
    if authority is not None:
        expected_execution_identity = _execution_identity_sha256(
            authority=authority,
            token=token,
            transaction_id=transaction_id,
            transaction_nonce=transaction_nonce,
            qualification_run=qualification_run,
            destination_identity=destination,
            source_equality_sha256=state["source_equality_sha256"],
        )
        if state["execution_identity_sha256"] != expected_execution_identity:
            raise InstallationError(
                "pending transaction execution identity is not canonical"
            )

    expected_receipt = _acceptance_receipt_path(artifact_root)
    if state.get("acceptance_receipt_path") != str(expected_receipt):
        raise InstallationError("pending transaction acceptance receipt path differs")
    predecessor_path = state.get("predecessor_path")
    if not isinstance(predecessor_path, str):
        raise InstallationError("pending transaction has no predecessor path")
    path = Path(predecessor_path)
    if (
        path.parent.parent != installed_app.parent
        or path.parent.name != f".MacScope.pending-{token}"
        or path.name != "predecessor"
    ):
        raise InstallationError("pending predecessor path is outside the installation boundary")
    predecessor_present = state.get("predecessor_present")
    if not isinstance(predecessor_present, bool):
        raise InstallationError("pending predecessor presence is invalid")
    predecessor_identity = state.get("predecessor_identity")
    if predecessor_present:
        _validate_snapshot_record(
            predecessor_identity, label="pending predecessor identity"
        )
    elif predecessor_identity is not None:
        raise InstallationError("absent pending predecessor has an identity")
    expected_predecessor_digest = _predecessor_digest(
        predecessor_present, predecessor_identity
    )
    if (
        state.get("predecessor_digest") != expected_predecessor_digest
        or not is_sha256(state.get("predecessor_digest"))
    ):
        raise InstallationError("pending predecessor digest is invalid")
    return path


def _parse_acceptance_gate_input_arguments(
    arguments: tuple[str, ...],
) -> tuple[tuple[str, Path], ...]:
    parsed: list[tuple[str, Path]] = []
    seen: set[str] = set()
    for argument in arguments:
        gate_id, separator, raw_path = argument.partition("=")
        if not separator or not gate_id or not raw_path:
            raise InstallationError(
                "acceptance gate inputs must use GATE_ID=/absolute/report.json"
            )
        if gate_id in seen:
            raise InstallationError(f"duplicate acceptance gate input: {gate_id}")
        seen.add(gate_id)
        parsed.append((gate_id, Path(raw_path)))
    if tuple(sorted(seen)) != REQUIRED_ACCEPTANCE_GATES:
        raise InstallationError(
            "commit requires exactly one authoritative input for every required acceptance gate"
        )
    return tuple(parsed)


def _acceptance_gate_records(
    *,
    state: Mapping[str, object],
    gate_arguments: tuple[str, ...],
) -> tuple[dict[str, dict[str, object]], int]:
    inputs = _parse_acceptance_gate_input_arguments(gate_arguments)
    destination_identity_sha256 = _sha256_payload(
        canonical_bytes(state["destination_identity"])
    )
    exact_bindings = {
        "application_executable_sha256": state["application_executable_sha256"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity_sha256": destination_identity_sha256,
        "execution_identity_sha256": state["execution_identity_sha256"],
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "rolled_back": False,
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
        "transaction_phase": "pending",
    }
    records: dict[str, dict[str, object]] = {}
    physical_files: set[tuple[int, int]] = set()
    latest_end = int(state["exposed_at_unix_ns"])
    for gate_id, requested_path in inputs:
        if gate_id not in REQUIRED_ACCEPTANCE_GATES:
            raise InstallationError(f"unknown acceptance gate input: {gate_id}")
        path = _canonical_existing(
            requested_path,
            directory=False,
            label=f"acceptance gate input {gate_id}",
        )
        snapshot = _stable_file(
            path, maximum_bytes=MAX_ACCEPTANCE_GATE_INPUT_BYTES
        )
        physical_identity = snapshot.metadata[:2]
        if physical_identity in physical_files:
            raise InstallationError("acceptance gate inputs must be distinct files")
        physical_files.add(physical_identity)
        if snapshot.metadata[5] < state["exposed_at_unix_ns"]:
            raise InstallationError(
                f"acceptance gate input {gate_id} predates candidate exposure"
            )
        try:
            document = decode_canonical_bytes(snapshot.payload)
        except CanonicalJSONError as error:
            raise InstallationError(
                f"acceptance gate input {gate_id} is not canonical JSON: {error}"
            ) from error
        gate = _require_closed_mapping(
            document,
            ACCEPTANCE_GATE_INPUT_FIELDS,
            label=f"acceptance gate input {gate_id}",
        )
        if (
            gate.get("schema_version") != ACCEPTANCE_GATE_INPUT_SCHEMA_VERSION
            or gate.get("input_kind") != ACCEPTANCE_GATE_INPUT_KIND
            or gate.get("gate_id") != gate_id
        ):
            raise InstallationError(
                f"acceptance gate input {gate_id} schema or gate identity differs"
            )
        if (
            gate.get("transaction_phase") != "pending"
            or gate.get("rolled_back") is not False
        ):
            raise InstallationError(
                f"acceptance gate input {gate_id} is rolled back or not pending"
            )
        for field, expected in exact_bindings.items():
            if gate.get(field) != expected:
                raise InstallationError(
                    f"acceptance gate input {gate_id} {field} differs from the pending transaction"
                )
        if (
            gate.get("result") != "passed"
            or not is_sha256(gate.get("evidence_sha256"))
        ):
            raise InstallationError(f"acceptance gate {gate_id} is not passing")
        started_at = gate.get("started_at_unix_ns")
        ended_at = gate.get("ended_at_unix_ns")
        if (
            not _nonnegative_integer(started_at)
            or not _nonnegative_integer(ended_at)
            or started_at < state["exposed_at_unix_ns"]
            or ended_at < started_at
        ):
            raise InstallationError(f"acceptance gate {gate_id} predates installation")
        latest_end = max(latest_end, ended_at)
        records[gate_id] = {
            "started_at_unix_ns": started_at,
            "ended_at_unix_ns": ended_at,
            "result": gate["result"],
            "evidence_sha256": gate["evidence_sha256"],
            "input_sha256": _sha256_payload(snapshot.payload),
        }
    return {gate_id: records[gate_id] for gate_id in REQUIRED_ACCEPTANCE_GATES}, latest_end


def _acceptance_receipt_document(
    *,
    state: Mapping[str, object],
    state_file: StableFile,
    gates: Mapping[str, object],
    produced_at_unix_ns: int,
) -> dict[str, object]:
    return {
        "schema_version": ACCEPTANCE_RECEIPT_SCHEMA_VERSION,
        "receipt_kind": ACCEPTANCE_RECEIPT_KIND,
        "result": "passed",
        "produced_at_unix_ns": produced_at_unix_ns,
        "pending_state_sha256": _sha256_payload(state_file.payload),
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
        "transaction_phase": "pending",
        "rolled_back": False,
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "artifact_root": state["artifact_root"],
        "source_commit": state["source_commit"],
        "source_tree": state["source_tree"],
        "application_executable_sha256": state["application_executable_sha256"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "source_equality_sha256": state["source_equality_sha256"],
        "execution_identity_sha256": state["execution_identity_sha256"],
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "predecessor_digest": state["predecessor_digest"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "destination_identity": state["destination_identity"],
        "gates": gates,
    }


def _assemble_acceptance_receipt(
    *,
    state: Mapping[str, object],
    state_file: StableFile,
    artifact_root: Path,
    gate_arguments: tuple[str, ...],
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
    clock_ns: ClockNS,
) -> None:
    gates, latest_end = _acceptance_gate_records(
        state=state, gate_arguments=gate_arguments
    )
    _validate_artifact_root_identity(
        state["artifact_root_identity"], artifact_root, require_root=False
    )
    try:
        artifact_root.lstat()
    except FileNotFoundError:
        os.mkdir(artifact_root, 0o700)
        sync_directory(artifact_root.parent)
    _directory_anchor(artifact_root, label="acceptance receipt artifact root")
    stale_temporaries = tuple(
        artifact_root.glob(".MacScopeInstaller.acceptance.next-*")
    )
    for stale in stale_temporaries:
        try:
            metadata = stale.lstat()
        except OSError as error:
            raise InstallationError(
                f"cannot inspect stale acceptance receipt temporary: {error}"
            ) from error
        if (
            not stat.S_ISREG(metadata.st_mode)
            or stat.S_ISLNK(metadata.st_mode)
            or metadata.st_nlink != 1
        ):
            raise InstallationError("stale acceptance receipt temporary is unsafe")
        try:
            stale.unlink()
        except OSError as error:
            raise InstallationError(
                f"cannot clear stale acceptance receipt temporary: {error}"
            ) from error
    if stale_temporaries:
        sync_directory(artifact_root)
        sync_directory(artifact_root.parent)
    path = _acceptance_receipt_path(artifact_root)
    if _path_exists(path):
        snapshot = _read_acceptance_receipt_file(path)
        try:
            existing = decode_canonical_bytes(snapshot.payload)
        except CanonicalJSONError as error:
            raise InstallationError(
                f"existing acceptance receipt is not canonical JSON: {error}"
            ) from error
        receipt = _require_closed_mapping(
            existing, ACCEPTANCE_RECEIPT_FIELDS, label="existing acceptance receipt"
        )
        produced_at = receipt.get("produced_at_unix_ns")
        if not _nonnegative_integer(produced_at) or produced_at < latest_end:
            raise InstallationError("existing acceptance receipt predates gate inputs")
        expected = _acceptance_receipt_document(
            state=state,
            state_file=state_file,
            gates=gates,
            produced_at_unix_ns=produced_at,
        )
        if receipt != expected:
            raise InstallationError(
                "existing acceptance receipt differs from authoritative gate inputs"
            )
        sync_regular_file(path)
        sync_directory(artifact_root)
        sync_directory(artifact_root.parent)
        return

    produced_at = max(clock_ns(), latest_end)
    if not _nonnegative_integer(produced_at):
        raise InstallationError("acceptance receipt clock is invalid")
    document = _acceptance_receipt_document(
        state=state,
        state_file=state_file,
        gates=gates,
        produced_at_unix_ns=produced_at,
    )
    payload = canonical_bytes(document)
    if len(payload) > MAX_ACCEPTANCE_RECEIPT_BYTES:
        raise InstallationError("acceptance receipt exceeds its size bound")
    temporary = artifact_root / (
        f".MacScopeInstaller.acceptance.next-{os.getpid()}-{secrets.token_hex(8)}"
    )
    try:
        _write_pending_payload(temporary, payload)
        sync_regular_file(temporary)
        atomic_rename(temporary, path, RENAME_EXCL)
        sync_regular_file(path)
        sync_directory(artifact_root)
        sync_directory(artifact_root.parent)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise InstallationError(
                f"cannot clean acceptance receipt temporary: {error}"
            ) from error


def _read_acceptance_receipt_file(path: Path) -> StableFile:
    return _stable_file(path, maximum_bytes=MAX_ACCEPTANCE_RECEIPT_BYTES)


def _validate_acceptance_receipt(
    *,
    state: Mapping[str, object],
    state_file: StableFile,
    artifact_root: Path,
    reader: Callable[[Path], StableFile],
) -> StableFile:
    _validate_artifact_root_identity(
        state.get("artifact_root_identity"), artifact_root, require_root=True
    )
    path = _acceptance_receipt_path(artifact_root)
    try:
        receipt_file = reader(path)
    except (InstallationError, OSError) as error:
        raise InstallationError(f"acceptance receipt is unreadable: {error}") from error
    if receipt_file.path != path or len(receipt_file.payload) > MAX_ACCEPTANCE_RECEIPT_BYTES:
        raise InstallationError("acceptance receipt reader did not return the bound file")
    if receipt_file.metadata[5] < state["exposed_at_unix_ns"]:
        raise InstallationError("acceptance receipt predates candidate exposure")
    try:
        document = decode_canonical_bytes(receipt_file.payload)
    except CanonicalJSONError as error:
        raise InstallationError(f"acceptance receipt is not canonical JSON: {error}") from error
    receipt = _require_closed_mapping(
        document, ACCEPTANCE_RECEIPT_FIELDS, label="acceptance receipt"
    )
    if (
        receipt.get("schema_version") != ACCEPTANCE_RECEIPT_SCHEMA_VERSION
        or receipt.get("receipt_kind") != ACCEPTANCE_RECEIPT_KIND
    ):
        raise InstallationError("acceptance receipt schema is unsupported")
    if receipt.get("result") != "passed":
        raise InstallationError("acceptance receipt is not passing")
    if receipt.get("transaction_phase") != "pending" or receipt.get("rolled_back") is not False:
        raise InstallationError("acceptance receipt is rolled back or not pending")

    exact_bindings = {
        "application_executable_sha256": state["application_executable_sha256"],
        "artifact_root": state["artifact_root"],
        "build_provenance_sha256": state["build_provenance_sha256"],
        "candidate_file_sha256": state["candidate_file_sha256"],
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity": state["destination_identity"],
        "pending_state_sha256": _sha256_payload(state_file.payload),
        "predecessor_digest": state["predecessor_digest"],
        "predecessor_observations_sha256": state[
            "predecessor_observations_sha256"
        ],
        "qualification_run_id": state["qualification_run_id"],
        "qualification_run_nonce": state["qualification_run_nonce"],
        "source_commit": state["source_commit"],
        "source_equality_sha256": state["source_equality_sha256"],
        "source_tree": state["source_tree"],
        "execution_identity_sha256": state["execution_identity_sha256"],
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
    }
    for field, expected in exact_bindings.items():
        if receipt.get(field) != expected:
            raise InstallationError(
                f"acceptance receipt {field} does not match the pending transaction"
            )

    produced_at = receipt.get("produced_at_unix_ns")
    if not _nonnegative_integer(produced_at) or produced_at < state["exposed_at_unix_ns"]:
        raise InstallationError("acceptance receipt production time predates installation")
    gates = receipt.get("gates")
    if not isinstance(gates, Mapping) or tuple(sorted(gates)) != REQUIRED_ACCEPTANCE_GATES:
        raise InstallationError("acceptance receipt does not contain the exact required gates")
    latest_gate_end = state["exposed_at_unix_ns"]
    for gate_id in REQUIRED_ACCEPTANCE_GATES:
        gate = _require_closed_mapping(
            gates[gate_id], ACCEPTANCE_GATE_FIELDS, label=f"acceptance gate {gate_id}"
        )
        if (
            gate.get("result") != "passed"
            or not is_sha256(gate.get("evidence_sha256"))
            or not is_sha256(gate.get("input_sha256"))
        ):
            raise InstallationError(f"acceptance gate {gate_id} is not passing")
        started_at = gate.get("started_at_unix_ns")
        ended_at = gate.get("ended_at_unix_ns")
        if (
            not _nonnegative_integer(started_at)
            or not _nonnegative_integer(ended_at)
            or started_at < state["exposed_at_unix_ns"]
            or ended_at < started_at
        ):
            raise InstallationError(f"acceptance gate {gate_id} predates installation")
        latest_gate_end = max(latest_gate_end, ended_at)
    if produced_at < latest_gate_end:
        raise InstallationError("acceptance receipt predates its gate evidence")
    return receipt_file


def _commit_authority_path(root: Path) -> Path:
    return root / COMMIT_AUTHORITY_NAME


def _commit_authority_document(
    state: Mapping[str, object],
    state_file: StableFile,
    acceptance_receipt_sha256: str,
) -> dict[str, object]:
    return {
        "schema_version": COMMIT_AUTHORITY_SCHEMA_VERSION,
        "authority_kind": COMMIT_AUTHORITY_KIND,
        "pending_state_sha256": _sha256_payload(state_file.payload),
        "acceptance_receipt_sha256": acceptance_receipt_sha256,
        "transaction_id": state["transaction_id"],
        "transaction_nonce": state["transaction_nonce"],
        "candidate_identity_sha256": state["candidate_identity_sha256"],
        "destination_identity": state["destination_identity"],
    }


def _read_commit_authority(
    root: Path,
    *,
    state: Mapping[str, object],
    state_file: StableFile,
) -> tuple[Mapping[str, object], StableFile]:
    marker_file = _stable_file(
        _commit_authority_path(root), maximum_bytes=MAX_COMMIT_AUTHORITY_BYTES
    )
    if marker_file.metadata[2] != 0o600:
        raise InstallationError("commit authority mode is not private")
    try:
        document = decode_canonical_bytes(marker_file.payload)
    except CanonicalJSONError as error:
        raise InstallationError(f"commit authority is not canonical JSON: {error}") from error
    marker = _require_closed_mapping(
        document, COMMIT_AUTHORITY_FIELDS, label="commit authority"
    )
    if (
        marker.get("schema_version") != COMMIT_AUTHORITY_SCHEMA_VERSION
        or marker.get("authority_kind") != COMMIT_AUTHORITY_KIND
    ):
        raise InstallationError("commit authority schema is unsupported")
    expected = _commit_authority_document(
        state,
        state_file,
        marker.get("acceptance_receipt_sha256")
        if isinstance(marker.get("acceptance_receipt_sha256"), str)
        else "",
    )
    if not is_sha256(marker.get("acceptance_receipt_sha256")) or marker != expected:
        raise InstallationError("commit authority does not bind the pending transaction")
    return marker, marker_file


def _publish_commit_authority(
    root: Path,
    *,
    state: Mapping[str, object],
    state_file: StableFile,
    receipt_file: StableFile,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> StableFile:
    receipt_sha256 = _sha256_payload(receipt_file.payload)
    expected = _commit_authority_document(state, state_file, receipt_sha256)
    path = _commit_authority_path(root)
    if _path_exists(path):
        marker, marker_file = _read_commit_authority(
            root, state=state, state_file=state_file
        )
        if marker != expected:
            raise InstallationError("existing commit authority binds different evidence")
    else:
        payload = canonical_bytes(expected)
        _write_pending_payload(path, payload)
        sync_regular_file(path)
        sync_directory(root)
        sync_directory(root.parent)
        marker_file = _stable_file(path, maximum_bytes=MAX_COMMIT_AUTHORITY_BYTES)
    return marker_file


def _cleanup_committed_predecessor(
    root: Path,
    *,
    state: Mapping[str, object],
    remove_tree: RemoveTree,
    sync_directory: SyncDirectory,
) -> None:
    predecessor = root / "predecessor"
    if not _path_exists(predecessor) or not state["predecessor_present"]:
        return
    try:
        snapshot = _capture_exact_bundle(predecessor)
    except InstallationError:
        return
    if not _snapshot_matches_record(snapshot, state["predecessor_identity"]):
        return
    try:
        remove_tree(predecessor)
        sync_directory(root)
        sync_directory(root.parent)
    except Exception:
        pass


def _capture_optional_bundle(path: Path) -> ExactBundleSnapshot | None:
    if not _path_exists(path):
        return None
    return _capture_exact_bundle(path)


def _resume_prepared_install(
    *,
    root: Path,
    state: Mapping[str, object],
    authority: SourceAuthority,
    source_app: Path,
    installed_app: Path,
    predecessor_path: Path,
    equality_collector: EqualityCollector,
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
    clock_ns: ClockNS,
) -> None:
    predecessor_present = state["predecessor_present"]
    installed = _capture_optional_bundle(installed_app)
    staged = _capture_optional_bundle(predecessor_path)
    candidate_at_destination = (
        installed is not None
        and _snapshot_matches_record(installed, state["candidate_identity"])
    )
    predecessor_at_destination = (
        predecessor_present
        and installed is not None
        and _snapshot_matches_record(installed, state["predecessor_identity"])
    )
    candidate_at_stage = (
        staged is not None
        and _snapshot_matches_record(staged, state["candidate_identity"])
    )
    predecessor_at_stage = (
        predecessor_present
        and staged is not None
        and _snapshot_matches_record(staged, state["predecessor_identity"])
    )

    if predecessor_present:
        if predecessor_at_destination and candidate_at_stage:
            atomic_rename(predecessor_path, installed_app, RENAME_SWAP)
        elif not (candidate_at_destination and predecessor_at_stage):
            raise InstallationError("prepared transaction layout is not exactly recoverable")
    else:
        if installed is None and candidate_at_stage:
            atomic_rename(predecessor_path, installed_app, RENAME_EXCL)
        elif not (candidate_at_destination and staged is None):
            raise InstallationError("prepared absent-destination layout is not exactly recoverable")

    sync_directory(root)
    sync_directory(installed_app.parent)
    installed = _capture_exact_bundle(installed_app)
    if not _snapshot_matches_record(installed, state["candidate_identity"]):
        raise InstallationError("exposed candidate identity differs from prepared state")
    _validate_destination_identity(
        state["destination_identity"], installed_app, snapshot=installed
    )
    if predecessor_present:
        predecessor = _capture_exact_bundle(predecessor_path)
        if not _snapshot_matches_record(predecessor, state["predecessor_identity"]):
            raise InstallationError("exposed predecessor identity differs from prepared state")
    elif _path_exists(predecessor_path):
        raise InstallationError("absent predecessor path became occupied")
    _require_source_unchanged(authority, phase="pending exposure")
    _collect_exact_equality(
        equality_collector,
        source_app,
        installed_app,
        authority,
        phase="installed pending candidate",
    )
    pending = dict(state)
    pending["phase"] = "pending"
    pending["exposed_at_unix_ns"] = max(clock_ns(), state["began_at_unix_ns"])
    _pending_replace(
        root,
        pending,
        sync_regular_file=sync_regular_file,
        sync_directory=sync_directory,
    )


def _begin_pending_install(
    *,
    source_app: Path,
    installed_app: Path,
    candidate: CandidateIdentity,
    authority: SourceAuthority,
    candidate_sha256: str,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    equality_collector: EqualityCollector,
    copy_tree: CopyTree,
    remove_tree: RemoveTree,
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
    transaction_nonce_factory: NonceFactory,
    clock_ns: ClockNS,
) -> str:
    token = _pending_token(candidate)
    root = _pending_root(installed_app, token)
    committing = _committing_root(installed_app, token)
    committed = _committed_roots(installed_app, token)
    if committed:
        raise InstallationError("candidate installation is already durably committed")
    if _path_exists(committing):
        raise InstallationError("candidate installation commit closeout is already in progress")
    if _path_exists(root) and not _path_exists(_pending_state_path(root)):
        predecessor_observation = capture_predecessor_observation(installed_app)
        if predecessor_observation.sha256 != predecessor_observations_sha256:
            raise InstallationError(
                "predecessor observations digest differs from the current "
                "installed destination"
            )
        installed_snapshot = predecessor_observation.snapshot
        initialization_path = _initialization_authority_path(root)
        if _path_exists(initialization_path):
            initialization = _initialization_authority_document(
                root=root,
                authority=authority,
                artifact_root=artifact_root,
                artifact_root_identity=_artifact_root_identity(artifact_root),
                installed_app=installed_app,
                source_app=source_app,
                qualification_run=qualification_run,
                predecessor_observations_sha256=predecessor_observations_sha256,
                predecessor=installed_snapshot,
            )
            _read_initialization_authority(root, initialization)
        else:
            unpublished_stage = root / "predecessor"
            if (
                installed_snapshot is not None
                and _same_digest(installed_snapshot, authority.source_snapshot)
                and installed_snapshot.root_mode == authority.source_snapshot.root_mode
            ) or _path_exists(unpublished_stage):
                raise InstallationError(
                    "pending transaction state is unreadable and no durable "
                    "initialization authority proves the stage is unexposed"
                )
        _remove_unpublished_pending_root(
            root, remove_tree=remove_tree, sync_directory=sync_directory
        )
    if _path_exists(root):
        state, _state_file = _pending_read_stable(root)
        predecessor_path = _pending_validate_state(
            state, authority=authority, token=token, installed_app=installed_app, source_app=source_app,
            artifact_root=artifact_root, qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
            allowed_phases=frozenset({"prepared", "pending"}),
        )
        initialization_path = _initialization_authority_path(root)
        if _path_exists(initialization_path):
            if state["phase"] != "prepared":
                raise InstallationError(
                    "pending transaction retained stale initialization authority"
                )
            initialization = _initialization_authority_from_state(root, state)
            _clear_initialization_authority(
                root, initialization, sync_directory=sync_directory
            )
        if state["phase"] == "prepared":
            _resume_prepared_install(
                root=root,
                state=state,
                authority=authority,
                source_app=source_app,
                installed_app=installed_app,
                predecessor_path=predecessor_path,
                equality_collector=equality_collector,
                atomic_rename=atomic_rename,
                sync_regular_file=sync_regular_file,
                sync_directory=sync_directory,
                clock_ns=clock_ns,
            )
        else:
            installed = _capture_exact_bundle(installed_app)
            if not _snapshot_matches_record(installed, state["candidate_identity"]):
                raise InstallationError("pending installed candidate identity changed")
            _validate_destination_identity(
                state["destination_identity"], installed_app, snapshot=installed
            )
        return "pending"

    artifact_identity = _artifact_root_identity(artifact_root)
    receipt_path = _acceptance_receipt_path(artifact_root)
    if _path_exists(receipt_path):
        raise InstallationError("pre-begin acceptance receipt is not admissible")
    predecessor_observation = capture_predecessor_observation(installed_app)
    if predecessor_observation.sha256 != predecessor_observations_sha256:
        raise InstallationError(
            "predecessor observations digest differs from the current "
            "installed destination"
        )
    predecessor = predecessor_observation.snapshot
    initialization = _initialization_authority_document(
        root=root,
        authority=authority,
        artifact_root=artifact_root,
        artifact_root_identity=artifact_identity,
        installed_app=installed_app,
        source_app=source_app,
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
        predecessor=predecessor,
    )
    stage = root / "predecessor"
    created_root = False
    try:
        os.mkdir(root, 0o700)
        created_root = True
        sync_directory(root.parent)
        other_pending = tuple(installed_app.parent.glob(".MacScope.pending-*"))
        other_committing = tuple(installed_app.parent.glob(".MacScope.committing-*"))
        if any(path != root for path in other_pending) or other_committing:
            raise InstallationError("another candidate-bound installation is already pending")
        _publish_initialization_authority(
            root,
            initialization,
            atomic_rename=atomic_rename,
            sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
        )
        copy_tree(source_app, stage)
        stage_snapshot = _capture_exact_bundle(stage)
        source_snapshot = authority.source_snapshot
        if not _same_digest(stage_snapshot, source_snapshot) or stage_snapshot.root_mode != source_snapshot.root_mode:
            raise InstallationError("pending candidate stage differs from source")
        _fsync_closed_tree(stage, sync_regular_file=sync_regular_file, sync_directory=sync_directory)
        stage_equality = _collect_exact_equality(
            equality_collector,
            source_app,
            stage,
            authority,
            phase="pending candidate",
        )
        source_equality_sha256 = _sha256_payload(canonical_bytes(stage_equality))
        transaction_nonce = transaction_nonce_factory()
        if not isinstance(transaction_nonce, str) or not is_sha256(transaction_nonce):
            raise InstallationError("transaction nonce factory did not issue a lowercase SHA-256")
        predecessor_identity = (
            _snapshot_record(predecessor) if predecessor is not None else None
        )
        destination_identity = _destination_identity(installed_app, stage_snapshot)
        transaction_id = _transaction_id(
            token=token,
            transaction_nonce=transaction_nonce,
            artifact_root=artifact_root,
            qualification_run=qualification_run,
            destination_identity=destination_identity,
        )
        execution_identity_sha256 = _execution_identity_sha256(
            authority=authority,
            token=token,
            transaction_id=transaction_id,
            transaction_nonce=transaction_nonce,
            qualification_run=qualification_run,
            destination_identity=destination_identity,
            source_equality_sha256=source_equality_sha256,
        )
        began_at = clock_ns()
        if not _nonnegative_integer(began_at) or began_at == 0:
            raise InstallationError("transaction clock did not issue a positive timestamp")
        state: dict[str, object] = {
            "schema_version": PENDING_TRANSACTION_SCHEMA_VERSION,
            "phase": "prepared",
            "candidate_token": token,
            "candidate_identity_sha256": candidate_sha256,
            "candidate_file_sha256": authority.candidate_file_sha256,
            "artifact_root": str(artifact_root),
            "artifact_root_identity": artifact_identity,
            "qualification_run_id": qualification_run.run_id,
            "qualification_run_nonce": qualification_run.nonce,
            "predecessor_observations_sha256": predecessor_observations_sha256,
            "source_app_path": str(source_app),
            "installed_app_path": str(installed_app),
            "predecessor_path": str(stage),
            "predecessor_present": predecessor is not None,
            "predecessor_identity": predecessor_identity,
            "predecessor_digest": _predecessor_digest(
                predecessor is not None, predecessor_identity
            ),
            "candidate_identity": _snapshot_record(stage_snapshot),
            "source_commit": authority.candidate.source.commit,
            "source_tree": authority.candidate.source.tree,
            "application_executable_sha256": authority.executable_sha256,
            "build_provenance_sha256": authority.build_provenance_sha256,
            "source_equality_sha256": source_equality_sha256,
            "execution_identity_sha256": execution_identity_sha256,
            "destination_identity": destination_identity,
            "transaction_nonce": transaction_nonce,
            "transaction_id": transaction_id,
            "began_at_unix_ns": began_at,
            "exposed_at_unix_ns": 0,
            "acceptance_receipt_path": str(receipt_path),
        }
        _pending_write(
            root,
            state,
            atomic_rename=atomic_rename,
            sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
        )
        _clear_initialization_authority(
            root, initialization, sync_directory=sync_directory
        )
        _resume_prepared_install(
            root=root,
            state=state,
            authority=authority,
            source_app=source_app,
            installed_app=installed_app,
            predecessor_path=stage,
            equality_collector=equality_collector,
            atomic_rename=atomic_rename,
            sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
            clock_ns=clock_ns,
        )
        return "pending"
    except Exception:
        # Once the durable prepared state exists, retain it and the predecessor
        # verbatim so begin can resume or rollback can close the transaction.
        # Before that authority exists, destination exposure is forbidden and
        # the private partial root can be removed safely.
        if (
            created_root
            and _path_exists(root)
            and not _path_exists(_pending_state_path(root))
        ):
            _remove_unpublished_pending_root(
                root, remove_tree=remove_tree, sync_directory=sync_directory
            )
        raise


def _commit_pending_install(
    *,
    source_app: Path,
    installed_app: Path,
    token: str,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    authority: SourceAuthority | None,
    atomic_rename: AtomicRename,
    remove_tree: RemoveTree,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
    acceptance_receipt_reader: Callable[[Path], StableFile],
    acceptance_gate_arguments: tuple[str, ...],
    clock_ns: ClockNS,
) -> str:
    pending = _pending_root(installed_app, token)
    committing = _committing_root(installed_app, token)
    committed_roots = _committed_roots(installed_app, token)
    roots_present = tuple(
        path
        for path in (pending, committing, *committed_roots)
        if _path_exists(path)
    )
    if not roots_present:
        raise InstallationError("pending transaction state is unavailable")
    if len(roots_present) != 1:
        raise InstallationError("multiple transaction closeout roots coexist")
    root = roots_present[0]
    recovered_terminal = root in committed_roots

    if root == committing:
        if authority is None:
            raise InstallationError(
                "interrupted commit requires current evidence revalidation"
            )
        interrupted_state, interrupted_state_file = _pending_read_stable(
            committing
        )
        _pending_validate_state(
            interrupted_state,
            authority=authority,
            token=token,
            installed_app=installed_app,
            source_app=source_app,
            artifact_root=artifact_root,
            qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
        )
        _read_commit_authority(
            committing,
            state=interrupted_state,
            state_file=interrupted_state_file,
        )
        atomic_rename(committing, pending, RENAME_EXCL)
        sync_directory(pending.parent)
        root = pending

    state, state_file = _pending_read_stable(root)
    if not recovered_terminal and authority is None:
        raise InstallationError("pending commit requires current source authority")
    recorded_predecessor_path = _pending_validate_state(
        state,
        authority=None if recovered_terminal else authority,
        token=token,
        installed_app=installed_app,
        source_app=source_app,
        artifact_root=artifact_root,
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
        validate_current_artifact_root=not recovered_terminal,
    )
    committed = _committed_root(installed_app, token, state["transaction_id"])
    if root in committed_roots and root != committed:
        raise InstallationError("terminal commit root identity is not canonical")
    if recovered_terminal:
        _read_commit_authority(root, state=state, state_file=state_file)
        installed = _capture_exact_bundle(installed_app)
        if not _snapshot_matches_record(installed, state["candidate_identity"]):
            raise InstallationError(
                "committed installed candidate no longer matches its authority"
            )
        _validate_destination_identity(
            state["destination_identity"], installed_app, snapshot=installed
        )
        sync_directory(root.parent)
        _cleanup_committed_predecessor(
            root,
            state=state,
            remove_tree=remove_tree,
            sync_directory=sync_directory,
        )
        return "committed"

    predecessor_path = recorded_predecessor_path
    _assemble_acceptance_receipt(
        state=state,
        state_file=state_file,
        artifact_root=artifact_root,
        gate_arguments=acceptance_gate_arguments,
        atomic_rename=atomic_rename,
        sync_regular_file=sync_regular_file,
        sync_directory=sync_directory,
        clock_ns=clock_ns,
    )
    artifact_metadata = _directory_anchor(
        artifact_root, label="acceptance receipt artifact root"
    )
    artifact_physical_identity = (artifact_metadata.st_dev, artifact_metadata.st_ino)
    receipt_file = _validate_acceptance_receipt(
        state=state,
        state_file=state_file,
        artifact_root=artifact_root,
        reader=acceptance_receipt_reader,
    )
    _require_directory_identity(
        artifact_root,
        artifact_physical_identity,
        label="acceptance receipt artifact root",
    )
    installed = _capture_exact_bundle(installed_app)
    if not _snapshot_matches_record(installed, state["candidate_identity"]):
        raise InstallationError("installed candidate no longer matches pending identity")
    _validate_destination_identity(
        state["destination_identity"], installed_app, snapshot=installed
    )
    predecessor: ExactBundleSnapshot | None = None
    if state["predecessor_present"]:
        predecessor = _capture_exact_bundle(predecessor_path)
        if not _snapshot_matches_record(predecessor, state["predecessor_identity"]):
            raise InstallationError("pending predecessor identity was mutated")
    elif _path_exists(predecessor_path):
        raise InstallationError("absent pending predecessor path is occupied")

    _require_directory_identity(
        artifact_root,
        artifact_physical_identity,
        label="acceptance receipt artifact root",
    )
    sync_regular_file(receipt_file.path)
    sync_directory(artifact_root)
    sync_directory(artifact_root.parent)
    sync_regular_file(state_file.path)
    sync_directory(root)
    sync_directory(root.parent)
    _require_same_file(
        receipt_file,
        phase="installer commit",
        maximum_bytes=MAX_ACCEPTANCE_RECEIPT_BYTES,
    )
    _require_directory_identity(
        artifact_root,
        artifact_physical_identity,
        label="acceptance receipt artifact root",
    )
    _require_same_file(
        state_file,
        phase="installer commit",
        maximum_bytes=MAX_PENDING_TRANSACTION_BYTES,
    )
    installed_after = _capture_exact_bundle(installed_app)
    if (
        not _snapshot_matches_record(installed_after, state["candidate_identity"])
        or not _same_relocated_directory_identity(installed_after, installed)
    ):
        raise InstallationError("installed candidate changed during commit validation")
    _validate_destination_identity(
        state["destination_identity"], installed_app, snapshot=installed_after
    )
    if predecessor is not None:
        predecessor_after = _capture_exact_bundle(predecessor_path)
        if (
            not _snapshot_matches_record(
                predecessor_after, state["predecessor_identity"]
            )
            or not _same_relocated_directory_identity(
                predecessor_after, predecessor
            )
        ):
            raise InstallationError("pending predecessor changed during commit validation")
    _require_directory_identity(
        artifact_root,
        artifact_physical_identity,
        label="acceptance receipt artifact root",
    )
    commit_authority_file = _publish_commit_authority(
        pending,
        state=state,
        state_file=state_file,
        receipt_file=receipt_file,
        sync_regular_file=sync_regular_file,
        sync_directory=sync_directory,
    )
    atomic_rename(pending, committing, RENAME_EXCL)
    try:
        transitioned_state = _stable_file(
            _pending_state_path(committing),
            maximum_bytes=MAX_PENDING_TRANSACTION_BYTES,
        )
        if (
            transitioned_state.metadata != state_file.metadata
            or transitioned_state.payload != state_file.payload
        ):
            raise InstallationError("pending state changed at the commit transition")
        transitioned_commit_authority = _stable_file(
            _commit_authority_path(committing),
            maximum_bytes=MAX_COMMIT_AUTHORITY_BYTES,
        )
        if (
            transitioned_commit_authority.metadata != commit_authority_file.metadata
            or transitioned_commit_authority.payload != commit_authority_file.payload
        ):
            raise InstallationError("commit authority changed at the commit transition")
        _require_same_file(
            receipt_file,
            phase="installer commit transition",
            maximum_bytes=MAX_ACCEPTANCE_RECEIPT_BYTES,
        )
        _require_directory_identity(
            artifact_root,
            artifact_physical_identity,
            label="acceptance receipt artifact root",
        )
        transitioned_installed = _capture_exact_bundle(installed_app)
        if (
            not _snapshot_matches_record(
                transitioned_installed, state["candidate_identity"]
            )
            or not _same_relocated_directory_identity(
                transitioned_installed, installed_after
            )
        ):
            raise InstallationError("installed candidate changed at commit transition")
        _validate_destination_identity(
            state["destination_identity"],
            installed_app,
            snapshot=transitioned_installed,
        )
        transitioned_predecessor_path = committing / recorded_predecessor_path.name
        if predecessor is not None:
            transitioned_predecessor = _capture_exact_bundle(
                transitioned_predecessor_path
            )
            if (
                not _snapshot_matches_record(
                    transitioned_predecessor, state["predecessor_identity"]
                )
                or not _same_relocated_directory_identity(
                    transitioned_predecessor, predecessor
                )
                ):
                raise InstallationError("predecessor changed at commit transition")
        elif _path_exists(transitioned_predecessor_path):
            raise InstallationError("absent predecessor appeared at commit transition")
        _require_same_file(
            receipt_file,
            phase="installer commit point",
            maximum_bytes=MAX_ACCEPTANCE_RECEIPT_BYTES,
        )
        _require_same_file(
            transitioned_state,
            phase="installer commit point",
            maximum_bytes=MAX_PENDING_TRANSACTION_BYTES,
        )
        _require_same_file(
            transitioned_commit_authority,
            phase="installer commit point",
            maximum_bytes=MAX_COMMIT_AUTHORITY_BYTES,
        )
        _require_directory_identity(
            artifact_root,
            artifact_physical_identity,
            label="acceptance receipt artifact root",
        )
        final_installed = _capture_exact_bundle(installed_app)
        if (
            not _snapshot_matches_record(
                final_installed, state["candidate_identity"]
            )
            or not _same_relocated_directory_identity(
                final_installed, transitioned_installed
            )
        ):
            raise InstallationError("installed candidate changed at commit point")
        if predecessor is not None:
            final_predecessor = _capture_exact_bundle(
                transitioned_predecessor_path
            )
            if (
                not _snapshot_matches_record(
                    final_predecessor, state["predecessor_identity"]
                )
                or not _same_relocated_directory_identity(
                    final_predecessor, transitioned_predecessor
                )
            ):
                raise InstallationError("predecessor changed at commit point")
        elif _path_exists(transitioned_predecessor_path):
            raise InstallationError("absent predecessor appeared at commit point")
        sync_directory(committing.parent)
    except Exception:
        if _path_exists(committing) and not _path_exists(pending):
            atomic_rename(committing, pending, RENAME_EXCL)
            sync_directory(pending.parent)
        raise

    # ``.committing`` is durable validated staging, not terminal authority.
    # Only the transaction-qualified ``.committed`` rename and parent barrier
    # cross the commit point.
    try:
        atomic_rename(committing, committed, RENAME_EXCL)
        terminal_state, terminal_state_file = _pending_read_stable(committed)
        if (
            terminal_state_file.metadata != transitioned_state.metadata
            or terminal_state_file.payload != transitioned_state.payload
        ):
            raise InstallationError("terminal commit state changed")
        _terminal_commit_authority, terminal_commit_authority_file = (
            _read_commit_authority(
                committed,
                state=terminal_state,
                state_file=terminal_state_file,
            )
        )
        if (
            terminal_commit_authority_file.metadata
            != transitioned_commit_authority.metadata
            or terminal_commit_authority_file.payload
            != transitioned_commit_authority.payload
        ):
            raise InstallationError("terminal commit authority changed")
        sync_directory(committed.parent)
        _require_same_file(
            receipt_file,
            phase="installer terminal closeout",
            maximum_bytes=MAX_ACCEPTANCE_RECEIPT_BYTES,
        )
        _require_directory_identity(
            artifact_root,
            artifact_physical_identity,
            label="acceptance receipt artifact root",
        )
        terminal_installed = _capture_exact_bundle(installed_app)
        if (
            not _snapshot_matches_record(
                terminal_installed, state["candidate_identity"]
            )
            or not _same_relocated_directory_identity(
                terminal_installed, final_installed
            )
        ):
            raise InstallationError(
                "installed destination changed at terminal closeout"
            )
        _validate_destination_identity(
            state["destination_identity"],
            installed_app,
            snapshot=terminal_installed,
        )
        terminal_predecessor_path = committed / recorded_predecessor_path.name
        if predecessor is not None:
            terminal_predecessor = _capture_exact_bundle(
                terminal_predecessor_path
            )
            if (
                not _snapshot_matches_record(
                    terminal_predecessor, state["predecessor_identity"]
                )
                or not _same_relocated_directory_identity(
                    terminal_predecessor, final_predecessor
                )
            ):
                raise InstallationError(
                    "predecessor changed at terminal closeout"
                )
        elif _path_exists(terminal_predecessor_path):
            raise InstallationError(
                "absent predecessor appeared at terminal closeout"
            )
    except Exception:
        retract = (
            committed
            if _path_exists(committed)
            else committing
            if _path_exists(committing)
            else None
        )
        if retract is not None and not _path_exists(pending):
            atomic_rename(retract, pending, RENAME_EXCL)
            sync_directory(pending.parent)
        raise
    _cleanup_committed_predecessor(
        committed,
        state=state,
        remove_tree=remove_tree,
        sync_directory=sync_directory,
    )
    return "committed"


def _rollback_pending_install(
    *,
    source_app: Path,
    installed_app: Path,
    token: str,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    atomic_rename: AtomicRename,
    remove_tree: RemoveTree,
    sync_directory: SyncDirectory,
) -> str:
    root = _pending_root(installed_app, token)
    committing = _committing_root(installed_app, token)
    committed = _committed_roots(installed_app, token)
    if committed:
        if _path_exists(root) or _path_exists(committing):
            raise InstallationError("active and committed roots coexist")
        raise InstallationError("transaction already crossed the commit point")
    if _path_exists(committing):
        if _path_exists(root):
            raise InstallationError("pending and committing roots coexist")
        interrupted_state, interrupted_state_file = _pending_read_stable(
            committing
        )
        _pending_validate_state(
            interrupted_state,
            authority=None,
            token=token,
            installed_app=installed_app,
            source_app=source_app,
            artifact_root=artifact_root,
            qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
            allowed_phases=frozenset({"pending"}),
            validate_current_artifact_root=False,
        )
        _read_commit_authority(
            committing,
            state=interrupted_state,
            state_file=interrupted_state_file,
        )
        atomic_rename(committing, root, RENAME_EXCL)
        sync_directory(root.parent)
    rolled_matches = tuple(
        sorted(installed_app.parent.glob(f".MacScope.rolled-back-{token}-*"))
    )
    if not _path_exists(root):
        request_matches: list[tuple[Path, Mapping[str, object]]] = []
        for rolled in rolled_matches:
            try:
                rolled_state, _rolled_state_file = _pending_read_stable(rolled)
                _pending_validate_state(
                    rolled_state,
                    authority=None,
                    token=token,
                    installed_app=installed_app,
                    source_app=source_app,
                    artifact_root=artifact_root,
                    qualification_run=qualification_run,
                    predecessor_observations_sha256=predecessor_observations_sha256,
                    allowed_phases=frozenset({"prepared", "pending"}),
                    validate_current_artifact_root=False,
                )
                if rolled != _rolled_back_root(
                    installed_app, token, rolled_state["transaction_id"]
                ):
                    raise InstallationError(
                        "rolled-back transaction root identity is not canonical"
                    )
                if rolled_state["predecessor_present"]:
                    restored = _capture_exact_bundle(installed_app)
                    if not _snapshot_matches_record(
                        restored, rolled_state["predecessor_identity"]
                    ):
                        raise InstallationError(
                            "rolled-back destination no longer matches its predecessor"
                        )
                elif _path_exists(installed_app):
                    raise InstallationError(
                        "rolled-back absent destination is now occupied"
                    )
            except InstallationError:
                continue
            request_matches.append((rolled, rolled_state))
        if len(request_matches) != 1:
            raise InstallationError(
                "pending rollback authority is unavailable or ambiguous"
            )
        sync_directory(installed_app.parent)
        return "rolled-back"
    state, state_file = _pending_read_stable(root)
    predecessor_path = _pending_validate_state(
        state, authority=None, token=token, installed_app=installed_app, source_app=source_app,
        artifact_root=artifact_root, qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
        allowed_phases=frozenset({"prepared", "pending"}),
        validate_current_artifact_root=False,
    )
    _require_same_file(
        state_file,
        phase="installer rollback",
        maximum_bytes=MAX_PENDING_TRANSACTION_BYTES,
    )
    rolled = _rolled_back_root(installed_app, token, state["transaction_id"])
    if _path_exists(rolled):
        raise InstallationError("current and rolled-back transaction roots coexist")
    predecessor_present = state["predecessor_present"]
    try:
        installed = _capture_optional_bundle(installed_app)
    except InstallationError:
        if not _path_exists(installed_app):
            raise
        installed = None
    try:
        staged = _capture_optional_bundle(predecessor_path)
    except InstallationError:
        if not _path_exists(predecessor_path):
            raise
        staged = None
    candidate_at_destination = (
        installed is not None
        and _snapshot_matches_record(installed, state["candidate_identity"])
    )
    candidate_at_stage = (
        staged is not None
        and _snapshot_matches_record(staged, state["candidate_identity"])
    )
    preserve_displaced = False
    if predecessor_present:
        predecessor_at_destination = (
            installed is not None
            and _snapshot_matches_record(installed, state["predecessor_identity"])
        )
        predecessor_at_stage = (
            staged is not None
            and _snapshot_matches_record(staged, state["predecessor_identity"])
        )
        if predecessor_at_destination:
            preserve_displaced = _path_exists(predecessor_path) and not candidate_at_stage
        elif predecessor_at_stage:
            if _path_exists(installed_app):
                atomic_rename(installed_app, predecessor_path, RENAME_SWAP)
                preserve_displaced = not candidate_at_destination
            else:
                atomic_rename(predecessor_path, installed_app, RENAME_EXCL)
            sync_directory(root)
            sync_directory(installed_app.parent)
        else:
            raise InstallationError("rollback layout contains mutated or unrelated bytes")
        restored = _capture_exact_bundle(installed_app)
        if not _snapshot_matches_record(restored, state["predecessor_identity"]):
            raise InstallationError("rollback did not restore the exact predecessor")
        if _path_exists(predecessor_path) and not preserve_displaced:
            try:
                displaced = _capture_exact_bundle(predecessor_path)
            except InstallationError:
                preserve_displaced = True
            else:
                if not _snapshot_matches_record(displaced, state["candidate_identity"]):
                    preserve_displaced = True
    else:
        if not _path_exists(installed_app) and _path_exists(predecessor_path):
            preserve_displaced = not candidate_at_stage
        elif _path_exists(installed_app) and not _path_exists(predecessor_path):
            atomic_rename(installed_app, predecessor_path, RENAME_EXCL)
            preserve_displaced = not candidate_at_destination
            sync_directory(root)
            sync_directory(installed_app.parent)
        else:
            raise InstallationError("absent rollback layout contains mutated or unrelated bytes")
        if _path_exists(installed_app):
            raise InstallationError("rollback did not restore the absent destination")
        if _path_exists(predecessor_path) and not preserve_displaced:
            try:
                displaced = _capture_exact_bundle(predecessor_path)
            except InstallationError:
                preserve_displaced = True
            else:
                if not _snapshot_matches_record(displaced, state["candidate_identity"]):
                    preserve_displaced = True

    _require_same_file(
        state_file,
        phase="installer rollback terminal transition",
        maximum_bytes=MAX_PENDING_TRANSACTION_BYTES,
    )
    if predecessor_present:
        final_restored = _capture_exact_bundle(installed_app)
        if not _snapshot_matches_record(
            final_restored, state["predecessor_identity"]
        ):
            raise InstallationError("rollback predecessor changed before closeout")
    elif _path_exists(installed_app):
        raise InstallationError("rollback absent destination changed before closeout")
    try:
        atomic_rename(root, rolled, RENAME_EXCL)
        sync_directory(rolled.parent)
        terminal_state, terminal_state_file = _pending_read_stable(rolled)
        if (
            terminal_state_file.metadata != state_file.metadata
            or terminal_state_file.payload != state_file.payload
            or terminal_state != state
        ):
            raise InstallationError("rollback state changed at terminal closeout")
        if predecessor_present:
            terminal_restored = _capture_exact_bundle(installed_app)
            if (
                not _snapshot_matches_record(
                    terminal_restored, state["predecessor_identity"]
                )
                or not _same_relocated_directory_identity(
                    terminal_restored, final_restored
                )
            ):
                raise InstallationError(
                    "installed destination changed at terminal closeout"
                )
        elif _path_exists(installed_app):
            raise InstallationError(
                "installed destination changed at terminal closeout"
            )
    except Exception:
        if _path_exists(rolled) and not _path_exists(root):
            atomic_rename(rolled, root, RENAME_EXCL)
            sync_directory(root.parent)
        raise
    if not preserve_displaced:
        displaced_payload = rolled / "predecessor"
        if _path_exists(displaced_payload):
            try:
                final_displaced = _capture_exact_bundle(displaced_payload)
            except InstallationError:
                final_displaced = None
            if final_displaced is not None and _snapshot_matches_record(
                final_displaced, state["candidate_identity"]
            ):
                try:
                    remove_tree(displaced_payload)
                    sync_directory(rolled)
                    sync_directory(rolled.parent)
                except Exception:
                    pass
        else:
            try:
                sync_directory(rolled)
                sync_directory(rolled.parent)
            except Exception:
                pass
    return "rolled-back"


def _run_pending_phase(
    *,
    phase: str,
    candidate_identity: Path,
    source_app: Path,
    installed_app: Path,
    artifact_root: Path,
    qualification_run_id: str,
    qualification_run_nonce: str,
    predecessor_observations_sha256: str,
    copy_tree: CopyTree,
    remove_tree: RemoveTree,
    atomic_rename: AtomicRename,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
    equality_collector: EqualityCollector,
    transaction_token: str | None,
    transaction_nonce_factory: NonceFactory,
    clock_ns: ClockNS,
    acceptance_receipt_reader: Callable[[Path], StableFile],
    acceptance_gate_arguments: tuple[str, ...],
) -> int:
    if not isinstance(qualification_run_id, str) or STABLE_ID_RE.fullmatch(qualification_run_id) is None:
        raise ExecutionReportError("qualification run ID must be an coordinator-issued canonical stable ID")
    if not isinstance(qualification_run_nonce, str) or not is_sha256(qualification_run_nonce):
        raise ExecutionReportError("qualification run nonce must be an coordinator-issued lowercase SHA-256")
    if not isinstance(predecessor_observations_sha256, str) or not is_sha256(predecessor_observations_sha256):
        raise ExecutionReportError("predecessor observations digest must be a lowercase SHA-256")
    qualification_run = QualificationRunAuthority(
        run_id=qualification_run_id, nonce=qualification_run_nonce
    )
    if phase == "commit" and transaction_token is not None:
        if not is_sha256(transaction_token):
            raise InstallationError(
                "commit transaction token must be a lowercase SHA-256"
            )
        terminal_destination = _canonical_destination(installed_app)
        terminal_present = bool(
            _committed_roots(terminal_destination, transaction_token)
        )
        active_present = _path_exists(
            _pending_root(terminal_destination, transaction_token)
        ) or _path_exists(
            _committing_root(terminal_destination, transaction_token)
        )
        if terminal_present and not active_present:
            if not source_app.is_absolute() or source_app.name != "MacScope.app":
                raise InstallationError(
                    "commit source app must be an absolute path named MacScope.app"
                )
            if (
                not artifact_root.is_absolute()
                or not artifact_root.name
                or artifact_root.name in {".", ".."}
            ):
                raise InstallationError(
                    "commit artifact root must be an absolute transaction path"
                )
            result = _commit_pending_install(
                source_app=source_app,
                installed_app=terminal_destination,
                token=transaction_token,
                artifact_root=artifact_root,
                qualification_run=qualification_run,
                predecessor_observations_sha256=predecessor_observations_sha256,
                authority=None,
                atomic_rename=atomic_rename,
                remove_tree=remove_tree,
                sync_regular_file=sync_regular_file,
                sync_directory=sync_directory,
                acceptance_receipt_reader=acceptance_receipt_reader,
                acceptance_gate_arguments=acceptance_gate_arguments,
                clock_ns=clock_ns,
            )
            print(f"MACSCOPE_INSTALL_RELEASE_PHASE={result}")
            print(
                "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN="
                f"{transaction_token}"
            )
            return 0
    if phase == "rollback":
        if acceptance_gate_arguments:
            raise InstallationError(
                "acceptance gate inputs are valid only for commit"
            )
        if transaction_token is None or not is_sha256(transaction_token):
            raise InstallationError(
                "a lowercase SHA-256 transaction token is required for rollback"
            )
        if not source_app.is_absolute() or source_app.name != "MacScope.app":
            raise InstallationError(
                "rollback source app must be an absolute path named MacScope.app"
            )
        installed_app = _canonical_destination_slot(installed_app)
        if (
            not artifact_root.is_absolute()
            or not artifact_root.name
            or artifact_root.name in {".", ".."}
        ):
            raise InstallationError(
                "rollback artifact root must be an absolute transaction path"
            )
        result = _rollback_pending_install(
            source_app=source_app,
            installed_app=installed_app,
            token=transaction_token,
            atomic_rename=atomic_rename,
            artifact_root=artifact_root,
            qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
            remove_tree=remove_tree,
            sync_directory=sync_directory,
        )
        print(f"MACSCOPE_INSTALL_RELEASE_PHASE={result}")
        print(
            "MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN="
            f"{transaction_token}"
        )
        return 0

    candidate_identity = _canonical_existing(candidate_identity, directory=False, label="candidate identity")
    source_app = _canonical_existing(source_app, directory=True, label="source app")
    installed_app = _canonical_destination(installed_app)
    artifact_root = _canonical_transaction_artifact_root(artifact_root)
    if source_app.name != "MacScope.app":
        raise InstallationError("source app must be named MacScope.app")
    if source_app == installed_app:
        raise InstallationError("source app and installed app must be distinct")
    if artifact_root in {source_app, installed_app} or source_app in artifact_root.parents or installed_app in artifact_root.parents:
        raise InstallationError("artifact root must be disjoint from source and installed apps")
    authority = _load_source_authority(candidate_identity, source_app)
    token = authority.candidate_identity_sha256
    if transaction_token is not None and transaction_token != token:
        raise InstallationError("transaction token does not match the candidate identity")
    if phase == "commit" and transaction_token is None:
        raise InstallationError("transaction token is required for closeout")
    if phase == "begin":
        if acceptance_gate_arguments:
            raise InstallationError(
                "acceptance gate inputs are valid only for commit"
            )
        result = _begin_pending_install(
            source_app=source_app, installed_app=installed_app,
            candidate=authority.candidate, authority=authority,
            candidate_sha256=token, equality_collector=equality_collector,
            artifact_root=artifact_root, qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
            copy_tree=copy_tree, remove_tree=remove_tree,
            atomic_rename=atomic_rename, sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
            transaction_nonce_factory=transaction_nonce_factory,
            clock_ns=clock_ns,
        )
    elif phase == "commit":
        result = _commit_pending_install(
            source_app=source_app, installed_app=installed_app,
            token=token,
            artifact_root=artifact_root, qualification_run=qualification_run,
            predecessor_observations_sha256=predecessor_observations_sha256,
            authority=authority, atomic_rename=atomic_rename,
            remove_tree=remove_tree, sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
            acceptance_receipt_reader=acceptance_receipt_reader,
            acceptance_gate_arguments=acceptance_gate_arguments,
            clock_ns=clock_ns,
        )
    else:
        raise InstallationError(f"unsupported installation phase: {phase}")
    print(f"MACSCOPE_INSTALL_RELEASE_PHASE={result}")
    print(f"MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN={token}")
    if result == "pending":
        pending_root = _pending_root(installed_app, token)
        state, state_file = _pending_read_stable(pending_root)
        print(f"MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID={state['transaction_id']}")
        print(f"MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE={state['transaction_nonce']}")
        print(
            "MACSCOPE_INSTALL_RELEASE_PENDING_STATE="
            f"{_pending_state_path(pending_root)}"
        )
        print(
            "MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256="
            f"{_sha256_payload(state_file.payload)}"
        )
        print(
            "MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT="
            f"{state['acceptance_receipt_path']}"
        )
    return 0


def _report_paths(artifact_root: Path) -> dict[str, Path]:
    return {
        "operation": artifact_root / OPERATION_REPORT_NAME,
        "source_equality": artifact_root / SOURCE_EQUALITY_REPORT_NAME,
        "execution": artifact_root / EXECUTION_REPORT_NAME,
    }


def _report_documents(
    *,
    started_at_unix_ms: int,
    ended_at_unix_ms: int,
    result: str,
    exit_code: int,
    candidate_identity_sha256_value: str | None,
    candidate_file_sha256: str | None,
    source_app: Path,
    installed_app: Path,
    source_identity: dict[str, object] | None,
    predecessor_identity: dict[str, object] | None,
    predecessor_present: bool,
    atomic_mode: str | None,
    stage_same_volume: bool,
    stage_equality: dict[str, str | int] | None,
    installed_equality: dict[str, str | int] | None,
    rollback_attempted: bool,
    rollback_succeeded: bool | None,
    point_of_no_return_reached: bool,
    predecessor_clearance_started: bool,
    predecessor_clearance_completed: bool,
    stage_residue_path: str | None,
    diagnostic: str | None,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
) -> dict[str, object]:
    operation = {
        "schema_version": OPERATION_REPORT_SCHEMA_VERSION,
        "report_kind": "release-to-applications-operation",
        "candidate_identity_sha256": candidate_identity_sha256_value,
        "candidate_file_sha256": candidate_file_sha256,
        "source_app_path": str(source_app),
        "installed_app_path": str(installed_app),
        "production_destination": str(PRODUCTION_DESTINATION),
        "source_identity": source_identity,
        "predecessor": {
            "present": predecessor_present,
            "identity": predecessor_identity,
        },
        "staging": {
            "fresh_sibling": stage_same_volume,
            "same_volume": stage_same_volume,
            "source_equality_validated": stage_equality is not None,
        },
        "atomic_replacement": {
            "primitive": "renameatx_np",
            "mode": atomic_mode,
        },
        "rollback": {
            "attempted": rollback_attempted,
            "succeeded": rollback_succeeded,
        },
        "point_of_no_return_reached": point_of_no_return_reached,
        "predecessor_clearance": {
            "started": predecessor_clearance_started,
            "completed": predecessor_clearance_completed,
        },
        "transaction_residue": {
            "present": stage_residue_path is not None,
            "path": stage_residue_path,
        },
        "result": result,
        "diagnostic": diagnostic,
    }
    source_equality = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "report_kind": "installed-source-equality",
        "candidate_identity_sha256": candidate_identity_sha256_value,
        "source_app_path": str(source_app),
        "installed_app_path": str(installed_app),
        "stage_authority": stage_equality,
        "installed_authority": installed_equality,
        "result": result,
        "diagnostic": diagnostic,
    }
    execution = execution_report_document(
        argparse.Namespace(
            started_at_unix_ms=started_at_unix_ms,
            ended_at_unix_ms=ended_at_unix_ms,
            result=result,
            exit_code=exit_code,
        ),
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
    )
    return {
        OPERATION_REPORT_NAME: operation,
        SOURCE_EQUALITY_REPORT_NAME: source_equality,
        EXECUTION_REPORT_NAME: execution,
    }


def _fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(
        os, "O_CLOEXEC", 0
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise InstallationError(f"cannot open directory for durability: {path}: {error}") from error
    try:
        os.fsync(descriptor)
    except OSError as error:
        raise InstallationError(f"cannot durably commit directory: {path}: {error}") from error
    finally:
        os.close(descriptor)


def _fsync_closed_tree(
    root: Path,
    *,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> None:
    """Durably serialize one already-closed tree, children before parents."""

    before = _capture_exact_bundle(root)

    def fail_walk(error: OSError) -> None:
        raise InstallationError(
            f"durability traversal failed at {error.filename}: {error}"
        ) from error

    visited_directories: list[Path] = []
    for current_root, directories, files in os.walk(
        root,
        topdown=False,
        onerror=fail_walk,
        followlinks=False,
    ):
        current = Path(current_root)
        directories.sort()
        files.sort()
        for name in files:
            path = current / name
            metadata = path.lstat()
            if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise InstallationError(
                    f"staged durability tree contains a non-regular file: {path}"
                )
            sync_regular_file(path)
        for name in directories:
            path = current / name
            metadata = path.lstat()
            if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                raise InstallationError(
                    f"staged durability tree contains a non-directory: {path}"
                )
        visited_directories.append(current)
        sync_directory(current)
    if not visited_directories or visited_directories[-1] != root:
        raise InstallationError("staged durability traversal did not commit its root")
    after = _capture_exact_bundle(root)
    if (
        not bundle_snapshots_match(after.tree, before.tree)
        or before.root_mode != after.root_mode
        or not _same_digest(before, after)
    ):
        raise InstallationError("staged bundle changed across durability barriers")


def _publish_report_set(
    *,
    artifact_root: Path,
    documents: Mapping[str, object],
    atomic_rename: AtomicRename,
    report_writer: ReportWriter,
    remove_tree: RemoveTree,
    sync_regular_file: SyncRegularFile,
    sync_directory: SyncDirectory,
) -> dict[str, Path]:
    """Expose all three reports with one exclusive atomic directory rename."""

    expected_names = {
        OPERATION_REPORT_NAME,
        SOURCE_EQUALITY_REPORT_NAME,
        EXECUTION_REPORT_NAME,
    }
    if set(documents) != expected_names:
        raise InstallationError("report transaction does not contain the exact report set")
    report_stage = _fresh_sibling(artifact_root, "report-stage")
    publication_started = False
    try:
        os.mkdir(report_stage, 0o700)
        if report_stage.stat().st_dev != artifact_root.parent.stat().st_dev:
            raise InstallationError("report stage is not on the artifact-root volume")
        for name in sorted(expected_names):
            report_path = report_stage / name
            report_writer(report_path, documents[name])
            sync_regular_file(report_path)
        observed_names = {path.name for path in report_stage.iterdir()}
        if observed_names != expected_names:
            raise InstallationError("staged report directory is not the exact closed report set")
        sync_directory(report_stage)
        # This exclusive directory rename is the visibility commit point.  All
        # three files and their containing directory are already durable; the
        # immediately following parent barrier makes that rename crash-durable.
        atomic_rename(report_stage, artifact_root, RENAME_EXCL)
        publication_started = True
        try:
            sync_directory(artifact_root.parent)
        except Exception as sync_error:
            # A favorable report set is not authoritative until its parent
            # rename is durable.  Retract it immediately on uncertainty, sync
            # that retraction, then clear the hidden transaction directory.
            try:
                atomic_rename(artifact_root, report_stage, RENAME_EXCL)
                sync_directory(artifact_root.parent)
                remove_tree(report_stage)
                sync_directory(artifact_root.parent)
            except Exception as retract_error:
                if _path_exists(artifact_root):
                    try:
                        remove_tree(artifact_root)
                        sync_directory(artifact_root.parent)
                    except Exception as removal_error:
                        raise InstallationError(
                            "report parent durability failed and favorable report "
                            "retraction is uncertain: "
                            f"{sync_error}; retract: {retract_error}; "
                            f"remove: {removal_error}"
                        ) from sync_error
                raise InstallationError(
                    "report parent durability failed; publication was retracted "
                    f"with cleanup uncertainty: {sync_error}; {retract_error}"
                ) from sync_error
            raise InstallationError(
                f"report parent durability failed; publication was retracted: {sync_error}"
            ) from sync_error
    except Exception as error:
        if publication_started:
            # The publication branch above owns retraction.  Never reinterpret
            # an after-rename durability failure as a successful report set.
            raise InstallationError(f"report transaction failed: {error}") from error
        if _path_exists(report_stage):
            try:
                remove_tree(report_stage)
                sync_directory(artifact_root.parent)
            except Exception as cleanup_error:
                raise InstallationError(
                    f"report transaction failed: {error}; hidden report-stage cleanup "
                    f"failed: {cleanup_error}"
                ) from error
        # If the rename call itself was ambiguous, visible files are not a
        # favorable receipt because the artifact-parent durability barrier did
        # not complete.  Retract them rather than inferring success.
        if _path_exists(artifact_root):
            try:
                remove_tree(artifact_root)
                sync_directory(artifact_root.parent)
            except Exception as inspect_error:
                raise InstallationError(
                    f"report publication state is ambiguous and cannot be retracted: {inspect_error}"
                ) from error
        raise InstallationError(f"report transaction failed: {error}") from error
    return _report_paths(artifact_root)


def install_release(
    *,
    candidate_identity: Path,
    source_app: Path,
    installed_app: Path,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    allow_test_destination: bool = False,
    atomic_rename: AtomicRename = _darwin_atomic_rename,
    equality_collector: EqualityCollector = collect_installed_source_equality,
    copy_tree: CopyTree = _default_copy_tree,
    remove_tree: RemoveTree = _remove_tree,
    report_writer: ReportWriter = _write_create_only,
    sync_regular_file: SyncRegularFile = _fsync_regular_file,
    sync_directory: SyncDirectory = _fsync_directory,
) -> tuple[int, dict[str, Path]]:
    """Execute one installation transaction and create its canonical reports."""

    started_at = _unix_ms()
    candidate_identity = _canonical_existing(
        candidate_identity, directory=False, label="candidate identity"
    )
    source_app = _canonical_existing(source_app, directory=True, label="source app")
    installed_app = _canonical_destination(installed_app)
    artifact_root = _canonical_new_root(artifact_root)
    if not allow_test_destination and installed_app != PRODUCTION_DESTINATION:
        raise InstallationError(
            "production installation destination must be exactly "
            f"{PRODUCTION_DESTINATION}"
        )
    if source_app == installed_app:
        raise InstallationError("source app and installed app must be distinct paths")
    if source_app.name != "MacScope.app":
        raise InstallationError("source app must be named MacScope.app")
    if artifact_root == source_app or source_app in artifact_root.parents:
        raise InstallationError("artifact root must not contain the source app")
    if artifact_root == installed_app or installed_app in artifact_root.parents:
        raise InstallationError("artifact root must not contain the installed app")

    source_authority: SourceAuthority | None = None
    predecessor: ExactBundleSnapshot | None = None
    stage: Path | None = None
    stage_snapshot: ExactBundleSnapshot | None = None
    stage_equality: dict[str, str | int] | None = None
    installed_equality: dict[str, str | int] | None = None
    atomic_mode: str | None = None
    stage_same_volume = False
    exposed = False
    point_of_no_return = False
    predecessor_clearance_started = False
    predecessor_clearance_completed = False
    rollback_attempted = False
    rollback_succeeded: bool | None = None
    rollback_diagnostic: str | None = None
    result = "passed"
    exit_code = 0
    diagnostic: str | None = None

    try:
        source_authority = _load_source_authority(candidate_identity, source_app)
        if installed_app.exists():
            predecessor = _capture_exact_bundle(installed_app)

        stage = _fresh_sibling(installed_app, "install-stage")
        _copy_to_fresh_stage(
            source_app,
            installed_app,
            stage,
            copy_tree=copy_tree,
            remove_tree=remove_tree,
            sync_directory=sync_directory,
        )
        stage_same_volume = True
        _require_source_unchanged(source_authority, phase="stage validation")
        _fsync_closed_tree(
            stage,
            sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
        )
        stage_snapshot = _capture_exact_bundle(stage)
        if (
            stage_snapshot.root_mode != source_authority.source_snapshot.root_mode
            or not _same_digest(stage_snapshot, source_authority.source_snapshot)
        ):
            raise InstallationError("staged app physical identity differs from the source")
        stage_equality = _collect_exact_equality(
            equality_collector,
            source_app,
            stage,
            source_authority,
            phase="staged app",
        )
        _require_source_unchanged(source_authority, phase="atomic exposure")
        if predecessor is not None:
            observed_predecessor = _capture_exact_bundle(installed_app)
            if (
                not bundle_snapshots_match(observed_predecessor.tree, predecessor.tree)
                or observed_predecessor.root_mode != predecessor.root_mode
                or not _same_digest(observed_predecessor, predecessor)
            ):
                raise InstallationError("installed predecessor changed before atomic swap")
            atomic_rename(stage, installed_app, RENAME_SWAP)
            atomic_mode = "swap-existing"
        else:
            atomic_rename(stage, installed_app, RENAME_EXCL)
            atomic_mode = "exclusive-absent"
        exposed = True
        sync_directory(installed_app.parent)

        if predecessor is not None:
            displaced_predecessor = _capture_exact_bundle(stage)
            if (
                not _same_relocated_directory_identity(
                    displaced_predecessor, predecessor
                )
                or not _same_digest(displaced_predecessor, predecessor)
            ):
                raise InstallationError(
                    "atomic swap did not preserve the exact predecessor at the stage"
                )
        elif stage.exists() or stage.is_symlink():
            raise InstallationError("exclusive atomic rename left an occupied stage")

        installed_equality = _collect_exact_equality(
            equality_collector,
            source_app,
            installed_app,
            source_authority,
            phase="installed app",
        )
        installed_snapshot = _capture_exact_bundle(installed_app)
        if (
            not _same_relocated_directory_identity(installed_snapshot, stage_snapshot)
            or not _same_digest(installed_snapshot, stage_snapshot)
        ):
            raise InstallationError("installed app changed after equality validation")
        _require_source_unchanged(source_authority, phase="successful completion")

        # From here onward rollback is forbidden.  Predecessor deletion is not
        # atomic and may partially succeed, so attempting a swap after it begins
        # could restore a damaged predecessor.  Report publication is likewise
        # downstream of this boundary.
        point_of_no_return = True
        if predecessor is not None:
            predecessor_clearance_started = True
            remove_tree(stage)
            sync_directory(installed_app.parent)
            predecessor_clearance_completed = not _path_exists(stage)
        else:
            predecessor_clearance_completed = True
        if _path_exists(stage):
            raise InstallationError("successful installation left transaction residue")
    except Exception as error:
        result = "failed"
        exit_code = 1
        primary_diagnostic = _bounded_diagnostic(error)
        if (
            exposed
            and not point_of_no_return
            and stage is not None
            and stage_snapshot is not None
        ):
            rollback_attempted = True
            rollback_succeeded, rollback_diagnostic = _rollback(
                installed=installed_app,
                stage=stage,
                predecessor=predecessor,
                atomic_rename=atomic_rename,
                source_snapshot=stage_snapshot,
                remove_tree=remove_tree,
                sync_directory=sync_directory,
            )
        elif (
            not exposed
            and stage is not None
            and not isinstance(error, StageCopyError)
            and _path_exists(stage)
        ):
            try:
                remove_tree(stage)
                sync_directory(installed_app.parent)
            except Exception as cleanup_error:
                rollback_diagnostic = _bounded_diagnostic(cleanup_error)
        diagnostic = primary_diagnostic
        if rollback_diagnostic is not None:
            diagnostic += f"; rollback/cleanup: {rollback_diagnostic}"

    # Report publication is itself the final point of no return for attempts
    # that failed before exposure.  Nothing below may initiate installation
    # rollback.  The hidden directory is committed as one exclusive rename, so
    # observers can see all three final reports or none of them.
    point_of_no_return = True
    stage_residue_path = (
        str(stage) if stage is not None and _path_exists(stage) else None
    )
    ended_at = _unix_ms()
    documents = _report_documents(
        started_at_unix_ms=started_at,
        ended_at_unix_ms=ended_at,
        result=result,
        exit_code=exit_code,
        candidate_identity_sha256_value=(
            source_authority.candidate_identity_sha256
            if source_authority is not None
            else None
        ),
        candidate_file_sha256=(
            source_authority.candidate_file_sha256
            if source_authority is not None
            else None
        ),
        source_app=source_app,
        installed_app=installed_app,
        source_identity=(
            _identity_mapping(source_authority.source_snapshot)
            if source_authority is not None
            else None
        ),
        predecessor_identity=_identity_mapping(predecessor),
        predecessor_present=predecessor is not None,
        atomic_mode=atomic_mode,
        stage_same_volume=stage_same_volume,
        stage_equality=stage_equality,
        installed_equality=installed_equality,
        rollback_attempted=rollback_attempted,
        rollback_succeeded=rollback_succeeded,
        point_of_no_return_reached=point_of_no_return,
        predecessor_clearance_started=predecessor_clearance_started,
        predecessor_clearance_completed=predecessor_clearance_completed,
        stage_residue_path=stage_residue_path,
        diagnostic=diagnostic,
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
    )
    try:
        report_paths = _publish_report_set(
            artifact_root=artifact_root,
            documents=documents,
            atomic_rename=atomic_rename,
            report_writer=report_writer,
            remove_tree=remove_tree,
            sync_regular_file=sync_regular_file,
            sync_directory=sync_directory,
        )
    except Exception as report_error:
        report_diagnostic = _bounded_diagnostic(report_error)
        print(
            "ERROR: Release installation report transaction failed after the "
            f"point of no return: {report_diagnostic}",
            file=sys.stderr,
        )
        return 1, {}
    if diagnostic is not None:
        print(f"ERROR: Release installation failed: {diagnostic}", file=sys.stderr)
    return exit_code, report_paths


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Atomically install one exact signed Release candidate at "
            "/Applications/MacScope.app."
        )
    )
    parser.add_argument("--phase", choices=("begin", "commit", "rollback"), default=None)
    parser.add_argument("--transaction-token")
    parser.add_argument(
        "--acceptance-gate-input",
        action="append",
        default=[],
        metavar="GATE_ID=/ABSOLUTE/CANONICAL.json",
    )
    parser.add_argument("--candidate-identity", required=True, type=Path)
    parser.add_argument("--source-app", required=True, type=Path)
    parser.add_argument("--installed-app", required=True, type=Path)
    parser.add_argument("--artifact-root", required=True, type=Path)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    return parser


def main(
    argv: list[str] | None = None,
    *,
    _allow_test_destination: bool = False,
    _allow_legacy_one_phase: bool = False,
    _atomic_rename: AtomicRename = _darwin_atomic_rename,
    _equality_collector: EqualityCollector = collect_installed_source_equality,
    _copy_tree: CopyTree = _default_copy_tree,
    _remove_tree_function: RemoveTree = _remove_tree,
    _report_writer: ReportWriter = _write_create_only,
    _sync_regular_file: SyncRegularFile = _fsync_regular_file,
    _sync_directory: SyncDirectory = _fsync_directory,
    _transaction_nonce_factory: NonceFactory = _new_transaction_nonce,
    _clock_ns: ClockNS = time.time_ns,
    _acceptance_receipt_reader: Callable[
        [Path], StableFile
    ] = _read_acceptance_receipt_file,
) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if not _allow_test_destination and Path(arguments.installed_app) != PRODUCTION_DESTINATION:
            raise InstallationError(
                "production installation destination must be exactly "
                f"{PRODUCTION_DESTINATION}"
            )
        if arguments.phase is not None:
            return _run_pending_phase(
                phase=arguments.phase,
                candidate_identity=arguments.candidate_identity,
                source_app=arguments.source_app,
                installed_app=arguments.installed_app,
                artifact_root=arguments.artifact_root,
                qualification_run_id=arguments.qualification_run_id,
                qualification_run_nonce=arguments.qualification_run_nonce,
                predecessor_observations_sha256=arguments.predecessor_observations_sha256,
                copy_tree=_copy_tree,
                remove_tree=_remove_tree_function,
                atomic_rename=_atomic_rename,
                sync_regular_file=_sync_regular_file,
                sync_directory=_sync_directory,
                equality_collector=_equality_collector,
                transaction_token=arguments.transaction_token,
                transaction_nonce_factory=_transaction_nonce_factory,
                clock_ns=_clock_ns,
                acceptance_receipt_reader=_acceptance_receipt_reader,
                acceptance_gate_arguments=tuple(arguments.acceptance_gate_input),
            )
        if not _allow_legacy_one_phase:
            raise InstallationError(
                "production installation requires an explicit begin, commit, or rollback phase"
            )
        run_authority = qualification_run_authority(arguments)
        exit_code, paths = install_release(
            candidate_identity=arguments.candidate_identity,
            source_app=arguments.source_app,
            installed_app=arguments.installed_app,
            artifact_root=arguments.artifact_root,
            qualification_run=run_authority,
            predecessor_observations_sha256=(
                arguments.predecessor_observations_sha256
            ),
            allow_test_destination=_allow_test_destination,
            atomic_rename=_atomic_rename,
            equality_collector=_equality_collector,
            copy_tree=_copy_tree,
            remove_tree=_remove_tree_function,
            report_writer=_report_writer,
            sync_regular_file=_sync_regular_file,
            sync_directory=_sync_directory,
        )
    except (
        InstallationError,
        OSError,
        CanonicalJSONError,
        ExecutionReportError,
    ) as error:
        print(f"ERROR: Release installation refused: {error}", file=sys.stderr)
        return 1
    for key, name in STDOUT_KEYS:
        path = paths.get(
            "operation"
            if name == OPERATION_REPORT_NAME
            else "source_equality"
            if name == SOURCE_EQUALITY_REPORT_NAME
            else "execution"
        )
        if path is not None:
            print(f"{key}={path}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
