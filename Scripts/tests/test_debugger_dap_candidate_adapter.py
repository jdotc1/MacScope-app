#!/usr/bin/env python3

import importlib.util
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Scripts" / "debugger-fixture" / "dap_candidate_adapter.py"
SPEC = importlib.util.spec_from_file_location("dap_candidate_adapter", PATH)
adapter = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = adapter
SPEC.loader.exec_module(adapter)


def accepted(sequence, name, *, epoch=9, lifecycle=3, stop=1):
    return adapter.drivers.DAPAcceptedEvent(
        sequence, name, epoch, lifecycle, stop)


def lifecycle(operation, pid=4242, *, terminal=False):
    process = adapter.drivers.dap.DAPProcessEventFact(
        20, 9, 2, 0, pid, operation, True)
    stopped = adapter.drivers.dap.DAPStoppedEventFact(
        21, 9, 3, 1, "entry", 7)
    terminated = (adapter.drivers.dap.DAPTerminalEventFact(
        40, 9, 4, 1, "terminated", None) if terminal else None)
    return adapter.drivers.dap.DAPLifecycleFacts(
        9, operation, 1, 2, 3, 4 if terminal else None,
        process, stopped, terminated, None)


def acknowledgement(command, *, response=None, facts=None, events=(), boundary=0,
                    request_sequence=11, lifecycle_revision=3, stop_revision=1):
    return adapter.drivers.DAPRequestAcknowledgement(
        response or {"type": "response", "success": True, "command": command},
        request_sequence, command, 9, lifecycle_revision, stop_revision,
        tuple(events), boundary, facts)


class FakeDriver:
    candidate = "xcode-lldb-dap"
    path = Path("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb-dap")

    def __init__(self):
        self.calls = []
        self.pid = 4242
        self.close_calls = 0
        self.unsupported = set()
        self.empty_body = set()
        self.expected_exit = False
        self.omit_events = set()
        self.defer_events = set()
        self.pending_events = []
        self.raise_commands = set()
        self.disconnect_without_terminal = False
        self.disconnect_success = True

    def request(self, path, command, arguments, timeout):
        self.calls.append((path, command, dict(arguments), timeout))
        if command in self.raise_commands:
            raise RuntimeError(command + " request failed")
        sequence = len(self.calls) + 10
        if command in {"launch", "attach"}:
            pid = int(arguments.get("pid", self.pid))
            return acknowledgement(command, facts=lifecycle(command, pid),
                                   events=(accepted(20, "process", lifecycle=2, stop=0),
                                           accepted(21, "stopped")),
                                   request_sequence=sequence)
        if command == "disconnect":
            operation = "launch" if arguments.get("terminateDebuggee") is True else "attach"
            terminal = not self.disconnect_without_terminal
            return acknowledgement(command, response={
                                       "type": "response",
                                       "success": self.disconnect_success,
                                       "command": command,
                                   }, facts=lifecycle(
                                       operation, self.pid, terminal=terminal),
                                   events=((accepted(40, "terminated", lifecycle=4),)
                                           if terminal else ()),
                                   request_sequence=sequence, lifecycle_revision=4)
        if command in self.unsupported:
            return acknowledgement(command, response={
                "type": "response", "success": False, "command": command,
                "message": "command is not supported",
            }, request_sequence=sequence)
        body = {} if command in self.empty_body else {
            "threads": {"threads": [{"id": 7}]},
            "stackTrace": {"stackFrames": [{"id": 70}]},
            "scopes": {"scopes": [{"name": "Registers", "variablesReference": 99}]},
            "variables": {"variables": [{"name": "x0", "value": "1"}]},
            "setVariable": {"value": "2"},
            "readMemory": {"address": "0x1000", "data": "AAAAAA=="},
            "writeMemory": {"bytesWritten": 4},
            "evaluate": {"result": "2", "variablesReference": 0},
            "modules": {"modules": [{"id": "fixture"}]},
            "setInstructionBreakpoints": {"breakpoints": [{"verified": True, "id": 1}]},
        }.get(command, {})
        events = ()
        boundary = 30
        if command == "pause" or command in {"stepIn", "next", "stepOut"}:
            events = (accepted(32, "stopped", lifecycle=5, stop=2),)
        elif command == "continue":
            events = ((accepted(31, "exited", lifecycle=4, stop=1),)
                      if self.expected_exit else
                      (accepted(31, "continued", lifecycle=4),))
        elif command == "terminate":
            events = (accepted(31, "terminated", lifecycle=4),)
        pending_events = tuple(self.pending_events)
        self.pending_events = []
        if command in self.defer_events:
            self.pending_events.extend(events)
            events = pending_events
        else:
            events = pending_events + events
        if command in self.omit_events:
            events = ()
        lifecycle_revision = (max(event.lifecycleRevision for event in events)
                              if events else
                              5 if command == "pause" else
                              4 if command in {"continue", "terminate"} else 3)
        stop_revision = (max(event.stopRevision for event in events)
                         if events else 1)
        return acknowledgement(command, response={
            "type": "response", "success": True, "command": command, "body": body,
        }, events=events, boundary=boundary, request_sequence=sequence,
           lifecycle_revision=lifecycle_revision, stop_revision=stop_revision)

    def close(self):
        self.close_calls += 1
        return {"role": "adapter", "registration": "DAP-REG", "complete": True}


class Control:
    def __init__(self, pid=4242):
        self.pid = pid
        self.calls = []

    def send(self, operation):
        self.calls.append(operation)
        return {"operation": operation, "pid": self.pid, "commandSequence": 2}


class DAPCandidateAdapterTests(unittest.TestCase):
    def setUp(self):
        self.driver = FakeDriver()
        self.runtime_calls = []
        self.projector_calls = []

    def runtime_binder(self, operation, acknowledgement_value, pid):
        self.runtime_calls.append((operation, acknowledgement_value.command, pid))
        return adapter.runtime.RuntimeProcessFact(
            operation, pid, True, "exact OS identity", {"pid": pid, "nonce": "N"})

    def projector(self, protocol, runtime_fact):
        self.projector_calls.append((protocol, runtime_fact))
        return {"validatorEvidence": {
            "request": {"id": protocol.requestID},
            "postcondition": dict(protocol.postcondition),
        }}

    def candidate(self, **overrides):
        return adapter.DAPCandidateAdapter(
            overrides.get("driver", self.driver),
            runtime_process_binder=overrides.get("runtime", self.runtime_binder),
            report_projector_binder=overrides.get("projector", self.projector),
        )

    @staticmethod
    def exact_target(pid=4242):
        return adapter.drivers.ExactAttachTarget(
            pid, 123456789, 501, 501, "/tmp/FixtureHelper", 0x0100000C, 0,
            "fixture-sha", 17, 23,
            "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            "Apple Development: Test", "N")

    def launch(self, candidate=None):
        candidate = candidate or self.candidate()
        evidence = candidate.launch(
            "launch-R", Path("/tmp/FixtureMain"), ("--nonce", "N"),
            Path("/tmp"), {"FIXTURE_NONCE": "N"})
        self.assertEqual(evidence.observation, "observed")
        return candidate, evidence

    def test_launch_pid_and_process_attempt_are_derived_from_lifecycle_facts(self):
        candidate, evidence = self.launch()
        self.assertEqual(evidence.operation, "configuredLaunch")
        self.assertEqual(evidence.targetPID, 4242)
        self.assertTrue(evidence.proof["processAttempted"])
        protocol = evidence.proof["protocolFact"]
        self.assertEqual(protocol["wireCommands"][0]["command"], "launch")
        self.assertEqual(protocol["postcondition"]["startMethod"], "launch")
        self.assertNotIn("targetPID", self.driver.calls[0][2])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "pause"])
        self.assertEqual(self.runtime_calls, [("configuredLaunch", "continue", 4242)])
        self.assertEqual([wire["command"] for wire in protocol["wireCommands"]],
                         ["launch", "continue", "pause"])
        self.assertEqual(protocol["postcondition"]["entryStoppedPID"], 4242)
        self.assertEqual(protocol["postcondition"]["runtimeBoundWhileRunning"], True)
        self.assertEqual(protocol["postcondition"]["restoredStoppedPID"], 4242)
        self.assertTrue(candidate.process_attempted)

    def test_launch_runtime_binding_occurs_after_continue_and_before_pause(self):
        call_snapshots = []

        def runtime_binder(operation, acknowledgement_value, pid):
            call_snapshots.append((operation, acknowledgement_value.command, pid,
                                   [call[1] for call in self.driver.calls]))
            return adapter.runtime.RuntimeProcessFact(
                operation, pid, True, "exact OS identity", {"pid": pid, "nonce": "N"})

        candidate, evidence = self.launch(self.candidate(runtime=runtime_binder))

        self.assertEqual(call_snapshots, [
            ("configuredLaunch", "continue", 4242, ["launch", "continue"]),
        ])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "pause"])
        self.assertEqual(candidate.mode, "launch")
        self.assertEqual(evidence.targetDisposition, "stopped")

    def test_launch_without_correlated_continue_event_fails_before_runtime_binding(self):
        self.driver.omit_events.add("continue")

        evidence = self.candidate().launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "protocolError")
        self.assertEqual(self.runtime_calls, [])
        self.assertEqual(self.projector_calls, [])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "threads", "disconnect"])
        self.assertEqual(self.driver.calls[-1][2], {"terminateDebuggee": True})
        abort = evidence.proof["unpublishedLaunchAbort"]
        self.assertEqual(abort["event"], "terminated")
        self.assertEqual(abort["targetPID"], 4242)

    def test_launch_continue_request_failure_aborts_unpublished_inferior(self):
        self.driver.raise_commands.add("continue")

        evidence = self.candidate().launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "harnessError")
        self.assertEqual(self.projector_calls, [])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "disconnect"])
        self.assertEqual(self.driver.calls[-1][2], {"terminateDebuggee": True})
        self.assertTrue(evidence.proof["unpublishedLaunchAbort"]["proved"])

    def test_runtime_admission_failure_aborts_before_pause_or_publication(self):
        def wrong(operation, acknowledgement_value, pid):
            return adapter.runtime.RuntimeProcessFact(
                operation, pid + 1, True, "wrong", {"pid": pid + 1})

        evidence = self.candidate(runtime=wrong).launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "identityMismatch")
        self.assertEqual(self.projector_calls, [])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "disconnect"])
        self.assertEqual(self.driver.calls[-1][2], {"terminateDebuggee": True})
        self.assertEqual(evidence.proof["unpublishedLaunchAbort"]["eventSequence"], 40)

    def test_unproved_unpublished_launch_abort_is_blocking_harness_error(self):
        self.driver.omit_events.add("continue")
        self.driver.disconnect_without_terminal = True

        evidence = self.candidate().launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "harnessError")
        self.assertEqual(self.projector_calls, [])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "threads", "disconnect"])
        self.assertFalse(evidence.proof["unpublishedLaunchAbort"]["proved"])

    def test_unpublished_launch_abort_requires_successful_disconnect_response(self):
        self.driver.omit_events.add("continue")
        self.driver.disconnect_success = False

        evidence = self.candidate().launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "harnessError")
        self.assertEqual(self.projector_calls, [])
        abort = evidence.proof["unpublishedLaunchAbort"]
        self.assertFalse(abort["responseSuccess"])
        self.assertFalse(abort["proved"])

    def test_launch_without_correlated_pause_stop_is_not_published(self):
        self.driver.omit_events.add("pause")

        evidence = self.candidate().launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})

        self.assertEqual(evidence.observation, "protocolError")
        self.assertEqual(self.runtime_calls, [("configuredLaunch", "continue", 4242)])
        self.assertEqual(self.projector_calls, [])
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "pause", "threads"])
        self.assertNotIn("unpublishedLaunchAbort", evidence.proof)

    def test_launch_fences_events_that_arrive_after_continue_and_pause_responses(self):
        self.driver.defer_events.update(("continue", "pause"))

        candidate, evidence = self.launch()

        self.assertEqual([call[1] for call in self.driver.calls], [
            "launch", "continue", "threads", "pause", "threads",
        ])
        protocol = evidence.proof["protocolFact"]
        self.assertEqual([wire["command"] for wire in protocol["wireCommands"]], [
            "launch", "continue", "threads", "pause", "threads",
        ])
        self.assertEqual(protocol["acceptedEventSequences"], (20, 21, 31, 32))
        self.assertEqual(candidate.mode, "launch")

    def test_attach_rejects_lifecycle_pid_mismatch_before_evidence_binders(self):
        target = self.exact_target(9191)
        self.driver.pid = 4242
        # The fake honours attach's explicit PID; override the response to prove a mismatch.
        original = self.driver.request
        def mismatch(path, command, arguments, timeout):
            if command == "attach":
                return acknowledgement("attach", facts=lifecycle("attach", 4242),
                                       events=(accepted(20, "process", lifecycle=2, stop=0),
                                               accepted(21, "stopped")))
            return original(path, command, arguments, timeout)
        self.driver.request = mismatch
        evidence = self.candidate().attach("attach-R", target)
        self.assertEqual(evidence.observation, "identityMismatch")
        self.assertTrue(evidence.proof["processAttempted"])
        self.assertEqual(self.runtime_calls, [])
        self.assertEqual(self.projector_calls, [])

    def test_one_adapter_instance_cannot_replace_its_run_session(self):
        candidate, _ = self.launch()
        second = candidate.attach("attach-R", self.exact_target())
        self.assertEqual(second.observation, "harnessError")
        self.assertEqual([call[1] for call in self.driver.calls],
                         ["launch", "continue", "pause"])

    def test_launch_configuration_rows_reuse_exact_start_request_evidence(self):
        candidate, launch = self.launch()
        context = {"operationArguments": {}}
        rows = [candidate.exercise_operation("R-" + name, name, context)
                for name in ("launchArguments", "launchEnvironment",
                             "launchWorkingDirectory")]
        self.assertTrue(all(row.observation == "observed" for row in rows))
        self.assertEqual(len(self.driver.calls), 3)
        self.assertEqual([row.proof["protocolFact"]["postcondition"]["configuredField"]
                          for row in rows], ["args", "env", "cwd"])
        protocol_facts = [row.proof["protocolFact"] for row in (launch, *rows)]
        self.assertEqual([fact["semanticFactID"] for fact in protocol_facts], [
            "launch:11:configuredLaunch", "launch:11:args",
            "launch:11:env", "launch:11:cwd",
        ])
        self.assertEqual([fact["wireCommands"][0]["requestSequence"]
                          for fact in protocol_facts], [11, 11, 11, 11])
        self.assertEqual([fact["requestEventBoundary"] for fact in protocol_facts],
                         [0, 0, 0, 0])
        self.assertEqual([fact["acceptedEventSequences"] for fact in protocol_facts],
                         [(20, 21, 31, 32), (20, 21), (20, 21), (20, 21)])

    def test_semantic_matrix_maps_to_exact_dap_commands_and_response_facts(self):
        candidate, _ = self.launch()
        arguments = {
            "initialBreakpoint": {"address": "0x1000"},
            "breakpointCreation": {"address": "0x1004"},
            "breakpointDelete": {"breakpoints": []},
            "breakpointEnable": {"breakpoints": [{"instructionReference": "0x1004"}]},
            "breakpointDisable": {"breakpoints": []},
            "breakpointCondition": {"breakpoints": [{"condition": "x == 1"}]},
            "breakpointIgnoreCount": {"breakpoints": [{"hitCondition": "3"}]},
            "breakpointHitCount": {"breakpoints": [{"instructionReference": "0x1004"}]},
            "threadSelection": {"threadID": 7},
            "frameList": {"threadID": 7},
            "frameSelection": {"frameID": 70},
            "registerRead": {"variablesReference": 99},
            "registerWrite": {"variablesReference": 99, "name": "x0", "value": "2"},
            "memoryRead": {"memoryReference": "0x1000", "count": 4},
            "memoryWrite": {"memoryReference": "0x1000", "data": "AAAAAA=="},
            "expressionEvaluation": {"expression": "1 + 1", "frameID": 70},
        }
        expected = {
            "initialBreakpoint": "setInstructionBreakpoints",
            "breakpointCreation": "setInstructionBreakpoints",
            "breakpointDelete": "setInstructionBreakpoints",
            "threadList": "threads", "threadSelection": "stackTrace",
            "frameList": "stackTrace", "frameSelection": "scopes",
            "registerRead": "variables", "registerWrite": "setVariable",
            "memoryRead": "readMemory", "memoryWrite": "writeMemory",
            "expressionEvaluation": "evaluate", "moduleList": "modules",
            "stepInto": "stepIn", "stepOver": "next", "stepOut": "stepOut",
        }
        for index, (operation, command) in enumerate(expected.items()):
            with self.subTest(operation=operation):
                result = candidate.exercise_operation(
                    "matrix-%02d" % index, operation,
                    {"operationArguments": arguments})
                self.assertEqual(result.observation, "observed", result.negative)
                self.assertEqual(result.proof["protocolFact"]["wireCommands"][0]["command"],
                                 command)

    def test_acknowledgement_without_operation_postcondition_is_protocol_error(self):
        candidate, _ = self.launch()
        self.driver.empty_body.add("threads")
        result = candidate.exercise_operation("threads-R", "threadList", {})
        self.assertEqual(result.observation, "protocolError")
        self.assertTrue(result.proof["processAttempted"])
        self.assertEqual(self.projector_calls[-1][0].semanticOperation, "configuredLaunch")

    def test_unsupported_requires_an_actual_correlated_wire_attempt(self):
        candidate, _ = self.launch()
        self.driver.unsupported.add("readMemory")
        result = candidate.exercise_operation("memory-R", "memoryRead", {
            "operationArguments": {"memoryRead": {"memoryReference": "0x1000"}},
        })
        self.assertEqual(result.observation, "unsupported")
        self.assertTrue(result.proof["processAttempted"])
        self.assertEqual(result.proof["protocolAttempt"]["command"], "readMemory")
        self.assertEqual(self.driver.calls[-1][1], "readMemory")

    def test_unimplemented_fault_probe_is_not_misreported_as_unsupported(self):
        candidate, _ = self.launch()
        count = len(self.driver.calls)
        result = candidate.exercise_operation("cancel-R", "cancelInFlight", {})
        self.assertEqual(result.observation, "notAttempted")
        self.assertFalse(result.proof["processAttempted"])
        self.assertEqual(len(self.driver.calls), count)

    def test_expected_exit_requires_terminal_event_after_request_boundary(self):
        candidate, _ = self.launch()
        missing = candidate.exercise_operation("exit-1", "expectedExit", {})
        self.assertEqual(missing.observation, "protocolError")
        self.driver.expected_exit = True
        observed = candidate.exercise_operation("exit-2", "expectedExit", {})
        self.assertEqual(observed.observation, "observed")
        self.assertEqual(observed.targetDisposition, "exited")
        self.assertEqual(observed.proof["protocolFact"]["postcondition"]["event"], "exited")

    def test_expected_exit_reuses_observed_terminate_terminal_fact_without_new_request(self):
        candidate, _ = self.launch()
        terminated = candidate.exercise_operation("terminate-R", "terminate", {})
        self.assertEqual(terminated.observation, "observed")
        request_count = len(self.driver.calls)

        exited = candidate.exercise_operation("exit-R", "expectedExit", {})

        self.assertEqual(exited.observation, "observed")
        self.assertEqual(exited.targetDisposition, "exited")
        self.assertEqual(len(self.driver.calls), request_count)
        protocol = exited.proof["protocolFact"]
        self.assertEqual(protocol["wireCommands"][0], {
            "command": "disconnect",
            "arguments": {"terminateDebuggee": True},
            "requestSequence": 14,
        })
        self.assertEqual(protocol["wireCommands"][0]["requestSequence"], 14)
        self.assertEqual(protocol["postcondition"], {
            "event": "terminated", "eventSequence": 40,
        })
        self.assertEqual(protocol["acceptedEventSequences"], (40,))
        self.assertEqual(protocol["semanticFactID"], "disconnect:14:expectedExit")
        self.assertEqual(
            terminated.proof["protocolFact"]["semanticFactID"],
            "disconnect:14:terminate",
        )
        self.assertEqual(self.driver.calls[-1][1:3],
                         ("disconnect", {"terminateDebuggee": True}))

    def test_detach_requires_nonterminating_dap_and_correlated_fixture_survival(self):
        candidate = self.candidate()
        attached = candidate.attach("attach-R", self.exact_target())
        self.assertEqual(attached.observation, "observed")
        control = Control()
        detached = candidate.detach("detach-R", control)
        self.assertEqual(detached.observation, "observed")
        self.assertEqual(detached.targetDisposition, "detached")
        self.assertEqual(control.calls, ["checkpoint"])
        self.assertEqual(self.driver.calls[-1][1:3],
                         ("disconnect", {"terminateDebuggee": False}))

    def test_runtime_fact_must_match_operation_pid_and_exact_identity(self):
        def wrong(operation, ack, pid):
            return adapter.runtime.RuntimeProcessFact(
                operation, pid + 1, True, "wrong", {"pid": pid + 1})
        evidence = self.candidate(runtime=wrong).launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})
        self.assertEqual(evidence.observation, "identityMismatch")
        self.assertEqual(self.projector_calls, [])

    def test_report_projector_cannot_author_validator_decisions(self):
        projector = lambda protocol, runtime: {
            "validatorEvidence": {"request": protocol.requestID},
            "selectionEligibility": "eligible",
        }
        evidence = self.candidate(projector=projector).launch(
            "launch-R", Path("/tmp/main"), (), Path("/tmp"), {})
        self.assertEqual(evidence.observation, "harnessError")
        self.assertNotIn("selectionEligibility", evidence.proof)

    def test_close_requires_exact_complete_adapter_receipt_and_is_idempotent(self):
        candidate, _ = self.launch()
        first = candidate.close()
        second = candidate.close()
        self.assertEqual(first, second)
        self.assertEqual(self.driver.close_calls, 1)
        self.assertTrue(first["complete"])

    def test_constructor_refuses_partial_production_composition(self):
        with self.assertRaises(ValueError):
            adapter.DAPCandidateAdapter(
                self.driver, runtime_process_binder=None,
                report_projector_binder=self.projector)
        with self.assertRaises(ValueError):
            adapter.DAPCandidateAdapter(
                self.driver, runtime_process_binder=self.runtime_binder,
                report_projector_binder=None)


if __name__ == "__main__":
    unittest.main()
