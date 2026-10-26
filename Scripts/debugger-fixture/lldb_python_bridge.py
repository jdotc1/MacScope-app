#!/usr/bin/env python3

"""Versioned JSONL bridge for Xcode's LLDB Python SB API.

The bridge deliberately does not inspect or signal processes itself.  A caller-
supplied authority owns launch/attach authorization and the independent process
identity checks which turn an SB API success into an observed result.
"""

from __future__ import annotations

import base64
import json
import select
import sys
import time
from dataclasses import dataclass
from pathlib import Path


BRIDGE_SCHEMA = "macscope.ws18.lldb-python-json.v1"
BRIDGE_CONTRACT_VERSION = 1
DEFAULT_MAX_RECORD_BYTES = 1 << 20

_IDENTITY_FIELDS = frozenset({
    "pid", "startTimeNS", "realUID", "effectiveUID", "canonicalPath",
    "cpuType", "cpuSubtype", "executableDevice", "executableInode",
    "executableIdentity", "machOUUID", "signingIdentity", "nonce", "role",
})
_UNSUPPORTED = frozenset({
    "moduleLoad", "moduleUnload", "cancelBeforeSpawn", "cancelInFlight",
    "timeoutRecovery", "adapterCrashRecovery",
})


class BridgeProtocolError(ValueError):
    """A malformed, stale, or uncorrelated protocol request."""


@dataclass(frozen=True)
class LLDBPythonDiscovery:
    supported: bool
    python_executable: str
    module_path: str
    version: str
    evidence: dict


def _text(result, name):
    value = getattr(result, name, "")
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def discover_selected_xcode_lldb(runner):
    """Prove the selected Xcode's lldb module and final Python executable."""
    python = "/usr/bin/python3"
    find = runner.run(["/usr/bin/xcrun", "--find", "lldb"], timeout=15.0)
    if find.returncode:
        return LLDBPythonDiscovery(False, python, "", "", {
            "stage": "find", "diagnostic": _text(find, "stderr")[:1024]})
    lldb_executable = _text(find, "stdout").strip()
    path_result = runner.run(
        [lldb_executable, "--no-lldbinit", "--batch", "-P"], timeout=15.0)
    if path_result.returncode:
        return LLDBPythonDiscovery(False, python, "", "", {
            "stage": "modulePath", "lldbExecutable": lldb_executable,
            "diagnostic": _text(path_result, "stderr")[:1024]})
    module_path = _text(path_result, "stdout").strip().splitlines()[-1]
    env = {"PYTHONPATH": module_path}
    probe_code = (
        "import ctypes,json,lldb,os\n"
        "buffer=ctypes.create_string_buffer(4096)\n"
        "libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)\n"
        "libproc.proc_pidpath.argtypes=(ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32)\n"
        "libproc.proc_pidpath.restype=ctypes.c_int\n"
        "length=libproc.proc_pidpath(os.getpid(),buffer,len(buffer))\n"
        "assert length>0\n"
        "print(json.dumps({'module':lldb.__file__,"
        "'pythonExecutable':buffer.value.decode('utf-8'),"
        "'version':lldb.SBDebugger.GetVersionString()}))"
    )
    probe = runner.run([python, "-c", probe_code], env=env, timeout=15.0)
    if probe.returncode:
        return LLDBPythonDiscovery(False, python, module_path, "", {
            "stage": "import", "lldbExecutable": lldb_executable,
            "diagnostic": _text(probe, "stderr")[:1024]})
    try:
        result = json.loads(_text(probe, "stdout").strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as error:
        return LLDBPythonDiscovery(False, python, module_path, "", {
            "stage": "importOutput", "diagnostic": str(error)})
    selected_developer = Path(lldb_executable).resolve().parents[2]
    try:
        final_python = Path(str(result["pythonExecutable"])).resolve()
        final_python.relative_to(selected_developer)
    except (IndexError, KeyError, OSError, ValueError) as error:
        return LLDBPythonDiscovery(False, python, module_path, "", {
            "stage": "pythonExecutable", "lldbExecutable": lldb_executable,
            "diagnostic": str(error)[:1024]})
    return LLDBPythonDiscovery(True, str(final_python), module_path,
                               str(result["version"]), {
        "importAvailable": True, "lldbExecutable": lldb_executable,
        "module": result.get("module", ""),
        "pythonExecutable": str(final_python),
    })


def _valid(value):
    return value is not None and (not hasattr(value, "IsValid") or value.IsValid())


def _error_message(error):
    value = error.GetCString() if error is not None and hasattr(error, "GetCString") else None
    return str(value or "LLDB operation failed")


class ExactFixtureAuthority:
    """Parent-side, exact-match authority for one configured test fixture.

    The authority never discovers processes.  Its two observer callables are
    supplied by the supervisor, which retains ownership of identity and
    post-detach survival checks.
    """

    def __init__(self, *, allowed_launch, allowed_attach_identities,
                 process_observer, detach_observer):
        self.allowed_launch = self._normalize_launch(allowed_launch)
        self.allowed_attach_identities = tuple(
            dict(identity) for identity in allowed_attach_identities)
        self.process_observer = process_observer
        self.detach_observer = detach_observer
        self._authorized_launch = None
        self._authorized_attach = None
        self._observed_by_pid = {}

    @staticmethod
    def _normalize_launch(value):
        required = {"executable", "arguments", "workingDirectory", "environment",
                    "canonicalPath", "nonce", "role"}
        missing = sorted(required - set(value))
        if missing:
            raise BridgeProtocolError(
                f"allowed launch is incomplete: {', '.join(missing)}")
        return {
            "executable": str(value["executable"]),
            "arguments": list(value["arguments"]),
            "workingDirectory": value["workingDirectory"],
            "environment": dict(value["environment"]),
            "canonicalPath": str(value["canonicalPath"]),
            "nonce": str(value["nonce"]),
            "role": str(value["role"]),
        }

    def authorize_launch(self, executable, arguments, cwd, environment):
        if (not isinstance(executable, str)
                or not isinstance(arguments, list)
                or any(not isinstance(item, str) for item in arguments)
                or (cwd is not None and not isinstance(cwd, str))
                or not isinstance(environment, dict)
                or any(not isinstance(key, str) or not isinstance(value, str)
                       for key, value in environment.items())):
            return {
                "authorized": False,
                "reasonCode": "launchRequestInvalid",
                "reason": "launch authorization fields have invalid types",
            }
        proposed = {
            "executable": executable,
            "arguments": list(arguments),
            "workingDirectory": cwd,
            "environment": dict(environment),
        }
        expected = {key: self.allowed_launch[key] for key in proposed}
        if proposed != expected:
            return {
                "authorized": False,
                "reasonCode": "launchAuthorizationMismatch",
                "reason": "launch executable, arguments, cwd, or environment differ from the configured fixture",
            }
        result = {
            "authorized": True,
            "canonicalPath": self.allowed_launch["canonicalPath"],
            "nonce": self.allowed_launch["nonce"],
            "role": self.allowed_launch["role"],
        }
        self._authorized_launch = dict(result)
        return result

    def authorize_attach(self, identity):
        if not isinstance(identity, dict):
            return {"authorized": False, "reasonCode": "attachIdentityIncomplete",
                    "reason": "attach identity must be an object"}
        missing = sorted(_IDENTITY_FIELDS - set(identity))
        if missing:
            return {"authorized": False, "reasonCode": "attachIdentityIncomplete",
                    "reason": f"attach identity is missing: {', '.join(missing)}"}
        exact = next((candidate for candidate in self.allowed_attach_identities
                      if candidate == identity), None)
        if exact is None:
            return {"authorized": False, "reasonCode": "attachAuthorizationMismatch",
                    "reason": "attach identity is not the exact configured fixture identity"}
        self._authorized_attach = dict(exact)
        return {"authorized": True, "identity": dict(exact)}

    def observe_process(self, operation, process_id, expected):
        if operation == "configuredLaunch":
            authorization = self._authorized_launch
            authorized = authorization is not None and all(
                expected.get(field) == authorization.get(field)
                for field in ("canonicalPath", "nonce", "role"))
        elif operation == "attach":
            authorization = self._authorized_attach
            authorized = authorization is not None and expected == authorization
        else:
            authorized = False
        if not authorized:
            return {"identityMatched": False,
                    "reasonCode": "processObservationNotAuthorized",
                    "reason": "process observation did not follow an exact authorization"}
        result = self.process_observer(operation, int(process_id), dict(expected))
        if not isinstance(result, dict) or result.get("identityMatched") is not True:
            return {"identityMatched": False,
                    "reasonCode": "processIdentityMismatch",
                    "reason": "supervisor did not prove the expected process identity"}
        if result.get("pid") != int(process_id):
            return {"identityMatched": False, "reasonCode": "processPIDMismatch",
                    "reason": "supervisor observation returned a different PID"}
        if result.get("canonicalPath") != expected.get("canonicalPath"):
            return {"identityMatched": False, "reasonCode": "processPathMismatch",
                    "reason": "supervisor observation returned a different path"}
        if result.get("nonce") != expected.get("nonce"):
            return {"identityMatched": False, "reasonCode": "processNonceMismatch",
                    "reason": "supervisor observation returned a different nonce"}
        self._observed_by_pid[int(process_id)] = dict(expected)
        return dict(result)

    def confirm_detach(self, identity, process_id):
        observed = self._observed_by_pid.get(int(process_id))
        if observed is None:
            return {"sameIdentity": False, "alive": False, "controllable": False,
                    "checkpointSequence": 0, "pid": int(process_id),
                    "reasonCode": "detachTargetNotObserved"}
        if (identity.get("canonicalPath") != observed.get("canonicalPath")
                or identity.get("nonce") != observed.get("nonce")):
            return {"sameIdentity": False, "alive": False, "controllable": False,
                    "checkpointSequence": 0, "pid": int(process_id),
                    "reasonCode": "detachIdentityMismatch"}
        result = self.detach_observer(dict(identity), int(process_id))
        return dict(result) if isinstance(result, dict) else {
            "sameIdentity": False, "alive": False, "controllable": False,
            "checkpointSequence": 0, "pid": int(process_id),
            "reasonCode": "detachObserverInvalidResponse",
        }

    def handle_authority_request(self, message):
        _validate_authority_message(message, "authorityRequest")
        operation = message["authorityOperation"]
        payload = message.get("payload")
        if not isinstance(payload, dict):
            raise BridgeProtocolError("authority payload must be an object")
        if operation == "authorizeLaunch":
            result = self.authorize_launch(
                payload.get("executable"), payload.get("arguments", []),
                payload.get("workingDirectory"), payload.get("environment", {}))
        elif operation == "authorizeAttach":
            result = self.authorize_attach(payload.get("identity"))
        elif operation == "observeProcess":
            result = self.observe_process(
                payload.get("targetOperation"), payload.get("processID"),
                payload.get("expected", {}))
        elif operation == "confirmDetach":
            result = self.confirm_detach(
                payload.get("identity", {}), payload.get("processID"))
        else:
            result = {"authorized": False, "reasonCode": "authorityOperationUnsupported",
                      "reason": f"unsupported authority operation: {operation}"}
        response = {key: message[key] for key in (
            "schema", "contractVersion", "authorityRequestID", "requestID",
            "sessionID", "sessionEpoch", "sequence", "operation",
            "authorityOperation")}
        response.update({"messageType": "authorityResponse", "result": result})
        return response


def _validate_authority_message(message, expected_type):
    if not isinstance(message, dict):
        raise BridgeProtocolError("authority message must be an object")
    if message.get("schema") != BRIDGE_SCHEMA:
        raise BridgeProtocolError("authority schema mismatch")
    if message.get("contractVersion") != BRIDGE_CONTRACT_VERSION:
        raise BridgeProtocolError("authority contract version mismatch")
    if message.get("messageType") != expected_type:
        raise BridgeProtocolError(f"expected {expected_type}")
    for field in ("authorityRequestID", "requestID", "sessionID", "sessionEpoch",
                  "sequence", "operation", "authorityOperation"):
        if field not in message:
            raise BridgeProtocolError(f"authority message missing {field}")
    if expected_type == "authorityRequest":
        timeout = message.get("timeoutMS")
        if not isinstance(timeout, int) or timeout <= 0 or timeout > 300_000:
            raise BridgeProtocolError("authority timeoutMS is out of bounds")
        if len(_canonical_json_line(message)) > DEFAULT_MAX_RECORD_BYTES:
            raise BridgeProtocolError("authority request exceeds byte limit")


class JSONLParentAuthorityProxy:
    """Child-side bounded callback proxy to the parent supervisor authority."""

    def __init__(self, reader, writer, *, wait_readable=None, clock=None,
                 max_record_bytes=DEFAULT_MAX_RECORD_BYTES, maximum_callbacks=8):
        self.reader = reader
        self.writer = writer
        self.wait_readable = wait_readable or self._select_readable
        self.clock = clock or time.monotonic
        self.max_record_bytes = max(1024, int(max_record_bytes))
        self.maximum_callbacks = max(1, min(int(maximum_callbacks), 32))
        self.context = None
        self.deadline = None
        self.callback_sequence = 0

    @staticmethod
    def _select_readable(stream, timeout):
        readable, _, _ = select.select([stream], [], [], timeout)
        return bool(readable)

    def begin_request(self, request):
        self.context = {key: request[key] for key in (
            "requestID", "sessionID", "sessionEpoch", "sequence", "operation")}
        self.deadline = self.clock() + min(int(request.get("timeoutMS", 1000)), 300_000) / 1000.0
        self.callback_sequence = 0

    def end_request(self):
        self.context = None
        self.deadline = None

    def authorize_launch(self, executable, arguments, cwd, environment):
        return self._call("authorizeLaunch", {
            "executable": executable, "arguments": list(arguments),
            "workingDirectory": cwd, "environment": dict(environment),
        })

    def authorize_attach(self, identity):
        return self._call("authorizeAttach", {"identity": dict(identity)})

    def observe_process(self, operation, process_id, expected):
        return self._call("observeProcess", {
            "targetOperation": operation, "processID": int(process_id),
            "expected": dict(expected),
        })

    def confirm_detach(self, identity, process_id):
        return self._call("confirmDetach", {
            "identity": dict(identity), "processID": int(process_id),
        })

    def _call(self, authority_operation, payload):
        if self.context is None or self.deadline is None:
            raise BridgeProtocolError("authority callback has no active request")
        self.callback_sequence += 1
        if self.callback_sequence > self.maximum_callbacks:
            raise BridgeProtocolError("authority callback limit exceeded")
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise TimeoutError("authority callback deadline exceeded")
        callback = {
            "schema": BRIDGE_SCHEMA, "contractVersion": BRIDGE_CONTRACT_VERSION,
            "messageType": "authorityRequest",
            "authorityRequestID": (
                f"{self.context['requestID']}:authority:{self.callback_sequence}"),
            **self.context,
            "authorityOperation": authority_operation,
            "timeoutMS": max(1, int(remaining * 1000)),
            "payload": payload,
        }
        raw = _canonical_json_line(callback)
        if len(raw) > self.max_record_bytes:
            raise BridgeProtocolError("authority callback exceeds byte limit")
        self.writer.write(raw)
        if hasattr(self.writer, "flush"):
            self.writer.flush()
        if not self.wait_readable(self.reader, remaining):
            raise TimeoutError("parent authority response deadline exceeded")
        response_raw = self.reader.readline(self.max_record_bytes + 2)
        if not response_raw or len(response_raw) > self.max_record_bytes:
            raise BridgeProtocolError("missing or oversized parent authority response")
        response = json.loads(response_raw)
        _validate_authority_message(response, "authorityResponse")
        for field in ("authorityRequestID", "requestID", "sessionID", "sessionEpoch",
                      "sequence", "operation", "authorityOperation"):
            if response.get(field) != callback.get(field):
                raise BridgeProtocolError(f"authority response {field} correlation mismatch")
        result = response.get("result")
        if not isinstance(result, dict):
            raise BridgeProtocolError("authority response result must be an object")
        return result


class LLDBPythonBridge:
    """Stateful, single-session adapter around an injected LLDB SB module."""

    def __init__(self, sb_module, authority, clock=None):
        self.sb = sb_module
        self.authority = authority
        self.clock = clock or time.monotonic
        self.debugger = None
        self.listener = None
        self.target = None
        self.process = None
        self.identity = None
        self.session_id = None
        self.session_epoch = None
        self.last_sequence = 0
        self.lifecycle_revision = 0
        self.stop_revision = 0
        self.ownership = "none"
        self.target_disposition = "notStarted"
        self.terminal_fact = None

    def handle(self, message):
        self._validate_envelope(message)
        if hasattr(self.authority, "begin_request"):
            self.authority.begin_request(message)
        try:
            operation = message["operation"]
            arguments = message.get("arguments", {})
            if operation == "initialize":
                result, evidence = self._initialize()
                observation, diagnostic = "observed", {}
            elif operation in _UNSUPPORTED:
                result, evidence = {}, {}
                observation = "unsupported"
                diagnostic = {"reason": f"{operation} is owned by the fixture supervisor, not the SB bridge"}
            else:
                handler = getattr(self, f"_op_{operation}", None)
                if handler is None:
                    result, evidence, observation = {}, {}, "unsupported"
                    diagnostic = {"reason": f"unknown bridge operation: {operation}"}
                else:
                    result, evidence, observation, diagnostic = handler(arguments)
        finally:
            if hasattr(self.authority, "end_request"):
                self.authority.end_request()
        return self._response(message, result, evidence, observation, diagnostic)

    def _wait_for_process_state(self, process, expected_state, timeout=5.0):
        """Drive and observe one bridge-owned asynchronous SBProcess transition."""
        deadline = self.clock() + timeout
        terminal_states = {
            getattr(self.sb, "eStateExited", object()),
            getattr(self.sb, "eStateDetached", object()),
        }
        state = process.GetState()
        while state != expected_state and state not in terminal_states:
            remaining = deadline - self.clock()
            if remaining <= 0:
                break
            event = self.sb.SBEvent()
            if (self.listener is not None
                    and self.listener.WaitForEvent(0, event)
                    and self.sb.SBProcess.EventIsProcessEvent(event)):
                state = self.sb.SBProcess.GetStateFromEvent(event)
                continue
            time.sleep(min(0.01, remaining))
            state = process.GetState()
        return state

    def _validate_envelope(self, message):
        if not isinstance(message, dict):
            raise BridgeProtocolError("request must be an object")
        if message.get("schema") != BRIDGE_SCHEMA:
            raise BridgeProtocolError("schema mismatch")
        if message.get("contractVersion") != BRIDGE_CONTRACT_VERSION:
            raise BridgeProtocolError("contract version mismatch")
        for field in ("requestID", "sessionID", "sessionEpoch", "sequence", "operation"):
            if field not in message:
                raise BridgeProtocolError(f"missing {field}")
        sequence = message["sequence"]
        if not isinstance(sequence, int) or sequence <= self.last_sequence:
            raise BridgeProtocolError("sequence must increase monotonically")
        if self.session_id is None:
            if message["operation"] != "initialize":
                raise BridgeProtocolError("initialize must be first")
            self.session_id = message["sessionID"]
            self.session_epoch = message["sessionEpoch"]
        elif message["sessionID"] != self.session_id:
            raise BridgeProtocolError("session mismatch")
        elif message["sessionEpoch"] != self.session_epoch:
            raise BridgeProtocolError("session epoch mismatch")
        timeout = message.get("timeoutMS", 1000)
        if not isinstance(timeout, int) or timeout <= 0 or timeout > 300_000:
            raise BridgeProtocolError("timeoutMS is out of bounds")
        self.last_sequence = sequence

    def _response(self, request, result, evidence, observation, diagnostic):
        return {
            "schema": BRIDGE_SCHEMA,
            "contractVersion": BRIDGE_CONTRACT_VERSION,
            "requestID": request["requestID"],
            "sessionID": request["sessionID"],
            "sessionEpoch": request["sessionEpoch"],
            "sequence": request["sequence"],
            "operation": request["operation"],
            "observation": observation,
            "lifecycleRevision": self.lifecycle_revision,
            "stopRevision": self.stop_revision,
            "targetDisposition": self.target_disposition,
            "ownership": self.ownership,
            "result": result,
            "evidence": evidence,
            "diagnostic": diagnostic,
        }

    @staticmethod
    def _postcondition(**details):
        return {"postcondition": {"satisfied": True, **details}}

    def _initialize(self):
        if self.debugger is not None:
            raise BridgeProtocolError("bridge is already initialized")
        self.debugger = self.sb.SBDebugger.Create()
        self.debugger.SetAsync(False)
        self.listener = self.debugger.GetListener()
        self.lifecycle_revision = 1
        return {
            "lldbVersion": self.sb.SBDebugger.GetVersionString(),
            "capabilities": self._capabilities(),
        }, self._postcondition(debuggerCreated=True, asynchronous=False)

    def _capabilities(self):
        return {
            "launch": True, "attach": True, "nonterminatingDetach": True,
            "pause": True, "continue": True, "stepping": True,
            "breakpoints": True, "threads": True, "frames": True,
            "registers": True, "memory": True, "expressions": True,
            "modules": True,
        }

    def _op_capabilities(self, arguments):
        return self._capabilities(), self._postcondition(frozen=True), "observed", {}

    def _op_configuredLaunch(self, arguments):
        executable = arguments.get("executable")
        if not isinstance(executable, str) or not executable:
            return {}, {}, "identityMismatch", {"reason": "missing executable"}
        if arguments.get("stopAtEntry") is not True:
            return {}, {}, "identityMismatch", {
                "reason": "configured launch must start stopped at entry"}
        argv = arguments.get("arguments", [])
        cwd = arguments.get("workingDirectory")
        environment = arguments.get("environment", {})
        authorization = self.authority.authorize_launch(executable, argv, cwd, environment)
        if not authorization.get("authorized"):
            return {}, {"authorization": authorization}, "identityMismatch", {"reason": "launch denied"}
        canonical = authorization.get("canonicalPath", executable)
        self.target = self.debugger.CreateTarget(canonical)
        if not _valid(self.target):
            return {}, {}, "adapterError", {"reason": "CreateTarget returned invalid target"}
        launch_info = self.sb.SBLaunchInfo(argv)
        if cwd:
            launch_info.SetWorkingDirectory(cwd)
        if environment:
            launch_info.SetEnvironmentEntries(
                [f"{key}={value}" for key, value in sorted(environment.items())], False)
        launch_info.SetLaunchFlags(self.sb.eLaunchFlagStopAtEntry)
        error = self.sb.SBError()
        process = self.target.Launch(launch_info, error)
        if not _valid(process) or (hasattr(error, "Fail") and error.Fail()):
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        pid = int(process.GetProcessID())
        expected = {**authorization, "canonicalPath": canonical}
        if process.GetState() != self.sb.eStateStopped:
            cleanup = self._abort_unpublished_launch(process)
            return {}, {"cleanup": cleanup}, "adapterError", {
                "reason": "configured launch did not stop at entry"}

        observed = None
        failure_observation = None
        failure_reason = None
        stop_error = None
        continued = False
        try:
            self.debugger.SetAsync(True)
            continue_error = process.Continue()
            if hasattr(continue_error, "Fail") and continue_error.Fail():
                failure_observation = "adapterError"
                failure_reason = f"failed to resume configured launch: {_error_message(continue_error)}"
            elif int(process.GetProcessID()) != pid:
                failure_observation = "identityMismatch"
                failure_reason = "configured launch PID changed before readiness observation"
            else:
                continued = True
                state = self._wait_for_process_state(
                    process, self.sb.eStateRunning)
                if state != self.sb.eStateRunning:
                    failure_observation = "adapterError"
                    failure_reason = "configured launch did not enter the running state"
                else:
                    try:
                        observed = self.authority.observe_process(
                            "configuredLaunch", pid, expected)
                    except Exception as error:
                        failure_observation = "adapterError"
                        failure_reason = f"configured launch readiness observation failed: {error}"
        except Exception as error:
            failure_observation = "adapterError"
            failure_reason = f"configured launch resume failed: {error}"
        finally:
            if continued:
                try:
                    stop_error = process.Stop()
                except Exception as error:
                    stop_error = error
            try:
                self.debugger.SetAsync(False)
            except Exception as error:
                if failure_reason is None:
                    failure_observation = "adapterError"
                    failure_reason = f"failed to restore synchronous debugger mode: {error}"

        restored_state = (self._wait_for_process_state(
            process, self.sb.eStateStopped) if continued else None)
        stopped = restored_state == self.sb.eStateStopped
        if isinstance(stop_error, Exception) and not stopped:
            failure_observation = "adapterError"
            failure_reason = f"failed to stop configured launch after readiness: {stop_error}"
        elif (continued and hasattr(stop_error, "Fail") and stop_error.Fail()
              and not stopped):
            failure_observation = "adapterError"
            failure_reason = (
                f"failed to stop configured launch after readiness: "
                f"{_error_message(stop_error)}")
        elif continued and int(process.GetProcessID()) != pid:
            failure_observation = "identityMismatch"
            failure_reason = "configured launch PID changed during readiness sequencing"
        elif continued and not stopped:
            failure_observation = "adapterError"
            failure_reason = "configured launch was not stopped after readiness observation"

        if failure_reason is None and (
                not isinstance(observed, dict)
                or observed.get("identityMatched") is not True):
            failure_observation = "identityMismatch"
            failure_reason = "launch identity not observed"
        if failure_reason is not None:
            admitted = (isinstance(observed, dict)
                        and observed.get("identityMatched") is True)
            if admitted:
                self.process = process
                self.identity = {**expected, **observed}
                self.ownership = "launchedTestFixture"
                self.target_disposition = self._state_name(process.GetState())
                cleanup = {"delegatedToOuterSupervisor": True}
            else:
                cleanup = self._abort_unpublished_launch(process)
            evidence = {"cleanup": cleanup}
            if isinstance(observed, dict):
                evidence["processObservation"] = observed
            return {}, evidence, failure_observation, {"reason": failure_reason}

        self.process = process
        self.identity = {**expected, **observed}
        self.ownership = "launchedTestFixture"
        self.target_disposition = self._state_name(process.GetState())
        self.lifecycle_revision += 1
        if process.GetState() == self.sb.eStateStopped:
            self.stop_revision += 1
        return {"targetPID": pid}, self._postcondition(
            targetPID=pid, processObservation=observed,
            resumedForReadiness=True, samePIDStopped=True,
            asynchronous=False), "observed", {}

    def _abort_unpublished_launch(self, process):
        """Terminate only the SB process created by this bridge before publication."""
        self.process = None
        self.identity = None
        self.ownership = "none"
        try:
            error = process.Kill()
            succeeded = not (hasattr(error, "Fail") and error.Fail())
        except Exception as error:
            succeeded = False
        state = process.GetState()
        self.target_disposition = (
            self._state_name(state) if succeeded
            else "targetDispositionUnknown")
        return {"killRequested": True, "complete": succeeded,
                "targetDisposition": self.target_disposition}

    def _op_attach(self, arguments):
        identity = arguments.get("identity")
        missing = sorted(_IDENTITY_FIELDS - set(identity or {}))
        if missing:
            self.target_disposition = "targetDispositionUnknown"
            return {}, {"missingIdentityFields": missing}, "identityMismatch", {
                "reason": "attach requires a complete process identity"}
        authorization = self.authority.authorize_attach(identity)
        if not authorization.get("authorized"):
            self.target_disposition = "targetDispositionUnknown"
            return {}, {"authorization": authorization}, "identityMismatch", {"reason": "attach denied"}
        expected = authorization.get("identity", identity)
        self.target = self.debugger.CreateTarget(expected["canonicalPath"])
        attach_info = self.sb.SBAttachInfo(int(expected["pid"]))
        if hasattr(attach_info, "SetWaitForLaunch"):
            attach_info.SetWaitForLaunch(False)
        error = self.sb.SBError()
        process = self.target.Attach(attach_info, error)
        if not _valid(process) or (hasattr(error, "Fail") and error.Fail()):
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        pid = int(process.GetProcessID())
        if pid != int(expected["pid"]):
            self.target_disposition = "targetDispositionUnknown"
            return {}, {"sbPID": pid, "expectedPID": expected["pid"]}, "identityMismatch", {
                "reason": "SB process PID differs from authorized PID"}
        observed = self.authority.observe_process("attach", pid, expected)
        if not observed.get("identityMatched"):
            self.target_disposition = "targetDispositionUnknown"
            return {}, {"processObservation": observed}, "identityMismatch", {
                "reason": "attached identity did not match"}
        self.process = process
        self.identity = dict(expected)
        self.ownership = "attachedTestFixture"
        self.target_disposition = self._state_name(process.GetState())
        self.lifecycle_revision += 1
        if process.GetState() == self.sb.eStateStopped:
            self.stop_revision += 1
        return {"targetPID": pid}, self._postcondition(
            targetPID=pid, processObservation=observed), "observed", {}

    def _op_detach(self, arguments):
        if not self._has_process():
            return {}, {}, "adapterError", {"reason": "no live process"}
        pid = int(self.process.GetProcessID())
        error = self.process.Detach()
        if hasattr(error, "Fail") and error.Fail():
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        proof = self.authority.confirm_detach(self.identity, pid)
        valid = (
            proof.get("sameIdentity") is True and proof.get("alive") is True
            and proof.get("controllable") is True
            and isinstance(proof.get("checkpointSequence"), int)
            and proof["checkpointSequence"] > 0
            and proof.get("pid") == pid
            and proof.get("canonicalPath") == self.identity.get("canonicalPath")
            and proof.get("nonce") == self.identity.get("nonce")
        )
        if not valid:
            self.target_disposition = "targetDispositionUnknown"
            return {"terminateRequested": False, "postDetach": proof}, {
                "survivalProof": proof}, "identityMismatch", {
                    "reason": "nonterminating detach survival proof failed"}
        self.target_disposition = "detached"
        self.lifecycle_revision += 1
        return {"terminateRequested": False, "postDetach": proof}, self._postcondition(
            detached=True, survivalProof=proof), "observed", {}

    def _op_pollEvents(self, arguments):
        maximum = max(1, min(int(arguments.get("maximumEvents", 32)), 256))
        events = []
        for _ in range(maximum):
            event = self.sb.SBEvent()
            if not self.listener.WaitForEvent(0, event):
                break
            if self.sb.SBProcess.EventIsProcessEvent(event):
                state = self.sb.SBProcess.GetStateFromEvent(event)
                name = self._state_name(state)
                self.lifecycle_revision += 1
                if state == self.sb.eStateStopped:
                    self.stop_revision += 1
                self.target_disposition = name
                events.append({"state": name, "eventType": event.GetType()})
        return {"events": events}, self._postcondition(eventsConsumed=len(events)), "observed", {}

    def _op_pause(self, arguments):
        return self._process_command("Stop", self.sb.eStateStopped)

    def _op_continue(self, arguments):
        return self._process_command("Continue", self.sb.eStateRunning)

    def _op_terminate(self, arguments):
        if not self._has_process():
            return {}, {}, "adapterError", {"reason": "no live process"}
        pid = int(self.process.GetProcessID())
        try:
            error = self.process.Kill()
            state = self.process.GetState()
        except Exception as error:
            return {}, {}, "adapterError", {"reason": str(error)}
        if hasattr(error, "Fail") and error.Fail():
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        disposition = self._state_name(state)
        self.target_disposition = disposition
        if state != self.sb.eStateExited:
            return {"targetPID": pid, "state": disposition}, {}, "adapterError", {
                "reason": "terminate did not produce an exited process state"}
        self.lifecycle_revision += 1
        self.terminal_fact = {
            "targetPID": pid,
            "state": "exited",
            "originatingOperation": "terminate",
            "terminalLifecycleRevision": self.lifecycle_revision,
        }
        return {"targetPID": pid, "state": "exited"}, self._postcondition(
            **self.terminal_fact), "observed", {}

    def _op_expectedExit(self, arguments):
        if not self._has_process():
            return {}, {}, "adapterError", {"reason": "no process exists to prove expected exit"}
        pid = int(self.process.GetProcessID())
        try:
            state = self.process.GetState()
        except Exception as error:
            return {"targetPID": pid}, {}, "adapterError", {"reason": str(error)}
        disposition = self._state_name(state)
        self.target_disposition = disposition
        if state != self.sb.eStateExited:
            return {"targetPID": pid, "state": disposition}, {}, "adapterError", {
                "reason": "target process has not exited"}
        fact = self.terminal_fact
        if not isinstance(fact, dict) or fact.get("targetPID") != pid:
            fact = {
                "targetPID": pid,
                "state": "exited",
                "originatingOperation": "processStateObservation",
                "terminalLifecycleRevision": self.lifecycle_revision,
            }
            self.terminal_fact = fact
        return dict(fact), self._postcondition(**fact), "observed", {}

    def _process_command(self, method, expected_state):
        if not self._has_process():
            return {}, {}, "adapterError", {"reason": "no live process"}
        error = getattr(self.process, method)()
        if hasattr(error, "Fail") and error.Fail():
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        state = self.process.GetState()
        if state != expected_state:
            return {"state": self._state_name(state)}, {}, "adapterError", {
                "reason": "process state postcondition failed"}
        self.lifecycle_revision += 1
        if state == self.sb.eStateStopped:
            self.stop_revision += 1
        self.target_disposition = self._state_name(state)
        return {"state": self.target_disposition}, self._postcondition(
            state=self.target_disposition), "observed", {}

    def _op_stepInto(self, arguments):
        return self._step("StepInto")

    def _op_stepOver(self, arguments):
        return self._step("StepOver")

    def _op_stepOut(self, arguments):
        return self._step("StepOut")

    def _step(self, method):
        thread = self.process.GetSelectedThread() if self._has_process() else None
        if not _valid(thread):
            return {}, {}, "adapterError", {"reason": "no selected thread"}
        getattr(thread, method)()
        event = self.sb.SBEvent()
        if self.listener.WaitForEvent(0, event) and self.sb.SBProcess.EventIsProcessEvent(event):
            state = self.sb.SBProcess.GetStateFromEvent(event)
        else:
            state = self.process.GetState()
        if state != self.sb.eStateStopped:
            return {"state": self._state_name(state)}, {}, "adapterError", {
                "reason": "step did not produce a stopped postcondition"}
        self.lifecycle_revision += 1
        self.stop_revision += 1
        self.target_disposition = "stopped"
        return {"state": "stopped"}, self._postcondition(state="stopped"), "observed", {}

    def _op_breakpointCreation(self, arguments):
        item = self.target.BreakpointCreateByAddress(int(arguments["address"])) if self.target else None
        if not _valid(item):
            return {}, {}, "adapterError", {"reason": "breakpoint creation failed"}
        return {"breakpointID": item.GetID(), "locations": item.GetNumLocations()}, self._postcondition(
            breakpointID=item.GetID(), locationCount=item.GetNumLocations()), "observed", {}

    def _breakpoint(self, arguments):
        item = self.target.FindBreakpointByID(int(arguments["breakpointID"])) if self.target else None
        return item if _valid(item) else None

    def _op_breakpointDelete(self, arguments):
        identifier = int(arguments["breakpointID"])
        deleted = bool(self.target and self.target.BreakpointDelete(identifier))
        if not deleted:
            return {}, {}, "adapterError", {"reason": "breakpoint not found"}
        return {"breakpointID": identifier, "deleted": True}, self._postcondition(deleted=True), "observed", {}

    def _breakpoint_mutation(self, arguments, method, value, result_name):
        item = self._breakpoint(arguments)
        if item is None:
            return {}, {}, "adapterError", {"reason": "breakpoint not found"}
        getattr(item, method)(value)
        return {"breakpointID": item.GetID(), result_name: value}, self._postcondition(
            breakpointID=item.GetID(), **{result_name: value}), "observed", {}

    def _op_breakpointEnable(self, arguments):
        return self._breakpoint_mutation(arguments, "SetEnabled", True, "enabled")

    def _op_breakpointDisable(self, arguments):
        return self._breakpoint_mutation(arguments, "SetEnabled", False, "enabled")

    def _op_breakpointCondition(self, arguments):
        return self._breakpoint_mutation(arguments, "SetCondition", str(arguments.get("condition", "")), "condition")

    def _op_breakpointIgnoreCount(self, arguments):
        return self._breakpoint_mutation(arguments, "SetIgnoreCount", int(arguments.get("ignoreCount", 0)), "ignoreCount")

    def _op_breakpointHitCount(self, arguments):
        item = self._breakpoint(arguments)
        if item is None:
            return {}, {}, "adapterError", {"reason": "breakpoint not found"}
        count = int(item.GetHitCount())
        return {"breakpointID": item.GetID(), "hitCount": count}, self._postcondition(hitCount=count), "observed", {}

    def _op_threadList(self, arguments):
        threads = []
        for index in range(self.process.GetNumThreads() if self._has_process() else 0):
            item = self.process.GetThreadAtIndex(index)
            threads.append({"threadID": item.GetThreadID(), "name": item.GetName() or "",
                            "stopReason": item.GetStopReason()})
        return {"threads": threads}, self._postcondition(count=len(threads)), "observed", {}

    def _thread(self, identifier):
        item = self.process.GetThreadByID(int(identifier)) if self._has_process() else None
        return item if _valid(item) else None

    def _op_threadSelection(self, arguments):
        item = self._thread(arguments["threadID"])
        if item is None or not self.process.SetSelectedThread(item):
            return {}, {}, "adapterError", {"reason": "thread selection failed"}
        return {"threadID": item.GetThreadID()}, self._postcondition(threadID=item.GetThreadID()), "observed", {}

    def _op_frameList(self, arguments):
        thread = self._thread(arguments.get("threadID", self.process.GetSelectedThread().GetThreadID()))
        frames = []
        for index in range(thread.GetNumFrames() if thread else 0):
            frame = thread.GetFrameAtIndex(index)
            frames.append({"frameIndex": index, "frameID": frame.GetFrameID(),
                           "pc": frame.GetPCAddress().GetLoadAddress(self.target),
                           "function": frame.GetFunctionName() or ""})
        return {"frames": frames}, self._postcondition(count=len(frames)), "observed", {}

    def _op_frameSelection(self, arguments):
        thread = self._thread(arguments.get("threadID", self.process.GetSelectedThread().GetThreadID()))
        index = int(arguments["frameIndex"])
        if thread is None or not thread.SetSelectedFrame(index):
            return {}, {}, "adapterError", {"reason": "frame selection failed"}
        return {"threadID": thread.GetThreadID(), "frameIndex": index}, self._postcondition(
            frameIndex=index), "observed", {}

    def _frame(self, arguments):
        thread_id = arguments.get("threadID")
        thread = self._thread(thread_id) if thread_id is not None else (
            self.process.GetSelectedThread() if self._has_process() else None)
        if not _valid(thread):
            return None
        index = arguments.get("frameIndex")
        return thread.GetFrameAtIndex(int(index)) if index is not None else thread.GetSelectedFrame()

    def _op_registerRead(self, arguments):
        frame = self._frame(arguments)
        if not _valid(frame):
            return {}, {}, "adapterError", {"reason": "frame not found"}
        registers = []
        groups = frame.GetRegisters()
        for group_index in range(groups.GetSize()):
            group = groups.GetValueAtIndex(group_index)
            if hasattr(group, "GetNumChildren"):
                for index in range(group.GetNumChildren()):
                    registers.append(self._value(group.GetChildAtIndex(index)))
            elif group.GetValue() is not None:
                registers.append(self._value(group))
        return {"registers": registers}, self._postcondition(count=len(registers)), "observed", {}

    def _op_registerWrite(self, arguments):
        frame = self._frame(arguments)
        name, value = str(arguments["name"]), str(arguments["value"])
        if not _valid(frame):
            return {}, {}, "adapterError", {"reason": "frame not found"}
        groups = frame.GetRegisters()
        for group_index in range(groups.GetSize()):
            group = groups.GetValueAtIndex(group_index)
            for index in range(group.GetNumChildren() if hasattr(group, "GetNumChildren") else 0):
                register = group.GetChildAtIndex(index)
                if register.GetName() == name and register.SetValueFromCString(value):
                    return {"name": name, "value": register.GetValue()}, self._postcondition(
                        name=name, value=register.GetValue()), "observed", {}
        return {}, {}, "adapterError", {"reason": "register not found or not writable"}

    @staticmethod
    def _value(item):
        return {"name": item.GetName() or "", "value": item.GetValue(),
                "summary": item.GetSummary(), "type": item.GetTypeName() or ""}

    def _op_memoryRead(self, arguments):
        error = self.sb.SBError()
        size = max(0, min(int(arguments["size"]), 16 * 1024 * 1024))
        data = self.process.ReadMemory(int(arguments["address"]), size, error)
        if hasattr(error, "Fail") and error.Fail():
            return {}, {}, "adapterError", {"reason": _error_message(error)}
        encoded = base64.b64encode(bytes(data)).decode("ascii")
        return {"dataBase64": encoded, "bytesRead": len(data)}, self._postcondition(
            bytesRead=len(data)), "observed", {}

    def _op_memoryWrite(self, arguments):
        try:
            data = base64.b64decode(arguments["dataBase64"], validate=True)
        except Exception as error:
            return {}, {}, "protocolError", {"reason": f"invalid base64: {error}"}
        error = self.sb.SBError()
        count = int(self.process.WriteMemory(int(arguments["address"]), data, error))
        if (hasattr(error, "Fail") and error.Fail()) or count != len(data):
            return {"bytesWritten": count}, {}, "adapterError", {"reason": _error_message(error)}
        return {"bytesWritten": count}, self._postcondition(bytesWritten=count), "observed", {}

    def _op_expressionEvaluation(self, arguments):
        frame = self._frame(arguments)
        if not _valid(frame):
            return {}, {}, "adapterError", {"reason": "frame not found"}
        options = self.sb.SBExpressionOptions()
        value = frame.EvaluateExpression(str(arguments["expression"]), options)
        if not _valid(value):
            return {}, {}, "adapterError", {"reason": "expression evaluation failed"}
        result = self._value(value)
        return result, self._postcondition(value=result.get("value"), summary=result.get("summary")), "observed", {}

    def _op_moduleList(self, arguments):
        modules = []
        for index in range(self.target.GetNumModules() if self.target else 0):
            module = self.target.GetModuleAtIndex(index)
            modules.append({"path": module.GetFileSpec().GetPath(),
                            "uuid": module.GetUUIDString() or ""})
        return {"modules": modules}, self._postcondition(count=len(modules)), "observed", {}

    def _has_process(self):
        return _valid(self.process)

    def _state_name(self, state):
        mapping = {
            getattr(self.sb, "eStateStopped", -1): "stopped",
            getattr(self.sb, "eStateRunning", -2): "running",
            getattr(self.sb, "eStateExited", -3): "exited",
            getattr(self.sb, "eStateDetached", -4): "detached",
        }
        return mapping.get(state, "targetDispositionUnknown")

    def close(self):
        if self.debugger is not None:
            self.sb.SBDebugger.Destroy(self.debugger)
            self.debugger = None


def _canonical_json_line(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


class JSONLBridgeServer:
    def __init__(self, engine, reader, writer, max_record_bytes=DEFAULT_MAX_RECORD_BYTES):
        self.engine = engine
        self.reader = reader
        self.writer = writer
        self.max_record_bytes = max(128, int(max_record_bytes))

    def serve_one(self):
        raw = self.reader.readline(self.max_record_bytes + 2)
        if not raw:
            return "eof"
        if len(raw) > self.max_record_bytes or not raw.endswith(b"\n"):
            return self._protocol_error("record exceeds byte limit")
        try:
            message = json.loads(raw)
            response = self.engine.handle(message)
        except (UnicodeDecodeError, json.JSONDecodeError, BridgeProtocolError, TypeError, KeyError, ValueError) as error:
            return self._protocol_error(str(error))
        self._write(response)
        return response["observation"]

    def serve_forever(self):
        while self.serve_one() != "eof":
            pass

    def _protocol_error(self, reason):
        response = {"schema": BRIDGE_SCHEMA, "contractVersion": BRIDGE_CONTRACT_VERSION,
                    "observation": "protocolError", "diagnostic": {"reason": reason[:64]}}
        raw = self._encoded(response)
        if len(raw) > self.max_record_bytes:
            response["diagnostic"] = {"reason": "invalid record"}
        self._write(response)
        return "protocolError"

    @staticmethod
    def _encoded(value):
        return _canonical_json_line(value)

    def _write(self, value):
        self.writer.write(self._encoded(value))
        if hasattr(self.writer, "flush"):
            self.writer.flush()


class LLDBPythonBridgeClient:
    """Bounded JSONL client whose process lifecycle is supplied by its caller."""

    def __init__(self, discovery, lifecycle, wait_readable=None, authority=None,
                 maximum_authority_callbacks=8):
        if not discovery.supported:
            raise BridgeProtocolError("LLDB Python discovery is unsupported")
        self.discovery = discovery
        self.lifecycle = lifecycle
        self.wait_readable = wait_readable or self._select_readable
        self.authority = authority
        self.maximum_authority_callbacks = max(
            1, min(int(maximum_authority_callbacks), 32))
        script = str(Path(__file__).resolve())
        env = {"PYTHONPATH": discovery.module_path}
        self.process, self.registration = lifecycle.spawn_and_register(
            [discovery.python_executable, script, "--child"], env)
        self.closed = False

    @staticmethod
    def _select_readable(stream, timeout):
        readable, _, _ = select.select([stream], [], [], timeout)
        return bool(readable)

    def request(self, message):
        if self.closed:
            raise BridgeProtocolError("bridge client is closed")
        raw = JSONLBridgeServer._encoded(message)
        if len(raw) > DEFAULT_MAX_RECORD_BYTES:
            raise BridgeProtocolError("request exceeds byte limit")
        self.process.stdin.write(raw)
        self.process.stdin.flush()
        timeout = max(0.001, min(float(message.get("timeoutMS", 1000)) / 1000.0, 300.0))
        deadline = time.monotonic() + timeout
        callback_count = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not self.wait_readable(self.process.stdout, remaining):
                raise TimeoutError(f"LLDB bridge deadline exceeded for {message.get('requestID')}")
            response_raw = self.process.stdout.readline(DEFAULT_MAX_RECORD_BYTES + 2)
            if not response_raw or len(response_raw) > DEFAULT_MAX_RECORD_BYTES:
                raise BridgeProtocolError("missing or oversized bridge response")
            response = json.loads(response_raw)
            if response.get("messageType") == "authorityRequest":
                callback_count += 1
                if callback_count > self.maximum_authority_callbacks:
                    raise BridgeProtocolError("authority callback limit exceeded")
                self._service_authority_callback(message, response)
                continue
            for key in ("schema", "contractVersion", "requestID", "sessionID",
                        "sessionEpoch", "sequence", "operation"):
                if response.get(key) != message.get(key):
                    raise BridgeProtocolError(f"response {key} correlation mismatch")
            return response

    def _service_authority_callback(self, request, callback):
        _validate_authority_message(callback, "authorityRequest")
        for field in ("requestID", "sessionID", "sessionEpoch", "sequence", "operation"):
            if callback.get(field) != request.get(field):
                raise BridgeProtocolError(f"authority request {field} correlation mismatch")
        if self.authority is None:
            response = {key: callback[key] for key in (
                "schema", "contractVersion", "authorityRequestID", "requestID",
                "sessionID", "sessionEpoch", "sequence", "operation",
                "authorityOperation")}
            response.update({
                "messageType": "authorityResponse",
                "result": {
                    "authorized": False,
                    "reasonCode": "parentAuthorityUnavailable",
                    "reason": "parent supervisor authority was not injected",
                },
            })
        else:
            response = self.authority.handle_authority_request(callback)
        raw = _canonical_json_line(response)
        if len(raw) > DEFAULT_MAX_RECORD_BYTES:
            raise BridgeProtocolError("authority response exceeds byte limit")
        self.process.stdin.write(raw)
        self.process.stdin.flush()

    def close(self):
        if self.closed:
            return {"complete": True, "alreadyClosed": True}
        self.closed = True
        return self.lifecycle.cleanup_bridge(self.registration)


def main():
    if len(sys.argv) != 2 or sys.argv[1] != "--child":
        raise SystemExit("usage: lldb_python_bridge.py --child")
    import lldb  # Imported only after the selected-Xcode PYTHONPATH is installed.
    authority = JSONLParentAuthorityProxy(sys.stdin.buffer, sys.stdout.buffer)
    engine = LLDBPythonBridge(lldb, authority)
    try:
        JSONLBridgeServer(engine, sys.stdin.buffer, sys.stdout.buffer).serve_forever()
    finally:
        engine.close()


if __name__ == "__main__":
    main()
