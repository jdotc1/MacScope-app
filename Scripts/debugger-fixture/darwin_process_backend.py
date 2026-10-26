#!/usr/bin/env python3
"""Bounded Darwin substrate for the WS-18 exact-process supervisor.

Only explicitly claimed PID/path pairs are inspectable.  Signalling is limited
to SIGTERM against an existing ``ProcessRegistry`` entry after a fresh exact
identity capture.  There is intentionally no basename lookup, PID discovery,
process-group signalling, or generic kill-by-pattern API in this module.
"""

from __future__ import annotations

import ctypes
import errno
import hashlib
import os
import re
import signal
import stat
import struct
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, Mapping, Optional, Protocol, Sequence, Tuple

from process_supervisor import (
    GracefulAction,
    ImmutableProcessIdentity,
    InspectionState,
    ProcessAnchor,
    ProcessInspector,
    ProcessRegistry,
    ProcessRole,
    ProcessSnapshot,
    ProcessTopology,
    RegisteredProcess,
    exact_descendant_ancestry,
)


PROC_PIDTBSDINFO = 3
PROC_PIDARCHINFO = 19
PROC_PIDPATHINFO_MAXSIZE = 4096
PROC_CHILD_PID_BYTES = ctypes.sizeof(ctypes.c_int32)
PROC_FLAG_TRACED = 0x00000002
SZOMB = 5
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0xFF000000
LC_UUID = 0x1B


class DarwinBackendError(RuntimeError):
    """Fail-closed Darwin identity inspection error."""


class _ChildIdentityRace(DarwinBackendError):
    """One discardable child A-B-A mismatch inside a bounded enumeration."""


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
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


class _ProcArchInfo(ctypes.Structure):
    _fields_ = [
        ("p_cputype", ctypes.c_int32),
        ("p_cpusubtype", ctypes.c_int32),
    ]


@dataclass(frozen=True)
class BSDProcessInfo:
    pid: int
    parent_pid: int
    process_group: int
    effective_uid: int
    real_uid: int
    flags: int
    status: int
    start_seconds: int
    start_microseconds: int


@dataclass(frozen=True)
class DarwinProcessArchitecture:
    cpu_type: int
    cpu_subtype: int


class DarwinProcessAPI(Protocol):
    def bsd_info(self, pid: int) -> BSDProcessInfo:
        ...

    def pid_path(self, pid: int) -> str:
        ...

    def session_id(self, pid: int) -> int:
        ...

    def child_pids(self, parent_pid: int, capacity: int) -> Tuple[int, ...]:
        ...

    def architecture(self, pid: int) -> DarwinProcessArchitecture:
        ...


class DarwinLibprocAPI:
    """Narrow ctypes wrapper around public libproc process inspection APIs."""

    def __init__(self, library: Optional[object] = None):
        if library is None:
            if os.uname().sysname != "Darwin":
                raise OSError("libproc process inspection requires Darwin")
            library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self._library = library
        self._library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self._library.proc_pidinfo.restype = ctypes.c_int
        self._library.proc_pidpath.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_uint32,
        ]
        self._library.proc_pidpath.restype = ctypes.c_int
        self._library.proc_listchildpids.argtypes = [
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        self._library.proc_listchildpids.restype = ctypes.c_int

    @staticmethod
    def _raise_for_errno(pid: int, operation: str) -> None:
        error_number = ctypes.get_errno()
        message = f"{operation}({pid}) failed: {os.strerror(error_number or errno.EIO)}"
        if error_number == errno.ESRCH:
            raise ProcessLookupError(error_number, message)
        if error_number in (errno.EPERM, errno.EACCES):
            raise PermissionError(error_number, message)
        raise OSError(error_number or errno.EIO, message)

    def bsd_info(self, pid: int) -> BSDProcessInfo:
        if pid <= 0:
            raise ValueError("PID must be positive")
        record = _ProcBSDInfo()
        ctypes.set_errno(0)
        size = self._library.proc_pidinfo(
            pid,
            PROC_PIDTBSDINFO,
            0,
            ctypes.byref(record),
            ctypes.sizeof(record),
        )
        if size <= 0:
            self._raise_for_errno(pid, "proc_pidinfo")
        if size != ctypes.sizeof(record):
            raise DarwinBackendError(
                f"short proc_pidinfo result for PID {pid}: {size}/{ctypes.sizeof(record)}"
            )
        if int(record.pbi_pid) != pid:
            raise DarwinBackendError("proc_pidinfo returned a different PID")
        return BSDProcessInfo(
            pid,
            int(record.pbi_ppid),
            int(record.pbi_pgid),
            int(record.pbi_uid),
            int(record.pbi_ruid),
            int(record.pbi_flags),
            int(record.pbi_status),
            int(record.pbi_start_tvsec),
            int(record.pbi_start_tvusec),
        )

    def pid_path(self, pid: int) -> str:
        if pid <= 0:
            raise ValueError("PID must be positive")
        buffer = ctypes.create_string_buffer(PROC_PIDPATHINFO_MAXSIZE)
        ctypes.set_errno(0)
        size = self._library.proc_pidpath(pid, buffer, len(buffer))
        if size <= 0:
            self._raise_for_errno(pid, "proc_pidpath")
        if size >= len(buffer):
            raise DarwinBackendError("proc_pidpath result exceeds configured bound")
        raw = bytes(buffer.raw[:size]).split(b"\0", 1)[0]
        try:
            path = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise DarwinBackendError("proc_pidpath returned non-UTF-8 path") from error
        if not path.startswith("/"):
            raise DarwinBackendError("proc_pidpath did not return an absolute path")
        return path

    def architecture(self, pid: int) -> DarwinProcessArchitecture:
        if pid <= 0:
            raise ValueError("PID must be positive")
        record = _ProcArchInfo()
        ctypes.set_errno(0)
        size = self._library.proc_pidinfo(
            pid,
            PROC_PIDARCHINFO,
            0,
            ctypes.byref(record),
            ctypes.sizeof(record),
        )
        if size <= 0:
            self._raise_for_errno(pid, "proc_pidinfo")
        if size != ctypes.sizeof(record):
            raise DarwinBackendError(
                f"short architecture proc_pidinfo result for PID {pid}: "
                f"{size}/{ctypes.sizeof(record)}"
            )
        if int(record.p_cputype) <= 0:
            raise DarwinBackendError("proc_pidinfo returned an invalid process architecture")
        return DarwinProcessArchitecture(
            int(record.p_cputype), int(record.p_cpusubtype)
        )

    def session_id(self, pid: int) -> int:
        return os.getsid(pid)

    def child_pids(self, parent_pid: int, capacity: int) -> Tuple[int, ...]:
        """Return at most ``capacity`` direct children of one exact parent PID."""

        if parent_pid <= 0 or capacity <= 0:
            raise ValueError("parent PID and child capacity must be positive")
        if capacity > 4096:
            raise ValueError("child capacity exceeds the libproc safety bound")
        buffer_type = ctypes.c_int32 * capacity
        buffer = buffer_type()
        ctypes.set_errno(0)
        count = self._library.proc_listchildpids(
            parent_pid,
            ctypes.byref(buffer),
            ctypes.sizeof(buffer),
        )
        if count < 0:
            self._raise_for_errno(parent_pid, "proc_listchildpids")
        if count > capacity:
            raise DarwinBackendError("proc_listchildpids exceeded supplied capacity")
        result = tuple(int(buffer[index]) for index in range(count))
        if any(pid <= 0 for pid in result) or len(set(result)) != len(result):
            raise DarwinBackendError("proc_listchildpids returned invalid child PIDs")
        return result


@dataclass(frozen=True)
class ExactChildObservation:
    """Stable parent/start/path evidence for one direct adapter child."""

    pid: int
    parent_pid: int
    start_seconds: int
    start_microseconds: int
    canonical_path: str


class DarwinExactChildEnumerator:
    """Bounded, race-detecting direct-child enumeration for a registered adapter.

    This is deliberately not a system-wide discovery API.  It accepts only the
    registry's exact adapter registration and never searches by executable name.
    """

    def __init__(
        self,
        process_api: DarwinProcessAPI,
        registry: ProcessRegistry,
        inspector: ProcessInspector,
        *,
        initial_capacity: int = 4,
        max_children: int = 256,
        max_attempts: int = 3,
        retry_interval_seconds: float = 0.025,
        retry_sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        if initial_capacity <= 0 or max_children < initial_capacity:
            raise ValueError("invalid child enumeration capacity")
        if max_attempts <= 0:
            raise ValueError("child enumeration attempts must be positive")
        if not 0.0 < retry_interval_seconds <= 1.0:
            raise ValueError("child enumeration retry interval is outside safety bounds")
        self._process_api = process_api
        self._registry = registry
        self._inspector = inspector
        self._initial_capacity = initial_capacity
        self._max_children = max_children
        self._max_attempts = max_attempts
        self._retry_interval_seconds = retry_interval_seconds
        self._retry_sleeper = retry_sleeper

    def _registration_is_exact(
        self, registration: RegisteredProcess, role: ProcessRole,
    ) -> bool:
        if registration.identity.role is not role:
            return False
        try:
            recorded = self._registry.lookup(registration.process_key)
        except KeyError:
            return False
        snapshot = self._inspector.capture(registration.identity.pid)
        return (
            recorded == registration
            and snapshot.state is InspectionState.EXACT
            and snapshot.identity == registration.identity
        )

    def _adapter_is_exact(self, registration: RegisteredProcess) -> bool:
        return self._registration_is_exact(registration, ProcessRole.ADAPTER)

    def _debugserver_is_exact(self, registration: RegisteredProcess) -> bool:
        if not self._registration_is_exact(
                registration, ProcessRole.LOCAL_DEBUGSERVER):
            return False
        try:
            adapter = self._registry.by_role(ProcessRole.ADAPTER)
        except KeyError:
            return False
        return (
            self._adapter_is_exact(adapter)
            and exact_descendant_ancestry(
                registration.identity, adapter.identity,
                registration.admission_ancestry,
            )
        )

    def _child_pid_snapshot(self, parent_pid: int) -> Tuple[int, ...]:
        capacity = self._initial_capacity
        while True:
            child_pids = self._process_api.child_pids(parent_pid, capacity)
            if len(child_pids) < capacity:
                return tuple(sorted(child_pids))
            if capacity >= self._max_children:
                raise DarwinBackendError("child PID buffer remained saturated at safety bound")
            capacity = min(capacity * 2, self._max_children)

    def _capture_child(self, pid: int, parent_pid: int) -> ExactChildObservation:
        before = self._process_api.bsd_info(pid)
        before_path = os.path.realpath(self._process_api.pid_path(pid))
        after = self._process_api.bsd_info(pid)
        after_path = os.path.realpath(self._process_api.pid_path(pid))
        if (
            before.pid != pid
            or after.pid != pid
            or before.parent_pid != parent_pid
            or after.parent_pid != parent_pid
            or before.start_seconds != after.start_seconds
            or before.start_microseconds != after.start_microseconds
            or before_path != after_path
            or not before_path.startswith("/")
        ):
            raise _ChildIdentityRace(
                "child identity changed during bounded enumeration: "
                f"requestedPID={pid} "
                f"beforePID={before.pid} afterPID={after.pid} "
                f"beforeParent={before.parent_pid} afterParent={after.parent_pid} "
                f"expectedParent={parent_pid} "
                f"beforeStart={before.start_seconds}.{before.start_microseconds:06d} "
                f"afterStart={after.start_seconds}.{after.start_microseconds:06d} "
                f"beforePath={before_path!r} afterPath={after_path!r}"
            )
        return ExactChildObservation(
            pid,
            parent_pid,
            before.start_seconds,
            before.start_microseconds,
            before_path,
        )

    @staticmethod
    def _validated_excluded_pids(excluded_pids: Sequence[int]) -> frozenset[int]:
        try:
            values = tuple(excluded_pids)
        except TypeError as error:
            raise ValueError("excluded PIDs must be positive integers") from error
        if any(type(pid) is not int or pid <= 0 for pid in values):
            raise ValueError("excluded PIDs must be positive integers")
        return frozenset(values)

    def enumerate(
        self,
        adapter: RegisteredProcess,
        *,
        excluded_pids: Sequence[int] = (),
    ) -> Tuple[ExactChildObservation, ...]:
        return self._enumerate_exact_parent(
            adapter, self._adapter_is_exact, "adapter", excluded_pids)

    def enumerate_debugserver_children(
        self,
        debugserver: RegisteredProcess,
        *,
        excluded_pids: Sequence[int] = (),
    ) -> Tuple[ExactChildObservation, ...]:
        """Enumerate children of one exact adapter-owned debugserver only."""
        return self._enumerate_exact_parent(
            debugserver, self._debugserver_is_exact, "debugserver", excluded_pids)

    def _enumerate_exact_parent(
        self,
        parent: RegisteredProcess,
        validator: Callable[[RegisteredProcess], bool],
        subject: str,
        excluded_pids: Sequence[int],
    ) -> Tuple[ExactChildObservation, ...]:
        exclusions = self._validated_excluded_pids(excluded_pids)
        if not validator(parent):
            raise PermissionError(
                "child enumeration requires the exact registered " + subject)
        last_race: Optional[DarwinBackendError] = None
        for attempt in range(self._max_attempts):
            if attempt > 0 and not validator(parent):
                raise DarwinBackendError(
                    subject + " identity changed during child enumeration")
            before = tuple(
                pid
                for pid in self._child_pid_snapshot(parent.identity.pid)
                if pid not in exclusions
            )
            child_race: Optional[_ChildIdentityRace] = None
            try:
                observations = tuple(
                    self._capture_child(pid, parent.identity.pid) for pid in before
                )
            except _ChildIdentityRace as error:
                observations = ()
                child_race = error
            after = tuple(
                pid
                for pid in self._child_pid_snapshot(parent.identity.pid)
                if pid not in exclusions
            )
            if not validator(parent):
                raise DarwinBackendError(
                    subject + " identity changed during child enumeration")
            if child_race is not None:
                last_race = child_race if before == after else DarwinBackendError(
                    "child PID set raced during bounded enumeration"
                )
            elif before == after:
                return observations
            else:
                last_race = DarwinBackendError(
                    "child PID set raced during bounded enumeration"
                )
            if attempt + 1 < self._max_attempts:
                self._retry_sleeper(self._retry_interval_seconds)
        assert last_race is not None
        raise last_race


@dataclass(frozen=True)
class SelectedProcessClaim:
    pid: int
    canonical_path: str
    nonce: str
    role: ProcessRole
    expected_executable_identity: str = ""

    def __post_init__(self) -> None:
        if self.pid <= 0 or not self.nonce:
            raise ValueError("selected process claim requires PID and nonce")
        canonical = os.path.realpath(self.canonical_path)
        if not canonical.startswith("/") or canonical != self.canonical_path:
            raise ValueError("selected process claim requires a canonical absolute path")
        if self.expected_executable_identity:
            _validate_executable_identity(self.expected_executable_identity)
        if self.role in {ProcessRole.ATTACHED_HELPER, ProcessRole.LAUNCHED_TARGET}:
            if not self.expected_executable_identity:
                raise ValueError(
                    "selected fixture target requires accepted executable identity"
                )


class SelectedProcessClaims:
    """Append-only exact PID/path authorization for one probe run."""

    def __init__(self) -> None:
        self._claims: Dict[int, SelectedProcessClaim] = {}
        self._roles: Dict[ProcessRole, int] = {}
        self._lock = threading.Lock()

    def add(self, claim: SelectedProcessClaim) -> None:
        with self._lock:
            existing_claim = self._claims.get(claim.pid)
            if existing_claim is not None:
                if (
                    existing_claim == claim
                    and self._roles.get(claim.role) == claim.pid
                ):
                    return
                raise ValueError("selected PID reuse is forbidden")
            if claim.role in self._roles:
                raise ValueError("selected process role reuse is forbidden")
            self._claims[claim.pid] = claim
            self._roles[claim.role] = claim.pid

    def exact(self, pid: int, canonical_path: str) -> SelectedProcessClaim:
        with self._lock:
            claim = self._claims.get(pid)
        if claim is None:
            raise PermissionError(f"PID {pid} was not selected by this WS-18 run")
        if claim.canonical_path != canonical_path:
            raise PermissionError("selected PID executable path changed")
        return claim


@dataclass(frozen=True)
class MachOIdentity:
    cpu_type: int
    cpu_subtype: int
    macho_uuid: str


def _validate_executable_identity(value: str) -> str:
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise ValueError("executable identity must be canonical sha256:<lowercase-hex>")
    return value


@dataclass(frozen=True)
class ExecutableContentEvidence:
    sha256: str
    executable_identity: str
    byte_count: int

    def __post_init__(self) -> None:
        if not re.fullmatch(r"[0-9a-f]{64}", self.sha256):
            raise ValueError("SHA-256 digest must be lowercase hexadecimal")
        _validate_executable_identity(self.executable_identity)
        if self.executable_identity != "sha256:" + self.sha256:
            raise ValueError("executable identity and digest disagree")
        if self.byte_count <= 0:
            raise ValueError("executable content must not be empty")


class ExecutableContentReader:
    """Hash and retain one bounded executable through an already-open file descriptor."""

    def __init__(self, max_file_bytes: int = 64 * 1024 * 1024):
        if max_file_bytes <= 0:
            raise ValueError("executable read bound must be positive")
        self._max_file_bytes = max_file_bytes

    def read_fd(self, descriptor: int) -> Tuple[bytes, ExecutableContentEvidence]:
        if descriptor < 0:
            raise ValueError("valid executable file descriptor is required")
        chunks = []
        offset = 0
        digest = hashlib.sha256()
        while offset <= self._max_file_bytes:
            chunk = os.pread(
                descriptor,
                min(1024 * 1024, self._max_file_bytes + 1 - offset),
                offset,
            )
            if not chunk:
                break
            chunks.append(chunk)
            digest.update(chunk)
            offset += len(chunk)
        if offset == 0:
            raise DarwinBackendError("selected executable is empty")
        if offset > self._max_file_bytes:
            raise DarwinBackendError("selected executable exceeds configured content bound")
        sha256 = digest.hexdigest()
        return b"".join(chunks), ExecutableContentEvidence(
            sha256, "sha256:" + sha256, offset
        )


@dataclass(frozen=True)
class DarwinImmutableProcessIdentity(ImmutableProcessIdentity):
    """Supervisor identity extended with exact executable-byte identity."""

    executable_identity: str

    def __post_init__(self) -> None:
        super().__post_init__()
        _validate_executable_identity(self.executable_identity)


class MachOIdentityReader:
    """Bounded parser for thin or universal Mach-O executable identity."""

    def __init__(self, max_file_bytes: int = 64 * 1024 * 1024):
        if max_file_bytes <= 0:
            raise ValueError("Mach-O read bound must be positive")
        self._max_file_bytes = max_file_bytes

    def inspect(
        self,
        path: str,
        expected_architecture: Optional[DarwinProcessArchitecture] = None,
    ) -> MachOIdentity:
        with open(path, "rb", buffering=0) as stream:
            data = stream.read(self._max_file_bytes + 1)
        if len(data) > self._max_file_bytes:
            raise DarwinBackendError("Mach-O exceeds configured inspection bound")
        return self.inspect_bytes(data, expected_architecture)

    def inspect_bytes(
        self,
        data: bytes,
        expected_architecture: Optional[DarwinProcessArchitecture] = None,
    ) -> MachOIdentity:
        if len(data) < 4:
            raise DarwinBackendError("short Mach-O header")
        magic = data[:4]
        if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            return self._inspect_fat(
                data,
                is_64=magic == b"\xca\xfe\xba\xbf",
                expected_architecture=expected_architecture,
            )
        if magic in (b"\xbe\xba\xfe\xca", b"\xbf\xba\xfe\xca"):
            raise DarwinBackendError("byte-swapped universal Mach-O is unsupported")
        result = self._inspect_thin(data)
        self._require_running_architecture(result, expected_architecture)
        return result

    @staticmethod
    def _base_cpu_subtype(cpu_subtype: int) -> int:
        return ctypes.c_uint32(cpu_subtype).value & ~CPU_SUBTYPE_MASK

    def _require_running_architecture(
        self,
        identity: MachOIdentity,
        expected_architecture: Optional[DarwinProcessArchitecture],
    ) -> None:
        if expected_architecture is None:
            return
        if (
            expected_architecture.cpu_type != CPU_TYPE_ARM64
            or identity.cpu_type != expected_architecture.cpu_type
            or self._base_cpu_subtype(identity.cpu_subtype)
            != self._base_cpu_subtype(expected_architecture.cpu_subtype)
        ):
            raise DarwinBackendError(
                "selected Mach-O slice does not match running architecture"
            )

    def _inspect_fat(
        self,
        data: bytes,
        *,
        is_64: bool,
        expected_architecture: Optional[DarwinProcessArchitecture],
    ) -> MachOIdentity:
        if len(data) < 8:
            raise DarwinBackendError("short universal Mach-O header")
        count = struct.unpack_from(">I", data, 4)[0]
        if count == 0 or count > 64:
            raise DarwinBackendError("invalid universal Mach-O architecture count")
        format_string = ">iiQQII" if is_64 else ">iiIII"
        entry_size = struct.calcsize(format_string)
        table_end = 8 + count * entry_size
        if table_end > len(data):
            raise DarwinBackendError("truncated universal Mach-O architecture table")
        candidates = []
        for index in range(count):
            fields = struct.unpack_from(format_string, data, 8 + index * entry_size)
            cpu_type = fields[0]
            cpu_subtype = fields[1]
            offset = int(fields[2])
            size = int(fields[3])
            if offset < table_end or size <= 0 or offset + size > len(data):
                raise DarwinBackendError("invalid universal Mach-O slice bounds")
            if cpu_type == CPU_TYPE_ARM64:
                if expected_architecture is None or (
                    expected_architecture.cpu_type == CPU_TYPE_ARM64
                    and self._base_cpu_subtype(cpu_subtype)
                    == self._base_cpu_subtype(expected_architecture.cpu_subtype)
                ):
                    candidates.append((offset, size, cpu_subtype))
        if len(candidates) > 1:
            raise DarwinBackendError("ambiguous ARM64 Mach-O slices")
        if not candidates:
            if expected_architecture is None:
                raise DarwinBackendError("universal Mach-O has no ARM64 slice")
            raise DarwinBackendError(
                "universal Mach-O has no matching ARM64 base-subtype slice"
            )
        offset, size, table_subtype = candidates[0]
        result = self._inspect_thin(data[offset : offset + size])
        if self._base_cpu_subtype(result.cpu_subtype) != self._base_cpu_subtype(
            table_subtype
        ):
            raise DarwinBackendError(
                "universal Mach-O table and selected slice architecture disagree"
            )
        self._require_running_architecture(result, expected_architecture)
        return result

    def _inspect_thin(self, data: bytes) -> MachOIdentity:
        magic = data[:4]
        if magic == b"\xcf\xfa\xed\xfe":
            endian, header_format = "<", "IiiIIIII"
        elif magic == b"\xfe\xed\xfa\xcf":
            endian, header_format = ">", "IiiIIIII"
        elif magic == b"\xce\xfa\xed\xfe":
            endian, header_format = "<", "IiiIIII"
        elif magic == b"\xfe\xed\xfa\xce":
            endian, header_format = ">", "IiiIIII"
        else:
            raise DarwinBackendError("not a supported Mach-O executable")
        header_size = struct.calcsize(endian + header_format)
        if len(data) < header_size:
            raise DarwinBackendError("truncated Mach-O header")
        fields = struct.unpack_from(endian + header_format, data, 0)
        cpu_type, cpu_subtype, command_count, commands_size = (
            int(fields[1]),
            int(fields[2]),
            int(fields[4]),
            int(fields[5]),
        )
        if cpu_type != CPU_TYPE_ARM64:
            raise DarwinBackendError("selected executable is not ARM64")
        if command_count > 100_000 or commands_size > len(data) - header_size:
            raise DarwinBackendError("invalid Mach-O load-command bounds")
        offset = header_size
        command_end = header_size + commands_size
        found_uuid: Optional[str] = None
        for _ in range(command_count):
            if offset + 8 > command_end:
                raise DarwinBackendError("truncated Mach-O load command")
            command, command_size = struct.unpack_from(endian + "II", data, offset)
            if command_size < 8 or offset + command_size > command_end:
                raise DarwinBackendError("invalid Mach-O load command size")
            if command == LC_UUID:
                if command_size != 24 or found_uuid is not None:
                    raise DarwinBackendError("invalid or duplicate LC_UUID")
                found_uuid = str(uuid.UUID(bytes=bytes(data[offset + 8 : offset + 24]))).upper()
            offset += command_size
        if offset != command_end or found_uuid is None:
            raise DarwinBackendError("Mach-O load commands lack one exact UUID")
        return MachOIdentity(cpu_type, cpu_subtype, found_uuid)


@dataclass(frozen=True)
class CommandResult:
    return_code: int
    stdout: bytes
    stderr: bytes
    stdout_dropped: int = 0
    stderr_dropped: int = 0


class CommandRunner(Protocol):
    def run(self, arguments: Sequence[str], timeout_seconds: float) -> CommandResult:
        ...


class BoundedCommandRunner:
    """Run one explicitly named inspection tool with bounded retained output."""

    def __init__(self, output_limit: int = 64 * 1024):
        if output_limit <= 0:
            raise ValueError("command output limit must be positive")
        self._output_limit = output_limit

    def run(self, arguments: Sequence[str], timeout_seconds: float) -> CommandResult:
        if not arguments or not os.path.isabs(arguments[0]):
            raise ValueError("inspection command requires an absolute executable path")
        if timeout_seconds <= 0:
            raise ValueError("inspection command timeout must be positive")
        process = subprocess.Popen(
            list(arguments),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
            close_fds=True,
        )
        try:
            stdout, stderr = process.communicate(timeout=timeout_seconds)
        except subprocess.TimeoutExpired as error:
            # This is the exact child created above, never a discovered PID/name.
            process.terminate()
            try:
                stdout, stderr = process.communicate(timeout=1.0)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
            raise TimeoutError("bounded inspection command timed out") from error
        return CommandResult(
            process.returncode,
            stdout[-self._output_limit :],
            stderr[-self._output_limit :],
            max(0, len(stdout) - self._output_limit),
            max(0, len(stderr) - self._output_limit),
        )


class SigningIdentityReader(Protocol):
    def signing_identity(self, path: str) -> str:
        ...


class CodesignIdentityReader:
    def __init__(
        self,
        runner: CommandRunner,
        codesign_path: str = "/usr/bin/codesign",
        timeout_seconds: float = 3.0,
    ):
        if not os.path.isabs(codesign_path):
            raise ValueError("codesign executable path must be absolute")
        self._runner = runner
        self._codesign_path = codesign_path
        self._timeout = timeout_seconds

    def signing_identity(self, path: str) -> str:
        if not os.path.isabs(path) or os.path.realpath(path) != path:
            raise DarwinBackendError("codesign query requires a canonical absolute path")
        try:
            path_stat = os.lstat(path)
        except OSError as error:
            raise DarwinBackendError("codesign query cannot inspect selected path") from error
        if stat.S_ISLNK(path_stat.st_mode) or not stat.S_ISREG(path_stat.st_mode):
            raise DarwinBackendError("codesign query refuses symlink or non-regular path")

        verification = self._runner.run(
            (
                self._codesign_path,
                "--verify",
                "--strict",
                "--verbose=4",
                "--",
                path,
            ),
            self._timeout,
        )
        if (
            verification.return_code != 0
            or verification.stdout_dropped
            or verification.stderr_dropped
        ):
            raise DarwinBackendError("strict codesign verification failed")

        result = self._runner.run(
            (self._codesign_path, "-d", "--verbose=4", "--", path), self._timeout
        )
        if result.stdout_dropped or result.stderr_dropped:
            raise DarwinBackendError("codesign metadata exceeded configured output bound")
        combined = result.stderr + b"\n" + result.stdout
        text = combined.decode("utf-8", errors="replace")
        if "\ufffd" in text or "\0" in text or any(
            len(line.encode("utf-8")) > 4096 for line in text.splitlines()
        ):
            raise DarwinBackendError("codesign metadata is malformed")
        authorities = [
            line.split("=", 1)[1].strip()
            for line in text.splitlines()
            if line.startswith("Authority=")
        ]
        if result.return_code != 0:
            raise DarwinBackendError("codesign identity query failed")
        identifiers = [
            line.split("=", 1)[1].strip()
            for line in text.splitlines()
            if line.startswith("Identifier=")
        ]
        teams = [
            line.split("=", 1)[1].strip()
            for line in text.splitlines()
            if line.startswith("TeamIdentifier=")
        ]
        cdhashes = [
            line.split("=", 1)[1].strip()
            for line in text.splitlines()
            if line.startswith("CDHash=")
        ]
        if (
            not authorities
            or any(not value for value in authorities)
            or len(identifiers) != 1
            or not identifiers[0]
            or len(teams) != 1
            or re.fullmatch(r"[A-Z0-9]{10}", teams[0]) is None
            or len(cdhashes) != 1
            or re.fullmatch(r"[0-9a-fA-F]{40,64}", cdhashes[0]) is None
        ):
            raise DarwinBackendError("codesign metadata is incomplete or malformed")
        return authorities[0]


class DarwinSnapshotBackend:
    """Selected-process-only backend consumed by ``ABASnapshotInspector``."""

    def __init__(
        self,
        process_api: DarwinProcessAPI,
        claims: SelectedProcessClaims,
        macho_reader: MachOIdentityReader,
        signing_reader: SigningIdentityReader,
        content_reader: Optional[ExecutableContentReader] = None,
    ):
        self._process_api = process_api
        self._claims = claims
        self._macho_reader = macho_reader
        self._signing_reader = signing_reader
        self._content_reader = content_reader or ExecutableContentReader()

    def read_anchor(self, pid: int) -> ProcessAnchor:
        info = self._process_api.bsd_info(pid)
        return ProcessAnchor(info.pid, info.start_seconds, info.start_microseconds)

    def read_identity_and_topology(
        self, pid: int
    ) -> Tuple[ImmutableProcessIdentity, ProcessTopology]:
        info = self._process_api.bsd_info(pid)
        running_architecture = self._process_api.architecture(pid)
        raw_path = self._process_api.pid_path(pid)
        try:
            raw_path_stat = os.lstat(raw_path)
        except OSError as error:
            raise DarwinBackendError("selected executable path is unavailable") from error
        if stat.S_ISLNK(raw_path_stat.st_mode):
            raise DarwinBackendError("selected process executable path must not be a symlink")
        canonical_path = os.path.realpath(raw_path)
        claim = self._claims.exact(pid, canonical_path)
        before = os.lstat(canonical_path)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise DarwinBackendError("selected executable path is not a regular file")
        open_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(canonical_path, open_flags)
        try:
            descriptor_before = os.fstat(descriptor)
            first_bytes, first_content = self._content_reader.read_fd(descriptor)
            macho = self._macho_reader.inspect_bytes(first_bytes, running_architecture)
            signing_identity = self._signing_reader.signing_identity(canonical_path)
            second_bytes, second_content = self._content_reader.read_fd(descriptor)
            descriptor_after = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        after = os.lstat(canonical_path)
        final_path = os.path.realpath(self._process_api.pid_path(pid))
        final_architecture = self._process_api.architecture(pid)
        if (
            before.st_dev != after.st_dev
            or before.st_ino != after.st_ino
            or descriptor_before.st_dev != before.st_dev
            or descriptor_before.st_ino != before.st_ino
            or descriptor_after.st_dev != descriptor_before.st_dev
            or descriptor_after.st_ino != descriptor_before.st_ino
            or first_content != second_content
            or first_bytes != second_bytes
            or canonical_path != final_path
            or running_architecture != final_architecture
        ):
            raise DarwinBackendError("executable identity changed during inspection")
        if (
            claim.expected_executable_identity
            and first_content.executable_identity != claim.expected_executable_identity
        ):
            raise DarwinBackendError(
                "executable content differs from accepted fixture identity"
            )
        session_id = self._process_api.session_id(pid)
        identity = DarwinImmutableProcessIdentity(
            pid=pid,
            start_seconds=info.start_seconds,
            start_microseconds=info.start_microseconds,
            canonical_path=canonical_path,
            executable_device=before.st_dev,
            executable_inode=before.st_ino,
            real_uid=info.real_uid,
            effective_uid=info.effective_uid,
            cpu_type=macho.cpu_type,
            cpu_subtype=macho.cpu_subtype,
            macho_uuid=macho.macho_uuid,
            signing_identity=signing_identity,
            nonce=claim.nonce,
            role=claim.role,
            executable_identity=first_content.executable_identity,
        )
        topology = ProcessTopology(
            parent_pid=info.parent_pid,
            process_group=info.process_group,
            session_id=session_id,
            traced=bool(info.flags & PROC_FLAG_TRACED),
            exited=info.status == SZOMB,
        )
        return identity, topology


GracefulCallback = Callable[[RegisteredProcess, float], GracefulAction]


class DarwinRegisteredProcessController:
    """Controller restricted to exact entries in one process registry."""

    def __init__(
        self,
        registry: ProcessRegistry,
        inspector: ProcessInspector,
        graceful_callbacks: Optional[Mapping[ProcessRole, GracefulCallback]] = None,
        kill_function: Callable[[int, int], None] = os.kill,
    ):
        self._registry = registry
        self._inspector = inspector
        self._graceful_callbacks = dict(graceful_callbacks or {})
        self._kill = kill_function

    def _registered_exact(self, registration: RegisteredProcess) -> bool:
        try:
            recorded = self._registry.lookup(registration.process_key)
        except KeyError:
            return False
        if recorded != registration:
            return False
        snapshot = self._inspector.capture(registration.identity.pid)
        return (
            snapshot.state is InspectionState.EXACT
            and snapshot.identity == registration.identity
        )

    def request_graceful(
        self, registration: RegisteredProcess, timeout_seconds: float
    ) -> GracefulAction:
        if timeout_seconds <= 0:
            raise ValueError("graceful timeout must be positive")
        if not self._registered_exact(registration):
            return GracefulAction(False, False, "refusedUnregisteredOrChangedIdentity")
        callback = self._graceful_callbacks.get(registration.identity.role)
        if callback is None:
            return GracefulAction(False, False, "noGracefulAction")
        return callback(registration, timeout_seconds)

    def send_signal(self, registration: RegisteredProcess, signal_number: int) -> bool:
        if signal_number not in {signal.SIGSTOP, signal.SIGTERM}:
            return False
        if (signal_number == signal.SIGSTOP
                and registration.identity.role is not ProcessRole.LAUNCHED_TARGET):
            return False
        # This second capture is immediately adjacent to the only signal call.
        if not self._registered_exact(registration):
            return False
        self._kill(registration.identity.pid, signal_number)
        return True


class DarwinRegisteredProcessWaiter:
    """Bounded identity-aware waiter; it never signals or discovers processes."""

    def __init__(
        self,
        registry: ProcessRegistry,
        inspector: ProcessInspector,
        *,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
        poll_interval_seconds: float = 0.02,
    ):
        if poll_interval_seconds <= 0:
            raise ValueError("poll interval must be positive")
        self._registry = registry
        self._inspector = inspector
        self._clock = clock
        self._sleeper = sleeper
        self._poll_interval = poll_interval_seconds

    def wait_after_action(
        self,
        identity: ImmutableProcessIdentity,
        timeout_seconds: float,
    ) -> ProcessSnapshot:
        if timeout_seconds <= 0:
            raise ValueError("wait timeout must be positive")
        registration = self._registry.lookup(identity.process_key)
        if registration.identity != identity:
            return ProcessSnapshot(
                InspectionState.IDENTITY_MISMATCH,
                detail="wait refused identity not owned by registry",
            )
        deadline = self._clock() + timeout_seconds
        while True:
            snapshot = self._inspector.capture(identity.pid)
            if snapshot.state is InspectionState.GONE:
                return snapshot
            if snapshot.state is not InspectionState.EXACT or snapshot.identity != identity:
                return ProcessSnapshot(
                    InspectionState.IDENTITY_MISMATCH
                    if snapshot.state is InspectionState.EXACT
                    else snapshot.state,
                    snapshot.identity,
                    snapshot.topology,
                    snapshot.detail or "identity changed while waiting",
                )
            remaining = deadline - self._clock()
            if remaining <= 0:
                return ProcessSnapshot(
                    InspectionState.EXACT,
                    identity,
                    snapshot.topology,
                    "bounded wait expired with exact process still running",
                )
            self._sleeper(min(self._poll_interval, remaining))
