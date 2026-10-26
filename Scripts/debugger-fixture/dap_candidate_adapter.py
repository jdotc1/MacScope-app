#!/usr/bin/env python3
"""Evidence-preserving WS-18 semantic adapter for Xcode's ``lldb-dap``.

The committed :mod:`candidate_drivers` DAP implementation owns framing,
request/event correlation, lifecycle fencing, and the adapter process.  This
module owns only the frozen WS-18 semantic-to-wire mapping.  It deliberately
cannot create OS identities, protocol revisions, cleanup receipts, or validator
decisions: those values arrive through injected authority boundaries.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Mapping, Optional, Sequence


HERE = Path(__file__).resolve().parent


def _load(name: str):
    if name in sys.modules:
        return sys.modules[name]
    specification = importlib.util.spec_from_file_location(name, HERE / (name + ".py"))
    if specification is None or specification.loader is None:
        raise RuntimeError("unable to load " + name)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


drivers = _load("candidate_drivers")
schema = _load("ws18_schema")
runtime = _load("ws18_runtime_bridge")


class DAPCandidateError(RuntimeError):
    pass


@dataclass(frozen=True)
class DAPWireRequest:
    command: str
    arguments: Mapping[str, object]


@dataclass(frozen=True)
class DAPProtocolFact:
    """One immutable semantic fact projected from correlated DAP evidence."""

    source: str
    semanticOperation: str
    wireCommands: tuple[Mapping[str, object], ...]
    semanticFactID: str
    requestEventBoundary: int
    acceptedEventSequences: tuple[int, ...]
    requestID: str
    sessionEpoch: int
    lifecycleRevision: int
    stopRevision: int
    targetPID: Optional[int]
    targetDisposition: str
    processAttempted: bool
    postcondition: Mapping[str, object]


_FORBIDDEN_PROJECTOR_KEYS = frozenset({
    "pass", "passed", "viable", "viability", "selected", "selectionEligible",
    "selectionEligibility", "validatorDecision", "accepted", "gateResult",
})

_NO_DIRECT_DAP_PROBE = frozenset({
    "breakpointHit", "cancelBeforeSpawn", "cancelInFlight", "timeoutRecovery",
    "adapterCrashRecovery", "moduleLoad", "moduleUnload", "runToCursor",
})

_REQUIRED_ARGUMENTS = {
    "initialBreakpoint": frozenset(("address",)),
    "breakpointCreation": frozenset(("address",)),
    "breakpointDelete": frozenset(("breakpoints",)),
    "breakpointEnable": frozenset(("breakpoints",)),
    "breakpointDisable": frozenset(("breakpoints",)),
    "breakpointCondition": frozenset(("breakpoints",)),
    "breakpointIgnoreCount": frozenset(("breakpoints",)),
    "breakpointHitCount": frozenset(("breakpoints",)),
    "threadSelection": frozenset(("threadID",)),
    "frameList": frozenset(("threadID",)),
    "frameSelection": frozenset(("frameID",)),
    "registerRead": frozenset(("variablesReference",)),
    "registerWrite": frozenset(("variablesReference", "name", "value")),
    "memoryRead": frozenset(("memoryReference",)),
    "memoryWrite": frozenset(("memoryReference", "data")),
    "expressionEvaluation": frozenset(("expression",)),
}


def _valid_pid(value: object) -> Optional[int]:
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def _event_after(acknowledgement, name: str) -> Optional[drivers.DAPAcceptedEvent]:
    return next((event for event in acknowledgement.acceptedEvents
                 if event.eventSequence > acknowledgement.requestEventBoundary
                 and event.eventName == name), None)


def _contains_forbidden_decision(value: object) -> bool:
    if isinstance(value, Mapping):
        return any(key in _FORBIDDEN_PROJECTOR_KEYS
                   or _contains_forbidden_decision(item) for key, item in value.items())
    if isinstance(value, (list, tuple)):
        return any(_contains_forbidden_decision(item) for item in value)
    return False


def _operation_arguments(context: Mapping[str, object], operation: str) -> Mapping[str, object]:
    configured = context.get("operationArguments", {})
    if not isinstance(configured, Mapping):
        raise ValueError("operationArguments must be a mapping")
    arguments = configured.get(operation, {})
    if not isinstance(arguments, Mapping):
        raise ValueError(operation + " arguments must be a mapping")
    missing = sorted(_REQUIRED_ARGUMENTS.get(operation, frozenset()) - set(arguments))
    if missing:
        raise ValueError("missing operation arguments: " + ", ".join(missing))
    return dict(arguments)


def _wire_request(operation: str, arguments: Mapping[str, object],
                  target_pid: Optional[int]) -> DAPWireRequest:
    """Map a WS-18 semantic operation to one concrete DAP request."""
    thread_id = arguments.get("threadID")
    if operation in {"initialBreakpoint", "breakpointCreation"}:
        address = arguments["address"]
        return DAPWireRequest("setInstructionBreakpoints", {
            "breakpoints": [{"instructionReference": str(address)}],
        })
    if operation in {"breakpointDelete", "breakpointEnable", "breakpointDisable",
                     "breakpointCondition", "breakpointIgnoreCount", "breakpointHitCount"}:
        return DAPWireRequest("setInstructionBreakpoints", {
            "breakpoints": list(arguments["breakpoints"]),
        })
    if operation == "terminate":
        return DAPWireRequest("disconnect", {"terminateDebuggee": True})
    if operation == "pause":
        return DAPWireRequest("pause", {"threadId": thread_id} if thread_id else {})
    if operation == "continue":
        return DAPWireRequest("continue", {"threadId": thread_id} if thread_id else {})
    if operation == "refresh" or operation == "threadList":
        return DAPWireRequest("threads", {})
    if operation in {"stepInto", "stepOver", "stepOut"}:
        command = {"stepInto": "stepIn", "stepOver": "next", "stepOut": "stepOut"}[operation]
        return DAPWireRequest(command, {"threadId": thread_id} if thread_id else {})
    if operation == "threadSelection" or operation == "frameList":
        return DAPWireRequest("stackTrace", {"threadId": arguments["threadID"]})
    if operation == "frameSelection":
        return DAPWireRequest("scopes", {"frameId": arguments["frameID"]})
    if operation == "registerRead":
        return DAPWireRequest("variables", {
            "variablesReference": arguments["variablesReference"],
        })
    if operation == "registerWrite":
        return DAPWireRequest("setVariable", {
            "variablesReference": arguments["variablesReference"],
            "name": arguments["name"], "value": arguments["value"],
        })
    if operation == "memoryRead":
        payload = {"memoryReference": arguments["memoryReference"],
                   "count": int(arguments.get("count", 16))}
        if "offset" in arguments:
            payload["offset"] = int(arguments["offset"])
        return DAPWireRequest("readMemory", payload)
    if operation == "memoryWrite":
        payload = {"memoryReference": arguments["memoryReference"],
                   "data": arguments["data"]}
        if "offset" in arguments:
            payload["offset"] = int(arguments["offset"])
        return DAPWireRequest("writeMemory", payload)
    if operation == "expressionEvaluation":
        payload = {"expression": arguments["expression"], "context": "repl"}
        if "frameID" in arguments:
            payload["frameId"] = arguments["frameID"]
        return DAPWireRequest("evaluate", payload)
    if operation == "moduleList":
        return DAPWireRequest("modules", {"startModule": 0, "moduleCount": 1024})
    if operation == "expectedExit":
        return DAPWireRequest("continue", {"threadId": thread_id} if thread_id else {})
    raise ValueError("operation has no direct DAP wire request")


def _response_postcondition(operation: str, acknowledgement) -> Optional[Mapping[str, object]]:
    """Return only postconditions present in the acknowledged response/events."""
    body = acknowledgement.response.get("body", {})
    body = body if isinstance(body, Mapping) else {}
    collection = {
        "refresh": "threads", "threadList": "threads",
        "threadSelection": "stackFrames", "frameList": "stackFrames",
        "frameSelection": "scopes", "registerRead": "variables",
        "moduleList": "modules",
    }.get(operation)
    if collection is not None:
        value = body.get(collection)
        if not isinstance(value, list):
            return None
        return {"responseField": collection, "itemCount": len(value)}
    if operation in {"initialBreakpoint", "breakpointCreation", "breakpointDelete",
                     "breakpointEnable", "breakpointDisable", "breakpointCondition",
                     "breakpointIgnoreCount", "breakpointHitCount"}:
        value = body.get("breakpoints")
        if not isinstance(value, list):
            return None
        return {"responseField": "breakpoints", "itemCount": len(value)}
    if operation == "registerWrite":
        return ({"responseField": "value", "valuePresent": True}
                if isinstance(body.get("value"), str) else None)
    if operation == "memoryRead":
        return ({"responseField": "data", "dataPresent": True}
                if isinstance(body.get("data"), str) else None)
    if operation == "memoryWrite":
        count = body.get("bytesWritten")
        return ({"responseField": "bytesWritten", "bytesWritten": count}
                if isinstance(count, int) and not isinstance(count, bool) and count >= 0 else None)
    if operation == "expressionEvaluation":
        return ({"responseField": "result", "resultPresent": True}
                if isinstance(body.get("result"), str) else None)
    if operation in {"pause", "stepInto", "stepOver", "stepOut"}:
        stopped = _event_after(acknowledgement, "stopped")
        return (None if stopped is None else {
            "event": "stopped", "eventSequence": stopped.eventSequence,
            "stopRevision": stopped.stopRevision,
        })
    if operation == "continue":
        continued = _event_after(acknowledgement, "continued")
        return (None if continued is None else {
            "event": "continued", "eventSequence": continued.eventSequence,
        })
    if operation in {"terminate", "expectedExit"}:
        terminal = _event_after(acknowledgement, "exited") or _event_after(
            acknowledgement, "terminated")
        return (None if terminal is None else {
            "event": terminal.eventName, "eventSequence": terminal.eventSequence,
        })
    return None


class DAPCandidateAdapter:
    """One fresh DAP run with evidence-authority boundaries injected."""

    candidate = "xcode-lldb-dap"

    def __init__(self, driver, *, runtime_process_binder: Callable,
                 report_projector_binder: Callable, timeout: float = 30.0) -> None:
        if (getattr(driver, "candidate", None) != self.candidate
                or not callable(getattr(driver, "request", None))
                or not callable(getattr(driver, "close", None))):
            raise ValueError("DAP adapter requires one composed LldbDAPDriver")
        if not callable(runtime_process_binder) or not callable(report_projector_binder):
            raise ValueError("runtime and report evidence binders are required")
        if timeout <= 0:
            raise ValueError("timeout must be positive")
        self.driver = driver
        self.runtime_process_binder = runtime_process_binder
        self.report_projector_binder = report_projector_binder
        self.timeout = timeout
        self.mode: Optional[str] = None
        self.target_pid: Optional[int] = None
        self.process_attempted = False
        self._start_acknowledgement = None
        self._start_arguments: Mapping[str, object] = {}
        self._terminal_acknowledgement = None
        self._terminal_wire: Optional[DAPWireRequest] = None
        self._closed = False
        self._close_receipt = None

    def launch(self, request_id: str, executable: Path, arguments: Sequence[str],
               cwd: Path, environment: Mapping[str, str]):
        body = {"program": str(executable.resolve()), "args": list(arguments),
                "cwd": str(cwd.resolve()), "env": dict(environment), "stopOnEntry": True}
        return self._start(request_id, "launch", "configuredLaunch", body, None)

    def attach(self, request_id: str, target):
        if not isinstance(target, drivers.ExactAttachTarget):
            raise TypeError("DAP attach requires an ExactAttachTarget")
        return self._start(request_id, "attach", "attach",
                           {"pid": target.pid, "stopOnEntry": True}, target.pid)

    def _start(self, request_id: str, wire_operation: str, semantic_operation: str,
               arguments: Mapping[str, object], expected_pid: Optional[int]):
        if self._closed or self.mode is not None:
            return self._negative(request_id, semantic_operation, "harnessError",
                                  "DAP run already owns a session or is closed")
        try:
            acknowledgement = self._request(wire_operation, arguments)
        except TimeoutError as error:
            return self._negative(request_id, semantic_operation, "timedOut", str(error),
                                  process_attempted=True)
        except Exception as error:
            return self._negative(request_id, semantic_operation, "harnessError", str(error),
                                  process_attempted=True)
        self.process_attempted = True
        fact_pid = None
        facts = acknowledgement.protocolFacts
        if isinstance(facts, drivers.dap.DAPLifecycleFacts) and facts.process is not None:
            fact_pid = _valid_pid(facts.process.systemProcessId)
        if acknowledgement.response.get("success") is not True:
            if wire_operation == "launch":
                return self._abort_unpublished_launch(
                    request_id, fact_pid, acknowledgement, "protocolError",
                    "DAP start response was unsuccessful")
            return self._negative(request_id, semantic_operation, "protocolError",
                                  "DAP start response was unsuccessful",
                                  acknowledgement=acknowledgement, process_attempted=True)
        if expected_pid is not None and fact_pid != expected_pid:
            return self._negative(request_id, semantic_operation, "identityMismatch",
                                  "DAP lifecycle facts did not prove the authorized PID",
                                  acknowledgement=acknowledgement, process_attempted=True)
        if fact_pid is None:
            if wire_operation == "launch":
                return self._abort_unpublished_launch(
                    request_id, None, acknowledgement, "identityMismatch",
                    "DAP lifecycle facts did not prove a target PID")
            return self._negative(request_id, semantic_operation, "identityMismatch",
                                  "DAP lifecycle facts did not prove a target PID",
                                  acknowledgement=acknowledgement, process_attempted=True)
        if facts.operation != wire_operation or facts.stopped is None:
            if wire_operation == "launch":
                return self._abort_unpublished_launch(
                    request_id, fact_pid, acknowledgement, "protocolError",
                    "DAP lifecycle facts did not prove the configured entry stop")
            return self._negative(request_id, semantic_operation, "protocolError",
                                  "DAP lifecycle facts did not prove the configured entry stop",
                                  fact_pid, acknowledgement, True)
        if wire_operation == "launch":
            evidence = self._complete_configured_launch(
                request_id, arguments, acknowledgement, facts, fact_pid)
            if evidence.observation == "observed":
                self.mode = wire_operation
                self.target_pid = fact_pid
                self._start_acknowledgement = acknowledgement
                self._start_arguments = dict(arguments)
            return evidence
        postcondition = {
            "processEventSequence": facts.process.eventSequence,
            "stoppedEventSequence": facts.stopped.eventSequence,
            "startMethod": facts.process.startMethod,
        }
        evidence = self._bind(request_id, semantic_operation, wire_operation, arguments,
                              acknowledgement, fact_pid, "stopped", postcondition, True)
        if evidence.observation == "observed":
            self.mode = wire_operation
            self.target_pid = fact_pid
            self._start_acknowledgement = acknowledgement
            self._start_arguments = dict(arguments)
        return evidence

    def _complete_configured_launch(self, request_id: str,
                                    arguments: Mapping[str, object],
                                    start_acknowledgement,
                                    start_facts,
                                    target_pid: int):
        """Run the launch target for OS proof, then restore its entry stop.

        ``stopOnEntry`` is required so the DAP lifecycle first proves the exact
        adapter-reported PID.  The fixture cannot emit its nonce-correlated
        ready event while stopped, so configured-launch evidence is published
        only after a correlated continue, runtime binding while running, and a
        correlated pause that restores the same session/PID to a new stop.
        """
        thread_id = start_facts.stopped.threadId
        continue_arguments = ({"threadId": thread_id} if thread_id is not None else {})
        try:
            continued_acknowledgement = self._request("continue", continue_arguments)
        except TimeoutError as error:
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement,
                "timedOut", str(error), failure_wire=DAPWireRequest(
                    "continue", continue_arguments))
        except Exception as error:
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement,
                "harnessError", str(error), failure_wire=DAPWireRequest(
                    "continue", continue_arguments))
        try:
            continued, continue_fence = self._event_after_with_fence(
                continued_acknowledgement, "continued")
        except TimeoutError as error:
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement,
                "timedOut", str(error), continued_acknowledgement,
                DAPWireRequest("continue", continue_arguments))
        except Exception as error:
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement,
                "harnessError", str(error), continued_acknowledgement,
                DAPWireRequest("continue", continue_arguments))
        if (continued_acknowledgement.response.get("success") is not True
                or continued_acknowledgement.sessionEpoch
                != start_acknowledgement.sessionEpoch
                or (continue_fence is not None
                    and continue_fence.sessionEpoch != start_acknowledgement.sessionEpoch)
                or continued is None
                or continued.sessionEpoch != start_acknowledgement.sessionEpoch
                or continued.lifecycleRevision
                <= start_facts.stopped.lifecycleRevision):
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement, "protocolError",
                "DAP continue did not prove the configured target entered the running state",
                continued_acknowledgement,
                DAPWireRequest("continue", continue_arguments),
            )

        runtime_fact = None
        runtime_problem: Optional[tuple[str, str]] = None
        try:
            candidate_runtime_fact = self.runtime_process_binder(
                "configuredLaunch", continued_acknowledgement, target_pid)
            if (not isinstance(candidate_runtime_fact, runtime.RuntimeProcessFact)
                    or candidate_runtime_fact.operation != "configuredLaunch"
                    or candidate_runtime_fact.targetPID != target_pid
                    or candidate_runtime_fact.identityMatched is not True
                    or not candidate_runtime_fact.condition
                    or not isinstance(candidate_runtime_fact.evidence, Mapping)
                    or not candidate_runtime_fact.evidence):
                runtime_problem = (
                    "identityMismatch",
                    "runtime binder did not prove the exact operation target",
                )
            else:
                runtime_fact = candidate_runtime_fact
        except Exception as error:
            runtime_problem = (
                "harnessError", "runtime process binding failed: " + str(error),
            )
        if runtime_problem is not None:
            classification, reason = runtime_problem
            return self._abort_unpublished_launch(
                request_id, target_pid, start_acknowledgement, classification, reason,
                continued_acknowledgement,
                DAPWireRequest("continue", continue_arguments),
            )

        pause_arguments = ({"threadId": thread_id} if thread_id is not None else {})
        try:
            paused_acknowledgement = self._request("pause", pause_arguments)
        except TimeoutError as error:
            return self._negative(request_id, "configuredLaunch", "timedOut", str(error),
                                  target_pid, continued_acknowledgement, True,
                                  DAPWireRequest("pause", pause_arguments),
                                  extra_proof={"cleanupDelegatedToOuterSupervisor": True})
        except Exception as error:
            return self._negative(request_id, "configuredLaunch", "harnessError", str(error),
                                  target_pid, continued_acknowledgement, True,
                                  DAPWireRequest("pause", pause_arguments),
                                  extra_proof={"cleanupDelegatedToOuterSupervisor": True})

        try:
            restored_stop, pause_fence = self._event_after_with_fence(
                paused_acknowledgement, "stopped")
        except TimeoutError as error:
            return self._negative(request_id, "configuredLaunch", "timedOut", str(error),
                                  target_pid, paused_acknowledgement, True,
                                  DAPWireRequest("pause", pause_arguments),
                                  extra_proof={"cleanupDelegatedToOuterSupervisor": True})
        except Exception as error:
            return self._negative(request_id, "configuredLaunch", "harnessError", str(error),
                                  target_pid, paused_acknowledgement, True,
                                  DAPWireRequest("pause", pause_arguments),
                                  extra_proof={"cleanupDelegatedToOuterSupervisor": True})
        replacement_process = next((
            event for acknowledgement in (continued_acknowledgement, continue_fence,
                                           paused_acknowledgement, pause_fence)
            if acknowledgement is not None
            for event in acknowledgement.acceptedEvents
            if event.eventName == "process"
            and event.eventSequence > start_facts.process.eventSequence
        ), None)
        if (paused_acknowledgement.response.get("success") is not True
                or paused_acknowledgement.sessionEpoch != start_acknowledgement.sessionEpoch
                or (pause_fence is not None
                    and pause_fence.sessionEpoch != start_acknowledgement.sessionEpoch)
                or restored_stop is None
                or restored_stop.sessionEpoch != start_acknowledgement.sessionEpoch
                or restored_stop.eventSequence <= continued.eventSequence
                or restored_stop.lifecycleRevision <= continued.lifecycleRevision
                or restored_stop.stopRevision <= start_facts.stopped.stopRevision
                or replacement_process is not None):
            return self._negative(
                request_id, "configuredLaunch", "protocolError",
                "DAP pause did not restore the same configured target to a new stop",
                target_pid, paused_acknowledgement, True,
                DAPWireRequest("pause", pause_arguments),
                extra_proof={"cleanupDelegatedToOuterSupervisor": True},
            )
        assert runtime_fact is not None

        wire_command_list = [
            {"command": "launch", "arguments": dict(arguments),
             "requestSequence": start_acknowledgement.requestSequence},
            {"command": "continue", "arguments": dict(continue_arguments),
             "requestSequence": continued_acknowledgement.requestSequence},
        ]
        if continue_fence is not None:
            wire_command_list.append({
                "command": "threads", "arguments": {},
                "requestSequence": continue_fence.requestSequence,
            })
        wire_command_list.append({
            "command": "pause", "arguments": dict(pause_arguments),
            "requestSequence": paused_acknowledgement.requestSequence,
        })
        if pause_fence is not None:
            wire_command_list.append({
                "command": "threads", "arguments": {},
                "requestSequence": pause_fence.requestSequence,
            })
        wire_commands = tuple(wire_command_list)
        accepted_event_sequences = tuple(dict.fromkeys((
            start_facts.process.eventSequence,
            start_facts.stopped.eventSequence,
            continued.eventSequence,
            restored_stop.eventSequence,
        )))
        final_acknowledgement = pause_fence or paused_acknowledgement
        return self._bind(
            request_id, "configuredLaunch", "launch", arguments,
            final_acknowledgement, target_pid, "stopped", {
                "processEventSequence": start_facts.process.eventSequence,
                "stoppedEventSequence": restored_stop.eventSequence,
                "entryStoppedPID": target_pid,
                "entryStoppedEventSequence": start_facts.stopped.eventSequence,
                "continuedEventSequence": continued.eventSequence,
                "runtimeBoundWhileRunning": True,
                "restoredStoppedPID": target_pid,
                "restoredStoppedEventSequence": restored_stop.eventSequence,
                "startMethod": start_facts.process.startMethod,
            }, True,
            runtime_fact=runtime_fact,
            wire_commands=wire_commands,
            semantic_request_sequence=start_acknowledgement.requestSequence,
            request_event_boundary=start_acknowledgement.requestEventBoundary,
            accepted_event_sequences=accepted_event_sequences,
        )

    def _event_after_with_fence(self, acknowledgement, event_name: str):
        """Capture an event emitted after its response without losing causality.

        DAP permits an adapter to emit a successful response before the state
        event it causes.  The driver acknowledgement is an immutable snapshot,
        so one harmless ``threads`` request is used only as a stream fence when
        the event is not already in that snapshot.  The accepted event must
        still be newer than the original request's event boundary.
        """
        event = _event_after(acknowledgement, event_name)
        if event is not None:
            return event, None
        fence = self._request("threads", {})
        event = next((
            accepted for accepted in fence.acceptedEvents
            if accepted.eventSequence > acknowledgement.requestEventBoundary
            and accepted.eventName == event_name
        ), None)
        return event, fence

    def _abort_unpublished_launch(
            self, request_id: str, target_pid: Optional[int], start_acknowledgement,
            failure_classification: str, failure_reason: str,
            failure_acknowledgement=None,
            failure_wire: Optional[DAPWireRequest] = None):
        """Terminate a DAP-created PID that runtime admission never proved.

        The exact-process supervisor cannot own cleanup until the runtime
        binder returns a valid fact.  Before that point the DAP session is the
        sole authority capable of terminating its unpublished inferior, and a
        successful disconnect response alone is insufficient: the correlated
        terminal lifecycle event is mandatory.
        """
        abort_arguments = {"terminateDebuggee": True}
        abort_proof: dict[str, object] = {
            "proved": False,
            "targetPID": target_pid,
            "command": "disconnect",
            "arguments": dict(abort_arguments),
            "failureClassification": failure_classification,
            "failureReason": failure_reason,
        }
        try:
            abort_acknowledgement = self._request("disconnect", abort_arguments)
        except Exception as error:
            abort_proof["diagnostic"] = "disconnect failed: " + str(error)
            return self._negative(
                request_id, "configuredLaunch", "harnessError",
                "unpublished launch abort could not be proved",
                target_pid, failure_acknowledgement or start_acknowledgement,
                True, failure_wire, extra_proof={"unpublishedLaunchAbort": abort_proof},
            )

        facts = abort_acknowledgement.protocolFacts
        terminal = None
        process_pid = None
        if isinstance(facts, drivers.dap.DAPLifecycleFacts):
            terminal = facts.terminated or facts.exited
            if facts.process is not None:
                process_pid = _valid_pid(facts.process.systemProcessId)
        accepted_terminal = (None if terminal is None else next((
            event for event in abort_acknowledgement.acceptedEvents
            if event.eventSequence == terminal.eventSequence
            and event.eventName == terminal.eventName
            and event.eventSequence > abort_acknowledgement.requestEventBoundary
        ), None))
        abort_valid = (
            abort_acknowledgement.response.get("success") is True
            and abort_acknowledgement.command == "disconnect"
            and abort_acknowledgement.sessionEpoch == start_acknowledgement.sessionEpoch
            and isinstance(facts, drivers.dap.DAPLifecycleFacts)
            and facts.operation == "launch"
            and process_pid is not None
            and (target_pid is None or process_pid == target_pid)
            and terminal is not None
            and terminal.sessionEpoch == start_acknowledgement.sessionEpoch
            and terminal.eventName in {"terminated", "exited"}
            and accepted_terminal is not None
            and accepted_terminal.sessionEpoch == start_acknowledgement.sessionEpoch
            and accepted_terminal.lifecycleRevision == terminal.lifecycleRevision
            and accepted_terminal.stopRevision == terminal.stopRevision
        )
        abort_proof.update({
            "responseSuccess": abort_acknowledgement.response.get("success") is True,
            "requestSequence": abort_acknowledgement.requestSequence,
            "sessionEpoch": abort_acknowledgement.sessionEpoch,
            "event": terminal.eventName if terminal is not None else None,
            "eventSequence": terminal.eventSequence if terminal is not None else None,
            "proved": abort_valid,
        })
        if not abort_valid:
            abort_proof["diagnostic"] = (
                "disconnect lacked a same-session terminal lifecycle proof")
            return self._negative(
                request_id, "configuredLaunch", "harnessError",
                "unpublished launch abort could not be proved",
                target_pid, failure_acknowledgement or start_acknowledgement,
                True, failure_wire, extra_proof={"unpublishedLaunchAbort": abort_proof},
            )
        return self._negative(
            request_id, "configuredLaunch", failure_classification, failure_reason,
            target_pid, failure_acknowledgement or start_acknowledgement,
            True, failure_wire, extra_proof={"unpublishedLaunchAbort": abort_proof},
        )

    def detach(self, request_id: str, control):
        if self.mode != "attach" or self.target_pid is None:
            return self._negative(request_id, "detach", "notAttempted",
                                  "detach requires one observed attach", self.target_pid)
        acknowledgement = self._request("disconnect", {"terminateDebuggee": False})
        facts = acknowledgement.protocolFacts
        terminal = facts.terminated if isinstance(facts, drivers.dap.DAPLifecycleFacts) else None
        if terminal is None:
            return self._negative(request_id, "detach", "protocolError",
                                  "DAP disconnect did not emit a terminated-session event",
                                  self.target_pid, acknowledgement, True)
        try:
            checkpoint = control.send("checkpoint")
        except Exception as error:
            return self._negative(request_id, "detach", "identityMismatch",
                                  "post-detach fixture control failed: " + str(error),
                                  self.target_pid, acknowledgement, True)
        if (not isinstance(checkpoint, Mapping)
                or checkpoint.get("pid") != self.target_pid
                or checkpoint.get("operation") != "checkpoint"):
            return self._negative(request_id, "detach", "identityMismatch",
                                  "post-detach fixture control was not PID-correlated",
                                  self.target_pid, acknowledgement, True)
        result = self._bind(request_id, "detach", "disconnect",
                            {"terminateDebuggee": False}, acknowledgement,
                            self.target_pid, "detached", {
                                "event": "terminated",
                                "eventSequence": terminal.eventSequence,
                                "postDetachControl": dict(checkpoint),
                            }, True)
        if result.observation == "observed":
            self.mode = "detached"
        return result

    def exercise_operation(self, request_id: str, operation: str,
                           context: Mapping[str, object]):
        if operation not in schema.OPERATION_ORDER:
            return self._negative(request_id, operation, "protocolError",
                                  "operation is outside the frozen WS-18 matrix")
        if operation in {"configuredLaunch", "attach", "detach"}:
            return self._negative(request_id, operation, "notAttempted",
                                  "operation is owned by its lifecycle method", self.target_pid)
        if self.mode not in {"launch", "attach"} or self.target_pid is None:
            return self._negative(request_id, operation, "notAttempted",
                                  "operation requires one observed DAP start")
        if operation in {"launchArguments", "launchEnvironment", "launchWorkingDirectory"}:
            return self._project_start_configuration(request_id, operation)
        if operation == "expectedExit" and self._terminal_acknowledgement is not None:
            return self._project_observed_termination(request_id)
        if operation in _NO_DIRECT_DAP_PROBE:
            return self._negative(request_id, operation, "notAttempted",
                                  "no causally sufficient direct DAP probe is implemented",
                                  self.target_pid)
        try:
            arguments = _operation_arguments(context, operation)
            wire = _wire_request(operation, arguments, self.target_pid)
        except (TypeError, ValueError) as error:
            return self._negative(request_id, operation, "notAttempted", str(error), self.target_pid)
        try:
            acknowledgement = self._request(wire.command, wire.arguments)
        except TimeoutError as error:
            return self._negative(request_id, operation, "timedOut", str(error), self.target_pid,
                                  process_attempted=True)
        except Exception as error:
            return self._negative(request_id, operation, "harnessError", str(error), self.target_pid,
                                  process_attempted=True)
        self.process_attempted = True
        if acknowledgement.response.get("success") is not True:
            message = str(acknowledgement.response.get("message", "unsuccessful DAP response"))
            classification = ("unsupported" if "not supported" in message.lower()
                              or "unsupported" in message.lower() else "protocolError")
            return self._negative(request_id, operation, classification, message, self.target_pid,
                                  acknowledgement, True, wire)
        postcondition = _response_postcondition(operation, acknowledgement)
        if postcondition is None:
            return self._negative(request_id, operation, "protocolError",
                                  "DAP acknowledgement lacks the semantic postcondition",
                                  self.target_pid, acknowledgement, True, wire)
        disposition = "exited" if operation == "expectedExit" else (
            "terminated" if operation == "terminate" else
            "running" if operation == "continue" else "stopped")
        result = self._bind(request_id, operation, wire.command, wire.arguments,
                            acknowledgement, self.target_pid, disposition,
                            postcondition, True)
        if operation == "terminate" and result.observation == "observed":
            self._terminal_acknowledgement = acknowledgement
            self._terminal_wire = wire
        return result

    def _project_start_configuration(self, request_id: str, operation: str):
        if self.mode != "launch" or self._start_acknowledgement is None:
            return self._negative(request_id, operation, "notApplicable",
                                  "launch configuration is not applicable to attach",
                                  self.target_pid)
        field = {"launchArguments": "args", "launchEnvironment": "env",
                 "launchWorkingDirectory": "cwd"}[operation]
        if field not in self._start_arguments:
            return self._negative(request_id, operation, "protocolError",
                                  "configured launch request omitted " + field, self.target_pid,
                                  self._start_acknowledgement, True)
        return self._bind(request_id, operation, "launch", self._start_arguments,
                          self._start_acknowledgement, self.target_pid, "stopped",
                          {"configuredField": field, "value": self._start_arguments[field]}, True)

    def _project_observed_termination(self, request_id: str):
        acknowledgement = self._terminal_acknowledgement
        wire = self._terminal_wire
        postcondition = _response_postcondition("expectedExit", acknowledgement)
        if wire is None or postcondition is None:
            return self._negative(
                request_id, "expectedExit", "protocolError",
                "observed terminate evidence lacks a correlated terminal event",
                self.target_pid, acknowledgement, True, wire,
            )
        return self._bind(
            request_id, "expectedExit", wire.command, wire.arguments,
            acknowledgement, self.target_pid, "exited", postcondition, True,
        )

    def _request(self, command: str, arguments: Mapping[str, object]):
        acknowledgement = self.driver.request(
            self.driver.path, command, dict(arguments), self.timeout)
        if not isinstance(acknowledgement, drivers.DAPRequestAcknowledgement):
            raise DAPCandidateError("DAP driver returned an untyped acknowledgement")
        return acknowledgement

    def _bind(self, request_id: str, semantic_operation: str, wire_command: str,
              wire_arguments: Mapping[str, object], acknowledgement, target_pid: int,
              disposition: str, postcondition: Mapping[str, object],
              process_attempted: bool, *, runtime_fact=None,
              wire_commands: Optional[tuple[Mapping[str, object], ...]] = None,
              semantic_request_sequence: Optional[int] = None,
              request_event_boundary: Optional[int] = None,
              accepted_event_sequences: Optional[tuple[int, ...]] = None):
        wire = wire_commands or (
            {"command": wire_command, "arguments": dict(wire_arguments),
             "requestSequence": acknowledgement.requestSequence},
        )
        semantic_component = postcondition.get("configuredField", semantic_operation)
        semantic_fact_id = "%s:%d:%s" % (
            wire_command,
            semantic_request_sequence or acknowledgement.requestSequence,
            semantic_component,
        )
        protocol_fact = DAPProtocolFact(
            "lldb-dap", semantic_operation, wire, semantic_fact_id,
            (acknowledgement.requestEventBoundary if request_event_boundary is None
             else request_event_boundary),
            (tuple(event.eventSequence for event in acknowledgement.acceptedEvents)
             if accepted_event_sequences is None else accepted_event_sequences),
            request_id,
            acknowledgement.sessionEpoch, acknowledgement.lifecycleRevision,
            acknowledgement.stopRevision, target_pid, disposition,
            process_attempted, dict(postcondition),
        )
        if runtime_fact is None:
            try:
                runtime_fact = self.runtime_process_binder(
                    semantic_operation, acknowledgement, target_pid)
            except Exception as error:
                return self._negative(request_id, semantic_operation, "harnessError",
                                      "runtime process binding failed: " + str(error),
                                      target_pid, acknowledgement, process_attempted)
        if (not isinstance(runtime_fact, runtime.RuntimeProcessFact)
                or runtime_fact.operation != semantic_operation
                or runtime_fact.targetPID != target_pid
                or runtime_fact.identityMatched is not True
                or not runtime_fact.condition
                or not isinstance(runtime_fact.evidence, Mapping)
                or not runtime_fact.evidence):
            return self._negative(request_id, semantic_operation, "identityMismatch",
                                  "runtime binder did not prove the exact operation target",
                                  target_pid, acknowledgement, process_attempted)
        try:
            projected = self.report_projector_binder(protocol_fact, runtime_fact)
        except Exception as error:
            return self._negative(request_id, semantic_operation, "harnessError",
                                  "report evidence projection failed: " + str(error),
                                  target_pid, acknowledgement, process_attempted)
        if (not isinstance(projected, Mapping) or not projected
                or _contains_forbidden_decision(projected)):
            return self._negative(request_id, semantic_operation, "harnessError",
                                  "report projector returned missing or decision-bearing evidence",
                                  target_pid, acknowledgement, process_attempted)
        return drivers.CandidateOperationEvidence(
            self.candidate, semantic_operation, "observed", request_id, target_pid,
            disposition, {"protocolFact": asdict(protocol_fact),
                          "runtimeProcessFact": asdict(runtime_fact),
                          "processAttempted": process_attempted, **dict(projected)}, None,
        )

    def _negative(self, request_id: str, operation: str, classification: str,
                  reason: str, pid: Optional[int] = None, acknowledgement=None,
                  process_attempted: bool = False, wire: Optional[DAPWireRequest] = None,
                  *, extra_proof: Optional[Mapping[str, object]] = None):
        negative = asdict(drivers.NegativeEvidence.from_text(classification, operation, reason))
        proof: dict[str, object] = {"processAttempted": process_attempted}
        if acknowledgement is not None:
            proof["protocolAttempt"] = {
                "command": wire.command if wire else acknowledgement.command,
                "requestSequence": acknowledgement.requestSequence,
                "sessionEpoch": acknowledgement.sessionEpoch,
                "lifecycleRevision": acknowledgement.lifecycleRevision,
                "stopRevision": acknowledgement.stopRevision,
                "response": dict(acknowledgement.response),
            }
        if extra_proof:
            proof.update(dict(extra_proof))
        return drivers.CandidateOperationEvidence(
            self.candidate, operation, classification, request_id, pid,
            "targetDispositionUnknown", proof, negative,
        )

    def close(self):
        if self._close_receipt is not None:
            return self._close_receipt
        self._closed = True
        receipt = self.driver.close()
        if (not isinstance(receipt, Mapping) or receipt.get("role") != "adapter"
                or receipt.get("complete") is not True):
            raise DAPCandidateError("DAP cleanup receipt is missing or incomplete")
        self._close_receipt = dict(receipt)
        return self._close_receipt
