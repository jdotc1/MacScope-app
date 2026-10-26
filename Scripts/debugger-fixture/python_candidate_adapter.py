#!/usr/bin/env python3
"""Production candidate boundary for the typed LLDB Python JSON bridge.

The child bridge reports LLDB protocol facts.  This adapter owns correlation and
classification, while an injected parent binder remains solely responsible for
turning supervisor observations into frozen validator evidence.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import asdict
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


bridge = _load("lldb_python_bridge")
drivers = _load("candidate_drivers")
schema = _load("ws18_schema")


class PythonCandidateError(RuntimeError):
    pass


_OBSERVATION_MAP = {
    "observed": "observed",
    "unsupported": "unsupported",
    "identityMismatch": "identityMismatch",
    "protocolError": "protocolError",
    "adapterError": "targetError",
}

_REQUIRED_ARGUMENTS = {
    "breakpointCreation": frozenset(("address",)),
    "breakpointDelete": frozenset(("breakpointID",)),
    "breakpointEnable": frozenset(("breakpointID",)),
    "breakpointDisable": frozenset(("breakpointID",)),
    "breakpointCondition": frozenset(("breakpointID", "condition")),
    "breakpointIgnoreCount": frozenset(("breakpointID", "ignoreCount")),
    "breakpointHitCount": frozenset(("breakpointID",)),
    "threadSelection": frozenset(("threadID",)),
    "frameSelection": frozenset(("frameIndex",)),
    "registerWrite": frozenset(("name", "value")),
    "memoryRead": frozenset(("address", "size")),
    "memoryWrite": frozenset(("address", "dataBase64")),
    "expressionEvaluation": frozenset(("expression",)),
}


def exact_attach_identity(target) -> dict[str, object]:
    """Translate the driver namespace without weakening or raw-dict comparing it."""
    if not isinstance(target, drivers.ExactAttachTarget):
        raise TypeError("Python attach requires an ExactAttachTarget")
    return {
        "pid": target.pid,
        "startTimeNS": target.startTimeNS,
        "realUID": target.realUID,
        "effectiveUID": target.effectiveUID,
        "canonicalPath": str(Path(target.canonicalPath).resolve()),
        "cpuType": target.cpuType,
        "cpuSubtype": target.cpuSubtype,
        "executableDevice": target.executableDevice,
        "executableInode": target.executableInode,
        "executableIdentity": target.executableIdentity,
        "machOUUID": target.machOUUID,
        "signingIdentity": target.signingIdentity,
        "nonce": target.nonce,
        "role": target.role,
    }


class PythonCandidateAdapter:
    candidate = "xcode-lldb-python-json"

    def __init__(self, runner, *, lifecycle, authority,
                 evidence_binder: Callable[[str, Mapping[str, object]], Mapping[str, object]],
                 client_factory=None, session_id: str = "ws18-python-json",
                 session_epoch: int = 1) -> None:
        if lifecycle is None or authority is None or evidence_binder is None:
            raise ValueError(
                "Python candidate requires lifecycle, exact parent authority, and evidence binder")
        if not session_id or session_epoch < 1:
            raise ValueError("Python candidate session identity is invalid")
        self.runner = runner
        self.lifecycle = lifecycle
        self.authority = authority
        self.evidence_binder = evidence_binder
        self.client_factory = client_factory or bridge.LLDBPythonBridgeClient
        self.session_id = session_id
        self.session_epoch = session_epoch
        self.client = None
        self.discovery = None
        self.sequence = 0
        self.request_ids: set[str] = set()
        self.mode: Optional[str] = None
        self.target_pid: Optional[int] = None
        self._close_receipt = None
        self._closed = False

    def discover(self):
        if self.discovery is None:
            native = bridge.discover_selected_xcode_lldb(self.runner)
            evidence = dict(native.evidence)
            evidence.update({
                "typedOperationBridge": True,
                "registeredLifecycle": True,
                "exactParentAuthority": True,
                "supervisorEvidenceBinder": True,
            })
            self.discovery = drivers.PythonLLDBDiscovery(
                native.supported,
                native.python_executable or None,
                native.module_path or None,
                native.version or None,
                evidence,
            )
        return self.discovery

    def start(self):
        if self._closed:
            raise PythonCandidateError("Python candidate is closed")
        if self.client is not None:
            return self.client
        discovery = self.discover()
        if not discovery.supported:
            raise PythonCandidateError("selected-Xcode LLDB Python discovery is unsupported")
        native = bridge.LLDBPythonDiscovery(
            True, discovery.pythonPath, discovery.modulePath,
            discovery.version, dict(discovery.evidence))
        self.client = self.client_factory(
            native, self.lifecycle, authority=self.authority)
        initialized = self._request("initialize", "initialize", {})
        if initialized.observation != "observed":
            try:
                self.close()
            finally:
                raise PythonCandidateError("LLDB Python initialize was not observed")
        return self.client

    def launch(self, request_id: str, executable: Path, arguments: Sequence[str],
               cwd: Path, environment: Mapping[str, str]):
        if self.mode is not None:
            return self._negative(request_id, "configuredLaunch", "harnessError",
                                  "candidate session already owns a target")
        self.start()
        evidence = self._request(request_id, "configuredLaunch", {
            "executable": str(executable.resolve()),
            "arguments": list(arguments),
            "workingDirectory": str(cwd.resolve()),
            "environment": dict(environment),
            "stopAtEntry": True,
        })
        if evidence.observation == "observed":
            self.mode, self.target_pid = "launch", evidence.targetPID
        return evidence

    def attach(self, request_id: str, target):
        if self.mode is not None:
            return self._negative(request_id, "attach", "harnessError",
                                  "candidate session already owns a target")
        identity = exact_attach_identity(target)
        self.start()
        evidence = self._request(request_id, "attach", {"identity": identity})
        if evidence.observation == "observed":
            if evidence.targetPID != target.pid:
                return self._negative(request_id, "attach", "identityMismatch",
                                      "bridge attached a different PID", target.pid)
            self.mode, self.target_pid = "attach", evidence.targetPID
        return evidence

    def detach(self, request_id: str):
        if self.mode != "attach" or self.target_pid is None:
            return self._negative(request_id, "detach", "harnessError",
                                  "detach requires one observed exact attach", self.target_pid)
        evidence = self._request(request_id, "detach", {})
        if evidence.observation == "observed":
            self.mode = "detached"
        return evidence

    def exercise_operation(self, request_id: str, operation: str,
                           context: Mapping[str, object]):
        if operation not in schema.OPERATION_ORDER:
            return self._negative(request_id, operation, "protocolError",
                                  "operation is outside the frozen WS-18 matrix")
        if operation in {"configuredLaunch", "attach", "detach"}:
            return self._negative(request_id, operation, "notAttempted",
                                  "operation is owned by its exact lifecycle method",
                                  self.target_pid)
        operation_arguments = context.get("operationArguments", {})
        arguments = operation_arguments.get(operation, {}) if isinstance(
            operation_arguments, Mapping) else {}
        if not isinstance(arguments, Mapping):
            return self._negative(request_id, operation, "protocolError",
                                  "operation arguments must be an object", self.target_pid)
        missing = sorted(_REQUIRED_ARGUMENTS.get(operation, frozenset()) - set(arguments))
        if missing:
            return self._negative(request_id, operation, "notAttempted",
                                  "operation arguments are missing: " + ", ".join(missing),
                                  self.target_pid)
        try:
            self.start()
        except Exception as error:
            return self._negative(request_id, operation, "harnessError",
                                  "Python bridge start failed: " + str(error),
                                  self.target_pid)
        return self._request(request_id, operation, arguments)

    def _request(self, request_id: str, operation: str,
                 arguments: Mapping[str, object], timeout_ms: int = 30_000):
        if self.client is None and operation != "initialize":
            raise PythonCandidateError("Python candidate has not started")
        if not isinstance(request_id, str) or not request_id or request_id in self.request_ids:
            raise PythonCandidateError("request ID must be nonempty and unique")
        self.request_ids.add(request_id)
        self.sequence += 1
        message = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "requestID": request_id,
            "sessionID": self.session_id,
            "sessionEpoch": self.session_epoch,
            "sequence": self.sequence,
            "operation": operation,
            "arguments": dict(arguments),
            "timeoutMS": timeout_ms,
        }
        try:
            response = self.client.request(message)
        except TimeoutError as error:
            return self._negative(request_id, operation, "timedOut", str(error), self.target_pid)
        except bridge.BridgeProtocolError as error:
            return self._negative(request_id, operation, "protocolError", str(error), self.target_pid)
        except Exception as error:
            return self._negative(request_id, operation, "harnessError", str(error), self.target_pid)
        raw_observation = response.get("observation")
        observation = _OBSERVATION_MAP.get(raw_observation, "protocolError")
        result = response.get("result")
        pid = result.get("targetPID") if isinstance(result, Mapping) else None
        pid = pid if isinstance(pid, int) and not isinstance(pid, bool) and pid > 0 else self.target_pid
        protocol = {
            "schema": response.get("schema"),
            "contractVersion": response.get("contractVersion"),
            "requestID": response.get("requestID"),
            "sessionID": response.get("sessionID"),
            "sessionEpoch": response.get("sessionEpoch"),
            "sequence": response.get("sequence"),
            "operation": response.get("operation"),
            "lifecycleRevision": response.get("lifecycleRevision"),
            "stopRevision": response.get("stopRevision"),
            "ownership": response.get("ownership"),
            "targetDisposition": response.get("targetDisposition"),
            "result": dict(result) if isinstance(result, Mapping) else {},
            "evidence": dict(response.get("evidence", {})) if isinstance(
                response.get("evidence"), Mapping) else {},
        }
        if observation != "observed" and operation == "configuredLaunch":
            accept_abort = getattr(
                self.lifecycle, "accept_unpublished_launch_abort", None)
            if callable(accept_abort):
                try:
                    accept_abort(protocol)
                except Exception as error:
                    return self._negative(
                        request_id, operation, "harnessError",
                        "unpublished launch cleanup authority rejected proof: "
                        + str(error), pid)
        if observation == "observed" and operation == "initialize":
            # Initialize creates only bridge-local state.  It is deliberately
            # not promoted into the frozen target-operation evidence contract.
            proof = {"protocolResponse": protocol}
            negative = None
        elif observation == "observed":
            try:
                bound = self.evidence_binder(operation, protocol)
            except Exception as error:
                return self._negative(request_id, operation, "harnessError",
                                      "supervisor evidence binding failed: " + str(error), pid)
            if not isinstance(bound, Mapping) or not isinstance(
                    bound.get("validatorEvidence"), Mapping):
                return self._negative(request_id, operation, "harnessError",
                                      "supervisor did not return frozen validator evidence", pid)
            proof = {"protocolResponse": protocol, **dict(bound)}
            negative = None
        else:
            proof = {"protocolResponse": protocol}
            diagnostic = response.get("diagnostic")
            reason = diagnostic.get("reason") if isinstance(diagnostic, Mapping) else None
            negative = asdict(drivers.NegativeEvidence.from_text(
                observation, operation, str(reason or raw_observation or "invalid bridge response")))
        return drivers.CandidateOperationEvidence(
            self.candidate, operation, observation, request_id, pid,
            str(response.get("targetDisposition", "targetDispositionUnknown")),
            proof, negative)

    def _negative(self, request_id: str, operation: str, classification: str,
                  reason: str, pid: Optional[int] = None):
        negative = asdict(drivers.NegativeEvidence.from_text(
            classification, operation, reason))
        return drivers.CandidateOperationEvidence(
            self.candidate, operation, classification, request_id, pid,
            "targetDispositionUnknown", {}, negative)

    def close(self):
        if self._close_receipt is not None:
            return self._close_receipt
        self._closed = True
        if self.client is None:
            self._close_receipt = {"role": "adapter", "complete": True,
                                   "notStarted": True}
            return self._close_receipt
        receipt = self.client.close()
        self.client = None
        if not isinstance(receipt, Mapping) or receipt.get("role") != "adapter" or receipt.get("complete") is not True:
            raise PythonCandidateError(
                "Python adapter cleanup receipt is missing, mismatched, or incomplete")
        self._close_receipt = dict(receipt)
        return self._close_receipt
