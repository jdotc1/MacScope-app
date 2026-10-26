#!/usr/bin/env python3
"""Hardened, dependency-free Debug Adapter Protocol transport primitives.

This module deliberately contains no LLDB process-launch behavior.  It owns the
wire protocol, harness-owned lifecycle fencing, and bounded stream plumbing used
by executable WS-18 candidate drivers.
"""

from __future__ import annotations

import json
import io
import select
import threading
from collections import deque
from dataclasses import dataclass
from enum import Enum
from typing import BinaryIO, Callable, Deque, Dict, List, Mapping, Optional, Protocol


class DAPProtocolError(ValueError):
    """A fail-closed DAP framing, correlation, or lifecycle error."""


class DAPTransportError(RuntimeError):
    """A byte-stream failure that prevents reliable DAP communication."""


class RequestState(str, Enum):
    PENDING = "pending"
    CANCELLATION_REQUESTED = "cancellationRequested"
    ACKNOWLEDGED = "acknowledged"
    OBSERVED = "observed"
    CANCELLED = "cancelled"
    TIMED_OUT = "timedOut"
    PROTOCOL_ERROR = "protocolError"
    HARNESS_ERROR = "harnessError"
    INVALIDATED = "invalidated"


_ACTIVE_STATES = {
    RequestState.PENDING,
    RequestState.CANCELLATION_REQUESTED,
    RequestState.ACKNOWLEDGED,
}
_LATE_RESPONSE_STATES = {
    RequestState.CANCELLED,
    RequestState.TIMED_OUT,
    RequestState.HARNESS_ERROR,
    RequestState.INVALIDATED,
}


def encode_frame(
    message: Mapping[str, object], *, max_body_bytes: int = 4 * 1024 * 1024
) -> bytes:
    """Encode one compact UTF-8 JSON object using DAP Content-Length framing."""

    if not isinstance(message, Mapping):
        raise TypeError("DAP message must be a mapping")
    if max_body_bytes <= 0:
        raise ValueError("max_body_bytes must be positive")
    try:
        body = json.dumps(
            dict(message), ensure_ascii=False, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise DAPProtocolError("DAP message is not JSON serializable") from error
    if not body or len(body) > max_body_bytes:
        raise DAPProtocolError("DAP body length is outside configured bounds")
    return f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body


class DAPFrameParser:
    """Incrementally decode bounded Content-Length framed DAP messages."""

    def __init__(
        self, max_body_bytes: int = 4 * 1024 * 1024, max_header_bytes: int = 16 * 1024
    ) -> None:
        if max_body_bytes <= 0 or max_header_bytes <= 0:
            raise ValueError("DAP frame limits must be positive")
        self._buffer = bytearray()
        self._body_length: Optional[int] = None
        self._max_body_bytes = max_body_bytes
        self._max_header_bytes = max_header_bytes
        self._finished = False

    def feed(self, data: bytes) -> List[Dict[str, object]]:
        if self._finished:
            raise DAPProtocolError("cannot feed a finished DAP parser")
        if not isinstance(data, bytes):
            raise TypeError("DAP input must be bytes")
        self._buffer.extend(data)
        decoded: List[Dict[str, object]] = []

        while True:
            if self._body_length is None:
                terminator = self._buffer.find(b"\r\n\r\n")
                if terminator < 0:
                    if len(self._buffer) > self._max_header_bytes:
                        raise DAPProtocolError("DAP header exceeds configured limit")
                    return decoded
                # A complete header cannot bypass the limit merely because its
                # terminator arrived in the same read.
                if terminator > self._max_header_bytes:
                    raise DAPProtocolError("DAP header exceeds configured limit")
                header = bytes(self._buffer[:terminator])
                del self._buffer[: terminator + 4]
                self._body_length = self._parse_content_length(header)

            body_length = self._body_length
            assert body_length is not None
            if len(self._buffer) < body_length:
                return decoded
            body = bytes(self._buffer[:body_length])
            del self._buffer[:body_length]
            self._body_length = None
            try:
                value = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise DAPProtocolError("DAP body is not valid UTF-8 JSON") from error
            if not isinstance(value, dict):
                raise DAPProtocolError("DAP body must be a JSON object")
            decoded.append(value)

    def finish(self) -> None:
        """Mark adapter EOF and reject any partial frame."""

        if self._finished:
            return
        self._finished = True
        if self._body_length is not None:
            raise DAPProtocolError("DAP stream ended with a truncated body")
        if self._buffer:
            raise DAPProtocolError("DAP stream ended with a truncated header")

    def _parse_content_length(self, header: bytes) -> int:
        try:
            text = header.decode("ascii")
        except UnicodeDecodeError as error:
            raise DAPProtocolError("DAP header must be ASCII") from error
        lengths: List[str] = []
        for line in text.split("\r\n"):
            if not line or ":" not in line:
                raise DAPProtocolError("malformed DAP header")
            name, value = line.split(":", 1)
            if name.strip().lower() == "content-length":
                lengths.append(value.strip())
        if len(lengths) != 1 or not lengths[0].isdigit():
            raise DAPProtocolError("DAP frame requires exactly one decimal Content-Length")
        length = int(lengths[0])
        if length <= 0 or length > self._max_body_bytes:
            raise DAPProtocolError("DAP body length is outside configured bounds")
        return length


class WritableBinary(Protocol):
    def write(self, data: bytes) -> int: ...


class SerializedDAPWriter:
    """Frame and fully write messages under a single serialization lock."""

    def __init__(self, stream: WritableBinary, max_body_bytes: int = 4 * 1024 * 1024) -> None:
        self._stream = stream
        self._max_body_bytes = max_body_bytes
        self._lock = threading.Lock()

    def send(self, message: Mapping[str, object]) -> None:
        frame = encode_frame(message, max_body_bytes=self._max_body_bytes)
        with self._lock:
            offset = 0
            while offset < len(frame):
                try:
                    written = self._stream.write(frame[offset:])
                except (OSError, ValueError) as error:
                    raise DAPTransportError("DAP stream write failed") from error
                if not isinstance(written, int) or written <= 0:
                    raise DAPTransportError("DAP stream write made no progress")
                if written > len(frame) - offset:
                    raise DAPTransportError("DAP stream reported an invalid write length")
                offset += written
            flush = getattr(self._stream, "flush", None)
            if callable(flush):
                try:
                    flush()
                except (OSError, ValueError) as error:
                    raise DAPTransportError("DAP stream flush failed") from error


@dataclass(frozen=True)
class EventEnvelope:
    message: Dict[str, object]
    session_epoch: int
    lifecycle_revision: int
    stop_revision: int


@dataclass(frozen=True)
class RequestResult:
    request_seq: int
    command: str
    operation: str
    state: RequestState
    evidence: str
    observed: bool
    response: Optional[Dict[str, object]]
    session_epoch: int
    lifecycle_revision: int
    stop_revision: int


@dataclass(frozen=True)
class DAPProcessEventFact:
    """Adapter-reported process fact; this is not an OS identity assertion."""

    eventSequence: int
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    systemProcessId: int
    startMethod: str
    isLocal: bool


@dataclass(frozen=True)
class DAPStoppedEventFact:
    eventSequence: int
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    reason: Optional[str]
    threadId: Optional[int]


@dataclass(frozen=True)
class DAPTerminalEventFact:
    eventSequence: int
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    eventName: str
    exitCode: Optional[int]


@dataclass(frozen=True)
class DAPLifecycleFacts:
    """Immutable facts derived exclusively from one accepted DAP transcript."""

    sessionEpoch: int
    operation: Optional[str]
    initializeRequestSequence: int
    startRequestSequence: Optional[int]
    configurationRequestSequence: Optional[int]
    disconnectRequestSequence: Optional[int]
    process: Optional[DAPProcessEventFact]
    stopped: Optional[DAPStoppedEventFact]
    terminated: Optional[DAPTerminalEventFact]
    exited: Optional[DAPTerminalEventFact]


@dataclass
class _PendingRequest:
    sequence: int
    command: str
    operation: str
    deadline: float
    bound_lifecycle_revision: int
    bound_stop_revision: int
    requires_stop: bool
    requires_new_stop: bool
    state: RequestState = RequestState.PENDING
    evidence: str = ""
    response: Optional[Dict[str, object]] = None


class DAPSession:
    """Bounded request/event correlation state for one harness epoch.

    Adapter responses acknowledge protocol requests.  Only an explicit harness
    call to :meth:`prove_postcondition` can promote an acknowledged operation to
    observed behavior.
    """

    def __init__(
        self,
        session_epoch: int,
        clock: Callable[[], float],
        *,
        max_pending: int = 256,
        max_events: int = 1024,
        max_late_messages: int = 128,
    ) -> None:
        if not isinstance(session_epoch, int) or session_epoch <= 0:
            raise ValueError("session_epoch must be a positive integer")
        if min(max_pending, max_events, max_late_messages) <= 0:
            raise ValueError("session store bounds must be positive")
        self.session_epoch = session_epoch
        self.lifecycle_revision = 0
        self.stop_revision = 0
        self._stopped = False
        self._clock = clock
        self._max_pending = max_pending
        self._events: Deque[EventEnvelope] = deque(maxlen=max_events)
        self._late_messages: Deque[Dict[str, object]] = deque(maxlen=max_late_messages)
        self._pending: Dict[int, _PendingRequest] = {}
        self._cancel_targets: Dict[int, int] = {}
        self._next_sequence = 1
        self._last_incoming_sequence = 0
        self._invalidated = False
        self.dropped_event_count = 0
        self.dropped_late_message_count = 0

    @property
    def events(self) -> List[EventEnvelope]:
        return list(self._events)

    @property
    def late_messages(self) -> List[Dict[str, object]]:
        return [dict(message) for message in self._late_messages]

    def make_request(
        self,
        command: str,
        arguments: Optional[Mapping[str, object]] = None,
        *,
        operation: Optional[str] = None,
        timeout_seconds: float = 5.0,
        requires_stop: bool = False,
        requires_new_stop: bool = False,
    ) -> Dict[str, object]:
        if self._invalidated:
            raise DAPProtocolError("DAP session is invalidated")
        if not command:
            raise ValueError("command is required")
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if requires_new_stop:
            requires_stop = True
        if requires_stop and not self._stopped:
            raise DAPProtocolError("stopped-state request requires a current stop")
        self._prune_terminal_requests_for_capacity()
        if len(self._pending) >= self._max_pending:
            raise DAPProtocolError("DAP pending request limit reached")

        sequence = self._next_sequence
        self._next_sequence += 1
        request: Dict[str, object] = {
            "seq": sequence,
            "type": "request",
            "command": command,
        }
        if arguments is not None:
            request["arguments"] = dict(arguments)
        self._pending[sequence] = _PendingRequest(
            sequence=sequence,
            command=command,
            operation=operation or command,
            deadline=self._clock() + timeout_seconds,
            bound_lifecycle_revision=self.lifecycle_revision,
            bound_stop_revision=self.stop_revision,
            requires_stop=requires_stop,
            requires_new_stop=requires_new_stop,
        )
        return request

    def _prune_terminal_requests_for_capacity(self) -> None:
        """Retain at most ``max_pending`` result records, oldest terminal first."""

        while len(self._pending) >= self._max_pending:
            removable = next(
                (
                    sequence
                    for sequence, record in self._pending.items()
                    if record.state not in _ACTIVE_STATES
                ),
                None,
            )
            if removable is None:
                return
            del self._pending[removable]
            self._cancel_targets.pop(removable, None)
            stale_cancel_sequences = [
                cancel_sequence
                for cancel_sequence, target_sequence in self._cancel_targets.items()
                if target_sequence == removable
            ]
            for cancel_sequence in stale_cancel_sequences:
                self._cancel_targets.pop(cancel_sequence, None)

    def receive(self, message: Mapping[str, object], *, session_epoch: int) -> None:
        if self._invalidated:
            raise DAPProtocolError("DAP session is invalidated")
        if session_epoch != self.session_epoch:
            relation = "older" if session_epoch < self.session_epoch else "different"
            raise DAPProtocolError(f"message belongs to an {relation} session epoch")
        sequence = message.get("seq")
        if (
            not isinstance(sequence, int)
            or isinstance(sequence, bool)
            or sequence <= self._last_incoming_sequence
        ):
            raise DAPProtocolError("adapter message sequence must be positive and monotonic")
        message_type = message.get("type")
        if message_type == "event":
            self._receive_event(message)
        elif message_type == "response":
            self._receive_response(message)
        else:
            raise DAPProtocolError("expected a DAP response or event")
        self._last_incoming_sequence = sequence

    def _receive_event(self, message: Mapping[str, object]) -> None:
        name = message.get("event")
        if not isinstance(name, str) or not name:
            raise DAPProtocolError("DAP event is missing its event name")
        if name == "stopped":
            self.lifecycle_revision += 1
            self.stop_revision += 1
            self._stopped = True
        elif name in {"continued", "process", "exited", "terminated"}:
            self.lifecycle_revision += 1
            if name != "process":
                self._stopped = False
        if len(self._events) == self._events.maxlen:
            self.dropped_event_count += 1
        self._events.append(
            EventEnvelope(
                message=dict(message),
                session_epoch=self.session_epoch,
                lifecycle_revision=self.lifecycle_revision,
                stop_revision=self.stop_revision,
            )
        )

    def _receive_response(self, message: Mapping[str, object]) -> None:
        request_sequence = message.get("request_seq")
        if not isinstance(request_sequence, int) or request_sequence not in self._pending:
            raise DAPProtocolError("response references an unknown request")
        pending = self._pending[request_sequence]
        command = message.get("command")
        if command != pending.command:
            raise DAPProtocolError("DAP response command mismatch")
        if pending.response is not None:
            raise DAPProtocolError("duplicate response for request")
        if pending.state in _LATE_RESPONSE_STATES:
            self._append_late(message)
            return
        if pending.state in {RequestState.OBSERVED, RequestState.PROTOCOL_ERROR}:
            raise DAPProtocolError("response arrived after request became terminal")

        pending.response = dict(message)
        succeeded = message.get("success") is True
        cancel_target = self._cancel_targets.get(request_sequence)
        if cancel_target is not None:
            self._complete_cancel_response(pending, cancel_target, succeeded, message)
            return

        if succeeded:
            # This also resolves a cancellation race in favor of the original
            # operation when its response arrived before cancel acknowledgement.
            pending.state = RequestState.ACKNOWLEDGED
            pending.evidence = "correlated DAP response; postcondition not yet proven"
        else:
            pending.state = RequestState.PROTOCOL_ERROR
            pending.evidence = str(message.get("message", "DAP request failed"))[:4096]

    def _complete_cancel_response(
        self,
        cancel: _PendingRequest,
        target_sequence: int,
        succeeded: bool,
        message: Mapping[str, object],
    ) -> None:
        target = self._pending[target_sequence]
        if succeeded:
            cancel.state = RequestState.ACKNOWLEDGED
            cancel.evidence = "correlated cancel acknowledgement"
            if target.state is RequestState.CANCELLATION_REQUESTED:
                target.state = RequestState.CANCELLED
                target.evidence = "cancel acknowledged before original response"
        else:
            cancel.state = RequestState.PROTOCOL_ERROR
            cancel.evidence = str(message.get("message", "cancel rejected"))[:4096]
            if target.state is RequestState.CANCELLATION_REQUESTED:
                target.state = RequestState.PENDING
                target.evidence = "cancel rejected; original request remains pending"

    def request_cancel(
        self, request_sequence: int, *, timeout_seconds: float = 2.0
    ) -> Dict[str, object]:
        target = self._pending.get(request_sequence)
        if target is None:
            raise DAPProtocolError("cannot cancel an unknown request")
        if target.state is not RequestState.PENDING:
            raise DAPProtocolError("cannot cancel a non-pending request")
        cancel = self.make_request(
            "cancel",
            {"requestId": request_sequence},
            operation="cancel",
            timeout_seconds=timeout_seconds,
        )
        target.state = RequestState.CANCELLATION_REQUESTED
        target.evidence = "cancel sent; acknowledgement pending"
        self._cancel_targets[int(cancel["seq"])] = request_sequence
        return cancel

    def prove_postcondition(
        self,
        request_sequence: int,
        evidence: str,
        *,
        lifecycle_revision: Optional[int] = None,
        stop_revision: Optional[int] = None,
    ) -> RequestResult:
        pending = self._pending.get(request_sequence)
        if pending is None:
            raise DAPProtocolError("unknown request")
        if pending.state is not RequestState.ACKNOWLEDGED:
            raise DAPProtocolError("postcondition requires an acknowledged request")
        if not evidence:
            raise ValueError("postcondition evidence is required")
        if lifecycle_revision is not None and lifecycle_revision != self.lifecycle_revision:
            raise DAPProtocolError("lifecycle revision changed before postcondition")
        if stop_revision is not None and stop_revision != self.stop_revision:
            raise DAPProtocolError("stop revision changed before postcondition")
        if pending.requires_new_stop:
            if not self._stopped or self.stop_revision <= pending.bound_stop_revision:
                raise DAPProtocolError("step requires a new stop revision")
        elif pending.requires_stop:
            if not self._stopped or self.stop_revision != pending.bound_stop_revision:
                raise DAPProtocolError("stop revision changed before postcondition")
        pending.state = RequestState.OBSERVED
        pending.evidence = evidence[:4096]
        return self.result_for(request_sequence)

    def result_for(self, request_sequence: int) -> RequestResult:
        pending = self._pending.get(request_sequence)
        if pending is None:
            raise DAPProtocolError("unknown request")
        return RequestResult(
            request_seq=pending.sequence,
            command=pending.command,
            operation=pending.operation,
            state=pending.state,
            evidence=pending.evidence,
            observed=pending.state is RequestState.OBSERVED,
            response=dict(pending.response) if pending.response is not None else None,
            session_epoch=self.session_epoch,
            lifecycle_revision=self.lifecycle_revision,
            stop_revision=self.stop_revision,
        )

    def expire_deadlines(self) -> List[int]:
        now = self._clock()
        expired: List[int] = []
        for sequence in sorted(self._pending):
            pending = self._pending[sequence]
            if pending.state in _ACTIVE_STATES and pending.deadline <= now:
                pending.state = RequestState.TIMED_OUT
                pending.evidence = "monotonic request deadline expired"
                expired.append(sequence)
                cancel_target = self._cancel_targets.get(sequence)
                if cancel_target is not None:
                    target = self._pending[cancel_target]
                    if target.state is RequestState.CANCELLATION_REQUESTED:
                        target.state = RequestState.TIMED_OUT
                        target.evidence = "cancel acknowledgement deadline expired"
        return expired

    def adapter_eof(self, detail: str) -> None:
        for pending in self._pending.values():
            if pending.state in _ACTIVE_STATES:
                pending.state = RequestState.HARNESS_ERROR
                pending.evidence = f"adapter EOF: {detail}"[:4096]
        self._invalidated = True

    def invalidate(self, detail: str) -> None:
        for pending in self._pending.values():
            if pending.state in _ACTIVE_STATES:
                pending.state = RequestState.INVALIDATED
                pending.evidence = detail[:4096]
        self._invalidated = True

    def _append_late(self, message: Mapping[str, object]) -> None:
        if len(self._late_messages) == self._late_messages.maxlen:
            self.dropped_late_message_count += 1
        self._late_messages.append(dict(message))


class DAPLifecycleStateMachine:
    """Frozen lldb-dap initialize/start/configure/stop/detach transcript.

    The machine deliberately records adapter protocol facts only.  Exact Darwin
    process identity and cleanup are separate supervisor responsibilities.
    """

    def __init__(self, session: DAPSession) -> None:
        self.session = session
        self._initialize: Optional[Dict[str, object]] = None
        self._start: Optional[Dict[str, object]] = None
        self._configuration: Optional[Dict[str, object]] = None
        self._disconnect: Optional[Dict[str, object]] = None
        self._operation: Optional[str] = None
        self._expected_pid: Optional[int] = None
        self._initialized_seen = False
        self._process: Optional[DAPProcessEventFact] = None
        self._stopped: Optional[DAPStoppedEventFact] = None
        self._terminated: Optional[DAPTerminalEventFact] = None
        self._exited: Optional[DAPTerminalEventFact] = None

    def begin_initialize(
        self, arguments: Mapping[str, object], timeout_seconds: float
    ) -> Dict[str, object]:
        if self._initialize is not None:
            raise DAPProtocolError("initialize was already sent for this adapter")
        self._initialize = self.session.make_request(
            "initialize", arguments, timeout_seconds=timeout_seconds
        )
        return dict(self._initialize)

    def begin_start(
        self,
        operation: str,
        arguments: Mapping[str, object],
        timeout_seconds: float,
    ) -> Dict[str, object]:
        if self._initialize is None:
            raise DAPProtocolError("initialize must be sent before start")
        if not self._request_succeeded(self._initialize):
            raise DAPProtocolError("initialize must be acknowledged before start")
        if self._start is not None:
            raise DAPProtocolError("a start request was already sent for this adapter")
        if operation not in {"launch", "attach"}:
            raise ValueError("start operation must be launch or attach")
        if arguments.get("stopOnEntry") is not True:
            raise DAPProtocolError("start requires stopOnEntry true")
        expected_pid: Optional[int] = None
        if operation == "attach":
            value = arguments.get("pid")
            if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
                raise DAPProtocolError("attach requires a positive requested PID")
            expected_pid = value
        self._operation = operation
        self._expected_pid = expected_pid
        self._start = self.session.make_request(
            operation, arguments, timeout_seconds=timeout_seconds
        )
        return dict(self._start)

    def configuration_request_if_ready(
        self, timeout_seconds: float
    ) -> Optional[Dict[str, object]]:
        if self._start is None or not self._initialized_seen or self._configuration is not None:
            return None
        self._configuration = self.session.make_request(
            "configurationDone", {}, timeout_seconds=timeout_seconds
        )
        return dict(self._configuration)

    def begin_disconnect(
        self, timeout_seconds: float, *, terminate_debuggee: bool
    ) -> Dict[str, object]:
        if not self.start_complete:
            raise DAPProtocolError("disconnect requires a completed stopped start")
        if self._disconnect is not None:
            raise DAPProtocolError("disconnect was already sent")
        if not isinstance(terminate_debuggee, bool):
            raise TypeError("terminate_debuggee must be a bool")
        expected_termination = self._operation == "launch"
        if terminate_debuggee != expected_termination:
            disposition = "terminate" if expected_termination else "preserve"
            raise DAPProtocolError(
                f"{self._operation} disconnect must {disposition} the debuggee"
            )
        self._disconnect = self.session.make_request(
            "disconnect", {"terminateDebuggee": terminate_debuggee},
            timeout_seconds=timeout_seconds,
        )
        return dict(self._disconnect)

    def accept(self, message: Mapping[str, object]) -> None:
        self.session.receive(message, session_epoch=self.session.session_epoch)
        if message.get("type") != "event":
            return
        name = message.get("event")
        envelope = self.session.events[-1]
        sequence = int(message["seq"])
        body_value = message.get("body", {})
        body = body_value if isinstance(body_value, Mapping) else {}

        if name == "initialized":
            if self._initialized_seen:
                raise DAPProtocolError("duplicate initialized event")
            if self._initialize is None:
                raise DAPProtocolError("initialized event arrived before initialize")
            self._initialized_seen = True
        elif name == "process":
            if self._start is None or self._operation is None:
                raise DAPProtocolError("process event arrived before start")
            if self._process is not None:
                raise DAPProtocolError("duplicate process event")
            pid = body.get("systemProcessId")
            if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
                raise DAPProtocolError("process event lacks a positive systemProcessId")
            if body.get("startMethod") != self._operation:
                raise DAPProtocolError("process event start method does not match request")
            if body.get("isLocalProcess") is not True:
                raise DAPProtocolError("process event does not identify a local process")
            if self._expected_pid is not None and pid != self._expected_pid:
                raise DAPProtocolError("process event PID differs from requested PID")
            self._process = DAPProcessEventFact(
                sequence,
                envelope.session_epoch,
                envelope.lifecycle_revision,
                envelope.stop_revision,
                pid,
                self._operation,
                True,
            )
        elif name == "stopped":
            if self._process is None:
                raise DAPProtocolError("stopped event arrived before exact process event")
            if sequence <= self._process.eventSequence:
                raise DAPProtocolError("stopped event does not follow process event")
            if self._stopped is not None:
                raise DAPProtocolError("duplicate stopped event")
            reason = body.get("reason")
            thread_id = body.get("threadId")
            self._stopped = DAPStoppedEventFact(
                sequence,
                envelope.session_epoch,
                envelope.lifecycle_revision,
                envelope.stop_revision,
                reason if isinstance(reason, str) else None,
                thread_id if isinstance(thread_id, int) and not isinstance(thread_id, bool) else None,
            )
        elif name in {"terminated", "exited"}:
            if self._disconnect is None:
                raise DAPProtocolError(f"{name} event arrived before disconnect")
            fact = DAPTerminalEventFact(
                sequence,
                envelope.session_epoch,
                envelope.lifecycle_revision,
                envelope.stop_revision,
                str(name),
                body.get("exitCode")
                if isinstance(body.get("exitCode"), int) and not isinstance(body.get("exitCode"), bool)
                else None,
            )
            if name == "terminated":
                if self._terminated is not None:
                    raise DAPProtocolError("duplicate terminated event")
                self._terminated = fact
            else:
                if self._exited is not None:
                    raise DAPProtocolError("duplicate exited event")
                self._exited = fact

    @property
    def initialize_complete(self) -> bool:
        return self._initialize is not None and self._request_succeeded(self._initialize)

    @property
    def start_complete(self) -> bool:
        return (
            self._start is not None
            and self._configuration is not None
            and self._request_succeeded(self._start)
            and self._request_succeeded(self._configuration)
            and self._process is not None
            and self._stopped is not None
        )

    @property
    def disconnect_complete(self) -> bool:
        return (
            self._disconnect is not None
            and self._request_succeeded(self._disconnect)
            and self._terminated is not None
        )

    def facts(self) -> DAPLifecycleFacts:
        if self._initialize is None:
            raise DAPProtocolError("initialize has not been sent")
        return DAPLifecycleFacts(
            sessionEpoch=self.session.session_epoch,
            operation=self._operation,
            initializeRequestSequence=int(self._initialize["seq"]),
            startRequestSequence=int(self._start["seq"]) if self._start else None,
            configurationRequestSequence=(
                int(self._configuration["seq"]) if self._configuration else None
            ),
            disconnectRequestSequence=(
                int(self._disconnect["seq"]) if self._disconnect else None
            ),
            process=self._process,
            stopped=self._stopped,
            terminated=self._terminated,
            exited=self._exited,
        )

    def _request_succeeded(self, request: Mapping[str, object]) -> bool:
        result = self.session.result_for(int(request["seq"]))
        return result.response is not None and result.response.get("success") is True


class BoundedOutputBuffer:
    """Thread-safe bounded byte tail with an exact dropped-byte count."""

    def __init__(self, capacity: int) -> None:
        if capacity <= 0:
            raise ValueError("output capacity must be positive")
        self._capacity = capacity
        self._value = bytearray()
        self._lock = threading.Lock()
        self.dropped_bytes = 0

    def append(self, data: bytes) -> None:
        if not isinstance(data, bytes):
            raise TypeError("output must be bytes")
        with self._lock:
            combined = self._value + data
            dropped = max(0, len(combined) - self._capacity)
            if dropped:
                del combined[:dropped]
                self.dropped_bytes += dropped
            self._value = combined

    def value(self) -> bytes:
        with self._lock:
            return bytes(self._value)


@dataclass(frozen=True)
class DrainResult:
    bytes_read: int
    eof: bool
    cancelled: bool
    timed_out: bool


def drain_stream(
    stream: BinaryIO,
    output: BoundedOutputBuffer,
    *,
    chunk_size: int = 16 * 1024,
    cancellation: Optional[threading.Event] = None,
    deadline: Optional[Callable[[], bool]] = None,
    poll_interval: float = 0.05,
) -> DrainResult:
    """Continuously drain a stream with bounded retention and stop checks.

    Streams exposing a file descriptor are polled before every read so an empty
    pipe cannot prevent cancellation or deadline handling.  In-memory and other
    descriptor-less streams must provide nonblocking ``read`` behavior.
    """

    if chunk_size <= 0 or poll_interval <= 0:
        raise ValueError("drain sizes and intervals must be positive")
    bytes_read = 0
    file_descriptor: Optional[int]
    try:
        file_descriptor = stream.fileno()
    except (AttributeError, OSError, ValueError, io.UnsupportedOperation):
        file_descriptor = None

    while True:
        if cancellation is not None and cancellation.is_set():
            return DrainResult(bytes_read, False, True, False)
        if deadline is not None and deadline():
            return DrainResult(bytes_read, False, False, True)
        if file_descriptor is not None:
            try:
                readable, _, _ = select.select([file_descriptor], [], [], poll_interval)
            except (OSError, ValueError) as error:
                raise DAPTransportError("stream readiness check failed") from error
            if not readable:
                continue
        try:
            chunk = stream.read(chunk_size)
        except (OSError, ValueError) as error:
            raise DAPTransportError("stream read failed") from error
        if chunk == b"":
            return DrainResult(bytes_read, True, False, False)
        if not isinstance(chunk, bytes):
            raise DAPTransportError("binary stream returned non-byte data")
        output.append(chunk)
        bytes_read += len(chunk)
