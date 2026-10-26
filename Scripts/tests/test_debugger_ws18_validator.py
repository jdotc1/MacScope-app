#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Scripts/debugger-fixture/validate_ws18.py"


def _load():
    spec = importlib.util.spec_from_file_location("validate_ws18", VALIDATOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


validator = _load()


def identity(role: str = "target", pid: int = 501) -> dict[str, object]:
    uuids = {
        "target": "11111111-1111-1111-1111-111111111111",
        "helper": "22222222-2222-2222-2222-222222222222",
        "adapter": "33333333-3333-3333-3333-333333333333",
        "debugserver": "44444444-4444-4444-4444-444444444444",
    }
    return {
        "pid": pid,
        "startTimeNS": 9001,
        "realUID": 501,
        "effectiveUID": 501,
        "canonicalPath": f"/private/tmp/ws18/{role}",
        "cpuType": 0x0100000C,
        "cpuSubtype": 0,
        "executableIdentity": f"uuid:{role.upper()};device:1;inode:{pid}",
        "nonce": f"nonce-{role}",
        "role": role,
        "device": 1,
        "inode": pid,
        "machOUUID": uuids[role],
    }


def evidence(
    name: str,
    *,
    request_id: str,
    session_id: str,
    session_epoch: int,
    lifecycle_revision: int,
    stop_revision: int,
    sequence: int,
) -> dict[str, object]:
    return {
        "request": {
            "id": f"{request_id}-{name}",
            "runID": request_id,
            "sessionID": session_id,
            "sessionEpoch": session_epoch,
            "lifecycleRevision": lifecycle_revision,
            "stopRevision": stop_revision - 1 if name in validator.STEP_OPERATIONS else stop_revision,
        },
        "event": {
            "sequence": sequence,
            "sessionID": session_id,
            "sessionEpoch": session_epoch,
            "lifecycleRevision": lifecycle_revision,
            "stopRevision": stop_revision,
            "name": name,
        },
        "postcondition": {
            "operation": name,
            "satisfied": True,
            "detail": f"correlated {name} postcondition",
            "identity": (
                {
                    "path": "/private/tmp/ws18/Fixture.framework/Fixture",
                    "machOUUID": "55555555-5555-5555-5555-555555555555",
                }
                if name in validator.MODULE_OPERATIONS else None
            ),
        },
    }


def operations(
    *,
    observed: bool,
    request_id: str,
    session_id: str,
    session_epoch: int,
    lifecycle_revision: int,
    stop_revision: int,
) -> list[dict[str, object]]:
    return [
        {
            "name": name,
            "advertisement": "advertised",
            "observation": "observed" if observed else "notAttempted",
            "evidence": evidence(
                name,
                request_id=request_id,
                session_id=session_id,
                session_epoch=session_epoch,
                lifecycle_revision=lifecycle_revision,
                stop_revision=stop_revision,
                sequence=index + 1,
            ) if observed else "not attempted with typed negative outcome",
            "stopRevision": stop_revision,
        }
        for index, name in enumerate(validator.schema.OPERATION_ORDER)
    ]


def run(candidate: str, mode: str, *, state: str = "observed") -> dict[str, object]:
    role = "helper" if mode == "attach" else "target"
    exact = identity(role)
    adapter = identity("adapter", 601 if mode == "launch" else 602)
    session = f"{candidate}-{mode}-session"
    request_id = f"{candidate}-{mode}-request"
    metadata = {
        "toolchainBinding": "toolchain-A",
        "fixtureBinding": "fixture-A",
        "adapterStartedInNewSession": True,
        "helperStartedInNewSession": True,
        "adapterHelperSessionsDistinct": True,
        "explicitAdapterPID": exact["pid"],
        "explicitDetachAcknowledged": mode == "attach",
        "detachAcknowledgementSessionID": session if mode == "attach" else "",
        "disconnectTerminateDebuggee": False if mode == "attach" else True,
        "helperAliveAfterDetach": mode == "attach",
        "helperControllableAfterDetach": mode == "attach",
        "postDetachIdentity": exact if mode == "attach" else None,
        "postDetachControlEvidence": (
            {
                "requestID": request_id,
                "sessionID": session,
                "sessionEpoch": 1,
                "lifecycleRevision": 4,
                "nonce": exact["nonce"],
                "sequence": 1,
                "postcondition": "same helper answered after detach",
            }
            if mode == "attach" else None
        ),
        "pidEvidenceSource": "adapter",
        "hybrid": False,
    }
    cleanup = {
        "role": role,
        "expectedIdentity": exact,
        "observedIdentity": exact,
        "revalidated": True,
        "action": "fixtureExit",
        "terminalState": "exited",
        "complete": True,
        "detail": "exact identity exited",
        "ownershipEvidence": None,
    }
    adapter_cleanup = {
        **cleanup,
        "role": "adapter",
        "expectedIdentity": adapter,
        "observedIdentity": adapter,
        "action": "gracefulExit",
    }
    registry = [
        {"role": "adapter", "identity": adapter},
        {"role": role, "identity": exact},
    ]
    identities = [adapter, exact]
    operation_rows = operations(
        observed=state == "observed",
        request_id=request_id,
        session_id=session,
        session_epoch=1,
        lifecycle_revision=4,
        stop_revision=3,
    )
    request_ledger = []
    for operation_row in operation_rows:
        if operation_row["observation"] != "observed":
            continue
        proof = operation_row["evidence"]
        request_ledger.append({
            "requestID": proof["request"]["id"],
            "runID": request_id,
            "sessionID": session,
            "sessionEpoch": 1,
            "lifecycleRevision": 4,
            "command": operation_row["name"],
            "responseEventSequence": proof["event"]["sequence"],
            "outcome": "observed",
        })
    return {
        "schemaVersion": 1,
        "candidate": candidate,
        "candidateVersion": "Xcode-27",
        "sessionID": session,
        "sessionEpoch": 1,
        "lifecycleRevision": 4,
        "stopRevision": 3,
        "requestID": request_id,
        "mode": mode,
        "outcome": {"state": state, "evidence": "correlated live evidence"},
        "ownership": "attachedTestFixture" if mode == "attach" else "launched",
        "targetDisposition": "detached" if mode == "attach" else "exited",
        "expectedIdentity": exact,
        "observedIdentity": exact if state == "observed" else None,
        "capabilities": [],
        "operations": operation_rows,
        "processRegistry": registry,
        "cleanupReceipts": [adapter_cleanup, cleanup],
        "residueAudit": {
            "auditedIdentities": identities,
            "remainingIdentities": [],
            "complete": True,
            "evidence": {
                "reinspection": "exactIdentity",
                "registryDigest": validator._registry_digest(identities),
                "remainingCount": 0,
            },
        },
        "diagnostics": [],
        "metadata": metadata,
        "rawBindings": {
            "targetPID": exact["pid"],
            "targetPath": exact["canonicalPath"],
            "targetNonce": exact["nonce"],
            "requestLedger": request_ledger,
        },
    }


def aggregate() -> dict[str, object]:
    candidates = []
    for candidate in validator.schema.CANDIDATE_ORDER:
        candidates.append(validator.schema.make_candidate(
            candidate,
            "Xcode-27",
            {
                "state": "observed",
                "evidence": "selected Xcode discovery",
                "toolchainBinding": "toolchain-A",
            },
            [run(candidate, "launch"), run(candidate, "attach")],
        ))
    target = identity("target")
    helper = identity("helper")
    fixture_processes = {
        role: validator._fixture_identity_projection(value)
        for role, value in (("target", target), ("helper", helper))
    }
    fixture_modules = [{
        "path": "/private/tmp/ws18/Fixture.framework/Fixture",
        "machOUUID": "55555555-5555-5555-5555-555555555555",
    }]
    value = validator.schema.make_aggregate(
        toolchain={"binding": "toolchain-A"},
        fixture={
            "binding": "fixture-A",
            "processIdentities": fixture_processes,
            "moduleIdentities": fixture_modules,
        },
        normalization=validator.schema.make_normalization(),
        candidates=candidates,
        validator=validator.schema.make_validator_envelope(),
    )
    value = validator.schema.seal_validator_digest(value)
    # A decoded JSON document never carries Python object aliasing between
    # expected/observed/registry/receipt identities. Model that real boundary.
    return json.loads(json.dumps(value))


def codes(result) -> set[str]:
    return {item.code for item in result.issues}


def reseal(value: dict[str, object]) -> dict[str, object]:
    return validator.schema.seal_validator_digest(value)


def add_gone_debugserver(run_value: dict[str, object]) -> dict[str, object]:
    debugserver = identity("debugserver", 777)
    adapter = next(
        entry["identity"] for entry in run_value["processRegistry"]
        if entry["role"] == "adapter"
    )
    run_value["processRegistry"].append({
        "role": "debugserver", "identity": debugserver,
    })
    receipt = {
        "role": "debugserver",
        "expectedIdentity": debugserver,
        "observedIdentity": debugserver,
        "revalidated": False,
        "action": "alreadyExited",
        "terminalState": "gone",
        "complete": True,
        "detail": "registered debugserver exited with the correlated lifecycle",
        "ownershipEvidence": {
            "stableExactDescendantChain": True,
            "adapterIdentityRevalidated": True,
            "ancestorIdentity": adapter,
        },
    }
    run_value["cleanupReceipts"].append(receipt)
    identities = [entry["identity"] for entry in run_value["processRegistry"]]
    run_value["residueAudit"]["auditedIdentities"] = identities
    run_value["residueAudit"]["evidence"]["registryDigest"] = (
        validator._registry_digest(identities)
    )
    return receipt


class ValidatorTests(unittest.TestCase):
    def test_accepts_exact_complete_aggregate_and_all_gates(self) -> None:
        result = validator.validate_report(
            aggregate(),
            require_launch=True,
            require_attach=True,
            require_typed_selection_candidate=True,
            require_cli_baseline=True,
        )
        self.assertTrue(result.structurally_valid, result.structural_issues)
        self.assertTrue(result.ok, result.issues)

    def test_structural_validity_is_separate_from_requested_gates(self) -> None:
        value = aggregate()
        value["candidates"][0]["runs"][0]["outcome"] = {
            "state": "policyDenied", "evidence": "macOS denied attach"
        }
        value = reseal(value)
        result = validator.validate_report(value)
        self.assertTrue(result.structurally_valid, result.structural_issues)
        self.assertTrue(result.ok, result.issues)
        gated = validator.validate_report(value, require_launch=True)
        self.assertTrue(gated.structurally_valid, gated.structural_issues)
        self.assertFalse(gated.gates_satisfied)
        self.assertIn("requiredModeNotObserved", codes(gated))

    def test_exact_candidate_and_mode_order_are_unconditional(self) -> None:
        value = aggregate()
        value["candidates"][0]["runs"].reverse()
        result = validator.validate_report(value)
        self.assertIn("modeOrderMismatch", codes(result))

        value = aggregate()
        value["candidates"].reverse()
        result = validator.validate_report(value)
        self.assertIn("invalidAggregateSchema", codes(result))

    def test_rejects_unknown_run_key_and_wrong_types(self) -> None:
        value = aggregate()
        value["candidates"][0]["runs"][0]["surprise"] = True
        result = validator.validate_report(value)
        self.assertIn("invalidRunKeys", codes(result))

        value = aggregate()
        value["candidates"][0]["runs"][0]["sessionEpoch"] = True
        result = validator.validate_report(value)
        self.assertIn("invalidRunType", codes(result))

    def test_rejects_toolchain_fixture_and_raw_identity_misbinding(self) -> None:
        for mutation, expected in (
            (lambda row: row["metadata"].update(toolchainBinding="other"), "toolchainBindingMismatch"),
            (lambda row: row["metadata"].update(fixtureBinding="other"), "fixtureBindingMismatch"),
            (lambda row: row["rawBindings"].update(targetNonce="other"), "rawBindingMismatch"),
        ):
            value = aggregate()
            mutation(value["candidates"][0]["runs"][0])
            self.assertIn(expected, codes(validator.validate_report(value)))

    def test_wrong_pid_path_start_or_nonce_never_false_passes(self) -> None:
        for key, replacement in (
            ("pid", 999),
            ("canonicalPath", "/private/tmp/unrelated"),
            ("startTimeNS", 42),
            ("nonce", "wrong"),
        ):
            value = aggregate()
            value["candidates"][0]["runs"][1]["observedIdentity"][key] = replacement
            result = validator.validate_report(value, require_attach=True)
            self.assertIn("identityMismatch", codes(result), key)

    def test_observed_operation_requires_correlated_evidence(self) -> None:
        value = aggregate()
        for candidate in value["candidates"][:2]:
            for run_value in candidate["runs"]:
                row = run_value["operations"][0]
                row["evidence"] = {"requestID": "", "postcondition": ""}
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertIn("missingOperationProof", codes(result))
        self.assertIn("typedSelectionCandidateUnavailable", codes(result))

    def test_hard_gate_is_complete_and_non_vacuous(self) -> None:
        value = aggregate()
        for candidate in value["candidates"][:2]:
            for run_value in candidate["runs"]:
                row = next(item for item in run_value["operations"] if item["name"] == "memoryRead")
                row["observation"] = "notAttempted"
                row["evidence"] = "not attempted"
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertIn("typedSelectionCandidateUnavailable", codes(result))

    def test_mode_gate_requires_operation_postcondition_not_only_run_outcome(self) -> None:
        value = aggregate()
        row = next(
            item for item in value["candidates"][0]["runs"][0]["operations"]
            if item["name"] == "configuredLaunch"
        )
        row["observation"] = "notAttempted"
        row["evidence"] = "run outcome existed but launch postcondition was absent"
        result = validator.validate_report(value, require_launch=True)
        self.assertIn("requiredModeNotObserved", codes(result))

        value = aggregate()
        row = next(
            item for item in value["candidates"][2]["runs"][1]["operations"]
            if item["name"] == "detach"
        )
        row["observation"] = "notAttempted"
        row["evidence"] = "no detach acknowledgement"
        result = validator.validate_report(value, require_cli_baseline=True)
        self.assertIn("attachDidNotProveDetach", codes(result))

    def test_registry_cleanup_and_residue_are_exact_identity_bound(self) -> None:
        cases = (
            (lambda row: row["cleanupReceipts"].clear(), "missingCleanupReceipt"),
            (lambda row: row["cleanupReceipts"][0].update(complete=False), "incompleteCleanup"),
            (lambda row: row["cleanupReceipts"][0]["expectedIdentity"].update(pid=999), "cleanupIdentityMismatch"),
            (lambda row: row["residueAudit"].update(remainingIdentities=[identity("helper", 999)]), "residueDetected"),
            (lambda row: row["residueAudit"].update(auditedIdentities=[]), "residueIdentityMismatch"),
        )
        for mutation, expected in cases:
            value = aggregate()
            mutation(value["candidates"][0]["runs"][1])
            self.assertIn(expected, codes(validator.validate_report(value)), expected)

    def test_expected_exit_allows_exact_target_already_gone_before_cleanup(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][0]
        receipt = next(item for item in run_value["cleanupReceipts"]
                       if item["role"] == "target")
        receipt.update(
            revalidated=False, action="alreadyExited", terminalState="gone",
            detail="expected-exit terminal evidence preceded cleanup",
        )

        result = validator.validate_report(value)

        self.assertNotIn("incompleteCleanup", codes(result))

    def test_already_gone_cleanup_exception_cannot_cover_launch_adapter_or_missing_exit(self) -> None:
        for mutate in ("launchAdapter", "missingExit"):
            value = aggregate()
            run_value = value["candidates"][0]["runs"][0]
            role = "adapter" if mutate == "launchAdapter" else "target"
            receipt = next(item for item in run_value["cleanupReceipts"]
                           if item["role"] == role)
            receipt.update(
                revalidated=False, action="alreadyExited", terminalState="gone",
                detail="process was gone before cleanup",
            )
            if mutate == "missingExit":
                row = next(item for item in run_value["operations"]
                           if item["name"] == "expectedExit")
                row["observation"] = "notAttempted"
                row["evidence"] = "no terminal protocol fact"

            self.assertIn("incompleteCleanup", codes(validator.validate_report(value)), mutate)

    def test_correlated_attach_detach_allows_exact_adapter_already_gone(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][1]
        receipt = next(item for item in run_value["cleanupReceipts"]
                       if item["role"] == "adapter")
        receipt.update(
            revalidated=False, action="alreadyExited", terminalState="gone",
            detail="adapter exited after correlated nonterminating disconnect",
        )

        result = validator.validate_report(value)

        self.assertNotIn("incompleteCleanup", codes(result))

        run_value["metadata"]["helperControllableAfterDetach"] = False
        self.assertIn(
            "incompleteCleanup", codes(validator.validate_report(value)))

    def test_registered_debugserver_may_be_gone_after_correlated_launch_exit(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][0]
        add_gone_debugserver(run_value)

        result = validator.validate_report(value)

        self.assertNotIn("incompleteCleanup", codes(result))
        self.assertNotIn("missingDebugserverOwnership", codes(result))

    def test_registered_debugserver_may_be_gone_after_correlated_attach_detach(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][1]
        add_gone_debugserver(run_value)

        result = validator.validate_report(value)

        self.assertNotIn("incompleteCleanup", codes(result))
        self.assertNotIn("missingDebugserverOwnership", codes(result))

    def test_gone_debugserver_accepts_correlated_terminal_adapter_chain(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][1]
        debugserver = add_gone_debugserver(run_value)
        debugserver["ownershipEvidence"]["adapterIdentityRevalidated"] = False
        adapter = next(item for item in run_value["cleanupReceipts"]
                       if item["role"] == "adapter")
        adapter.update(
            revalidated=False, action="alreadyExited", terminalState="gone",
            complete=True, detail="adapter exited after correlated detach")

        result = validator.validate_report(value)

        self.assertNotIn("incompleteCleanup", codes(result))
        self.assertNotIn("missingDebugserverOwnership", codes(result))

        adapter["action"] = "gracefulExit"
        result = validator.validate_report(value)
        self.assertIn("missingDebugserverOwnership", codes(result))

        adapter["action"] = "alreadyExited"
        debugserver["action"] = "gracefulExit"
        result = validator.validate_report(value)
        self.assertIn("missingDebugserverOwnership", codes(result))

        debugserver["action"] = "alreadyExited"
        debugserver["terminalState"] = "exited"
        result = validator.validate_report(value)
        self.assertIn("missingDebugserverOwnership", codes(result))

    def test_gone_debugserver_exception_requires_ancestry_correlation_and_action(self) -> None:
        for mode, broken_proof in (
            ("launch", "ancestry"),
            ("launch", "correlation"),
            ("launch", "action"),
            ("attach", "ancestry"),
            ("attach", "correlation"),
            ("attach", "action"),
        ):
            with self.subTest(mode=mode, broken_proof=broken_proof):
                value = aggregate()
                run_value = value["candidates"][0]["runs"][
                    0 if mode == "launch" else 1
                ]
                receipt = add_gone_debugserver(run_value)
                if broken_proof == "ancestry":
                    receipt["ownershipEvidence"]["stableExactDescendantChain"] = False
                elif broken_proof == "correlation":
                    operation = "expectedExit" if mode == "launch" else "detach"
                    row = next(
                        item for item in run_value["operations"]
                        if item["name"] == operation
                    )
                    row["evidence"]["event"]["sessionID"] = "other-session"
                else:
                    receipt["action"] = "gracefulExit"

                result = validator.validate_report(value)

                self.assertIn("incompleteCleanup", codes(result))

    def test_shared_launch_request_sequence_is_allowed_only_for_exact_semantic_subfacts(self) -> None:
        value = aggregate()
        run_value = value["candidates"][0]["runs"][0]
        components = ("configuredLaunch", "args", "env", "cwd")
        names = ("configuredLaunch", "launchArguments", "launchEnvironment",
                 "launchWorkingDirectory")
        for name, component in zip(names, components):
            row = next(item for item in run_value["operations"] if item["name"] == name)
            row["evidence"]["event"]["sequence"] = 1
            row["evidence"]["postcondition"]["detail"] = json.dumps({
                "semanticFactID": f"launch:1:{component}", "postcondition": {"proved": name},
            }, sort_keys=True, separators=(",", ":"))
            ledger = next(item for item in run_value["rawBindings"]["requestLedger"]
                          if item["command"] == name)
            ledger["responseEventSequence"] = 1

        result = validator.validate_report(value)
        self.assertNotIn("nonMonotonicEventSequence", codes(result))

        invalid = aggregate()
        invalid_run = invalid["candidates"][0]["runs"][0]
        for name, component in zip(names, components):
            row = next(item for item in invalid_run["operations"] if item["name"] == name)
            row["evidence"]["event"]["sequence"] = 1
            row["evidence"]["postcondition"]["detail"] = json.dumps({
                "semanticFactID": f"launch:1:{component}", "postcondition": {"proved": name},
            }, sort_keys=True, separators=(",", ":"))
            ledger = next(item for item in invalid_run["rawBindings"]["requestLedger"]
                          if item["command"] == name)
            ledger["responseEventSequence"] = 1
        bad = next(item for item in invalid_run["operations"]
                   if item["name"] == "launchEnvironment")
        bad["evidence"]["postcondition"]["detail"] = json.dumps({
            "semanticFactID": "launch:1:wrong", "postcondition": {"proved": "wrong"},
        }, sort_keys=True, separators=(",", ":"))
        self.assertIn("nonMonotonicEventSequence", codes(validator.validate_report(invalid)))

    def test_shared_terminal_sequence_requires_one_exact_disconnect_fact(self) -> None:
        def configure(value: dict[str, object]) -> tuple[dict[str, object], dict[str, object]]:
            run_value = value["candidates"][0]["runs"][0]
            terminate = next(item for item in run_value["operations"]
                             if item["name"] == "terminate")
            expected = next(item for item in run_value["operations"]
                            if item["name"] == "expectedExit")
            sequence = terminate["evidence"]["event"]["sequence"]
            terminal = {"event": "terminated", "eventSequence": 41}
            between = False
            skipped: set[str] = set()
            for row in run_value["operations"]:
                if row is terminate:
                    between = True
                    continue
                if row is expected:
                    break
                if between:
                    skipped.add(row["name"])
                    row["observation"] = "notAttempted"
                    row["evidence"] = "not attempted after disconnect"
            run_value["rawBindings"]["requestLedger"] = [
                item for item in run_value["rawBindings"]["requestLedger"]
                if item["command"] not in skipped
            ]
            for row in (terminate, expected):
                name = row["name"]
                row["evidence"]["event"]["sequence"] = sequence
                row["evidence"]["postcondition"]["detail"] = json.dumps({
                    "semanticFactID": f"disconnect:{sequence}:{name}",
                    "postcondition": terminal,
                }, sort_keys=True, separators=(",", ":"))
                ledger = next(item for item in run_value["rawBindings"]["requestLedger"]
                              if item["command"] == name)
                ledger["responseEventSequence"] = sequence
            return terminate, expected

        value = aggregate()
        configure(value)
        self.assertNotIn(
            "nonMonotonicEventSequence", codes(validator.validate_report(value)))

        mutations = (
            lambda terminate, expected: expected["evidence"]["postcondition"].update(
                detail=expected["evidence"]["postcondition"]["detail"].replace(
                    '"eventSequence":41', '"eventSequence":42')),
            lambda terminate, expected: expected["evidence"]["postcondition"].update(
                detail=expected["evidence"]["postcondition"]["detail"].replace(
                    ":expectedExit", ":wrong")),
            lambda terminate, expected: terminate["evidence"]["postcondition"].update(
                detail="correlated terminate postcondition"),
        )
        for mutation in mutations:
            invalid = aggregate()
            terminate, expected = configure(invalid)
            mutation(terminate, expected)
            self.assertIn(
                "nonMonotonicEventSequence",
                codes(validator.validate_report(invalid)),
            )

    def test_attach_gate_requires_independent_exact_detach_proof(self) -> None:
        mutations = (
            lambda metadata, row: row.update(targetDisposition="targetDispositionUnknown"),
            lambda metadata, row: metadata.update(explicitAdapterPID=999),
            lambda metadata, row: metadata.update(explicitDetachAcknowledged=False),
            lambda metadata, row: metadata.update(disconnectTerminateDebuggee=True),
            lambda metadata, row: metadata.update(helperAliveAfterDetach=False),
            lambda metadata, row: metadata.update(helperControllableAfterDetach=False),
            lambda metadata, row: metadata.update(postDetachControlEvidence={}),
        )
        for mutation in mutations:
            value = aggregate()
            row = value["candidates"][0]["runs"][1]
            mutation(row["metadata"], row)
            result = validator.validate_report(value, require_attach=True)
            self.assertIn("attachDidNotProveDetach", codes(result))

    def test_cli_gate_cannot_be_satisfied_by_dap_or_python(self) -> None:
        value = aggregate()
        value["candidates"][2]["runs"][1]["outcome"] = {
            "state": "timedOut", "evidence": "bounded timeout"
        }
        result = validator.validate_report(value, require_cli_baseline=True)
        self.assertIn("cliBaselineNotObserved", codes(result))

    def test_python_candidate_independently_satisfies_typed_gate_when_dap_fails(self) -> None:
        value = aggregate()
        value["candidates"][0]["runs"][1]["outcome"] = {
            "state": "unsupported", "evidence": "typed failure"
        }
        value = reseal(value)
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertTrue(result.structurally_valid, result.structural_issues)
        self.assertTrue(result.ok, result.issues)
        self.assertNotIn("typedSelectionCandidateUnavailable", codes(result))

    def test_dap_candidate_independently_satisfies_typed_gate_when_python_fails(self) -> None:
        value = aggregate()
        value["candidates"][1]["runs"][1]["outcome"] = {
            "state": "unsupported", "evidence": "typed failure"
        }
        value = reseal(value)
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertTrue(result.structurally_valid, result.structural_issues)
        self.assertTrue(result.ok, result.issues)
        self.assertNotIn("typedSelectionCandidateUnavailable", codes(result))

    def test_typed_gate_fails_when_neither_typed_candidate_qualifies(self) -> None:
        value = aggregate()
        for candidate in value["candidates"][:2]:
            candidate["runs"][1]["outcome"] = {
                "state": "unsupported", "evidence": "typed failure"
            }
        value = reseal(value)
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertTrue(result.structurally_valid, result.structural_issues)
        self.assertIn("typedSelectionCandidateUnavailable", codes(result))

    def test_observed_run_requires_nonempty_adapter_and_debuggee_registry(self) -> None:
        for field in ("processRegistry", "cleanupReceipts"):
            value = aggregate()
            value["candidates"][0]["runs"][0][field] = []
            result = validator.validate_report(value)
            self.assertIn("emptyProcessProof", codes(result), field)

        value = aggregate()
        row = value["candidates"][0]["runs"][0]
        row["processRegistry"] = []
        row["cleanupReceipts"] = []
        row["residueAudit"] = {
            "auditedIdentities": [], "remainingIdentities": [], "complete": True,
            "evidence": {
                "reinspection": "exactIdentity",
                "registryDigest": validator._registry_digest([]),
                "remainingCount": 0,
            },
        }
        result = validator.validate_report(value)
        self.assertIn("missingMandatoryProcessRole", codes(result))

    def test_operation_proof_is_bound_to_request_session_event_and_revision(self) -> None:
        mutations = (
            lambda proof: proof["request"].update(runID="unrelated"),
            lambda proof: proof["event"].update(sessionID="old-session"),
            lambda proof: proof["event"].update(lifecycleRevision=999),
            lambda proof: proof["event"].update(sequence=0),
            lambda proof: proof["postcondition"].update(operation="other"),
            lambda proof: proof["postcondition"].update(detail=""),
        )
        for mutation in mutations:
            value = aggregate()
            proof = value["candidates"][0]["runs"][0]["operations"][0]["evidence"]
            mutation(proof)
            self.assertIn("missingOperationProof", codes(validator.validate_report(value)))

    def test_full_hard_gate_includes_hit_lists_and_module_list(self) -> None:
        for missing in ("breakpointHit", "threadList", "frameList", "moduleList"):
            value = aggregate()
            for candidate in value["candidates"][:2]:
                for run_value in candidate["runs"]:
                    row = next(item for item in run_value["operations"] if item["name"] == missing)
                    row["observation"] = "notAttempted"
                    row["evidence"] = f"{missing} was not attempted"
            result = validator.validate_report(value, require_typed_selection_candidate=True)
            self.assertIn("typedSelectionCandidateUnavailable", codes(result), missing)

    def test_revisions_ownership_and_disposition_are_strict(self) -> None:
        for field, bad, expected in (
            ("sessionEpoch", -7, "invalidRevision"),
            ("lifecycleRevision", -9, "invalidRevision"),
            ("stopRevision", -11, "invalidRevision"),
            ("ownership", "garbage", "invalidOwnership"),
            ("targetDisposition", "garbage", "invalidTargetDisposition"),
        ):
            value = aggregate()
            value["candidates"][0]["runs"][0][field] = bad
            self.assertIn(expected, codes(validator.validate_report(value)), field)

    def test_cleanup_rejects_unsafe_action_state_null_identity_and_missing_ancestry(self) -> None:
        cases = (
            (lambda receipt: receipt.update(action="signalUnrelated"), "unsafeCleanupReceipt"),
            (lambda receipt: receipt.update(terminalState="running"), "unsafeCleanupReceipt"),
            (lambda receipt: receipt.update(observedIdentity=None), "cleanupIdentityMismatch"),
        )
        for mutation, expected in cases:
            value = aggregate()
            mutation(value["candidates"][0]["runs"][0]["cleanupReceipts"][0])
            self.assertIn(expected, codes(validator.validate_report(value)))

        value = aggregate()
        row = value["candidates"][0]["runs"][0]
        debugserver = identity("debugserver", 777)
        row["processRegistry"].append({"role": "debugserver", "identity": debugserver})
        row["cleanupReceipts"].append({
            "role": "debugserver", "expectedIdentity": debugserver,
            "observedIdentity": debugserver, "revalidated": True,
            "action": "gracefulExit", "terminalState": "exited", "complete": True,
            "detail": "debugserver exited", "ownershipEvidence": None,
        })
        identities = [entry["identity"] for entry in row["processRegistry"]]
        row["residueAudit"]["auditedIdentities"] = identities
        row["residueAudit"]["evidence"]["registryDigest"] = validator._registry_digest(identities)
        self.assertIn("missingDebugserverOwnership", codes(validator.validate_report(value)))

    def test_isolation_pid_source_and_hybrid_safety_are_mandatory(self) -> None:
        cases = (
            ("adapterStartedInNewSession", False, "adapterIsolationFailure"),
            ("helperStartedInNewSession", False, "helperIsolationFailure"),
            ("adapterHelperSessionsDistinct", False, "sessionIsolationFailure"),
            ("pidEvidenceSource", "requestFallback", "pidFallbackForbidden"),
        )
        for field, bad, expected in cases:
            value = aggregate()
            value["candidates"][0]["runs"][1]["metadata"][field] = bad
            self.assertIn(expected, codes(validator.validate_report(value)))
        value = aggregate()
        value["candidates"][0]["runs"][1]["metadata"].update(
            hybrid=True, consoleSessionID="second-session", adapterProcessCount=2
        )
        self.assertIn("invalidHybridSession", codes(validator.validate_report(value)))

    def test_identity_domains_reject_relative_paths_negative_ids_and_fake_uuid(self) -> None:
        mutations = (
            ("realUID", -1), ("effectiveUID", -2), ("canonicalPath", "relative/helper"),
            ("cpuType", -99), ("device", -1), ("inode", -1), ("machOUUID", "x"),
        )
        for field, bad in mutations:
            value = aggregate()
            value["candidates"][0]["runs"][1]["expectedIdentity"][field] = bad
            self.assertIn("incompleteExpectedIdentity", codes(validator.validate_report(value)), field)

    def test_malformed_nested_values_fail_closed_without_exceptions(self) -> None:
        mutations = (
            lambda row: row.pop("mode"),
            lambda row: row.update(residueAudit=[]),
            lambda row: row["cleanupReceipts"][0].update(role=[]),
            lambda row: row.update(capabilities=[42]),
            lambda row: row.update(diagnostics=[{"preview": "not hashed"}]),
        )
        for mutation in mutations:
            value = aggregate()
            mutation(value["candidates"][0]["runs"][0])
            result = validator.validate_report(value)
            self.assertFalse(result.structurally_valid)

    def test_default_requires_dap_cli_attempts_and_python_unsupported_is_consistent(self) -> None:
        value = aggregate()
        for candidate_index in (0, 2):
            for row in value["candidates"][candidate_index]["runs"]:
                row["outcome"] = {"state": "notAttempted", "evidence": "not attempted"}
        self.assertIn("mandatoryCandidateNotAttempted", codes(validator.validate_report(value)))

        value = aggregate()
        value["candidates"][1]["discovery"]["state"] = "structurallyUnsupported"
        result = validator.validate_report(value)
        self.assertIn("contradictoryUnsupportedCandidate", codes(result))

    def test_validator_digest_is_mandatory_and_forgery_detected(self) -> None:
        value = aggregate()
        value["validator"]["canonicalDigest"] = "0" * 64
        self.assertIn("invalidValidatorDigest", codes(validator.validate_report(value)))
        value = aggregate()
        value["validator"] = {"pass": True, "canonicalDigest": "0" * 64}
        self.assertIn("invalidAggregateSchema", codes(validator.validate_report(value)))

    def test_steps_require_new_stop_and_modules_require_uuid_event_identity(self) -> None:
        value = aggregate()
        step = next(
            item for item in value["candidates"][0]["runs"][0]["operations"]
            if item["name"] == "stepInto"
        )
        step["evidence"]["request"]["stopRevision"] = step["evidence"]["event"]["stopRevision"]
        self.assertIn("missingOperationProof", codes(validator.validate_report(value)))

        value = aggregate()
        module = next(
            item for item in value["candidates"][0]["runs"][0]["operations"]
            if item["name"] == "moduleLoad"
        )
        module["evidence"]["postcondition"]["identity"] = None
        self.assertIn("missingOperationProof", codes(validator.validate_report(value)))

    def test_event_sequences_and_operation_request_ids_are_unique_and_monotonic(self) -> None:
        value = aggregate()
        for row in value["candidates"][0]["runs"][0]["operations"]:
            row["evidence"]["event"]["sequence"] = 1
        self.assertIn("nonMonotonicEventSequence", codes(validator.validate_report(value)))

        value = aggregate()
        for row in value["candidates"][0]["runs"][0]["operations"]:
            row["evidence"]["request"]["id"] = "one-request"
        self.assertIn("duplicateOperationRequest", codes(validator.validate_report(value)))

    def test_observed_operation_must_resolve_in_raw_request_ledger(self) -> None:
        value = aggregate()
        value["candidates"][0]["runs"][0]["rawBindings"]["requestLedger"][0]["command"] = "other"
        self.assertIn("requestLedgerMismatch", codes(validator.validate_report(value)))

        value = aggregate()
        value["candidates"][0]["runs"][0]["rawBindings"]["requestLedger"].pop(0)
        self.assertIn("requestLedgerMismatch", codes(validator.validate_report(value)))

    def test_typed_hard_gate_cannot_be_split_across_launch_and_attach_sessions(self) -> None:
        value = aggregate()
        non_mode = [name for name in validator.HARD_OPERATIONS if name not in {"attach", "detach"}]
        for candidate in value["candidates"][:2]:
            for index, name in enumerate(non_mode):
                run_index = 0 if index % 2 == 0 else 1
                row = next(
                    item for item in candidate["runs"][run_index]["operations"]
                    if item["name"] == name
                )
                row["observation"] = "notAttempted"
                row["evidence"] = "operation absent from this session"
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertIn("typedSelectionCandidateUnavailable", codes(result))

    def test_syntactically_valid_unrelated_process_cannot_replace_fixture(self) -> None:
        value = aggregate()
        row = value["candidates"][0]["runs"][1]
        unrelated = identity("helper", 888)
        unrelated.update({
            "canonicalPath": "/private/tmp/ws18/unrelated-helper",
            "device": 9,
            "inode": 888,
            "executableIdentity": "uuid:99999999-9999-9999-9999-999999999999;device:9;inode:888",
            "machOUUID": "99999999-9999-9999-9999-999999999999",
        })
        row["expectedIdentity"] = unrelated
        row["observedIdentity"] = unrelated
        row["rawBindings"].update(
            targetPID=unrelated["pid"], targetPath=unrelated["canonicalPath"],
            targetNonce=unrelated["nonce"],
        )
        row["metadata"].update(
            explicitAdapterPID=unrelated["pid"], postDetachIdentity=unrelated,
        )
        row["processRegistry"][1]["identity"] = unrelated
        row["cleanupReceipts"][1]["expectedIdentity"] = unrelated
        row["cleanupReceipts"][1]["observedIdentity"] = unrelated
        identities = [entry["identity"] for entry in row["processRegistry"]]
        row["residueAudit"]["auditedIdentities"] = identities
        row["residueAudit"]["evidence"]["registryDigest"] = validator._registry_digest(identities)
        self.assertIn("fixtureIdentityMismatch", codes(validator.validate_report(value)))

    def test_syntactically_valid_unrelated_module_cannot_satisfy_module_gate(self) -> None:
        value = aggregate()
        unrelated = {
            "path": "/private/tmp/ws18/Unrelated.dylib",
            "machOUUID": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        }
        for candidate in value["candidates"][:2]:
            for run_value in candidate["runs"]:
                for row in run_value["operations"]:
                    if row["name"] in validator.MODULE_OPERATIONS:
                        row["evidence"]["postcondition"]["identity"] = unrelated
        result = validator.validate_report(value, require_typed_selection_candidate=True)
        self.assertIn("missingOperationProof", codes(result))
        self.assertIn("typedSelectionCandidateUnavailable", codes(result))

    def test_registry_rejects_same_pid_for_adapter_and_debuggee(self) -> None:
        value = aggregate()
        row = value["candidates"][0]["runs"][0]
        adapter = row["processRegistry"][0]["identity"]
        target = row["processRegistry"][1]["identity"]
        adapter["pid"] = target["pid"]
        row["cleanupReceipts"][0]["expectedIdentity"]["pid"] = target["pid"]
        row["cleanupReceipts"][0]["observedIdentity"]["pid"] = target["pid"]
        identities = [entry["identity"] for entry in row["processRegistry"]]
        row["residueAudit"]["auditedIdentities"] = identities
        row["residueAudit"]["evidence"]["registryDigest"] = validator._registry_digest(identities)
        self.assertIn("duplicateRegisteredPID", codes(validator.validate_report(value)))

    def test_cleanup_cannot_call_every_process_detached(self) -> None:
        value = aggregate()
        for candidate in value["candidates"]:
            for run_value in candidate["runs"]:
                for receipt in run_value["cleanupReceipts"]:
                    receipt["action"] = "detach"
                    receipt["terminalState"] = "detached"
        self.assertIn("unsafeCleanupReceipt", codes(validator.validate_report(value)))


class ValidatorCLITests(unittest.TestCase):
    def test_positional_and_report_alias_are_interoperable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "aggregate.json"
            path.write_text(json.dumps(aggregate()), encoding="utf-8")
            flags = ["--require-launch", "--require-attach", "--require-cli-baseline"]
            self.assertEqual(validator.main([str(path), *flags]), 0)
            self.assertEqual(validator.main(["--report", str(path), *flags]), 0)

    def test_cli_returns_two_for_load_error_and_one_for_gate_failure(self) -> None:
        self.assertEqual(validator.main(["/does/not/exist"]), 2)
        with tempfile.TemporaryDirectory() as directory:
            value = aggregate()
            value["candidates"][2]["runs"][0]["outcome"] = {
                "state": "policyDenied", "evidence": "denied"
            }
            path = Path(directory) / "aggregate.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            self.assertEqual(
                validator.main([str(path), "--require-cli-baseline"]),
                1,
            )


if __name__ == "__main__":
    unittest.main()
