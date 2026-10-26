#!/usr/bin/env python3
"""Subprocess-backed WS-18 debugger candidate drivers.

This module is deliberately import-safe: discovery and process creation occur only
when an explicit method is called.  Live launch/attach remains serialized operator
work; the unit tests inject runners and process factories.
"""

from __future__ import annotations

import hashlib
import importlib.util
import errno
import json
import math
import os
import re
import select
import stat
import subprocess
import sys
import threading
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Dict, Iterable, Mapping, Optional, Protocol, Sequence

try:
    import dap_transport as dap
except ModuleNotFoundError:  # importlib file loading in pure tests
    _dap_path = Path(__file__).resolve().with_name("dap_transport.py")
    _dap_spec = importlib.util.spec_from_file_location("dap_transport", _dap_path)
    if _dap_spec is None or _dap_spec.loader is None:
        raise RuntimeError("unable to load dap_transport.py")
    dap = importlib.util.module_from_spec(_dap_spec)
    sys.modules.setdefault("dap_transport", dap)
    _dap_spec.loader.exec_module(dap)


MAX_DIAGNOSTIC_BYTES = 4096
MAX_FIXTURE_EVENT_BYTES = 16 * 1024 * 1024
FIXTURE_SCHEMA = 1
FIXTURE_OPERATIONS = frozenset(("load", "checkpoint", "unload", "exit"))


class DriverError(RuntimeError):
    pass


@dataclass(frozen=True)
class CommandResult:
    argv: tuple[str, ...]
    returncode: int
    stdout: str = ""
    stderr: str = ""


class Runner(Protocol):
    def run(self, argv: Sequence[str], *, env: Optional[Mapping[str, str]] = None,
            timeout: float = 15.0) -> CommandResult: ...


class SubprocessRunner:
    def run(self, argv: Sequence[str], *, env: Optional[Mapping[str, str]] = None,
            timeout: float = 15.0) -> CommandResult:
        completed = subprocess.run(
            list(argv), capture_output=True, text=True, check=False, timeout=timeout,
            env=None if env is None else dict(env),
        )
        return CommandResult(tuple(argv), completed.returncode, completed.stdout, completed.stderr)


def _bounded(value: str) -> tuple[str, str, bool]:
    encoded = value.encode("utf-8", errors="replace")
    digest = hashlib.sha256(encoded).hexdigest()
    return encoded[:MAX_DIAGNOSTIC_BYTES].decode("utf-8", errors="replace"), digest, len(encoded) > MAX_DIAGNOSTIC_BYTES


@dataclass(frozen=True)
class NegativeEvidence:
    classification: str
    stage: str
    diagnosticPreview: str
    diagnosticSHA256: str
    diagnosticTruncated: bool
    returnCode: Optional[int] = None

    @classmethod
    def from_text(cls, classification: str, stage: str, text: str,
                  return_code: Optional[int] = None) -> "NegativeEvidence":
        preview, digest, truncated = _bounded(text)
        return cls(classification, stage, preview, digest, truncated, return_code)


@dataclass(frozen=True)
class ToolProvenance:
    path: str
    version: str
    sha256: str
    signing: Mapping[str, object]


def _checked(runner: Runner, argv: Sequence[str], *, timeout: float = 15.0,
             env: Optional[Mapping[str, str]] = None) -> CommandResult:
    result = runner.run(argv, timeout=timeout, env=env)
    if result.returncode != 0:
        raise DriverError("%s failed (%d): %s" % (
            argv[0], result.returncode, (result.stderr or result.stdout).strip()))
    return result


def selected_developer_dir(runner: Runner) -> Path:
    value = os.environ.get("DEVELOPER_DIR", "").strip()
    if not value:
        value = _checked(runner, ("/usr/bin/xcode-select", "-p")).stdout.strip()
    path = Path(value).resolve()
    if not value or not path.is_absolute():
        raise DriverError("selected Xcode developer directory is invalid")
    return path


def discover_xcode_tool(runner: Runner, name: str) -> Path:
    result = _checked(runner, ("/usr/bin/xcrun", "--find", name))
    path = Path(result.stdout.strip()).resolve()
    developer = selected_developer_dir(runner)
    if not path.is_file() or developer not in path.parents:
        raise DriverError("%s is not a file inside the selected Xcode" % name)
    return path


def tool_provenance(runner: Runner, path: Path) -> ToolProvenance:
    resolved = path.resolve(strict=True)
    version = _checked(runner, (str(resolved), "--version")).stdout.strip()
    digest = hashlib.sha256(resolved.read_bytes()).hexdigest()
    signing_result = runner.run(("/usr/bin/codesign", "-dvvv", str(resolved)), timeout=15.0)
    signing_text = "\n".join((signing_result.stdout, signing_result.stderr))
    fields: Dict[str, object] = {
        "verified": signing_result.returncode == 0,
        "teamIdentifier": _field(signing_text, "TeamIdentifier"),
        "identifier": _field(signing_text, "Identifier"),
        "cdhash": _field(signing_text, "CDHash"),
    }
    return ToolProvenance(str(resolved), version, digest, fields)


def _field(text: str, name: str) -> Optional[str]:
    match = re.search(r"(?:^|\n)%s=([^\n]+)" % re.escape(name), text)
    return match.group(1).strip() if match else None


def read_secure_bounded_file(path: Path, max_bytes: int,
                             minimum_mtime_ns: Optional[int] = None) -> bytes:
    """Read one exact owner-only regular file without allocating past its bound."""
    if max_bytes <= 0:
        raise ValueError("file read bound must be positive")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except FileNotFoundError:
        raise
    except OSError as error:
        raise DriverError("unable to open secure fixture event stream") from error
    try:
        before = os.fstat(descriptor)
        if (not stat.S_ISREG(before.st_mode)
                or stat.S_IMODE(before.st_mode) != 0o600
                or before.st_uid != os.geteuid()):
            raise DriverError(
                "fixture event stream owner, mode, or type is invalid")
        if (minimum_mtime_ns is not None
                and before.st_mtime_ns < minimum_mtime_ns):
            raise DriverError("fixture event stream predates this run")
        if before.st_size > max_bytes:
            raise DriverError("fixture event stream exceeds configured bound")
        raw = bytearray()
        while len(raw) <= max_bytes:
            chunk = os.read(descriptor, min(64 * 1024, max_bytes + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) > max_bytes:
            raise DriverError("fixture event stream exceeds configured bound")
        after = os.fstat(descriptor)
        if ((after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
                or not stat.S_ISREG(after.st_mode)
                or stat.S_IMODE(after.st_mode) != 0o600
                or after.st_uid != before.st_uid):
            raise DriverError("fixture event stream identity changed during read")
        return bytes(raw)
    finally:
        os.close(descriptor)


class FixtureControlClient:
    """Nonce/sequence-correlated client for one fixture role."""

    def __init__(self, control_dir: Path, role: str, nonce: str, pid: int,
                 *, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep,
                 writer: Optional[Callable[[Path, bytes], None]] = None,
                 reader: Optional[Callable[[Path], bytes]] = None,
                 minimum_event_mtime_ns: Optional[int] = None) -> None:
        if not role or not nonce or pid <= 0:
            raise ValueError("role, nonce, and positive PID are required")
        self.control_dir = control_dir.resolve()
        self.role, self.nonce, self.pid = role, nonce, pid
        self.clock, self.sleep = clock, sleep
        self._command_fd: Optional[int] = None
        self.writer = writer or self._write_persistent_fifo
        self.reader = reader or (
            lambda path: read_secure_bounded_file(
                path, MAX_FIXTURE_EVENT_BYTES, minimum_event_mtime_ns))
        self.next_command_sequence = 1
        self.last_event_sequence = 0

    @property
    def command_path(self) -> Path:
        return self.control_dir / (self.role + ".commands")

    @property
    def event_path(self) -> Path:
        return self.control_dir / (self.role + ".events.jsonl")

    @staticmethod
    def _validate_command_fifo(metadata: os.stat_result,
                               expected_identity: Optional[tuple[int, int]] = None) -> None:
        identity = (metadata.st_dev, metadata.st_ino)
        if (not stat.S_ISFIFO(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_uid != os.geteuid()
                or (expected_identity is not None and identity != expected_identity)):
            raise DriverError(
                "fixture command FIFO owner, mode, type, or identity is invalid")

    def open(self, *, timeout: float = 5.0) -> None:
        """Admit and retain the exact fixture FIFO writer before readiness polling."""
        if self._command_fd is not None:
            return
        if (not isinstance(timeout, (int, float)) or isinstance(timeout, bool)
                or not math.isfinite(timeout) or timeout <= 0):
            raise ValueError("fixture command FIFO timeout must be positive and bounded")
        deadline = self.clock() + timeout
        flags = os.O_WRONLY | os.O_NONBLOCK
        flags |= getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        while True:
            try:
                path_metadata = os.lstat(self.command_path)
                self._validate_command_fifo(path_metadata)
                descriptor = os.open(self.command_path, flags)
            except FileNotFoundError:
                pass
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise DriverError("unable to open fixture command FIFO") from error
            else:
                try:
                    opened_metadata = os.fstat(descriptor)
                    self._validate_command_fifo(
                        opened_metadata,
                        (path_metadata.st_dev, path_metadata.st_ino),
                    )
                except BaseException:
                    os.close(descriptor)
                    raise
                self._command_fd = descriptor
                return
            remaining = deadline - self.clock()
            if remaining <= 0:
                raise TimeoutError("fixture command FIFO admission timed out")
            self.sleep(min(0.01, remaining))

    def _write_persistent_fifo(self, path: Path, payload: bytes) -> None:
        if path != self.command_path:
            raise DriverError("fixture command path does not match the admitted FIFO")
        self.open()
        if self._command_fd is None:
            raise DriverError("fixture command FIFO admission did not retain a descriptor")
        offset = 0
        while offset < len(payload):
            written = os.write(self._command_fd, payload[offset:])
            if written <= 0:
                raise DriverError("fixture command FIFO write made no progress")
            offset += written

    def close(self) -> None:
        if self._command_fd is not None:
            os.close(self._command_fd)
            self._command_fd = None

    def __enter__(self) -> "FixtureControlClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def send(self, operation: str, *, timeout: float = 5.0) -> Mapping[str, object]:
        if operation not in FIXTURE_OPERATIONS:
            raise ValueError("unsupported fixture operation")
        sequence = self.next_command_sequence
        command = {"schema": FIXTURE_SCHEMA, "sequence": sequence,
                   "nonce": self.nonce, "operation": operation}
        payload = (json.dumps(command, sort_keys=True, separators=(",", ":")) + "\n").encode()
        self.writer(self.command_path, payload)
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            for event in self._events():
                if event["sequence"] <= self.last_event_sequence:
                    continue
                self.last_event_sequence = int(event["sequence"])
                if event.get("commandSequence") == sequence:
                    if event.get("operation") != operation or event.get("result") != "ok":
                        raise DriverError("fixture rejected correlated command")
                    self.next_command_sequence += 1
                    return event
            self.sleep(min(0.01, max(0.0, deadline - self.clock())))
        raise TimeoutError("fixture response timed out")

    def _events(self) -> list[Mapping[str, object]]:
        try:
            raw = self.reader(self.event_path)
        except FileNotFoundError:
            return []
        if len(raw) > MAX_FIXTURE_EVENT_BYTES:
            raise DriverError("fixture event stream exceeds configured bound")
        events = []
        for line in raw.splitlines():
            if not line:
                continue
            try:
                event = json.loads(line)
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise DriverError("fixture event stream is invalid JSONL") from error
            if not isinstance(event, dict):
                raise DriverError("fixture event is not an object")
            required = (event.get("schema") == FIXTURE_SCHEMA and
                        event.get("nonce") == self.nonce and event.get("role") == self.role and
                        event.get("pid") == self.pid and
                        isinstance(event.get("sequence"), int) and not isinstance(event.get("sequence"), bool))
            if not required:
                raise DriverError("fixture event identity mismatch")
            events.append(event)
        for previous, current in zip(events, events[1:]):
            if current["sequence"] <= previous["sequence"]:
                raise DriverError("fixture event sequence is not strictly monotonic")
        return events

    def read_events_bytes(self) -> bytes:
        """Return the admitted event bytes for sequence bookkeeping."""
        return self.reader(self.event_path)


@dataclass(frozen=True)
class CandidateOperationEvidence:
    candidate: str
    operation: str
    observation: str
    requestID: str
    targetPID: Optional[int]
    targetDisposition: str
    proof: Mapping[str, object]
    negative: Optional[Mapping[str, object]] = None


@dataclass(frozen=True)
class ExactAttachTarget:
    """Immutable harness-owned attach authorization; PID alone is insufficient."""
    pid: int
    startTimeNS: int
    realUID: int
    effectiveUID: int
    canonicalPath: str
    cpuType: int
    cpuSubtype: int
    executableIdentity: str
    executableDevice: int
    executableInode: int
    machOUUID: str
    signingIdentity: str
    nonce: str
    role: str = "attachedHelper"

    def __post_init__(self) -> None:
        if (self.pid <= 0 or self.startTimeNS <= 0 or self.realUID < 0 or self.effectiveUID < 0 or
                not self.canonicalPath.startswith("/") or
                not self.executableIdentity or not self.machOUUID or not self.signingIdentity or
                self.executableDevice < 0 or self.executableInode <= 0 or not self.nonce):
            raise ValueError("complete immutable attach identity is required")


@dataclass(frozen=True)
class DAPAcceptedEvent:
    """Immutable observer view of one event accepted by the DAP core."""

    eventSequence: int
    eventName: str
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int


@dataclass(frozen=True)
class DAPRequestAcknowledgement:
    """A correlated protocol response with harness-owned revision bindings."""

    response: Mapping[str, object]
    requestSequence: int
    command: str
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    acceptedEvents: tuple[DAPAcceptedEvent, ...] = ()
    requestEventBoundary: int = 0
    protocolFacts: Optional[dap.DAPLifecycleFacts] = None


@dataclass(frozen=True)
class DAPPostconditionProof:
    """Typed semantic evidence required before a DAP operation is observed."""

    operation: str
    requestSequence: int
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    targetPID: Optional[int]
    identityMatched: bool
    condition: str
    evidence: Mapping[str, object]
    acceptedEventSequence: Optional[int] = None
    acceptedEventName: Optional[str] = None


class DAPAdapterLifecycle(Protocol):
    """Exact-identity owner for adapter spawn, registration, and cleanup."""

    def spawn_and_register(self, adapter: Path) -> tuple[object, object]: ...
    def cleanup_adapter(self, registration: object) -> Mapping[str, object]: ...


class DAPProcessSession:
    """Persistent lldb-dap stdio session backed by the hardened DAP core.

    The session cannot spawn an adapter without an injected lifecycle owner that
    atomically returns both the process and its exact supervisor registration.
    No signal or process-group operation is performed here.
    """

    def __init__(
        self,
        adapter: Path,
        *,
        adapter_lifecycle: DAPAdapterLifecycle,
        session_epoch: int = 1,
        clock: Callable[[], float] = time.monotonic,
        diagnostic_capacity: int = MAX_DIAGNOSTIC_BYTES,
    ) -> None:
        if adapter_lifecycle is None:
            raise ValueError("exact adapter lifecycle owner is required")
        self.clock = clock
        self._lifecycle = adapter_lifecycle
        process, registration = adapter_lifecycle.spawn_and_register(adapter.resolve())
        stdin = getattr(process, "stdin", None)
        stdout = getattr(process, "stdout", None)
        stderr = getattr(process, "stderr", None)
        if stdin is None or stdout is None or stderr is None:
            try:
                receipt = adapter_lifecycle.cleanup_adapter(registration)
            except BaseException as error:
                raise DriverError(
                    "registered DAP adapter has invalid pipes and cleanup failed"
                ) from error
            if not (
                isinstance(receipt, Mapping)
                and receipt.get("role") == "adapter"
                and receipt.get("registration") == registration
                and receipt.get("complete") is True
            ):
                raise DriverError(
                    "registered DAP adapter has invalid pipes and no complete cleanup receipt"
                )
            raise DriverError("registered DAP adapter requires stdin, stdout, and stderr pipes")
        self.process = process
        self.registration = registration
        self.protocol = dap.DAPSession(session_epoch, clock)
        self.lifecycle = dap.DAPLifecycleStateMachine(self.protocol)
        self.parser = dap.DAPFrameParser()
        self.writer = dap.SerializedDAPWriter(stdin)
        self._adapter_sequence_mode: Optional[str] = None
        self._compat_adapter_sequence = 0
        self.stderr_output = dap.BoundedOutputBuffer(diagnostic_capacity)
        self._stderr_cancel = threading.Event()
        self._stderr_error: Optional[BaseException] = None
        self._stderr_thread = threading.Thread(
            target=self._drain_stderr,
            args=(stderr,),
            name="ws18-lldb-dap-stderr",
            daemon=True,
        )
        self._stderr_thread.start()
        self.closed = False
        self._close_receipt: Optional[Mapping[str, object]] = None

    @property
    def events(self) -> list[dap.EventEnvelope]:
        return self.protocol.events

    def request(
        self, command: str, arguments: Mapping[str, object], timeout: float
    ) -> DAPRequestAcknowledgement:
        if self.closed:
            raise DriverError("DAP session is closed")
        request_event_boundary = max(
            (int(envelope.message["seq"]) for envelope in self.protocol.events),
            default=0,
        )
        request = self.protocol.make_request(
            command, arguments, timeout_seconds=timeout
        )
        sequence = int(request["seq"])
        self.writer.send(request)
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            result = self.protocol.result_for(sequence)
            if result.response is not None:
                return self._acknowledgement(
                    sequence, command, request_event_boundary, None
                )
            self._pump_once(deadline, lifecycle=False)

        self.protocol.expire_deadlines()
        self.protocol.invalidate("request timeout invalidated adapter session")
        raise TimeoutError("lldb-dap request timed out")

    def initialize(
        self, arguments: Mapping[str, object], timeout: float
    ) -> DAPRequestAcknowledgement:
        request = self.lifecycle.begin_initialize(arguments, timeout)
        self.writer.send(request)
        deadline = self.clock() + timeout
        while self.clock() < deadline and not self.lifecycle.initialize_complete:
            self._pump_once(deadline, lifecycle=True)
        if not self.lifecycle.initialize_complete:
            self._timeout("initialize")
        return self._acknowledgement(int(request["seq"]), "initialize", 0, self.lifecycle.facts())

    def start(
        self, operation: str, arguments: Mapping[str, object], timeout: float
    ) -> DAPRequestAcknowledgement:
        request_event_boundary = self._event_boundary()
        request = self.lifecycle.begin_start(operation, arguments, timeout)
        # The start request is emitted immediately. configurationDone is held
        # until the adapter's initialized event is accepted.
        self.writer.send(request)
        deadline = self.clock() + timeout
        while self.clock() < deadline and not self.lifecycle.start_complete:
            configuration = self.lifecycle.configuration_request_if_ready(timeout)
            if configuration is not None:
                self.writer.send(configuration)
                continue
            self._pump_once(deadline, lifecycle=True)
        if not self.lifecycle.start_complete:
            self._timeout(operation)
        return self._acknowledgement(
            int(request["seq"]), operation, request_event_boundary, self.lifecycle.facts()
        )

    def disconnect(
        self, timeout: float, *, terminate_debuggee: bool
    ) -> DAPRequestAcknowledgement:
        request_event_boundary = self._event_boundary()
        request = self.lifecycle.begin_disconnect(
            timeout, terminate_debuggee=terminate_debuggee
        )
        self.writer.send(request)
        deadline = self.clock() + timeout
        while self.clock() < deadline and not self.lifecycle.disconnect_complete:
            self._pump_once(deadline, lifecycle=True)
        if not self.lifecycle.disconnect_complete:
            self._timeout("disconnect")
        return self._acknowledgement(
            int(request["seq"]), "disconnect", request_event_boundary, self.lifecycle.facts()
        )

    def _pump_once(self, deadline: float, *, lifecycle: bool) -> None:
        stdout = self.process.stdout
        remaining = max(0.0, deadline - self.clock())
        try:
            ready, _, _ = select.select((stdout,), (), (), remaining)
        except (OSError, ValueError) as error:
            self.protocol.invalidate("stdout readiness failure")
            raise DriverError("lldb-dap stdout readiness check failed") from error
        if not ready:
            return
        try:
            chunk = os.read(stdout.fileno(), 64 * 1024)
        except (OSError, ValueError) as error:
            self.protocol.invalidate("stdout read failure")
            raise DriverError("lldb-dap stdout read failed") from error
        if not chunk:
            try:
                self.parser.finish()
            finally:
                self.protocol.adapter_eof("stdout EOF")
            raise DriverError("lldb-dap closed stdout before lifecycle completion")
        for message in self.parser.feed(chunk):
            message = self._normalize_adapter_message(message)
            if lifecycle:
                self.lifecycle.accept(message)
                configuration = self.lifecycle.configuration_request_if_ready(
                    max(0.001, deadline - self.clock())
                )
                if configuration is not None:
                    self.writer.send(configuration)
            else:
                self.protocol.receive(message, session_epoch=self.protocol.session_epoch)

    def _normalize_adapter_message(
        self, message: Mapping[str, object]
    ) -> Mapping[str, object]:
        """Normalize Xcode's all-zero adapter sequence mode at the I/O boundary."""

        sequence = message.get("seq")
        is_integer = isinstance(sequence, int) and not isinstance(sequence, bool)
        mode = "zero" if is_integer and sequence == 0 else "strict"
        if is_integer and sequence >= 0:
            if self._adapter_sequence_mode is None:
                self._adapter_sequence_mode = mode
            elif self._adapter_sequence_mode != mode:
                raise dap.DAPProtocolError("adapter sequence mode changed during session")
        if mode != "zero":
            return message

        self._compat_adapter_sequence += 1
        normalized = dict(message)
        normalized["rawAdapterSequence"] = 0
        normalized["seq"] = self._compat_adapter_sequence
        return normalized

    def _acknowledgement(
        self,
        sequence: int,
        command: str,
        request_event_boundary: int,
        facts: Optional[dap.DAPLifecycleFacts],
    ) -> DAPRequestAcknowledgement:
        result = self.protocol.result_for(sequence)
        return DAPRequestAcknowledgement(
            response=result.response or {},
            requestSequence=sequence,
            command=command,
            sessionEpoch=result.session_epoch,
            lifecycleRevision=result.lifecycle_revision,
            stopRevision=result.stop_revision,
            acceptedEvents=tuple(
                DAPAcceptedEvent(
                    eventSequence=int(envelope.message["seq"]),
                    eventName=str(envelope.message["event"]),
                    sessionEpoch=envelope.session_epoch,
                    lifecycleRevision=envelope.lifecycle_revision,
                    stopRevision=envelope.stop_revision,
                )
                for envelope in self.protocol.events
            ),
            requestEventBoundary=request_event_boundary,
            protocolFacts=facts,
        )

    def _event_boundary(self) -> int:
        return max(
            (int(envelope.message["seq"]) for envelope in self.protocol.events),
            default=0,
        )

    def _timeout(self, operation: str) -> None:
        self.protocol.expire_deadlines()
        self.protocol.invalidate(operation + " lifecycle timeout invalidated adapter session")
        raise TimeoutError("lldb-dap %s lifecycle timed out" % operation)

    def close(self) -> Mapping[str, object]:
        if self._close_receipt is not None:
            return self._validated_close_receipt(self._close_receipt)
        self.closed = True
        self.protocol.invalidate("adapter session closed")
        try:
            receipt = dict(self._lifecycle.cleanup_adapter(self.registration))
            self._close_receipt = receipt
        finally:
            self._stderr_cancel.set()
            try:
                self.process.stdin.close()
            except (OSError, ValueError):
                pass
            self._stderr_thread.join(timeout=1.0)
            for stream in (self.process.stdout, self.process.stderr):
                try:
                    stream.close()
                except (OSError, ValueError):
                    pass
        return self._validated_close_receipt(self._close_receipt)

    def _drain_stderr(self, stream: object) -> None:
        try:
            dap.drain_stream(
                stream,
                self.stderr_output,
                cancellation=self._stderr_cancel,
            )
        except BaseException as error:
            self._stderr_error = error
            self.stderr_output.append(str(error).encode("utf-8", errors="replace"))

    def _validated_close_receipt(
        self, receipt: Optional[Mapping[str, object]]
    ) -> Mapping[str, object]:
        valid = (
            isinstance(receipt, Mapping)
            and receipt.get("role") == "adapter"
            and receipt.get("registration") == self.registration
            and receipt.get("complete") is True
        )
        if not valid:
            diagnostic = {
                "receiptType": type(receipt).__name__,
                "role": receipt.get("role") if isinstance(receipt, Mapping) else None,
                "registrationMatches": (
                    receipt.get("registration") == self.registration
                    if isinstance(receipt, Mapping) else False
                ),
                "complete": (
                    receipt.get("complete")
                    if isinstance(receipt, Mapping) else None
                ),
                "diagnostic": (
                    receipt.get("diagnostic")
                    if isinstance(receipt, Mapping) else None
                ),
            }
            raise DriverError(
                "adapter cleanup receipt is missing, mismatched, or incomplete: "
                + json.dumps(diagnostic, sort_keys=True, separators=(",", ":"))
            )
        return receipt


class LldbDAPDriver:
    candidate = "xcode-lldb-dap"

    def __init__(self, runner: Runner, *,
                 request: Optional[Callable[[Path, str, Mapping[str, object], float], DAPRequestAcknowledgement]] = None,
                 session_factory: Optional[Callable[[Path], DAPProcessSession]] = None,
                 adapter_lifecycle: Optional[DAPAdapterLifecycle] = None,
                 observe: Optional[Callable[[str, DAPRequestAcknowledgement, Optional[int]], DAPPostconditionProof]] = None) -> None:
        self.runner = runner
        self.path = discover_xcode_tool(runner, "lldb-dap")
        self._session: Optional[DAPProcessSession] = None
        self._session_factory = session_factory or (
            lambda path: DAPProcessSession(path, adapter_lifecycle=adapter_lifecycle)
        )
        self.request = request or self._live_request
        self.observe = observe

    def _live_request(self, path: Path, operation: str, arguments: Mapping[str, object],
                      timeout: float) -> DAPRequestAcknowledgement:
        if operation in {"launch", "attach"}:
            if self._session is not None:
                self._session.close()
                self._session = None
            self._session = self._session_factory(path)
            initialized = self._session.initialize({
                "clientID": "MacScope-WS18", "adapterID": "lldb-dap",
                "pathFormat": "path", "linesStartAt1": True, "columnsStartAt1": True,
            }, timeout)
            if initialized.response.get("success") is not True:
                raise DriverError("lldb-dap initialize failed")
            return self._session.start(operation, arguments, timeout)
        if self._session is None:
            raise DriverError("DAP operation requires an active start session")
        if operation == "disconnect":
            if (
                set(arguments) != {"terminateDebuggee"}
                or not isinstance(arguments.get("terminateDebuggee"), bool)
            ):
                raise DriverError(
                    "DAP disconnect requires an exact boolean termination policy"
                )
            return self._session.disconnect(
                timeout, terminate_debuggee=arguments["terminateDebuggee"]
            )
        return self._session.request(operation, arguments, timeout)

    def close(self) -> Optional[Mapping[str, object]]:
        if self._session is not None:
            receipt = self._session.close()
            self._session = None
            return receipt
        return None

    def provenance(self) -> ToolProvenance:
        return tool_provenance(self.runner, self.path)

    def launch(self, request_id: str, executable: Path, arguments: Sequence[str], cwd: Path,
               environment: Mapping[str, str]) -> CandidateOperationEvidence:
        body = {"program": str(executable.resolve()), "args": list(arguments),
                "cwd": str(cwd.resolve()), "env": dict(environment), "stopOnEntry": True}
        return self._request_evidence(request_id, "launch", body, None, "running")

    def attach(self, request_id: str, pid: int) -> CandidateOperationEvidence:
        if pid <= 0:
            raise ValueError("attach requires a positive test-owned PID")
        evidence = self._request_evidence(
            request_id, "attach", {"pid": pid, "stopOnEntry": True}, pid, "running"
        )
        if evidence.observation != "observed":
            return evidence
        postcondition = evidence.proof.get("postcondition", {})
        proved = postcondition.get("targetPID") if isinstance(postcondition, Mapping) else None
        if proved != pid:
            return self._negative(request_id, "attach", pid, "identityMismatch",
                                  "DAP did not explicitly prove the requested PID")
        return evidence

    def detach(self, request_id: str, pid: int, control: FixtureControlClient) -> CandidateOperationEvidence:
        evidence = self._request_evidence(request_id, "disconnect", {"terminateDebuggee": False}, pid, "detached")
        if evidence.observation != "observed":
            return CandidateOperationEvidence(self.candidate, "detach", evidence.observation,
                request_id, pid, "targetDispositionUnknown", evidence.proof, evidence.negative)
        checkpoint = control.send("checkpoint")
        proof = dict(evidence.proof)
        proof["postDetachControl"] = checkpoint
        return CandidateOperationEvidence(self.candidate, "detach", "observed", request_id,
                                          pid, "detached", proof)

    def _request_evidence(self, request_id: str, operation: str, arguments: Mapping[str, object],
                          pid: Optional[int], disposition: str) -> CandidateOperationEvidence:
        try:
            acknowledgement = self.request(self.path, operation, arguments, 30.0)
            if not isinstance(acknowledgement, DAPRequestAcknowledgement):
                raise TypeError("DAP request must return a typed acknowledgement")
            response = dict(acknowledgement.response)
            if response.get("success") is not True:
                return self._negative(request_id, operation, pid, "protocolError",
                                      "unsuccessful DAP response")
            response.pop("requestId", None)
            response["requestId"] = request_id
            if self.observe is None:
                negative = NegativeEvidence.from_text("notAttempted", operation,
                    "DAP response is acknowledgement only; no postcondition observer was supplied")
                return CandidateOperationEvidence(self.candidate, operation, "notAttempted", request_id,
                    pid, "targetDispositionUnknown", {"acknowledgement": response}, asdict(negative))
            proof = self.observe(operation, acknowledgement, pid)
            problem = self._postcondition_problem(operation, acknowledgement, proof, pid)
            if problem:
                return self._negative(request_id, operation, pid, "identityMismatch",
                                      problem)
            return CandidateOperationEvidence(self.candidate, operation, "observed", request_id,
                                              pid, disposition,
                                              {"acknowledgement": response,
                                               "requestArguments": dict(arguments),
                                               "postcondition": asdict(proof)})
        except TimeoutError as error:
            return self._negative(request_id, operation, pid, "timedOut", str(error))
        except Exception as error:
            return self._negative(request_id, operation, pid, "harnessError", str(error))

    def _postcondition_problem(
        self,
        operation: str,
        acknowledgement: DAPRequestAcknowledgement,
        proof: object,
        expected_pid: Optional[int],
    ) -> str:
        if not isinstance(proof, DAPPostconditionProof):
            raise TypeError("postcondition observer must return DAPPostconditionProof")
        if proof.operation != operation:
            return "postcondition operation does not match request"
        if proof.requestSequence != acknowledgement.requestSequence:
            return "postcondition request sequence does not match acknowledgement"
        if proof.sessionEpoch != acknowledgement.sessionEpoch:
            return "postcondition belongs to a different session epoch"
        protocol = getattr(getattr(self, "_session", None), "protocol", None)
        if not isinstance(protocol, dap.DAPSession):
            return "postcondition is not bound to the live DAP session"
        if protocol.session_epoch != acknowledgement.sessionEpoch:
            return "acknowledgement belongs to a different live DAP session"
        if proof.lifecycleRevision != acknowledgement.lifecycleRevision:
            return "postcondition lifecycle revision differs from acknowledgement"
        if proof.stopRevision != acknowledgement.stopRevision:
            return "postcondition stop revision differs from acknowledgement"
        if proof.lifecycleRevision != protocol.lifecycle_revision:
            return "postcondition lifecycle revision is not current"
        if proof.stopRevision != protocol.stop_revision:
            return "postcondition stop revision is not current"
        if not proof.condition or not proof.evidence:
            return "postcondition evidence is empty"
        if not proof.identityMatched or proof.targetPID is None or proof.targetPID <= 0:
            return "postcondition does not prove an exact target identity"
        if expected_pid is not None and proof.targetPID != expected_pid:
            return "postcondition target PID differs from the authorized target"
        if proof.evidence.get("processId") != proof.targetPID:
            return "postcondition evidence does not prove the target PID"

        accepted_snapshot = next(
            (
                event
                for event in acknowledgement.acceptedEvents
                if event.eventSequence == proof.acceptedEventSequence
            ),
            None,
        )
        if accepted_snapshot is None:
            return "postcondition event was not present when the request was acknowledged"
        if accepted_snapshot.eventSequence <= acknowledgement.requestEventBoundary:
            return "postcondition event predates request creation"
        if (
            accepted_snapshot.eventName != proof.acceptedEventName
            or accepted_snapshot.sessionEpoch != proof.sessionEpoch
            or accepted_snapshot.lifecycleRevision != proof.lifecycleRevision
            or accepted_snapshot.stopRevision != proof.stopRevision
        ):
            return "postcondition event differs from the acknowledged event snapshot"

        accepted_event = next(
            (
                envelope
                for envelope in protocol.events
                if envelope.message.get("seq") == proof.acceptedEventSequence
            ),
            None,
        )
        if accepted_event is None:
            return "postcondition event was not accepted by the live DAP session"
        if accepted_event.message.get("event") != proof.acceptedEventName:
            return "postcondition event name differs from the accepted DAP event"
        if accepted_event.session_epoch != proof.sessionEpoch:
            return "postcondition event belongs to a different session epoch"
        if accepted_event.lifecycle_revision != proof.lifecycleRevision:
            return "postcondition event lifecycle revision is not current"
        if accepted_event.stop_revision != proof.stopRevision:
            return "postcondition event stop revision is not current"

        required_event = {
            "launch": "stopped",
            "attach": "stopped",
            "disconnect": "terminated",
        }.get(operation)
        if required_event is None or proof.acceptedEventName != required_event:
            return "postcondition event does not prove the requested operation"
        process_identity_seen = any(
            envelope.session_epoch == proof.sessionEpoch
            and envelope.message.get("event") == "process"
            and isinstance(envelope.message.get("body"), Mapping)
            and envelope.message["body"].get("systemProcessId") == proof.targetPID
            for envelope in protocol.events
        )
        if not process_identity_seen:
            return "live DAP events do not prove the exact target process identity"
        try:
            result = protocol.prove_postcondition(
                proof.requestSequence,
                proof.condition,
                lifecycle_revision=proof.lifecycleRevision,
                stop_revision=proof.stopRevision,
            )
        except dap.DAPProtocolError as error:
            return str(error)
        if not result.observed or result.session_epoch != proof.sessionEpoch:
            return "DAP core did not promote the correlated request"
        return ""

    def _negative(self, request_id: str, operation: str, pid: Optional[int], classification: str,
                  message: str) -> CandidateOperationEvidence:
        negative = NegativeEvidence.from_text(classification, operation, message)
        return CandidateOperationEvidence(self.candidate, operation, classification, request_id,
                                          pid, "targetDispositionUnknown", {}, asdict(negative))


class LldbCLIDriver:
    candidate = "macscope-lldb-cli-baseline"

    def __init__(self, runner: Runner, *,
                 observe: Optional[Callable[[str, CommandResult, Optional[int]], "CLIPostconditionProof"]] = None,
                 session_lifecycle: Optional["CLISessionLifecycle"] = None) -> None:
        self.runner = runner
        self.path = discover_xcode_tool(runner, "lldb")
        self.observe = observe
        self.session_lifecycle = session_lifecycle

    def provenance(self) -> ToolProvenance:
        return tool_provenance(self.runner, self.path)

    def _run_commands(self, commands: Iterable[str], timeout: float = 30.0) -> CommandResult:
        argv = [str(self.path), "--no-lldbinit", "--batch"]
        for command in commands:
            argv.extend(("-o", command))
        if self.session_lifecycle is None:
            if isinstance(self.runner, SubprocessRunner):
                raise DriverError("live LLDB CLI execution requires an exact registered session lifecycle")
            return self.runner.run(argv, timeout=timeout)
        result, receipt = self.session_lifecycle.execute_and_cleanup(tuple(argv), timeout)
        if (receipt.get("role") != "adapter" or receipt.get("complete") is not True or
                not receipt.get("registration")):
            raise DriverError("LLDB CLI cleanup receipt is missing, mismatched, or incomplete")
        return result

    def launch(self, request_id: str, executable: Path, arguments: Sequence[str], cwd: Path,
               environment: Mapping[str, str]) -> CandidateOperationEvidence:
        commands = ["target create %s" % _lldb_quote(str(executable.resolve()))]
        commands += ["settings set target.env-vars %s=%s" % (key, _lldb_quote(value))
                     for key, value in sorted(environment.items())]
        commands += ["settings set target.run-args " + " ".join(_lldb_quote(item) for item in arguments),
                     "platform settings -w " + _lldb_quote(str(cwd.resolve())), "process launch -s"]
        return self._result(request_id, "launch", self._run_commands(commands), None, "running")

    def attach(self, request_id: str, pid: int) -> CandidateOperationEvidence:
        result = self._run_commands(("process attach --pid %d" % pid, "process status"))
        evidence = self._result(request_id, "attach", result, pid, "running")
        if evidence.observation == "observed" and not re.search(r"Process\s+%d\b" % pid, result.stdout):
            return self._negative(request_id, "attach", pid, "identityMismatch", result)
        return evidence

    def detach(self, request_id: str, pid: int, control: FixtureControlClient) -> CandidateOperationEvidence:
        result = self._run_commands(("process attach --pid %d" % pid, "process detach"))
        evidence = self._result(request_id, "detach", result, pid, "detached")
        if evidence.observation != "observed" or not re.search(r"detached", result.stdout, re.I):
            return self._negative(request_id, "detach", pid, "protocolError", result)
        checkpoint = control.send("checkpoint")
        return CandidateOperationEvidence(self.candidate, "detach", "observed", request_id, pid,
                                          "detached", {"stdoutSHA256": hashlib.sha256(result.stdout.encode()).hexdigest(),
                                                       "postDetachControl": checkpoint})

    def attach_and_detach(self, attach_request: str, detach_request: str, pid: int,
                          control: FixtureControlClient) -> tuple[CandidateOperationEvidence, CandidateOperationEvidence]:
        """Prove attach and detach in one LLDB process/session."""
        result = self._run_commands(("process attach --pid %d" % pid,
                                     "process status", "process detach"))
        if result.returncode != 0:
            failed = self._negative(attach_request, "attach", pid, "targetError", result)
            return failed, self._negative(detach_request, "detach", pid, "targetError", result)
        if not re.search(r"Process\s+%d\b" % pid, result.stdout):
            failed = self._negative(attach_request, "attach", pid, "identityMismatch", result)
            return failed, self._negative(detach_request, "detach", pid, "identityMismatch", result)
        if self.observe is None:
            unproved = self._negative(attach_request, "attach", pid, "identityMismatch", result)
            return unproved, self._negative(detach_request, "detach", pid, "identityMismatch", result)
        attach_proof = self.observe("attach", result, pid)
        if not isinstance(attach_proof, CLIPostconditionProof) or not attach_proof.identityMatched or attach_proof.targetPID != pid:
            unproved = self._negative(attach_request, "attach", pid, "identityMismatch", result)
            return unproved, self._negative(detach_request, "detach", pid, "identityMismatch", result)
        attached = CandidateOperationEvidence(self.candidate, "attach", "observed", attach_request,
            pid, "running", {"processId": pid, "sessionTranscriptSHA256": hashlib.sha256(result.stdout.encode()).hexdigest(),
                             "postcondition": asdict(attach_proof)})
        if not re.search(r"detached", result.stdout, re.I):
            return attached, self._negative(detach_request, "detach", pid, "protocolError", result)
        checkpoint = control.send("checkpoint")
        detach_proof = self.observe("detach", result, pid)
        if not isinstance(detach_proof, CLIPostconditionProof) or not detach_proof.identityMatched or detach_proof.targetPID != pid:
            return attached, self._negative(detach_request, "detach", pid, "identityMismatch", result)
        detached = CandidateOperationEvidence(self.candidate, "detach", "observed", detach_request,
            pid, "detached", {"sessionTranscriptSHA256": hashlib.sha256(result.stdout.encode()).hexdigest(),
                              "postDetachControl": checkpoint, "postcondition": asdict(detach_proof)})
        return attached, detached

    def _result(self, request_id: str, operation: str, result: CommandResult,
                pid: Optional[int], disposition: str) -> CandidateOperationEvidence:
        if result.returncode != 0:
            return self._negative(request_id, operation, pid, "targetError", result)
        if self.observe is None:
            negative = NegativeEvidence.from_text("notAttempted", operation,
                "LLDB command success is acknowledgement only; no postcondition observer was supplied")
            return CandidateOperationEvidence(self.candidate, operation, "notAttempted", request_id,
                pid, "targetDispositionUnknown", {"stdoutSHA256": hashlib.sha256(result.stdout.encode()).hexdigest()},
                asdict(negative))
        postcondition = self.observe(operation, result, pid)
        if not isinstance(postcondition, CLIPostconditionProof):
            negative = NegativeEvidence.from_text("harnessError", operation,
                "CLI postcondition observer returned an untyped proof")
            return CandidateOperationEvidence(self.candidate, operation, "harnessError", request_id,
                pid, "targetDispositionUnknown", {}, asdict(negative))
        if (postcondition.operation != operation or not postcondition.identityMatched or
                postcondition.targetPID <= 0 or not postcondition.canonicalPath or
                not postcondition.nonce or not postcondition.condition or not postcondition.evidence or
                (pid is not None and postcondition.targetPID != pid)):
            return self._negative(request_id, operation, pid, "identityMismatch", result)
        return CandidateOperationEvidence(self.candidate, operation, "observed", request_id,
                                          postcondition.targetPID,
                                          disposition, {"argv": list(result.argv),
                                          "stdoutSHA256": hashlib.sha256(result.stdout.encode()).hexdigest(),
                                          "postcondition": asdict(postcondition)})

    def _negative(self, request_id: str, operation: str, pid: Optional[int], classification: str,
                  result: CommandResult) -> CandidateOperationEvidence:
        negative = NegativeEvidence.from_text(classification, operation,
                                              result.stderr or result.stdout, result.returncode)
        return CandidateOperationEvidence(self.candidate, operation, classification, request_id,
                                          pid, "targetDispositionUnknown", {}, asdict(negative))


def _lldb_quote(value: str) -> str:
    return ('"' + value.replace("\\", "\\\\").replace('"', '\\"')
            .replace("`", "\\`") + '"')


@dataclass(frozen=True)
class CLIPostconditionProof:
    operation: str
    targetPID: int
    canonicalPath: str
    nonce: str
    identityMatched: bool
    condition: str
    evidence: Mapping[str, object]


class CLISessionLifecycle(Protocol):
    def execute_and_cleanup(self, argv: Sequence[str], timeout: float) -> tuple[CommandResult, Mapping[str, object]]: ...


@dataclass(frozen=True)
class PythonLLDBDiscovery:
    supported: bool
    pythonPath: Optional[str]
    modulePath: Optional[str]
    version: Optional[str]
    evidence: Mapping[str, object]


class LldbPythonJSONDriver:
    candidate = "xcode-lldb-python-json"

    def __init__(self, runner: Runner) -> None:
        self.runner = runner
        self.lldb_path = discover_xcode_tool(runner, "lldb")

    def discover(self) -> PythonLLDBDiscovery:
        search = self.runner.run((str(self.lldb_path), "--no-lldbinit", "--batch", "-P"), timeout=15.0)
        module_path = search.stdout.strip()
        if search.returncode != 0 or not module_path:
            return self._unsupported("lldb -P did not expose a module path", search)
        python_path = Path("/usr/bin/python3")
        probe = self.runner.run((str(python_path), "-c",
            "import json,lldb; print(json.dumps({'version':lldb.SBDebugger.GetVersionString()}))"),
            env={**os.environ, "PYTHONPATH": module_path}, timeout=15.0)
        if probe.returncode != 0:
            return self._unsupported("selected-Xcode LLDB Python import failed", probe, module_path)
        try:
            version = json.loads(probe.stdout)["version"]
        except (json.JSONDecodeError, KeyError, TypeError):
            return self._unsupported("LLDB Python probe returned invalid JSON", probe, module_path)
        return PythonLLDBDiscovery(False, str(python_path), module_path, str(version),
                                   {"reason": "LLDB import is available but the frozen typed operation bridge is not implemented",
                                    "importAvailable": True, "typedOperationBridge": False,
                                    "discoveryCommand": list(search.argv), "importCommand": list(probe.argv)})

    def start_bridge(self, discovery: PythonLLDBDiscovery,
                     popen: Callable[..., subprocess.Popen] = subprocess.Popen) -> subprocess.Popen:
        raise DriverError("LLDB Python bridge is structurally unsupported until typed operations are implemented")

    def _unsupported(self, reason: str, result: CommandResult,
                     module_path: Optional[str] = None) -> PythonLLDBDiscovery:
        negative = NegativeEvidence.from_text("unsupported", "pythonDiscovery",
                                              result.stderr or result.stdout or reason,
                                              result.returncode)
        return PythonLLDBDiscovery(False, None, module_path, None,
                                   {"reason": reason, "negative": asdict(negative),
                                    "command": list(result.argv)})


class CandidateOrchestrator:
    """Runs the frozen candidate order without converting failures into success."""

    def __init__(self, dap: LldbDAPDriver, python: LldbPythonJSONDriver, cli: LldbCLIDriver) -> None:
        self.dap, self.python, self.cli = dap, python, cli

    def discovery_report(self) -> Mapping[str, object]:
        python = self.python.discover()
        return {"candidates": [
            {"candidate": self.dap.candidate, "provenance": asdict(self.dap.provenance())},
            {"candidate": self.python.candidate, "discovery": asdict(python)},
            {"candidate": self.cli.candidate, "provenance": asdict(self.cli.provenance())},
        ]}

    @staticmethod
    def attach_and_detach(driver: object, request_prefix: str, target: ExactAttachTarget,
                          control: FixtureControlClient,
                          revalidate: Callable[[ExactAttachTarget], bool]) -> tuple[CandidateOperationEvidence, ...]:
        """Exact A/attach/detach/B orchestration for a fixture-owned helper only."""
        if control.pid != target.pid or control.nonce != target.nonce:
            raise DriverError("fixture control identity does not match attach authorization")
        if not revalidate(target):
            negative = NegativeEvidence.from_text("identityMismatch", "preAttach",
                                                  "test-owned helper identity changed before attach")
            return (CandidateOperationEvidence(getattr(driver, "candidate"), "attach",
                "identityMismatch", request_prefix + "-attach", target.pid,
                "targetDispositionUnknown", {}, asdict(negative)),)
        combined = getattr(driver, "attach_and_detach", None)
        if callable(combined):
            attached, detached = combined(request_prefix + "-attach", request_prefix + "-detach",
                                          target.pid, control)
            if attached.observation != "observed" or detached.observation != "observed":
                return (attached, detached)
        else:
            attached = driver.attach(request_prefix + "-attach", target.pid)
            if attached.observation != "observed":
                return (attached,)
            detached = driver.detach(request_prefix + "-detach", target.pid, control)
        if detached.observation != "observed":
            return (attached, detached)
        if not revalidate(target):
            negative = NegativeEvidence.from_text("identityMismatch", "postDetach",
                                                  "helper identity changed after detach acknowledgement")
            failed = CandidateOperationEvidence(getattr(driver, "candidate"), "detach",
                "identityMismatch", request_prefix + "-detach-proof", target.pid,
                "targetDispositionUnknown", {}, asdict(negative))
            return (attached, detached, failed)
        return (attached, detached)
