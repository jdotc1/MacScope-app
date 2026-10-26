#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PATH = ROOT / "Scripts" / "debugger-fixture" / "lldb_python_bridge.py"
SPEC = importlib.util.spec_from_file_location("lldb_python_bridge", PATH)
assert SPEC and SPEC.loader
bridge = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = bridge
SPEC.loader.exec_module(bridge)


class FakeError:
    def __init__(self, success=True, message=""):
        self.success = success
        self.message = message

    def Success(self): return self.success
    def Fail(self): return not self.success
    def GetCString(self): return self.message


class FakeFileSpec:
    def __init__(self, path): self.fullpath = path
    def GetPath(self): return self.fullpath


class FakeAddress:
    def __init__(self, value): self.value = value
    def GetLoadAddress(self, target): return self.value


class FakeValue:
    def __init__(self, name, value, *, valid=True):
        self.name, self.value, self.valid = name, value, valid

    def IsValid(self): return self.valid
    def GetName(self): return self.name
    def GetValue(self): return self.value
    def GetSummary(self): return None
    def GetTypeName(self): return "unsigned long"
    def SetValueFromCString(self, value, error=None):
        self.value = value
        return True


class FakeValueList:
    def __init__(self, values): self.values = list(values)
    def GetSize(self): return len(self.values)
    def GetValueAtIndex(self, index): return self.values[index]


class FakeFrame:
    def __init__(self):
        self.registers = FakeValueList([
            FakeValue("General Purpose Registers", None),
            FakeValue("x0", "0x2a"),
        ])
        self.registers.values[0].GetNumChildren = lambda: 1
        self.registers.values[0].GetChildAtIndex = lambda index: self.registers.values[1]

    def IsValid(self): return True
    def GetFrameID(self): return 3
    def GetPCAddress(self): return FakeAddress(0x100001000)
    def GetFunctionName(self): return "fixture_checkpoint"
    def GetRegisters(self): return self.registers
    def EvaluateExpression(self, expression, options=None): return FakeValue("result", "42")


class FakeThread:
    def __init__(self):
        self.frame = FakeFrame()
        self.steps = []

    def IsValid(self): return True
    def GetThreadID(self): return 77
    def GetName(self): return "main"
    def GetStopReason(self): return 3
    def GetNumFrames(self): return 1
    def GetFrameAtIndex(self, index): return self.frame
    def GetSelectedFrame(self): return self.frame
    def SetSelectedFrame(self, index): return index == 0
    def StepOver(self): self.steps.append("stepOver")
    def StepInto(self): self.steps.append("stepInto")
    def StepOut(self): self.steps.append("stepOut")


class FakeProcess:
    def __init__(self, pid=4242, state=5):
        self.pid, self.state = pid, state
        self.thread = FakeThread()
        self.detached = False
        self.kill_calls = 0
        self.call_order = []
        self.continue_error = FakeError()
        self.stop_error = FakeError()
        self.memory = bytearray(b"abcdefgh")

    def IsValid(self): return True
    def GetProcessID(self): return self.pid
    def GetState(self): return self.state
    def Stop(self):
        self.call_order.append("stop")
        if self.stop_error.Success():
            self.state = 5
        return self.stop_error
    def Continue(self):
        self.call_order.append("continue")
        if self.continue_error.Success():
            self.state = 6
        return self.continue_error
    def Detach(self): self.detached = True; self.state = 9; return FakeError()
    def Kill(self): self.kill_calls += 1; self.state = 10; return FakeError()
    def GetNumThreads(self): return 1
    def GetThreadAtIndex(self, index): return self.thread
    def GetThreadByID(self, identifier): return self.thread if identifier == 77 else FakeThreadInvalid()
    def GetSelectedThread(self): return self.thread
    def SetSelectedThread(self, thread): self.thread = thread; return True
    def ReadMemory(self, address, size, error): return bytes(self.memory[:size])
    def WriteMemory(self, address, payload, error):
        self.memory[:len(payload)] = payload
        return len(payload)


class FakeThreadInvalid(FakeThread):
    def IsValid(self): return False


class FakeBreakpoint:
    def __init__(self, identifier, address):
        self.identifier, self.address = identifier, address
        self.enabled, self.condition, self.ignore_count = True, "", 0

    def IsValid(self): return True
    def GetID(self): return self.identifier
    def GetNumLocations(self): return 1
    def GetHitCount(self): return 2
    def SetEnabled(self, enabled): self.enabled = enabled
    def SetCondition(self, value): self.condition = value
    def SetIgnoreCount(self, value): self.ignore_count = value


class FakeModule:
    def __init__(self, path="/tmp/Fixture", uuid="UUID-1"):
        self.path, self.uuid = path, uuid

    def IsValid(self): return True
    def GetFileSpec(self): return FakeFileSpec(self.path)
    def GetUUIDString(self): return self.uuid


class FakeTarget:
    def __init__(self, path):
        self.path = path
        self.process = FakeProcess()
        self.breakpoints = {}
        self.modules = [FakeModule(path), FakeModule("/tmp/Fixture.framework/Fixture", "UUID-2")]
        self.last_launch_info = None
        self.last_attach_info = None

    def IsValid(self): return True
    def GetExecutable(self): return FakeFileSpec(self.path)
    def Launch(self, launch_info, error):
        self.last_launch_info = launch_info
        return self.process
    def Attach(self, attach_info, error):
        self.last_attach_info = attach_info
        self.process.pid = attach_info.pid
        return self.process
    def BreakpointCreateByAddress(self, address):
        item = FakeBreakpoint(len(self.breakpoints) + 1, address)
        self.breakpoints[item.identifier] = item
        return item
    def FindBreakpointByID(self, identifier): return self.breakpoints.get(identifier, FakeBreakpointInvalid())
    def BreakpointDelete(self, identifier): return self.breakpoints.pop(identifier, None) is not None
    def GetNumModules(self): return len(self.modules)
    def GetModuleAtIndex(self, index): return self.modules[index]


class FakeBreakpointInvalid(FakeBreakpoint):
    def __init__(self): super().__init__(-1, 0)
    def IsValid(self): return False


class FakeLaunchInfo:
    def __init__(self, arguments):
        self.arguments = list(arguments)
        self.cwd = None
        self.environment = []
        self.flags = 0

    def SetWorkingDirectory(self, value): self.cwd = value
    def SetEnvironmentEntries(self, values, append): self.environment = list(values)
    def SetLaunchFlags(self, flags): self.flags = flags


class FakeAttachInfo:
    def __init__(self, pid): self.pid = pid
    def SetWaitForLaunch(self, value): self.wait_for_launch = value


class FakeEvent:
    def __init__(self): self.valid = False; self.state = None
    def IsValid(self): return self.valid
    def GetType(self): return 1


class FakeListener:
    def __init__(self): self.states = []; self.timeouts = []
    def WaitForEvent(self, timeout, event):
        self.timeouts.append(timeout)
        if not self.states: return False
        event.valid = True
        event.state = self.states.pop(0)
        return True


class FakeDebugger:
    def __init__(self):
        self.listener = FakeListener()
        self.target = None
        self.async_value = None
        self.async_history = []

    def SetAsync(self, value):
        self.async_value = value
        self.async_history.append(value)
    def GetListener(self): return self.listener
    def CreateTarget(self, path): self.target = FakeTarget(path); return self.target


class FakeSBDebuggerFactory:
    version = "lldb-fake-27"
    last = None

    @classmethod
    def Create(cls): cls.last = FakeDebugger(); return cls.last
    @classmethod
    def Destroy(cls, debugger): cls.last = None
    @classmethod
    def GetVersionString(cls): return cls.version


class FakeSBProcessEvents:
    @staticmethod
    def EventIsProcessEvent(event): return event.IsValid()
    @staticmethod
    def GetStateFromEvent(event): return event.state


class FakeSB:
    SBDebugger = FakeSBDebuggerFactory
    SBError = FakeError
    SBLaunchInfo = FakeLaunchInfo
    SBAttachInfo = FakeAttachInfo
    SBEvent = FakeEvent
    SBProcess = FakeSBProcessEvents
    SBExpressionOptions = object
    eLaunchFlagStopAtEntry = 1
    eStateStopped = 5
    eStateRunning = 6
    eStateExited = 10
    eStateDetached = 9


class Authority:
    def __init__(self):
        self.calls = []
        self.observed_states = []
        self.identity_match = True
        self.detach_alive = True

    def authorize_launch(self, executable, arguments, cwd, environment):
        self.calls.append(("authorizeLaunch", executable))
        return {"authorized": True, "canonicalPath": executable, "nonce": "N"}

    def authorize_attach(self, identity):
        self.calls.append(("authorizeAttach", identity["pid"]))
        return {"authorized": True, "identity": dict(identity)}

    def observe_process(self, operation, process_id, expected):
        self.calls.append(("observeProcess", operation, process_id))
        target = FakeSBDebuggerFactory.last.target
        self.observed_states.append(target.process.GetState())
        return {"identityMatched": self.identity_match, "pid": process_id,
                "canonicalPath": expected["canonicalPath"], "nonce": expected.get("nonce", "N")}

    def confirm_detach(self, identity, process_id):
        self.calls.append(("confirmDetach", process_id))
        return {"sameIdentity": True, "alive": self.detach_alive,
                "controllable": self.detach_alive, "checkpointSequence": 4,
                "pid": process_id, "canonicalPath": identity["canonicalPath"],
                "nonce": identity["nonce"]}


def request(operation, sequence, *, arguments=None, session="S", epoch=1, timeout_ms=1000):
    return {
        "schema": bridge.BRIDGE_SCHEMA,
        "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
        "requestID": f"R-{sequence}",
        "sessionID": session,
        "sessionEpoch": epoch,
        "sequence": sequence,
        "operation": operation,
        "timeoutMS": timeout_ms,
        "arguments": arguments or {},
    }


def exact_identity(pid=4242):
    return {
        "pid": pid, "startTimeNS": 123456789, "realUID": 501, "effectiveUID": 501,
        "canonicalPath": "/tmp/FixtureHelper", "cpuType": 0x0100000C,
        "cpuSubtype": 0, "executableDevice": 1, "executableInode": 2,
        "executableIdentity": "sha256:abc", "machOUUID": "UUID-H",
        "signingIdentity": "Apple Development", "nonce": "N", "role": "attachedHelper",
    }


class BridgeContractTests(unittest.TestCase):
    def setUp(self):
        self.authority = Authority()
        self.engine = bridge.LLDBPythonBridge(FakeSB, self.authority)

    def initialize(self):
        response = self.engine.handle(request("initialize", 1))
        self.assertEqual(response["observation"], "observed", response)
        return response

    def test_initialize_echoes_correlation_and_versions_the_selected_lldb(self):
        response = self.initialize()
        self.assertEqual(response["schema"], bridge.BRIDGE_SCHEMA)
        self.assertEqual(response["requestID"], "R-1")
        self.assertEqual(response["sessionID"], "S")
        self.assertEqual(response["sessionEpoch"], 1)
        self.assertEqual(response["result"]["lldbVersion"], "lldb-fake-27")
        self.assertEqual(response["lifecycleRevision"], 1)
        self.assertEqual(response["stopRevision"], 0)

    def test_rejects_duplicate_sequence_and_wrong_session_epoch(self):
        self.initialize()
        with self.assertRaisesRegex(bridge.BridgeProtocolError, "sequence"):
            self.engine.handle(request("capabilities", 1))
        with self.assertRaisesRegex(bridge.BridgeProtocolError, "epoch"):
            self.engine.handle(request("capabilities", 2, epoch=2))

    def test_launch_requires_authority_and_independent_process_postcondition(self):
        self.initialize()
        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))
        self.assertEqual(response["observation"], "observed")
        self.assertEqual(response["result"]["targetPID"], 4242)
        self.assertEqual(response["targetDisposition"], "stopped")
        target = FakeSBDebuggerFactory.last.target
        self.assertEqual(target.last_launch_info.arguments, ["--nonce", "N"])
        self.assertEqual(target.last_launch_info.cwd, "/tmp")
        self.assertEqual(target.last_launch_info.environment, ["FIXTURE_NONCE=N"])
        self.assertEqual(target.last_launch_info.flags, FakeSB.eLaunchFlagStopAtEntry)
        self.assertIn(("observeProcess", "configuredLaunch", 4242), self.authority.calls)
        self.assertEqual(self.authority.observed_states, [FakeSB.eStateRunning])
        self.assertEqual(target.process.call_order, ["continue", "stop"])
        self.assertEqual(FakeSBDebuggerFactory.last.async_history, [False, True, False])

    def test_launch_waits_for_delayed_async_running_transition(self):
        self.initialize()
        target = FakeSBDebuggerFactory.last.CreateTarget("/tmp/placeholder")
        process = target.process
        original_continue = process.Continue
        states = [FakeSB.eStateStopped, FakeSB.eStateStopped, FakeSB.eStateRunning]

        def delayed_continue():
            result = original_continue()
            process.state = FakeSB.eStateStopped
            return result

        def delayed_state():
            if states:
                process.state = states.pop(0)
            return process.state

        process.Continue = delayed_continue
        process.GetState = delayed_state
        FakeSBDebuggerFactory.last.target = None
        def create_target(path):
            FakeSBDebuggerFactory.last.target = target
            return target
        FakeSBDebuggerFactory.last.CreateTarget = create_target

        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        self.assertEqual(response["observation"], "observed", response)
        self.assertEqual(response["result"]["targetPID"], 4242)
        self.assertIn(("observeProcess", "configuredLaunch", 4242), self.authority.calls)
        self.assertEqual(process.call_order, ["continue", "stop"])

    def test_launch_waits_for_delayed_async_stopped_transition(self):
        self.initialize()
        target = FakeSBDebuggerFactory.last.CreateTarget("/tmp/placeholder")
        process = target.process
        stop_states = []

        def delayed_stop():
            process.call_order.append("stop")
            stop_states.extend([FakeSB.eStateRunning, FakeSB.eStateStopped])
            return process.stop_error

        def delayed_state():
            if stop_states:
                process.state = stop_states.pop(0)
            return process.state

        process.Stop = delayed_stop
        process.GetState = delayed_state
        FakeSBDebuggerFactory.last.target = None
        def create_target(path):
            FakeSBDebuggerFactory.last.target = target
            return target
        FakeSBDebuggerFactory.last.CreateTarget = create_target

        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        self.assertEqual(response["observation"], "observed", response)
        self.assertEqual(response["targetDisposition"], "stopped")
        self.assertEqual(process.call_order, ["continue", "stop"])

    def test_launch_drives_bridge_owned_async_process_events(self):
        self.initialize()
        target = FakeSBDebuggerFactory.last.CreateTarget("/tmp/placeholder")
        process = target.process
        debugger = FakeSBDebuggerFactory.last
        original_wait = debugger.listener.WaitForEvent

        def delayed_continue():
            process.call_order.append("continue")
            debugger.listener.states.append(FakeSB.eStateRunning)
            return process.continue_error

        def delayed_stop():
            process.call_order.append("stop")
            debugger.listener.states.append(FakeSB.eStateStopped)
            return process.stop_error

        def state_updating_wait(timeout, event):
            delivered = original_wait(timeout, event)
            if delivered:
                process.state = event.state
            return delivered

        process.Continue = delayed_continue
        process.Stop = delayed_stop
        debugger.listener.WaitForEvent = state_updating_wait
        debugger.target = None
        def create_target(path):
            debugger.target = target
            return target
        debugger.CreateTarget = create_target

        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        self.assertEqual(response["observation"], "observed", response)
        self.assertEqual(self.authority.observed_states, [FakeSB.eStateRunning])
        self.assertEqual(process.call_order, ["continue", "stop"])
        self.assertTrue(debugger.listener.timeouts)
        self.assertTrue(all(isinstance(value, int)
                            for value in debugger.listener.timeouts))

    def test_launch_restop_failure_delegates_registered_target_to_supervisor(self):
        self.initialize()
        target = FakeSBDebuggerFactory.last.CreateTarget("/tmp/placeholder")
        target.process.stop_error = FakeError(False, "stop failed")
        FakeSBDebuggerFactory.last.target = None

        original_create = FakeSBDebuggerFactory.last.CreateTarget
        def create_target(path):
            FakeSBDebuggerFactory.last.target = target
            return target
        FakeSBDebuggerFactory.last.CreateTarget = create_target
        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        self.assertEqual(response["observation"], "adapterError")
        self.assertEqual(response["ownership"], "launchedTestFixture")
        self.assertEqual(target.process.kill_calls, 0)
        self.assertTrue(response["evidence"]["cleanup"]["delegatedToOuterSupervisor"])
        self.assertEqual(target.process.call_order, ["continue", "stop"])
        self.assertEqual(FakeSBDebuggerFactory.last.async_history, [False, True, False])
        self.assertIs(self.engine.process, target.process)
        FakeSBDebuggerFactory.last.CreateTarget = original_create

    def test_launch_accepts_stop_error_when_same_process_is_already_stopped(self):
        self.initialize()
        target = FakeSBDebuggerFactory.last.CreateTarget("/tmp/placeholder")
        process = target.process
        process.stop_error = FakeError(False, "Process is not running.")
        original_stop = process.Stop

        def already_stopped():
            result = original_stop()
            process.state = FakeSB.eStateStopped
            return result

        process.Stop = already_stopped
        FakeSBDebuggerFactory.last.target = None
        def create_target(path):
            FakeSBDebuggerFactory.last.target = target
            return target
        FakeSBDebuggerFactory.last.CreateTarget = create_target

        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        self.assertEqual(response["observation"], "observed", response)
        self.assertEqual(response["targetDisposition"], "stopped")
        self.assertEqual(response["result"]["targetPID"], 4242)

    def test_launch_identity_mismatch_rests_then_kills_before_publishing(self):
        self.initialize()
        self.authority.identity_match = False
        response = self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp", "environment": {"FIXTURE_NONCE": "N"},
            "stopAtEntry": True,
        }))

        process = FakeSBDebuggerFactory.last.target.process
        self.assertEqual(response["observation"], "identityMismatch")
        self.assertEqual(process.call_order, ["continue", "stop"])
        self.assertEqual(process.kill_calls, 1)
        self.assertEqual(response["ownership"], "none")
        self.assertIsNone(self.engine.process)

    def test_attach_requires_complete_identity_and_explicit_matching_sb_pid(self):
        self.initialize()
        incomplete = exact_identity()
        incomplete.pop("startTimeNS")
        response = self.engine.handle(request("attach", 2, arguments={"identity": incomplete}))
        self.assertEqual(response["observation"], "identityMismatch")

        engine = bridge.LLDBPythonBridge(FakeSB, self.authority)
        engine.handle(request("initialize", 1))
        response = engine.handle(request("attach", 2, arguments={"identity": exact_identity(9191)}))
        self.assertEqual(response["observation"], "observed")
        self.assertEqual(response["result"]["targetPID"], 9191)
        self.assertEqual(response["ownership"], "attachedTestFixture")

    def test_attach_abstains_when_external_identity_observer_disagrees(self):
        self.initialize()
        self.authority.identity_match = False
        response = self.engine.handle(request("attach", 2, arguments={"identity": exact_identity()}))
        self.assertEqual(response["observation"], "identityMismatch")
        self.assertEqual(response["targetDisposition"], "targetDispositionUnknown")

    def test_detach_is_nonterminating_and_requires_correlated_survival_proof(self):
        self.initialize()
        self.engine.handle(request("attach", 2, arguments={"identity": exact_identity()}))
        detached = self.engine.handle(request("detach", 3))
        self.assertEqual(detached["observation"], "observed")
        self.assertEqual(detached["targetDisposition"], "detached")
        self.assertFalse(detached["result"]["terminateRequested"])
        self.assertTrue(detached["result"]["postDetach"]["alive"])

        engine = bridge.LLDBPythonBridge(FakeSB, self.authority)
        engine.handle(request("initialize", 1))
        engine.handle(request("attach", 2, arguments={"identity": exact_identity()}))
        self.authority.detach_alive = False
        rejected = engine.handle(request("detach", 3))
        self.assertEqual(rejected["observation"], "identityMismatch")
        self.assertEqual(rejected["targetDisposition"], "targetDispositionUnknown")

    def test_poll_events_advances_lifecycle_and_stop_revisions(self):
        self.initialize()
        self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": [], "workingDirectory": "/tmp",
            "environment": {}, "stopAtEntry": True,
        }))
        FakeSBDebuggerFactory.last.listener.states.extend([FakeSB.eStateRunning, FakeSB.eStateStopped])
        response = self.engine.handle(request("pollEvents", 3, arguments={"maximumEvents": 2}))
        self.assertEqual([item["state"] for item in response["result"]["events"]],
                         ["running", "stopped"])
        self.assertGreaterEqual(response["lifecycleRevision"], 4)
        self.assertEqual(response["stopRevision"], 2)

    def test_supported_hard_primitives_return_concrete_postconditions(self):
        self.initialize()
        self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": [], "workingDirectory": "/tmp",
            "environment": {}, "stopAtEntry": True,
        }))
        operations = [
            ("breakpointCreation", {"address": 0x100001000}, "breakpointID"),
            ("threadList", {}, "threads"),
            ("threadSelection", {"threadID": 77}, "threadID"),
            ("frameList", {"threadID": 77}, "frames"),
            ("frameSelection", {"threadID": 77, "frameIndex": 0}, "frameIndex"),
            ("registerRead", {"threadID": 77, "frameIndex": 0}, "registers"),
            ("memoryRead", {"address": 0x1000, "size": 4}, "dataBase64"),
            ("memoryWrite", {"address": 0x1000, "dataBase64": "V1hZWg=="}, "bytesWritten"),
            ("expressionEvaluation", {"expression": "6 * 7"}, "value"),
            ("moduleList", {}, "modules"),
        ]
        sequence = 3
        for operation, arguments, result_key in operations:
            with self.subTest(operation=operation):
                response = self.engine.handle(request(operation, sequence, arguments=arguments))
                self.assertEqual(response["observation"], "observed")
                self.assertIn(result_key, response["result"])
                self.assertTrue(response["evidence"]["postcondition"]["satisfied"])
            sequence += 1

    def test_pause_continue_and_steps_are_revision_bound(self):
        self.initialize()
        self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": [], "workingDirectory": "/tmp",
            "environment": {}, "stopAtEntry": True,
        }))
        paused = self.engine.handle(request("pause", 3))
        continued = self.engine.handle(request("continue", 4))
        self.assertEqual(paused["result"]["state"], "stopped")
        self.assertEqual(continued["result"]["state"], "running")
        self.engine.process.state = FakeSB.eStateStopped
        for sequence, operation in enumerate(("stepInto", "stepOver", "stepOut"), 5):
            self.engine.listener.states.append(FakeSB.eStateStopped)
            response = self.engine.handle(request(operation, sequence))
            self.assertEqual(response["observation"], "observed")
            self.assertEqual(response["result"]["state"], "stopped")

    def test_expected_exit_reuses_truthful_terminal_fact_from_terminate(self):
        self.initialize()
        self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": [], "workingDirectory": "/tmp",
            "environment": {}, "stopAtEntry": True,
        }))
        terminated = self.engine.handle(request("terminate", 3))
        exited = self.engine.handle(request("expectedExit", 4))

        self.assertEqual(terminated["observation"], "observed")
        self.assertEqual(terminated["targetDisposition"], "exited")
        self.assertEqual(terminated["result"]["targetPID"], 4242)
        self.assertEqual(exited["observation"], "observed")
        self.assertEqual(exited["targetDisposition"], "exited")
        self.assertEqual(exited["result"]["originatingOperation"], "terminate")
        self.assertEqual(exited["result"]["targetPID"], 4242)
        self.assertEqual(self.engine.process.kill_calls, 1)

    def test_expected_exit_without_terminal_state_is_typed_negative_evidence(self):
        self.initialize()
        self.engine.handle(request("configuredLaunch", 2, arguments={
            "executable": "/tmp/Fixture", "arguments": [], "workingDirectory": "/tmp",
            "environment": {}, "stopAtEntry": True,
        }))
        response = self.engine.handle(request("expectedExit", 3))

        self.assertEqual(response["observation"], "adapterError")
        self.assertNotEqual(response["targetDisposition"], "exited")
        self.assertIn("not exited", response["diagnostic"]["reason"])

    def test_unsupported_operations_are_typed_and_never_observed(self):
        self.initialize()
        for sequence, operation in enumerate((
            "moduleLoad", "moduleUnload", "cancelBeforeSpawn", "cancelInFlight",
            "timeoutRecovery", "adapterCrashRecovery",
        ), 2):
            response = self.engine.handle(request(operation, sequence))
            self.assertEqual(response["observation"], "unsupported")
            self.assertTrue(response["diagnostic"]["reason"])


class JSONLTests(unittest.TestCase):
    def test_server_rejects_oversized_and_malformed_records_with_bounded_error(self):
        engine = bridge.LLDBPythonBridge(FakeSB, Authority())
        output = io.BytesIO()
        server = bridge.JSONLBridgeServer(engine, io.BytesIO(b"x" * 300 + b"\n"), output,
                                          max_record_bytes=256)
        self.assertEqual(server.serve_one(), "protocolError")
        error = json.loads(output.getvalue())
        self.assertEqual(error["observation"], "protocolError")
        self.assertLessEqual(len(output.getvalue()), 256)

        output = io.BytesIO()
        server = bridge.JSONLBridgeServer(engine, io.BytesIO(b"{bad}\n"), output)
        self.assertEqual(server.serve_one(), "protocolError")
        self.assertEqual(json.loads(output.getvalue())["observation"], "protocolError")

    def test_server_round_trip_is_one_canonical_json_line(self):
        engine = bridge.LLDBPythonBridge(FakeSB, Authority())
        raw = (json.dumps(request("initialize", 1), sort_keys=True) + "\n").encode()
        output = io.BytesIO()
        server = bridge.JSONLBridgeServer(engine, io.BytesIO(raw), output)
        self.assertEqual(server.serve_one(), "observed")
        self.assertEqual(output.getvalue().count(b"\n"), 1)
        self.assertEqual(json.loads(output.getvalue())["requestID"], "R-1")


class DiscoveryAndClientTests(unittest.TestCase):
    class Runner:
        def __init__(self, outputs): self.outputs, self.calls = list(outputs), []
        def run(self, argv, *, env=None, timeout=15.0):
            self.calls.append((tuple(argv), env, timeout))
            return self.outputs.pop(0)

    class Result:
        def __init__(self, returncode=0, stdout="", stderr=""):
            self.returncode, self.stdout, self.stderr = returncode, stdout, stderr

    def test_discovery_uses_selected_xcode_lldb_module_path_and_import_probe(self):
        python = ("/Applications/Xcode-beta.app/Contents/Developer/Library/Frameworks/"
                  "Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python")
        runner = self.Runner([
            self.Result(stdout="/Applications/Xcode-beta.app/Contents/Developer/usr/bin/lldb\n"),
            self.Result(stdout="/Applications/Xcode-beta.app/Contents/SharedFrameworks/LLDB.framework/Resources/Python\n"),
            self.Result(stdout=json.dumps({
                "module": "/Xcode/lldb/__init__.py",
                "pythonExecutable": python,
                "version": "lldb-27",
            }) + "\n"),
        ])
        discovery = bridge.discover_selected_xcode_lldb(runner)
        self.assertTrue(discovery.supported)
        self.assertEqual(discovery.python_executable, python)
        self.assertEqual(discovery.module_path,
            "/Applications/Xcode-beta.app/Contents/SharedFrameworks/LLDB.framework/Resources/Python")
        self.assertEqual(discovery.version, "lldb-27")
        self.assertEqual(runner.calls[1][0][-3:], ("--no-lldbinit", "--batch", "-P"))
        self.assertEqual(runner.calls[2][1]["PYTHONPATH"], discovery.module_path)
        self.assertIn("proc_pidpath", runner.calls[2][0][-1])

    def test_client_requires_injected_lifecycle_and_exact_response_correlation(self):
        discovery = bridge.LLDBPythonDiscovery(True, "/usr/bin/python3", "/Xcode/Python",
                                               "lldb-27", {"importAvailable": True})
        responses = [
            json.dumps({"schema": bridge.BRIDGE_SCHEMA,
                        "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
                        "requestID": "R", "sessionID": "S", "sessionEpoch": 1,
                        "sequence": 1, "operation": "initialize", "observation": "observed",
                        "lifecycleRevision": 1, "stopRevision": 0,
                        "targetDisposition": "notStarted", "ownership": "none",
                        "result": {}, "evidence": {}, "diagnostic": {}}).encode() + b"\n"
        ]
        class Process:
            stdin = io.BytesIO()
            stdout = io.BytesIO(responses[0])
            stderr = io.BytesIO()
        class Lifecycle:
            def __init__(self): self.cleaned = []
            def spawn_and_register(self, argv, env): return Process(), "REG"
            def cleanup_bridge(self, registration):
                self.cleaned.append(registration)
                return {"role": "adapter", "registration": registration, "complete": True}
        lifecycle = Lifecycle()
        client = bridge.LLDBPythonBridgeClient(discovery, lifecycle,
            wait_readable=lambda stream, timeout: True)
        response = client.request(request("initialize", 1, session="S") | {"requestID": "R"})
        self.assertEqual(response["observation"], "observed")
        receipt = client.close()
        self.assertTrue(receipt["complete"])
        self.assertEqual(lifecycle.cleaned, ["REG"])
        payload = json.loads(Process.stdin.getvalue())
        self.assertEqual(payload["requestID"], "R")


class CrossProcessAuthorityTests(unittest.TestCase):
    def setUp(self):
        self.launch = {
            "executable": "/tmp/FixtureHelper",
            "arguments": ["--nonce", "N"],
            "workingDirectory": "/tmp",
            "environment": {"FIXTURE_NONCE": "N"},
            "canonicalPath": "/tmp/FixtureHelper",
            "nonce": "N",
            "role": "launchedHelper",
        }
        self.observations = []
        self.detach_checks = []

        def process_observer(operation, process_id, expected):
            self.observations.append((operation, process_id, dict(expected)))
            return {
                "identityMatched": True,
                "pid": process_id,
                "canonicalPath": expected["canonicalPath"],
                "nonce": expected["nonce"],
            }

        def detach_observer(identity, process_id):
            self.detach_checks.append((dict(identity), process_id))
            return {
                "sameIdentity": True, "alive": True, "controllable": True,
                "checkpointSequence": 9, "pid": process_id,
                "canonicalPath": identity["canonicalPath"], "nonce": identity["nonce"],
            }

        self.authority = bridge.ExactFixtureAuthority(
            allowed_launch=self.launch,
            allowed_attach_identities=[exact_identity(9191)],
            process_observer=process_observer,
            detach_observer=detach_observer,
        )

    def test_exact_fixture_authority_denies_every_mutated_launch_dimension(self):
        exact = self.authority.authorize_launch(
            self.launch["executable"], self.launch["arguments"],
            self.launch["workingDirectory"], self.launch["environment"])
        self.assertTrue(exact["authorized"])
        mutations = [
            ("/tmp/Other", self.launch["arguments"], "/tmp", self.launch["environment"]),
            (self.launch["executable"], ["--nonce", "WRONG"], "/tmp", self.launch["environment"]),
            (self.launch["executable"], self.launch["arguments"], "/private/tmp", self.launch["environment"]),
            (self.launch["executable"], self.launch["arguments"], "/tmp", {"LD_PRELOAD": "/tmp/x"}),
        ]
        for executable, arguments, cwd, environment in mutations:
            with self.subTest(executable=executable, arguments=arguments, cwd=cwd,
                              environment=environment):
                rejected = self.authority.authorize_launch(executable, arguments, cwd, environment)
                self.assertFalse(rejected["authorized"])
                self.assertEqual(rejected["reasonCode"], "launchAuthorizationMismatch")
        malformed = self.authority.authorize_launch(
            self.launch["executable"], None, "/tmp", self.launch["environment"])
        self.assertFalse(malformed["authorized"])
        self.assertEqual(malformed["reasonCode"], "launchRequestInvalid")

    def test_exact_fixture_authority_denies_incomplete_or_mutated_attach_identity(self):
        allowed = self.authority.authorize_attach(exact_identity(9191))
        self.assertTrue(allowed["authorized"])
        for field, value in (("pid", 9192), ("canonicalPath", "/tmp/Other"),
                             ("nonce", "WRONG"), ("startTimeNS", None)):
            mutated = exact_identity(9191)
            if value is None:
                mutated.pop(field)
            else:
                mutated[field] = value
            with self.subTest(field=field):
                rejected = self.authority.authorize_attach(mutated)
                self.assertFalse(rejected["authorized"])
                self.assertIn(rejected["reasonCode"],
                              ("attachIdentityIncomplete", "attachAuthorizationMismatch"))

    def test_parent_authority_rpc_is_correlated_and_preserves_explicit_fields(self):
        callback = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "messageType": "authorityRequest",
            "authorityRequestID": "R-2:authority:1",
            "requestID": "R-2", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 2, "operation": "configuredLaunch",
            "authorityOperation": "authorizeLaunch", "timeoutMS": 500,
            "payload": {
                "executable": self.launch["executable"],
                "arguments": self.launch["arguments"],
                "workingDirectory": self.launch["workingDirectory"],
                "environment": self.launch["environment"],
            },
        }
        response = self.authority.handle_authority_request(callback)
        for field in ("authorityRequestID", "requestID", "sessionID", "sessionEpoch",
                      "sequence", "operation", "authorityOperation"):
            self.assertEqual(response[field], callback[field])
        self.assertEqual(response["messageType"], "authorityResponse")
        self.assertTrue(response["result"]["authorized"])

    def test_child_proxy_uses_bounded_correlated_callback_not_local_process_discovery(self):
        expected_response = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "messageType": "authorityResponse",
            "authorityRequestID": "R-2:authority:1",
            "requestID": "R-2", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 2, "operation": "configuredLaunch",
            "authorityOperation": "authorizeLaunch",
            "result": {"authorized": True, "canonicalPath": "/tmp/FixtureHelper",
                       "nonce": "N", "role": "launchedHelper"},
        }
        reader = io.BytesIO((json.dumps(expected_response) + "\n").encode())
        writer = io.BytesIO()
        proxy = bridge.JSONLParentAuthorityProxy(
            reader, writer, wait_readable=lambda stream, timeout: True)
        proxy.begin_request(request("configuredLaunch", 2, arguments={}, timeout_ms=500))
        result = proxy.authorize_launch(
            self.launch["executable"], self.launch["arguments"],
            self.launch["workingDirectory"], self.launch["environment"])
        self.assertTrue(result["authorized"])
        emitted = json.loads(writer.getvalue())
        self.assertEqual(emitted["messageType"], "authorityRequest")
        self.assertEqual(emitted["payload"]["arguments"], ["--nonce", "N"])
        self.assertNotIn("discover", emitted)

    def test_client_services_authority_callback_before_final_bridge_response(self):
        callback = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "messageType": "authorityRequest",
            "authorityRequestID": "R:authority:1",
            "requestID": "R", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 1, "operation": "configuredLaunch",
            "authorityOperation": "authorizeLaunch", "timeoutMS": 500,
            "payload": {
                "executable": self.launch["executable"],
                "arguments": self.launch["arguments"],
                "workingDirectory": self.launch["workingDirectory"],
                "environment": self.launch["environment"],
            },
        }
        final = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "requestID": "R", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 1, "operation": "configuredLaunch", "observation": "observed",
            "lifecycleRevision": 2, "stopRevision": 1,
            "targetDisposition": "stopped", "ownership": "launchedTestFixture",
            "result": {"targetPID": 4242}, "evidence": {}, "diagnostic": {},
        }

        class Process:
            stdin = io.BytesIO()
            stdout = io.BytesIO(
                (json.dumps(callback) + "\n" + json.dumps(final) + "\n").encode())
            stderr = io.BytesIO()

        class Lifecycle:
            def spawn_and_register(self, argv, env): return Process(), "REG"
            def cleanup_bridge(self, registration): return {"complete": True}

        discovery = bridge.LLDBPythonDiscovery(
            True, "/usr/bin/python3", "/Xcode/Python", "lldb-27", {})
        client = bridge.LLDBPythonBridgeClient(
            discovery, Lifecycle(), authority=self.authority,
            wait_readable=lambda stream, timeout: True)
        message = request("configuredLaunch", 1, arguments=callback["payload"],
                          session="S", timeout_ms=500) | {"requestID": "R"}
        response = client.request(message)
        self.assertEqual(response["observation"], "observed")
        written = Process.stdin.getvalue().splitlines()
        self.assertEqual(len(written), 2)
        authority_response = json.loads(written[1])
        self.assertEqual(authority_response["messageType"], "authorityResponse")
        self.assertTrue(authority_response["result"]["authorized"])

    def test_client_without_parent_authority_returns_typed_denial(self):
        callback = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "messageType": "authorityRequest", "authorityRequestID": "R:authority:1",
            "requestID": "R", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 1, "operation": "attach", "authorityOperation": "authorizeAttach",
            "timeoutMS": 500, "payload": {"identity": exact_identity(9191)},
        }
        final = {
            "schema": bridge.BRIDGE_SCHEMA,
            "contractVersion": bridge.BRIDGE_CONTRACT_VERSION,
            "requestID": "R", "sessionID": "S", "sessionEpoch": 1,
            "sequence": 1, "operation": "attach", "observation": "identityMismatch",
            "lifecycleRevision": 1, "stopRevision": 0,
            "targetDisposition": "targetDispositionUnknown", "ownership": "none",
            "result": {}, "evidence": {}, "diagnostic": {"reason": "attach denied"},
        }

        class Process:
            stdin = io.BytesIO()
            stdout = io.BytesIO(
                (json.dumps(callback) + "\n" + json.dumps(final) + "\n").encode())
            stderr = io.BytesIO()

        class Lifecycle:
            def spawn_and_register(self, argv, env): return Process(), "REG"
            def cleanup_bridge(self, registration): return {"complete": True}

        discovery = bridge.LLDBPythonDiscovery(
            True, "/usr/bin/python3", "/Xcode/Python", "lldb-27", {})
        client = bridge.LLDBPythonBridgeClient(
            discovery, Lifecycle(), wait_readable=lambda stream, timeout: True)
        response = client.request(request("attach", 1, arguments=callback["payload"],
                                          session="S", timeout_ms=500) | {"requestID": "R"})
        self.assertEqual(response["observation"], "identityMismatch")
        denial = json.loads(Process.stdin.getvalue().splitlines()[1])
        self.assertFalse(denial["result"]["authorized"])
        self.assertEqual(denial["result"]["reasonCode"], "parentAuthorityUnavailable")


if __name__ == "__main__":
    unittest.main()
