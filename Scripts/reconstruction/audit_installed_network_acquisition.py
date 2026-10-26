#!/usr/bin/env python3
"""Observe one exact installed MacScope process for non-loopback network use.

The audit is deliberately read-only.  It does not launch or terminate the app,
open a socket, contact a provider, mutate TCC, or alter the installed bundle.
It binds the observed PID to the candidate's exact executable before and after
the bounded observation window, then asks macOS ``nettop`` for per-process
summaries on every external or undefined interface.  Loopback is excluded
because MacScope's reviewed local-provider traffic is not dependency
acquisition.

An empty observation is accepted only when the observer exits successfully,
emits the complete expected CSV sample framing, runs for the requested window,
and the same PID/start-time/executable binding survives the window.  Missing,
malformed, truncated, timed-out, or otherwise unavailable observation is
reported as ``unavailable`` and exits nonzero; it is never converted to a pass.
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import errno
import hashlib
import os
import platform
import plistlib
import pty
import select
import stat
import subprocess
import sys
import termios
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from collections.abc import Mapping
from typing import Callable, Sequence, TypeVar


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    file_sha256,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (  # noqa: E402
    CandidateMaterializationError,
    capture_bundle_snapshot,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    candidate_identity_sha256,
    parse_candidate_identity,
)
from Scripts.reconstruction_gate_f.receipt_validator import (  # noqa: E402
    QualificationRunAuthority,
)
from Scripts.reconstruction.write_execution_report import (  # noqa: E402
    document as execution_report_document,
    qualification_run_authority,
    write_create_only,
)
from Scripts.ws24_emit_installed_qualification_report import (  # noqa: E402
    installed_selector_projection,
    load_installed_selector_catalog,
)
from Scripts.reconstruction.network_process_watch import ProcessWatchCollector, ProcessWatchError
from Scripts.reconstruction.network_attribution import PROOF_KIND, NetworkAttributionError, validate_foreign_proofs


REPORT_SCHEMA_VERSION = 1
OBSERVER_ID = "nettop-per-process-nonloopback-v1"
REPORT_NAME = "InstalledNetworkAcquisition.audit.json"
EXECUTION_REPORT_NAME = "InstalledNetworkAcquisition.execution-report.json"
OBSERVATION_NAME = "InstalledNetworkAcquisition.nettop.csv"
NETTOP_PATH = Path("/usr/bin/nettop")
MIN_DURATION_SECONDS = 2
MAX_DURATION_SECONDS = 300
MAX_CANDIDATE_BYTES = 4 * 1024 * 1024
MAX_INFO_PLIST_BYTES = 2 * 1024 * 1024
MAX_OBSERVER_STDOUT_BYTES = 1024 * 1024
MAX_OBSERVER_STDERR_BYTES = 64 * 1024
MATRIX_OBSERVER_READY_TIMEOUT_SECONDS = 15
PROC_ALL_PIDS = 1
PROC_PIDTBSDINFO = 3
PROC_PIDPATHINFO_MAXSIZE = 4 * 1024
MAX_PID_BUFFER_BYTES = 1024 * 1024
MAXCOMLEN = 16
MATRIX_REPORT_SCHEMA_VERSION = 4
MATRIX_OBSERVER_ID = "nettop-prearmed-foreign-exclusion-v4"
MATRIX_EVIDENCE_SCOPE = "sampled-external-undefined-state-for-five-governed-executables"
MATRIX_LIMITATIONS = (
    "not-packet-complete",
    "no-sub-sample-lifecycle-or-traffic-proof",
    "excludes-shell-broker-children-and-delegated-services",
    "not-universal-network-or-acquisition-absence",
)
MAX_MATRIX_REPORT_BYTES = 4 * 1024 * 1024


class AuditInputError(ValueError):
    """The caller did not identify a safe, exact candidate or artifact root."""


@dataclass(frozen=True, order=True)
class ProcessIdentity:
    pid: int
    executable_path: str
    start_time_unix_us: int


@dataclass(frozen=True)
class ObserverExecution:
    returncode: int
    stdout: bytes
    stderr: bytes
    elapsed_ms: int
    timed_out: bool = False
    stopped_by_auditor: bool = False
    observer_eof_ns: int | None = None


@dataclass(frozen=True)
class ObservationSummary:
    sample_count: int
    process_row_count: int


@dataclass(frozen=True)
class MatrixObservationSummary:
    sample_count: int
    process_row_count: int
    candidate_row_count: int
    foreign_row_count: int
    unresolved_row_count: int


def _matrix_row_pids(payload: bytes) -> tuple[int, tuple[int, ...]]:
    """Strict physical CSV frames; retain rather than filter the original bytes."""
    if type(payload) is not bytes or not payload or len(payload) > MAX_OBSERVER_STDOUT_BYTES:
        raise AuditInputError("matrix CSV is empty or exceeds its fixed evidence bound")
    if not payload.endswith(b"\n"):
        raise AuditInputError("matrix CSV has an incomplete tail")
    normalized = payload.replace(b"\r\n", b"\n")
    if b"\r" in normalized or (b"\r\n" in payload and b"\n" in payload.replace(b"\r\n", b"")):
        raise AuditInputError("matrix CSV has invalid or mixed line endings")
    samples, pids = 0, []
    for line in normalized.split(b"\n")[:-1]:
        if not line or len(line) > 8192:
            raise AuditInputError("matrix CSV has an empty or oversized row")
        try:
            text = line.decode("utf-8", errors="strict")
            if any(ord(char) < 32 or ord(char) == 127 for char in text):
                raise ValueError("control character")
            rows = list(csv.reader([text], strict=True))
        except (UnicodeDecodeError, csv.Error, ValueError) as error:
            raise AuditInputError("matrix CSV row is malformed") from error
        row = rows[0]
        if row == ["", "bytes_in", "bytes_out", ""]:
            if line != b",bytes_in,bytes_out,":
                raise AuditInputError("matrix CSV header is noncanonical")
            samples += 1
            continue
        if samples == 0 or len(row) != 4 or row[-1] != "":
            raise AuditInputError("matrix CSV requires a header and exact process row schema")
        name, incoming, outgoing, _ = row
        prefix, separator, pid_text = name.rpartition(".")
        if (not prefix or not separator or len(name.encode("utf-8")) > 4096
                or not pid_text or len(pid_text) > 10
                or any(char not in "0123456789" for char in pid_text)
                or not 1 <= int(pid_text) <= 2147483647 or str(int(pid_text)) != pid_text):
            raise AuditInputError("matrix CSV process has no canonical positive PID")
        for counter in (incoming, outgoing):
            if (not counter or len(counter) > 20 or any(char not in "0123456789" for char in counter)
                    or int(counter) > (1 << 64) - 1):
                raise AuditInputError("matrix CSV has invalid bounded ASCII counters")
        pids.append(int(pid_text))
    if samples == 0:
        raise AuditInputError("matrix CSV contains no complete sample")
    return samples, tuple(pids)


def classify_matrix_observation(
    payload: bytes, *, candidate_pids: frozenset[int], foreign_pids: frozenset[int],
) -> MatrixObservationSummary:
    """Classify every row using independently admitted process authorities."""
    for identities in (candidate_pids, foreign_pids):
        if (type(identities) is not frozenset or len(identities) > 4096
                or any(type(pid) is not int or not 1 <= pid <= 2147483647 for pid in identities)):
            raise AuditInputError("matrix PID authority is not a bounded exact set")
    if not candidate_pids or candidate_pids & foreign_pids:
        raise AuditInputError("matrix candidate/foreign authority is absent or contradictory")
    samples, pids = _matrix_row_pids(payload)
    candidate = sum(pid in candidate_pids for pid in pids)
    foreign = sum(pid in foreign_pids for pid in pids)
    return MatrixObservationSummary(samples, len(pids), candidate, foreign, len(pids) - candidate - foreign)


@dataclass(frozen=True)
class AppAuthority:
    bundle_path: str
    bundle_identifier: str
    bundle_sha256: str
    closed_tree_sha256: str
    executable_path: str
    executable_sha256: str


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


ProcessProvider = Callable[[str], tuple[ProcessIdentity, ...]]
ObserverRunner = Callable[[int, int], tuple[tuple[str, ...], ObserverExecution]]
@dataclass(frozen=True)
class ContinuousMatrixObserverSession:
    """One ready, long-lived observer whose interval encloses a workload.

    The session is not usable until ``nettop`` has emitted the first valid CSV
    sample frame.  This makes the recorded readiness boundary evidence rather
    than a best-effort timestamp taken after ``Popen`` returns.
    """

    argv: tuple[str, ...]
    started_at_unix_ms: int
    ready_at_unix_ms: int
    readiness_frame_sha256: str
    finish: Callable[[], ObserverExecution]
    observer_spawn_ns: int | None = None


ContinuousMatrixObserverFactory = Callable[[], ContinuousMatrixObserverSession]
T = TypeVar("T")


MANDATORY_EXECUTABLE_NAMES = {
    "ai-agent-worker": "AIAgentWorkerXPCService",
    "analysis-worker": "AnalysisWorkerXPCService",
    "native-decompiler": "NativeDecompilerXPCService",
    "shell-broker": "ShellBrokerXPCService",
}


@dataclass(frozen=True, order=True)
class ExecutableAuthority:
    identity_id: str
    executable_path: str
    executable_sha256: str


def _regular_file(path: Path, *, label: str, maximum_bytes: int | None = None) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AuditInputError(f"{label} is missing or inaccessible: {error}") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise AuditInputError(f"{label} must be a non-symlink regular file")
    if maximum_bytes is not None and metadata.st_size > maximum_bytes:
        raise AuditInputError(f"{label} exceeds its fixed size bound")
    return metadata


def _canonical_existing_path(path: Path, *, label: str, directory: bool) -> Path:
    if not path.is_absolute():
        raise AuditInputError(f"{label} must be absolute")
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise AuditInputError(f"{label} is unavailable: {error}") from error
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_type(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "regular file"
        raise AuditInputError(f"{label} must be a non-symlink {kind}")
    if resolved != path:
        raise AuditInputError(f"{label} must be a canonical path without symlink traversal")
    return resolved


def load_candidate(path: Path) -> tuple[CandidateIdentity, str]:
    canonical_path = _canonical_existing_path(path, label="candidate identity", directory=False)
    _regular_file(
        canonical_path,
        label="candidate identity",
        maximum_bytes=MAX_CANDIDATE_BYTES,
    )
    try:
        document = load_canonical_json(canonical_path)
    except CanonicalJSONError as error:
        raise AuditInputError(f"candidate identity is not canonical JSON: {error}") from error
    candidate, issues = parse_candidate_identity(document)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} {issue.path}: {issue.message}" for issue in issues
        )
        raise AuditInputError(f"candidate identity is invalid: {detail}")
    return candidate, file_sha256(canonical_path)


def inspect_app(app_bundle: Path, candidate: CandidateIdentity) -> AppAuthority:
    bundle = _canonical_existing_path(app_bundle, label="installed app", directory=True)
    if bundle.suffix != ".app":
        raise AuditInputError("installed app must be an .app bundle")
    info_path = bundle / "Contents" / "Info.plist"
    _regular_file(info_path, label="installed app Info.plist", maximum_bytes=MAX_INFO_PLIST_BYTES)
    try:
        with info_path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise AuditInputError(f"installed app Info.plist is invalid: {error}") from error
    bundle_id = info.get("CFBundleIdentifier")
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise AuditInputError("installed app has no valid CFBundleIdentifier")
    if (
        not isinstance(executable_name, str)
        or not executable_name
        or executable_name in {".", ".."}
        or "/" in executable_name
        or "\x00" in executable_name
    ):
        raise AuditInputError("installed app has no safe CFBundleExecutable")
    if bundle_id != candidate.application.bundle_identifier:
        raise AuditInputError("installed app bundle identifier differs from the candidate")
    executable = _canonical_existing_path(
        bundle / "Contents" / "MacOS" / executable_name,
        label="installed app executable",
        directory=False,
    )
    executable_metadata = _regular_file(executable, label="installed app executable")
    if not executable_metadata.st_mode & stat.S_IXUSR:
        raise AuditInputError("installed app executable is not executable")
    executable_digest = file_sha256(executable)
    if executable_digest != candidate.application.executable_sha256:
        raise AuditInputError("installed app executable SHA-256 differs from the candidate")
    try:
        snapshot = capture_bundle_snapshot(bundle, app_root=True)
    except CandidateMaterializationError as error:
        raise AuditInputError(f"installed app bundle identity is unsafe: {error}") from error
    root_mode = stat.S_IMODE(bundle.lstat().st_mode)
    if (
        snapshot.digests.content_sha256 != candidate.application.bundle_sha256
        or snapshot.digests.closed_tree_sha256
        != candidate.application.closed_tree_sha256
        or root_mode != candidate.application.root_mode
    ):
        raise AuditInputError("installed app bundle identity differs from the candidate")
    return AppAuthority(
        bundle_path=str(bundle),
        bundle_identifier=bundle_id,
        bundle_sha256=snapshot.digests.content_sha256,
        closed_tree_sha256=snapshot.digests.closed_tree_sha256,
        executable_path=str(executable),
        executable_sha256=executable_digest,
    )


def inspect_candidate_executables(
    app_bundle: Path,
    candidate: CandidateIdentity,
) -> tuple[ExecutableAuthority, ...]:
    """Freeze the complete candidate-governed installed process vocabulary."""
    app = inspect_app(app_bundle, candidate)
    expected = {
        item.identity_id: item.sha256
        for item in candidate.application.embedded_executables
    }
    if set(expected) != set(MANDATORY_EXECUTABLE_NAMES):
        raise AuditInputError("candidate embedded executable set is not the closed mandatory set")
    authorities = [
        ExecutableAuthority("app", app.executable_path, app.executable_sha256)
    ]
    bundle = Path(app.bundle_path)
    for identity_id, executable_name in sorted(MANDATORY_EXECUTABLE_NAMES.items()):
        executable = _canonical_existing_path(
            bundle
            / "Contents/XPCServices"
            / f"{executable_name}.xpc/Contents/MacOS"
            / executable_name,
            label=f"installed {identity_id} executable",
            directory=False,
        )
        digest = file_sha256(executable)
        if digest != expected[identity_id]:
            raise AuditInputError(
                f"installed {identity_id} executable SHA-256 differs from the candidate"
            )
        authorities.append(ExecutableAuthority(identity_id, str(executable), digest))
    return tuple(sorted(authorities))


def _libproc() -> ctypes.CDLL:
    if sys.platform != "darwin":
        raise AuditInputError("the installed network observer requires macOS")
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError as error:
        raise AuditInputError(f"libproc is unavailable: {error}") from error
    library.proc_listpids.argtypes = (
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_int,
    )
    library.proc_listpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = (ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32)
    library.proc_pidpath.restype = ctypes.c_int
    library.proc_pidinfo.argtypes = (
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint64,
        ctypes.c_void_p,
        ctypes.c_int,
    )
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def _probe_process(library: ctypes.CDLL, pid: int) -> ProcessIdentity | None:
    if pid <= 0:
        return None
    path_buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
    path_length = library.proc_pidpath(pid, path_buffer, len(path_buffer))
    if path_length <= 0:
        return None
    try:
        executable_path = path_buffer.value.decode("utf-8")
    except UnicodeDecodeError:
        return None
    info = _ProcBSDInfo()
    returned = library.proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        ctypes.byref(info),
        ctypes.sizeof(info),
    )
    if returned != ctypes.sizeof(info) or info.pbi_pid != pid:
        return None
    return ProcessIdentity(
        pid=pid,
        executable_path=executable_path,
        start_time_unix_us=(
            int(info.pbi_start_tvsec) * 1_000_000 + int(info.pbi_start_tvusec)
        ),
    )


def _all_process_ids(library=None) -> tuple[int, ...]:
    """One bounded census, not a claim of complete lifecycle observation."""
    library = library or _libproc()
    required_bytes = library.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
    if required_bytes <= 0 or required_bytes > MAX_PID_BUFFER_BYTES:
        raise AuditInputError("libproc returned an unavailable or unbounded PID catalog")
    capacity = min(MAX_PID_BUFFER_BYTES, required_bytes + 16 * 1024)
    buffer = (ctypes.c_int * (capacity // ctypes.sizeof(ctypes.c_int)))()
    returned = library.proc_listpids(PROC_ALL_PIDS, 0, ctypes.byref(buffer), capacity)
    if returned <= 0 or returned >= capacity or returned % ctypes.sizeof(ctypes.c_int):
        raise AuditInputError("libproc could not enumerate a complete bounded PID catalog")
    pids = tuple(sorted(set(int(value) for value in buffer[:returned // ctypes.sizeof(ctypes.c_int)] if value > 0)))
    if len(pids) > 4096:
        raise AuditInputError("process census exceeds watcher bound")
    return pids


def matching_processes(expected_executable_path: str) -> tuple[ProcessIdentity, ...]:
    library = _libproc()
    required_bytes = library.proc_listpids(PROC_ALL_PIDS, 0, None, 0)
    if required_bytes <= 0 or required_bytes > MAX_PID_BUFFER_BYTES:
        raise AuditInputError("libproc returned an unavailable or unbounded PID catalog")
    # Processes may appear between the sizing and population calls.  A bounded
    # extra page prevents ordinary races from truncating the catalog.
    capacity_bytes = min(MAX_PID_BUFFER_BYTES, required_bytes + 16 * 1024)
    count = capacity_bytes // ctypes.sizeof(ctypes.c_int)
    buffer = (ctypes.c_int * count)()
    returned_bytes = library.proc_listpids(
        PROC_ALL_PIDS,
        0,
        ctypes.byref(buffer),
        capacity_bytes,
    )
    if returned_bytes <= 0 or returned_bytes >= capacity_bytes:
        raise AuditInputError("libproc could not enumerate a bounded PID catalog")
    returned_count = returned_bytes // ctypes.sizeof(ctypes.c_int)
    expected = os.path.realpath(expected_executable_path)
    matches: list[ProcessIdentity] = []
    for pid in sorted(set(int(value) for value in buffer[:returned_count] if value > 0)):
        identity = _probe_process(library, pid)
        if identity is not None and os.path.realpath(identity.executable_path) == expected:
            matches.append(identity)
    return tuple(sorted(matches))


def observer_argv(pid: int, duration_seconds: int) -> tuple[str, ...]:
    if pid <= 0:
        raise AuditInputError("observed PID must be positive")
    if not MIN_DURATION_SECONDS <= duration_seconds <= MAX_DURATION_SECONDS:
        raise AuditInputError(
            f"duration must be {MIN_DURATION_SECONDS}...{MAX_DURATION_SECONDS} seconds"
        )
    sample_count = duration_seconds + 1
    return (
        str(NETTOP_PATH),
        "-n",
        "-P",
        "-x",
        "-L",
        str(sample_count),
        "-s",
        "1",
        "-p",
        str(pid),
        "-t",
        "external",
        "-t",
        "undefined",
        "-J",
        "bytes_in,bytes_out",
    )


def run_observer(pid: int, duration_seconds: int) -> tuple[tuple[str, ...], ObserverExecution]:
    argv = observer_argv(pid, duration_seconds)
    started = time.monotonic_ns()
    try:
        completed = subprocess.run(
            argv,
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=duration_seconds + 15,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
    except subprocess.TimeoutExpired as error:
        elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
        return argv, ObserverExecution(
            returncode=124,
            stdout=error.stdout or b"",
            stderr=error.stderr or b"",
            elapsed_ms=int(elapsed_ms),
            timed_out=True,
        )
    elapsed_ms = (time.monotonic_ns() - started) // 1_000_000
    return argv, ObserverExecution(
        returncode=completed.returncode,
        stdout=completed.stdout,
        stderr=completed.stderr,
        elapsed_ms=int(elapsed_ms),
    )


MATRIX_OBSERVER_READY_FRAME = b",bytes_in,bytes_out,\n"


def matrix_observer_argv() -> tuple[str, ...]:
    # ``-L 0`` is one unbounded CSV logging session.  Do not freeze a PID
    # filter here: Task10 deliberately terminates and relaunches the exact
    # installed app while capturing its governed presentation states.  A
    # process filter would create an unobservable gap at each relaunch.  Every
    # emitted process event is instead bound after collection to an exact
    # candidate executable/path/start-time identity, and any foreign or
    # unattributable PID fails closed.
    argv = [str(NETTOP_PATH), "-n", "-P", "-x", "-L", "0", "-s", "1"]
    argv.extend(("-t", "external", "-t", "undefined", "-J", "bytes_in,bytes_out"))
    return tuple(argv)


def _await_matrix_observer_readiness(collector: "_MatrixObserverCollector") -> tuple[int, bytes]:
    """Require the first exact CSV frame before the matrix may begin.

    ``nettop`` is not considered observing just because its process has been
    spawned.  The lifetime collector reads the exact first frame and retains
    it in the final sealed CSV so the physical evidence retains the readiness
    sample.  Any early stderr, exit, malformed frame, or timeout is unavailable
    evidence and prevents the workload from starting.
    """
    deadline = time.monotonic() + MATRIX_OBSERVER_READY_TIMEOUT_SECONDS
    with collector.condition:
        while True:
            if collector.failure:
                raise AuditInputError(collector.failure)
            if collector.done or collector.process.poll() is not None:
                raise AuditInputError("continuous nettop exited before readiness was proven")
            if collector.ready_at_unix_ms is not None:
                return collector.ready_at_unix_ms, MATRIX_OBSERVER_READY_FRAME
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AuditInputError("continuous nettop readiness was not proven before timeout")
            collector.condition.wait(min(remaining, 0.1))


class _MatrixObserverCollector:
    """Continuously drain owned descriptors with fixed memory bounds."""

    def __init__(self, process: subprocess.Popen[bytes], master: int):
        self.process = process
        self.master = master
        self.stdout = bytearray()
        self.stderr = bytearray()
        self.condition = threading.Condition()
        self.stop = threading.Event()
        self.auditor_stopping = threading.Event()
        self.failure = ""
        self.ready_at_unix_ms: int | None = None
        self.eof_monotonic_ns: int | None = None
        self.done = False
        self.descriptors_closed = False
        self.close_lock = threading.Lock()
        self.thread = threading.Thread(target=self._drain, name="macscope-nettop-drain")

    def _close_descriptors(self) -> None:
        with self.close_lock:
            if not self.descriptors_closed:
                self.descriptors_closed = True
                os.close(self.master)
                assert self.process.stderr is not None
                self.process.stderr.close()

    def _terminate_owned_child(self) -> None:
        if self.process.poll() is None:
            try:
                self.process.terminate()
            except ProcessLookupError:
                pass  # The owned child exited between poll and terminate.

    def _drain(self) -> None:
        assert self.process.stderr is not None
        stderr_fd = self.process.stderr.fileno()
        descriptors = {self.master, stderr_fd}
        try:
            for descriptor in descriptors:
                os.set_blocking(descriptor, False)
            while descriptors and not self.stop.is_set():
                readable, _, _ = select.select(tuple(descriptors), (), (), 0.1)
                # Stderr must not be hidden by a simultaneously ready header.
                for descriptor in sorted(readable, key=lambda item: item != stderr_fd):
                    try:
                        chunk = os.read(descriptor, 8192)
                    except OSError as error:
                        if error.errno in {errno.EAGAIN, errno.EWOULDBLOCK}:
                            continue
                        if descriptor == self.master and error.errno == errno.EIO:
                            chunk = b""  # PTY slave closed after child exit.
                        else:
                            raise
                    if not chunk:
                        if descriptor == self.master and not self.auditor_stopping.is_set():
                            with self.condition:
                                self.failure = "continuous nettop closed stdout before auditor termination"
                                self.condition.notify_all()
                            self._terminate_owned_child()
                            return
                        descriptors.remove(descriptor)
                        continue
                    with self.condition:
                        target = self.stderr if descriptor == stderr_fd else self.stdout
                        limit = MAX_OBSERVER_STDERR_BYTES if descriptor == stderr_fd else MAX_OBSERVER_STDOUT_BYTES
                        target.extend(chunk[:max(0, limit + 1 - len(target))])
                        if len(target) > limit:
                            self.failure = "continuous nettop output exceeded its fixed evidence bound"
                        elif descriptor == stderr_fd:
                            self.failure = "continuous nettop emitted stderr"
                        elif self.ready_at_unix_ms is None:
                            prefix = bytes(self.stdout[:len(MATRIX_OBSERVER_READY_FRAME)])
                            if not MATRIX_OBSERVER_READY_FRAME.startswith(prefix):
                                self.failure = "continuous nettop emitted an invalid readiness frame"
                            elif prefix == MATRIX_OBSERVER_READY_FRAME:
                                self.ready_at_unix_ms = time.time_ns() // 1_000_000
                        self.condition.notify_all()
                    if self.failure:
                        self._terminate_owned_child()
                        return
        except (OSError, ValueError) as error:
            with self.condition:
                self.failure = f"continuous nettop drain failed: {error}"
        finally:
            if not descriptors and not self.stop.is_set() and not self.failure:
                self.eof_monotonic_ns = time.monotonic_ns()
            self._close_descriptors()
            with self.condition:
                self.done = True
                self.condition.notify_all()

    def finish(self, started: int) -> ObserverExecution:
        stopped_by_auditor = self.process.poll() is None and not self.failure
        self.auditor_stopping.set()
        self._terminate_owned_child()
        timed_out = False
        try:
            try:
                self.process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    self.process.kill()
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=15)
        except subprocess.TimeoutExpired as error:
            raise AuditInputError("continuous nettop child did not exit within its cleanup bound") from error
        finally:
            # Even a second wait failure must release the owned transport.
            self.thread.join(timeout=2)
            if self.thread.is_alive():
                self.failure = "continuous nettop descriptors remained open after child exit"
                self.stop.set()
                self.thread.join(timeout=1)
                if self.thread.is_alive():
                    self._close_descriptors()
                    self.thread.join(timeout=1)
                    if self.thread.is_alive():
                        raise AuditInputError("continuous nettop drain did not stop within its cleanup bound")
        stderr = bytes(self.stderr)
        if self.failure and not stderr:
            stderr = self.failure.encode("utf-8")
        return ObserverExecution(
            self.process.returncode, bytes(self.stdout), stderr,
            int((time.monotonic_ns() - started) // 1_000_000), timed_out,
            stopped_by_auditor and not self.failure,
            self.eof_monotonic_ns,
        )


def start_matrix_observer() -> ContinuousMatrixObserverSession:
    """Start exactly one continuous, task-owned nettop observation session."""
    argv = matrix_observer_argv()
    try:
        master, slave = pty.openpty()
    except OSError as error:
        raise AuditInputError(f"cannot open continuous nettop transport: {error}") from error
    try:
        attributes = termios.tcgetattr(slave)
        attributes[1] &= ~termios.OPOST
        termios.tcsetattr(slave, termios.TCSANOW, attributes)
        started = time.monotonic_ns()
        started_at_unix_ms = time.time_ns() // 1_000_000
        process = subprocess.Popen(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=slave,
            stderr=subprocess.PIPE,
            bufsize=0,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"},
        )
    except (OSError, termios.error) as error:
        os.close(master)
        raise AuditInputError(f"cannot start continuous nettop observation: {error}") from error
    finally:
        os.close(slave)
    collector = _MatrixObserverCollector(process, master)
    try:
        collector.thread.start()
    except RuntimeError as error:
        collector._terminate_owned_child()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=15)
        finally:
            os.close(master)
            assert process.stderr is not None
            process.stderr.close()
        raise AuditInputError("cannot start continuous nettop drain") from error
    try:
        ready_at_unix_ms, readiness_frame = _await_matrix_observer_readiness(collector)
    except AuditInputError:
        collector.finish(started)
        raise

    def finish() -> ObserverExecution:
        return collector.finish(started)

    return ContinuousMatrixObserverSession(
        tuple(argv),
        started_at_unix_ms,
        ready_at_unix_ms,
        hashlib.sha256(readiness_frame).hexdigest(),
        finish,
        started,
    )


def parse_matrix_observation(
    payload: bytes,
    *,
    identities_by_pid: Mapping[int, ProcessIdentity],
) -> ObservationSummary:
    # The continuous observer deliberately sees all external/undefined process
    # traffic so it survives Task10's app relaunches.  A row is evidence only
    # when its PID can be bound to a candidate executable and immutable process
    # start time captured at a workload boundary; every other row is fail-closed.
    if len(payload) > MAX_OBSERVER_STDOUT_BYTES:
        raise AuditInputError("nettop output exceeds the fixed evidence bound")
    try:
        rows = list(csv.reader(payload.decode("utf-8").splitlines()))
    except (UnicodeDecodeError, csv.Error) as error:
        raise AuditInputError(f"nettop CSV is malformed: {error}") from error
    samples = 0
    process_rows = 0
    for index, row in enumerate(rows):
        if row == ["", "bytes_in", "bytes_out", ""]:
            samples += 1
            continue
        if not row or all(not cell for cell in row):
            continue
        if len(row) != 4 or row[-1] != "":
            raise AuditInputError(f"nettop row {index + 1} has an unknown schema")
        process_name, bytes_in, bytes_out, _ = row
        try:
            observed_pid = int(process_name.rsplit(".", 1)[1])
        except (IndexError, ValueError):
            raise AuditInputError(f"nettop row {index + 1} has no PID-qualified process")
        if observed_pid not in identities_by_pid:
            raise AuditInputError(
                f"nettop row {index + 1} is foreign or lacks a governed process identity"
            )
        if not bytes_in.isdigit() or not bytes_out.isdigit():
            raise AuditInputError(f"nettop row {index + 1} has invalid byte counters")
        process_rows += 1
    if samples <= 0:
        raise AuditInputError("nettop did not emit a complete continuous matrix sample frame")
    return ObservationSummary(samples, process_rows)


def parse_combined_matrix_observation(
    payload: bytes,
    *,
    pids: frozenset[int],
) -> ObservationSummary:
    """Recompute aggregate counters from the exact concatenated nettop bytes."""
    if not pids:
        raise AuditInputError("matrix observation has no candidate-bound PID vocabulary")
    if not payload:
        raise AuditInputError("matrix observation is empty")
    if len(payload) > MAX_OBSERVER_STDOUT_BYTES:
        raise AuditInputError("nettop output exceeds the fixed evidence bound")
    try:
        rows = list(csv.reader(payload.decode("utf-8").splitlines()))
    except (UnicodeDecodeError, csv.Error) as error:
        raise AuditInputError(f"nettop CSV is malformed: {error}") from error
    samples = 0
    process_rows = 0
    for index, row in enumerate(rows):
        if row == ["", "bytes_in", "bytes_out", ""]:
            samples += 1
            continue
        if not row or all(not cell for cell in row):
            continue
        if len(row) != 4 or row[-1] != "":
            raise AuditInputError(f"nettop row {index + 1} has an unknown schema")
        process_name, bytes_in, bytes_out, _ = row
        try:
            observed_pid = int(process_name.rsplit(".", 1)[1])
        except (IndexError, ValueError):
            raise AuditInputError(f"nettop row {index + 1} has no PID-qualified process")
        if observed_pid not in pids:
            raise AuditInputError(f"nettop row {index + 1} belongs to another PID")
        if (
            not bytes_in.isdigit()
            or not bytes_out.isdigit()
            or len(bytes_in) > 20
            or len(bytes_out) > 20
        ):
            raise AuditInputError(f"nettop row {index + 1} has invalid byte counters")
        process_rows += 1
    if samples <= 0:
        raise AuditInputError("nettop did not emit a complete matrix sample frame")
    return ObservationSummary(samples, process_rows)


def observation_contains_workload(
    observation_started_ms: int,
    workload_started_ms: int,
    workload_ended_ms: int,
    observation_ended_ms: int,
) -> bool:
    return (
        observation_started_ms <= workload_started_ms
        and workload_started_ms < workload_ended_ms
        and workload_ended_ms <= observation_ended_ms
    )


def _candidate_process_snapshot(
    authorities: Sequence[ExecutableAuthority],
    process_provider: ProcessProvider,
) -> dict[int, tuple[str, ProcessIdentity]]:
    """Capture all currently live candidate identities without requiring liveness.

    The application and XPC services are demand-launched and may deliberately
    exit/relaunch during the UI matrix.  Their absence at a boundary is not
    evidence of a network gap.  If one appears in ``nettop`` it must, however,
    be represented by an exact snapshot identity at one of the boundaries.
    """
    snapshot: dict[int, tuple[str, ProcessIdentity]] = {}
    for authority in authorities:
        active = process_provider(authority.executable_path)
        for identity in active:
            if identity.pid <= 0 or identity.start_time_unix_us <= 0:
                raise AuditInputError("candidate process identity is incomplete")
            if os.path.realpath(identity.executable_path) != authority.executable_path:
                raise AuditInputError("candidate process executable path drifted")
            existing = snapshot.get(identity.pid)
            if existing is not None:
                raise AuditInputError("candidate PID is duplicated across governed executable identities")
            snapshot[identity.pid] = (authority.identity_id, identity)
    return snapshot


def _merge_candidate_process_snapshots(
    before: Mapping[int, tuple[str, ProcessIdentity]],
    after: Mapping[int, tuple[str, ProcessIdentity]],
) -> dict[int, tuple[str, ProcessIdentity]]:
    """Combine boundary snapshots while rejecting detectable PID reuse.

    Deliberate relaunch is represented by a *new* PID/start-time identity and
    is retained alongside the terminated predecessor.  Reusing a PID for a
    different executable or start time makes any intervening nettop row
    ambiguous and therefore unavailable evidence.
    """
    merged = dict(before)
    for pid, value in after.items():
        existing = merged.get(pid)
        if existing is not None and existing != value:
            raise AuditInputError(
                "candidate PID was reused across the continuous matrix observation"
            )
        merged[pid] = value
    return merged


def _minimum_continuous_frame_count(
    readiness_at_unix_ms: int,
    observation_ended_at_unix_ms: int,
) -> int:
    if observation_ended_at_unix_ms < readiness_at_unix_ms:
        raise AuditInputError("continuous observer ended before its readiness frame")
    # The readiness frame is sample one.  Every complete subsequent one-second
    # interval must contribute another frame; otherwise the sealed observer
    # output cannot prove that it remained continuously live.
    return 1 + (observation_ended_at_unix_ms - readiness_at_unix_ms) // 1_000


def parse_observation(payload: bytes, *, pid: int) -> ObservationSummary:
    if len(payload) > MAX_OBSERVER_STDOUT_BYTES:
        raise AuditInputError("nettop output exceeds the fixed evidence bound")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise AuditInputError(f"nettop output is not UTF-8: {error}") from error
    sample_count = 0
    process_row_count = 0
    try:
        rows = csv.reader(text.splitlines())
        for index, row in enumerate(rows):
            if len(row) == 4 and row == ["", "bytes_in", "bytes_out", ""]:
                sample_count += 1
                continue
            if not row or all(not cell for cell in row):
                continue
            if len(row) != 4 or row[-1] != "":
                raise AuditInputError(f"nettop row {index + 1} has an unknown schema")
            process_name, bytes_in, bytes_out, _ = row
            if not process_name or "." not in process_name:
                raise AuditInputError(f"nettop row {index + 1} has no PID-qualified process")
            _, observed_pid = process_name.rsplit(".", 1)
            if observed_pid != str(pid):
                raise AuditInputError(f"nettop row {index + 1} belongs to another PID")
            if (
                not bytes_in.isdigit()
                or not bytes_out.isdigit()
                or len(bytes_in) > 20
                or len(bytes_out) > 20
            ):
                raise AuditInputError(f"nettop row {index + 1} has invalid byte counters")
            process_row_count += 1
    except csv.Error as error:
        raise AuditInputError(f"nettop CSV is malformed: {error}") from error
    return ObservationSummary(sample_count, process_row_count)


def _write_exclusive(path: Path, payload: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())


def _prepare_artifact_root(path: Path) -> Path:
    if not path.is_absolute():
        raise AuditInputError("artifact root must be absolute")
    if path.exists() or path.is_symlink():
        raise AuditInputError("refusing to overwrite the artifact root")
    try:
        parent = path.parent.resolve(strict=True)
    except OSError as error:
        raise AuditInputError(f"artifact root parent is unavailable: {error}") from error
    if parent != path.parent:
        raise AuditInputError("artifact root parent must be a canonical path")
    metadata = parent.lstat()
    if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise AuditInputError("artifact root parent must be a non-symlink directory")
    path.mkdir(mode=0o700)
    return path


def _one_exact_process(
    provider: ProcessProvider,
    expected_executable_path: str,
) -> ProcessIdentity:
    matches = provider(expected_executable_path)
    if len(matches) != 1:
        raise AuditInputError(
            "expected exactly one running process for the candidate executable, "
            f"found {len(matches)}"
        )
    identity = matches[0]
    if identity.pid <= 0 or identity.start_time_unix_us <= 0:
        raise AuditInputError("process identity is incomplete")
    if os.path.realpath(identity.executable_path) != expected_executable_path:
        raise AuditInputError("process executable path differs from the candidate app")
    return identity


def audit(
    *,
    candidate_identity_path: Path,
    app_bundle: Path,
    duration_seconds: int,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    process_provider: ProcessProvider = matching_processes,
    observer_runner: ObserverRunner = run_observer,
    observer_tool_path: Path = NETTOP_PATH,
) -> tuple[dict[str, object], int]:
    if not MIN_DURATION_SECONDS <= duration_seconds <= MAX_DURATION_SECONDS:
        raise AuditInputError(
            f"duration must be {MIN_DURATION_SECONDS}...{MAX_DURATION_SECONDS} seconds"
        )
    candidate, candidate_document_digest = load_candidate(candidate_identity_path)
    app = inspect_app(app_bundle, candidate)
    observer_path = _canonical_existing_path(
        observer_tool_path,
        label="nettop",
        directory=False,
    )
    observer_metadata = _regular_file(observer_path, label="nettop")
    if not observer_metadata.st_mode & stat.S_IXUSR:
        raise AuditInputError("nettop is not executable")
    observer_digest = file_sha256(observer_path)
    process_before = _one_exact_process(process_provider, app.executable_path)
    root = _prepare_artifact_root(artifact_root)
    started_at_unix_ms = time.time_ns() // 1_000_000
    argv, execution = observer_runner(process_before.pid, duration_seconds)
    ended_at_unix_ms = time.time_ns() // 1_000_000

    stdout = execution.stdout
    stderr = execution.stderr
    if len(stdout) > MAX_OBSERVER_STDOUT_BYTES:
        stdout = stdout[: MAX_OBSERVER_STDOUT_BYTES + 1]
    if len(stderr) > MAX_OBSERVER_STDERR_BYTES:
        stderr = stderr[: MAX_OBSERVER_STDERR_BYTES + 1]
    observation_path = root / OBSERVATION_NAME
    _write_exclusive(observation_path, stdout)

    expected_samples = duration_seconds + 1
    expected_argv = observer_argv(process_before.pid, duration_seconds)
    diagnostic: str | None = None
    summary: ObservationSummary | None = None
    availability = "available"
    result = "unavailable"
    exit_code = 1

    try:
        process_after = _one_exact_process(process_provider, app.executable_path)
    except AuditInputError as error:
        process_after = None
        diagnostic = f"process identity unavailable after observation: {error}"
    else:
        if process_after != process_before:
            diagnostic = "candidate process identity changed during observation"

    if diagnostic is None and argv != expected_argv:
        diagnostic = "observer command differs from the frozen read-only vector"
    if diagnostic is None:
        try:
            app_after = inspect_app(app_bundle, candidate)
        except AuditInputError as error:
            diagnostic = f"candidate app bundle changed during observation: {error}"
        else:
            if app_after != app:
                diagnostic = "candidate app bundle changed during observation"
    if diagnostic is None and file_sha256(observer_path) != observer_digest:
        diagnostic = "nettop changed during observation"
    if (
        diagnostic is None
        and file_sha256(candidate_identity_path) != candidate_document_digest
    ):
        diagnostic = "candidate identity document changed during observation"
    if diagnostic is None and execution.timed_out:
        diagnostic = "nettop exceeded the bounded observation timeout"
    if diagnostic is None and execution.returncode != 0:
        diagnostic = f"nettop exited {execution.returncode}"
    if diagnostic is None and len(execution.stdout) > MAX_OBSERVER_STDOUT_BYTES:
        diagnostic = "nettop output exceeded the fixed evidence bound"
    if diagnostic is None and len(execution.stderr) > MAX_OBSERVER_STDERR_BYTES:
        diagnostic = "nettop stderr exceeded the fixed evidence bound"
    if diagnostic is None and stderr:
        diagnostic = "nettop emitted an unexpected diagnostic"
    if diagnostic is None:
        try:
            summary = parse_observation(stdout, pid=process_before.pid)
        except AuditInputError as error:
            diagnostic = str(error)
    if diagnostic is None and summary is not None:
        if summary.sample_count != expected_samples:
            diagnostic = (
                "nettop did not emit the complete expected sample framing "
                f"({summary.sample_count}/{expected_samples})"
            )
        elif execution.elapsed_ms < max(0, (duration_seconds - 1) * 1_000):
            diagnostic = "nettop completed before the bounded observation window"
        elif summary.process_row_count:
            result = "failed"
            exit_code = 1
            diagnostic = (
                "observed candidate-owned non-loopback network state in "
                f"{summary.process_row_count} sample(s)"
            )
        else:
            result = "passed"
            exit_code = 0
    if result == "unavailable":
        availability = "unavailable"

    observation_digest = hashlib.sha256(stdout).hexdigest()
    execution_report = execution_report_document(
        argparse.Namespace(
            ended_at_unix_ms=int(ended_at_unix_ms),
            exit_code=None if result == "unavailable" else exit_code,
            result=result,
            started_at_unix_ms=int(started_at_unix_ms),
        ),
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
    )
    execution_report_path = root / EXECUTION_REPORT_NAME
    execution_publication = write_create_only(
        execution_report_path,
        execution_report,
    )
    report: dict[str, object] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "command_id": "installed.network-acquisition-audit",
        "evidence_layer": "installed-launch-log",
        "candidate": {
            "identity_sha256": candidate_identity_sha256(candidate),
            "document_sha256": candidate_document_digest,
            "source_commit": candidate.source.commit,
            "source_tree": candidate.source.tree,
        },
        "app": {
            "bundle_path": app.bundle_path,
            "bundle_identifier": app.bundle_identifier,
            "bundle_sha256": app.bundle_sha256,
            "closed_tree_sha256": app.closed_tree_sha256,
            "executable_path": app.executable_path,
            "executable_sha256": app.executable_sha256,
        },
        "process": {
            "pid": process_before.pid,
            "executable_path": process_before.executable_path,
            "start_time_unix_us": process_before.start_time_unix_us,
        },
        "observer": {
            "observer_id": OBSERVER_ID,
            "tool_path": str(observer_path),
            "tool_sha256": observer_digest,
            "argv_sha256": canonical_sha256(list(argv)),
            "interface_scope": ["external", "undefined"],
            "loopback_excluded": True,
            "sample_interval_ms": 1_000,
            "requested_duration_ms": duration_seconds * 1_000,
            "observed_duration_ms": execution.elapsed_ms,
            "expected_sample_count": expected_samples,
            "observed_sample_count": summary.sample_count if summary is not None else 0,
            "observed_process_row_count": (
                summary.process_row_count if summary is not None else 0
            ),
            "availability": availability,
            "limitation": (
                "nettop is a one-second per-process sampler; the receipt proves the "
                "recorded bounded samples, not packet-complete tracing between samples"
            ),
        },
        "environment": {
            "architecture": platform.machine(),
            "os_release": platform.release(),
            "platform": sys.platform,
            "subprocess": {
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            },
        },
        "artifacts": [
            {
                "relative_path": OBSERVATION_NAME,
                "kind": "network-observation",
                "media_type": "text/csv",
                "byte_count": len(stdout),
                "sha256": observation_digest,
            },
            {
                "relative_path": EXECUTION_REPORT_NAME,
                "kind": "execution-report",
                "media_type": "application/json",
                "byte_count": execution_publication.size,
                "sha256": execution_publication.sha256,
            },
        ],
        "started_at_unix_ms": int(started_at_unix_ms),
        "ended_at_unix_ms": int(ended_at_unix_ms),
        "result": result,
        "exit_code": exit_code,
        "diagnostic": diagnostic,
    }
    report_path = root / REPORT_NAME
    write_create_only(report_path, report)
    return report, exit_code


def audit_matrix_workload(
    *,
    candidate_identity_path: Path,
    app_bundle: Path,
    artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str,
    workload: Callable[[], tuple[T, Mapping[str, object]]],
    process_provider: ProcessProvider = matching_processes,
    observer_session_factory: ContinuousMatrixObserverFactory = start_matrix_observer,
    observer_tool_path: Path = NETTOP_PATH,
    watch_collector_factory: Callable | None = None,
    pid_census: Callable[[], tuple[int, ...]] | None = None,
) -> tuple[T, dict[str, object], int]:
    """Observe the exact installed matrix while it is the active workload.

    This is deliberately a callback seam, not an arbitrary command runner: the
    canonical matrix runner owns the one xcodebuild vector and supplies it here.
    """
    candidate, candidate_document_digest = load_candidate(candidate_identity_path)
    authorities = inspect_candidate_executables(app_bundle, candidate)
    observer_path = _canonical_existing_path(observer_tool_path, label="nettop", directory=False)
    observer_digest = file_sha256(observer_path)
    root = _prepare_artifact_root(artifact_root)
    diagnostic: list[str] = []
    for authority in authorities:
        if file_sha256(Path(authority.executable_path)) != authority.executable_sha256:
            raise AuditInputError(
                f"candidate executable drifted before matrix: {authority.identity_id}"
            )
    identities_before = _candidate_process_snapshot(authorities, process_provider)
    watcher = (watch_collector_factory or ProcessWatchCollector)([a.executable_path for a in authorities])
    session = None
    session_finished = False
    watch_result = None
    try:
        watcher.arm((pid_census or _all_process_ids)())
        session = observer_session_factory()
        if session.argv != matrix_observer_argv():
            raise AuditInputError("matrix observer command differs from the frozen continuous vector")
        if (
            session.ready_at_unix_ms < session.started_at_unix_ms
            or session.readiness_frame_sha256 != hashlib.sha256(MATRIX_OBSERVER_READY_FRAME).hexdigest()
        ):
            raise AuditInputError("continuous matrix observer readiness is not attested by its first valid frame")
        watcher.observer_started(session.observer_spawn_ns)
        observation_started_ms = session.started_at_unix_ms
        observation_ready_ms = session.ready_at_unix_ms
        workload_started_ms = time.time_ns() // 1_000_000
        if observation_ready_ms > workload_started_ms:
            raise AuditInputError("continuous matrix observer was not ready before the workload")
        # One queue owner: leave EXEC/EXIT latched during the callback. The
        # observer's separate bounded PTY reader continuously drains all CSV.
        try:
            workload_result, workload_evidence = workload()
        finally:
            workload_ended_ms = time.time_ns() // 1_000_000
            session_finished = True
            execution = session.finish()
        observation_ended_ms = time.time_ns() // 1_000_000
        try:
            _, used_pids = _matrix_row_pids(execution.stdout)
        except AuditInputError as error:
            used_pids = ()
            diagnostic.append(str(error))
        try:
            watcher.observer_eof(execution.observer_eof_ns)
            watch_result = watcher.finalize(sorted(set(used_pids)))
            if not watch_result.healthy:
                diagnostic.append("process watcher did not retain a healthy whole-session bracket")
        except (ProcessWatchError, OSError) as error:
            diagnostic.append(f"process watch finalization unavailable: {error}")
    finally:
        try:
            if session is not None and not session_finished:
                session_finished = True
                session.finish()
        finally:
            watcher.close()
            if watch_result is None:
                watch_result = watcher.failure_snapshot()
    attribution = {
        "policy_id": PROOF_KIND,
        "observer_spawn_ns": watch_result.observer_spawn_ns if watch_result else session.observer_spawn_ns,
        "observer_eof_ns": watch_result.observer_eof_ns if watch_result else execution.observer_eof_ns,
        "queue_closed_ns": watch_result.queue_closed_ns if watch_result else None,
        "proofs": list(watch_result.proofs) if watch_result and watch_result.healthy else [],
        "drains": list(watch_result.drains) if watch_result else [],
    }
    try:
        identities_after = _candidate_process_snapshot(authorities, process_provider)
        identities_by_pid = _merge_candidate_process_snapshots(
            identities_before, identities_after
        )
    except AuditInputError as error:
        identities_by_pid = dict(identities_before)
        diagnostic.append(str(error))
    try:
        foreign_pids = validate_foreign_proofs(
            attribution["proofs"], attribution["drains"],
            observer_spawn_ns=attribution["observer_spawn_ns"], observer_eof_ns=attribution["observer_eof_ns"],
            queue_closed_ns=attribution["queue_closed_ns"], candidate_paths=[a.executable_path for a in authorities],
        )
        summary = classify_matrix_observation(
            execution.stdout, candidate_pids=frozenset(identities_by_pid), foreign_pids=foreign_pids,
        )
    except (AuditInputError, NetworkAttributionError) as error:
        summary = MatrixObservationSummary(0, 0, 0, 0, 0)
        diagnostic.append(str(error))
    if len(execution.stdout) > MAX_OBSERVER_STDOUT_BYTES:
        diagnostic.append("continuous matrix observation exceeds the fixed evidence bound")
    if execution.timed_out or execution.stderr:
        diagnostic.append("continuous matrix observer was unavailable")
    # A continuous observer is authoritative only when this audit owns its
    # termination after the workload returns.  A zero exit status does not
    # establish that an unbounded ``nettop`` session stayed alive for the full
    # interval, so any premature exit is unavailable evidence.
    if not execution.stopped_by_auditor:
        diagnostic.append("continuous matrix observer exited before the workload closed")
    if execution.stopped_by_auditor and execution.returncode not in {0, -15}:
        diagnostic.append("continuous matrix observer did not stop cleanly")
    try:
        authorities_after = inspect_candidate_executables(app_bundle, candidate)
    except AuditInputError as error:
        diagnostic.append(f"candidate app bundle drifted during matrix: {error}")
    else:
        if authorities_after != authorities:
            diagnostic.append("candidate executable authority drifted during matrix")
    required_evidence_fields = {
        "matrix_receipt_sha256",
        "xcresult_bundle_sha256",
        "xcresult_closed_tree_sha256",
        "selector_catalog_sha256",
        "selector_projection_sha256",
        "xcresult_semantic_manifest_sha256",
        "expected_selector_count",
        "executed_selector_count",
        "passed_selector_count",
        "failed_selector_count",
        "skipped_selector_count",
        "matrix_result",
    }
    if set(workload_evidence) != required_evidence_fields:
        diagnostic.append("matrix workload evidence does not carry its exact closed field set")
    overlap_is_complete = observation_contains_workload(
        observation_started_ms,
        workload_started_ms,
        workload_ended_ms,
        observation_ended_ms,
    )
    if not overlap_is_complete:
        diagnostic.append("network observation did not contain the exact matrix workload interval")
    if summary.sample_count == 0:
        diagnostic.append("network observation captured no candidate-bound sample")
    if summary.candidate_row_count:
        diagnostic.append("observed candidate-owned non-loopback network state")
    if summary.unresolved_row_count:
        diagnostic.append("observed process rows without prearmed foreign or exact candidate authority")
    if file_sha256(candidate_identity_path) != candidate_document_digest:
        diagnostic.append("candidate identity document changed during matrix observation")
    if file_sha256(observer_path) != observer_digest:
        diagnostic.append("nettop changed during matrix observation")
    if not (observation_started_ms <= workload_started_ms < workload_ended_ms <= observation_ended_ms):
        diagnostic.append("continuous matrix observer interval did not enclose the workload")
    if not (
        observation_started_ms
        <= observation_ready_ms
        <= workload_started_ms
        < workload_ended_ms
        <= observation_ended_ms
    ):
        diagnostic.append("continuous matrix observer readiness did not enclose the workload")
    try:
        minimum_frame_count = _minimum_continuous_frame_count(
            observation_ready_ms, observation_ended_ms
        )
    except AuditInputError as error:
        minimum_frame_count = 0
        diagnostic.append(str(error))
    if summary.sample_count < minimum_frame_count:
        diagnostic.append("continuous matrix observation has an unproven sample-frame gap")
    if set(workload_evidence) == required_evidence_fields:
        integer_counts = (
            workload_evidence["expected_selector_count"],
            workload_evidence["executed_selector_count"],
            workload_evidence["passed_selector_count"],
            workload_evidence["failed_selector_count"],
            workload_evidence["skipped_selector_count"],
        )
        if (
            workload_evidence["matrix_result"] != "passed"
            or workload_evidence["selector_projection_sha256"]
            != canonical_sha256(
                installed_selector_projection(load_installed_selector_catalog())
            )
            or any(type(value) is not int or value < 0 for value in integer_counts)
            or integer_counts[0] != 22
            or integer_counts[1:] != (22, 22, 0, 0)
        ):
            diagnostic.append("installed matrix did not execute and pass all 22 selectors")

    result = "passed" if not diagnostic else ("failed" if summary.candidate_row_count else "unavailable")
    exit_code = 0 if result == "passed" else 1
    observation_path = root / OBSERVATION_NAME
    observation_bytes = execution.stdout
    _write_exclusive(observation_path, observation_bytes)
    observation_sha256 = hashlib.sha256(observation_bytes).hexdigest()
    execution_report = execution_report_document(
        argparse.Namespace(
            ended_at_unix_ms=int(observation_ended_ms),
            exit_code=None if result == "unavailable" else exit_code,
            result=result,
            started_at_unix_ms=int(observation_started_ms),
        ),
        qualification_run=qualification_run,
        predecessor_observations_sha256=predecessor_observations_sha256,
    )
    execution_path = root / EXECUTION_REPORT_NAME
    write_create_only(execution_path, execution_report)
    report: dict[str, object] = {
        "schema_version": MATRIX_REPORT_SCHEMA_VERSION,
        "command_id": "installed.network-acquisition-audit",
        "evidence_layer": "installed-launch-log",
        "candidate": {
            "identity_sha256": candidate_identity_sha256(candidate),
            "document_sha256": candidate_document_digest,
            "source_commit": candidate.source.commit,
            "source_tree": candidate.source.tree,
        },
        "workload": {
            "command_id": "installed.task10-workflow",
            "started_at_unix_ms": int(workload_started_ms),
            "ended_at_unix_ms": int(workload_ended_ms),
            "observer_ready_at_unix_ms": int(observation_ready_ms),
            "observer_readiness_precedes_workload": observation_ready_ms <= workload_started_ms,
            "observation_contains_workload": overlap_is_complete,
            **dict(workload_evidence),
        },
        "executables": [
            {
                "identity_id": authority.identity_id,
                "executable_path": authority.executable_path,
                "executable_sha256": authority.executable_sha256,
                "processes": [
                    {
                        "pid": identity.pid,
                        "start_time_unix_us": identity.start_time_unix_us,
                    }
                    for _pid, (role, identity) in sorted(identities_by_pid.items())
                    if role == authority.identity_id
                ],
            }
            for authority in authorities
        ],
        "attribution": attribution,
        "observer": {
            "observer_id": MATRIX_OBSERVER_ID,
            "evidence_scope": MATRIX_EVIDENCE_SCOPE,
            "limitations": list(MATRIX_LIMITATIONS),
            "tool_path": str(observer_path),
            "tool_sha256": observer_digest,
            "interface_scope": ["external", "undefined"],
            "loopback_excluded": True,
            "observed_sample_count": summary.sample_count,
            "observed_process_row_count": summary.process_row_count,
            "observed_candidate_row_count": summary.candidate_row_count,
            "observed_foreign_row_count": summary.foreign_row_count,
            "observed_unresolved_row_count": summary.unresolved_row_count,
            "observer_invocation_count": 1,
            "continuous_interval_started_at_unix_ms": observation_started_ms,
            "continuous_interval_ready_at_unix_ms": observation_ready_ms,
            "continuous_interval_ended_at_unix_ms": observation_ended_ms,
            "readiness_frame_sha256": session.readiness_frame_sha256,
            "readiness_proven": session.ready_at_unix_ms >= session.started_at_unix_ms,
            "stopped_by_auditor": execution.stopped_by_auditor,
            "continuity_proven": not diagnostic,
            "observation_byte_count": len(observation_bytes),
            "observation_sha256": observation_sha256,
            "availability": "available" if result != "unavailable" else "unavailable",
        },
        "artifacts": [],
        "started_at_unix_ms": int(observation_started_ms),
        "ended_at_unix_ms": int(observation_ended_ms),
        "result": result,
        "exit_code": exit_code,
        "diagnostic": "; ".join(diagnostic) if diagnostic else None,
    }
    report_path = root / REPORT_NAME
    if len(canonical_bytes(report)) > MAX_MATRIX_REPORT_BYTES:
        raise AuditInputError("whole network audit report exceeds the fixed 4 MiB bound")
    write_create_only(report_path, report)
    return workload_result, report, exit_code


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Audit one exact installed MacScope PID for non-loopback network acquisition"
    )
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--app-bundle", type=Path, required=True)
    parser.add_argument("--duration-seconds", type=int, default=30)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        run_authority = qualification_run_authority(arguments)
        report, exit_code = audit(
            candidate_identity_path=arguments.candidate_identity,
            app_bundle=arguments.app_bundle,
            duration_seconds=arguments.duration_seconds,
            artifact_root=arguments.artifact_root,
            qualification_run=run_authority,
            predecessor_observations_sha256=(
                arguments.predecessor_observations_sha256
            ),
        )
    except (AuditInputError, CanonicalJSONError, OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"MACSCOPE_INSTALLED_NETWORK_AUDIT_REPORT="
        f"{arguments.artifact_root / REPORT_NAME}"
    )
    print(
        f"MACSCOPE_INSTALLED_NETWORK_AUDIT_EXECUTION_REPORT="
        f"{arguments.artifact_root / EXECUTION_REPORT_NAME}"
    )
    print(
        f"MACSCOPE_INSTALLED_NETWORK_AUDIT_OBSERVATION="
        f"{arguments.artifact_root / OBSERVATION_NAME}"
    )
    if report["diagnostic"] is not None:
        print(f"network audit {report['result']}: {report['diagnostic']}", file=sys.stderr)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
