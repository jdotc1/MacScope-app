#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Scripts" / "debugger-fixture" / "python_candidate_adapter.py"
SPEC = importlib.util.spec_from_file_location("python_candidate_adapter", PATH)
adapter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = adapter
SPEC.loader.exec_module(adapter)


class Result:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class Runner:
    def __init__(self, supported=True):
        self.calls = []
        self.results = [
            Result(stdout="/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb\n"),
            Result(stdout="/Applications/Xcode-beta.app/Contents/SharedFrameworks/LLDB.framework/Resources/Python\n"),
            Result(stdout=(
                '{"module":"/Xcode/lldb/__init__.py",'
                '"pythonExecutable":"/Applications/Xcode-beta.app/Contents/Developer/'
                'Library/Frameworks/Python3.framework/Versions/3.9/Resources/'
                'Python.app/Contents/MacOS/Python","version":"lldb-27"}\n'
            )),
        ] if supported else [Result(returncode=1, stderr="missing")]

    def run(self, argv, *, env=None, timeout=15.0):
        self.calls.append((tuple(argv), env, timeout))
        return self.results.pop(0)


def target(pid=4242):
    return adapter.drivers.ExactAttachTarget(
        pid=pid, startTimeNS=123456789, realUID=501, effectiveUID=501,
        canonicalPath="/tmp/FixtureHelper", cpuType=0x0100000C, cpuSubtype=0,
        executableIdentity="fixture-sha", executableDevice=17, executableInode=23,
        machOUUID="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        signingIdentity="Apple Development: Test", nonce="NONCE")


def validator_binding(operation, protocol):
    return {"validatorEvidence": {
        "request": {"id": protocol["requestID"]},
        "event": {"sequence": protocol["sequence"]},
        "postcondition": {"operation": operation, "satisfied": True},
    }}


class FakeClient:
    instances = []
    unsupported = {
        "launchArguments", "launchEnvironment", "launchWorkingDirectory",
        "initialBreakpoint", "refresh", "runToCursor", "breakpointHit",
        "moduleLoad", "moduleUnload", "cancelBeforeSpawn", "cancelInFlight",
        "timeoutRecovery", "adapterCrashRecovery",
    }

    def __init__(self, discovery, lifecycle, authority=None):
        self.discovery, self.lifecycle, self.authority = discovery, lifecycle, authority
        self.requests, self.close_calls = [], 0
        self.__class__.instances.append(self)

    def request(self, message):
        self.requests.append(dict(message))
        operation = message["operation"]
        observation = "unsupported" if operation in self.unsupported else "observed"
        if operation == "configuredLaunch":
            result, disposition = {"targetPID": 4242}, "stopped"
        elif operation == "attach":
            result = {"targetPID": message["arguments"]["identity"]["pid"]}
            disposition = "stopped"
        elif operation == "detach":
            result, disposition = {"terminateRequested": False}, "detached"
        elif operation == "terminate":
            result, disposition = {"targetPID": 4242}, "exited"
        elif operation == "expectedExit":
            result = {"targetPID": 4242, "originatingOperation": "terminate"}
            disposition = "exited"
        else:
            result, disposition = {}, "stopped"
        return {
            "schema": message["schema"], "contractVersion": message["contractVersion"],
            "requestID": message["requestID"], "sessionID": message["sessionID"],
            "sessionEpoch": message["sessionEpoch"], "sequence": message["sequence"],
            "operation": operation, "observation": observation,
            "lifecycleRevision": message["sequence"], "stopRevision": 1,
            "ownership": "attachedTestFixture", "targetDisposition": disposition,
            "result": result, "evidence": {"protocolFact": True},
            "diagnostic": ({"reason": "supervisor-owned fault injection"}
                           if observation == "unsupported" else {}),
        }

    def close(self):
        self.close_calls += 1
        return {"role": "adapter", "registration": "REG", "complete": True}


class PythonCandidateAdapterTests(unittest.TestCase):
    def setUp(self):
        FakeClient.instances.clear()
        self.lifecycle = object()
        self.authority = object()

    def make_adapter(self, runner=None, binder=validator_binding, factory=FakeClient):
        return adapter.PythonCandidateAdapter(
            runner or Runner(), lifecycle=self.lifecycle, authority=self.authority,
            evidence_binder=binder, client_factory=factory,
            session_id="RUN-PYTHON", session_epoch=7)

    def test_discovery_supported_means_all_live_boundaries_are_installed(self):
        candidate = self.make_adapter()
        discovery = candidate.discover()
        self.assertTrue(discovery.supported)
        self.assertTrue(discovery.evidence["typedOperationBridge"])
        self.assertTrue(discovery.evidence["registeredLifecycle"])
        self.assertTrue(discovery.evidence["exactParentAuthority"])
        self.assertTrue(discovery.evidence["supervisorEvidenceBinder"])
        self.assertEqual(len(FakeClient.instances), 0)

    def test_structural_discovery_failure_never_spawns_a_bridge(self):
        candidate = self.make_adapter(Runner(supported=False))
        self.assertFalse(candidate.discover().supported)
        with self.assertRaises(adapter.PythonCandidateError):
            candidate.start()
        self.assertEqual(FakeClient.instances, [])

    def test_launch_uses_one_session_exact_arguments_and_parent_authority(self):
        candidate = self.make_adapter()
        observed = candidate.launch(
            "launch-R", Path("/tmp/FixtureHelper"), ("--nonce", "N"),
            Path("/tmp"), {"FIXTURE_NONCE": "N"})
        self.assertEqual(observed.observation, "observed")
        self.assertEqual(observed.operation, "configuredLaunch")
        self.assertEqual(observed.targetPID, 4242)
        self.assertIn("validatorEvidence", observed.proof)
        client = FakeClient.instances[0]
        self.assertIs(client.lifecycle, self.lifecycle)
        self.assertIs(client.authority, self.authority)
        self.assertEqual([item["operation"] for item in client.requests],
                         ["initialize", "configuredLaunch"])
        launch = client.requests[-1]
        self.assertEqual(launch["requestID"], "launch-R")
        self.assertEqual(launch["arguments"]["arguments"], ["--nonce", "N"])
        self.assertTrue(launch["arguments"]["stopAtEntry"])

    def test_terminal_unpublished_launch_abort_is_bound_to_parent_lifecycle(self):
        accepted = []
        class Lifecycle:
            def accept_unpublished_launch_abort(self, protocol):
                accepted.append(protocol)
        class AbortClient(FakeClient):
            def request(self, message):
                response = super().request(message)
                if message["operation"] == "configuredLaunch":
                    response.update({
                        "observation": "adapterError",
                        "ownership": "none",
                        "targetDisposition": "exited",
                        "result": {},
                        "evidence": {"cleanup": {
                            "killRequested": True,
                            "complete": True,
                            "targetDisposition": "exited",
                        }},
                        "diagnostic": {"reason": "launch never entered running state"},
                    })
                return response
        self.lifecycle = Lifecycle()
        candidate = self.make_adapter(factory=AbortClient)

        result = candidate.launch(
            "launch-R", Path("/tmp/FixtureHelper"), (), Path("/tmp"), {})

        self.assertEqual(result.observation, "targetError")
        self.assertEqual(len(accepted), 1)
        self.assertEqual(accepted[0]["operation"], "configuredLaunch")
        self.assertEqual(accepted[0]["ownership"], "none")
        self.assertTrue(accepted[0]["evidence"]["cleanup"]["complete"])

    def test_attach_translates_every_identity_field_then_detaches_nonterminating(self):
        candidate = self.make_adapter()
        exact = target(9191)
        attached = candidate.attach("attach-R", exact)
        detached = candidate.detach("detach-R")
        self.assertEqual((attached.observation, detached.observation),
                         ("observed", "observed"))
        self.assertEqual(detached.targetDisposition, "detached")
        identity = FakeClient.instances[0].requests[1]["arguments"]["identity"]
        self.assertEqual(identity["executableDevice"], exact.executableDevice)
        self.assertEqual(identity["executableInode"], exact.executableInode)
        self.assertEqual(identity["signingIdentity"], exact.signingIdentity)
        self.assertEqual(identity["role"], "attachedHelper")
        self.assertNotIn("device", identity)
        self.assertNotIn("inode", identity)
        self.assertEqual(FakeClient.instances[0].requests[-1]["operation"], "detach")

    def test_full_frozen_matrix_is_executable_or_has_typed_negative_evidence(self):
        candidate = self.make_adapter()
        candidate.attach("attach-R", target())
        arguments = {
            "breakpointCreation": {"address": 0x1000},
            "breakpointDelete": {"breakpointID": 1},
            "breakpointEnable": {"breakpointID": 1},
            "breakpointDisable": {"breakpointID": 1},
            "breakpointCondition": {"breakpointID": 1, "condition": "x == 1"},
            "breakpointIgnoreCount": {"breakpointID": 1, "ignoreCount": 2},
            "breakpointHitCount": {"breakpointID": 1},
            "threadSelection": {"threadID": 8},
            "frameSelection": {"frameIndex": 0},
            "registerWrite": {"name": "x0", "value": "1"},
            "memoryRead": {"address": 0x1000, "size": 4},
            "memoryWrite": {"address": 0x1000, "dataBase64": "AAAAAA=="},
            "expressionEvaluation": {"expression": "1 + 1"},
        }
        results = []
        for index, operation in enumerate(adapter.schema.OPERATION_ORDER):
            if operation in {"configuredLaunch", "attach", "detach"}:
                continue
            results.append(candidate.exercise_operation(
                "matrix-%02d" % index, operation,
                {"operationArguments": arguments}))
        self.assertEqual(len(results), len(adapter.schema.OPERATION_ORDER) - 3)
        self.assertTrue(all(item.observation in {"observed", "unsupported"}
                            for item in results))
        unsupported = [item for item in results if item.observation == "unsupported"]
        self.assertEqual({item.operation for item in unsupported}, FakeClient.unsupported)
        self.assertTrue(all(item.negative for item in unsupported))

    def test_missing_required_matrix_arguments_are_not_fabricated(self):
        candidate = self.make_adapter()
        result = candidate.exercise_operation("memory-R", "memoryRead", {})
        self.assertEqual(result.observation, "notAttempted")
        self.assertIn("address", result.negative["diagnosticPreview"])
        self.assertEqual(FakeClient.instances, [])

    def test_adapter_error_is_mapped_to_frozen_target_error(self):
        class ErrorClient(FakeClient):
            def request(self, message):
                response = super().request(message)
                if message["operation"] == "pause":
                    response["observation"] = "adapterError"
                    response["diagnostic"] = {"reason": "process rejected stop"}
                return response
        candidate = self.make_adapter(factory=ErrorClient)
        result = candidate.exercise_operation("pause-R", "pause", {})
        self.assertEqual(result.observation, "targetError")
        self.assertEqual(result.negative["classification"], "targetError")

    def test_bridge_start_failure_is_typed_negative_evidence(self):
        def failing_factory(discovery, lifecycle, authority=None):
            del discovery, lifecycle, authority
            raise RuntimeError("bridge child could not start")

        candidate = self.make_adapter(factory=failing_factory)
        result = candidate.exercise_operation("pause-R", "pause", {})

        self.assertEqual(result.observation, "harnessError")
        self.assertEqual(result.negative["classification"], "harnessError")
        self.assertIn("bridge child could not start", result.negative["diagnosticPreview"])

    def test_observed_protocol_fact_without_supervisor_binding_is_harness_error(self):
        candidate = self.make_adapter(binder=lambda operation, protocol: (
            validator_binding(operation, protocol) if operation == "initialize" else {}))
        result = candidate.exercise_operation("pause-R", "pause", {})
        self.assertEqual(result.observation, "harnessError")
        self.assertEqual(result.proof, {})

    def test_close_requires_one_complete_adapter_receipt_and_is_idempotent(self):
        candidate = self.make_adapter()
        candidate.start()
        first = candidate.close()
        second = candidate.close()
        self.assertEqual(first, second)
        self.assertTrue(first["complete"])
        self.assertEqual(FakeClient.instances[0].close_calls, 1)
        with self.assertRaises(adapter.PythonCandidateError):
            candidate.start()

    def test_incomplete_cleanup_receipt_is_rejected(self):
        class BadCloseClient(FakeClient):
            def close(self):
                return {"role": "adapter", "complete": False}
        candidate = self.make_adapter(factory=BadCloseClient)
        candidate.start()
        with self.assertRaises(adapter.PythonCandidateError):
            candidate.close()

    def test_constructor_refuses_partial_production_composition(self):
        for name, values in (
            ("lifecycle", (None, self.authority, validator_binding)),
            ("authority", (self.lifecycle, None, validator_binding)),
            ("binder", (self.lifecycle, self.authority, None)),
        ):
            with self.subTest(name=name), self.assertRaises(ValueError):
                adapter.PythonCandidateAdapter(
                    Runner(), lifecycle=values[0], authority=values[1],
                    evidence_binder=values[2])


if __name__ == "__main__":
    unittest.main()
