#!/usr/bin/env python3
"""Fail-closed semantic validator for the canonical WS-18 aggregate report."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, List, Mapping, Optional, Sequence


_HERE = Path(__file__).resolve().parent
_SCHEMA_PATH = _HERE / "ws18_schema.py"
_SPEC = importlib.util.spec_from_file_location("ws18_schema", _SCHEMA_PATH)
if _SPEC is None or _SPEC.loader is None:  # pragma: no cover - installation failure
    raise RuntimeError("unable to load ws18_schema.py")
schema = importlib.util.module_from_spec(_SPEC)
sys.modules.setdefault(_SPEC.name, schema)
_SPEC.loader.exec_module(schema)


OBSERVED = "observed"
EXPECTED_MODES = {
    "xcode-lldb-dap": ("launch", "attach"),
    "xcode-lldb-python-json": ("launch", "attach"),
    "macscope-lldb-cli-baseline": ("launch", "attach"),
}
TYPED_CANDIDATES = (
    "xcode-lldb-dap",
    "xcode-lldb-python-json",
)
HARD_OPERATIONS = (
    "configuredLaunch",
    "attach",
    "detach",
    "pause",
    "continue",
    "breakpointCreation",
    "breakpointHit",
    "breakpointDelete",
    "breakpointHitCount",
    "stepInto",
    "stepOver",
    "stepOut",
    "threadList",
    "threadSelection",
    "frameList",
    "frameSelection",
    "registerRead",
    "memoryRead",
    "expressionEvaluation",
    "moduleList",
    "moduleLoad",
    "moduleUnload",
    "cancelBeforeSpawn",
    "cancelInFlight",
    "timeoutRecovery",
    "adapterCrashRecovery",
)
STOP_BOUND_OPERATIONS = {
    "threadSelection",
    "frameSelection",
    "registerRead",
    "registerWrite",
    "memoryRead",
    "memoryWrite",
    "expressionEvaluation",
}
RUN_KEYS = frozenset({
    "schemaVersion", "candidate", "candidateVersion", "sessionID", "sessionEpoch",
    "lifecycleRevision", "stopRevision", "requestID", "mode", "outcome", "ownership",
    "targetDisposition", "expectedIdentity", "observedIdentity", "capabilities", "operations",
    "processRegistry", "cleanupReceipts", "residueAudit", "diagnostics", "metadata", "rawBindings",
})
OUTCOME_KEYS = frozenset({"state", "evidence"})
OPERATION_KEYS = frozenset({"name", "advertisement", "observation", "evidence", "stopRevision"})
CAPABILITY_KEYS = frozenset({"name", "advertisement", "observation", "evidence"})
REGISTRY_KEYS = frozenset({"role", "identity"})
CLEANUP_KEYS = frozenset({
    "role", "expectedIdentity", "observedIdentity", "revalidated", "action",
    "terminalState", "complete", "detail", "ownershipEvidence",
})
RESIDUE_KEYS = frozenset({"auditedIdentities", "remainingIdentities", "complete", "evidence"})
VALID_OUTCOMES = frozenset({
    "observed", "notAttempted", "unsupported", "policyDenied", "timedOut", "cancelled",
    "targetError", "protocolError", "identityMismatch", "harnessError", "notApplicable",
})
VALID_ADVERTISEMENTS = frozenset({"advertised", "notAdvertised", "unknown", "notApplicable"})
VALID_ROLES = frozenset({"adapter", "target", "helper", "debugserver"})
VALID_CLEANUP_ACTIONS = frozenset({"gracefulExit", "fixtureExit", "terminate", "alreadyExited"})
VALID_TERMINAL_STATES = frozenset({"exited", "gone"})
STEP_OPERATIONS = frozenset({"stepInto", "stepOver", "stepOut"})
MODULE_OPERATIONS = frozenset({"moduleList", "moduleLoad", "moduleUnload"})
CORRELATED_EVIDENCE_KEYS = frozenset({"request", "event", "postcondition"})
REQUEST_EVIDENCE_KEYS = frozenset({
    "id", "runID", "sessionID", "sessionEpoch", "lifecycleRevision", "stopRevision",
})
EVENT_EVIDENCE_KEYS = frozenset({
    "sequence", "sessionID", "sessionEpoch", "lifecycleRevision", "stopRevision", "name",
})
POSTCONDITION_KEYS = frozenset({"operation", "satisfied", "detail", "identity"})
VALIDATOR_KEYS = frozenset({"name", "contractVersion", "canonicalDigest"})
RAW_BINDING_KEYS = frozenset({"targetPID", "targetPath", "targetNonce", "requestLedger"})
LEDGER_KEYS = frozenset({
    "requestID", "runID", "sessionID", "sessionEpoch", "lifecycleRevision",
    "command", "responseEventSequence", "outcome",
})


@dataclass(frozen=True)
class ValidationIssue:
    code: str
    message: str


@dataclass
class ValidationResult:
    structural_issues: List[ValidationIssue] = field(default_factory=list)
    gate_issues: List[ValidationIssue] = field(default_factory=list)

    @property
    def issues(self) -> List[ValidationIssue]:
        return self.structural_issues + self.gate_issues

    @property
    def structurally_valid(self) -> bool:
        return not self.structural_issues

    @property
    def gates_satisfied(self) -> bool:
        return self.structurally_valid and not self.gate_issues

    @property
    def ok(self) -> bool:
        return self.gates_satisfied


def validate_report(
    aggregate: object,
    *,
    require_launch: bool = False,
    require_attach: bool = False,
    require_typed_selection_candidate: bool = False,
    require_cli_baseline: bool = False,
) -> ValidationResult:
    """Validate schema first, then independently derive requested hard gates."""
    result = ValidationResult()

    try:
        schema.validate_aggregate(aggregate)
    except schema.SchemaError as error:
        result.structural_issues.append(
            ValidationIssue("invalidAggregateSchema", str(error))
        )
        return result

    assert isinstance(aggregate, Mapping)
    candidates = aggregate["candidates"]
    assert isinstance(candidates, list)

    def structural(code: str, message: str) -> None:
        result.structural_issues.append(ValidationIssue(code, message))

    def gate(code: str, message: str) -> None:
        result.gate_issues.append(ValidationIssue(code, message))

    actual_candidates = tuple(item["candidate"] for item in candidates)
    if actual_candidates != tuple(schema.CANDIDATE_ORDER):
        structural("candidateOrderMismatch", "candidates must exactly match frozen order")

    toolchain = aggregate["toolchain"]
    fixture = aggregate["fixture"]
    toolchain_binding = _binding(toolchain)
    fixture_binding = _binding(fixture)
    if not toolchain_binding:
        structural("invalidToolchainBinding", "toolchain requires a nonempty stable binding")
    if not fixture_binding:
        structural("invalidFixtureBinding", "fixture requires a nonempty stable binding")
    fixture_processes, fixture_modules = _fixture_contract(fixture, structural)

    validator_envelope = aggregate["validator"]
    if set(validator_envelope) != VALIDATOR_KEYS:
        structural("invalidValidatorEnvelope", "validator keys differ from frozen contract")
    else:
        digest = validator_envelope["canonicalDigest"]
        if (
            validator_envelope["name"] != "validate_ws18.py"
            or validator_envelope["contractVersion"] != 1
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
            or not schema.validator_digest_matches(aggregate)
        ):
            structural("invalidValidatorDigest", "validator identity or canonical digest is invalid")

    run_index: dict[tuple[str, str], Mapping[str, object]] = {}
    for candidate in candidates:
        candidate_id = candidate["candidate"]
        candidate_version = candidate["candidateVersion"]
        discovery = candidate["discovery"]
        if set(discovery) != {"state", "evidence", "toolchainBinding"}:
            structural("invalidDiscovery", f"{candidate_id} discovery keys differ from schema")
        elif (
            not _is_enum(discovery["state"], {OBSERVED, "structurallyUnsupported"})
            or not isinstance(discovery["evidence"], str)
            or not discovery["evidence"]
            or discovery["toolchainBinding"] != toolchain_binding
        ):
            structural("invalidDiscovery", f"{candidate_id} discovery evidence is invalid")
        runs = candidate["runs"]
        modes = tuple(run.get("mode") if isinstance(run, Mapping) else None for run in runs)
        if modes != EXPECTED_MODES[candidate_id]:
            structural(
                "modeOrderMismatch",
                f"{candidate_id} modes {modes!r} do not match {EXPECTED_MODES[candidate_id]!r}",
            )
        for run in runs:
            mode = run.get("mode") if isinstance(run, Mapping) else None
            prefix = f"{candidate_id}/{mode if isinstance(mode, str) else '<invalid>'}"
            if not isinstance(run, Mapping):
                structural("invalidRun", f"{prefix} must be an object")
                continue
            if run.get("candidateVersion") != candidate_version:
                structural("candidateVersionMismatch", f"{prefix} differs from candidate envelope")
            _validate_run(
                run,
                prefix,
                toolchain_binding,
                fixture_binding,
                fixture_processes,
                fixture_modules,
                structural,
            )
            if isinstance(mode, str):
                run_index[(candidate_id, mode)] = run

        if candidate_id in {"xcode-lldb-dap", "macscope-lldb-cli-baseline"}:
            for run in runs:
                if not isinstance(run, Mapping) or _state(run) == "notAttempted":
                    structural(
                        "mandatoryCandidateNotAttempted",
                        f"{candidate_id} must produce typed attempted evidence for every mode",
                    )
        if discovery.get("state") == "structurallyUnsupported":
            if candidate_id != "xcode-lldb-python-json":
                structural("invalidUnsupportedDiscovery", f"{candidate_id} cannot be structurally unsupported")
            for run in runs:
                if isinstance(run, Mapping) and _state(run) not in {"unsupported", "notApplicable"}:
                    structural(
                        "contradictoryUnsupportedCandidate",
                        "Python structurallyUnsupported discovery contradicts executed run evidence",
                    )

    # Gates are intentionally separate from structural validity. A valid record of a
    # denial/timeout remains valid evidence, but cannot satisfy a requested release gate.
    if require_launch:
        _require_observed(run_index, "xcode-lldb-dap", "launch", gate)
        _require_observed(run_index, "macscope-lldb-cli-baseline", "launch", gate)
    if require_attach:
        for candidate in ("xcode-lldb-dap", "macscope-lldb-cli-baseline"):
            run = _require_observed(run_index, candidate, "attach", gate)
            if run is not None:
                _require_detach_proof(run, candidate, gate)
    if require_cli_baseline:
        for mode in ("launch", "attach"):
            run = _require_observed(
                run_index, "macscope-lldb-cli-baseline", mode, gate,
                code="cliBaselineNotObserved",
            )
            if mode == "attach" and run is not None:
                _require_detach_proof(run, "macscope-lldb-cli-baseline", gate)
    if require_typed_selection_candidate:
        def qualifies(candidate_id: str) -> bool:
            launch = run_index.get((candidate_id, "launch"))
            attach = run_index.get((candidate_id, "attach"))
            return (
                _observed(launch)
                and _observed(attach)
                and _candidate_hard_gate_complete((launch, attach), fixture_modules)
                and _detach_proven(attach)
            )

        if not any(qualifies(candidate_id) for candidate_id in TYPED_CANDIDATES):
            gate(
                "typedSelectionCandidateUnavailable",
                "no typed candidate proves launch, attach/detach, and the complete hard gate",
            )

    return result


def validate_reports(reports: object, **requirements: bool) -> ValidationResult:
    """Compatibility spelling; WS-18 now accepts exactly one aggregate, never loose reports."""
    return validate_report(reports, **requirements)


def _binding(value: object) -> str:
    if not isinstance(value, Mapping):
        return ""
    for key in ("binding", "sha256", "digest", "identity"):
        candidate = value.get(key)
        if isinstance(candidate, str) and candidate:
            return candidate
    return ""


def _fixture_contract(
    fixture: object, add: Callable[[str, str], None]
) -> tuple[dict[str, Mapping[str, object]], list[Mapping[str, object]]]:
    if not isinstance(fixture, Mapping) or set(fixture) != {
        "binding", "processIdentities", "moduleIdentities"
    }:
        add("invalidFixtureContract", "fixture keys differ from semantic contract")
        return {}, []
    processes = fixture["processIdentities"]
    modules = fixture["moduleIdentities"]
    if not isinstance(processes, Mapping) or set(processes) != {"target", "helper"}:
        add("invalidFixtureContract", "fixture requires exact target/helper identities")
        processes = {}
    else:
        for role, value in processes.items():
            if not _complete_fixture_identity(value, role):
                add("invalidFixtureContract", f"fixture {role} identity is invalid")
    if not isinstance(modules, list) or not modules or any(
        not _complete_module_identity(value) for value in modules
    ):
        add("invalidFixtureContract", "fixture module identities are invalid")
        modules = []
    return dict(processes), list(modules)


def _complete_fixture_identity(value: object, role: object) -> bool:
    keys = {
        "canonicalPath", "cpuType", "cpuSubtype", "executableIdentity",
        "device", "inode", "machOUUID", "role",
    }
    return (
        isinstance(value, Mapping)
        and set(value) == keys
        and value["role"] == role
        and isinstance(value["canonicalPath"], str)
        and os.path.isabs(value["canonicalPath"])
        and value["cpuType"] == 0x0100000C
        and isinstance(value["cpuSubtype"], int)
        and not isinstance(value["cpuSubtype"], bool)
        and value["cpuSubtype"] >= 0
        and isinstance(value["executableIdentity"], str)
        and bool(value["executableIdentity"])
        and isinstance(value["device"], int)
        and not isinstance(value["device"], bool)
        and value["device"] > 0
        and isinstance(value["inode"], int)
        and not isinstance(value["inode"], bool)
        and value["inode"] > 0
        and isinstance(value["machOUUID"], str)
        and re.fullmatch(
            r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
            value["machOUUID"],
        ) is not None
    )


def _fixture_identity_projection(value: Mapping[str, object]) -> dict[str, object]:
    return {
        key: value[key]
        for key in (
            "canonicalPath", "cpuType", "cpuSubtype", "executableIdentity",
            "device", "inode", "machOUUID", "role",
        )
    }


def _validate_run(
    run: Mapping[str, object],
    prefix: str,
    toolchain_binding: str,
    fixture_binding: str,
    fixture_processes: Mapping[str, Mapping[str, object]],
    fixture_modules: Sequence[Mapping[str, object]],
    add: Callable[[str, str], None],
) -> None:
    if set(run) != RUN_KEYS:
        add("invalidRunKeys", f"{prefix} run keys differ from the frozen schema")
        return
    if "pass" in run or "eligible" in run or "viable" in run:
        add("candidateAuthoredVerdict", f"{prefix} contains a candidate-authored verdict")

    scalar_types = {
        "schemaVersion": int, "candidate": str, "candidateVersion": str,
        "sessionID": str, "sessionEpoch": int, "lifecycleRevision": int,
        "stopRevision": int, "requestID": str, "mode": str, "ownership": str,
        "targetDisposition": str,
    }
    for key, expected_type in scalar_types.items():
        value = run[key]
        if not isinstance(value, expected_type) or isinstance(value, bool) or (
            expected_type is str and not value
        ):
            add("invalidRunType", f"{prefix}.{key} has the wrong type/value")
    if run["schemaVersion"] != 1:
        add("invalidRunVersion", f"{prefix} must use run schemaVersion 1")
    revisions = (run["sessionEpoch"], run["lifecycleRevision"], run["stopRevision"])
    if all(isinstance(value, int) and not isinstance(value, bool) for value in revisions) and (
        run["sessionEpoch"] < 1 or run["lifecycleRevision"] < 1 or run["stopRevision"] < 0
    ):
        add("invalidRevision", f"{prefix} revisions are outside valid domains")
    if run["candidate"] != prefix.split("/", 1)[0]:
        add("candidateBindingMismatch", f"{prefix} run candidate differs from envelope")
    if not isinstance(run["metadata"], Mapping) or not isinstance(run["rawBindings"], Mapping):
        add("invalidRunType", f"{prefix} metadata/rawBindings must be objects")
        return
    for key in ("capabilities", "operations", "processRegistry", "cleanupReceipts", "diagnostics"):
        if not isinstance(run[key], list):
            add("invalidRunType", f"{prefix}.{key} must be an array")
            return
    metadata = run["metadata"]
    bindings = run["rawBindings"]
    ledger_by_request: dict[str, Mapping[str, object]] = {}
    if set(bindings) != RAW_BINDING_KEYS or not isinstance(bindings.get("requestLedger"), list):
        add("invalidRawBindings", f"{prefix} raw bindings differ from schema")
    else:
        for ledger_row in bindings["requestLedger"]:
            if not isinstance(ledger_row, Mapping) or set(ledger_row) != LEDGER_KEYS:
                add("invalidRequestLedger", f"{prefix} has malformed request ledger evidence")
                continue
            request_id = ledger_row["requestID"]
            if not isinstance(request_id, str) or not request_id or request_id in ledger_by_request:
                add("invalidRequestLedger", f"{prefix} has invalid/duplicate ledger request ID")
                continue
            ledger_by_request[request_id] = ledger_row
    if not _is_enum(run["ownership"], {"launched", "attachedTestFixture"}):
        add("invalidOwnership", f"{prefix} has invalid ownership")
    expected_ownership = "launched" if run["mode"] == "launch" else "attachedTestFixture"
    if run["ownership"] != expected_ownership:
        add("invalidOwnership", f"{prefix} ownership disagrees with mode")
    if metadata.get("toolchainBinding") != toolchain_binding:
        add("toolchainBindingMismatch", f"{prefix} is not bound to aggregate toolchain")
    if metadata.get("fixtureBinding") != fixture_binding:
        add("fixtureBindingMismatch", f"{prefix} is not bound to aggregate fixture")

    expected = run.get("expectedIdentity")
    observed = run.get("observedIdentity")
    outcome = run["outcome"]
    if not isinstance(outcome, Mapping) or set(outcome) != OUTCOME_KEYS:
        add("invalidOutcome", f"{prefix} outcome keys differ from schema")
        state = None
    else:
        state = outcome["state"]
        if (
            not _is_enum(state, VALID_OUTCOMES)
            or not isinstance(outcome["evidence"], str)
            or not outcome["evidence"].strip()
        ):
            add("invalidOutcome", f"{prefix} has invalid outcome evidence")
    if run["mode"] in {"launch", "attach"}:
        if not _complete_identity(expected):
            add("incompleteExpectedIdentity", f"{prefix} lacks complete expected identity")
        if state == OBSERVED and not _complete_identity(observed):
            add("incompleteObservedIdentity", f"{prefix} lacks complete observed identity")
        if state == OBSERVED and expected != observed:
            add("identityMismatch", f"{prefix} observed the wrong immutable identity")
        expected_role = "target" if run["mode"] == "launch" else "helper"
        if (
            _complete_identity(expected)
            and isinstance(expected, Mapping)
            and fixture_processes.get(expected_role) != _fixture_identity_projection(expected)
        ):
            add("fixtureIdentityMismatch", f"{prefix} debuggee is not the verified fixture identity")
        if isinstance(expected, Mapping) and (
            bindings.get("targetPID"),
            bindings.get("targetPath"),
            bindings.get("targetNonce"),
        ) != (
            expected.get("pid"),
            expected.get("canonicalPath"),
            expected.get("nonce"),
        ):
            add("rawBindingMismatch", f"{prefix} raw identity binding differs")
        if state == OBSERVED:
            valid_dispositions = {"exited", "terminated"} if run["mode"] == "launch" else {"detached"}
            if not _is_enum(run["targetDisposition"], valid_dispositions):
                add("invalidTargetDisposition", f"{prefix} has an impossible observed disposition")

    if state == OBSERVED and metadata.get("adapterStartedInNewSession") is not True:
        add("adapterIsolationFailure", f"{prefix} adapter was not session-isolated")
    if run["mode"] == "attach" and state == OBSERVED:
        if metadata.get("helperStartedInNewSession") is not True:
            add("helperIsolationFailure", f"{prefix} helper was not session-isolated")
        if metadata.get("adapterHelperSessionsDistinct") is not True:
            add("sessionIsolationFailure", f"{prefix} adapter/helper sessions are not distinct")
        if metadata.get("pidEvidenceSource") != "adapter":
            add("pidFallbackForbidden", f"{prefix} did not obtain PID from the adapter")
    if metadata.get("hybrid") is True and (
        metadata.get("consoleSessionID") != run["sessionID"]
        or metadata.get("adapterProcessCount") != 1
    ):
        add("invalidHybridSession", f"{prefix} hybrid path is not same-session")

    capabilities = run["capabilities"]
    seen_capabilities: set[str] = set()
    for capability in capabilities:
        if not isinstance(capability, Mapping) or set(capability) != CAPABILITY_KEYS:
            add("invalidCapability", f"{prefix} has malformed capability evidence")
            continue
        name = capability["name"]
        if not isinstance(name, str) or not name or name in seen_capabilities:
            add("invalidCapability", f"{prefix} has invalid/duplicate capability name")
        elif not _is_enum(capability["advertisement"], VALID_ADVERTISEMENTS):
            add("invalidCapability", f"{prefix}/{name} has invalid advertisement")
        elif not _is_enum(capability["observation"], VALID_OUTCOMES):
            add("invalidCapability", f"{prefix}/{name} has invalid observation")
        elif not _row_has_evidence(capability["evidence"]):
            add("invalidCapability", f"{prefix}/{name} lacks evidence")
        seen_capabilities.add(name) if isinstance(name, str) else None

    if not all(isinstance(item, str) for item in run["diagnostics"]):
        add("invalidDiagnostics", f"{prefix} diagnostics must contain raw strings")

    operations = run["operations"]
    request_ids: set[str] = set()
    last_event_sequence = 0
    launch_fact_sequence: Optional[int] = None
    terminal_fact: Optional[tuple[int, str, int]] = None
    for operation in operations:
        if not isinstance(operation, Mapping) or set(operation) != OPERATION_KEYS:
            add("invalidOperationEvidence", f"{prefix} has malformed operation row")
            continue
        name = operation["name"]
        if not _is_enum(operation["advertisement"], VALID_ADVERTISEMENTS):
            add("invalidAdvertisement", f"{prefix}/{name} has invalid advertisement")
        if not _is_enum(operation["observation"], VALID_OUTCOMES):
            add("invalidObservation", f"{prefix}/{name} has invalid observation")
        evidence = operation["evidence"]
        if operation["observation"] == OBSERVED and not _correlated_evidence(
            evidence, run, name, fixture_modules
        ):
            add("missingOperationProof", f"{prefix}/{name} has no correlated proof")
        elif operation["observation"] == OBSERVED and isinstance(evidence, Mapping):
            request = evidence.get("request")
            event = evidence.get("event")
            if isinstance(request, Mapping) and isinstance(request.get("id"), str):
                request_id = request["id"]
                if request_id in request_ids:
                    add("duplicateOperationRequest", f"{prefix}/{name} reuses a request ID")
                request_ids.add(request_id)
                ledger = ledger_by_request.get(request_id)
                event = evidence.get("event")
                if not (
                    isinstance(ledger, Mapping)
                    and ledger["runID"] == run["requestID"]
                    and ledger["sessionID"] == run["sessionID"]
                    and ledger["sessionEpoch"] == run["sessionEpoch"]
                    and ledger["lifecycleRevision"] == run["lifecycleRevision"]
                    and ledger["command"] == name
                    and isinstance(event, Mapping)
                    and ledger["responseEventSequence"] == event.get("sequence")
                    and ledger["outcome"] == OBSERVED
                ):
                    add("requestLedgerMismatch", f"{prefix}/{name} proof is absent from raw ledger")
            if isinstance(event, Mapping) and isinstance(event.get("sequence"), int):
                sequence = event["sequence"]
                shared_launch_fact = _shared_launch_semantic_fact(
                    evidence, name, sequence,
                )
                if name == "configuredLaunch" and shared_launch_fact:
                    launch_fact_sequence = sequence
                shared_terminal_fact, parsed_terminal_fact = _shared_terminal_semantic_fact(
                    evidence, name, sequence, terminal_fact,
                )
                if name == "terminate" and parsed_terminal_fact is not None:
                    terminal_fact = parsed_terminal_fact
                if sequence <= last_event_sequence and not (
                    sequence == launch_fact_sequence and shared_launch_fact
                ) and not (
                    sequence == last_event_sequence and shared_terminal_fact
                ):
                    add("nonMonotonicEventSequence", f"{prefix}/{name} event sequence is not increasing")
                last_event_sequence = sequence
        elif operation["observation"] != OBSERVED and not _row_has_evidence(evidence):
            add("missingOperationEvidence", f"{prefix}/{name} has no typed negative evidence")
        if name in STOP_BOUND_OPERATIONS and operation["observation"] == OBSERVED:
            if operation.get("stopRevision") != run["stopRevision"]:
                add("staleStopRevision", f"{prefix}/{name} is bound to a stale stop")

    _validate_registry_cleanup(run, prefix, add)


def _shared_launch_semantic_fact(
    evidence: Mapping[str, object], operation: object, sequence: int,
) -> bool:
    components = {
        "configuredLaunch": "configuredLaunch",
        "launchArguments": "args",
        "launchEnvironment": "env",
        "launchWorkingDirectory": "cwd",
    }
    component = components.get(operation)
    postcondition = evidence.get("postcondition")
    detail = postcondition.get("detail") if isinstance(postcondition, Mapping) else None
    if component is None or not isinstance(detail, str):
        return False
    try:
        value = json.loads(detail)
    except (TypeError, ValueError, json.JSONDecodeError):
        return False
    return (
        isinstance(value, Mapping)
        and set(value) == {"semanticFactID", "postcondition"}
        and value.get("semanticFactID") == f"launch:{sequence}:{component}"
        and isinstance(value.get("postcondition"), Mapping)
        and bool(value["postcondition"])
    )


def _shared_terminal_semantic_fact(
    evidence: Mapping[str, object], operation: object, sequence: int,
    prior: Optional[tuple[int, str, int]],
) -> tuple[bool, Optional[tuple[int, str, int]]]:
    """Recognize the two exact semantic projections of one DAP disconnect."""
    if operation not in {"terminate", "expectedExit"}:
        return False, None
    postcondition = evidence.get("postcondition")
    detail = postcondition.get("detail") if isinstance(postcondition, Mapping) else None
    if not isinstance(detail, str):
        return False, None
    try:
        value = json.loads(detail)
    except (TypeError, ValueError, json.JSONDecodeError):
        return False, None
    semantic = value.get("postcondition") if isinstance(value, Mapping) else None
    if (
        not isinstance(value, Mapping)
        or set(value) != {"semanticFactID", "postcondition"}
        or value.get("semanticFactID") != f"disconnect:{sequence}:{operation}"
        or not isinstance(semantic, Mapping)
        or set(semantic) != {"event", "eventSequence"}
        or not isinstance(semantic.get("event"), str)
        or not semantic["event"]
        or not isinstance(semantic.get("eventSequence"), int)
        or isinstance(semantic["eventSequence"], bool)
        or semantic["eventSequence"] <= 0
    ):
        return False, None
    fact = (sequence, semantic["event"], semantic["eventSequence"])
    if operation == "terminate":
        return False, fact
    return prior == fact, None


def _complete_identity(value: object) -> bool:
    if not isinstance(value, Mapping):
        return False
    exact_keys = {
        "pid", "startTimeNS", "realUID", "effectiveUID", "canonicalPath",
        "cpuType", "cpuSubtype", "executableIdentity", "nonce", "role",
        "device", "inode", "machOUUID",
    }
    if set(value) != exact_keys:
        return False
    integer_keys = ("pid", "startTimeNS", "realUID", "effectiveUID", "cpuType", "cpuSubtype", "device", "inode")
    if any(not isinstance(value[key], int) or isinstance(value[key], bool) for key in integer_keys):
        return False
    return (
        value["pid"] > 0
        and value["startTimeNS"] > 0
        and value["realUID"] >= 0
        and value["effectiveUID"] >= 0
        and value["cpuType"] == 0x0100000C
        and value["cpuSubtype"] >= 0
        and value["device"] > 0
        and value["inode"] > 0
        and isinstance(value["canonicalPath"], str)
        and os.path.isabs(value["canonicalPath"])
        and os.path.realpath(value["canonicalPath"]) == value["canonicalPath"]
        and isinstance(value["executableIdentity"], str)
        and bool(value["executableIdentity"])
        and isinstance(value["nonce"], str)
        and bool(value["nonce"])
        and _is_enum(value["role"], VALID_ROLES)
        and isinstance(value["machOUUID"], str)
        and re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", value["machOUUID"]) is not None
    )


def _correlated_evidence(
    value: object,
    run: Mapping[str, object],
    operation: str,
    fixture_modules: Sequence[Mapping[str, object]],
) -> bool:
    if not isinstance(value, Mapping) or set(value) != CORRELATED_EVIDENCE_KEYS:
        return False
    request = value.get("request")
    event = value.get("event")
    postcondition = value.get("postcondition")
    if (
        not isinstance(request, Mapping)
        or set(request) != REQUEST_EVIDENCE_KEYS
        or not isinstance(event, Mapping)
        or set(event) != EVENT_EVIDENCE_KEYS
        or not isinstance(postcondition, Mapping)
        or set(postcondition) != POSTCONDITION_KEYS
    ):
        return False
    if not (
        isinstance(request["id"], str)
        and bool(request["id"])
        and request["runID"] == run.get("requestID")
        and request["sessionID"] == run.get("sessionID")
        and request["sessionEpoch"] == run.get("sessionEpoch")
        and request["lifecycleRevision"] == run.get("lifecycleRevision")
        and isinstance(request["stopRevision"], int)
        and not isinstance(request["stopRevision"], bool)
        and request["stopRevision"] >= 0
        and event["sessionID"] == run.get("sessionID")
        and event["sessionEpoch"] == run.get("sessionEpoch")
        and event["lifecycleRevision"] == run.get("lifecycleRevision")
        and event["stopRevision"] == run.get("stopRevision")
        and isinstance(event["sequence"], int)
        and not isinstance(event["sequence"], bool)
        and event["sequence"] > 0
        and event["name"] == operation
        and postcondition["operation"] == operation
        and postcondition["satisfied"] is True
        and isinstance(postcondition["detail"], str)
        and bool(postcondition["detail"].strip())
    ):
        return False
    if operation in STEP_OPERATIONS and event["stopRevision"] <= request["stopRevision"]:
        return False
    if operation in MODULE_OPERATIONS and (
        not _complete_module_identity(postcondition["identity"])
        or postcondition["identity"] not in fixture_modules
    ):
        return False
    return True


def _complete_module_identity(value: object) -> bool:
    return (
        isinstance(value, Mapping)
        and set(value) == {"path", "machOUUID"}
        and isinstance(value["path"], str)
        and os.path.isabs(value["path"])
        and isinstance(value["machOUUID"], str)
        and re.fullmatch(
            r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}",
            value["machOUUID"],
        ) is not None
    )


def _validate_registry_cleanup(
    run: Mapping[str, object], prefix: str, add: Callable[[str, str], None]
) -> None:
    registry = run["processRegistry"]
    receipts = run["cleanupReceipts"]
    residue = run["residueAudit"]
    if not isinstance(registry, list):
        add("invalidRegistry", f"{prefix} processRegistry must be an array")
        return
    if not isinstance(receipts, list):
        add("invalidCleanupReceipt", f"{prefix} cleanupReceipts must be an array")
        return
    if not isinstance(residue, Mapping):
        add("invalidResidueAudit", f"{prefix} residueAudit must be an object")
        return
    if _state(run) == OBSERVED and (not registry or not receipts):
        add("emptyProcessProof", f"{prefix} observed run has no process cleanup proof")

    registered: dict[str, Mapping[str, object]] = {}
    registered_pids: set[int] = set()
    for entry in registry:
        if not isinstance(entry, Mapping) or set(entry) != REGISTRY_KEYS:
            add("invalidRegistryEntry", f"{prefix} has malformed registry entry")
            continue
        role = entry["role"]
        identity = entry["identity"]
        if not isinstance(role, str) or not role:
            add("invalidRegistryEntry", f"{prefix} has invalid registry role")
            continue
        if role in registered:
            add("duplicateRegisteredRole", f"{prefix} repeats registry role {role}")
        if not _is_enum(role, VALID_ROLES) or not _complete_identity(identity) or identity.get("role") != role:
            add("invalidRegisteredIdentity", f"{prefix} registry identity is incomplete for {role}")
            continue
        pid = identity["pid"]
        if pid in registered_pids:
            add("duplicateRegisteredPID", f"{prefix} reuses PID across process roles")
        registered_pids.add(pid)
        registered[role] = identity

    if _state(run) == OBSERVED:
        required_roles = {"adapter", "target"} if run.get("mode") == "launch" else {"adapter", "helper"}
        if not required_roles.issubset(registered):
            add("missingMandatoryProcessRole", f"{prefix} lacks adapter/debuggee registry identities")
        debuggee_role = "target" if run.get("mode") == "launch" else "helper"
        if registered.get(debuggee_role) != run.get("expectedIdentity"):
            add("registryIdentityMismatch", f"{prefix} registry debuggee differs from run identity")

    receipt_roles: set[str] = set()
    receipt_counts: dict[str, int] = {}
    for receipt in receipts:
        if not isinstance(receipt, Mapping) or set(receipt) != CLEANUP_KEYS:
            add("invalidCleanupReceipt", f"{prefix} has malformed cleanup receipt")
            continue
        role = receipt["role"]
        if not isinstance(role, str) or role not in VALID_ROLES:
            add("invalidCleanupReceipt", f"{prefix} cleanup role is invalid")
            continue
        receipt_roles.add(role)
        receipt_counts[role] = receipt_counts.get(role, 0) + 1
        expected = registered.get(role)
        if expected is None or receipt["expectedIdentity"] != expected:
            add("cleanupIdentityMismatch", f"{prefix} cleanup is not registry-bound for {role}")
        correlated_lifecycle_completion = _correlated_lifecycle_proves_gone(
            run, receipt, registered,
        )
        if ((receipt["revalidated"] is not True and not correlated_lifecycle_completion)
                or receipt["complete"] is not True):
            add("incompleteCleanup", f"{prefix} cleanup is incomplete for {role}")
        observed = receipt["observedIdentity"]
        if not _complete_identity(observed) or observed != expected:
            add("cleanupIdentityMismatch", f"{prefix} cleanup observed another {role}")
        action = receipt["action"]
        terminal = receipt["terminalState"]
        if (
            not _is_enum(action, VALID_CLEANUP_ACTIONS)
            or not _is_enum(terminal, VALID_TERMINAL_STATES)
            or not isinstance(receipt["detail"], str)
            or not receipt["detail"].strip()
        ):
            add("unsafeCleanupReceipt", f"{prefix} cleanup action/state is invalid for {role}")
        ownership = receipt["ownershipEvidence"]
        if role == "debugserver":
            if not _debugserver_ownership_proven(
                    ownership, registered, run, receipt):
                add("missingDebugserverOwnership", f"{prefix} debugserver lacks exact stable ancestry")
        elif ownership is not None:
            add("invalidCleanupReceipt", f"{prefix} non-debugserver has ownership ancestry evidence")
    if receipt_roles != set(registered) or any(count != 1 for count in receipt_counts.values()):
        add("missingCleanupReceipt", f"{prefix} lacks exactly one cleanup receipt per registry identity")

    if set(residue) != RESIDUE_KEYS:
        add("invalidResidueAudit", f"{prefix} residue audit keys differ from schema")
        return
    audited = residue["auditedIdentities"]
    remaining = residue["remainingIdentities"]
    if not isinstance(audited, list) or not isinstance(remaining, list):
        add("invalidResidueAudit", f"{prefix} residue identity fields must be arrays")
        return
    if audited != list(registered.values()):
        add("residueIdentityMismatch", f"{prefix} residue audit is not registry-bound")
    if residue["complete"] is not True or remaining != []:
        add("residueDetected", f"{prefix} did not prove zero owned-process residue")
    residue_evidence = residue["evidence"]
    if not (
        isinstance(residue_evidence, Mapping)
        and set(residue_evidence) == {"reinspection", "registryDigest", "remainingCount"}
        and residue_evidence["reinspection"] == "exactIdentity"
        and residue_evidence["registryDigest"] == _registry_digest(list(registered.values()))
        and isinstance(residue_evidence["remainingCount"], int)
        and not isinstance(residue_evidence["remainingCount"], bool)
        and residue_evidence["remainingCount"] == 0
    ):
        add("invalidResidueAudit", f"{prefix} residue audit lacks evidence")


def _correlated_lifecycle_proves_gone(
    run: Mapping[str, object], receipt: Mapping[str, object],
    registered: Mapping[str, Mapping[str, object]],
) -> bool:
    """Allow an exact owned process gone after its correlated terminal lifecycle."""
    if not (
        _state(run) == OBSERVED
        and receipt.get("action") == "alreadyExited"
        and receipt.get("terminalState") == "gone"
        and receipt.get("complete") is True
    ):
        return False
    role = receipt.get("role")
    expected = registered.get(role) if isinstance(role, str) else None
    if (
        expected is None
        or receipt.get("expectedIdentity") != expected
        or receipt.get("observedIdentity") != expected
    ):
        return False
    if role == "debugserver":
        if not _debugserver_ownership_proven(
            receipt.get("ownershipEvidence"), registered, run, receipt,
        ):
            return False
        if run.get("mode") == "attach":
            return _detach_proven(run)
    elif role == "adapter" and run.get("mode") == "attach":
        return _detach_proven(run)
    elif not (
        role == "target"
        and run.get("mode") == "launch"
        and expected == run.get("expectedIdentity")
    ):
        return False
    if run.get("mode") != "launch" or run.get("targetDisposition") != "exited":
        return False
    operations = run.get("operations")
    expected_exit = next((
        item for item in operations
        if isinstance(item, Mapping) and item.get("name") == "expectedExit"
    ), None) if isinstance(operations, list) else None
    return (
        isinstance(expected_exit, Mapping)
        and expected_exit.get("observation") == OBSERVED
        and _correlated_evidence(
            expected_exit.get("evidence"), run, "expectedExit", (),
        )
    )


def _debugserver_ownership_proven(
    ownership: object,
    registered: Mapping[str, Mapping[str, object]],
    run: Optional[Mapping[str, object]] = None,
    debugserver_receipt: Optional[Mapping[str, object]] = None,
) -> bool:
    if not (
        isinstance(ownership, Mapping)
        and set(ownership) == {
            "stableExactDescendantChain", "adapterIdentityRevalidated", "ancestorIdentity"
        }
        and ownership["stableExactDescendantChain"] is True
        and ownership["ancestorIdentity"] == registered.get("adapter")
    ):
        return False
    if ownership["adapterIdentityRevalidated"] is True:
        return True
    debugserver = registered.get("debugserver")
    if (
        ownership["adapterIdentityRevalidated"] is not False
        or not isinstance(run, Mapping)
        or not isinstance(debugserver_receipt, Mapping)
        or debugserver is None
        or debugserver_receipt.get("role") != "debugserver"
        or debugserver_receipt.get("action") != "alreadyExited"
        or debugserver_receipt.get("terminalState") != "gone"
        or debugserver_receipt.get("complete") is not True
        or debugserver_receipt.get("expectedIdentity") != debugserver
        or debugserver_receipt.get("observedIdentity") != debugserver
    ):
        return False
    receipts = run.get("cleanupReceipts")
    adapter_receipt = next((
        item for item in receipts
        if isinstance(item, Mapping) and item.get("role") == "adapter"
    ), None) if isinstance(receipts, list) else None
    # When both the registered debugserver and its exact admission-time adapter
    # have already exited, cleanup-time ancestor recapture is impossible.  The
    # stable admission chain remains authoritative only if the adapter's own
    # registry-bound terminal receipt is independently lifecycle-correlated.
    return (
        isinstance(adapter_receipt, Mapping)
        and _correlated_lifecycle_proves_gone(run, adapter_receipt, registered)
    )


def _registry_digest(identities: Sequence[Mapping[str, object]]) -> str:
    payload = json.dumps(list(identities), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _state(run: Optional[Mapping[str, object]]) -> object:
    if not isinstance(run, Mapping):
        return None
    outcome = run.get("outcome")
    return outcome.get("state") if isinstance(outcome, Mapping) else None


def _observed(run: Optional[Mapping[str, object]]) -> bool:
    return _state(run) == OBSERVED


def _row_has_evidence(value: object) -> bool:
    return (
        isinstance(value, str) and bool(value.strip())
    ) or (
        isinstance(value, Mapping) and bool(value)
    )


def _is_enum(value: object, allowed: object) -> bool:
    return isinstance(value, str) and value in allowed


def _candidate_hard_gate_complete(
    runs: Sequence[Optional[Mapping[str, object]]],
    fixture_modules: Sequence[Mapping[str, object]],
) -> bool:
    if len(runs) != 2:
        return False
    launch, attach = runs

    def run_proves(run: object, required: Sequence[str]) -> bool:
        if not isinstance(run, Mapping):
            return False
        operations = run.get("operations")
        if not isinstance(operations, list):
            return False
        by_name = {
            item.get("name"): item
            for item in operations
            if isinstance(item, Mapping)
        }
        return all(
            name in by_name
            and by_name[name].get("observation") == OBSERVED
            and _correlated_evidence(
                by_name[name].get("evidence"), run, name, fixture_modules
            )
            for name in required
        )

    launch_hard = tuple(name for name in HARD_OPERATIONS if name not in {"attach", "detach"})
    return run_proves(launch, launch_hard) and run_proves(attach, ("attach", "detach"))


def _detach_proven(run: Optional[Mapping[str, object]]) -> bool:
    if not isinstance(run, Mapping) or run.get("targetDisposition") != "detached":
        return False
    metadata = run.get("metadata")
    expected = run.get("expectedIdentity")
    operations = run.get("operations")
    detach_row = next(
        (
            item for item in operations
            if isinstance(item, Mapping) and item.get("name") == "detach"
        ),
        None,
    ) if isinstance(operations, list) else None
    return (
        isinstance(metadata, Mapping)
        and isinstance(expected, Mapping)
        and isinstance(detach_row, Mapping)
        and detach_row.get("observation") == OBSERVED
        and _correlated_evidence(detach_row.get("evidence"), run, "detach", ())
        and metadata.get("explicitAdapterPID") == expected.get("pid")
        and metadata.get("explicitDetachAcknowledged") is True
        and metadata.get("detachAcknowledgementSessionID") == run.get("sessionID")
        and metadata.get("disconnectTerminateDebuggee") is False
        and metadata.get("helperAliveAfterDetach") is True
        and metadata.get("helperControllableAfterDetach") is True
        and metadata.get("postDetachIdentity") == expected
        and _post_detach_control_proven(
            metadata.get("postDetachControlEvidence"), run, expected
        )
    )


def _post_detach_control_proven(
    value: object, run: Mapping[str, object], identity: Mapping[str, object]
) -> bool:
    keys = {
        "requestID", "sessionID", "sessionEpoch", "lifecycleRevision",
        "nonce", "sequence", "postcondition",
    }
    return (
        isinstance(value, Mapping)
        and set(value) == keys
        and value["requestID"] == run.get("requestID")
        and value["sessionID"] == run.get("sessionID")
        and value["sessionEpoch"] == run.get("sessionEpoch")
        and value["lifecycleRevision"] == run.get("lifecycleRevision")
        and value["nonce"] == identity.get("nonce")
        and isinstance(value["sequence"], int)
        and not isinstance(value["sequence"], bool)
        and value["sequence"] > 0
        and value["postcondition"] == "same helper answered after detach"
    )


def _require_detach_proof(
    run: Mapping[str, object], candidate: str, add: Callable[[str, str], None]
) -> None:
    if not _detach_proven(run):
        add("attachDidNotProveDetach", f"{candidate} lacks exact nonterminating detach proof")


def _require_observed(
    index: Mapping[tuple[str, str], Mapping[str, object]],
    candidate: str,
    mode: str,
    add: Callable[[str, str], None],
    *,
    code: str = "requiredModeNotObserved",
) -> Optional[Mapping[str, object]]:
    run = index.get((candidate, mode))
    operation_name = "configuredLaunch" if mode == "launch" else "attach"
    operations = run.get("operations") if isinstance(run, Mapping) else None
    operation = next(
        (
            item for item in operations
            if isinstance(item, Mapping) and item.get("name") == operation_name
        ),
        None,
    ) if isinstance(operations, list) else None
    if (
        not _observed(run)
        or not isinstance(operation, Mapping)
        or operation.get("observation") != OBSERVED
        or not _correlated_evidence(operation.get("evidence"), run, operation_name, ())
    ):
        add(code, f"{candidate} did not positively observe {mode}")
        return None
    return run


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Validate one canonical WS-18 aggregate")
    parser.add_argument("aggregate", nargs="?", help="canonical aggregate JSON")
    parser.add_argument("--report", dest="report", help="compatibility alias for aggregate")
    parser.add_argument("--require-launch", action="store_true")
    parser.add_argument("--require-attach", action="store_true")
    parser.add_argument("--require-typed-selection-candidate", action="store_true")
    parser.add_argument("--require-cli-baseline", action="store_true")
    try:
        arguments = parser.parse_args(argv)
    except SystemExit as error:
        return int(error.code)
    path = arguments.aggregate or arguments.report
    if not path or (arguments.aggregate and arguments.report):
        parser.print_usage(sys.stderr)
        return 2
    try:
        aggregate = schema.load_aggregate(Path(path))
    except (OSError, ValueError, json.JSONDecodeError, schema.SchemaError) as error:
        print(f"WS-18 aggregate load failed: {error}", file=sys.stderr)
        return 2
    result = validate_report(
        aggregate,
        require_launch=arguments.require_launch,
        require_attach=arguments.require_attach,
        require_typed_selection_candidate=arguments.require_typed_selection_candidate,
        require_cli_baseline=arguments.require_cli_baseline,
    )
    for issue in result.issues:
        print(f"{issue.code}: {issue.message}", file=sys.stderr)
    return 0 if result.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
