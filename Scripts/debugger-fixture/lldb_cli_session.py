#!/usr/bin/env python3
"""Persistent, supervisor-owned LLDB CLI session for the WS-18 baseline.

This module owns only CLI command correlation and transcript interpretation.
The injected lifecycle owns process creation, exact-identity registration, I/O,
and cleanup.  In particular, this module never creates or signals a process.
"""

from __future__ import annotations

import hashlib
import os
import re
import selectors
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Callable, Mapping, Optional, Protocol, Sequence


CANDIDATE = "macscope-lldb-cli-baseline"
MAX_DIAGNOSTIC_BYTES = 4096
MAX_TRANSCRIPT_BYTES = 256 * 1024
MAX_COMMAND_BYTES = 4096

OPERATION_ORDER = (
    "configuredLaunch", "launchArguments", "launchEnvironment",
    "launchWorkingDirectory", "initialBreakpoint", "attach", "detach",
    "terminate", "pause", "continue", "refresh", "runToCursor",
    "breakpointCreation", "breakpointHit", "breakpointDelete",
    "breakpointEnable", "breakpointDisable", "breakpointCondition",
    "breakpointIgnoreCount", "breakpointHitCount", "stepInto", "stepOver",
    "stepOut", "threadList", "threadSelection", "frameList",
    "frameSelection", "registerRead", "registerWrite", "memoryRead",
    "memoryWrite", "expressionEvaluation", "moduleList", "moduleLoad",
    "moduleUnload", "expectedExit", "cancelBeforeSpawn", "cancelInFlight",
    "timeoutRecovery", "adapterCrashRecovery",
)

# A synchronous LLDB command interpreter has no request identifier with which to
# cancel or recover a particular in-flight command.  The outer supervisor still
# bounds and cleans those fault cases, but that is not a CLI protocol capability.
STRUCTURALLY_UNSUPPORTED = (
    "cancelBeforeSpawn", "cancelInFlight", "timeoutRecovery",
    "adapterCrashRecovery",
)
SUPPORTED_OPERATIONS = tuple(
    operation for operation in OPERATION_ORDER
    if operation not in STRUCTURALLY_UNSUPPORTED
)

_TOKEN = re.compile(r"\A[A-Za-z0-9_-]{8,64}\Z")
_PROCESS_PID = re.compile(r"\bProcess\s+([1-9][0-9]*)\b")
_ERROR_LINE = re.compile(r"(?im)^\s*error:\s+")
_STOPPED = re.compile(r"\bstopped\b", re.IGNORECASE)
_DETACHED = re.compile(r"\bdetached\b", re.IGNORECASE)
_EXITED = re.compile(r"\b(?:exited|killed|terminated)\b", re.IGNORECASE)


class CLIChannel(Protocol):
    def exchange(self, payload: str, *, begin_marker: str, end_marker: str,
                 timeout: float, max_bytes: int) -> str: ...


class PipeCLIChannel:
    """Bounded synchronous exchange over one supervisor-owned child process.

    This object owns only the pipe I/O.  It never creates, waits for, or signals
    the process; those operations remain with the exact-identity lifecycle.
    """

    def __init__(self, stdin: BinaryIO, stdout: BinaryIO,
                 stderr: Optional[BinaryIO] = None, *,
                 process: Optional[object] = None) -> None:
        if stdin is None or stdout is None or stdin.closed or stdout.closed:
            raise ValueError("CLI channel requires open input and output pipes")
        if stderr is not None and stderr.closed:
            raise ValueError("CLI error pipe is closed")
        self.stdin = stdin
        self.stdout = stdout
        self.stderr = stderr
        self.process = process
        self._pending = bytearray()
        self._lock = threading.Lock()

    def exchange(self, payload: str, *, begin_marker: str, end_marker: str,
                 timeout: float, max_bytes: int) -> str:
        if not payload or not begin_marker or not end_marker:
            raise ValueError("CLI exchange requires payload and correlation markers")
        if timeout <= 0 or max_bytes <= 0:
            raise ValueError("CLI exchange deadline and byte bound must be positive")
        encoded_payload = payload.encode("utf-8")
        end = end_marker.encode("utf-8")
        with self._lock:
            if self.stdin.closed:
                raise RuntimeError("CLI input pipe is closed")
            try:
                self.stdin.write(encoded_payload)
                self.stdin.flush()
            except (BrokenPipeError, OSError, ValueError) as error:
                raise RuntimeError("CLI input pipe rejected the command") from error

            transcript = bytearray(self._pending)
            self._pending.clear()
            selector = selectors.DefaultSelector()
            try:
                for stream in (self.stdout, self.stderr):
                    if stream is not None and not stream.closed:
                        selector.register(stream, selectors.EVENT_READ)
                deadline = time.monotonic() + timeout
                while True:
                    exchange_end = _exact_marker_extent(transcript, end)
                    if exchange_end is not None:
                        if exchange_end > max_bytes:
                            raise ValueError("CLI transcript exceeded its byte bound")
                        self._pending.extend(transcript[exchange_end:])
                        return bytes(transcript[:exchange_end]).decode(
                            "utf-8", errors="replace")
                    if len(transcript) > max_bytes:
                        raise ValueError("CLI transcript exceeded its byte bound")
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("CLI exchange deadline exceeded")
                    ready = selector.select(remaining)
                    if not ready:
                        raise TimeoutError("CLI exchange deadline exceeded")
                    for key, _ in ready:
                        chunk = os.read(key.fd, min(8192, max_bytes + 1))
                        if chunk:
                            transcript.extend(chunk)
                        else:
                            selector.unregister(key.fileobj)
                    if not selector.get_map():
                        raise RuntimeError("CLI output pipes closed before the end marker")
            finally:
                selector.close()

    def close_pipes(self) -> None:
        """Close only this channel's file descriptors after supervisor cleanup."""

        for stream in (self.stdin, self.stdout, self.stderr):
            if stream is not None and not stream.closed:
                stream.close()


def _exact_marker_extent(transcript: bytearray, marker: bytes) -> Optional[int]:
    offset = 0
    for line in bytes(transcript).splitlines(keepends=True):
        offset += len(line)
        if line.rstrip(b"\r\n") == marker:
            return offset
    return None


class CLISessionLifecycle(Protocol):
    def open_cli_session(self, argv: Sequence[str]) -> tuple[CLIChannel, object]: ...
    def close_cli_session(self, registration: object, timeout: float) -> Mapping[str, object]: ...
    def authorize_launch(self, executable: str, arguments: Sequence[str], cwd: str,
                         environment: Mapping[str, str]) -> Mapping[str, object]: ...
    def begin_launch_readiness(self, pid: int, authorization: Mapping[str, object],
                               timeout: float) -> None: ...
    def accept_launch(self, pid: int, authorization: Mapping[str, object],
                      timeout: float) -> None: ...
    def accept_launch_stop(self, pid: int, authorization: Mapping[str, object],
                           timeout: float) -> Mapping[str, object]: ...


@dataclass(frozen=True)
class CLICommandRequest:
    semanticOperation: str
    requestID: str
    wireCommands: tuple[str, ...]
    expectedPID: Optional[int] = None
    requireStopped: bool = True
    expectedDisposition: str = "stopped"

    def __post_init__(self) -> None:
        if self.semanticOperation not in SUPPORTED_OPERATIONS:
            raise ValueError("operation is not an executable CLI operation")
        if not self.requestID or len(self.requestID.encode("utf-8")) > 256:
            raise ValueError("a bounded request ID is required")
        if not self.wireCommands:
            raise ValueError("at least one wire command is required")
        if self.expectedPID is not None and self.expectedPID <= 0:
            raise ValueError("expected PID must be positive")
        for command in self.wireCommands:
            encoded = command.encode("utf-8")
            if (not command or len(encoded) > MAX_COMMAND_BYTES or "\n" in command
                    or "\r" in command):
                raise ValueError("wire commands must be nonempty, single-line, and bounded")


@dataclass(frozen=True)
class CLIOperationObservation:
    candidate: str
    semanticOperation: str
    requestID: str
    observation: str
    targetPID: Optional[int]
    targetDisposition: str
    wireCommands: tuple[str, ...]
    protocolFact: Mapping[str, object]
    diagnosticPreview: str
    transcriptSHA256: str
    diagnosticTruncated: bool
    negativeEvidence: Mapping[str, object]


def classify_operation(operation: str) -> str:
    if operation in STRUCTURALLY_UNSUPPORTED:
        return "structurallyUnsupported"
    if operation in SUPPORTED_OPERATIONS:
        return "supported"
    raise ValueError("unknown WS-18 operation: " + operation)


class PersistentLLDBCLISession:
    """One registered LLDB interpreter and its correlated command stream."""

    def __init__(self, lldb_path: Path, lifecycle: CLISessionLifecycle, *,
                 session_token: str, timeout: float = 30.0,
                 max_transcript_bytes: int = MAX_TRANSCRIPT_BYTES) -> None:
        if not lldb_path.is_absolute():
            raise ValueError("LLDB path must be absolute")
        if not _TOKEN.fullmatch(session_token):
            raise ValueError("session token must be 8-64 safe ASCII characters")
        if timeout <= 0 or max_transcript_bytes <= 0:
            raise ValueError("timeout and transcript bound must be positive")
        self.lldb_path = lldb_path
        self.lifecycle = lifecycle
        self.session_token = session_token
        self.timeout = timeout
        self.max_transcript_bytes = max_transcript_bytes
        self._sequence = 0
        self._closed = False
        self._close_attempted = False
        self._close_error: Optional[BaseException] = None
        self._close_receipt: Optional[Mapping[str, object]] = None
        self._terminal_evidence: Optional[CLIOperationObservation] = None
        self._channel, self._registration = lifecycle.open_cli_session(
            (str(lldb_path), "--no-lldbinit")
        )

    def __enter__(self) -> "PersistentLLDBCLISession":
        return self

    def __exit__(self, exc_type, exc_value, traceback) -> None:
        del exc_type, exc_value, traceback
        self.close()

    def close(self) -> Mapping[str, object]:
        if self._close_receipt is not None:
            return self._close_receipt
        if self._close_error is not None:
            raise self._close_error
        if self._close_attempted:
            raise RuntimeError("CLI lifecycle close did not produce a durable result")
        self._close_attempted = True
        self._closed = True
        try:
            receipt = self.lifecycle.close_cli_session(self._registration, self.timeout)
        except BaseException as error:
            self._close_error = error
            raise
        if (receipt.get("role") != "adapter" or receipt.get("complete") is not True
                or receipt.get("registration") != self._registration):
            self._close_error = RuntimeError(
                "CLI lifecycle returned an incomplete cleanup receipt")
            raise self._close_error
        self._close_receipt = dict(receipt)
        return self._close_receipt

    def execute_operation(self, semantic_operation: str, request_id: str,
                          arguments: Optional[Mapping[str, object]] = None,
                          *, expected_pid: Optional[int] = None) -> CLIOperationObservation:
        classification = classify_operation(semantic_operation)
        if classification == "structurallyUnsupported":
            reason = {
                "cancelBeforeSpawn": "LLDB CLI has no command request before its interpreter is spawned",
                "cancelInFlight": "LLDB CLI has no correlated cancellation for an in-flight command",
                "timeoutRecovery": "LLDB CLI cannot fence and recover an individual timed-out command",
                "adapterCrashRecovery": "LLDB CLI cannot resume a crashed interpreter session",
            }[semantic_operation]
            return self._negative(semantic_operation, request_id, "unsupported", None,
                                  (), reason)
        if semantic_operation == "expectedExit":
            return self._retained_expected_exit(request_id)
        if semantic_operation == "configuredLaunch":
            return self._configured_launch(request_id, arguments or {})
        try:
            commands, require_stopped, disposition = _wire_commands(
                semantic_operation, arguments or {}
            )
        except (AttributeError, TypeError, ValueError) as error:
            return self._negative(
                semantic_operation, request_id, "notAttempted", expected_pid, (),
                "invalid CLI operation arguments: " + str(error),
            )
        return self.execute(CLICommandRequest(
            semantic_operation, request_id, commands, expected_pid,
            require_stopped, disposition,
        ))

    def execute(self, request: CLICommandRequest) -> CLIOperationObservation:
        if request.semanticOperation == "configuredLaunch":
            raise ValueError(
                "configured launch must pass through run-owned authorization")
        return self._execute_request(request)

    def _execute_request(self, request: CLICommandRequest) -> CLIOperationObservation:
        if self._closed:
            raise RuntimeError("CLI session is closed")
        self._sequence += 1
        correlation = hashlib.sha256(request.requestID.encode("utf-8")).hexdigest()[:16]
        prefix = "__MACSCOPE_WS18_CLI__%s_%d_%s" % (
            self.session_token, self._sequence, correlation)
        begin_marker, end_marker = prefix + "_BEGIN", prefix + "_END"
        wire_commands = request.wireCommands
        if request.requireStopped and wire_commands[-1] != "process status":
            wire_commands += ("process status",)
        payload_lines = ["script print(%r)" % begin_marker]
        payload_lines.extend(wire_commands)
        payload_lines.append("script print(%r)" % end_marker)
        payload = "\n".join(payload_lines) + "\n"
        try:
            raw = self._channel.exchange(
                payload, begin_marker=begin_marker, end_marker=end_marker,
                timeout=self.timeout, max_bytes=self.max_transcript_bytes,
            )
        except TimeoutError as error:
            return self._negative(request.semanticOperation, request.requestID,
                                  "timedOut", request.expectedPID, wire_commands,
                                  str(error))
        except Exception as error:
            return self._negative(request.semanticOperation, request.requestID,
                                  "harnessError", request.expectedPID, wire_commands,
                                  str(error))
        try:
            transcript = _correlated_transcript(
                raw, begin_marker, end_marker, self.max_transcript_bytes)
        except ValueError as error:
            return self._negative(request.semanticOperation, request.requestID,
                                  "protocolError", request.expectedPID, wire_commands,
                                  str(error), raw)

        target_pid = _exact_process_pid(transcript)
        if target_pid is None or (request.expectedPID is not None
                                  and target_pid != request.expectedPID):
            return self._negative(request.semanticOperation, request.requestID,
                                  "identityMismatch", None, wire_commands,
                                  "transcript did not prove exactly the authorized target PID",
                                  transcript)
        if _ERROR_LINE.search(transcript):
            return self._negative(request.semanticOperation, request.requestID,
                                  "protocolError", target_pid, wire_commands,
                                  "LLDB reported a command error", transcript)
        if request.requireStopped and not _STOPPED.search(transcript):
            return self._negative(request.semanticOperation, request.requestID,
                                  "protocolError", target_pid, wire_commands,
                                  "operation did not prove a stopped target", transcript)
        if request.expectedDisposition == "detached" and not _DETACHED.search(transcript):
            return self._negative(request.semanticOperation, request.requestID,
                                  "protocolError", target_pid, wire_commands,
                                  "detach acknowledgement is absent", transcript)
        if request.expectedDisposition in {"terminated", "exited"} and not _EXITED.search(transcript):
            return self._negative(request.semanticOperation, request.requestID,
                                  "protocolError", target_pid, wire_commands,
                                  "target exit acknowledgement is absent", transcript)

        preview, digest, truncated = _bounded(transcript)
        fact = {
            "source": "lldb-cli-transcript",
            "sessionToken": self.session_token,
            "commandSequence": self._sequence,
            "requestID": request.requestID,
            "semanticOperation": request.semanticOperation,
            "wireCommandSHA256": hashlib.sha256(
                "\n".join(wire_commands).encode("utf-8")).hexdigest(),
            "targetPID": target_pid,
            "transcriptSHA256": digest,
        }
        disposition = request.expectedDisposition
        if disposition == "stopped":
            disposition = "running"
        result = CLIOperationObservation(
            CANDIDATE, request.semanticOperation, request.requestID, "observed",
            target_pid, disposition, wire_commands, fact, preview, digest,
            truncated, {},
        )
        if request.expectedDisposition in {"terminated", "exited"}:
            self._terminal_evidence = result
        return result

    def _configured_launch(self, request_id: str,
                           arguments: Mapping[str, object]) -> CLIOperationObservation:
        try:
            executable = _safe_text(_required(arguments, "executable"), "executable")
            launch_arguments = _string_sequence(arguments.get("arguments", ()), "arguments")
            cwd = _safe_text(_required(arguments, "workingDirectory"), "workingDirectory")
            environment = _string_environment(arguments.get("environment", {}))
            authorization = self.lifecycle.authorize_launch(
                executable, launch_arguments, cwd, environment)
            if authorization.get("authorized") is not True:
                raise ValueError(str(authorization.get("reason")
                                     or "launch authorization denied"))
            frozen = authorization.get("launch")
            if not isinstance(frozen, Mapping):
                raise ValueError("launch authorization lacks frozen configuration")
            commands, _, _ = _wire_commands("configuredLaunch", frozen)
        except (AttributeError, TypeError, ValueError) as error:
            return self._negative(
                "configuredLaunch", request_id, "notAttempted", None, (),
                "invalid or unauthorized CLI launch: " + str(error))

        first = self._execute_request(CLICommandRequest(
            "configuredLaunch", request_id + ":entry", commands,
            requireStopped=True))
        if first.observation != "observed" or first.targetPID is None:
            abort = self._abort_unpublished_launch(request_id, first.targetPID)
            classification = (first.observation if abort.observation == "observed"
                              else "harnessError")
            return self._negative("configuredLaunch", request_id, classification,
                                  first.targetPID, first.wireCommands,
                                  "stopped-entry launch was not observed; abort="
                                  + abort.observation,
                                  first.diagnosticPreview)
        pid = first.targetPID
        try:
            self.lifecycle.begin_launch_readiness(pid, authorization, self.timeout)
        except BaseException as error:
            abort = self._abort_unpublished_launch(request_id, pid)
            classification = ("identityMismatch" if abort.observation == "observed"
                              else "harnessError")
            return self._negative(
                "configuredLaunch", request_id, classification, pid,
                first.wireCommands + abort.wireCommands,
                "launch readiness authority could not start: " + str(error)
                + "; abort=" + abort.observation)
        resume_attempt = self._execute_request(CLICommandRequest(
            "continue", request_id + ":readiness-run",
            ("script import threading; _ms_process = "
             "lldb.debugger.GetSelectedTarget().GetProcess(); "
             "print('Process %d resume requested' % _ms_process.GetProcessID()); "
             "_ms_resume = threading.Thread(target=lambda: _ms_process.Continue()); "
             "_ms_resume.start()",),
            expectedPID=pid, requireStopped=False,
            expectedDisposition="targetDispositionUnknown"))
        if resume_attempt.observation != "observed":
            abort = self._abort_unpublished_launch(request_id, pid)
            classification = (resume_attempt.observation
                              if abort.observation == "observed"
                              else "harnessError")
            return self._negative("configuredLaunch", request_id, classification,
                                  pid, first.wireCommands + resume_attempt.wireCommands,
                                  "asynchronous readiness run was not observed; abort="
                                  + abort.observation,
                                  resume_attempt.diagnosticPreview)
        try:
            self.lifecycle.accept_launch(pid, authorization, self.timeout)
        except BaseException as error:
            abort = self._abort_unpublished_launch(request_id, pid)
            classification = ("identityMismatch" if abort.observation == "observed"
                              else "harnessError")
            return self._negative(
                "configuredLaunch", request_id, classification, pid,
                first.wireCommands + resume_attempt.wireCommands + abort.wireCommands,
                "launch readiness authority rejected the process: " + str(error)
                + "; abort=" + abort.observation)
        try:
            stop_postcondition = self.lifecycle.accept_launch_stop(
                pid, authorization, self.timeout)
        except BaseException as error:
            return self._negative(
                "configuredLaunch", request_id, "identityMismatch", pid,
                first.wireCommands + resume_attempt.wireCommands,
                "run-owned stopped postcondition rejected the process: "
                + str(error))
        stopped = self._execute_request(CLICommandRequest(
            "pause", request_id + ":readiness-stop",
            ("process status",), expectedPID=pid, requireStopped=True))
        wire_commands = (first.wireCommands + resume_attempt.wireCommands
                         + stopped.wireCommands)
        if stopped.observation != "observed":
            return self._negative("configuredLaunch", request_id, stopped.observation,
                                  pid, wire_commands,
                                  "post-readiness stopped state was not observed; "
                                  "cleanupDelegatedToOuterSupervisor=true",
                                  stopped.diagnosticPreview)
        combined = "\n".join((first.transcriptSHA256,
                               resume_attempt.transcriptSHA256,
                               stopped.transcriptSHA256))
        digest = hashlib.sha256(combined.encode("ascii")).hexdigest()
        fact = {
            "source": "lldb-cli-transcript",
            "sessionToken": self.session_token,
            "commandSequence": self._sequence,
            "requestID": request_id,
            "semanticOperation": "configuredLaunch",
            "targetPID": pid,
            "wireCommandSHA256": hashlib.sha256(
                "\n".join(wire_commands).encode("utf-8")).hexdigest(),
            "transcriptSHA256": digest,
            "phaseFacts": [first.protocolFact, resume_attempt.protocolFact,
                           stopped.protocolFact],
            "stoppedPostcondition": dict(stop_postcondition),
        }
        preview, _, truncated = _bounded("\n".join((
            first.diagnosticPreview, resume_attempt.diagnosticPreview,
            stopped.diagnosticPreview)))
        return CLIOperationObservation(
            CANDIDATE, "configuredLaunch", request_id, "observed", pid,
            "stopped", wire_commands, fact, preview, digest, truncated, {})

    def _abort_unpublished_launch(
            self, request_id: str,
            pid: Optional[int]) -> CLIOperationObservation:
        """Terminate only the inferior created by this registered LLDB session."""
        commands = ("script lldb.debugger.SetAsync(False)", "process kill")
        return self._execute_request(CLICommandRequest(
            "terminate", request_id + ":unpublished-abort",
            commands,
            expectedPID=pid, requireStopped=False,
            expectedDisposition="terminated"))

    def _retained_expected_exit(self, request_id: str) -> CLIOperationObservation:
        terminal = self._terminal_evidence
        if terminal is None:
            return self._negative(
                "expectedExit", request_id, "notAttempted", None, (),
                "expected exit lacks retained observed terminal evidence",
            )
        self._sequence += 1
        fact = {
            "source": "lldb-cli-transcript",
            "evidenceMode": "retained-terminal",
            "sessionToken": self.session_token,
            "commandSequence": self._sequence,
            "requestID": request_id,
            "semanticOperation": "expectedExit",
            "originatingRequestID": terminal.requestID,
            "originatingOperation": terminal.semanticOperation,
            "originatingCommandSequence": terminal.protocolFact["commandSequence"],
            "targetPID": terminal.targetPID,
            "transcriptSHA256": terminal.transcriptSHA256,
        }
        return CLIOperationObservation(
            CANDIDATE, "expectedExit", request_id, "observed",
            terminal.targetPID, "exited", (), fact, terminal.diagnosticPreview,
            terminal.transcriptSHA256, terminal.diagnosticTruncated, {},
        )

    def attach_and_detach(self, *, pid: int, attach_request_id: str,
                          detach_request_id: str,
                          on_attached: Optional[Callable[[CLIOperationObservation], object]] = None,
                          post_detach_probe: Callable[[int], Mapping[str, object]]) \
            -> tuple[CLIOperationObservation, CLIOperationObservation]:
        attached = self.execute(CLICommandRequest(
            "attach", attach_request_id,
            ("process attach --pid %d" % pid,), expectedPID=pid,
        ))
        if attached.observation != "observed":
            return attached, self._negative(
                "detach", detach_request_id, "notAttempted", pid, (),
                "attach was not observed; detach was not issued",
            )
        if on_attached is not None:
            on_attached(attached)
        detached = self.execute(CLICommandRequest(
            "detach", detach_request_id, ("process detach",), expectedPID=pid,
            requireStopped=False, expectedDisposition="detached",
        ))
        if detached.observation != "observed":
            return attached, detached
        proof = dict(post_detach_probe(pid))
        if (proof.get("sameIdentity") is not True or proof.get("alive") is not True
                or proof.get("controllable") is not True
                or not isinstance(proof.get("checkpointSequence"), int)
                or proof.get("checkpointSequence", 0) <= 0):
            return attached, self._negative(
                "detach", detach_request_id, "identityMismatch", pid,
                detached.wireCommands,
                "post-detach exact-identity control proof is incomplete",
                detached.diagnosticPreview,
            )
        protocol_fact = dict(detached.protocolFact)
        protocol_fact["postDetachControl"] = proof
        detached = CLIOperationObservation(
            detached.candidate, detached.semanticOperation, detached.requestID,
            detached.observation, detached.targetPID, detached.targetDisposition,
            detached.wireCommands, protocol_fact, detached.diagnosticPreview,
            detached.transcriptSHA256, detached.diagnosticTruncated, {},
        )
        return attached, detached

    @staticmethod
    def _negative(operation: str, request_id: str, classification: str,
                  pid: Optional[int], wire_commands: tuple[str, ...], reason: str,
                  diagnostic: str = "") -> CLIOperationObservation:
        preview, digest, truncated = _bounded(diagnostic or reason)
        return CLIOperationObservation(
            CANDIDATE, operation, request_id, classification, pid,
            "targetDispositionUnknown", wire_commands, {}, preview, digest,
            truncated, {"classification": classification, "stage": operation,
                        "reason": reason, "diagnosticSHA256": digest},
        )


def _correlated_transcript(raw: str, begin: str, end: str, max_bytes: int) -> str:
    if len(raw.encode("utf-8", errors="replace")) > max_bytes:
        raise ValueError("CLI transcript exceeds bound")
    lines = raw.splitlines()
    begins = [index for index, line in enumerate(lines) if line == begin]
    ends = [index for index, line in enumerate(lines) if line == end]
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        raise ValueError("CLI transcript markers are missing, duplicated, or reordered")
    return "\n".join(lines[begins[0] + 1:ends[0]])


def _exact_process_pid(transcript: str) -> Optional[int]:
    values = {int(value) for value in _PROCESS_PID.findall(transcript)}
    return next(iter(values)) if len(values) == 1 else None


def _bounded(value: str) -> tuple[str, str, bool]:
    encoded = value.encode("utf-8", errors="replace")
    digest = hashlib.sha256(encoded).hexdigest()
    return (encoded[:MAX_DIAGNOSTIC_BYTES].decode("utf-8", errors="replace"),
            digest, len(encoded) > MAX_DIAGNOSTIC_BYTES)


def _safe_text(value: object, name: str, *, allow_empty: bool = False) -> str:
    if (not isinstance(value, str) or not allow_empty and not value or any(
            character in value for character in ("\0", "\n", "\r"))):
        raise ValueError(name + " must be nonempty control-free text")
    return value


def _string_sequence(value: object, name: str) -> tuple[str, ...]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise ValueError(name + " must be a sequence")
    return tuple(_safe_text(item, name + " item") for item in value)


def _string_environment(value: object) -> Mapping[str, str]:
    if not isinstance(value, Mapping):
        raise ValueError("environment must be a mapping")
    result = {}
    for key, item in value.items():
        key = _safe_text(key, "environment key")
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key) is None:
            raise ValueError("environment key is invalid")
        result[key] = _safe_text(item, "environment value", allow_empty=True)
    return result


def _quote(value: object) -> str:
    text = _safe_text(value, "command value", allow_empty=True)
    return ('"' + text.replace("\\", "\\\\").replace('"', '\\"')
            .replace("`", "\\`") + '"')


def _required(arguments: Mapping[str, object], name: str) -> object:
    value = arguments.get(name)
    if value is None or value == "":
        raise ValueError("%s is required" % name)
    return value


def _wire_commands(operation: str, arguments: Mapping[str, object]) \
        -> tuple[tuple[str, ...], bool, str]:
    """Translate a semantic matrix row to explicit LLDB interpreter commands."""
    if operation == "configuredLaunch":
        executable = _quote(_safe_text(
            _required(arguments, "executable"), "executable"))
        launch_arguments = _string_sequence(arguments.get("arguments", ()), "arguments")
        environment = _string_environment(arguments.get("environment", {}))
        environment_values = " ".join(
            "%s=%s" % (key, _quote(value))
            for key, value in sorted(environment.items()))
        cwd = _quote(_safe_text(
            _required(arguments, "workingDirectory"), "workingDirectory"))
        commands = (
            "target create " + executable,
            "settings clear target.run-args",
            *(("settings set -- target.run-args "
               + " ".join(_quote(value) for value in launch_arguments),)
              if launch_arguments else ()),
            "settings clear target.env-vars",
            *(("settings set target.env-vars " + environment_values,)
              if environment_values else ()),
            "platform settings -w " + cwd,
            "process launch -s",
        )
        return (commands, True, "stopped")
    if operation == "launchArguments":
        values = arguments.get("arguments", ())
        return (("settings set -- target.run-args " + " ".join(_quote(v) for v in values),
                 "settings show target.run-args"), True, "stopped")
    if operation == "launchEnvironment":
        environment = arguments.get("environment", {})
        if not isinstance(environment, Mapping):
            raise ValueError("environment must be a mapping")
        commands = tuple("settings set target.env-vars %s=%s" % (key, _quote(value))
                         for key, value in sorted(environment.items()))
        return (commands + ("settings show target.env-vars",), True, "stopped")
    if operation == "launchWorkingDirectory":
        cwd = _quote(_required(arguments, "workingDirectory"))
        return (("platform settings -w " + cwd, "platform settings -w"), True, "stopped")
    if operation == "initialBreakpoint":
        return (("breakpoint set --address %s" % _required(arguments, "address"),), True, "stopped")
    if operation == "attach":
        return (("process attach --pid %d" % int(_required(arguments, "pid")),), True, "stopped")
    if operation == "detach":
        return (("process detach",), False, "detached")
    if operation == "terminate":
        return (("process kill",), False, "terminated")
    if operation == "pause":
        return (("process interrupt",), True, "stopped")
    if operation == "continue":
        return (("process continue",), True, "stopped")
    if operation == "refresh":
        return (("process status",), True, "stopped")
    if operation == "runToCursor":
        return (("thread until %s" % _required(arguments, "address"),), True, "stopped")
    if operation == "breakpointCreation":
        return (("breakpoint set --address %s" % _required(arguments, "address"),), True, "stopped")
    if operation == "breakpointHit":
        return (("process status",), True, "stopped")
    if operation == "breakpointDelete":
        return (("breakpoint delete %s" % _required(arguments, "breakpointID"),), True, "stopped")
    if operation in {"breakpointEnable", "breakpointDisable"}:
        verb = "enable" if operation.endswith("Enable") else "disable"
        return (("breakpoint %s %s" % (verb, _required(arguments, "breakpointID")),), True, "stopped")
    if operation == "breakpointCondition":
        return (("breakpoint modify -c %s %s" % (
            _quote(_required(arguments, "condition")),
            _required(arguments, "breakpointID")),), True, "stopped")
    if operation == "breakpointIgnoreCount":
        return (("breakpoint modify -i %d %s" % (
            int(_required(arguments, "count")),
            _required(arguments, "breakpointID")),), True, "stopped")
    if operation == "breakpointHitCount":
        return (("breakpoint list %s" % _required(arguments, "breakpointID"),), True, "stopped")
    if operation in {"stepInto", "stepOver", "stepOut"}:
        command = {"stepInto": "thread step-in", "stepOver": "thread step-over",
                   "stepOut": "thread step-out"}[operation]
        return ((command,), True, "stopped")
    if operation == "threadList":
        return (("thread list",), True, "stopped")
    if operation == "threadSelection":
        return (("thread select %s" % _required(arguments, "threadID"),), True, "stopped")
    if operation == "frameList":
        return (("thread backtrace",), True, "stopped")
    if operation == "frameSelection":
        return (("frame select %s" % _required(arguments, "frameID"),), True, "stopped")
    if operation == "registerRead":
        name = arguments.get("register")
        return ((("register read " + str(name)) if name else "register read",), True, "stopped")
    if operation == "registerWrite":
        return (("register write %s %s" % (
            _required(arguments, "register"), _required(arguments, "value")),), True, "stopped")
    if operation == "memoryRead":
        return (("memory read --count %d %s" % (
            int(arguments.get("count", 16)), _required(arguments, "address")),), True, "stopped")
    if operation == "memoryWrite":
        return (("memory write %s %s" % (
            _required(arguments, "address"), _required(arguments, "value")),), True, "stopped")
    if operation == "expressionEvaluation":
        return (("expression -- %s" % _required(arguments, "expression"),), True, "stopped")
    if operation in {"moduleList", "moduleLoad", "moduleUnload"}:
        # The fixture control action happens outside LLDB; this command observes
        # the resulting same-session module state without starting another LLDB.
        return (("image list -v",), True, "stopped")
    if operation == "expectedExit":
        return (("process continue",), False, "exited")
    raise ValueError("no CLI wire plan for operation: " + operation)
