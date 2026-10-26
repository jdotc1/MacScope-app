#!/usr/bin/env python3
"""Prove the exact MacScope developer run loop for one final local candidate.

The producer is intentionally narrow.  It rebuilds into a dedicated external
DerivedData root, exercises the real developer entrypoint once, reuses the
existing exact-process helper for nine warm launches, and publishes one
create-only receipt.  It never discovers or signals a process by name.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


SCHEMA_VERSION = 1
RECEIPT_KIND = "macscope-next5-runloop-acceptance"
RESULT = "passed"
ATTEMPT_COUNT = 10
TERMINAL_POLL_ATTEMPTS = 80
TERMINAL_POLL_SECONDS = 0.1
MAX_AUTHORITY_BYTES = 4 * 1024 * 1024
MAX_BUILD_RECEIPT_BYTES = 512 * 1024
MAX_COMMAND_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_PID_BUFFER_BYTES = 1024 * 1024
PROC_ALL_PIDS = 1
PROC_PIDTBSDINFO = 3
PROC_PIDPATHINFO_MAXSIZE = 4 * 1024
MAXCOMLEN = 16
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")
EXPECTED_BUNDLE_IDENTIFIER = "org.macscope.app"
EXPECTED_EXECUTABLE_NAME = "MacScope"
BUILD_SCHEMA = "macscope.developer-run-build.v1"
PROCESS_SCHEMA = "macscope.developer-run-process.v1"
HANDOFF_RECOVERY_NAME = "launch-handoff-recovery.json"
ENTRYPOINT_KEYS = frozenset({"debug", "logs", "run", "stop", "telemetry", "verify"})
TOP_LEVEL_KEYS = frozenset(
    {
        "authority",
        "baseline",
        "cycles",
        "entrypoints",
        "produced_at_unix_ns",
        "receipt_kind",
        "result",
        "schema_version",
        "terminal",
    }
)
PROCESS_RECORD_KEYS = frozenset(
    {
        "executable_path",
        "open_file_count",
        "pid",
        "ppid",
        "start_microseconds",
        "start_seconds",
    }
)
CYCLE_KEYS = frozenset(
    {
        "app_bundle_processes",
        "attempt",
        "coordinator_fd_count_after",
        "coordinator_fd_count_before",
        "coordinator_fd_count_during",
        "descendants",
        "diagnostic_children",
        "launch_route",
        "process_identity",
        "process_receipt_path",
        "process_receipt_sha256",
        "recovery_receipt_absent",
        "stop_route",
        "verify_route",
        "window_count",
    }
)


class AcceptanceError(RuntimeError):
    """The requested evidence could not prove the exact final candidate."""


@dataclass(frozen=True)
class StableFile:
    path: Path
    payload: bytes
    sha256: str
    device: int
    inode: int
    size: int
    mtime_ns: int
    ctime_ns: int
    mode: int


class StableFileFences:
    """Hold admitted authority inodes open through receipt publication."""

    def __init__(self, snapshots: Sequence[tuple[StableFile, str]]) -> None:
        self._snapshots = tuple(snapshots)
        self._descriptors: list[int] = []

    def __enter__(self) -> "StableFileFences":
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        try:
            for snapshot, _label in self._snapshots:
                self._descriptors.append(os.open(snapshot.path, flags))
            self.verify()
        except BaseException:
            self.close()
            raise
        return self

    def verify(self) -> None:
        if len(self._descriptors) != len(self._snapshots):
            raise AcceptanceError("authority inode fence is incomplete")
        fields = (
            "st_dev",
            "st_ino",
            "st_mode",
            "st_nlink",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        for descriptor, (snapshot, label) in zip(self._descriptors, self._snapshots):
            before = os.fstat(descriptor)
            try:
                path_metadata = snapshot.path.lstat()
                resolved = snapshot.path.resolve(strict=True)
            except OSError as error:
                raise AcceptanceError(f"{label} path changed while inode-fenced: {error}") from error
            if resolved != snapshot.path or any(
                getattr(before, field) != getattr(path_metadata, field) for field in fields
            ):
                raise AcceptanceError(f"{label} path no longer names its admitted inode")
            os.lseek(descriptor, 0, os.SEEK_SET)
            payload = bytearray()
            while len(payload) <= snapshot.size:
                block = os.read(descriptor, snapshot.size + 1 - len(payload))
                if not block:
                    break
                payload.extend(block)
            after = os.fstat(descriptor)
            if (
                any(getattr(before, field) != getattr(after, field) for field in fields)
                or bytes(payload) != snapshot.payload
                or _sha256(bytes(payload)) != snapshot.sha256
            ):
                raise AcceptanceError(f"{label} changed while inode-fenced")

    def close(self) -> None:
        while self._descriptors:
            os.close(self._descriptors.pop())

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()


@dataclass(frozen=True, order=True)
class ProcessRecord:
    pid: int
    ppid: int
    start_seconds: int
    start_microseconds: int
    executable_path: str
    open_file_count: int

    @property
    def identity(self) -> tuple[int, int, int, str]:
        return (
            self.pid,
            self.start_seconds,
            self.start_microseconds,
            self.executable_path,
        )

    def mapping(self) -> dict[str, object]:
        return {
            "executable_path": self.executable_path,
            "open_file_count": self.open_file_count,
            "pid": self.pid,
            "ppid": self.ppid,
            "start_microseconds": self.start_microseconds,
            "start_seconds": self.start_seconds,
        }


@dataclass(frozen=True)
class CandidateAuthority:
    candidate_file: StableFile
    qualification_file: StableFile
    final_file: StableFile
    identity_semantic_sha256: str
    repository_label: str
    branch_label: str
    source_commit: str
    source_tree: str
    integration_ref: str
    application_executable_sha256: str
    qualification_source_identity_sha256: str
    final_source_app_path: str
    installed_app_path: str


@dataclass(frozen=True)
class Configuration:
    repository: Path
    entrypoint: Path
    helper: Path
    candidate_identity: Path
    qualification_receipt: Path
    final_receipt: Path
    derived_data: Path
    configuration: str
    output: Path
    command_timeout_seconds: float
    diagnostic_start_seconds: float
    diagnostic_exit_timeout_seconds: float

    @property
    def app_bundle(self) -> Path:
        return (
            self.derived_data
            / "Build"
            / "Products"
            / self.configuration
            / "MacScope.app"
        )

    @property
    def executable(self) -> Path:
        return self.app_bundle / "Contents" / "MacOS" / EXPECTED_EXECUTABLE_NAME

    @property
    def receipt_root(self) -> Path:
        return self.derived_data / "MacScopeRunLoop"

    @property
    def build_receipt(self) -> Path:
        return self.receipt_root / "build-receipt.json"

    @property
    def entrypoint_process_receipt(self) -> Path:
        return self.receipt_root / "process-receipt.json"

    @property
    def recovery_receipt(self) -> Path:
        return self.receipt_root / HANDOFF_RECOVERY_NAME

    def process_receipt(self, attempt: int) -> Path:
        if attempt == 1:
            return self.entrypoint_process_receipt
        return self.receipt_root / f"process-receipt-attempt-{attempt:02d}.json"


@dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: bytes
    stderr: bytes


class ChildProcess(Protocol):
    pid: int

    def poll(self) -> int | None:
        ...

    def wait(self, timeout: float | None = None) -> int:
        ...

    def terminate(self) -> None:
        ...

    def kill(self) -> None:
        ...


class CommandAPI(Protocol):
    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
        input_bytes: bytes | None = None,
        timeout: float,
    ) -> CommandResult:
        ...

    def spawn(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
    ) -> ChildProcess:
        ...


class RuntimeAPI(Protocol):
    def snapshot(self) -> tuple[ProcessRecord, ...]:
        ...

    def coordinator_fd_count(self) -> int:
        ...

    def application_inventory(self) -> list[dict[str, object]]:
        ...

    def sleep(self, seconds: float) -> None:
        ...


class RealCommands:
    def run(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
        input_bytes: bytes | None = None,
        timeout: float,
    ) -> CommandResult:
        try:
            completed = subprocess.run(
                list(argv),
                cwd=cwd,
                env=dict(env),
                input=input_bytes,
                stdin=subprocess.DEVNULL if input_bytes is None else None,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise AcceptanceError(f"command could not complete: {argv[0]}: {error}") from error
        if len(completed.stdout) > MAX_COMMAND_OUTPUT_BYTES or len(
            completed.stderr
        ) > MAX_COMMAND_OUTPUT_BYTES:
            raise AcceptanceError(f"command output exceeds its bound: {argv[0]}")
        return CommandResult(completed.returncode, completed.stdout, completed.stderr)

    def spawn(
        self,
        argv: Sequence[str],
        *,
        cwd: Path,
        env: Mapping[str, str],
    ) -> ChildProcess:
        try:
            return subprocess.Popen(
                list(argv),
                cwd=cwd,
                env=dict(env),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
            )
        except OSError as error:
            raise AcceptanceError(f"diagnostic child could not start: {argv[0]}: {error}") from error


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * MAXCOMLEN),
        ("pbi_name", ctypes.c_char * (2 * MAXCOMLEN)),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class DarwinRuntime:
    def __init__(self, application_inventory: Callable[[], list[dict[str, object]]]):
        if sys.platform != "darwin":
            raise AcceptanceError("runloop acceptance requires macOS")
        try:
            self._library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        except OSError as error:
            raise AcceptanceError(f"libproc is unavailable: {error}") from error
        self._library.proc_listpids.argtypes = (
            ctypes.c_uint32,
            ctypes.c_uint32,
            ctypes.c_void_p,
            ctypes.c_int,
        )
        self._library.proc_listpids.restype = ctypes.c_int
        self._library.proc_pidpath.argtypes = (
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        )
        self._library.proc_pidpath.restype = ctypes.c_int
        self._library.proc_pidinfo.argtypes = (
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        )
        self._library.proc_pidinfo.restype = ctypes.c_int
        self._application_inventory = application_inventory

    def _probe(self, pid: int) -> ProcessRecord | None:
        if pid <= 0:
            return None
        first = _ProcBSDInfo()
        returned = self._library.proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            ctypes.byref(first),
            ctypes.sizeof(first),
        )
        if returned != ctypes.sizeof(first) or first.pbi_pid != pid:
            return None
        path_buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        if self._library.proc_pidpath(pid, path_buffer, len(path_buffer)) <= 0:
            return None
        second = _ProcBSDInfo()
        returned = self._library.proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            ctypes.byref(second),
            ctypes.sizeof(second),
        )
        if returned != ctypes.sizeof(second) or second.pbi_pid != pid:
            return None
        stable = (
            first.pbi_pid,
            first.pbi_ppid,
            first.pbi_start_tvsec,
            first.pbi_start_tvusec,
        ) == (
            second.pbi_pid,
            second.pbi_ppid,
            second.pbi_start_tvsec,
            second.pbi_start_tvusec,
        )
        if not stable:
            return None
        try:
            path = os.path.realpath(path_buffer.value.decode("utf-8"))
        except UnicodeDecodeError:
            return None
        return ProcessRecord(
            pid=pid,
            ppid=int(second.pbi_ppid),
            start_seconds=int(second.pbi_start_tvsec),
            start_microseconds=int(second.pbi_start_tvusec),
            executable_path=path,
            open_file_count=int(second.pbi_nfiles),
        )

    def snapshot(self) -> tuple[ProcessRecord, ...]:
        required = self._library.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
        if required <= 0 or required > MAX_PID_BUFFER_BYTES:
            raise AcceptanceError("libproc returned an unavailable PID catalog")
        capacity = min(MAX_PID_BUFFER_BYTES, required + 16 * 1024)
        count = capacity // ctypes.sizeof(ctypes.c_int)
        values = (ctypes.c_int * count)()
        returned = self._library.proc_listpids(
            PROC_ALL_PIDS, 0, ctypes.byref(values), capacity
        )
        if returned <= 0 or returned >= capacity:
            raise AcceptanceError("libproc could not enumerate a bounded PID catalog")
        records = []
        for pid in sorted(
            {
                int(value)
                for value in values[: returned // ctypes.sizeof(ctypes.c_int)]
                if value > 0
            }
        ):
            record = self._probe(pid)
            if record is not None:
                records.append(record)
        return tuple(records)

    def coordinator_fd_count(self) -> int:
        record = self._probe(os.getpid())
        if record is None:
            raise AcceptanceError("coordinator process identity is unavailable")
        return record.open_file_count

    def application_inventory(self) -> list[dict[str, object]]:
        return self._application_inventory()

    def sleep(self, seconds: float) -> None:
        time.sleep(seconds)


def _canonical_json(value: object) -> bytes:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError, UnicodeEncodeError) as error:
        raise AcceptanceError(f"receipt value is not canonical JSON: {error}") from error


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _stable_file(
    path: Path,
    *,
    label: str,
    maximum_bytes: int,
    required_mode: int | None = None,
) -> StableFile:
    if not path.is_absolute():
        raise AcceptanceError(f"{label} path must be absolute")
    try:
        before = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise AcceptanceError(f"{label} is unavailable: {error}") from error
    if resolved != path or not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
        raise AcceptanceError(f"{label} must be a canonical ordinary file")
    if before.st_nlink != 1 or not 0 < before.st_size <= maximum_bytes:
        raise AcceptanceError(f"{label} is not one bounded single-link file")
    mode = stat.S_IMODE(before.st_mode)
    if required_mode is not None and mode != required_mode:
        raise AcceptanceError(f"{label} must have mode {required_mode:04o}")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        opened = os.fstat(descriptor)
        payload = bytearray()
        while len(payload) <= maximum_bytes:
            block = os.read(descriptor, min(1024 * 1024, maximum_bytes + 1 - len(payload)))
            if not block:
                break
            payload.extend(block)
        after_descriptor = os.fstat(descriptor)
    except OSError as error:
        raise AcceptanceError(f"{label} could not be read safely: {error}") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    after = path.lstat()
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if len(payload) != before.st_size or any(
        getattr(before, field) != getattr(observed, field)
        for observed in (opened, after_descriptor, after)
        for field in fields
    ):
        raise AcceptanceError(f"{label} changed while inspected")
    return StableFile(
        path=path,
        payload=bytes(payload),
        sha256=_sha256(bytes(payload)),
        device=before.st_dev,
        inode=before.st_ino,
        size=before.st_size,
        mtime_ns=before.st_mtime_ns,
        ctime_ns=before.st_ctime_ns,
        mode=mode,
    )


def _revalidate(snapshot: StableFile, *, label: str) -> StableFile:
    try:
        observed = _stable_file(
            snapshot.path,
            label=label,
            maximum_bytes=max(snapshot.size, 1),
            required_mode=snapshot.mode,
        )
    except AcceptanceError as error:
        raise AcceptanceError(f"{label} changed after admission: {error}") from error
    if observed != snapshot:
        raise AcceptanceError(f"{label} changed after admission")
    return observed


def _decode_canonical(snapshot: StableFile, *, label: str, trailing_lf: bool) -> dict[str, Any]:
    payload = snapshot.payload
    encoded = payload[:-1] if trailing_lf and payload.endswith(b"\n") else payload
    if trailing_lf and encoded == payload:
        raise AcceptanceError(f"{label} must end in one LF")
    try:
        value = json.loads(encoded.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcceptanceError(f"{label} is not JSON: {error}") from error
    if not isinstance(value, dict) or _canonical_json(value) != encoded:
        raise AcceptanceError(f"{label} is not canonical JSON")
    return value


def _closed(record: object, keys: frozenset[str], *, label: str) -> Mapping[str, Any]:
    if not isinstance(record, Mapping) or set(record) != keys:
        raise AcceptanceError(f"{label} field set differs")
    return record


def _required_text(record: Mapping[str, Any], key: str, pattern: re.Pattern[str]) -> str:
    value = record.get(key)
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise AcceptanceError(f"authority {key} is invalid")
    return value


def load_candidate_authority(configuration: Configuration) -> CandidateAuthority:
    candidate_file = _stable_file(
        configuration.candidate_identity,
        label="candidate identity",
        maximum_bytes=MAX_AUTHORITY_BYTES,
    )
    qualification_file = _stable_file(
        configuration.qualification_receipt,
        label="qualification receipt",
        maximum_bytes=MAX_AUTHORITY_BYTES,
        required_mode=0o600,
    )
    final_file = _stable_file(
        configuration.final_receipt,
        label="final local candidate receipt",
        maximum_bytes=MAX_AUTHORITY_BYTES,
        required_mode=0o600,
    )
    candidate_document = _decode_canonical(
        candidate_file, label="candidate identity", trailing_lf=False
    )
    qualification_document = _decode_canonical(
        qualification_file, label="qualification receipt", trailing_lf=True
    )
    final_document = _decode_canonical(
        final_file, label="final local candidate receipt", trailing_lf=False
    )

    root = Path(__file__).resolve().parents[1]
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    try:
        from Scripts.reconstruction_gate_f.schema import (  # type: ignore
            candidate_identity_sha256,
            parse_candidate_identity,
        )
    except ImportError as error:
        raise AcceptanceError(f"candidate schema authority is unavailable: {error}") from error
    candidate, issues = parse_candidate_identity(candidate_document)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        raise AcceptanceError(f"candidate identity is invalid: {detail}")

    if (
        qualification_document.get("schema_version") != 4
        or qualification_document.get("mode") != "full-test"
        or qualification_document.get("dependency_network_allowed") is not False
        or qualification_document.get("dependency_network_used") is not False
    ):
        raise AcceptanceError("qualification receipt is not an offline full-test authority")
    qualification_source = qualification_document.get("source_identity")
    if not isinstance(qualification_source, Mapping):
        raise AcceptanceError("qualification source identity is missing")
    qualification_commit = _required_text(
        qualification_source, "canonical_integration_commit", GIT_OBJECT_RE
    )
    qualification_tree = _required_text(qualification_source, "git_head_tree", GIT_OBJECT_RE)
    integration_ref = qualification_source.get("canonical_integration_ref")
    if not isinstance(integration_ref, str) or not integration_ref.startswith("refs/remotes/"):
        raise AcceptanceError("qualification integration ref is invalid")
    if (
        qualification_source.get("git_head_commit") != qualification_commit
        or qualification_commit != candidate.source.commit
        or qualification_tree != candidate.source.tree
    ):
        raise AcceptanceError("candidate and qualification source identities differ")

    final_top = _closed(
        final_document,
        frozenset(
            {
                "acceptance_gates",
                "candidate",
                "installation",
                "integration",
                "produced_at_unix_ns",
                "qualification",
                "receipt_kind",
                "result",
                "schema_version",
                "scope",
                "transaction_result",
            }
        ),
        label="final local candidate receipt",
    )
    if (
        final_top.get("schema_version") != 1
        or final_top.get("receipt_kind") != "macscope-final-local-candidate"
        or final_top.get("result") != "passed"
    ):
        raise AcceptanceError("final local candidate receipt is not passed authority")
    final_candidate = final_top.get("candidate")
    final_integration = final_top.get("integration")
    final_qualification = final_top.get("qualification")
    final_installation = final_top.get("installation")
    if not all(
        isinstance(value, Mapping)
        for value in (final_candidate, final_integration, final_qualification, final_installation)
    ):
        raise AcceptanceError("final local candidate authority is incomplete")
    assert isinstance(final_candidate, Mapping)
    assert isinstance(final_integration, Mapping)
    assert isinstance(final_qualification, Mapping)
    assert isinstance(final_installation, Mapping)
    semantic_sha = candidate_identity_sha256(candidate)
    app_sha = candidate.application.executable_sha256
    if (
        final_candidate.get("identity_path") != str(candidate_file.path)
        or final_candidate.get("identity_file_sha256") != candidate_file.sha256
        or final_candidate.get("identity_sha256") != semantic_sha
        or final_candidate.get("application_executable_sha256") != app_sha
        or final_integration.get("commit") != candidate.source.commit
        or final_integration.get("tree") != candidate.source.tree
        or final_integration.get("ref") != integration_ref
        or final_qualification.get("receipt_path") != str(qualification_file.path)
        or final_qualification.get("receipt_sha256") != qualification_file.sha256
    ):
        raise AcceptanceError("final receipt differs from candidate or qualification authority")
    source_app_path = final_candidate.get("source_app_path")
    installed_app_path = final_installation.get("installed_app_path")
    if (
        not isinstance(source_app_path, str)
        or not source_app_path.startswith("/")
        or not isinstance(installed_app_path, str)
        or not installed_app_path.startswith("/")
    ):
        raise AcceptanceError("final receipt application paths are invalid")
    return CandidateAuthority(
        candidate_file=candidate_file,
        qualification_file=qualification_file,
        final_file=final_file,
        identity_semantic_sha256=semantic_sha,
        repository_label=candidate.source.repository,
        branch_label=candidate.source.branch_label,
        source_commit=candidate.source.commit,
        source_tree=candidate.source.tree,
        integration_ref=integration_ref,
        application_executable_sha256=app_sha,
        qualification_source_identity_sha256=_sha256(_canonical_json(qualification_source)),
        final_source_app_path=source_app_path,
        installed_app_path=installed_app_path,
    )


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first in second.parents or second in first.parents


def validate_configuration(configuration: Configuration, authority: CandidateAuthority) -> None:
    for path, directory, label in (
        (configuration.repository, True, "repository"),
        (configuration.entrypoint, False, "developer entrypoint"),
        (configuration.helper, False, "runloop helper"),
    ):
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise AcceptanceError(f"{label} must be an existing canonical absolute path")
        if directory != path.is_dir():
            raise AcceptanceError(f"{label} has the wrong filesystem kind")
        if not directory and (path.is_symlink() or path.stat().st_mode & 0o111 == 0):
            raise AcceptanceError(f"{label} must be a direct executable file")
    if configuration.entrypoint != configuration.repository / "script/build_and_run.sh":
        raise AcceptanceError("developer entrypoint is not repository-owned")
    if configuration.helper != configuration.repository / "Scripts/runloop_exact_app.py":
        raise AcceptanceError("runloop helper is not repository-owned")
    if configuration.configuration != "Release":
        raise AcceptanceError("runloop acceptance requires a Release rebuild")
    if not configuration.derived_data.is_absolute() or configuration.derived_data.is_symlink():
        raise AcceptanceError("DerivedData must be a direct absolute path")
    derived_real = Path(os.path.realpath(configuration.derived_data))
    protected = (
        configuration.repository,
        authority.candidate_file.path.parent,
        authority.qualification_file.path.parent,
        authority.final_file.path.parent,
        Path(authority.final_source_app_path),
        Path(authority.installed_app_path),
    )
    if derived_real == Path("/") or any(_paths_overlap(derived_real, path) for path in protected):
        raise AcceptanceError("DerivedData must be dedicated, external, and outside all authorities")
    configuration.derived_data.mkdir(mode=0o700, parents=True, exist_ok=True)
    if configuration.derived_data.resolve(strict=True) != configuration.derived_data:
        raise AcceptanceError("DerivedData path is not canonical")
    if not 1 <= configuration.command_timeout_seconds <= 3600:
        raise AcceptanceError("command timeout is outside the safety bound")
    if not 0 < configuration.diagnostic_start_seconds <= 10:
        raise AcceptanceError("diagnostic start interval is outside the safety bound")
    if not 1 <= configuration.diagnostic_exit_timeout_seconds <= 60:
        raise AcceptanceError("diagnostic exit timeout is outside the safety bound")


def _command_text(payload: bytes, *, label: str) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AcceptanceError(f"{label} output is not UTF-8") from error


def _require_success(result: CommandResult, *, label: str) -> CommandResult:
    if result.returncode != 0:
        detail = _command_text(result.stderr[-4096:], label=label).strip()
        raise AcceptanceError(
            f"{label} exited {result.returncode}" + (f": {detail}" if detail else "")
        )
    return result


def _environment(configuration: Configuration) -> dict[str, str]:
    environment = os.environ.copy()
    environment.update(
        {
            "MACSCOPE_CONFIGURATION": configuration.configuration,
            "MACSCOPE_DERIVED_DATA": str(configuration.derived_data),
        }
    )
    return environment


def _entrypoint_argv(configuration: Configuration, mode: str) -> tuple[str, ...]:
    return ("/bin/bash", str(configuration.entrypoint), mode)


def _helper_argv(
    configuration: Configuration, mode: str, process_receipt: Path | None = None
) -> tuple[str, ...]:
    argv = ["/usr/bin/python3", "-B", str(configuration.helper), mode]
    if mode != "stop":
        argv.extend(("--build-receipt", str(configuration.build_receipt)))
    if process_receipt is not None:
        argv.extend(("--process-receipt", str(process_receipt)))
    return tuple(argv)


def _run(
    commands: CommandAPI,
    configuration: Configuration,
    argv: Sequence[str],
    *,
    label: str,
    input_bytes: bytes | None = None,
) -> CommandResult:
    return _require_success(
        commands.run(
            argv,
            cwd=configuration.repository,
            env=_environment(configuration),
            input_bytes=input_bytes,
            timeout=configuration.command_timeout_seconds,
        ),
        label=label,
    )


def _load_build_authority(
    configuration: Configuration,
    authority: CandidateAuthority,
    commands: CommandAPI,
) -> tuple[StableFile, dict[str, Any]]:
    proof = _run(
        commands,
        configuration,
        _helper_argv(configuration, "verify-build"),
        label="exact build verification",
    )
    if _command_text(proof.stdout, label="verify-build").strip() != str(configuration.executable):
        raise AcceptanceError("verify-build returned a different executable")
    snapshot = _stable_file(
        configuration.build_receipt,
        label="runloop build receipt",
        maximum_bytes=MAX_BUILD_RECEIPT_BYTES,
        required_mode=0o600,
    )
    document = _decode_canonical(snapshot, label="runloop build receipt", trailing_lf=True)
    source = document.get("source")
    dependencies = document.get("dependencyContract")
    if not isinstance(source, Mapping) or not isinstance(dependencies, Mapping):
        raise AcceptanceError("runloop build receipt lacks source or dependency authority")
    if (
        document.get("schema") != BUILD_SCHEMA
        or document.get("configuration") != "Release"
        or document.get("repositoryRoot") != str(configuration.repository)
        or document.get("appBundlePath") != str(configuration.app_bundle)
        or document.get("executablePath") != str(configuration.executable)
        or document.get("executableSha256") != authority.application_executable_sha256
        or source.get("head") != authority.source_commit
        or source.get("headTree") != authority.source_tree
        or source.get("dirty") is not False
    ):
        raise AcceptanceError("runloop build differs from final candidate authority")
    for key, value in (
        ("build generation", document.get("buildGeneration")),
        ("source identity", source.get("identitySha256")),
        ("generated project identity", document.get("generatedProjectIdentitySha256")),
        ("dependency identity", dependencies.get("identitySha256")),
    ):
        if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
            if key == "build generation" and isinstance(value, str) and re.fullmatch(r"[0-9a-f]{32}", value):
                continue
            raise AcceptanceError(f"runloop {key} is invalid")
    executable = _stable_file(
        configuration.executable,
        label="rebuilt executable",
        maximum_bytes=512 * 1024 * 1024,
    )
    if executable.sha256 != authority.application_executable_sha256:
        raise AcceptanceError("rebuilt executable digest differs from candidate and final authority")
    return snapshot, document


def _load_process_receipt(path: Path) -> tuple[StableFile, dict[str, Any]]:
    snapshot = _stable_file(
        path,
        label="process receipt",
        maximum_bytes=MAX_BUILD_RECEIPT_BYTES,
        required_mode=0o600,
    )
    document = _decode_canonical(snapshot, label="process receipt", trailing_lf=True)
    if document.get("schema") != PROCESS_SCHEMA:
        raise AcceptanceError("process receipt has the wrong schema")
    return snapshot, document


def _parse_verify_output(result: CommandResult) -> dict[str, Any]:
    text = _command_text(result.stdout, label="verify").strip()
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise AcceptanceError(f"verify output is not JSON: {error}") from error
    expected = {
        "buildGeneration",
        "executablePath",
        "pid",
        "startMicroseconds",
        "startSeconds",
        "windowCount",
    }
    if not isinstance(value, dict) or set(value) != expected:
        raise AcceptanceError("verify output field set differs")
    if (
        type(value.get("pid")) is not int
        or value["pid"] <= 0
        or type(value.get("startSeconds")) is not int
        or type(value.get("startMicroseconds")) is not int
        or type(value.get("windowCount")) is not int
        or value["windowCount"] < 1
        or not isinstance(value.get("executablePath"), str)
        or not isinstance(value.get("buildGeneration"), str)
    ):
        raise AcceptanceError("verify output identity is invalid")
    return value


def _app_inventory_identity(inventory: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    values: list[dict[str, object]] = []
    for item in inventory:
        pid = item.get("pid")
        path = item.get("executablePath")
        if type(pid) is not int or not isinstance(path, str) or not path.startswith("/"):
            raise AcceptanceError("LaunchServices inventory contains an invalid identity")
        values.append({"executable_path": os.path.realpath(path), "pid": pid})
    return sorted(values, key=lambda item: (str(item["executable_path"]), int(item["pid"])))


def _bundle_records(records: Sequence[ProcessRecord], app_bundle: Path) -> tuple[ProcessRecord, ...]:
    prefix = os.path.realpath(app_bundle) + os.sep
    return tuple(
        sorted(record for record in records if record.executable_path.startswith(prefix))
    )


def _descendants(records: Sequence[ProcessRecord], root_pid: int) -> tuple[ProcessRecord, ...]:
    by_parent: dict[int, list[ProcessRecord]] = {}
    for record in records:
        by_parent.setdefault(record.ppid, []).append(record)
    pending = [root_pid]
    observed: dict[tuple[int, int, int, str], ProcessRecord] = {}
    while pending:
        parent = pending.pop()
        for child in by_parent.get(parent, ()):  # pragma: no branch - tiny traversal
            if child.identity in observed:
                continue
            observed[child.identity] = child
            pending.append(child.pid)
    return tuple(sorted(observed.values()))


def _record_for_identity(
    records: Sequence[ProcessRecord], proof: Mapping[str, Any]
) -> ProcessRecord:
    expected = (
        proof["pid"],
        proof["startSeconds"],
        proof["startMicroseconds"],
        os.path.realpath(proof["executablePath"]),
    )
    matches = [record for record in records if record.identity == expected]
    if len(matches) != 1:
        raise AcceptanceError("process catalog does not expose the exact verified app identity")
    return matches[0]


def _require_identities_absent(
    identities: Sequence[ProcessRecord], terminal: Sequence[ProcessRecord]
) -> None:
    live = {record.identity for record in terminal}
    survivors = [record for record in identities if record.identity in live]
    if survivors:
        raise AcceptanceError(
            "captured process identity survived stop: "
            + ", ".join(str(record.pid) for record in survivors)
        )


def _await_terminal_snapshot(
    *,
    runtime: RuntimeAPI,
    captured: Sequence[ProcessRecord],
    app_bundle: Path,
    process_receipt: Path,
    recovery_receipt: Path,
    baseline_ls: list[dict[str, object]],
    baseline_fd: int,
) -> tuple[tuple[ProcessRecord, ...], list[dict[str, object]], int]:
    terminal: tuple[ProcessRecord, ...] = ()
    terminal_ls: list[dict[str, object]] = []
    terminal_fd = -1
    captured_identities = {record.identity for record in captured}
    for attempt in range(TERMINAL_POLL_ATTEMPTS):
        terminal = runtime.snapshot()
        terminal_ls = _app_inventory_identity(runtime.application_inventory())
        terminal_fd = runtime.coordinator_fd_count()
        live_identities = {record.identity for record in terminal}
        complete = (
            captured_identities.isdisjoint(live_identities)
            and not _bundle_records(terminal, app_bundle)
            and not process_receipt.exists()
            and not process_receipt.is_symlink()
            and not recovery_receipt.exists()
            and not recovery_receipt.is_symlink()
            and terminal_ls == baseline_ls
            and terminal_fd == baseline_fd
        )
        if complete:
            return terminal, terminal_ls, terminal_fd
        if attempt + 1 < TERMINAL_POLL_ATTEMPTS:
            runtime.sleep(TERMINAL_POLL_SECONDS)
    return terminal, terminal_ls, terminal_fd


def _wait_diagnostic_child(child: ChildProcess, *, timeout: float, label: str) -> int:
    try:
        returncode = child.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        try:
            child.terminate()
            child.wait(timeout=2.0)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                child.kill()
                child.wait(timeout=2.0)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        raise AcceptanceError(f"directly owned {label} child did not exit after target stop") from error
    if returncode != 0:
        raise AcceptanceError(f"{label} entrypoint exited {returncode}")
    return returncode


def _require_absent(path: Path, *, label: str) -> None:
    if path.exists() or path.is_symlink():
        raise AcceptanceError(f"{label} remains present: {path}")


def _cleanup_receipted_process(
    commands: CommandAPI,
    configuration: Configuration,
    process_receipt: Path,
) -> None:
    if not process_receipt.exists() and not process_receipt.is_symlink():
        return
    result = commands.run(
        _helper_argv(configuration, "stop", process_receipt),
        cwd=configuration.repository,
        env=_environment(configuration),
        timeout=configuration.command_timeout_seconds,
    )
    if result.returncode != 0:
        raise AcceptanceError("receipted cleanup failed; receipt was preserved")


def _positive_integer(value: object) -> bool:
    return type(value) is int and value > 0


def _validate_process_mapping(value: object, *, label: str) -> Mapping[str, Any]:
    record = _closed(value, PROCESS_RECORD_KEYS, label=label)
    if (
        not _positive_integer(record.get("pid"))
        or type(record.get("ppid")) is not int
        or int(record["ppid"]) < 0
        or type(record.get("start_seconds")) is not int
        or int(record["start_seconds"]) < 0
        or type(record.get("start_microseconds")) is not int
        or not 0 <= int(record["start_microseconds"]) < 1_000_000
        or type(record.get("open_file_count")) is not int
        or int(record["open_file_count"]) < 0
        or not isinstance(record.get("executable_path"), str)
        or not str(record["executable_path"]).startswith("/")
    ):
        raise AcceptanceError(f"{label} is not an exact process identity")
    return record


def _validate_process_list(value: object, *, label: str) -> list[Mapping[str, Any]]:
    if not isinstance(value, list):
        raise AcceptanceError(f"{label} must be an array")
    records = [
        _validate_process_mapping(item, label=f"{label}[{index}]")
        for index, item in enumerate(value)
    ]
    identities = {
        (
            record["pid"],
            record["start_seconds"],
            record["start_microseconds"],
            record["executable_path"],
        )
        for record in records
    }
    if len(identities) != len(records):
        raise AcceptanceError(f"{label} contains duplicate process identities")
    return records


def _validate_launchservices_inventory(value: object, *, label: str) -> list[Mapping[str, Any]]:
    if not isinstance(value, list):
        raise AcceptanceError(f"{label} must be an array")
    result = []
    for index, item in enumerate(value):
        record = _closed(
            item,
            frozenset({"executable_path", "pid"}),
            label=f"{label}[{index}]",
        )
        if (
            not _positive_integer(record.get("pid"))
            or not isinstance(record.get("executable_path"), str)
            or not str(record["executable_path"]).startswith("/")
        ):
            raise AcceptanceError(f"{label}[{index}] is invalid")
        result.append(record)
    if len({(item["pid"], item["executable_path"]) for item in result}) != len(result):
        raise AcceptanceError(f"{label} contains duplicate identities")
    return result


def _validate_generated_receipt(document: object) -> None:
    """Validate the closed, pure runloop receipt consumed by Tranche 1."""

    top = _closed(document, TOP_LEVEL_KEYS, label="runloop receipt")
    if (
        top.get("schema_version") != SCHEMA_VERSION
        or top.get("receipt_kind") != RECEIPT_KIND
        or top.get("result") != RESULT
        or not _positive_integer(top.get("produced_at_unix_ns"))
    ):
        raise AcceptanceError("runloop receipt header is invalid")

    authority = _closed(
        top.get("authority"),
        frozenset({"application", "build", "candidate", "final", "qualification"}),
        label="runloop authority",
    )
    application = _closed(
        authority.get("application"),
        frozenset({"bundle_path", "executable_path", "executable_sha256"}),
        label="runloop application authority",
    )
    build = _closed(
        authority.get("build"),
        frozenset(
            {
                "build_generation",
                "dependency_identity_sha256",
                "generated_project_identity_sha256",
                "receipt_path",
                "receipt_sha256",
                "source_identity_sha256",
            }
        ),
        label="runloop build authority",
    )
    candidate = _closed(
        authority.get("candidate"),
        frozenset(
            {
                "application_executable_sha256",
                "identity_file_sha256",
                "identity_path",
                "identity_semantic_sha256",
                "source_commit",
                "source_tree",
            }
        ),
        label="runloop candidate authority",
    )
    final = _closed(
        authority.get("final"),
        frozenset({"receipt_path", "receipt_sha256"}),
        label="runloop final authority",
    )
    qualification = _closed(
        authority.get("qualification"),
        frozenset({"integration_ref", "receipt_path", "receipt_sha256"}),
        label="runloop qualification authority",
    )
    if (
        not isinstance(application.get("bundle_path"), str)
        or not str(application["bundle_path"]).startswith("/")
        or not isinstance(application.get("executable_path"), str)
        or application["executable_path"]
        != str(application["bundle_path"]) + "/Contents/MacOS/MacScope"
        or application.get("executable_sha256")
        != candidate.get("application_executable_sha256")
    ):
        raise AcceptanceError("runloop application authority is incoherent")
    for label, value in (
        ("application executable", application.get("executable_sha256")),
        ("build dependency", build.get("dependency_identity_sha256")),
        ("build project", build.get("generated_project_identity_sha256")),
        ("build receipt", build.get("receipt_sha256")),
        ("build source", build.get("source_identity_sha256")),
        ("candidate file", candidate.get("identity_file_sha256")),
        ("candidate semantic", candidate.get("identity_semantic_sha256")),
        ("final receipt", final.get("receipt_sha256")),
        ("qualification receipt", qualification.get("receipt_sha256")),
    ):
        if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
            raise AcceptanceError(f"runloop {label} digest is invalid")
    if (
        not isinstance(build.get("build_generation"), str)
        or re.fullmatch(r"[0-9a-f]{32}", str(build["build_generation"])) is None
        or not isinstance(candidate.get("source_commit"), str)
        or GIT_OBJECT_RE.fullmatch(str(candidate["source_commit"])) is None
        or not isinstance(candidate.get("source_tree"), str)
        or GIT_OBJECT_RE.fullmatch(str(candidate["source_tree"])) is None
    ):
        raise AcceptanceError("runloop source or build generation is invalid")
    for label, value in (
        ("build receipt", build.get("receipt_path")),
        ("candidate identity", candidate.get("identity_path")),
        ("final receipt", final.get("receipt_path")),
        ("qualification receipt", qualification.get("receipt_path")),
    ):
        if not isinstance(value, str) or not value.startswith("/"):
            raise AcceptanceError(f"runloop {label} path is invalid")
    if (
        not isinstance(qualification.get("integration_ref"), str)
        or not str(qualification["integration_ref"]).startswith("refs/remotes/")
    ):
        raise AcceptanceError("runloop qualification ref is invalid")

    baseline = _closed(
        top.get("baseline"),
        frozenset(
            {"app_bundle_processes", "coordinator_fd_count", "launchservices_inventory"}
        ),
        label="runloop baseline",
    )
    terminal = _closed(
        top.get("terminal"),
        frozenset(
            {
                "app_bundle_processes",
                "coordinator_fd_count",
                "launchservices_inventory",
                "process_receipts_absent",
                "recovery_receipt_absent",
            }
        ),
        label="runloop terminal",
    )
    if baseline.get("app_bundle_processes") != [] or terminal.get("app_bundle_processes") != []:
        raise AcceptanceError("runloop baseline or terminal contains exact-bundle residue")
    if (
        type(baseline.get("coordinator_fd_count")) is not int
        or int(baseline["coordinator_fd_count"]) < 0
        or terminal.get("coordinator_fd_count") != baseline["coordinator_fd_count"]
        or terminal.get("process_receipts_absent") is not True
        or terminal.get("recovery_receipt_absent") is not True
    ):
        raise AcceptanceError("runloop terminal descriptor or receipt cleanup differs")
    baseline_ls = _validate_launchservices_inventory(
        baseline.get("launchservices_inventory"), label="baseline LaunchServices inventory"
    )
    terminal_ls = _validate_launchservices_inventory(
        terminal.get("launchservices_inventory"), label="terminal LaunchServices inventory"
    )
    if baseline_ls != terminal_ls:
        raise AcceptanceError("runloop baseline and terminal inventories differ")

    entrypoints = _closed(top.get("entrypoints"), ENTRYPOINT_KEYS, label="runloop entrypoints")
    for mode in ("run", "stop", "verify"):
        record = _closed(
            entrypoints.get(mode),
            frozenset({"attempt", "passed"}),
            label=f"{mode} entrypoint",
        )
        if record.get("attempt") != 1 or record.get("passed") is not True:
            raise AcceptanceError(f"{mode} entrypoint did not pass attempt one")
    debug = _closed(
        entrypoints.get("debug"),
        frozenset({"executable_path", "passed"}),
        label="debug entrypoint",
    )
    if (
        debug.get("passed") is not True
        or debug.get("executable_path") != application["executable_path"]
    ):
        raise AcceptanceError("debug entrypoint did not bind the exact executable")
    for mode in ("logs", "telemetry"):
        record = _closed(
            entrypoints.get(mode),
            frozenset(
                {
                    "attempt",
                    "child_pid",
                    "descendants",
                    "passed",
                    "process_identity",
                    "returncode",
                }
            ),
            label=f"{mode} entrypoint",
        )
        process = _validate_process_mapping(
            record.get("process_identity"), label=f"{mode} process"
        )
        _validate_process_list(record.get("descendants"), label=f"{mode} descendants")
        if (
            record.get("attempt") != 1
            or record.get("passed") is not True
            or record.get("returncode") != 0
            or record.get("child_pid") != process["pid"]
        ):
            raise AcceptanceError(f"{mode} entrypoint proof is invalid")

    cycles = top.get("cycles")
    if not isinstance(cycles, list) or len(cycles) != ATTEMPT_COUNT:
        raise AcceptanceError("runloop receipt must contain exactly ten cycles")
    identities: set[tuple[object, ...]] = set()
    receipt_paths: set[str] = set()
    for index, value in enumerate(cycles, start=1):
        cycle = _closed(value, CYCLE_KEYS, label=f"runloop cycle {index}")
        if cycle.get("attempt") != index:
            raise AcceptanceError("runloop cycle attempts are not sequential")
        process = _validate_process_mapping(
            cycle.get("process_identity"), label=f"cycle {index} process"
        )
        bundle_processes = _validate_process_list(
            cycle.get("app_bundle_processes"), label=f"cycle {index} bundle processes"
        )
        _validate_process_list(cycle.get("descendants"), label=f"cycle {index} descendants")
        identity = (
            process["pid"],
            process["start_seconds"],
            process["start_microseconds"],
            process["executable_path"],
        )
        if identity in identities or process["executable_path"] != application["executable_path"]:
            raise AcceptanceError("runloop cycles are not ten distinct exact executable identities")
        if process not in bundle_processes:
            raise AcceptanceError("runloop cycle bundle inventory omits the exact app root")
        identities.add(identity)
        process_path = cycle.get("process_receipt_path")
        if (
            not isinstance(process_path, str)
            or not process_path.startswith("/")
            or process_path in receipt_paths
            or not isinstance(cycle.get("process_receipt_sha256"), str)
            or SHA256_RE.fullmatch(str(cycle["process_receipt_sha256"])) is None
        ):
            raise AcceptanceError("runloop cycle process receipt authority is invalid")
        receipt_paths.add(process_path)
        expected_routes = (
            ("entrypoint-run", "entrypoint-verify", "entrypoint-stop")
            if index == 1
            else (
                "runloop-helper-launch",
                "runloop-helper-verify",
                "runloop-helper-stop",
            )
        )
        if (
            (
                cycle.get("launch_route"),
                cycle.get("verify_route"),
                cycle.get("stop_route"),
            )
            != expected_routes
            or cycle.get("recovery_receipt_absent") is not True
            or not _positive_integer(cycle.get("window_count"))
            or cycle.get("coordinator_fd_count_before")
            != baseline["coordinator_fd_count"]
            or cycle.get("coordinator_fd_count_after")
            != baseline["coordinator_fd_count"]
            or type(cycle.get("coordinator_fd_count_during")) is not int
            or int(cycle["coordinator_fd_count_during"]) < 0
        ):
            raise AcceptanceError(f"runloop cycle {index} route or cleanup proof is invalid")
        diagnostics = cycle.get("diagnostic_children")
        if index == 1:
            cycle_diagnostics = _closed(
                diagnostics,
                frozenset({"logs", "telemetry"}),
                label="cycle diagnostics",
            )
            for mode in ("logs", "telemetry"):
                diagnostic = _closed(
                    cycle_diagnostics.get(mode),
                    frozenset(
                        {
                            "child_pid",
                            "descendants",
                            "passed",
                            "process_identity",
                            "returncode",
                        }
                    ),
                    label=f"cycle {mode} diagnostic",
                )
                expected_entrypoint = dict(diagnostic)
                expected_entrypoint["attempt"] = 1
                if expected_entrypoint != entrypoints[mode]:
                    raise AcceptanceError(
                        f"cycle and entrypoint {mode} diagnostics differ"
                    )
        elif diagnostics != {}:
            raise AcceptanceError("warm runloop cycle unexpectedly owns diagnostics")


def _cycle(
    attempt: int,
    *,
    configuration: Configuration,
    authority: CandidateAuthority,
    build_document: Mapping[str, Any] | None,
    commands: CommandAPI,
    runtime: RuntimeAPI,
    baseline_ls: list[dict[str, object]],
) -> tuple[
    dict[str, object],
    dict[str, object],
    StableFile | None,
    Mapping[str, Any],
]:
    process_receipt = configuration.process_receipt(attempt)
    _require_absent(process_receipt, label=f"attempt {attempt} process receipt")
    _require_absent(configuration.recovery_receipt, label="launch recovery receipt")
    before_fd = runtime.coordinator_fd_count()
    diagnostics: dict[str, ChildProcess] = {}
    launch_completed = False
    stopped = False
    entrypoint_updates: dict[str, object] = {}
    cycle_build_snapshot: StableFile | None = None
    try:
        if attempt == 1:
            launch_result = _run(
                commands,
                configuration,
                _entrypoint_argv(configuration, "run"),
                label="Run entrypoint",
            )
            if b"MacScope ready:" not in launch_result.stdout:
                raise AcceptanceError("Run entrypoint did not report first-window readiness")
            launch_route = "entrypoint-run"
            entrypoint_updates["run"] = {"attempt": 1, "passed": True}
        else:
            launch_result = _run(
                commands,
                configuration,
                _helper_argv(configuration, "launch", process_receipt),
                label=f"attempt {attempt} fast launch",
            )
            if b"MacScope ready:" not in launch_result.stdout:
                raise AcceptanceError(f"attempt {attempt} did not report readiness")
            launch_route = "runloop-helper-launch"
        launch_completed = True
        _require_absent(configuration.recovery_receipt, label="post-launch recovery receipt")
        if attempt == 1:
            cycle_build_snapshot, observed_build = _load_build_authority(
                configuration, authority, commands
            )
            build_document = observed_build
        if build_document is None:
            raise AcceptanceError("cycle has no exact build authority")

        verify_argv = (
            _entrypoint_argv(configuration, "verify")
            if attempt == 1
            else _helper_argv(configuration, "verify", process_receipt)
        )
        proof = _parse_verify_output(
            _run(
                commands,
                configuration,
                verify_argv,
                label=f"attempt {attempt} verify",
            )
        )
        verify_route = "entrypoint-verify" if attempt == 1 else "runloop-helper-verify"
        if attempt == 1:
            entrypoint_updates["verify"] = {"attempt": 1, "passed": True}
        process_snapshot, process_document = _load_process_receipt(process_receipt)
        expected_process_fields = {
            "buildGeneration": build_document["buildGeneration"],
            "executablePath": str(configuration.executable),
            "pid": proof["pid"],
            "startMicroseconds": proof["startMicroseconds"],
            "startSeconds": proof["startSeconds"],
        }
        if any(process_document.get(key) != value for key, value in expected_process_fields.items()):
            raise AcceptanceError(f"attempt {attempt} verify and process receipt differ")
        if (
            proof["buildGeneration"] != build_document["buildGeneration"]
            or os.path.realpath(proof["executablePath"])
            != os.path.realpath(configuration.executable)
        ):
            raise AcceptanceError(f"attempt {attempt} belongs to a different generation")

        if attempt == 1:
            for mode in ("logs", "telemetry"):
                child = commands.spawn(
                    _entrypoint_argv(configuration, mode),
                    cwd=configuration.repository,
                    env=_environment(configuration),
                )
                diagnostics[mode] = child
            runtime.sleep(configuration.diagnostic_start_seconds)
            for mode, child in diagnostics.items():
                if child.poll() is not None:
                    raise AcceptanceError(f"{mode} entrypoint ended before the exact target stopped")

        during = runtime.snapshot()
        root = _record_for_identity(during, proof)
        descendants = _descendants(during, root.pid)
        bundle_records = _bundle_records(during, configuration.app_bundle)
        if root not in bundle_records:
            raise AcceptanceError("verified root is outside the exact rebuilt app bundle")
        diagnostic_processes: dict[str, tuple[ProcessRecord, tuple[ProcessRecord, ...]]] = {}
        for mode, child in diagnostics.items():
            matches = [record for record in during if record.pid == child.pid]
            if len(matches) != 1:
                raise AcceptanceError(
                    f"{mode} entrypoint child has no exact process-catalog identity"
                )
            diagnostic_processes[mode] = (
                matches[0],
                _descendants(during, child.pid),
            )
        during_fd = runtime.coordinator_fd_count()

        stop_argv = (
            _entrypoint_argv(configuration, "stop")
            if attempt == 1
            else _helper_argv(configuration, "stop", process_receipt)
        )
        _run(
            commands,
            configuration,
            stop_argv,
            label=f"attempt {attempt} stop",
        )
        stopped = True
        stop_route = "entrypoint-stop" if attempt == 1 else "runloop-helper-stop"
        if attempt == 1:
            entrypoint_updates["stop"] = {"attempt": 1, "passed": True}
        diagnostic_rows: dict[str, object] = {}
        for mode, child in diagnostics.items():
            returncode = _wait_diagnostic_child(
                child,
                timeout=configuration.diagnostic_exit_timeout_seconds,
                label=mode,
            )
            diagnostic_rows[mode] = {
                "child_pid": child.pid,
                "descendants": [
                    record.mapping() for record in diagnostic_processes[mode][1]
                ],
                "passed": True,
                "process_identity": diagnostic_processes[mode][0].mapping(),
                "returncode": returncode,
            }
            entrypoint_updates[mode] = {"attempt": 1, **diagnostic_rows[mode]}

        diagnostic_identities = tuple(
            record
            for diagnostic_root, diagnostic_descendants in diagnostic_processes.values()
            for record in (diagnostic_root, *diagnostic_descendants)
        )
        captured_identities = (root, *descendants, *diagnostic_identities)
        terminal, terminal_ls, after_fd = _await_terminal_snapshot(
            runtime=runtime,
            captured=captured_identities,
            app_bundle=configuration.app_bundle,
            process_receipt=process_receipt,
            recovery_receipt=configuration.recovery_receipt,
            baseline_ls=baseline_ls,
            baseline_fd=before_fd,
        )
        _require_identities_absent(
            captured_identities, terminal
        )
        if _bundle_records(terminal, configuration.app_bundle):
            raise AcceptanceError(f"attempt {attempt} left an exact-bundle process")
        _require_absent(process_receipt, label=f"attempt {attempt} process receipt")
        _require_absent(configuration.recovery_receipt, label="terminal recovery receipt")
        if terminal_ls != baseline_ls:
            raise AcceptanceError(f"attempt {attempt} changed unrelated LaunchServices inventory")
        if after_fd != before_fd:
            raise AcceptanceError(
                f"attempt {attempt} leaked coordinator descriptors ({before_fd} -> {after_fd})"
            )
        return (
            {
                "attempt": attempt,
                "app_bundle_processes": [record.mapping() for record in bundle_records],
                "coordinator_fd_count_after": after_fd,
                "coordinator_fd_count_before": before_fd,
                "coordinator_fd_count_during": during_fd,
                "descendants": [record.mapping() for record in descendants],
                "diagnostic_children": diagnostic_rows,
                "launch_route": launch_route,
                "process_identity": root.mapping(),
                "process_receipt_path": str(process_receipt),
                "process_receipt_sha256": process_snapshot.sha256,
                "recovery_receipt_absent": True,
                "stop_route": stop_route,
                "verify_route": verify_route,
                "window_count": proof["windowCount"],
            },
            entrypoint_updates,
            cycle_build_snapshot,
            build_document,
        )
    except BaseException as error:
        cleanup_error: Exception | None = None
        if launch_completed and not stopped:
            try:
                _cleanup_receipted_process(commands, configuration, process_receipt)
            except AcceptanceError as candidate:
                cleanup_error = candidate
        for mode, child in diagnostics.items():
            if child.poll() is None:
                try:
                    _wait_diagnostic_child(
                        child,
                        timeout=configuration.diagnostic_exit_timeout_seconds,
                        label=mode,
                    )
                except AcceptanceError as candidate:
                    cleanup_error = cleanup_error or candidate
        if cleanup_error is not None:
            raise AcceptanceError(f"{error}; cleanup failed: {cleanup_error}") from error
        raise


def _publish_create_only(
    path: Path,
    document: Mapping[str, object],
    *,
    post_link_fence: Callable[[], None] | None = None,
) -> StableFile:
    if not path.is_absolute() or not path.name:
        raise AcceptanceError("output must be an absolute file path")
    try:
        supplied_parent = path.parent
        parent = supplied_parent.resolve(strict=True)
    except OSError as error:
        raise AcceptanceError(f"output parent is unavailable: {error}") from error
    if parent != supplied_parent or not parent.is_dir() or parent.is_symlink():
        raise AcceptanceError("output parent must be a canonical direct directory")
    if path.exists() or path.is_symlink():
        raise AcceptanceError("output already exists; create-only publication refused")
    payload = _canonical_json(document)
    nonce = os.urandom(16).hex()
    temporary_name = f".{path.name}.{nonce}.tmp"
    descriptor = -1
    parent_descriptor = -1
    output_identity: tuple[int, int] | None = None
    final_output_metadata: os.stat_result | None = None
    try:
        parent_descriptor = os.open(
            parent,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        admitted_parent = os.fstat(parent_descriptor)
        path_parent = supplied_parent.lstat()
        if not stat.S_ISDIR(admitted_parent.st_mode) or (
            admitted_parent.st_dev,
            admitted_parent.st_ino,
        ) != (path_parent.st_dev, path_parent.st_ino):
            raise AcceptanceError("output parent changed while it was opened")
        descriptor = os.open(
            temporary_name,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
            dir_fd=parent_descriptor,
        )
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                raise AcceptanceError("receipt write made no progress")
            written += count
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = -1
        os.link(
            temporary_name,
            path.name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
        linked = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        output_identity = (linked.st_dev, linked.st_ino)
        os.unlink(temporary_name, dir_fd=parent_descriptor)
        os.fsync(parent_descriptor)

        output_descriptor = os.open(
            path.name,
            os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
            dir_fd=parent_descriptor,
        )
        try:
            opened = os.fstat(output_descriptor)
            observed_payload = bytearray()
            while len(observed_payload) <= len(payload):
                block = os.read(output_descriptor, len(payload) + 1 - len(observed_payload))
                if not block:
                    break
                observed_payload.extend(block)
            after_open = os.fstat(output_descriptor)
        finally:
            os.close(output_descriptor)
        if (
            (opened.st_dev, opened.st_ino) != output_identity
            or (after_open.st_dev, after_open.st_ino) != output_identity
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != 0o600
            or bytes(observed_payload) != payload
        ):
            raise AcceptanceError("linked receipt inode, mode, or bytes differ")
        try:
            current_parent = supplied_parent.lstat()
        except OSError as error:
            raise AcceptanceError(f"output parent changed during publication: {error}") from error
        if (
            current_parent.st_dev,
            current_parent.st_ino,
        ) != (admitted_parent.st_dev, admitted_parent.st_ino):
            raise AcceptanceError("output parent changed during publication")
        if post_link_fence is not None:
            post_link_fence()
        current_output = os.stat(path.name, dir_fd=parent_descriptor, follow_symlinks=False)
        if (current_output.st_dev, current_output.st_ino) != output_identity:
            raise AcceptanceError("published receipt inode changed before final fence")
        final_output_metadata = current_output
        current_parent = supplied_parent.lstat()
        if (
            current_parent.st_dev,
            current_parent.st_ino,
        ) != (admitted_parent.st_dev, admitted_parent.st_ino):
            raise AcceptanceError("output parent changed before final fence")
        os.fsync(parent_descriptor)
    except FileExistsError as error:
        raise AcceptanceError("output already exists; create-only publication refused") from error
    except BaseException:
        if parent_descriptor >= 0 and output_identity is not None:
            try:
                observed = os.stat(
                    path.name, dir_fd=parent_descriptor, follow_symlinks=False
                )
                if (observed.st_dev, observed.st_ino) == output_identity:
                    os.unlink(path.name, dir_fd=parent_descriptor)
                    os.fsync(parent_descriptor)
            except FileNotFoundError:
                pass
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if parent_descriptor >= 0:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
            os.close(parent_descriptor)
    if output_identity is None or final_output_metadata is None:
        raise AcceptanceError("receipt output inode was not established")
    snapshot = StableFile(
        path,
        payload,
        _sha256(payload),
        final_output_metadata.st_dev,
        final_output_metadata.st_ino,
        final_output_metadata.st_size,
        final_output_metadata.st_mtime_ns,
        final_output_metadata.st_ctime_ns,
        stat.S_IMODE(final_output_metadata.st_mode),
    )
    return snapshot


def run_acceptance(
    configuration: Configuration,
    authority: CandidateAuthority,
    *,
    commands: CommandAPI,
    runtime: RuntimeAPI,
) -> dict[str, object]:
    validate_configuration(configuration, authority)
    for attempt in range(1, ATTEMPT_COUNT + 1):
        _require_absent(
            configuration.process_receipt(attempt),
            label=f"initial attempt {attempt} process receipt",
        )
    _require_absent(configuration.recovery_receipt, label="initial recovery receipt")
    initial_processes = runtime.snapshot()
    if _bundle_records(initial_processes, configuration.app_bundle):
        raise AcceptanceError("exact rebuilt app bundle is already running; adoption refused")
    baseline_ls = _app_inventory_identity(runtime.application_inventory())
    baseline_fd = runtime.coordinator_fd_count()

    debug = _run(
        commands,
        configuration,
        _entrypoint_argv(configuration, "debug"),
        label="debug entrypoint",
        input_bytes=b"quit\n",
    )
    debug_output = _command_text(debug.stdout + debug.stderr, label="LLDB debug")
    if str(configuration.executable) not in debug_output:
        raise AcceptanceError("LLDB did not report the exact rebuilt executable")
    _debug_build_snapshot, _ = _load_build_authority(
        configuration, authority, commands
    )
    if _bundle_records(runtime.snapshot(), configuration.app_bundle):
        raise AcceptanceError("debug entrypoint left an app-bundle process")
    if runtime.coordinator_fd_count() != baseline_fd:
        raise AcceptanceError("debug entrypoint leaked coordinator descriptors")

    # Cycle one performs the real Run action, so its post-build receipt is the
    # sole build generation reused by attempts two through ten.
    entrypoints: dict[str, object] = {
        "debug": {
            "executable_path": str(configuration.executable),
            "passed": True,
        }
    }
    first_row, updates, build_snapshot, build_document = _cycle(
        1,
        configuration=configuration,
        authority=authority,
        build_document=None,
        commands=commands,
        runtime=runtime,
        baseline_ls=baseline_ls,
    )
    if build_snapshot is None:
        raise AcceptanceError("Run cycle did not return its exact build receipt")
    if first_row["process_identity"]["executable_path"] != str(configuration.executable):
        raise AcceptanceError("Run cycle executable differs from the final candidate")
    process_generation = first_row.get("process_receipt_sha256")
    if not isinstance(process_generation, str) or SHA256_RE.fullmatch(process_generation) is None:
        raise AcceptanceError("Run cycle process receipt digest is invalid")
    entrypoints.update(updates)

    rows = [first_row]
    identities = {tuple(first_row["process_identity"][key] for key in ("pid", "start_seconds", "start_microseconds", "executable_path"))}
    for attempt in range(2, ATTEMPT_COUNT + 1):
        row, updates, unexpected_build_snapshot, observed_build_document = _cycle(
            attempt,
            configuration=configuration,
            authority=authority,
            build_document=build_document,
            commands=commands,
            runtime=runtime,
            baseline_ls=baseline_ls,
        )
        if unexpected_build_snapshot is not None or observed_build_document != build_document:
            raise AcceptanceError("warm cycle replaced the frozen Run build authority")
        identity = tuple(
            row["process_identity"][key]
            for key in ("pid", "start_seconds", "start_microseconds", "executable_path")
        )
        if identity in identities:
            raise AcceptanceError("launch attempts did not produce ten distinct process identities")
        identities.add(identity)
        rows.append(row)
        entrypoints.update(updates)

    if len(rows) != ATTEMPT_COUNT or len(identities) != ATTEMPT_COUNT:
        raise AcceptanceError("exactly ten distinct launch cycles were not proven")
    if set(entrypoints) != ENTRYPOINT_KEYS or any(
        not isinstance(value, Mapping) or value.get("passed") is not True
        for value in entrypoints.values()
    ):
        raise AcceptanceError("real entrypoint proof is incomplete")

    terminal_processes = runtime.snapshot()
    if _bundle_records(terminal_processes, configuration.app_bundle):
        raise AcceptanceError("terminal process catalog contains rebuilt app residue")
    terminal_ls = _app_inventory_identity(runtime.application_inventory())
    if terminal_ls != baseline_ls:
        raise AcceptanceError("terminal LaunchServices inventory differs from baseline")
    terminal_fd = runtime.coordinator_fd_count()
    if terminal_fd != baseline_fd:
        raise AcceptanceError("terminal coordinator descriptor count differs from baseline")
    for attempt in range(1, ATTEMPT_COUNT + 1):
        _require_absent(
            configuration.process_receipt(attempt),
            label=f"terminal attempt {attempt} process receipt",
        )
    _require_absent(configuration.recovery_receipt, label="terminal recovery receipt")

    _revalidate(authority.candidate_file, label="candidate identity")
    _revalidate(authority.qualification_file, label="qualification receipt")
    _revalidate(authority.final_file, label="final local candidate receipt")
    _revalidate(build_snapshot, label="runloop build receipt")
    executable_snapshot = _stable_file(
        configuration.executable,
        label="terminal rebuilt executable",
        maximum_bytes=512 * 1024 * 1024,
    )
    if executable_snapshot.sha256 != authority.application_executable_sha256:
        raise AcceptanceError("rebuilt executable changed during runloop proof")

    with StableFileFences(
        (
            (authority.candidate_file, "candidate identity"),
            (authority.qualification_file, "qualification receipt"),
            (authority.final_file, "final local candidate receipt"),
            (build_snapshot, "runloop build receipt"),
            (executable_snapshot, "rebuilt executable"),
        )
    ) as fences:
        document: dict[str, object] = {
            "authority": {
                "application": {
                    "bundle_path": str(configuration.app_bundle),
                    "executable_path": str(configuration.executable),
                    "executable_sha256": executable_snapshot.sha256,
                },
                "build": {
                    "build_generation": build_document["buildGeneration"],
                    "dependency_identity_sha256": build_document["dependencyContract"][
                        "identitySha256"
                    ],
                    "generated_project_identity_sha256": build_document[
                        "generatedProjectIdentitySha256"
                    ],
                    "receipt_path": str(build_snapshot.path),
                    "receipt_sha256": build_snapshot.sha256,
                    "source_identity_sha256": build_document["source"]["identitySha256"],
                },
                "candidate": {
                    "application_executable_sha256": authority.application_executable_sha256,
                    "identity_file_sha256": authority.candidate_file.sha256,
                    "identity_path": str(authority.candidate_file.path),
                    "identity_semantic_sha256": authority.identity_semantic_sha256,
                    "source_commit": authority.source_commit,
                    "source_tree": authority.source_tree,
                },
                "final": {
                    "receipt_path": str(authority.final_file.path),
                    "receipt_sha256": authority.final_file.sha256,
                },
                "qualification": {
                    "integration_ref": authority.integration_ref,
                    "receipt_path": str(authority.qualification_file.path),
                    "receipt_sha256": authority.qualification_file.sha256,
                },
            },
            "baseline": {
                "app_bundle_processes": [],
                "coordinator_fd_count": baseline_fd,
                "launchservices_inventory": baseline_ls,
            },
            "cycles": rows,
            "entrypoints": entrypoints,
            "produced_at_unix_ns": time.time_ns(),
            "receipt_kind": RECEIPT_KIND,
            "result": RESULT,
            "schema_version": SCHEMA_VERSION,
            "terminal": {
                "app_bundle_processes": [],
                "coordinator_fd_count": terminal_fd,
                "launchservices_inventory": terminal_ls,
                "process_receipts_absent": True,
                "recovery_receipt_absent": True,
            },
        }
        _validate_generated_receipt(document)
        _publish_create_only(
            configuration.output,
            document,
            post_link_fence=fences.verify,
        )
    return document


def _load_runloop_module(helper: Path) -> Any:
    specification = importlib.util.spec_from_file_location("macscope_next5_runloop", helper)
    if specification is None or specification.loader is None:
        raise AcceptanceError("runloop helper could not be loaded")
    module = importlib.util.module_from_spec(specification)
    try:
        specification.loader.exec_module(module)
    except (OSError, ImportError, RuntimeError) as error:
        raise AcceptanceError(f"runloop helper could not be loaded: {error}") from error
    return module


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--candidate-identity", required=True, type=Path)
    parser.add_argument("--qualification-receipt", required=True, type=Path)
    parser.add_argument("--final-receipt", required=True, type=Path)
    parser.add_argument("--derived-data", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--configuration", default="Release")
    parser.add_argument("--command-timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--diagnostic-start-seconds", type=float, default=0.5)
    parser.add_argument("--diagnostic-exit-timeout-seconds", type=float, default=15.0)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        repository = arguments.repository.resolve(strict=True)
        derived_data = Path(os.path.realpath(arguments.derived_data))
        configuration = Configuration(
            repository=repository,
            entrypoint=repository / "script/build_and_run.sh",
            helper=repository / "Scripts/runloop_exact_app.py",
            candidate_identity=arguments.candidate_identity,
            qualification_receipt=arguments.qualification_receipt,
            final_receipt=arguments.final_receipt,
            derived_data=derived_data,
            configuration=arguments.configuration,
            output=arguments.output,
            command_timeout_seconds=arguments.command_timeout_seconds,
            diagnostic_start_seconds=arguments.diagnostic_start_seconds,
            diagnostic_exit_timeout_seconds=arguments.diagnostic_exit_timeout_seconds,
        )
        authority = load_candidate_authority(configuration)
        module = _load_runloop_module(configuration.helper)
        runtime = DarwinRuntime(module.running_applications)
        run_acceptance(
            configuration,
            authority,
            commands=RealCommands(),
            runtime=runtime,
        )
    except (AcceptanceError, OSError) as error:
        print(f"ERROR: next-five runloop acceptance refused: {error}", file=sys.stderr)
        return 1
    print(str(arguments.output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
