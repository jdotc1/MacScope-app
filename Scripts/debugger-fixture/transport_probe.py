#!/usr/bin/env python3
"""Executable WS-18 orchestration over the hardened candidate/core modules.

Candidate code records observations only.  It never authors pass, viability, or
selection eligibility; those decisions belong exclusively to validate_ws18.py.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import inspect
import json
import os
import re
import signal
import stat
import subprocess
import sys
import time
import uuid
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence


HERE = Path(__file__).resolve().parent


def _load(name: str):
    path = HERE / (name + ".py")
    specification = importlib.util.spec_from_file_location(name, path)
    if specification is None or specification.loader is None:
        raise RuntimeError("unable to load " + str(path))
    module = importlib.util.module_from_spec(specification)
    sys.modules.setdefault(name, module)
    specification.loader.exec_module(module)
    return module


dap = _load("dap_transport")
supervisor = _load("process_supervisor")
schema = _load("ws18_schema")
drivers = _load("candidate_drivers")

# Compatibility exports now point at the single hardened owners.
DAPProtocolError = dap.DAPProtocolError
DAPFrameParser = dap.DAPFrameParser
DAPSession = dap.DAPSession
BoundedOutputBuffer = dap.BoundedOutputBuffer
drain_stream = dap.drain_stream
ABASnapshotInspector = supervisor.ABASnapshotInspector
OuterSupervisor = supervisor.OuterProcessSupervisor
ProcessIdentity = supervisor.ImmutableProcessIdentity
InspectionState = supervisor.InspectionState

MAX_JOURNAL_BYTES = 16 * 1024 * 1024
MAX_RECORD_BYTES = 1024 * 1024
MAX_LAUNCH_FRESHNESS_NS = 60 * 1_000_000_000
FIXTURE_CONTROL_OPTIONS = frozenset({"--control-dir", "--nonce", "--started-after-ns"})


class ProbeError(RuntimeError):
    pass


class MatrixSignalInterrupt(ProbeError):
    """A scoped matrix interruption that still permits exact-owned cleanup."""

    def __init__(self, signum: int) -> None:
        self.signum = signum
        self.exit_code = 128 + signum
        super().__init__("received " + signal.Signals(signum).name)


class _MatrixSignalBoundary:
    """Convert the first termination signal into a cleanup-safe exception.

    Repeated SIGINT/SIGTERM delivery is ignored while the first exception
    unwinds through per-cell cleanup.  The boundary never signals a child;
    exact run-owned supervisors retain sole termination authority.
    """

    def __init__(self) -> None:
        self._previous: dict[int, object] = {}
        self._interrupted_by: Optional[int] = None

    def __enter__(self) -> "_MatrixSignalBoundary":
        for signum in (signal.SIGINT, signal.SIGTERM):
            self._previous[signum] = signal.signal(signum, self._handle)
        return self

    def __exit__(self, *_: object) -> None:
        for signum, handler in self._previous.items():
            signal.signal(signum, handler)
        self._previous.clear()

    def _handle(self, signum: int, _frame: object) -> None:
        if self._interrupted_by is not None:
            return
        self._interrupted_by = signum
        raise MatrixSignalInterrupt(signum)


@dataclass(frozen=True)
class AcceptedLaunchIdentity:
    """Harness-verified immutable launch authorization, before any adapter starts."""

    executable: Path
    executableIdentity: str
    machOUUID: str
    signingIdentity: str
    nonce: str
    startedAfterNS: int
    controlDirectory: Path
    fixtureArguments: tuple[str, ...]


@dataclass(frozen=True)
class CandidateRunProjection:
    candidate: str
    candidateVersion: str
    mode: str
    observations: tuple[drivers.CandidateOperationEvidence, ...]
    target: drivers.ExactAttachTarget
    journalDigest: str
    supervisorArtifacts: Mapping[str, object]
    processAttempted: bool


def accepted_launch_identity(
    executable: Path, *, executable_sha256: str, macho_uuid: str,
    signing_identity: str, nonce: str, started_after_ns: int,
    control_directory: Path, user_arguments: Sequence[str],
    now_ns: Optional[int] = None,
) -> AcceptedLaunchIdentity:
    """Fail closed before launch and inject the fixture control contract once.

    The SHA is checked here because a debugger acknowledgement cannot establish
    which bytes the operating system eventually executed.  UUID and signer are
    authorization inputs; the run-owned Darwin bridge independently rechecks
    both after the process exists.
    """
    path = executable.resolve(strict=True)
    if not path.is_file() or not os.access(path, os.X_OK):
        raise ProbeError("accepted launch executable must be an executable regular file")
    digest = executable_sha256.lower()
    if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
        raise ProbeError("accepted launch executable SHA-256 is invalid")
    observed_digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if observed_digest != digest:
        raise ProbeError("accepted launch executable SHA-256 does not match on-disk bytes")
    if re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", macho_uuid) is None:
        raise ProbeError("accepted launch Mach-O UUID is invalid")
    if not signing_identity.strip() or not nonce or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", nonce):
        raise ProbeError("accepted launch signer and nonce are required")
    if not isinstance(started_after_ns, int) or isinstance(started_after_ns, bool):
        raise ProbeError("started-after freshness must be an integer nanosecond timestamp")
    current = time.time_ns() if now_ns is None else now_ns
    age = current - started_after_ns
    if age < 0 or age > MAX_LAUNCH_FRESHNESS_NS:
        raise ProbeError("started-after freshness is outside the live launch window")
    control = control_directory.resolve(strict=True)
    control_info = os.stat(control, follow_symlinks=False)
    if (not stat.S_ISDIR(control_info.st_mode) or control_info.st_uid != os.geteuid()
            or stat.S_IMODE(control_info.st_mode) != 0o700):
        raise ProbeError("fixture control directory must be current-user mode 0700")
    supplied = tuple(str(item) for item in user_arguments)
    if any(item in FIXTURE_CONTROL_OPTIONS or any(
        item.startswith(option + "=") for option in FIXTURE_CONTROL_OPTIONS
    ) for item in supplied):
        raise ProbeError("fixture control options are harness-owned and cannot be supplied twice")
    injected = supplied + (
        "--control-dir", str(control), "--nonce", nonce,
        "--started-after-ns", str(started_after_ns),
    )
    return AcceptedLaunchIdentity(
        path, "sha256:" + digest, macho_uuid.upper(), signing_identity,
        nonce, started_after_ns, control, injected,
    )


def register_exact_helper(target: drivers.ExactAttachTarget,
                          observed: supervisor.ImmutableProcessIdentity,
                          registry: supervisor.ProcessRegistry) -> supervisor.RegisteredProcess:
    """Convert an authorization into the supervisor ledger exactly once."""
    if observed.role is not supervisor.ProcessRole.ATTACHED_HELPER:
        raise ProbeError("attach target must have attachedHelper supervisor role")
    if (observed.pid != target.pid or observed.start_seconds * 1_000_000_000 +
            observed.start_microseconds * 1_000 != target.startTimeNS or
            observed.real_uid != target.realUID or observed.effective_uid != target.effectiveUID or
            observed.canonical_path != str(Path(target.canonicalPath).resolve()) or
            observed.cpu_type != target.cpuType or observed.cpu_subtype != target.cpuSubtype or
            observed.executable_device != target.executableDevice or
            observed.executable_inode != target.executableInode or
            observed.macho_uuid != target.machOUUID or
            observed.signing_identity != target.signingIdentity or
            observed.nonce != target.nonce):
        raise ProbeError("observed helper identity differs from attach authorization")
    return registry.register(observed)


def supervisor_artifacts(registry: supervisor.ProcessRegistry,
                         cleanup_receipts: Sequence[supervisor.CleanupReceipt],
                         residue: supervisor.ResidueAudit) -> Mapping[str, object]:
    """Serialize independent supervisor receipts; functional evidence is not accepted here."""
    registrations = [{"role": item.identity.role.value, "identity": _jsonable(asdict(item.identity))}
                     for item in registry.registrations]
    return {"processRegistry": registrations,
            "cleanupReceipts": [_jsonable(asdict(item)) for item in cleanup_receipts],
            "cleanupComplete": supervisor.cleanup_receipts_are_complete(registry, cleanup_receipts),
            "residueAudit": _jsonable(asdict(residue))}


def _jsonable(value: object) -> object:
    if isinstance(value, Enum):
        return value.value
    if isinstance(value, dict):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(item) for item in value]
    return value


class RawJournal:
    """Exclusively created, append-only, bounded JSONL evidence journal."""

    def __init__(self, path: Path, *, max_bytes: int = MAX_JOURNAL_BYTES,
                 artifact_root: Optional[Path] = None,
                 journal_id: Optional[str] = None) -> None:
        self.artifact_root = (artifact_root or path.parent).resolve(strict=True)
        self.path = path.absolute()
        self.max_bytes = max_bytes
        self.journal_id = journal_id or str(uuid.uuid4())
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", self.journal_id):
            raise ValueError("journal_id must be a bounded filesystem-safe token")
        self._validate_root()
        self._validate_destination()
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_APPEND
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            self._descriptor: Optional[int] = os.open(self.path, flags, 0o600)
        except FileExistsError as error:
            raise ProbeError("stale evidence journal already exists") from error
        except OSError as error:
            raise ProbeError("unable to securely create evidence journal") from error
        os.fchmod(self._descriptor, 0o600)
        self._identity = self._validate_open_file(self._descriptor)
        self.bytes_written = 0
        self._sequence = 0

    def _validate_root(self) -> None:
        root_stat = os.lstat(self.artifact_root)
        if stat.S_ISLNK(root_stat.st_mode):
            raise ProbeError("artifact root must not be a symlink")
        if not stat.S_ISDIR(root_stat.st_mode):
            raise ProbeError("artifact root must be a directory")
        if root_stat.st_uid != os.geteuid() or stat.S_IMODE(root_stat.st_mode) != 0o700:
            raise ProbeError("artifact root must be owned by the current user with mode 0700")

    def _validate_destination(self) -> None:
        try:
            self.path.resolve(strict=False).relative_to(self.artifact_root)
        except ValueError as error:
            raise ProbeError("evidence journal must remain inside artifact root") from error
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        parent_stat = os.stat(self.path.parent, follow_symlinks=False)
        if (not stat.S_ISDIR(parent_stat.st_mode) or parent_stat.st_uid != os.geteuid()
                or stat.S_IMODE(parent_stat.st_mode) != 0o700):
            raise ProbeError("journal directory must be owned by the current user with mode 0700")
        try:
            existing = os.lstat(self.path)
        except FileNotFoundError:
            return
        if stat.S_ISLNK(existing.st_mode):
            raise ProbeError("evidence journal output must not be a symlink")
        raise ProbeError("stale evidence journal already exists")

    @staticmethod
    def _validate_open_file(descriptor: int) -> tuple[int, int]:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ProbeError("evidence journal must be a regular file")
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ProbeError("evidence journal must be owned by the current user with mode 0600")
        return info.st_dev, info.st_ino

    def append(self, kind: str, payload: Mapping[str, object]) -> str:
        if self._descriptor is None:
            raise ProbeError("raw evidence journal is closed")
        current = self._validate_open_file(self._descriptor)
        try:
            path_info = os.lstat(self.path)
        except FileNotFoundError as error:
            raise ProbeError("raw evidence journal path was removed") from error
        if stat.S_ISLNK(path_info.st_mode) or (path_info.st_dev, path_info.st_ino) != current:
            raise ProbeError("raw evidence journal path identity changed")
        record = {"kind": kind, "payload": dict(payload), "sequence": self._next_sequence(),
                  "journalID": self.journal_id,
                  "timestampNS": time.time_ns()}
        encoded = (json.dumps(record, sort_keys=True, separators=(",", ":"),
                              allow_nan=False) + "\n").encode("utf-8")
        if len(encoded) > MAX_RECORD_BYTES or self.bytes_written + len(encoded) > self.max_bytes:
            raise ProbeError("raw evidence journal exceeds configured bound")
        offset = 0
        while offset < len(encoded):
            written = os.write(self._descriptor, encoded[offset:])
            if written <= 0:
                raise ProbeError("raw evidence journal write made no progress")
            offset += written
        os.fsync(self._descriptor)
        self.bytes_written += len(encoded)
        self._sequence += 1
        return hashlib.sha256(encoded).hexdigest()

    def _next_sequence(self) -> int:
        return self._sequence + 1

    def close(self) -> None:
        if self._descriptor is not None:
            os.close(self._descriptor)
            self._descriptor = None

    def __enter__(self):
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def _secure_read_journal(path: Path, artifact_root: Path) -> bytes:
    root = artifact_root.resolve(strict=True)
    absolute = path.absolute()
    try:
        absolute.resolve(strict=True).relative_to(root)
    except ValueError as error:
        raise ProbeError("input evidence journal is outside artifact root") from error
    info = os.lstat(absolute)
    if stat.S_ISLNK(info.st_mode):
        raise ProbeError("input evidence journal must not be a symlink")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(absolute, flags)
    try:
        opened = os.fstat(descriptor)
        if (not stat.S_ISREG(opened.st_mode) or opened.st_uid != os.geteuid()
                or stat.S_IMODE(opened.st_mode) != 0o600
                or (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino)):
            raise ProbeError("input evidence journal owner, mode, or identity is invalid")
        if opened.st_size > MAX_JOURNAL_BYTES:
            raise ProbeError("input evidence journal exceeds configured bound")
        chunks = []
        remaining = opened.st_size
        while remaining:
            chunk = os.read(descriptor, min(64 * 1024, remaining))
            if not chunk:
                raise ProbeError("input evidence journal was truncated while reading")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def aggregate_raw_journals(inputs: Sequence[Path], output: Path, *,
                           artifact_root: Optional[Path] = None) -> int:
    root = (artifact_root or output.parent).resolve(strict=True)
    destination = RawJournal(output, artifact_root=root)
    count = 0
    try:
        seen_journals = set()
        for source_index, source in enumerate(inputs):
            raw = _secure_read_journal(source, root)
            expected = 1
            source_journal_id = None
            for line in raw.splitlines():
                value = schema.strict_json_loads(line, max_bytes=MAX_RECORD_BYTES)
                if not isinstance(value, dict) or value.get("sequence") != expected:
                    raise ProbeError("input evidence journal sequence is invalid")
                journal_id = value.get("journalID")
                if not isinstance(journal_id, str) or not journal_id:
                    raise ProbeError("input evidence journal has no scope identity")
                if source_journal_id is None:
                    source_journal_id = journal_id
                    if journal_id in seen_journals:
                        raise ProbeError("duplicate input evidence journal scope")
                    seen_journals.add(journal_id)
                elif journal_id != source_journal_id:
                    raise ProbeError("input evidence journal contains mixed scope evidence")
                destination.append("aggregated-record", {"sourceIndex": source_index,
                                                          "sourceSHA256": hashlib.sha256(raw).hexdigest(),
                                                          "record": value})
                expected += 1
                count += 1
        return count
    finally:
        destination.close()


def _raw_records(inputs: Sequence[Path], artifact_root: Path) -> list[Mapping[str, object]]:
    """Read immutable journal records without projecting or normalizing their facts."""
    records: list[Mapping[str, object]] = []
    seen_journals: set[str] = set()
    for source in inputs:
        raw = _secure_read_journal(source, artifact_root)
        expected_sequence = 1
        source_journal_id: Optional[str] = None
        for raw_line in raw.splitlines(keepends=True):
            if not raw_line.endswith(b"\n"):
                raise ProbeError("input evidence journal record is not newline-terminated")
            line = raw_line[:-1]
            value = schema.strict_json_loads(line, max_bytes=MAX_RECORD_BYTES)
            if not isinstance(value, dict) or set(value) != {
                "kind", "payload", "sequence", "journalID", "timestampNS"
            }:
                raise ProbeError("input evidence journal record differs from frozen envelope")
            if value["sequence"] != expected_sequence:
                raise ProbeError("input evidence journal sequence is invalid")
            journal_id = value["journalID"]
            if not isinstance(journal_id, str) or not journal_id:
                raise ProbeError("input evidence journal has no scope identity")
            if source_journal_id is None:
                source_journal_id = journal_id
                if journal_id in seen_journals:
                    raise ProbeError("duplicate input evidence journal scope")
                seen_journals.add(journal_id)
            elif source_journal_id != journal_id:
                raise ProbeError("input evidence journal contains mixed scope evidence")
            if not isinstance(value["kind"], str) or not isinstance(value["payload"], dict):
                raise ProbeError("input evidence journal kind/payload is invalid")
            record = dict(value)
            record["recordSHA256"] = hashlib.sha256(raw_line).hexdigest()
            records.append(record)
            expected_sequence += 1
    return records


def _protocol_fact_digest_index(
    records: Sequence[Mapping[str, object]],
) -> dict[tuple[str, str], tuple[
    str, tuple[drivers.CandidateOperationEvidence, ...]
]]:
    """Bind each raw record digest and derived projection to its matrix cell."""
    index: dict[tuple[str, str], tuple[
        str, tuple[drivers.CandidateOperationEvidence, ...]
    ]] = {}
    for record in records:
        if record.get("kind") != "candidate-protocol-facts":
            continue
        payload = record.get("payload")
        digest = record.get("recordSHA256")
        if (not isinstance(payload, Mapping)
                or set(payload) != {"candidate", "mode", "observations"}):
            raise ProbeError("candidate protocol facts differ from frozen envelope")
        candidate, mode = payload["candidate"], payload["mode"]
        key = (candidate, mode)
        if (candidate not in schema.CANDIDATE_ORDER or mode not in {"launch", "attach"}
                or not isinstance(payload["observations"], list) or key in index
                or not isinstance(digest, str)
                or re.fullmatch(r"[0-9a-f]{64}", digest) is None):
            raise ProbeError("candidate protocol facts are invalid or duplicated")
        observations = tuple(
            _candidate_evidence(item) for item in payload["observations"]
        )
        if (tuple(item.operation for item in observations) != schema.OPERATION_ORDER
                or any(item.candidate != candidate for item in observations)):
            raise ProbeError("candidate protocol facts do not contain the frozen operation order")
        index[key] = (digest, _freeze_run_revision_context(observations))
    return index


def _candidate_evidence(value: object) -> drivers.CandidateOperationEvidence:
    if not isinstance(value, Mapping) or set(value) != {
        "candidate", "operation", "observation", "requestID", "targetPID",
        "targetDisposition", "proof", "negative"
    }:
        raise ProbeError("candidate operation differs from frozen evidence envelope")
    string_fields = ("candidate", "operation", "observation", "requestID", "targetDisposition")
    if any(not isinstance(value[name], str) or not value[name] for name in string_fields):
        raise ProbeError("candidate operation has invalid string identity fields")
    target_pid = value["targetPID"]
    if target_pid is not None and (
        not isinstance(target_pid, int) or isinstance(target_pid, bool) or target_pid <= 0
    ):
        raise ProbeError("candidate operation target PID must be positive or null")
    if not isinstance(value["proof"], Mapping):
        raise ProbeError("candidate operation proof must be an object")
    negative = value["negative"]
    if negative is not None and not isinstance(negative, Mapping):
        raise ProbeError("candidate operation negative evidence must be an object or null")
    return drivers.CandidateOperationEvidence(
        value["candidate"], value["operation"], value["observation"],
        value["requestID"], target_pid, value["targetDisposition"],
        dict(value["proof"]), None if negative is None else dict(negative),
    )


def _attach_target(value: object) -> drivers.ExactAttachTarget:
    expected = {
        "pid", "startTimeNS", "realUID", "effectiveUID", "canonicalPath", "cpuType",
        "cpuSubtype", "executableIdentity", "executableDevice", "executableInode",
        "machOUUID", "signingIdentity", "nonce",
    }
    if not isinstance(value, Mapping) or set(value) != expected:
        raise ProbeError("run target differs from exact immutable identity envelope")
    try:
        return drivers.ExactAttachTarget(
            value["pid"], value["startTimeNS"], value["realUID"], value["effectiveUID"],
            value["canonicalPath"], value["cpuType"], value["cpuSubtype"],
            value["executableIdentity"], value["executableDevice"],
            value["executableInode"], value["machOUUID"], value["signingIdentity"],
            value["nonce"],
        )
    except (TypeError, ValueError) as error:
        raise ProbeError("run target exact identity is invalid") from error


def _require_attempt_cleanup(
    observations: Sequence[drivers.CandidateOperationEvidence],
    artifacts: Mapping[str, object],
    process_attempted: Optional[bool] = None,
) -> None:
    inferred_attempt = any(
        isinstance(item.targetPID, int) and not isinstance(item.targetPID, bool)
        and item.targetPID > 0 for item in observations
    )
    attempted = inferred_attempt if process_attempted is None else process_attempted
    if inferred_attempt and attempted is not True:
        raise ProbeError("attempted process cannot be marked unattempted")
    if not attempted:
        return
    registry = artifacts.get("processRegistry")
    receipts = artifacts.get("cleanupReceipts")
    residue = artifacts.get("residueAudit")
    if not isinstance(registry, list) or not registry or not isinstance(receipts, list) or not receipts:
        raise ProbeError("attempted process lacks registry-bound cleanup evidence")
    if not isinstance(residue, Mapping) or residue.get("complete") is not True:
        raise ProbeError("attempted process lacks complete residue cleanup evidence")
    if residue.get("remainingIdentities") != []:
        raise ProbeError("attempted process cleanup left owned-process residue")


def _supervisor_debuggee_identity(
    artifacts: Mapping[str, object], mode: str,
) -> Optional[Mapping[str, object]]:
    role = "target" if mode == "launch" else "helper"
    registry = artifacts.get("processRegistry")
    if not isinstance(registry, list):
        return None
    matches = [item.get("identity") for item in registry
               if isinstance(item, Mapping) and item.get("role") == role
               and isinstance(item.get("identity"), Mapping)]
    if len(matches) > 1:
        raise ProbeError("supervisor facts repeat the run-owned debuggee role")
    return dict(matches[0]) if matches else None


def _secure_write_report(path: Path, payload: bytes, artifact_root: Path) -> str:
    root = artifact_root.resolve(strict=True)
    destination = path.absolute()
    try:
        destination.resolve(strict=False).relative_to(root)
    except ValueError as error:
        raise ProbeError("aggregate report must remain inside artifact root") from error
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(destination, flags, 0o600)
    except FileExistsError as error:
        raise ProbeError("stale aggregate report already exists") from error
    try:
        os.fchmod(descriptor, 0o600)
        offset = 0
        while offset < len(payload):
            written = os.write(descriptor, payload[offset:])
            if written <= 0:
                raise ProbeError("aggregate report write made no progress")
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    return hashlib.sha256(payload).hexdigest()


def _sealed_report_bytes(aggregate: Mapping[str, object]) -> bytes:
    """Serialize the raw sealed report; canonical projection is digest-only."""
    return (json.dumps(aggregate, sort_keys=True, separators=(",", ":"),
                       ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")


def aggregate_report_from_journals(
    inputs: Sequence[Path], output: Path, *, artifact_root: Optional[Path] = None,
) -> str:
    """Project raw protocol/supervisor facts into one sealed frozen aggregate."""
    root = (artifact_root or output.parent).resolve(strict=True)
    records = _raw_records(inputs, root)
    protocol_fact_bindings = _protocol_fact_digest_index(records)
    contexts = [record["payload"] for record in records
                if record["kind"] == "aggregate-context"]
    if len(contexts) != 1:
        raise ProbeError("aggregate projection requires exactly one aggregate-context")
    context = contexts[0]
    if set(context) != {"toolchain", "fixture", "normalizationRoot"}:
        raise ProbeError("aggregate-context differs from frozen projection envelope")
    if not isinstance(context["toolchain"], Mapping) or not isinstance(context["fixture"], Mapping):
        raise ProbeError("aggregate toolchain/fixture facts must be objects")
    normalization_root = Path(str(context["normalizationRoot"]))
    if not normalization_root.is_absolute():
        raise ProbeError("normalization root must be absolute")

    discoveries: dict[str, Mapping[str, object]] = {}
    versions: dict[str, str] = {}
    for record in records:
        if record["kind"] != "candidate-discovery":
            continue
        payload = record["payload"]
        if set(payload) != {"candidate", "candidateVersion", "discovery"}:
            raise ProbeError("candidate discovery differs from frozen projection envelope")
        candidate = payload["candidate"]
        version = payload["candidateVersion"]
        discovery = payload["discovery"]
        if (not isinstance(candidate, str) or candidate in discoveries
                or not isinstance(version, str) or not version
                or not isinstance(discovery, Mapping)):
            raise ProbeError("candidate discovery is invalid or duplicated")
        discoveries[candidate] = dict(discovery)
        versions[candidate] = version

    projected_runs: dict[tuple[str, str], Mapping[str, object]] = {}
    for record in records:
        if record["kind"] != "candidate-run-projection":
            continue
        payload = record["payload"]
        required = {"candidate", "candidateVersion", "mode", "observations", "target",
                    "journalDigest", "supervisorArtifacts"}
        optional = {"processAttempted"}
        if not required.issubset(payload) or not set(payload).issubset(required | optional):
            raise ProbeError("candidate run differs from frozen projection envelope")
        candidate, mode = payload["candidate"], payload["mode"]
        key = (candidate, mode)
        if (not isinstance(candidate, str) or mode not in {"launch", "attach"}
                or key in projected_runs):
            raise ProbeError("candidate run identity is invalid or duplicated")
        if payload["candidateVersion"] != versions.get(candidate):
            raise ProbeError("candidate run version differs from discovery")
        raw_observations = payload["observations"]
        artifacts = payload["supervisorArtifacts"]
        if not isinstance(raw_observations, list) or not isinstance(artifacts, Mapping):
            raise ProbeError("candidate run observations/supervisor facts are invalid")
        observations = tuple(_candidate_evidence(item) for item in raw_observations)
        if tuple(item.operation for item in observations) != tuple(schema.OPERATION_ORDER):
            raise ProbeError("candidate run must classify every frozen operation exactly once")
        if any(item.candidate != candidate for item in observations):
            raise ProbeError("candidate run contains evidence from another candidate")
        process_attempted = payload.get("processAttempted")
        if process_attempted is not None and not isinstance(process_attempted, bool):
            raise ProbeError("processAttempted must be boolean when present")
        _require_attempt_cleanup(observations, artifacts, process_attempted)
        supervisor_identity = _supervisor_debuggee_identity(artifacts, mode)
        if any(item.targetPID is not None for item in observations) and supervisor_identity is None:
            raise ProbeError("attempted debuggee lacks run-owned supervisor identity")
        digest = payload["journalDigest"]
        binding = protocol_fact_bindings.get(key)
        if binding is None or digest != binding[0]:
            raise ProbeError("candidate run journal digest is not bound to its protocol facts")
        if observations != binding[1]:
            raise ProbeError("candidate run observations are not derived from bound protocol facts")
        projected_runs[key] = {
            "observations": observations,
            "target": _attach_target(payload["target"]),
            "journalDigest": digest,
            "supervisorArtifacts": dict(artifacts),
            "supervisorIdentity": supervisor_identity,
        }

    if set(protocol_fact_bindings) != set(projected_runs):
        raise ProbeError("candidate protocol facts do not exactly cover projected runs")

    candidates = []
    toolchain_binding = str(context["toolchain"].get("binding", ""))
    fixture_binding = str(context["fixture"].get("binding", ""))
    for candidate in schema.CANDIDATE_ORDER:
        if candidate not in discoveries:
            raise ProbeError("aggregate projection is missing candidate discovery")
        runs = []
        for mode in ("launch", "attach"):
            projected = projected_runs.get((candidate, mode))
            if projected is None:
                raise ProbeError("aggregate projection is missing a frozen candidate mode")
            digest = projected["journalDigest"]
            if not isinstance(digest, str) or not digest:
                raise ProbeError("candidate run journal digest is missing")
            runs.append(make_run(
                candidate, versions[candidate], mode, projected["observations"],
                projected["target"], toolchain_binding, fixture_binding, digest,
                expected_identity=projected["supervisorIdentity"],
                supervisor_artifacts=projected["supervisorArtifacts"],
            ))
        candidates.append(schema.make_candidate(
            candidate, versions[candidate], discoveries[candidate], runs,
        ))
    aggregate = schema.make_aggregate(
        toolchain=context["toolchain"], fixture=context["fixture"],
        normalization=schema.make_normalization(({
            "alias": "$ARTIFACT", "path": str(normalization_root.resolve())
        },)), candidates=candidates, validator=schema.make_validator_envelope(),
    )
    sealed = schema.seal_validator_digest(aggregate)
    return _secure_write_report(output, _sealed_report_bytes(sealed), root)


def _identity(value: drivers.ExactAttachTarget, role: str = "helper") -> dict[str, object]:
    return {"pid": value.pid, "startTimeNS": value.startTimeNS, "realUID": value.realUID,
            "effectiveUID": value.effectiveUID, "canonicalPath": os.path.realpath(value.canonicalPath),
            "cpuType": value.cpuType, "cpuSubtype": value.cpuSubtype,
            "executableIdentity": value.executableIdentity, "nonce": value.nonce,
            "role": role, "device": value.executableDevice,
            "inode": value.executableInode, "machOUUID": value.machOUUID}


def _observed_context(
    observations: Sequence[drivers.CandidateOperationEvidence],
) -> Optional[dict[str, object]]:
    contexts = []
    for item in observations:
        if item.observation != "observed":
            continue
        evidence = _validator_operation_evidence(item.proof)
        if not isinstance(evidence, Mapping):
            continue
        request = evidence.get("request")
        event = evidence.get("event")
        if not isinstance(request, Mapping) or not isinstance(event, Mapping):
            continue
        contexts.append({
            "runID": request.get("runID"), "sessionID": request.get("sessionID"),
            "sessionEpoch": request.get("sessionEpoch"),
            "lifecycleRevision": event.get("lifecycleRevision"),
            "stopRevision": event.get("stopRevision"),
        })
    if not contexts:
        return None
    first = contexts[0]
    if any(value != first for value in contexts[1:]) or not (
        isinstance(first["runID"], str) and first["runID"]
        and isinstance(first["sessionID"], str) and first["sessionID"]
        and isinstance(first["sessionEpoch"], int) and not isinstance(first["sessionEpoch"], bool)
        and first["sessionEpoch"] >= 1
        and isinstance(first["lifecycleRevision"], int)
        and not isinstance(first["lifecycleRevision"], bool)
        and first["lifecycleRevision"] >= 1
        and isinstance(first["stopRevision"], int)
        and not isinstance(first["stopRevision"], bool)
        and first["stopRevision"] >= 0
    ):
        raise ProbeError("observed operation evidence has inconsistent run/session revisions")
    return first


def _operation_rows(
    observations: Sequence[drivers.CandidateOperationEvidence],
    context: Optional[Mapping[str, object]] = None,
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    by_name = {item.operation: item for item in observations}
    aliases = {"launch": "configuredLaunch", "disconnect": "detach"}
    rows = []
    ledger = []
    resolved_context = dict(context or _observed_context(observations) or {
        "runID": observations[0].requestID if observations else "unattempted-run",
        "sessionID": "no-observed-session",
        "sessionEpoch": 1, "lifecycleRevision": 1, "stopRevision": 0,
    })
    for name in schema.OPERATION_ORDER:
        item = by_name.get(name)
        if item is None:
            item = next((value for key, value in by_name.items() if aliases.get(key) == name), None)
        if item is None:
            request_id = str(resolved_context["runID"]) + ":" + name + ":notAttempted"
            observation = "notAttempted"
            evidence: object = {"classification": "notAttempted",
                                "reason": "operation was not exercised in this run"}
            event_sequence = 0
        else:
            proof = dict(item.proof)
            if item.observation == "observed":
                validator_evidence = _validator_operation_evidence(proof)
                if validator_evidence is None:
                    rows.append({"name": name, "advertisement": "unknown",
                        "observation": "harnessError",
                        "evidence": {"classification": "harnessError",
                                     "reason": "observed claim lacks frozen request/event/postcondition evidence"},
                        "stopRevision": 0})
                    ledger.append({
                        "requestID": item.requestID, "runID": resolved_context["runID"],
                        "sessionID": resolved_context["sessionID"],
                        "sessionEpoch": resolved_context["sessionEpoch"],
                        "lifecycleRevision": resolved_context["lifecycleRevision"],
                        "command": name, "responseEventSequence": 0,
                        "outcome": "harnessError",
                    })
                    continue
                proof = validator_evidence
            request_id = item.requestID
            observation = item.observation
            evidence = proof or item.negative or {
                "classification": "harnessError", "reason": "operation evidence is empty"
            }
            event = proof.get("event") if isinstance(proof, Mapping) else None
            event_sequence = event.get("sequence", 0) if isinstance(event, Mapping) else 0
        stop_revision = resolved_context["stopRevision"]
        if isinstance(evidence, Mapping) and isinstance(evidence.get("event"), Mapping):
            stop_revision = evidence["event"].get("stopRevision", stop_revision)
        rows.append({"name": name, "advertisement": "unknown",
                     "observation": observation, "evidence": evidence,
                     "stopRevision": stop_revision})
        if item is None:
            continue
        ledger.append({
            "requestID": request_id, "runID": resolved_context["runID"],
            "sessionID": resolved_context["sessionID"],
            "sessionEpoch": resolved_context["sessionEpoch"],
            "lifecycleRevision": resolved_context["lifecycleRevision"],
            "command": name, "responseEventSequence": event_sequence,
            "outcome": observation,
        })
    return rows, ledger


def _validator_operation_evidence(proof: Mapping[str, object]) -> Optional[Mapping[str, object]]:
    direct = proof.get("validatorEvidence")
    if isinstance(direct, Mapping):
        return dict(direct)
    postcondition = proof.get("postcondition")
    if isinstance(postcondition, Mapping):
        nested = postcondition.get("evidence")
        if isinstance(nested, Mapping) and isinstance(nested.get("validatorEvidence"), Mapping):
            return dict(nested["validatorEvidence"])
    return None


def _post_detach_checkpoint(proof: Mapping[str, object]) -> Optional[Mapping[str, object]]:
    candidates: list[object] = [proof.get("postDetachControl")]
    protocol_fact = proof.get("protocolFact")
    if isinstance(protocol_fact, Mapping):
        candidates.append(protocol_fact.get("postDetachControl"))
        postcondition = protocol_fact.get("postcondition")
        if isinstance(postcondition, Mapping):
            candidates.append(postcondition.get("postDetachControl"))
    for value in candidates:
        if isinstance(value, Mapping):
            return value
    return None


def _python_post_detach_checkpoint(
    proof: Mapping[str, object], target: drivers.ExactAttachTarget,
) -> Mapping[str, object]:
    """Promote the Python detach observer's exact checkpoint without mutating it again."""
    candidates: list[object] = [_post_detach_checkpoint(proof)]
    response = proof.get("protocolResponse")
    if isinstance(response, Mapping):
        result = response.get("result")
        if isinstance(result, Mapping):
            candidates.append(result.get("postDetach"))
        evidence = response.get("evidence")
        if isinstance(evidence, Mapping):
            candidates.append(evidence.get("survivalProof"))
            postcondition = evidence.get("postcondition")
            if isinstance(postcondition, Mapping):
                candidates.append(postcondition.get("survivalProof"))
    for value in candidates:
        if not isinstance(value, Mapping):
            continue
        sequence = value.get("commandSequence", value.get(
            "checkpointSequence", value.get("sequence")))
        if (not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= 0
                or value.get("pid") != target.pid or value.get("nonce") != target.nonce):
            continue
        for field in ("sameIdentity", "alive", "controllable"):
            if field in value and value.get(field) is not True:
                break
        else:
            return {"operation": "checkpoint", "commandSequence": sequence,
                    "pid": target.pid, "nonce": target.nonce}
    raise ProbeError("observed Python detach lacks exact checkpoint proof")


def _derive_detach_metadata(
    observations: Sequence[drivers.CandidateOperationEvidence],
    context: Mapping[str, object], identity: Mapping[str, object],
) -> Mapping[str, object]:
    """Project an observed nonterminating detach into the frozen metadata proof."""
    by_operation = {item.operation: item for item in observations}
    attached = by_operation.get("attach")
    detached = by_operation.get("detach") or by_operation.get("disconnect")
    if (attached is None or detached is None
            or attached.observation != "observed" or detached.observation != "observed"
            or attached.targetPID != identity.get("pid")
            or detached.targetPID != identity.get("pid")
            or detached.targetDisposition != "detached"):
        return {}
    checkpoint = _post_detach_checkpoint(detached.proof)
    if not isinstance(checkpoint, Mapping):
        return {}
    sequence = checkpoint.get("commandSequence", checkpoint.get(
        "checkpointSequence", checkpoint.get("sequence")))
    pid = checkpoint.get("pid", identity.get("pid"))
    nonce = checkpoint.get("nonce", identity.get("nonce"))
    if (not isinstance(sequence, int) or isinstance(sequence, bool) or sequence <= 0
            or pid != identity.get("pid") or nonce != identity.get("nonce")):
        return {}
    session_id = context["sessionID"]
    return {
        "explicitAdapterPID": identity["pid"],
        "explicitDetachAcknowledged": True,
        "detachAcknowledgementSessionID": session_id,
        "disconnectTerminateDebuggee": False,
        "helperAliveAfterDetach": True,
        "helperControllableAfterDetach": True,
        "postDetachIdentity": dict(identity),
        "postDetachControlEvidence": {
            "requestID": context["runID"], "sessionID": session_id,
            "sessionEpoch": context["sessionEpoch"],
            "lifecycleRevision": context["lifecycleRevision"],
            "nonce": identity["nonce"], "sequence": sequence,
            "postcondition": "same helper answered after detach",
        },
    }


def make_run(candidate: str, version: str, mode: str,
             observations: Sequence[drivers.CandidateOperationEvidence],
             target: drivers.ExactAttachTarget, toolchain_binding: str,
             fixture_binding: str, journal_digest: str, *,
             expected_identity: Optional[Mapping[str, object]] = None,
             supervisor_artifacts: Optional[Mapping[str, object]] = None) -> dict[str, object]:
    primary = observations[-1] if observations else None
    by_operation = {item.operation: item for item in observations}
    launch = by_operation.get("configuredLaunch") or by_operation.get("launch")
    attach = by_operation.get("attach")
    detach = by_operation.get("detach") or by_operation.get("disconnect")
    expected_exit = by_operation.get("expectedExit")
    if mode == "launch":
        if launch is None:
            state = "notAttempted"
        elif launch.observation != "observed":
            state = launch.observation
        elif expected_exit is None:
            state = "harnessError"
        else:
            state = expected_exit.observation
    else:
        if attach is None:
            state = "notAttempted"
        elif attach.observation != "observed":
            state = attach.observation
        elif detach is None:
            state = "harnessError"
        else:
            state = detach.observation
    context = _observed_context(observations)
    if state == "observed" and context is None:
        state = "harnessError"
    if context is None:
        context = {
            "runID": primary.requestID if primary else candidate + ":" + mode + ":unattempted",
            "sessionID": candidate + ":" + mode + ":no-observed-session",
            "sessionEpoch": 1, "lifecycleRevision": 1, "stopRevision": 0,
        }
    identity = (dict(expected_identity) if expected_identity is not None
                else _identity(target, "target" if mode == "launch" else "helper"))
    registry = list((supervisor_artifacts or {}).get("processRegistry", []))
    receipts = list((supervisor_artifacts or {}).get("cleanupReceipts", []))
    residue = (supervisor_artifacts or {}).get("residueAudit")
    debuggee_role = "target" if mode == "launch" else "helper"
    registered_identity = next((
        item.get("identity") for item in registry
        if isinstance(item, Mapping) and item.get("role") == debuggee_role
        and isinstance(item.get("identity"), Mapping)
    ), None)
    if state == "observed" and (registered_identity != identity or not receipts
                                or not isinstance(residue, Mapping)):
        state = "harnessError"
    observed = dict(registered_identity) if state == "observed" and registered_identity else None
    disposition_evidence = (
        detach if mode == "attach" else by_operation.get("expectedExit") or primary
    )
    disposition = disposition_evidence.targetDisposition if disposition_evidence else "notStarted"
    rows, request_ledger = _operation_rows(observations, context)
    metadata = {"toolchainBinding": toolchain_binding, "fixtureBinding": fixture_binding}
    artifact_metadata = (supervisor_artifacts or {}).get("metadata", {})
    if isinstance(artifact_metadata, Mapping):
        metadata.update(artifact_metadata)
    if mode == "attach" and state == "observed":
        metadata.update(_derive_detach_metadata(observations, context, identity))
    return {
        "schemaVersion": 1, "candidate": candidate, "candidateVersion": version,
        "sessionID": context["sessionID"], "sessionEpoch": context["sessionEpoch"],
        "lifecycleRevision": context["lifecycleRevision"],
        "stopRevision": context["stopRevision"], "requestID": context["runID"],
        "mode": mode, "outcome": {"state": state, "evidence": journal_digest},
        "ownership": "attachedTestFixture" if mode == "attach" else "launched",
        "targetDisposition": disposition, "expectedIdentity": identity,
        "observedIdentity": observed, "capabilities": [],
        "operations": rows, "processRegistry": registry,
        "cleanupReceipts": receipts,
        "residueAudit": dict(residue) if isinstance(residue, Mapping) else {
            "auditedIdentities": [], "remainingIdentities": [], "complete": False,
            "evidence": {"reinspection": "missingSupervisorEvidence",
                         "registryDigest": hashlib.sha256(b"[]").hexdigest(),
                         "remainingCount": 0}},
        "diagnostics": [], "metadata": metadata,
        "rawBindings": {"targetPID": identity["pid"], "targetPath": identity["canonicalPath"],
                        "targetNonce": identity["nonce"],
                        "requestLedger": request_ledger},
    }


@dataclass
class ProbeCoordinator:
    dap_driver: object
    python_driver: object
    cli_driver: object
    journal: RawJournal
    _closed: bool = False

    def close(self) -> None:
        if self._closed:
            return
        for candidate in (self.dap_driver, self.python_driver, self.cli_driver):
            close = getattr(candidate, "close", None)
            receipt = close() if callable(close) else None
            if receipt is not None:
                self.journal.append("supervisor-receipt", {
                    "candidate": getattr(candidate, "candidate", "unknown"),
                    "receipt": _jsonable(dict(receipt)),
                })
        self._closed = True

    def close_then_snapshot(self, snapshot: Callable[[], Mapping[str, object]]) -> Mapping[str, object]:
        self.close()
        value = snapshot()
        if not isinstance(value, Mapping):
            raise ProbeError("supervisor snapshot must be a mapping")
        return value

    def discovery(self) -> list[dict[str, object]]:
        python = self.python_driver.discover()
        result = [
            {"candidate": "xcode-lldb-dap", "provenance": asdict(self.dap_driver.provenance())},
            {"candidate": "xcode-lldb-python-json", "discovery": asdict(python)},
            {"candidate": "macscope-lldb-cli-baseline", "provenance": asdict(self.cli_driver.provenance())},
        ]
        self.journal.append("discovery", {"candidates": result})
        return result

    def attach(self, target: drivers.ExactAttachTarget, control: drivers.FixtureControlClient,
               revalidate: Callable[[drivers.ExactAttachTarget], bool]) -> Mapping[str, Sequence[drivers.CandidateOperationEvidence]]:
        results = {}
        for candidate in (self.dap_driver, self.cli_driver):
            evidence = drivers.CandidateOrchestrator.attach_and_detach(
                candidate, str(uuid.uuid4()), target, control, revalidate)
            results[candidate.candidate] = evidence
            self.journal.append("candidate-run", {"candidate": candidate.candidate,
                                                   "mode": "attach",
                                                   "observations": [asdict(item) for item in evidence]})
        return results

    def launch(self, executable: Path, arguments: Sequence[str], cwd: Path,
               environment: Mapping[str, str]) -> Mapping[str, Sequence[drivers.CandidateOperationEvidence]]:
        results = {}
        for candidate in (self.dap_driver, self.cli_driver):
            launch_context = {
                "executable": str(executable.resolve()), "arguments": list(arguments),
                "workingDirectory": str(cwd.resolve()), "environment": dict(environment),
            }
            evidence = candidate.launch(str(uuid.uuid4()), executable, arguments, cwd, environment)
            observations = [evidence]
            exercise = getattr(candidate, "exercise_operation", None)
            for operation in schema.OPERATION_ORDER:
                if operation in {"configuredLaunch", "attach", "detach"}:
                    continue
                request_id = str(uuid.uuid4())
                if callable(exercise):
                    observed = exercise(request_id, operation, launch_context)
                    if not isinstance(observed, drivers.CandidateOperationEvidence):
                        raise ProbeError("candidate exercise_operation returned untyped evidence")
                    if observed.candidate != candidate.candidate or observed.operation != operation:
                        raise ProbeError("candidate operation evidence is bound to another operation")
                else:
                    negative = drivers.NegativeEvidence.from_text(
                        "notAttempted", operation,
                        "candidate does not expose this frozen operation probe",
                    )
                    observed = drivers.CandidateOperationEvidence(
                        candidate.candidate, operation, "notAttempted", request_id,
                        evidence.targetPID, "targetDispositionUnknown", {}, asdict(negative),
                    )
                observations.append(observed)
            results[candidate.candidate] = tuple(observations)
            self.journal.append("candidate-run", {"candidate": candidate.candidate,
                                                   "mode": "launch",
                                                   "observations": [asdict(item) for item in observations]})
        return results


def _not_attempted(candidate: str, operation: str, run_id: str,
                   target_pid: Optional[int] = None) -> drivers.CandidateOperationEvidence:
    negative = drivers.NegativeEvidence.from_text(
        "notAttempted", operation, "operation was not exercised in this candidate/mode run",
    )
    return drivers.CandidateOperationEvidence(
        candidate, operation, "notAttempted", run_id + ":" + operation,
        target_pid, "targetDispositionUnknown", {}, asdict(negative),
    )


def complete_operation_matrix(
    candidate: str, run_id: str,
    observations: Sequence[drivers.CandidateOperationEvidence],
) -> tuple[drivers.CandidateOperationEvidence, ...]:
    """Bind raw candidate facts to the frozen matrix without inventing success."""
    aliases = {"launch": "configuredLaunch", "disconnect": "detach"}
    by_operation: dict[str, drivers.CandidateOperationEvidence] = {}
    for item in observations:
        if item.candidate != candidate:
            raise ProbeError("candidate facts crossed a run ownership boundary")
        operation = aliases.get(item.operation, item.operation)
        if operation not in schema.OPERATION_ORDER or operation in by_operation:
            raise ProbeError("candidate emitted an unknown or duplicate semantic operation")
        if operation != item.operation:
            item = drivers.CandidateOperationEvidence(
                item.candidate, operation, item.observation, item.requestID,
                item.targetPID, item.targetDisposition, item.proof, item.negative,
            )
        by_operation[operation] = item
    proved_pids = {item.targetPID for item in observations if item.targetPID is not None}
    target_pid = next(iter(proved_pids)) if len(proved_pids) == 1 else None
    return tuple(by_operation.get(operation) or _not_attempted(
        candidate, operation, run_id, target_pid,
    ) for operation in schema.OPERATION_ORDER)


def _freeze_run_revision_context(
    observations: Sequence[drivers.CandidateOperationEvidence],
) -> tuple[drivers.CandidateOperationEvidence, ...]:
    """Project per-request revisions onto the final immutable run revision."""
    evidence = [(_validator_operation_evidence(item.proof), item)
                for item in observations if item.observation == "observed"]
    evidence = [(value, item) for value, item in evidence if isinstance(value, Mapping)]
    if not evidence:
        return tuple(observations)
    sessions = {(value.get("request", {}).get("runID"),
                 value.get("request", {}).get("sessionID"),
                 value.get("request", {}).get("sessionEpoch"))
                for value, _ in evidence}
    if len(sessions) != 1:
        raise ProbeError("observed facts crossed a run/session boundary")
    lifecycle = max(int(value["event"]["lifecycleRevision"]) for value, _ in evidence)
    stop = max(int(value["event"]["stopRevision"]) for value, _ in evidence)
    frozen: list[drivers.CandidateOperationEvidence] = []
    for item in observations:
        validator_evidence = _validator_operation_evidence(item.proof)
        if item.observation != "observed" or not isinstance(validator_evidence, Mapping):
            frozen.append(item)
            continue
        projected = dict(validator_evidence)
        request = dict(projected["request"])
        event = dict(projected["event"])
        # A request's stop revision is historical evidence.  In particular, a
        # step proves a transition only when its response event advances beyond
        # that request boundary.  The final run context binds lifecycle and the
        # accepted event revision, but never rewrites request history.
        request["lifecycleRevision"] = lifecycle
        event["lifecycleRevision"], event["stopRevision"] = lifecycle, stop
        projected["request"], projected["event"] = request, event
        proof = dict(item.proof)
        proof["validatorEvidence"] = projected
        frozen.append(drivers.CandidateOperationEvidence(
            item.candidate, item.operation, item.observation, item.requestID,
            item.targetPID, item.targetDisposition, proof, item.negative,
        ))
    return tuple(frozen)


def _merge_supervisor_contexts(
    snapshot: Mapping[str, object], candidate: str, mode: str,
) -> Mapping[str, object]:
    """Select only runtime facts owned by one candidate/mode run."""
    if isinstance(snapshot.get("processRegistry"), list):
        contexts = [snapshot]
    else:
        raw_contexts = snapshot.get("contexts")
        if not isinstance(raw_contexts, list):
            raise ProbeError("runtime snapshot has no run-owned supervisor contexts")
        contexts = [value for value in raw_contexts if isinstance(value, Mapping)
                    and value.get("candidate") == candidate and value.get("mode") == mode]
    if not contexts:
        return {
            "processRegistry": [], "cleanupReceipts": [], "cleanupComplete": True,
            "residueAudit": {"auditedIdentities": [], "remainingIdentities": [],
                "complete": True, "evidence": {"reinspection": "exactIdentity",
                    "registryDigest": hashlib.sha256(b"[]").hexdigest(),
                    "remainingCount": 0}},
            "signingEvidence": [],
            "metadata": {},
        }
    registry: list[object] = []
    receipts: list[object] = []
    signing: list[object] = []
    audited: list[object] = []
    metadata: dict[str, object] = {}
    for context in contexts:
        if context.get("candidate", candidate) != candidate or context.get("mode", mode) != mode:
            raise ProbeError("runtime snapshot crossed a candidate/mode ownership boundary")
        process_registry = context.get("processRegistry")
        cleanup_receipts = context.get("cleanupReceipts")
        residue = context.get("residueAudit")
        if (not isinstance(process_registry, list) or not isinstance(cleanup_receipts, list)
                or not isinstance(residue, Mapping) or residue.get("complete") is not True
                or residue.get("remainingIdentities") != []):
            raise ProbeError("runtime snapshot lacks complete zero-residue evidence")
        registry.extend(process_registry)
        receipts.extend(cleanup_receipts)
        audited.extend(residue.get("auditedIdentities", []))
        evidence = context.get("signingEvidence", [])
        if not isinstance(evidence, list):
            raise ProbeError("runtime signing evidence must be an array")
        signing.extend(evidence)
        context_metadata = context.get("metadata", {})
        if not isinstance(context_metadata, Mapping):
            raise ProbeError("runtime supervisor metadata must be an object")
        for key, value in context_metadata.items():
            if key in metadata and metadata[key] != value:
                raise ProbeError("runtime supervisor metadata conflicts across contexts")
            metadata[str(key)] = value
    if len({(item.get("role"), item.get("identity", {}).get("pid"))
            for item in registry if isinstance(item, Mapping)}) != len(registry):
        raise ProbeError("runtime snapshot repeats a run-owned process registration")
    identities = [item.get("identity") for item in registry if isinstance(item, Mapping)]
    if len(identities) != len(registry) or any(not isinstance(item, Mapping)
                                               for item in identities):
        raise ProbeError("runtime registry contains an invalid identity wrapper")
    return {
        "processRegistry": registry, "cleanupReceipts": receipts,
        "cleanupComplete": True,
        "residueAudit": {"auditedIdentities": audited, "remainingIdentities": [],
            "complete": True, "evidence": {"reinspection": "exactIdentity",
                "registryDigest": hashlib.sha256(json.dumps(
                    identities, sort_keys=True, separators=(",", ":"), allow_nan=False,
                ).encode("utf-8")).hexdigest(), "remainingCount": 0}},
        "signingEvidence": signing, "metadata": metadata,
    }


def _launch_target_from_supervisor(
    accepted: AcceptedLaunchIdentity, artifacts: Mapping[str, object],
) -> drivers.ExactAttachTarget:
    registry = artifacts.get("processRegistry")
    signing = artifacts.get("signingEvidence")
    if not isinstance(registry, list) or not isinstance(signing, list):
        raise ProbeError("launch supervisor evidence is malformed")
    targets = [item["identity"] for item in registry if isinstance(item, Mapping)
               and item.get("role") == "target" and isinstance(item.get("identity"), Mapping)]
    signers = [item.get("signingIdentity") for item in signing if isinstance(item, Mapping)
               and item.get("role") == "target"]
    if len(targets) != 1 or signers != [accepted.signingIdentity]:
        raise ProbeError("launch did not prove one exact signed target")
    value = targets[0]
    if (value.get("canonicalPath") != str(accepted.executable)
            or value.get("executableIdentity") != accepted.executableIdentity
            or str(value.get("machOUUID", "")).upper() != accepted.machOUUID
            or value.get("nonce") != accepted.nonce):
        raise ProbeError("launch runtime identity differs from accepted executable authority")
    try:
        return drivers.ExactAttachTarget(
            value["pid"], value["startTimeNS"], value["realUID"], value["effectiveUID"],
            value["canonicalPath"], value["cpuType"], value["cpuSubtype"],
            value["executableIdentity"], value["device"], value["inode"],
            value["machOUUID"], accepted.signingIdentity, value["nonce"], "launchedTarget",
        )
    except (KeyError, TypeError, ValueError) as error:
        raise ProbeError("launch supervisor identity is incomplete") from error


def _target_payload(target: drivers.ExactAttachTarget) -> Mapping[str, object]:
    return {key: getattr(target, key) for key in (
        "pid", "startTimeNS", "realUID", "effectiveUID", "canonicalPath", "cpuType",
        "cpuSubtype", "executableIdentity", "executableDevice", "executableInode",
        "machOUUID", "signingIdentity", "nonce",
    )}


def execute_candidate_mode(
    *, candidate: str, candidate_version: str, mode: str, driver: object,
    bridge: object, journal: RawJournal,
    launch_identity: Optional[AcceptedLaunchIdentity] = None,
    attach_target: Optional[drivers.ExactAttachTarget] = None,
    attach_control: Optional[drivers.FixtureControlClient] = None,
) -> CandidateRunProjection:
    """Execute exactly one candidate/mode and project facts after ordered cleanup."""
    if candidate not in schema.CANDIDATE_ORDER or mode not in {"launch", "attach"}:
        raise ProbeError("candidate/mode is outside the frozen matrix")
    run_id = str(uuid.uuid4())
    raw: tuple[drivers.CandidateOperationEvidence, ...] = ()
    raw_digest = ""
    snapshot: Optional[Mapping[str, object]] = None
    primary_error: Optional[BaseException] = None
    try:
        if mode == "launch":
            if launch_identity is None:
                raise ProbeError("launch run lacks accepted executable authority")
            with bridge.admission_boundary():
                primary = _normalize_candidate_evidence(driver.launch(
                    run_id + ":configuredLaunch", launch_identity.executable,
                    launch_identity.fixtureArguments, launch_identity.executable.parent, {},
                ), bridge)
            raw_items = [primary]
            exercise = getattr(driver, "exercise_operation", None)
            if callable(exercise):
                operation_context = {"executable": str(launch_identity.executable),
                    "arguments": list(launch_identity.fixtureArguments),
                    "workingDirectory": str(launch_identity.executable.parent),
                    "environment": {}}
                operation_arguments = getattr(bridge, "operation_arguments", None)
                if callable(operation_arguments):
                    value = operation_arguments()
                    if not isinstance(value, Mapping):
                        raise ProbeError("run operation arguments must be a mapping")
                    operation_context["operationArguments"] = dict(value)
                for operation in _launch_probe_operations():
                    item = _normalize_candidate_evidence(
                        exercise(run_id + ":" + operation, operation, operation_context),
                        bridge,
                    )
                    raw_items.append(item)
            raw = tuple(raw_items)
        else:
            if attach_target is None or attach_control is None:
                raise ProbeError("attach run lacks exact target/control authority")
            raw = _attach_candidate(
                candidate, driver, run_id, attach_target, attach_control, bridge,
            )
        raw = complete_operation_matrix(candidate, run_id, raw)
        raw_digest = journal.append("candidate-protocol-facts", {
            "candidate": candidate, "mode": mode,
            "observations": [_jsonable(asdict(item)) for item in raw],
        })
        # The journal is the immutable protocol chronology.  Freeze only the
        # aggregate projection; make_run stores its final revision separately
        # while the raw record retains every operation's historical revision.
        raw = _freeze_run_revision_context(raw)
    except BaseException as error:
        primary_error = error

    cleanup_errors: list[str] = []
    try:
        close_driver = getattr(driver, "close", None)
        if callable(close_driver):
            close_driver()
    except BaseException as error:
        cleanup_errors.append("candidate close: " + str(error))
    try:
        close_bridge = getattr(bridge, "close", None)
        if not callable(close_bridge):
            raise ProbeError("run-owned bridge has no close operation")
        close_bridge()
    except BaseException as error:
        cleanup_errors.append("bridge close: " + str(error))
    try:
        if attach_control is not None:
            attach_control.close()
    except BaseException as error:
        cleanup_errors.append("control close: " + str(error))
    try:
        take_snapshot = getattr(bridge, "supervisor_snapshot", None)
        if not callable(take_snapshot):
            raise ProbeError("run-owned bridge has no supervisor snapshot")
        value = take_snapshot()
        if not isinstance(value, Mapping) or value.get("cleanupComplete") is not True:
            raise ProbeError("run-owned bridge cleanup is incomplete")
        snapshot = value
    except BaseException as error:
        cleanup_errors.append("supervisor snapshot: " + str(error))
    if primary_error is not None:
        if cleanup_errors and hasattr(primary_error, "add_note"):
            primary_error.add_note("; ".join(cleanup_errors))
        raise primary_error
    if cleanup_errors:
        raise ProbeError("run cleanup failed: " + "; ".join(cleanup_errors))
    if snapshot is None or not raw_digest:
        raise ProbeError("run did not produce protocol and cleanup evidence")
    matrix = complete_operation_matrix(candidate, run_id, raw)
    artifacts = _merge_supervisor_contexts(snapshot, candidate, mode)
    target = (attach_target if mode == "attach" else
              _launch_target_from_supervisor(launch_identity, artifacts))
    registry = artifacts.get("processRegistry", [])
    process_attempted = isinstance(registry, list) and any(
        isinstance(item, Mapping) and item.get("role") in {
            "adapter", "target", "helper", "debugserver",
        } for item in registry
    )
    return CandidateRunProjection(
        candidate, candidate_version, mode, matrix, target, raw_digest,
        dict(artifacts), process_attempted,
    )


def _launch_probe_operations() -> tuple[str, ...]:
    """Return the causally complete launch baseline executable in this spike.

    Dynamic typed probes need UUID-qualified load addresses and session-derived
    debugger identifiers.  Until a candidate owns that dependency resolver, the
    complete report records those rows as ``notAttempted`` instead of executing
    incoherent commands.  A real terminal operation ends the test-owned target,
    and ``expectedExit`` independently binds the retained terminal fact.
    """
    return ("terminate", "expectedExit")


def emit_frozen_matrix(
    *, journal: RawJournal, toolchain: Mapping[str, object],
    fixture: Mapping[str, object], normalization_root: Path,
    discoveries: Mapping[str, Mapping[str, object]],
    run: Callable[[str, str, str], CandidateRunProjection],
) -> None:
    """Emit one context, three discoveries, and all six run projections.

    ``run`` owns construction of a fresh bridge and candidate instance for the
    supplied candidate/mode.  Keeping that factory boundary explicit prevents
    adapters, debuggees, and cleanup ledgers from leaking between matrix cells.
    """
    if set(discoveries) != set(schema.CANDIDATE_ORDER):
        raise ProbeError("matrix discovery must cover the exact frozen candidate set")
    journal.append("aggregate-context", {
        "toolchain": dict(toolchain), "fixture": dict(fixture),
        "normalizationRoot": str(normalization_root.resolve()),
    })
    versions: dict[str, str] = {}
    for candidate in schema.CANDIDATE_ORDER:
        value = discoveries[candidate]
        if set(value) != {"candidateVersion", "discovery"}:
            raise ProbeError("matrix discovery differs from the frozen input envelope")
        version, discovery = value["candidateVersion"], value["discovery"]
        if not isinstance(version, str) or not version or not isinstance(discovery, Mapping):
            raise ProbeError("matrix discovery identity is invalid")
        versions[candidate] = version
        journal.append("candidate-discovery", {
            "candidate": candidate, "candidateVersion": version,
            "discovery": dict(discovery),
        })
    for candidate in schema.CANDIDATE_ORDER:
        for mode in ("launch", "attach"):
            projection = run(candidate, mode, versions[candidate])
            if (not isinstance(projection, CandidateRunProjection)
                    or projection.candidate != candidate or projection.mode != mode
                    or projection.candidateVersion != versions[candidate]):
                raise ProbeError("matrix run projection crossed a candidate/mode boundary")
            if (len(projection.observations) != len(schema.OPERATION_ORDER)
                    or tuple(item.operation for item in projection.observations) != schema.OPERATION_ORDER):
                raise ProbeError("matrix run did not emit the complete frozen operation order")
            journal.append("candidate-run-projection", {
                "candidate": candidate, "candidateVersion": versions[candidate], "mode": mode,
                "observations": [_jsonable(asdict(item)) for item in projection.observations],
                "target": _target_payload(projection.target),
                "journalDigest": projection.journalDigest,
                "supervisorArtifacts": _jsonable(dict(projection.supervisorArtifacts)),
                "processAttempted": projection.processAttempted,
            })


def write_aggregate(path: Path, *, toolchain: Mapping[str, object], fixture: Mapping[str, object],
                    candidates: Sequence[Mapping[str, object]], normalization_root: Path) -> str:
    aggregate = schema.make_aggregate(
        toolchain=toolchain, fixture=fixture,
        normalization=schema.make_normalization(({"alias": "$ARTIFACT", "path": str(normalization_root.resolve())},)),
        candidates=candidates,
        validator=schema.make_validator_envelope(),
    )
    sealed = schema.seal_validator_digest(aggregate)
    payload = _sealed_report_bytes(sealed)
    path.write_bytes(payload)
    return hashlib.sha256(payload).hexdigest()


def validator_handoff(aggregate: Path, requirements: Sequence[str],
                      runner: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> int:
    command = [sys.executable, str(HERE / "validate_ws18.py"), str(aggregate), *requirements]
    completed = runner(command, check=False)
    return int(completed.returncode)


def _load_runtime_bridge(path: Path):
    specification = importlib.util.spec_from_file_location("ws18_runtime_bridge", path.resolve())
    if specification is None or specification.loader is None:
        raise ProbeError("unable to load runtime bridge")
    module = importlib.util.module_from_spec(specification)
    previous = sys.modules.get(specification.name)
    sys.modules[specification.name] = module
    try:
        specification.loader.exec_module(module)
    except BaseException:
        if previous is None:
            sys.modules.pop(specification.name, None)
        else:
            sys.modules[specification.name] = previous
        raise
    required = ("make_run_context",)
    if any(not callable(getattr(module, name, None)) for name in required):
        raise ProbeError("runtime bridge supervision contract lacks the run-owned factory")
    return module


def _make_run_context(bridge_module: object, candidate: str, mode: str,
                      per_cell_arguments: Mapping[str, object]) -> object:
    factory = getattr(bridge_module, "make_run_context", None)
    if not callable(factory):
        raise ProbeError("runtime bridge has no run-owned context factory")
    context = factory(candidate, mode, dict(per_cell_arguments))
    required = ("admission_boundary", "close", "supervisor_snapshot")
    if any(not callable(getattr(context, name, None)) for name in required):
        raise ProbeError("run-owned bridge context is incomplete")
    if mode == "attach" and not callable(getattr(context, "revalidate", None)):
        raise ProbeError("attach bridge context has no exact revalidation hook")
    return context


def _normalize_candidate_evidence(
    value: object, context: Optional[object] = None,
) -> drivers.CandidateOperationEvidence:
    """Normalize typed candidate facts at the one orchestration boundary."""
    if isinstance(value, drivers.CandidateOperationEvidence):
        return value
    operation = getattr(value, "semanticOperation", None)
    candidate = getattr(value, "candidate", None)
    observation = getattr(value, "observation", None)
    request_id = getattr(value, "requestID", None)
    if not all(isinstance(item, str) and item
               for item in (candidate, operation, observation, request_id)):
        raise ProbeError("candidate returned an untyped operation fact")
    proof = getattr(value, "protocolFact", {})
    negative = getattr(value, "negativeEvidence", getattr(value, "negative", {}))
    normalized_proof = dict(proof) if isinstance(proof, Mapping) else {}
    if (observation == "observed" and "validatorEvidence" not in normalized_proof
            and context is not None and normalized_proof.get("source") == "lldb-cli-transcript"):
        pid = getattr(value, "targetPID", None)
        observe = getattr(context, "observe_process", None)
        if not isinstance(pid, int) or not callable(observe):
            raise ProbeError("CLI observed fact lacks exact runtime authority")
        runtime_fact = observe(pid, operation)
        sequence = normalized_proof.get("commandSequence")
        session_id = normalized_proof.get("sessionToken")
        if (not isinstance(sequence, int) or sequence < 1
                or not isinstance(session_id, str) or not session_id):
            raise ProbeError("CLI observed fact lacks correlated session evidence")
        run_id = request_id.split(":", 1)[0]
        normalized_proof["validatorEvidence"] = {
            "request": {"id": request_id, "runID": run_id,
                "sessionID": session_id, "sessionEpoch": 1,
                "lifecycleRevision": sequence, "stopRevision": sequence},
            "event": {"sequence": sequence, "name": operation,
                "sessionID": session_id, "sessionEpoch": 1,
                "lifecycleRevision": sequence, "stopRevision": sequence},
            "postcondition": {"operation": operation, "satisfied": True,
                "detail": _canonical_evidence_detail(normalized_proof),
                "identity": _protocol_module_identity(operation, normalized_proof)},
        }
    return drivers.CandidateOperationEvidence(
        candidate, operation, observation, request_id,
        getattr(value, "targetPID", None),
        getattr(value, "targetDisposition", "targetDispositionUnknown"),
        normalized_proof,
        dict(negative) if isinstance(negative, Mapping) else {},
    )


def _canonical_evidence_detail(value: Mapping[str, object]) -> str:
    """Render structured evidence into the frozen nonempty detail string."""
    try:
        detail = json.dumps(
            _jsonable(dict(value)), sort_keys=True, separators=(",", ":"),
            ensure_ascii=False, allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        raise ProbeError("operation postcondition detail is not canonical JSON") from error
    if not detail:
        raise ProbeError("operation postcondition detail is empty")
    return detail


def _protocol_module_identity(
    operation: str, evidence: Mapping[str, object],
) -> Optional[Mapping[str, object]]:
    """Return only a module identity explicitly carried by protocol evidence."""
    if operation not in {"moduleList", "moduleLoad", "moduleUnload"}:
        return None
    containers = [evidence]
    for key in ("protocolFact", "postcondition", "evidence", "result"):
        nested = evidence.get(key)
        if isinstance(nested, Mapping):
            containers.append(nested)
    candidates: list[object] = []
    for container in containers:
        candidates.extend((container.get("moduleIdentity"), container.get("identity")))
        modules = container.get("modules")
        if isinstance(modules, list) and len(modules) == 1:
            candidates.append(modules[0])
    for value in candidates:
        if (isinstance(value, Mapping)
                and set(value) == {"path", "machOUUID"}
                and isinstance(value.get("path"), str)
                and isinstance(value.get("machOUUID"), str)):
            return dict(value)
    return None


def _project_dap_validator_evidence(
    context: object, protocol_fact: object, runtime_fact: object,
) -> Mapping[str, object]:
    """Project immutable DAP/runtime facts into the frozen validator envelope."""
    request_id = getattr(protocol_fact, "requestID", None)
    wire = getattr(protocol_fact, "wireCommands", ())
    if (not isinstance(request_id, str) or not request_id
            or not isinstance(wire, tuple) or not wire
            or any(not isinstance(item, Mapping) for item in wire)):
        raise ProbeError("DAP protocol fact lacks correlated wire requests")
    operation = getattr(protocol_fact, "semanticOperation", None)
    commands = tuple(item.get("command") for item in wire)
    valid_configured_launch = (
        operation == "configuredLaunch"
        and commands in {
            ("launch", "continue", "pause"),
            ("launch", "continue", "threads", "pause"),
            ("launch", "continue", "pause", "threads"),
            ("launch", "continue", "threads", "pause", "threads"),
        }
    )
    if len(wire) != 1 and not valid_configured_launch:
        raise ProbeError("DAP protocol fact has an invalid semantic wire sequence")
    request_sequences = tuple(item.get("requestSequence") for item in wire)
    if (any(not isinstance(value, int) or isinstance(value, bool)
            for value in request_sequences)
            or any(current <= previous for previous, current
                   in zip(request_sequences, request_sequences[1:]))):
        raise ProbeError("DAP protocol fact lacks a request sequence")
    request_sequence = request_sequences[0]
    runtime_evidence = getattr(runtime_fact, "evidence", None)
    if (not isinstance(operation, str) or not operation
            or not isinstance(runtime_evidence, Mapping)):
        raise ProbeError("DAP runtime fact is incomplete")
    run_id = request_id.split(":", 1)[0]
    session_id = "%s:%s:%s" % (context.candidate, context.mode, run_id)
    epoch = getattr(protocol_fact, "sessionEpoch", None)
    lifecycle = getattr(protocol_fact, "lifecycleRevision", None)
    stop = getattr(protocol_fact, "stopRevision", None)
    if any(not isinstance(value, int) or isinstance(value, bool)
           for value in (epoch, lifecycle, stop)):
        raise ProbeError("DAP protocol revisions are invalid")
    postcondition = getattr(protocol_fact, "postcondition", None)
    if not isinstance(postcondition, Mapping) or not postcondition:
        raise ProbeError("DAP semantic postcondition is missing")
    detail = dict(postcondition)
    semantic_fact_id = getattr(protocol_fact, "semanticFactID", None)
    if isinstance(semantic_fact_id, str) and semantic_fact_id:
        detail = {"semanticFactID": semantic_fact_id, "postcondition": detail}
    return {"validatorEvidence": {
        "request": {"id": request_id, "runID": run_id,
            "sessionID": session_id, "sessionEpoch": epoch,
            "lifecycleRevision": lifecycle, "stopRevision": stop},
        "event": {"sequence": request_sequence, "name": operation,
            "sessionID": session_id, "sessionEpoch": epoch,
            "lifecycleRevision": lifecycle, "stopRevision": stop},
        "postcondition": {"operation": operation, "satisfied": True,
            "detail": _canonical_evidence_detail(detail),
            "identity": _protocol_module_identity(operation, postcondition)},
    }}


def _project_python_validator_evidence(
    context: object, operation: str, protocol: Mapping[str, object],
) -> Mapping[str, object]:
    """Bind a typed Python bridge response to exact runtime and frozen revisions."""
    request_id = protocol.get("requestID")
    result = protocol.get("result")
    result = result if isinstance(result, Mapping) else {}
    target_pid = result.get("targetPID")
    if operation == "detach":
        post_detach = result.get("postDetach")
        pid = post_detach.get("pid") if isinstance(post_detach, Mapping) else None
        if (not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0
                or ("targetPID" in result and (
                    not isinstance(target_pid, int) or isinstance(target_pid, bool)
                    or target_pid <= 0))):
            raise ProbeError("Python detach response lacks exact target identity")
        if target_pid is not None and target_pid != pid:
            raise ProbeError("Python detach PID fields disagree")
    else:
        pid = target_pid
    if (not isinstance(request_id, str) or not request_id
            or not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0):
        raise ProbeError("Python protocol response lacks request/target identity")
    runtime_fact = context.observe_process(pid, operation)
    session_id = protocol.get("sessionID")
    epoch = protocol.get("sessionEpoch")
    lifecycle = protocol.get("lifecycleRevision")
    stop = protocol.get("stopRevision")
    sequence = protocol.get("sequence")
    if (not isinstance(session_id, str) or not session_id
            or any(not isinstance(value, int) or isinstance(value, bool)
                   for value in (epoch, lifecycle, stop, sequence))):
        raise ProbeError("Python protocol response lacks frozen session revisions")
    run_id = request_id.split(":", 1)[0]
    protocol_evidence = (dict(protocol.get("evidence", {}))
                         if isinstance(protocol.get("evidence"), Mapping) else {})
    return {"validatorEvidence": {
        "request": {"id": request_id, "runID": run_id,
            "sessionID": session_id, "sessionEpoch": epoch,
            "lifecycleRevision": lifecycle, "stopRevision": stop},
        "event": {"sequence": sequence, "name": operation,
            "sessionID": session_id, "sessionEpoch": epoch,
            "lifecycleRevision": lifecycle, "stopRevision": stop},
        "postcondition": {"operation": operation, "satisfied": True,
            "detail": _canonical_evidence_detail(protocol_evidence),
            "identity": _protocol_module_identity(operation, protocol_evidence)},
    }}


class _PersistentCLIMatrixDriver:
    """Expose the frozen candidate interface over one persistent LLDB process."""
    candidate = "macscope-lldb-cli-baseline"

    def __init__(self, session: object) -> None:
        self.session = session

    def launch(self, request_id: str, executable: Path, arguments: Sequence[str],
               cwd: Path, environment: Mapping[str, str]) -> object:
        return self.session.execute_operation("configuredLaunch", request_id, {
            "executable": str(executable.resolve()), "arguments": list(arguments),
            "workingDirectory": str(cwd.resolve()), "environment": dict(environment),
        })

    def exercise_operation(self, request_id: str, operation: str,
                           context: Mapping[str, object]) -> object:
        configured = context.get("operationArguments", {})
        operation_arguments = (configured.get(operation, {})
                               if isinstance(configured, Mapping) else {})
        if not isinstance(operation_arguments, Mapping):
            raise ProbeError("CLI operation arguments must be a mapping")
        arguments = dict(operation_arguments)
        if operation == "launchArguments":
            arguments.setdefault("arguments", context.get("arguments", ()))
        elif operation == "launchEnvironment":
            arguments.setdefault("environment", context.get("environment", {}))
        elif operation == "launchWorkingDirectory":
            arguments.setdefault("workingDirectory", context.get("workingDirectory"))
        try:
            return self.session.execute_operation(operation, request_id, arguments)
        except (TypeError, ValueError) as error:
            negative = drivers.NegativeEvidence.from_text(
                "notAttempted", operation,
                "CLI operation arguments are not evidence-bound: " + str(error),
            )
            return drivers.CandidateOperationEvidence(
                self.candidate, operation, "notAttempted", request_id, None,
                "targetDispositionUnknown", {}, asdict(negative),
            )

    def attach_and_detach(
        self, *, pid: int, attach_request_id: str, detach_request_id: str,
        on_attached: Optional[Callable[[object], object]] = None,
        post_detach_probe: Callable[[int], Mapping[str, object]],
    ) -> object:
        arguments = {
            "pid": pid,
            "attach_request_id": attach_request_id,
            "detach_request_id": detach_request_id,
            "post_detach_probe": post_detach_probe,
        }
        if on_attached is not None:
            arguments["on_attached"] = on_attached
        return self.session.attach_and_detach(**arguments)

    def close(self) -> object:
        return self.session.close()


def _attach_candidate(
    candidate: str, driver: object, run_id: str,
    target: drivers.ExactAttachTarget, control: drivers.FixtureControlClient,
    context: object,
) -> tuple[drivers.CandidateOperationEvidence, ...]:
    """Adapt three intentionally different candidate APIs without duck-typing calls."""
    if not context.revalidate(target):
        raise ProbeError("attach target failed exact pre-attach revalidation")
    if candidate == "xcode-lldb-dap" and not callable(
        getattr(driver, "attach_and_detach", None)
    ):
        with context.admission_boundary():
            attached = _normalize_candidate_evidence(
                driver.attach(run_id + ":attach", target), context
            )
        if attached.observation != "observed":
            return attached, _not_attempted(candidate, "detach", run_id, target.pid)
        if not context.revalidate(target):
            raise ProbeError("attach target changed identity after DAP attach")
        detached = _normalize_candidate_evidence(
            driver.detach(run_id + ":detach", control)
        )
        if not context.revalidate(target):
            raise ProbeError("attach target changed identity after DAP detach")
        return attached, detached
    if candidate == "xcode-lldb-python-json":
        with context.admission_boundary():
            attached = _normalize_candidate_evidence(
                driver.attach(run_id + ":attach", target), context)
        if attached.observation != "observed":
            return (attached, _not_attempted(candidate, "detach", run_id, target.pid))
        if not context.revalidate(target):
            raise ProbeError("attach target changed identity after Python attach")
        detached = _normalize_candidate_evidence(driver.detach(run_id + ":detach"))
        if detached.observation == "observed":
            proof = dict(detached.proof)
            proof["postDetachControl"] = _python_post_detach_checkpoint(proof, target)
            detached = drivers.CandidateOperationEvidence(
                detached.candidate, detached.operation, detached.observation,
                detached.requestID, detached.targetPID, detached.targetDisposition,
                proof, detached.negative,
            )
        if not context.revalidate(target):
            raise ProbeError("attach target changed identity after Python detach")
        return attached, detached

    session = getattr(driver, "attach_and_detach", None)
    if not callable(session):
        with context.admission_boundary():
            return drivers.CandidateOrchestrator.attach_and_detach(
                driver, run_id, target, control, context.revalidate,
            )
    parameters = inspect.signature(session).parameters
    if "post_detach_probe" in parameters:
        probe = getattr(context, "post_detach_probe", None)
        if not callable(probe):
            raise ProbeError("persistent CLI context lacks post-detach exact-control probe")
        normalized_attached = []
        def on_attached(value):
            normalized_attached.append(_normalize_candidate_evidence(value, context))
        with context.admission_boundary():
            result = session(pid=target.pid, attach_request_id=run_id + ":attach",
                             detach_request_id=run_id + ":detach",
                             on_attached=on_attached,
                             post_detach_probe=probe)
    else:
        with context.admission_boundary():
            result = session(run_id + ":attach", run_id + ":detach",
                             target.pid, control)
    if not isinstance(result, tuple) or len(result) != 2:
        raise ProbeError("candidate attach session returned an invalid fact pair")
    if "post_detach_probe" in parameters:
        if result[0].observation == "observed" and len(normalized_attached) != 1:
            raise ProbeError("persistent CLI attach was not admitted before detach")
        first = (normalized_attached[0] if normalized_attached
                 else _normalize_candidate_evidence(result[0], context))
        normalized = (first, _normalize_candidate_evidence(result[1], context))
    else:
        normalized = tuple(_normalize_candidate_evidence(item, context) for item in result)
    if not context.revalidate(target):
        raise ProbeError("attach target changed identity after candidate detach")
    return normalized


def _make_candidate_driver(candidate: str, runner: object, context: object) -> object:
    """Lazily compose one candidate with its one run-owned authority context."""
    if candidate == "xcode-lldb-dap":
        lifecycle = getattr(context, "make_dap_lifecycle", None)
        observe_process = getattr(context, "observe_process", None)
        if not callable(lifecycle) or not callable(observe_process):
            raise ProbeError("DAP run context lacks lifecycle or process authority")
        core = drivers.LldbDAPDriver(
            runner, adapter_lifecycle=lifecycle(),
        )
        module = _load("dap_candidate_adapter")
        return module.DAPCandidateAdapter(
            core,
            runtime_process_binder=lambda operation, acknowledgement, pid:
                observe_process(pid, operation),
            report_projector_binder=lambda protocol_fact, runtime_fact:
                _project_dap_validator_evidence(context, protocol_fact, runtime_fact),
        )
    if candidate == "xcode-lldb-python-json":
        module = _load("python_candidate_adapter")
        lifecycle = getattr(context, "make_python_lifecycle", None)
        authority = getattr(context, "make_python_authority", None)
        observe = getattr(context, "observe_process", None)
        if not all(callable(value) for value in (lifecycle, authority, observe)):
            raise ProbeError("Python run context lacks lifecycle, authority, or evidence binder")
        return module.PythonCandidateAdapter(
            runner, lifecycle=lifecycle(), authority=authority(),
            evidence_binder=lambda operation, protocol:
                _project_python_validator_evidence(context, operation, protocol),
        )
    if candidate == "macscope-lldb-cli-baseline":
        # The persistent CLI module is imported only for this matrix cell.  Its
        # run-owned adapter construction remains an explicit bridge contract.
        module = _load("lldb_cli_session")
        lifecycle = getattr(context, "make_cli_lifecycle", None)
        if not callable(lifecycle):
            raise ProbeError("CLI run context has no persistent lifecycle")
        path = drivers.discover_xcode_tool(runner, "lldb")
        return _PersistentCLIMatrixDriver(module.PersistentLLDBCLISession(
            path, lifecycle(), session_token="ws18-" + uuid.uuid4().hex,
        ))
    raise ProbeError("unknown frozen candidate")


def discover_frozen_candidates(
    runner: object, toolchain_binding: str,
) -> Mapping[str, Mapping[str, object]]:
    """Discover the exact selected-Xcode candidates without starting adapters."""
    if not toolchain_binding:
        raise ProbeError("toolchain binding is required for candidate discovery")
    dap_path = drivers.discover_xcode_tool(runner, "lldb-dap")
    cli_path = drivers.discover_xcode_tool(runner, "lldb")
    dap_provenance = drivers.tool_provenance(runner, dap_path)
    cli_provenance = drivers.tool_provenance(runner, cli_path)
    python_bridge = _load("lldb_python_bridge")
    python = python_bridge.discover_selected_xcode_lldb(runner)
    python_supported = bool(getattr(python, "supported", False))
    python_version = str(getattr(python, "version", "") or "unsupported")
    return {
        "xcode-lldb-dap": {
            "candidateVersion": dap_provenance.version,
            "discovery": {"state": "observed",
                "evidence": json.dumps(asdict(dap_provenance), sort_keys=True),
                "toolchainBinding": toolchain_binding},
        },
        "xcode-lldb-python-json": {
            "candidateVersion": python_version,
            "discovery": {
                "state": "observed" if python_supported else "structurallyUnsupported",
                "evidence": json.dumps(_jsonable(asdict(python)), sort_keys=True),
                "toolchainBinding": toolchain_binding,
            },
        },
        "macscope-lldb-cli-baseline": {
            "candidateVersion": cli_provenance.version,
            "discovery": {"state": "observed",
                "evidence": json.dumps(asdict(cli_provenance), sort_keys=True),
                "toolchainBinding": toolchain_binding},
        },
    }


def run_frozen_matrix(
    *, bridge_module: object, runner: object, journal: RawJournal,
    toolchain: Mapping[str, object], fixture: Mapping[str, object],
    normalization_root: Path, discoveries: Mapping[str, Mapping[str, object]],
    per_cell_arguments: Mapping[str, object],
) -> None:
    """Execute the strict 3x2 matrix with one fresh supervision owner per cell."""
    def run(candidate: str, mode: str, version: str) -> CandidateRunProjection:
        cell_arguments = _fresh_cell_arguments(
            per_cell_arguments, candidate, mode,
        )
        context = _make_run_context(
            bridge_module, candidate, mode, cell_arguments,
        )
        driver: Optional[object] = None
        control: Optional[drivers.FixtureControlClient] = None
        execution_started = False
        try:
            if mode == "launch":
                prepare = getattr(context, "prepare_launch", None)
                launch = prepare() if callable(prepare) else AcceptedLaunchIdentity(
                    Path(str(cell_arguments["executable"])),
                    str(cell_arguments["executable_identity"]),
                    str(cell_arguments["macho_uuid"]),
                    str(cell_arguments["signing_identity"]),
                    str(cell_arguments["nonce"]),
                    int(cell_arguments["started_after_ns"]),
                    Path(str(cell_arguments["control_dir"])),
                    tuple(str(value) for value in cell_arguments.get("argument", ())),
                )
                if not isinstance(launch, AcceptedLaunchIdentity):
                    raise ProbeError("launch context returned invalid accepted authority")
                driver = _make_candidate_driver(candidate, runner, context)
                execution_started = True
                return execute_candidate_mode(
                    candidate=candidate, candidate_version=version, mode=mode,
                    driver=driver, bridge=context, journal=journal,
                    launch_identity=launch,
                )
            prepare = getattr(context, "prepare_attach_helper", None)
            if not callable(prepare):
                raise ProbeError("attach context has no fresh helper preparation")
            prepared = prepare()
            if isinstance(prepared, tuple) and len(prepared) == 2:
                target, control = prepared
            else:
                target = prepared
                control = drivers.FixtureControlClient(
                    Path(str(getattr(context, "control_dir"))), "helper",
                    target.nonce, target.pid,
                ) if isinstance(target, drivers.ExactAttachTarget) else None
            if not isinstance(target, drivers.ExactAttachTarget):
                raise ProbeError("attach context returned invalid helper authority")
            if not callable(getattr(control, "close", None)):
                raise ProbeError("attach context returned invalid control authority")
            driver = _make_candidate_driver(candidate, runner, context)
            execution_started = True
            return execute_candidate_mode(
                candidate=candidate, candidate_version=version, mode=mode,
                driver=driver, bridge=context, journal=journal,
                attach_target=target, attach_control=control,
            )
        except BaseException:
            # execute_candidate_mode owns cleanup once entered.  Preparation or
            # construction failures still close the fresh per-cell authority.
            if not execution_started:
                if control is not None:
                    close_control = getattr(control, "close", None)
                    if callable(close_control):
                        close_control()
                close_context = getattr(context, "close", None)
                if callable(close_context):
                    close_context()
            raise

    emit_frozen_matrix(
        journal=journal, toolchain=toolchain, fixture=fixture,
        normalization_root=normalization_root, discoveries=discoveries, run=run,
    )


def _fresh_cell_arguments(
    base: Mapping[str, object], candidate: str, mode: str,
) -> Mapping[str, object]:
    """Create one empty 0700 fixture-control namespace per matrix cell."""
    root_value = base.get("control_root")
    if not isinstance(root_value, str):
        raise ProbeError("matrix arguments lack the verified control root")
    root = Path(root_value).resolve(strict=True)
    root_info = os.stat(root, follow_symlinks=False)
    if (not stat.S_ISDIR(root_info.st_mode) or root_info.st_uid != os.geteuid()
            or stat.S_IMODE(root_info.st_mode) != 0o700):
        raise ProbeError("matrix control root must be current-user mode 0700")
    threshold = max(int(base.get("started_after_ns", 0)), time.time_ns())
    cell = root / (candidate + "-" + mode + "-" + uuid.uuid4().hex)
    cell.mkdir(mode=0o700)
    nonce_seed = str(base.get("nonce_seed", "ws18"))[:64]
    nonce = nonce_seed + "-" + uuid.uuid4().hex
    user_arguments = (tuple(str(value) for value in base.get("argument", ()))
                      if mode == "launch" else ())
    fixture_arguments = user_arguments + (
        "--control-dir", str(cell), "--nonce", nonce,
        "--started-after-ns", str(threshold),
    )
    is_attach = mode == "attach"
    return {
        "command": mode,
        "control_dir": str(cell),
        "executable": base["executable"],
        "helper": base["helper"],
        "executable_identity": (base["helper_executable_identity"] if is_attach
                                else base["executable_identity"]),
        "macho_uuid": (base["helper_macho_uuid"] if is_attach
                       else base["macho_uuid"]),
        "signing_identity": (base["helper_signing_identity"] if is_attach
                             else base["signing_identity"]),
        "nonce": nonce,
        "started_after_ns": threshold,
        "argument": fixture_arguments,
        "environment": dict(base.get("environment", {})),
    }


def _load_json_object(path: Path, description: str) -> Mapping[str, object]:
    value = json.loads(path.resolve(strict=True).read_text())
    if not isinstance(value, Mapping):
        raise ProbeError(description + " must be a JSON object")
    return dict(value)


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run WS-18 debugger transport evidence probes")
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--runtime-bridge", type=Path,
                        help="reviewed local exact-identity/supervisor bridge required for live runs")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("discover")
    matrix = subparsers.add_parser(
        "matrix", help="execute the only aggregate-eligible 3-candidate x 2-mode run",
    )
    matrix.add_argument("--executable", type=Path, required=True)
    matrix.add_argument("--executable-sha256", required=True)
    matrix.add_argument("--macho-uuid", required=True)
    matrix.add_argument("--signing-identity", required=True)
    matrix.add_argument("--helper", type=Path, required=True)
    matrix.add_argument("--helper-sha256", required=True)
    matrix.add_argument("--helper-macho-uuid", required=True)
    matrix.add_argument("--helper-signing-identity", required=True)
    matrix.add_argument("--started-after-ns", type=int, required=True)
    matrix.add_argument("--nonce", required=True)
    matrix.add_argument("--control-root", type=Path, required=True)
    matrix.add_argument("--toolchain-context", type=Path, required=True)
    matrix.add_argument("--fixture-context", type=Path, required=True)
    matrix.add_argument("--output", type=Path, required=True)
    matrix.add_argument("argument", nargs="*")
    aggregate = subparsers.add_parser("aggregate")
    aggregate.add_argument("--output", type=Path, required=True)
    aggregate.add_argument("journal", nargs="+", type=Path)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--report", type=Path, required=True)
    validate.add_argument("--require-launch", action="store_true")
    validate.add_argument("--require-attach", action="store_true")
    validate.add_argument("--require-typed-selection-candidate", action="store_true")
    validate.add_argument("--require-cli-baseline", action="store_true")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = _argument_parser().parse_args(argv)
    root = arguments.artifact_root.resolve()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if arguments.command == "aggregate":
        try:
            aggregate_report_from_journals(arguments.journal, arguments.output,
                                           artifact_root=root)
            return 0
        except (OSError, ValueError, ProbeError, schema.SchemaError) as error:
            print("WS-18 journal aggregation failed: " + str(error), file=sys.stderr)
            return 2
    if arguments.command == "validate":
        requirements = [name for name, enabled in (
            ("--require-launch", arguments.require_launch),
            ("--require-attach", arguments.require_attach),
            ("--require-typed-selection-candidate", arguments.require_typed_selection_candidate),
            ("--require-cli-baseline", arguments.require_cli_baseline)) if enabled]
        return validator_handoff(arguments.report, requirements)
    runner = drivers.SubprocessRunner()
    bridge = _load_runtime_bridge(arguments.runtime_bridge) if arguments.runtime_bridge else None
    if arguments.command != "discover" and bridge is None:
        print("WS-18 live execution requires --runtime-bridge", file=sys.stderr)
        return 2
    if arguments.command == "matrix":
        journal: Optional[RawJournal] = None
        try:
            with _MatrixSignalBoundary():
                accepted = accepted_launch_identity(
                    arguments.executable,
                    executable_sha256=arguments.executable_sha256,
                    macho_uuid=arguments.macho_uuid,
                    signing_identity=arguments.signing_identity,
                    nonce=arguments.nonce,
                    started_after_ns=arguments.started_after_ns,
                    control_directory=arguments.control_root,
                    user_arguments=arguments.argument,
                )
                accepted_helper = accepted_launch_identity(
                    arguments.helper,
                    executable_sha256=arguments.helper_sha256,
                    macho_uuid=arguments.helper_macho_uuid,
                    signing_identity=arguments.helper_signing_identity,
                    nonce=arguments.nonce + "-helper",
                    started_after_ns=arguments.started_after_ns,
                    control_directory=arguments.control_root,
                    user_arguments=(),
                )
                toolchain = _load_json_object(arguments.toolchain_context, "toolchain context")
                fixture = _load_json_object(arguments.fixture_context, "fixture context")
                binding = toolchain.get("binding")
                if not isinstance(binding, str) or not binding:
                    raise ProbeError("toolchain context has no nonempty binding")
                per_cell_arguments = {
                    "executable": str(accepted.executable),
                    "executable_identity": accepted.executableIdentity,
                    "macho_uuid": accepted.machOUUID,
                    "signing_identity": accepted.signingIdentity,
                    "nonce_seed": accepted.nonce,
                    "started_after_ns": accepted.startedAfterNS,
                    "control_root": str(accepted.controlDirectory),
                    "argument": list(arguments.argument),
                    "helper": str(accepted_helper.executable),
                    "helper_executable_identity": accepted_helper.executableIdentity,
                    "helper_macho_uuid": accepted_helper.machOUUID,
                    "helper_signing_identity": accepted_helper.signingIdentity,
                }
                journal = RawJournal(root / "matrix-evidence.jsonl", artifact_root=root)
                discoveries = discover_frozen_candidates(runner, binding)
                run_frozen_matrix(
                    bridge_module=bridge, runner=runner, journal=journal,
                    toolchain=toolchain, fixture=fixture, normalization_root=root,
                    discoveries=discoveries, per_cell_arguments=per_cell_arguments,
                )
                journal.close()
                digest = aggregate_report_from_journals(
                    (journal.path,), arguments.output, artifact_root=root,
                )
                print(digest)
                return 0
        except MatrixSignalInterrupt as error:
            print("WS-18 matrix interrupted: " + str(error), file=sys.stderr)
            return error.exit_code
        except (OSError, ValueError, ProbeError, drivers.DriverError,
                schema.SchemaError, json.JSONDecodeError) as error:
            print("WS-18 matrix failed: " + str(error), file=sys.stderr)
            return 2
        finally:
            if journal is not None:
                journal.close()
    coordinator = ProbeCoordinator(
        drivers.LldbDAPDriver(runner), drivers.LldbPythonJSONDriver(runner),
        drivers.LldbCLIDriver(runner), RawJournal(root / "raw-evidence.jsonl"))
    try:
        coordinator.discovery()
    except (OSError, ValueError, ProbeError, drivers.DriverError) as error:
        coordinator.journal.append("harness-error", {"type": type(error).__name__, "diagnostic": str(error)})
        print("WS-18 probe failed: " + str(error), file=sys.stderr)
        return 2
    finally:
        coordinator.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
